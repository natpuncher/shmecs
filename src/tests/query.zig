const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const EntityId = @import("../entity_id.zig").EntityId;

test "named query visits all matching entities in pool order and mutates original data" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const first = try world.add(fixtures.plane(10));
    const second = try world.add(fixtures.plane(20));
    const third = try world.add(fixtures.building(30));
    const bullet = try world.add(fixtures.bullet(40));

    const expected_ids = [_]EntityId{ first, second, third };
    const expected_values = [_]f32{ 10, 20, 30 };

    var query = world.query(.{ .hp = fixtures.Health });
    defer query.deinit();

    var count: usize = 0;

    while (query.next()) |components| {
        try testing.expect(count < expected_ids.len);

        const id = query.id() orelse return error.MissingId;

        try testing.expectEqualDeep(expected_ids[count], id);
        try testing.expectEqual(expected_values[count], components.hp.current);

        components.hp.current += 5;
        count += 1;
    }

    try testing.expectEqual(3, count);

    const expected_after = [_]f32{ 15, 25, 35 };

    const healths = [_]*fixtures.Health{
        (world.get(fixtures.Plane, first) orelse return error.MissingEntity).health,
        (world.get(fixtures.Plane, second) orelse return error.MissingEntity).health,
        (world.get(fixtures.Building, third) orelse return error.MissingEntity).durability,
    };

    for (healths, 0..) |health, index| {
        try testing.expectEqual(expected_after[index], health.current);
    }

    const motion = (world.get(fixtures.Bullet, bullet) orelse return error.MissingEntity).movement;

    try testing.expectEqual(40, motion.x);
}

test "multi component query joins fields of one entity and requires every requested type" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const plane = try world.add(fixtures.plane(40));
    const building = try world.add(fixtures.building(80));
    const bullet = try world.add(fixtures.bullet(90));

    var query = world.query(.{
        .movement = fixtures.Motion,
        .durability = fixtures.Health,
        .gun = fixtures.Weapon,
    });
    defer query.deinit();

    const components = query.next() orelse return error.MissingEntity;

    try testing.expectEqualDeep(plane, query.id() orelse return error.MissingId);

    components.durability.current = 7;
    components.movement.x = 8;
    components.gun.ammunition = 3;

    try testing.expect(query.next() == null);

    const health = (world.get(fixtures.Plane, plane) orelse return error.MissingEntity).health;
    const motion = (world.get(fixtures.Plane, plane) orelse return error.MissingEntity).motion;
    const weapon = (world.get(fixtures.Plane, plane) orelse return error.MissingEntity).weapon;

    try testing.expectEqual(7, health.current);
    try testing.expectEqual(8, motion.x);
    try testing.expectEqual(3, weapon.ammunition);

    const untouched_health = (world.get(fixtures.Building, building) orelse return error.MissingEntity).durability;
    const untouched_motion = (world.get(fixtures.Bullet, bullet) orelse return error.MissingEntity).movement;

    try testing.expectEqual(80, untouched_health.current);
    try testing.expectEqual(90, untouched_motion.x);
}

test "query skips empty matching pools before and after populated pools" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const building = try world.add(fixtures.building(55));

    var query = world.query(.{ .health = fixtures.Health });
    defer query.deinit();

    const row = query.next() orelse return error.MissingEntity;

    try testing.expectEqual(55, row.health.current);
    try testing.expectEqualDeep(building, query.id() orelse return error.MissingId);
    try testing.expect(query.next() == null);
    try testing.expect(query.next() == null);
}

test "empty world queries finish without a current entity" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    var query = world.query(.{ .motion = fixtures.Motion });
    defer query.deinit();

    try testing.expect(query.id() == null);
    try testing.expectError(error.NoCurrentEntity, query.markForRemoval());
    try testing.expect(query.next() == null);
    try testing.expect(query.next() == null);
    try testing.expect(query.id() == null);
    try testing.expectError(error.NoCurrentEntity, query.markForRemoval());
}

test "query for an absent component neither yields entities nor locks unrelated pools" {
    const Missing = struct { number: i64 };
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.add(fixtures.plane(10));

    var query = world.query(.{ .missing = Missing });
    defer query.deinit();

    try testing.expect(query.next() == null);

    _ = try world.add(fixtures.plane(20));

    try testing.expectEqual(2, world.pool(fixtures.Plane).len());
    try testing.expectError(error.NoCurrentEntity, query.markForRemoval());
}

test "current entity is cleared before iteration after exhaustion and after closing" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const first = try world.add(fixtures.plane(10));
    const second = try world.add(fixtures.plane(20));

    var query = world.query(.{ .hp = fixtures.Health });
    defer query.deinit();

    try testing.expect(query.id() == null);
    try testing.expectError(error.NoCurrentEntity, query.markForRemoval());

    _ = query.next() orelse return error.MissingEntity;

    try testing.expectEqualDeep(first, query.id() orelse return error.MissingId);

    _ = query.next() orelse return error.MissingEntity;

    try testing.expectEqualDeep(second, query.id() orelse return error.MissingId);
    try testing.expect(query.next() == null);
    try testing.expect(query.id() == null);
    try testing.expectError(error.NoCurrentEntity, query.markForRemoval());

    query.deinit();

    try testing.expect(query.next() == null);
    try testing.expect(query.id() == null);
    try testing.expectError(error.NoCurrentEntity, query.markForRemoval());
}

