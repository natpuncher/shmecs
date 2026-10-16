const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const ThingId = @import("../thing_id.zig").ThingId;

test "automatic removal hides pending rows before iterator cleanup" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const removed = store.add(fixtures.plane(10));
    const survivor = store.add(fixtures.plane(20));
    var holder = store.things(fixtures.Plane);
    defer holder.deinit();

    _ = holder.next() orelse return error.MissingEntity;
    store.remove(holder.thingId());

    try testing.expect(store.get(fixtures.Plane, removed) == null);
    try testing.expectEqual(1, store.count(fixtures.Plane));

    var parts = store.parts(.{ .hp = fixtures.Health });
    defer parts.deinit();

    const row = parts.next() orelse return error.MissingEntity;

    try testing.expectEqual(20, row.hp.current);
    try testing.expectEqualDeep(survivor, parts.thingId());
    try testing.expect(parts.next() == null);
    try testing.expectEqual(1, store.count(fixtures.Plane));

    holder.deinit();

    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expect(store.get(fixtures.Plane, survivor) != null);
}

test "parts iteration visits matching things in type order and mutates original data" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const first = store.add(fixtures.plane(10));
    const second = store.add(fixtures.plane(20));
    const third = store.add(fixtures.building(30));
    const bullet = store.add(fixtures.bullet(40));

    const expected_ids = [_]ThingId{ first, second, third };
    const expected_values = [_]f32{ 10, 20, 30 };

    var parts = store.parts(.{ .hp = fixtures.Health });
    defer parts.deinit();

    var count: usize = 0;

    while (parts.next()) |components| {
        try testing.expect(count < expected_ids.len);

        const id = parts.thingId();

        try testing.expectEqualDeep(expected_ids[count], id);
        try testing.expectEqual(expected_values[count], components.hp.current);

        components.hp.current += 5;
        count += 1;
    }

    try testing.expectEqual(3, count);

    const expected_after = [_]f32{ 15, 25, 35 };

    const healths = [_]*fixtures.Health{
        (store.get(fixtures.Plane, first) orelse return error.MissingEntity).health,
        (store.get(fixtures.Plane, second) orelse return error.MissingEntity).health,
        (store.get(fixtures.Building, third) orelse return error.MissingEntity).durability,
    };

    for (healths, 0..) |health, index| {
        try testing.expectEqual(expected_after[index], health.current);
    }

    const motion = (store.get(fixtures.Bullet, bullet) orelse return error.MissingEntity).movement;

    try testing.expectEqual(40, motion.x);
}

test "parts selection joins fields of one thing and requires every requested type" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const plane = store.add(fixtures.plane(40));
    const building = store.add(fixtures.building(80));
    const bullet = store.add(fixtures.bullet(90));

    var parts = store.parts(.{
        .movement = fixtures.Motion,
        .durability = fixtures.Health,
        .gun = fixtures.Weapon,
    });
    defer parts.deinit();

    const components = parts.next() orelse return error.MissingEntity;

    try testing.expectEqualDeep(plane, parts.thingId());

    components.durability.current = 7;
    components.movement.x = 8;
    components.gun.ammunition = 3;

    try testing.expect(parts.next() == null);

    const health = (store.get(fixtures.Plane, plane) orelse return error.MissingEntity).health;
    const motion = (store.get(fixtures.Plane, plane) orelse return error.MissingEntity).motion;
    const weapon = (store.get(fixtures.Plane, plane) orelse return error.MissingEntity).weapon;

    try testing.expectEqual(7, health.current);
    try testing.expectEqual(8, motion.x);
    try testing.expectEqual(3, weapon.ammunition);

    const untouched_health = (store.get(fixtures.Building, building) orelse return error.MissingEntity).durability;
    const untouched_motion = (store.get(fixtures.Bullet, bullet) orelse return error.MissingEntity).movement;

    try testing.expectEqual(80, untouched_health.current);
    try testing.expectEqual(90, untouched_motion.x);
}

test "parts iteration skips empty matching types" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const building = store.add(fixtures.building(55));

    var parts = store.parts(.{ .health = fixtures.Health });
    defer parts.deinit();

    const row = parts.next() orelse return error.MissingEntity;

    try testing.expectEqual(55, row.health.current);
    try testing.expectEqualDeep(building, parts.thingId());
    try testing.expect(parts.next() == null);
    try testing.expect(parts.next() == null);
}

test "parts iteration on an empty store releases matching types" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    var parts = store.parts(.{ .motion = fixtures.Motion });
    defer parts.deinit();

    try testing.expect(parts.next() == null);
    try testing.expect(parts.next() == null);

    _ = store.add(fixtures.plane(10));
    _ = store.add(fixtures.bullet(20));

    try testing.expect(parts.next() == null);
    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(1, store.count(fixtures.Bullet));
}

