const std = @import("std");
const testing = std.testing;
const PoolStorage = @import("../pool_storage.zig").PoolStorage;
const EntityId = @import("../entity_id.zig").EntityId;
const fixtures = @import("fixtures.zig");

test "pool preserves component values and IDs across automatic growth" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    var ids: [96]EntityId = undefined;

    for (0..ids.len) |index| {
        const value: f32 = @floatFromInt(index);
        ids[index] = try pool.append(fixtures.plane(value));
    }

    try testing.expectEqual(96, pool.len);

    for (0..ids.len) |index| {
        const row = pool.indexOf(ids[index]) orelse return error.MissingEntity;
        const value: f32 = @floatFromInt(index);
        const entity = fixtures.planeAt(&pool, row) orelse return error.MissingEntity;

        try testing.expectEqualDeep(fixtures.plane(value), entity);
    }
}

test "pool stores components in contiguous mutable columns" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    _ = try pool.append(fixtures.plane(10));
    const second = try pool.append(fixtures.plane(20));
    const health = pool.components(fixtures.Health);

    try testing.expectEqual(@sizeOf(fixtures.Health), @intFromPtr(&health[1]) - @intFromPtr(&health[0]));

    health[1].current = 7;
    const row = pool.indexOf(second) orelse return error.MissingEntity;
    const entity = fixtures.planeAt(&pool, row) orelse return error.MissingEntity;

    try testing.expectEqual(7, entity.health.current);
    try testing.expectEqual(20, entity.motion.x);
}

test "pool removal moves every component and preserves the moved ID" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    const first = try pool.append(fixtures.plane(10));
    const middle = try pool.append(fixtures.plane(20));

    var last_entity = fixtures.plane(30);
    last_entity.weapon.ammunition = 42;
    const last = try pool.append(last_entity);

    try pool.remove(middle);

    try testing.expect(pool.indexOf(middle) == null);
    try testing.expectEqual(2, pool.len);

    const moved_row = pool.indexOf(last) orelse return error.MissingEntity;
    const moved = fixtures.planeAt(&pool, moved_row) orelse return error.MissingEntity;

    try testing.expectEqualDeep(last_entity, moved);

    const first_row = pool.indexOf(first) orelse return error.MissingEntity;
    const unchanged = fixtures.planeAt(&pool, first_row) orelse return error.MissingEntity;

    try testing.expectEqualDeep(fixtures.plane(10), unchanged);
}

test "pool rejects stale IDs after slot reuse and repeated deletion" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    const old = try pool.append(fixtures.plane(10));

    try pool.remove(old);

    try testing.expectError(error.InvalidEntity, pool.remove(old));

    const replacement = try pool.append(fixtures.plane(90));

    try testing.expectEqual(old.slot, replacement.slot);
    try testing.expect(old.generation != replacement.generation);
    try testing.expect(pool.indexOf(old) == null);
    try testing.expectError(error.InvalidEntity, pool.remove(old));

    const row = pool.indexOf(replacement) orelse return error.MissingEntity;
    const entity = fixtures.planeAt(&pool, row) orelse return error.MissingEntity;

    try testing.expectEqual(90, entity.health.current);
}

test "pool rejects invalid pool slot and generation without changing data" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    const valid = try pool.append(fixtures.plane(10));
    const invalid = [_]EntityId{
        .{ .pool = valid.pool + 1, .slot = valid.slot, .generation = valid.generation },
        .{ .pool = valid.pool, .slot = std.math.maxInt(usize), .generation = valid.generation },
        .{ .pool = valid.pool, .slot = valid.slot, .generation = valid.generation + 1 },
    };

    for (0..invalid.len) |index| {
        try testing.expect(pool.indexOf(invalid[index]) == null);
        try testing.expectError(error.InvalidEntity, pool.remove(invalid[index]));
    }

    try testing.expectEqual(1, pool.len);
    try testing.expect(pool.indexOf(valid) != null);
}

