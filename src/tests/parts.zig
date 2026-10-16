const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const EntityId = @import("../entity_id.zig").EntityId;

test "automatic removal hides pending rows before iterator cleanup" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const removed = world.add(fixtures.plane(10));
    const survivor = world.add(fixtures.plane(20));
    var holder = world.pool(fixtures.Plane).iterator();
    defer holder.deinit();

    _ = holder.next() orelse return error.MissingEntity;
    world.remove(holder.entityId());

    try testing.expect(world.get(fixtures.Plane, removed) == null);
    try testing.expectEqual(2, world.pool(fixtures.Plane).len());

    var query = world.query(.{ .hp = fixtures.Health });
    defer query.deinit();

    const row = query.next() orelse return error.MissingEntity;

    try testing.expectEqual(20, row.hp.current);
    try testing.expectEqualDeep(survivor, query.entityId());
    try testing.expect(query.next() == null);
    try testing.expectEqual(2, world.pool(fixtures.Plane).len());

    holder.deinit();

    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
    try testing.expect(world.get(fixtures.Plane, survivor) != null);
}

test "automatic removal cleans up when an unfinished iterator closes" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const removed = world.add(fixtures.plane(10));
    _ = world.add(fixtures.plane(20));
    var iterator = world.pool(fixtures.Plane).iterator();
    defer iterator.deinit();

    _ = iterator.next() orelse return error.MissingEntity;
    world.remove(iterator.entityId());
    iterator.deinit();
    iterator.deinit();

    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
    try testing.expect(world.get(fixtures.Plane, removed) == null);
}

test "named query visits all matching entities in pool order and mutates original data" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const first = world.add(fixtures.plane(10));
    const second = world.add(fixtures.plane(20));
    const third = world.add(fixtures.building(30));
    const bullet = world.add(fixtures.bullet(40));

    const expected_ids = [_]EntityId{ first, second, third };
    const expected_values = [_]f32{ 10, 20, 30 };

    var query = world.query(.{ .hp = fixtures.Health });
    defer query.deinit();

    var count: usize = 0;

    while (query.next()) |components| {
        try testing.expect(count < expected_ids.len);

        const id = query.entityId();

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

    const plane = world.add(fixtures.plane(40));
    const building = world.add(fixtures.building(80));
    const bullet = world.add(fixtures.bullet(90));

    var query = world.query(.{
        .movement = fixtures.Motion,
        .durability = fixtures.Health,
        .gun = fixtures.Weapon,
    });
    defer query.deinit();

    const components = query.next() orelse return error.MissingEntity;

    try testing.expectEqualDeep(plane, query.entityId());

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

    const building = world.add(fixtures.building(55));

    var query = world.query(.{ .health = fixtures.Health });
    defer query.deinit();

    const row = query.next() orelse return error.MissingEntity;

    try testing.expectEqual(55, row.health.current);
    try testing.expectEqualDeep(building, query.entityId());
    try testing.expect(query.next() == null);
    try testing.expect(query.next() == null);
}

test "empty world queries finish and release matching pools" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    var query = world.query(.{ .motion = fixtures.Motion });
    defer query.deinit();

    try testing.expect(query.next() == null);
    try testing.expect(query.next() == null);

    _ = world.add(fixtures.plane(10));
    _ = world.add(fixtures.bullet(20));

    try testing.expect(query.next() == null);
    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
    try testing.expectEqual(1, world.pool(fixtures.Bullet).len());
}

test "query for an absent component neither yields entities nor locks unrelated pools" {
    const Missing = struct { number: i64 };
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    _ = world.add(fixtures.plane(10));

    var query = world.query(.{ .missing = Missing });
    defer query.deinit();

    try testing.expect(query.next() == null);

    _ = world.add(fixtures.plane(20));

    try testing.expectEqual(2, world.pool(fixtures.Plane).len());
}

test "entity IDs follow yielded rows and a finished query remains closed" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const first = world.add(fixtures.plane(10));
    const second = world.add(fixtures.plane(20));
    var query = world.query(.{ .hp = fixtures.Health });
    defer query.deinit();

    _ = query.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(first, query.entityId());

    _ = query.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(second, query.entityId());
    try testing.expect(query.next() == null);

    _ = world.add(fixtures.plane(30));
    query.deinit();

    try testing.expect(query.next() == null);
    try testing.expectEqual(3, world.pool(fixtures.Plane).len());
}