test "selecting an absent part neither yields things nor locks unrelated types" {
    const Missing = struct { number: i64 };
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    _ = store.add(fixtures.plane(10));

    var parts = store.parts(.{ .missing = Missing });
    defer parts.deinit();

    try testing.expect(parts.next() == null);

    _ = store.add(fixtures.plane(20));

    try testing.expectEqual(2, store.count(fixtures.Plane));
}

test "thing IDs follow yielded rows and a finished parts iterator remains closed" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const first = store.add(fixtures.plane(10));
    const second = store.add(fixtures.plane(20));
    var parts = store.parts(.{ .hp = fixtures.Health });
    defer parts.deinit();

    _ = parts.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(first, parts.thingId());

    _ = parts.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(second, parts.thingId());
    try testing.expect(parts.next() == null);

    _ = store.add(fixtures.plane(30));
    parts.deinit();

    try testing.expect(parts.next() == null);
    try testing.expectEqual(3, store.count(fixtures.Plane));
}

test "active parts iterators defer removal only in matching pools" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const plane = store.add(fixtures.plane(10));
    const survivor = store.add(fixtures.plane(20));
    var parts = store.parts(.{ .weapon = fixtures.Weapon });
    defer parts.deinit();

    store.remove(plane);
    store.remove(plane);
    const building = store.add(fixtures.building(30));
    store.remove(building);

    try testing.expectEqual(0, store.count(fixtures.Building));
    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expect(store.get(fixtures.Plane, plane) == null);

    _ = parts.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(survivor, parts.thingId());
    try testing.expect(parts.next() == null);
    try testing.expectEqual(1, store.count(fixtures.Plane));
}

test "closing a parts iterator releases matching empty types for insertion" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    var parts = store.parts(.{ .health = fixtures.Health });
    defer parts.deinit();

    _ = store.add(fixtures.bullet(30));
    parts.deinit();

    _ = store.add(fixtures.plane(10));
    _ = store.add(fixtures.building(20));

    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(1, store.count(fixtures.Building));
}

test "nested parts iterators clean each pool only after its last cursor closes" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const plane = store.add(fixtures.plane(10));
    const survivor = store.add(fixtures.plane(20));
    const building = store.add(fixtures.building(30));
    var health = store.parts(.{ .health = fixtures.Health });
    defer health.deinit();
    var motion = store.parts(.{ .motion = fixtures.Motion });
    defer motion.deinit();

    const row = motion.next() orelse return error.MissingEntity;
    store.remove(plane);
    store.remove(building);
    health.deinit();
    health.deinit();

    try testing.expectEqual(0, store.count(fixtures.Building));
    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(10, row.motion.x);
    try testing.expect(store.get(fixtures.Plane, plane) == null);

    motion.deinit();

    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(20, store.get(fixtures.Plane, survivor).?.motion.x);
}

test "exhaustion and closing an unfinished parts iterator both release its types" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    _ = store.add(fixtures.plane(10));
    var parts = store.parts(.{ .weapon = fixtures.Weapon });
    defer parts.deinit();

    while (parts.next()) |_| {}

    _ = store.add(fixtures.plane(20));
    parts.deinit();

    var unfinished = store.parts(.{ .weapon = fixtures.Weapon });
    defer unfinished.deinit();

    _ = unfinished.next() orelse return error.MissingEntity;
    unfinished.deinit();

    try testing.expect(unfinished.next() == null);

    _ = store.add(fixtures.plane(30));
    try testing.expectEqual(3, store.count(fixtures.Plane));
}

test "independent parts iterators preserve earlier pointers and observe shared mutations" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    _ = store.add(fixtures.plane(10));
    _ = store.add(fixtures.plane(20));

    var first = store.parts(.{ .health = fixtures.Health });
    defer first.deinit();

    var second = store.parts(.{ .hp = fixtures.Health });
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

test "parts iteration and automatic removal require no allocations" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = fixtures.GameStore.init(failing.allocator());
    defer store.deinit();

    const plane = store.add(fixtures.plane(10));
    const building = store.add(fixtures.building(20));
    failing.fail_index = failing.alloc_index;

    var parts = store.parts(.{ .hp = fixtures.Health });
    defer parts.deinit();

    var count: usize = 0;

    while (parts.next()) |_| {
        const id = parts.thingId();
        try testing.expect(store.get(fixtures.Plane, id) != null or store.get(fixtures.Building, id) != null);

        store.remove(parts.thingId());
        count += 1;
    }

    try testing.expectEqual(2, count);

    parts.deinit();

    try testing.expectEqual(0, store.count(fixtures.Plane) + store.count(fixtures.Building));
    try testing.expect(store.get(fixtures.Plane, plane) == null);
    try testing.expect(store.get(fixtures.Building, building) == null);
}