test "pool removes first last and moved entities until empty" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    const ids = [_]EntityId{
        try pool.append(fixtures.plane(10)),
        try pool.append(fixtures.plane(20)),
        try pool.append(fixtures.plane(30)),
        try pool.append(fixtures.plane(40)),
    };

    const order = [_]usize{ 0, 2, 3, 1 };

    for (0..order.len) |step| {
        try pool.remove(ids[order[step]]);

        try testing.expect(pool.indexOf(ids[order[step]]) == null);
        try testing.expectEqual(order.len - step - 1, pool.len);

        for (step + 1..order.len) |remaining| {
            try testing.expect(pool.indexOf(ids[order[remaining]]) != null);
        }
    }

    try testing.expectEqual(0, pool.components(fixtures.Health).len);
    try testing.expect(fixtures.planeAt(&pool, 0) == null);
}

test "pool growth preserves pending removals and reused generations" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    const first = try pool.append(fixtures.plane(10));
    const removed = try pool.append(fixtures.plane(20));
    const survivor = try pool.append(fixtures.plane(30));

    try pool.remove(removed);
    const replacement = try pool.append(fixtures.plane(40));
    const row = pool.indexOf(first) orelse return error.MissingEntity;

    try fixtures.markAt(&pool, row);
    try pool.reserve(128);

    try testing.expectEqual(3, pool.len);
    try testing.expectEqual(1, try pool.flushRemovals());
    try testing.expect(pool.indexOf(first) == null);
    try testing.expect(pool.indexOf(removed) == null);
    try testing.expect(pool.indexOf(survivor) != null);
    try testing.expect(pool.indexOf(replacement) != null);
}

test "pending removal follows an entity moved by immediate removal" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    const first = try pool.append(fixtures.plane(10));
    const survivor = try pool.append(fixtures.plane(20));
    const pending = try pool.append(fixtures.plane(30));

    try fixtures.markAt(&pool, 2);
    try pool.remove(first);

    try testing.expectEqual(1, try pool.flushRemovals());
    try testing.expect(pool.indexOf(pending) == null);
    try testing.expect(pool.indexOf(survivor) != null);
    try testing.expectEqual(1, pool.len);
}

test "deferred removal handles adjacent marks and the last row exactly once" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    var ids: [5]EntityId = undefined;

    for (0..ids.len) |index| {
        const value: f32 = @floatFromInt(index);
        ids[index] = try pool.append(fixtures.plane(value));
    }

    try fixtures.markAt(&pool, 1);
    try fixtures.markAt(&pool, 1);
    try fixtures.markAt(&pool, 2);
    try fixtures.markAt(&pool, 4);

    try testing.expectEqual(3, try pool.flushRemovals());
    try testing.expectEqual(0, try pool.flushRemovals());
    try testing.expect(pool.indexOf(ids[0]) != null);
    try testing.expect(pool.indexOf(ids[3]) != null);
    try testing.expect(pool.indexOf(ids[1]) == null);
    try testing.expect(pool.indexOf(ids[2]) == null);
    try testing.expect(pool.indexOf(ids[4]) == null);
}

test "failed reserve preserves IDs values and pending removals" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var pool = PoolStorage(fixtures.Plane).init(failing.allocator());
    defer pool.deinit();

    const pending = try pool.append(fixtures.plane(10));
    const survivor = try pool.append(fixtures.plane(20));

    try fixtures.markAt(&pool, 0);

    try testing.expectError(error.OutOfMemory, pool.reserve(128));
    try testing.expectEqual(2, pool.len);

    const entity = fixtures.planeAt(&pool, 1) orelse return error.MissingEntity;

    try testing.expectEqualDeep(fixtures.plane(20), entity);
    try testing.expectEqual(1, try pool.flushRemovals());
    try testing.expect(pool.indexOf(pending) == null);
    try testing.expect(pool.indexOf(survivor) != null);
}

test "failed append preserves the pool and permits a later successful append" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var pool = PoolStorage(fixtures.Plane).init(failing.allocator());
    defer pool.deinit();

    try pool.reserve(2);
    const first = try pool.append(fixtures.plane(10));
    const second = try pool.append(fixtures.plane(20));

    try testing.expectError(error.OutOfMemory, pool.append(fixtures.plane(30)));
    try testing.expectEqual(2, pool.len);
    try testing.expect(pool.indexOf(first) != null);
    try testing.expect(pool.indexOf(second) != null);

    failing.fail_index = std.math.maxInt(usize);
    const third = try pool.append(fixtures.plane(30));

    try testing.expectEqual(3, pool.len);

    const row = pool.indexOf(third) orelse return error.MissingEntity;
    const entity = fixtures.planeAt(&pool, row) orelse return error.MissingEntity;

    try testing.expectEqualDeep(fixtures.plane(30), entity);
}