test "active queries defer removal only in matching pools" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const plane = world.add(fixtures.plane(10));
    const survivor = world.add(fixtures.plane(20));
    var query = world.query(.{ .weapon = fixtures.Weapon });
    defer query.deinit();

    world.remove(plane);
    world.remove(plane);
    const building = world.add(fixtures.building(30));
    world.remove(building);

    try testing.expectEqual(0, world.pool(fixtures.Building).len());
    try testing.expectEqual(2, world.pool(fixtures.Plane).len());
    try testing.expect(world.get(fixtures.Plane, plane) == null);

    _ = query.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(survivor, query.entityId());
    try testing.expect(query.next() == null);
    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
}

test "closing a query releases matching empty pools for insertion" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    var query = world.query(.{ .health = fixtures.Health });
    defer query.deinit();

    _ = world.add(fixtures.bullet(30));
    query.deinit();

    _ = world.add(fixtures.plane(10));
    _ = world.add(fixtures.building(20));

    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
    try testing.expectEqual(1, world.pool(fixtures.Building).len());
}

test "nested queries clean each pool only after its last cursor closes" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const plane = world.add(fixtures.plane(10));
    const survivor = world.add(fixtures.plane(20));
    const building = world.add(fixtures.building(30));
    var health = world.query(.{ .health = fixtures.Health });
    defer health.deinit();
    var motion = world.query(.{ .motion = fixtures.Motion });
    defer motion.deinit();

    const row = motion.next() orelse return error.MissingEntity;
    world.remove(plane);
    world.remove(building);
    health.deinit();
    health.deinit();

    try testing.expectEqual(0, world.pool(fixtures.Building).len());
    try testing.expectEqual(2, world.pool(fixtures.Plane).len());
    try testing.expectEqual(10, row.motion.x);
    try testing.expect(world.get(fixtures.Plane, plane) == null);

    motion.deinit();

    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
    try testing.expectEqual(20, world.get(fixtures.Plane, survivor).?.motion.x);
}

test "exhaustion and closing an unfinished query both release its pools" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    _ = world.add(fixtures.plane(10));
    var query = world.query(.{ .weapon = fixtures.Weapon });
    defer query.deinit();

    while (query.next()) |_| {}

    _ = world.add(fixtures.plane(20));
    query.deinit();

    var unfinished = world.query(.{ .weapon = fixtures.Weapon });
    defer unfinished.deinit();

    _ = unfinished.next() orelse return error.MissingEntity;
    unfinished.deinit();

    try testing.expect(unfinished.next() == null);

    _ = world.add(fixtures.plane(30));
    try testing.expectEqual(3, world.pool(fixtures.Plane).len());
}

test "independent query cursors preserve earlier pointers and observe shared mutations" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    _ = world.add(fixtures.plane(10));
    _ = world.add(fixtures.plane(20));

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

test "query iteration and automatic removal require no allocations" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var world = fixtures.GameWorld.init(failing.allocator());
    defer world.deinit();

    const plane = world.add(fixtures.plane(10));
    const building = world.add(fixtures.building(20));
    failing.fail_index = failing.alloc_index;

    var query = world.query(.{ .hp = fixtures.Health });
    defer query.deinit();

    var count: usize = 0;

    while (query.next()) |_| {
        const id = query.entityId();
        try testing.expect(world.get(fixtures.Plane, id) != null or world.get(fixtures.Building, id) != null);

        world.remove(query.entityId());
        count += 1;
    }

    try testing.expectEqual(2, count);

    query.deinit();

    try testing.expectEqual(0, world.pool(fixtures.Plane).len() + world.pool(fixtures.Building).len());
    try testing.expect(world.get(fixtures.Plane, plane) == null);
    try testing.expect(world.get(fixtures.Building, building) == null);
}

test "removing the current entity twice neither skips rows nor deletes survivors" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const first = world.add(fixtures.plane(0));
    const survivor = world.add(fixtures.plane(10));
    const last = world.add(fixtures.plane(-1));

    var query = world.query(.{ .health = fixtures.Health });
    defer query.deinit();

    var count: usize = 0;

    while (query.next()) |components| {
        if (components.health.current <= 0) {
            world.remove(query.entityId());
            world.remove(query.entityId());
        }

        count += 1;
    }

    try testing.expectEqual(3, count);

    query.deinit();

    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
    try testing.expect(world.get(fixtures.Plane, first) == null);
    try testing.expect(world.get(fixtures.Plane, last) == null);

    const health = (world.get(fixtures.Plane, survivor) orelse return error.MissingEntity).health;

    try testing.expectEqual(10, health.current);
}