test "removing the current entity twice neither skips rows nor deletes survivors" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const first = store.add(fixtures.plane(0));
    const survivor = store.add(fixtures.plane(10));
    const last = store.add(fixtures.plane(-1));

    var parts = store.parts(.{ .health = fixtures.Health });
    defer parts.deinit();

    var count: usize = 0;

    while (parts.next()) |components| {
        if (components.health.current <= 0) {
            store.remove(parts.thingId());
            store.remove(parts.thingId());
        }

        count += 1;
    }

    try testing.expectEqual(3, count);

    parts.deinit();

    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expect(store.get(fixtures.Plane, first) == null);
    try testing.expect(store.get(fixtures.Plane, last) == null);

    const health = (store.get(fixtures.Plane, survivor) orelse return error.MissingEntity).health;

    try testing.expectEqual(10, health.current);
}

test "part aliases can use names also used by iterator methods" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    _ = store.add(fixtures.plane(10));

    var parts = store.parts(.{ .thingId = fixtures.Health, .next = fixtures.Motion });
    defer parts.deinit();

    const components = parts.next() orelse return error.MissingEntity;
    components.thingId.current = 15;
    components.next.x = 25;

    try testing.expect(store.get(fixtures.Plane, parts.thingId()) != null);
    try testing.expectEqual(15, store.get(fixtures.Plane, parts.thingId()).?.health.current);
    try testing.expectEqual(25, store.get(fixtures.Plane, parts.thingId()).?.motion.x);
}

test "parts iteration skips a type whose rows were all removed before visiting" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const plane = store.add(fixtures.plane(10));
    const building = store.add(fixtures.building(20));
    var parts = store.parts(.{ .hp = fixtures.Health });
    defer parts.deinit();

    store.remove(plane);
    store.remove(building);

    try testing.expect(parts.next() == null);
    try testing.expectEqual(0, store.count(fixtures.Plane));
    try testing.expectEqual(0, store.count(fixtures.Building));
}

test "breaking an iteration cleans up at the enclosing scope boundary" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const removed = store.add(fixtures.plane(10));
    _ = store.add(fixtures.plane(20));

    {
        var parts = store.parts(.{ .hp = fixtures.Health });
        defer parts.deinit();

        while (parts.next()) |_| {
            store.remove(parts.thingId());
            break;
        }

        try testing.expectEqual(1, store.count(fixtures.Plane));
        try testing.expect(store.get(fixtures.Plane, removed) == null);
    }

    try testing.expectEqual(1, store.count(fixtures.Plane));
}

test "an error return releases a parts iterator and applies pending removal" {
    const Operation = struct {
        fn run(store: *fixtures.GameStore) !void {
            var parts = store.parts(.{ .hp = fixtures.Health });
            defer parts.deinit();

            _ = parts.next() orelse return error.MissingEntity;
            store.remove(parts.thingId());
            return error.ExpectedExit;
        }
    };

    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    const removed = store.add(fixtures.plane(10));

    try testing.expectError(error.ExpectedExit, Operation.run(&store));
    try testing.expect(store.get(fixtures.Plane, removed) == null);
    try testing.expectEqual(0, store.count(fixtures.Plane));

    _ = store.add(fixtures.plane(20));
    try testing.expectEqual(1, store.count(fixtures.Plane));
}

test "exhausting an inner parts iterator preserves the outer cursor until it finishes" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const removed = store.add(fixtures.plane(10));
    const survivor = store.add(fixtures.plane(20));
    var outer = store.parts(.{ .hp = fixtures.Health });
    defer outer.deinit();
    const row = outer.next() orelse return error.MissingEntity;

    var inner = store.parts(.{ .motion = fixtures.Motion });
    defer inner.deinit();

    _ = inner.next() orelse return error.MissingEntity;
    store.remove(inner.thingId());

    _ = inner.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(survivor, inner.thingId());
    try testing.expect(inner.next() == null);
    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(10, row.hp.current);
    try testing.expectEqualDeep(removed, outer.thingId());

    const next = outer.next() orelse return error.MissingEntity;
    try testing.expectEqual(20, next.hp.current);
    try testing.expectEqualDeep(survivor, outer.thingId());
    try testing.expect(outer.next() == null);
    try testing.expectEqual(1, store.count(fixtures.Plane));
}