test "capacity overflow fails without damaging existing entities" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    const id = try pool.append(fixtures.plane(10));

    try testing.expectError(error.OutOfMemory, pool.reserve(std.math.maxInt(usize)));
    try testing.expectEqual(1, pool.len);
    try testing.expect(pool.indexOf(id) != null);

    const entity = fixtures.planeAt(&pool, 0) orelse return error.MissingEntity;

    try testing.expectEqualDeep(fixtures.plane(10), entity);
}

test "zero sized components survive growth removal and slot reuse" {
    const Tag = struct {};
    const Value = struct { number: u32 };
    const Entity = struct { tag: Tag, value: Value };

    var pool = PoolStorage(Entity).init(testing.allocator);
    defer pool.deinit();

    const first = try pool.append(.{ .tag = .{}, .value = .{ .number = 11 } });
    const second = try pool.append(.{ .tag = .{}, .value = .{ .number = 22 } });

    try pool.reserve(33);
    try pool.remove(first);
    const replacement = try pool.append(.{ .tag = .{}, .value = .{ .number = 33 } });

    try testing.expectEqual(2, pool.components(Tag).len);

    const second_row = pool.indexOf(second) orelse return error.MissingEntity;

    try testing.expectEqual(22, pool.components(Value)[second_row].number);
    try testing.expect(pool.indexOf(replacement) != null);
    try testing.expect(pool.indexOf(first) == null);
}

test "empty entities still support stable IDs and deletion" {
    const Empty = struct {};

    var pool = PoolStorage(Empty).init(testing.allocator);
    defer pool.deinit();

    const first = try pool.append(.{});
    const second = try pool.append(.{});

    try pool.remove(first);
    try pool.reserve(17);

    try testing.expectEqual(1, pool.len);
    try testing.expect(pool.indexOf(first) == null);
    try testing.expect(pool.indexOf(second) != null);

    var iterator = pool.iterator();
    defer iterator.deinit();

    try testing.expect(iterator.next() != null);
    try testing.expect(iterator.next() == null);
}

test "overaligned columns retain alignment and values after relocation" {
    const Large = struct { bytes: [64]u8 align(64) };
    const Small = struct { number: u8 };
    const Counter = struct { number: u64 };
    const Entity = struct { small: Small, large: Large, counter: Counter };

    var pool = PoolStorage(Entity).init(testing.allocator);
    defer pool.deinit();

    try pool.reserve(3);
    const first = try pool.append(.{
        .small = .{ .number = 1 },
        .large = .{ .bytes = @splat(7) },
        .counter = .{ .number = 100 },
    });
    const second = try pool.append(.{
        .small = .{ .number = 2 },
        .large = .{ .bytes = @splat(9) },
        .counter = .{ .number = 200 },
    });

    try testing.expectEqual(0, @intFromPtr(pool.components(Large).ptr) % 64);

    try pool.reserve(19);
    try pool.remove(first);
    const row = pool.indexOf(second) orelse return error.MissingEntity;

    try testing.expectEqual(0, @intFromPtr(pool.components(Large).ptr) % 64);
    try testing.expectEqual(2, pool.components(Small)[row].number);
    try testing.expectEqual(200, pool.components(Counter)[row].number);

    for (0..64) |index| try testing.expectEqual(9, pool.components(Large)[row].bytes[index]);
}

test "exhausted generations retire slots instead of reviving stale IDs" {
    var pool = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer pool.deinit();

    try pool.reserve(1);
    var last_generation = try pool.append(fixtures.plane(10));
    pool.slots[last_generation.slot].generation = std.math.maxInt(u64);
    last_generation.generation = std.math.maxInt(u64);

    try pool.remove(last_generation);

    const replacement = try pool.append(fixtures.plane(20));

    try testing.expect(last_generation.slot != replacement.slot);
    try testing.expect(pool.indexOf(last_generation) == null);
    try testing.expectError(error.InvalidEntity, pool.remove(last_generation));
    try testing.expect(pool.indexOf(replacement) != null);
}