test "query aliases can use names also used by iterator methods" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    _ = world.add(fixtures.plane(10));

    var query = world.query(.{ .entityId = fixtures.Health, .next = fixtures.Motion });
    defer query.deinit();

    const components = query.next() orelse return error.MissingEntity;
    components.entityId.current = 15;
    components.next.x = 25;

    try testing.expect(world.get(fixtures.Plane, query.entityId()) != null);
    try testing.expectEqual(15, world.pool(fixtures.Plane).components(fixtures.Health)[0].current);
    try testing.expectEqual(25, world.pool(fixtures.Plane).components(fixtures.Motion)[0].x);
}

test "a pool iterator skips pending rows and cleans up on exhaustion" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const first = world.add(fixtures.plane(10));
    const skipped = world.add(fixtures.plane(20));
    const last = world.add(fixtures.plane(30));
    var iterator = world.pool(fixtures.Plane).iterator();
    defer iterator.deinit();

    _ = iterator.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(first, iterator.entityId());
    world.remove(skipped);

    const row = iterator.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(last, iterator.entityId());
    try testing.expectEqual(30, row.health.current);
    try testing.expect(iterator.next() == null);
    try testing.expectEqual(2, world.pool(fixtures.Plane).len());

    _ = world.add(fixtures.plane(40));
    iterator.deinit();
    try testing.expectEqual(3, world.pool(fixtures.Plane).len());
}

test "query skips a matching pool whose rows were all removed before visiting" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const plane = world.add(fixtures.plane(10));
    const building = world.add(fixtures.building(20));
    var query = world.query(.{ .hp = fixtures.Health });
    defer query.deinit();

    world.remove(plane);
    world.remove(building);

    try testing.expect(query.next() == null);
    try testing.expectEqual(0, world.pool(fixtures.Plane).len());
    try testing.expectEqual(0, world.pool(fixtures.Building).len());
}

test "breaking an iteration cleans up at the enclosing scope boundary" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const removed = world.add(fixtures.plane(10));
    _ = world.add(fixtures.plane(20));

    {
        var query = world.query(.{ .hp = fixtures.Health });
        defer query.deinit();

        while (query.next()) |_| {
            world.remove(query.entityId());
            break;
        }

        try testing.expectEqual(2, world.pool(fixtures.Plane).len());
        try testing.expect(world.get(fixtures.Plane, removed) == null);
    }

    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
}

test "an error return releases a query and applies pending removal" {
    const Operation = struct {
        fn run(world: *fixtures.GameWorld) !void {
            var query = world.query(.{ .hp = fixtures.Health });
            defer query.deinit();

            _ = query.next() orelse return error.MissingEntity;
            world.remove(query.entityId());
            return error.ExpectedExit;
        }
    };

    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();
    const removed = world.add(fixtures.plane(10));

    try testing.expectError(error.ExpectedExit, Operation.run(&world));
    try testing.expect(world.get(fixtures.Plane, removed) == null);
    try testing.expectEqual(0, world.pool(fixtures.Plane).len());

    _ = world.add(fixtures.plane(20));
    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
}

test "exhausting an inner query preserves the outer cursor until it finishes" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const removed = world.add(fixtures.plane(10));
    const survivor = world.add(fixtures.plane(20));
    var outer = world.query(.{ .hp = fixtures.Health });
    defer outer.deinit();
    const row = outer.next() orelse return error.MissingEntity;

    var inner = world.query(.{ .motion = fixtures.Motion });
    defer inner.deinit();

    _ = inner.next() orelse return error.MissingEntity;
    world.remove(inner.entityId());

    _ = inner.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(survivor, inner.entityId());
    try testing.expect(inner.next() == null);
    try testing.expectEqual(2, world.pool(fixtures.Plane).len());
    try testing.expectEqual(10, row.hp.current);
    try testing.expectEqualDeep(removed, outer.entityId());

    const next = outer.next() orelse return error.MissingEntity;
    try testing.expectEqual(20, next.hp.current);
    try testing.expectEqualDeep(survivor, outer.entityId());
    try testing.expect(outer.next() == null);
    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
}
