const std = @import("std");
const builtin = @import("builtin");
const shmecs = @import("shmecs");

const entity_count = 131_072;
const frame_count = 128;
const sample_count = 7;
const delta: f32 = 0.25;
const allocator = std.heap.page_allocator;

const Motion = struct { x: f32, y: f32, velocity_x: f32, velocity_y: f32 };
const Health = struct { current: f32, maximum: f32 };
const Cold = struct { bytes: [64]u8 };
const Traversal = enum { array, columns, iterator, query };
const Marking = enum { world, iterator, query };

fn Entity(comptime tag: usize) type {
    return struct {
        pub const kind = tag;

        motion: Motion,
        health: Health,
        cold: Cold,
    };
}

fn entityTypes(comptime count: usize) [count]type {
    var result: [count]type = undefined;

    for (0..count) |index| result[index] = Entity(index);

    return result;
}

pub fn main(init: std.process.Init) !void {
    if (builtin.mode != .ReleaseFast) return error.UseReleaseFast;

    std.debug.print("Zig {s}, {s}, ReleaseFast; {d} entities, {d} frames, median of {d}\n", .{
        builtin.zig_version_string, @tagName(builtin.cpu.arch), entity_count, frame_count, sample_count,
    });
    std.debug.print("Entity components: {d} bytes; ID: {d}\n", .{
        @sizeOf(Motion) + @sizeOf(Health) + @sizeOf(Cold),
        @sizeOf(shmecs.EntityId),
    });
    std.debug.print("Traversal includes iterator setup/teardown; flush excludes marking. Allocator: page_allocator.\n", .{});

    try benchmarkTraversal(init.io, 1, false);
    try benchmarkTraversal(init.io, 16, false);
    try benchmarkTraversal(init.io, 16, true);
    try benchmarkSpawn(init.io, false);
    try benchmarkSpawn(init.io, true);

    inline for (.{ 0, 1, 10, 100 }) |percentage| {
        inline for (comptime std.meta.tags(Marking)) |method| {
            try benchmarkRemovals(init.io, percentage, method);
        }
    }
}

fn initialMotion(index: usize) Motion {
    return .{
        .x = @floatFromInt(index % 256),
        .y = 0,
        .velocity_x = 1,
        .velocity_y = -0.5,
    };
}

fn initialEntity(comptime T: type, index: usize) T {
    return .{
        .motion = initialMotion(index),
        .health = .{ .current = 100, .maximum = 100 },
        .cold = .{ .bytes = @splat(@truncate(index)) },
    };
}

fn benchmarkTraversal(io: std.Io, comptime pool_count: usize, comptime with_empty_pools: bool) !void {
    @setEvalBranchQuota(20_000);

    const types = comptime entityTypes(pool_count);
    var world = shmecs.World(types).init(allocator);
    defer world.deinit();

    const populated_count = if (with_empty_pools) pool_count / 2 else pool_count;
    var populated_index: usize = 0;

    inline for (types, 0..) |T, pool_index| {
        if (!with_empty_pools or pool_index % 4 == 1 or pool_index % 4 == 2) {
            try world.pool(T).reserve(entity_count / populated_count);

            for (0..entity_count / populated_count) |index| {
                _ = try world.add(initialEntity(T, populated_index * (entity_count / populated_count) + index));
            }

            populated_index += 1;
        }
    }

    const array = try allocator.alloc(Motion, entity_count);
    defer allocator.free(array);

    const methods = comptime std.meta.tags(Traversal);
    var timings: [methods.len][sample_count]u64 = undefined;
    var expected: f64 = 0;

    for (0..entity_count) |index| {
        const motion = initialMotion(index);
        const frames: f64 = frame_count + 1;
        expected += motion.x + frames * delta * motion.velocity_x;
        expected += motion.y + frames * delta * motion.velocity_y;
    }

    for (0..sample_count) |sample| {
        for (0..methods.len) |turn| {
            const method_index = (sample + turn) % methods.len;

            inline for (methods, 0..) |method, index| {
                if (method_index == index) {
                    resetMotions(types, &world, array);
                    update(method, types, &world, array);

                    const start = std.Io.Clock.awake.now(io);

                    for (0..frame_count) |_| {
                        update(method, types, &world, array);
                    }

                    timings[index][sample] = elapsed(io, start);

                    const result = if (method == .array) checksum(array) else worldChecksum(types, &world);
                    if (result != expected) return error.InvalidTraversalChecksum;
                }
            }
        }
    }

    inline for (methods, 0..) |method, index| {
        const duration = median(timings[index]);
        const operations: f64 = entity_count * frame_count;
        const nanoseconds: f64 = @floatFromInt(duration);

        std.debug.print("iterate/{d}/{s}/{s}: {d:.3} ns/entity, {d:.3} us/frame\n", .{
            pool_count,
            if (with_empty_pools) "half empty" else "all populated",
            @tagName(method),
            nanoseconds / operations,
            nanoseconds / frame_count / 1000,
        });
    }
}

fn resetMotions(comptime types: anytype, world: anytype, array: []Motion) void {
    for (0..array.len) |index| array[index] = initialMotion(index);

    var offset: usize = 0;

    inline for (types) |T| {
        const motion = world.pool(T).components(Motion);

        for (0..motion.len) |index| {
            motion[index] = initialMotion(offset + index);
        }

        offset += motion.len;
    }
}