test "active queries block structural changes only in matching pools" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const plane = try world.add(fixtures.plane(10));

    var query = world.query(.{ .weapon = fixtures.Weapon });
    defer query.deinit();

    try testing.expectError(error.PoolInUse, world.add(fixtures.plane(20)));
    try testing.expectError(error.PoolInUse, world.pool(fixtures.Plane).reserve(128));
    try testing.expectError(error.PoolInUse, world.remove(plane));
    try testing.expectError(error.PoolInUse, world.pool(fixtures.Plane).storage.flushRemovals());
    try testing.expectError(error.PoolInUse, world.flushRemovals());

    const building = try world.add(fixtures.building(30));

    try world.remove(building);
    _ = query.next() orelse return error.MissingEntity;
    try query.markForRemoval();

    query.deinit();

    try testing.expectEqual(1, try world.flushRemovals());
    try testing.expect(world.get(fixtures.Plane, plane) == null);
}

test "queries lock matching empty pools before the first insertion" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    var query = world.query(.{ .health = fixtures.Health });
    defer query.deinit();

    try testing.expectError(error.PoolInUse, world.add(fixtures.plane(10)));
    try testing.expectError(error.PoolInUse, world.add(fixtures.building(20)));

    _ = try world.add(fixtures.bullet(30));

    query.deinit();

    _ = try world.add(fixtures.plane(10));
    _ = try world.add(fixtures.building(20));
}

test "nested queries retain shared pool locks until the last query closes" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.add(fixtures.plane(10));

    var health = world.query(.{ .health = fixtures.Health });
    defer health.deinit();

    var motion = world.query(.{ .motion = fixtures.Motion });
    defer motion.deinit();

    health.deinit();
    health.deinit();

    _ = try world.add(fixtures.building(20));

    try testing.expectError(error.PoolInUse, world.add(fixtures.plane(30)));

    motion.deinit();

    _ = try world.add(fixtures.plane(30));

    try testing.expectEqual(2, world.pool(fixtures.Plane).len());
}

test "exhaustion retains locks while closing an unfinished query releases them" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.add(fixtures.plane(10));

    var query = world.query(.{ .weapon = fixtures.Weapon });
    defer query.deinit();

    while (query.next()) |_| {}

    try testing.expectError(error.PoolInUse, world.add(fixtures.plane(20)));

    query.deinit();

    _ = try world.add(fixtures.plane(20));

    var unfinished = world.query(.{ .weapon = fixtures.Weapon });
    defer unfinished.deinit();

    _ = unfinished.next() orelse return error.MissingEntity;

    unfinished.deinit();

    try testing.expect(unfinished.next() == null);

    _ = try world.add(fixtures.plane(30));

    try testing.expectEqual(3, world.pool(fixtures.Plane).len());
}

test "independent query cursors preserve earlier pointers and observe shared mutations" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.add(fixtures.plane(10));
    _ = try world.add(fixtures.plane(20));

    var first = world.query(.{ .health = fixtures.Health });
    defer first.deinit();

    var second = world.query(.{ .hp = fixtures.Health });
    defer second.deinit();

    const first_row = first.next() orelse return error.MissingEntity;
    first_row.health.current = 11;

    const second_row = second.next() orelse return error.MissingEntity;

    try testing.expectEqual(11, second_row.hp.current);

    const next_first = first.next() orelse return error.MissingEntity;

    try testing.expectEqual(20, next_first.health.current);

    first_row.health.current = 12;

    try testing.expectEqual(12, second_row.hp.current);

    const next_second = second.next() orelse return error.MissingEntity;
    next_second.hp.current = 22;

    try testing.expectEqual(22, next_first.health.current);
}

test "query creation iteration IDs and marking require no allocations" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var world = fixtures.GameWorld.init(failing.allocator());
    defer world.deinit();

    const plane = try world.add(fixtures.plane(10));
    const building = try world.add(fixtures.building(20));
    failing.fail_index = failing.alloc_index;

    var query = world.query(.{ .hp = fixtures.Health });
    defer query.deinit();

    var count: usize = 0;

    while (query.next()) |_| {
        try testing.expect(query.id() != null);

        try query.markForRemoval();
        count += 1;
    }

    try testing.expectEqual(2, count);

    query.deinit();

    try testing.expectEqual(2, try world.flushRemovals());
    try testing.expect(world.get(fixtures.Plane, plane) == null);
    try testing.expect(world.get(fixtures.Building, building) == null);
}

test "marking the current entity twice neither skips rows nor deletes survivors" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const first = try world.add(fixtures.plane(0));
    const survivor = try world.add(fixtures.plane(10));
    const last = try world.add(fixtures.plane(-1));

    var query = world.query(.{ .health = fixtures.Health });
    defer query.deinit();

    var count: usize = 0;

    while (query.next()) |components| {
        if (components.health.current <= 0) {
            try query.markForRemoval();
            try query.markForRemoval();
        }

        count += 1;
    }

    try testing.expectEqual(3, count);

    query.deinit();

    try testing.expectEqual(2, try world.flushRemovals());
    try testing.expect(world.get(fixtures.Plane, first) == null);
    try testing.expect(world.get(fixtures.Plane, last) == null);

    const health = (world.get(fixtures.Plane, survivor) orelse return error.MissingEntity).health;

    try testing.expectEqual(10, health.current);
}

test "query aliases can use names also used by iterator methods" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.add(fixtures.plane(10));

    var query = world.query(.{ .id = fixtures.Health, .next = fixtures.Motion });
    defer query.deinit();

    const components = query.next() orelse return error.MissingEntity;
    components.id.current = 15;
    components.next.x = 25;

    try testing.expect(query.id() != null);
    try testing.expectEqual(15, world.pool(fixtures.Plane).components(fixtures.Health)[0].current);
    try testing.expectEqual(25, world.pool(fixtures.Plane).components(fixtures.Motion)[0].x);
}
