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
const Traversal = enum { array, storage_columns, things, parts };
const Removal = enum { direct, things, parts };

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
        @sizeOf(shmecs.ThingId),
    });
    std.debug.print("storage_columns uses internal storage directly. Traversal includes iterator setup/teardown; removals include selection, removal, and automatic cleanup. Allocator: page_allocator.\n", .{});

    try benchmarkTraversal(init.io, 1, false);
    try benchmarkTraversal(init.io, 16, false);
    try benchmarkTraversal(init.io, 16, true);
    try benchmarkSpawn(init.io, false);
    try benchmarkSpawn(init.io, true);
    try benchmarkCopy(init.io, false);
    try benchmarkCopy(init.io, true);

    inline for (.{ 0, entity_count / 2, entity_count - 1 }) |row| {
        try benchmarkSingleRemoval(init.io, row);
    }

    inline for (.{ 0, 1, 10, 100 }) |percentage| {
        inline for (comptime std.meta.tags(Removal)) |method| {
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
    var store = shmecs.Store(types).init(allocator);
    defer store.deinit();

    const populated_count = if (with_empty_pools) pool_count / 2 else pool_count;
    var populated_index: usize = 0;

    inline for (types, 0..) |T, pool_index| {
        if (!with_empty_pools or pool_index % 4 == 1 or pool_index % 4 == 2) {
            store.reserve(T, entity_count / populated_count);

            for (0..entity_count / populated_count) |index| {
                _ = store.add(initialEntity(T, populated_index * (entity_count / populated_count) + index));
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
                    resetMotions(types, &store, array);
                    update(method, types, &store, array);

                    const start = std.Io.Clock.awake.now(io);

                    for (0..frame_count) |_| {
                        update(method, types, &store, array);
                    }

                    timings[index][sample] = elapsed(io, start);

                    const result = if (method == .array) checksum(array) else storeChecksum(types, &store);
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

fn resetMotions(comptime types: anytype, store: anytype, array: []Motion) void {
    for (0..array.len) |index| array[index] = initialMotion(index);

    var offset: usize = 0;

    inline for (types, 0..) |_, pool_index| {
        const motion = store.pools[pool_index].components(Motion);

        for (0..motion.len) |index| {
            motion[index] = initialMotion(offset + index);
        }

        offset += motion.len;
    }
}

noinline fn update(comptime method: Traversal, comptime types: anytype, store: anytype, array: []Motion) void {
    switch (method) {
        .array => {
            move(array);
            std.mem.doNotOptimizeAway(array.ptr);
        },
        .storage_columns => {
            inline for (types, 0..) |_, index| move(store.pools[index].components(Motion));
            std.mem.doNotOptimizeAway(store);
        },
        .things => {
            inline for (types) |T| {
                var entities = store.things(T);
                defer entities.deinit();

                while (entities.next()) |entity| {
                    entity.motion.x += entity.motion.velocity_x * delta;
                    entity.motion.y += entity.motion.velocity_y * delta;
                }
            }

            std.mem.doNotOptimizeAway(store);
        },
        .parts => {
            var parts = store.parts(.{ .motion = Motion });
            defer parts.deinit();

            while (parts.next()) |entity| {
                entity.motion.x += entity.motion.velocity_x * delta;
                entity.motion.y += entity.motion.velocity_y * delta;
            }

            std.mem.doNotOptimizeAway(store);
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

fn storeChecksum(comptime types: anytype, store: anytype) f64 {
    var result: f64 = 0;

    inline for (types, 0..) |_, index| result += checksum(store.pools[index].components(Motion));

    return result;
}

fn benchmarkSpawn(io: std.Io, comptime reserved: bool) !void {
    var timings: [sample_count]u64 = undefined;

    for (0..sample_count + 1) |sample| {
        var store = shmecs.Store(.{Entity(0)}).init(allocator);
        defer store.deinit();

        if (reserved) store.reserve(Entity(0), entity_count);

        const start = std.Io.Clock.awake.now(io);

        for (0..entity_count) |index| {
            _ = store.add(initialEntity(Entity(0), index));
        }

        std.mem.doNotOptimizeAway(&store);
        const duration = elapsed(io, start);

        if (store.count(Entity(0)) != entity_count) return error.InvalidSpawnCount;
        if (sample != 0) timings[sample - 1] = duration;
    }

    const nanoseconds: f64 = @floatFromInt(median(timings));

    std.debug.print("spawn/{s}: {d:.3} ns/entity, {d:.3} ms/batch\n", .{
        if (reserved) "reserved (reserve excluded)" else "automatic growth",
        nanoseconds / entity_count,
        nanoseconds / 1_000_000,
    });
}

fn benchmarkCopy(io: std.Io, comptime growing: bool) !void {
    const history_count = 8;
    const copy_count = 32;
    const added_per_copy = 512;
    const initial_count = if (growing) entity_count - copy_count * added_per_copy else entity_count;
    const GameStore = shmecs.Store(.{Entity(0)});
    var timings: [sample_count]u64 = undefined;

    for (0..sample_count + 1) |sample| {
        var store = GameStore.init(allocator);
        defer store.deinit();
        store.reserve(Entity(0), entity_count);

        for (0..initial_count) |index| {
            _ = store.add(initialEntity(Entity(0), index));
        }

        var history: [history_count]GameStore = undefined;

        for (0..history.len) |index| {
            history[index] = GameStore.init(allocator);
            history[index].copyFrom(&store);
        }

        defer for (0..history.len) |index| history[index].deinit();

        var duration: u64 = 0;

        for (0..copy_count) |frame| {
            if (growing) {
                const first = store.count(Entity(0));

                for (first..first + added_per_copy) |index| {
                    _ = store.add(initialEntity(Entity(0), index));
                }
            }

            const snapshot = &history[frame % history.len];
            const start = std.Io.Clock.awake.now(io);
            snapshot.copyFrom(&store);
            std.mem.doNotOptimizeAway(snapshot);
            duration += elapsed(io, start);
        }

        const last = &history[(copy_count - 1) % history.len];

        if (last.count(Entity(0)) != entity_count) return error.InvalidCopyCount;
        if (storeChecksum(.{Entity(0)}, last) != storeChecksum(.{Entity(0)}, &store))
            return error.InvalidCopyChecksum;

        if (sample != 0) timings[sample - 1] = duration;
    }

    const nanoseconds: f64 = @floatFromInt(median(timings));

    std.debug.print("copy/{s}/{d} history slots: {d:.3} us/copy\n", .{
        if (growing) "growing" else "stable", history_count, nanoseconds / copy_count / 1000,
    });
}

fn benchmarkSingleRemoval(io: std.Io, comptime row: usize) !void {
    const repetitions = 256;
    var timings: [sample_count]u64 = undefined;

    for (0..sample_count + 1) |sample| {
        var store = shmecs.Store(.{Entity(0)}).init(allocator);
        defer store.deinit();
        store.reserve(Entity(0), entity_count);

        for (0..entity_count) |index| {
            _ = store.add(initialEntity(Entity(0), index));
        }

        var duration: u64 = 0;

        for (0..repetitions) |_| {
            const storage = &store.pools[0];
            const slot = storage.dense_to_slot[row];
            const removed = shmecs.ThingId{
                .pool = storage.pool_index,
                .slot = slot,
                .generation = storage.slots[slot].generation,
            };

            var things = store.things(Entity(0));
            defer things.deinit();
            store.remove(removed);

            const start = std.Io.Clock.awake.now(io);
            things.deinit();
            std.mem.doNotOptimizeAway(&store);
            duration += elapsed(io, start);

            if (store.count(Entity(0)) != entity_count - 1) return error.InvalidRemovalCount;
            if (store.get(Entity(0), removed) != null) return error.RemovedEntityStillVisible;

            _ = store.add(initialEntity(Entity(0), entity_count - 1));
        }

        if (sample != 0) timings[sample - 1] = duration;
    }

    const nanoseconds: f64 = @floatFromInt(median(timings));

    std.debug.print("cleanup/one/row {d}: {d:.3} us/cleanup (marking excluded)\n", .{
        row, nanoseconds / repetitions / 1000,
    });
}

fn benchmarkRemovals(io: std.Io, comptime percentage: usize, comptime method: Removal) !void {
    const ids = try allocator.alloc(shmecs.ThingId, entity_count);
    defer allocator.free(ids);

    var timings: [sample_count]u64 = undefined;
    var expected: usize = 0;

    for (0..entity_count) |index| {
        if (index % 100 < percentage) expected += 1;
    }

    for (0..sample_count + 1) |sample| {
        var store = shmecs.Store(.{Entity(0)}).init(allocator);
        defer store.deinit();

        store.reserve(Entity(0), entity_count);

        for (0..entity_count) |index| {
            ids[index] = store.add(initialEntity(Entity(0), index));
        }

        const start = std.Io.Clock.awake.now(io);

        switch (method) {
            .direct => {
                for (0..ids.len) |index| {
                    if (index % 100 < percentage) store.remove(ids[index]);
                }
            },
            .things => {
                var entities = store.things(Entity(0));
                defer entities.deinit();
                var index: usize = 0;

                while (entities.next()) |_| {
                    if (index % 100 < percentage) store.remove(entities.thingId());

                    index += 1;
                }
            },
            .parts => {
                var parts = store.parts(.{ .motion = Motion, .health = Health });
                defer parts.deinit();
                var index: usize = 0;

                while (parts.next()) |_| {
                    if (index % 100 < percentage) store.remove(parts.thingId());

                    index += 1;
                }
            },
        }

        std.mem.doNotOptimizeAway(&store);
        const duration = elapsed(io, start);

        if (store.count(Entity(0)) != entity_count - expected) return error.InvalidRemovalCount;

        for (0..ids.len) |index| {
            const entity = store.get(Entity(0), ids[index]);

            if (index % 100 < percentage) {
                if (entity != null) return error.RemovedEntityStillVisible;
            } else {
                const survivor = entity orelse return error.MissingSurvivor;

                if (survivor.motion.x != initialMotion(index).x or survivor.health.current != 100)
                    return error.InvalidSurvivorComponents;
            }
        }

        if (sample != 0) timings[sample - 1] = duration;
    }

    const nanoseconds: f64 = @floatFromInt(median(timings));

    std.debug.print("remove/{d}%/{s}: {d:.3} us/batch\n", .{
        percentage, @tagName(method), nanoseconds / 1000,
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