noinline fn update(comptime method: Traversal, comptime types: anytype, world: anytype, array: []Motion) void {
    switch (method) {
        .array => {
            move(array);
            std.mem.doNotOptimizeAway(array.ptr);
        },
        .columns => {
            inline for (types) |T| move(world.pool(T).components(Motion));
            std.mem.doNotOptimizeAway(world);
        },
        .iterator => {
            inline for (types) |T| {
                var entities = world.pool(T).iterator();
                defer entities.deinit();

                while (entities.next()) |entity| {
                    entity.motion.x += entity.motion.velocity_x * delta;
                    entity.motion.y += entity.motion.velocity_y * delta;
                }
            }

            std.mem.doNotOptimizeAway(world);
        },
        .query => {
            var query = world.query(.{ .motion = Motion });
            defer query.deinit();

            while (query.next()) |entity| {
                entity.motion.x += entity.motion.velocity_x * delta;
                entity.motion.y += entity.motion.velocity_y * delta;
            }

            std.mem.doNotOptimizeAway(world);
        },
    }
}

fn move(motion: []Motion) void {
    for (0..motion.len) |index| {
        motion[index].x += motion[index].velocity_x * delta;
        motion[index].y += motion[index].velocity_y * delta;
    }
}

fn checksum(motion: []const Motion) f64 {
    var result: f64 = 0;

    for (0..motion.len) |index| {
        const x: f64 = motion[index].x;
        const y: f64 = motion[index].y;
        result += x;
        result += y;
    }

    return result;
}

fn worldChecksum(comptime types: anytype, world: anytype) f64 {
    var result: f64 = 0;

    inline for (types) |T| result += checksum(world.pool(T).components(Motion));

    return result;
}

fn benchmarkSpawn(io: std.Io, comptime reserved: bool) !void {
    var timings: [sample_count]u64 = undefined;

    for (0..sample_count + 1) |sample| {
        var world = shmecs.World(.{Entity(0)}).init(allocator);
        defer world.deinit();

        if (reserved) try world.pool(Entity(0)).reserve(entity_count);

        const start = std.Io.Clock.awake.now(io);

        for (0..entity_count) |index| {
            _ = try world.add(initialEntity(Entity(0), index));
        }

        std.mem.doNotOptimizeAway(&world);
        const duration = elapsed(io, start);

        if (world.pool(Entity(0)).len() != entity_count) return error.InvalidSpawnCount;
        if (sample != 0) timings[sample - 1] = duration;
    }

    const nanoseconds: f64 = @floatFromInt(median(timings));

    std.debug.print("spawn/{s}: {d:.3} ns/entity, {d:.3} ms/batch\n", .{
        if (reserved) "reserved (reserve excluded)" else "automatic growth",
        nanoseconds / entity_count,
        nanoseconds / 1_000_000,
    });
}

fn benchmarkRemovals(io: std.Io, comptime percentage: usize, comptime method: Marking) !void {
    const ids = try allocator.alloc(shmecs.EntityId, entity_count);
    defer allocator.free(ids);

    var timings: [sample_count]u64 = undefined;
    const repetitions = if (percentage == 0) 256 else 1;

    for (0..sample_count + 1) |sample| {
        var world = shmecs.World(.{Entity(0)}).init(allocator);
        defer world.deinit();

        try world.pool(Entity(0)).reserve(entity_count);

        for (0..entity_count) |index| {
            ids[index] = try world.add(initialEntity(Entity(0), index));
        }

        var expected: usize = 0;

        switch (method) {
            .world => {
                for (0..ids.len) |index| {
                    if (index % 100 < percentage) {
                        try world.markForRemoval(ids[index]);
                        expected += 1;
                    }
                }
            },
            .iterator => {
                var entities = world.pool(Entity(0)).iterator();
                defer entities.deinit();
                var index: usize = 0;

                while (entities.next()) |_| {
                    if (!std.meta.eql(entities.id().?, ids[index])) return error.InvalidIteratorId;

                    if (index % 100 < percentage) {
                        try entities.markForRemoval();
                        try entities.markForRemoval();
                        expected += 1;
                    }

                    index += 1;
                }
            },
            .query => {
                var query = world.query(.{ .motion = Motion, .health = Health });
                defer query.deinit();
                var index: usize = 0;

                while (query.next()) |entity| {
                    if (!std.meta.eql(query.id().?, ids[index])) return error.InvalidQueryId;
                    if (entity.health.current != 100 or entity.motion.x != initialMotion(index).x)
                        return error.InvalidQueryComponents;

                    if (index % 100 < percentage) {
                        try query.markForRemoval();
                        try query.markForRemoval();
                        expected += 1;
                    }

                    index += 1;
                }
            },
        }

        const start = std.Io.Clock.awake.now(io);
        var removed: usize = 0;

        for (0..repetitions) |_| {
            removed += try world.flushRemovals();
            std.mem.doNotOptimizeAway(&world);
        }

        const duration = elapsed(io, start);

        if (removed != expected or world.pool(Entity(0)).len() != entity_count - expected)
            return error.InvalidRemovalCount;

        if (sample != 0) timings[sample - 1] = duration;
    }

    const nanoseconds: f64 = @floatFromInt(median(timings));

    std.debug.print("flush/{d}%/{s}: {d:.6} us/flush\n", .{
        percentage, @tagName(method), nanoseconds / repetitions / 1000,
    });
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
}

fn median(values: [sample_count]u64) u64 {
    var sorted = values;
    std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
    return sorted[sample_count / 2];
}
