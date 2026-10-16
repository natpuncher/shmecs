const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

test "typed clear invalidates IDs isolates other types and reuses its allocation" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = fixtures.GameStore.init(failing.allocator());
    defer store.deinit();

    const first = store.add(fixtures.plane(10));
    const second = store.add(fixtures.plane(20));
    const building = store.add(fixtures.building(30));
    failing.fail_index = failing.alloc_index;

    store.clear(fixtures.Plane);
    store.clear(fixtures.Plane);

    try testing.expectEqual(0, store.count(fixtures.Plane));
    try testing.expect(store.get(fixtures.Plane, first) == null);
    try testing.expect(store.get(fixtures.Plane, second) == null);
    try testing.expectEqual(30, store.get(fixtures.Building, building).?.durability.current);

    const replacement = store.add(fixtures.plane(40));
    store.remove(first);
    store.remove(second);

    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(40, store.get(fixtures.Plane, replacement).?.health.current);
}

test "typed clear hides every row while nested iterators retain their pointers" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const first = store.add(fixtures.plane(10));
    const second = store.add(fixtures.plane(20));
    const third = store.add(fixtures.plane(30));
    var things = store.things(fixtures.Plane);
    defer things.deinit();
    const row = things.next() orelse return error.MissingThing;

    var parts = store.parts(.{ .health = fixtures.Health });
    defer parts.deinit();

    store.remove(second);
    store.clear(fixtures.Plane);
    store.clear(fixtures.Plane);

    try testing.expectEqual(0, store.count(fixtures.Plane));
    try testing.expectEqual(3, things.len);
    try testing.expect(store.get(fixtures.Plane, first) == null);
    try testing.expect(store.get(fixtures.Plane, second) == null);
    try testing.expect(store.get(fixtures.Plane, third) == null);
    try testing.expect(parts.next() == null);
    try testing.expectEqual(10, row.health.current);
    try testing.expect(things.next() == null);

    const replacement = store.add(fixtures.plane(40));

    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(first.slot, replacement.slot);
    try testing.expect(first.generation != replacement.generation);
}

test "clear all handles occupied and free types independently" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const plane = store.add(fixtures.plane(10));
    const building = store.add(fixtures.building(20));
    const bullet = store.add(fixtures.bullet(30));
    var parts = store.parts(.{ .health = fixtures.Health });
    defer parts.deinit();

    store.clearAll();
    store.clearAll();

    try testing.expectEqual(0, store.count(fixtures.Plane));
    try testing.expectEqual(0, store.count(fixtures.Building));
    try testing.expectEqual(0, store.count(fixtures.Bullet));
    try testing.expect(store.get(fixtures.Plane, plane) == null);
    try testing.expect(store.get(fixtures.Building, building) == null);
    try testing.expect(store.get(fixtures.Bullet, bullet) == null);

    const new_bullet = store.add(fixtures.bullet(40));

    try testing.expectEqual(bullet.slot, new_bullet.slot);
    try testing.expect(parts.next() == null);

    const new_plane = store.add(fixtures.plane(50));
    const new_building = store.add(fixtures.building(60));

    store.clearAll();

    try testing.expectEqual(0, store.count(fixtures.Plane));
    try testing.expectEqual(0, store.count(fixtures.Building));
    try testing.expectEqual(0, store.count(fixtures.Bullet));
    try testing.expect(store.get(fixtures.Plane, new_plane) == null);
    try testing.expect(store.get(fixtures.Building, new_building) == null);
    try testing.expect(store.get(fixtures.Bullet, new_bullet) == null);
}

test "clearing empty stores neither allocates nor prevents later use" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var store = fixtures.GameStore.init(failing.allocator());
    defer store.deinit();

    store.clear(fixtures.Plane);
    store.clearAll();

    var things = store.things(fixtures.Plane);
    defer things.deinit();
    store.clear(fixtures.Plane);

    try testing.expectEqual(0, store.count(fixtures.Plane));
    try testing.expect(things.next() == null);

    failing.fail_index = std.math.maxInt(usize);
    const id = store.add(fixtures.plane(10));

    try testing.expectEqual(10, store.get(fixtures.Plane, id).?.health.current);
}

test "clear retires an exhausted generation instead of reusing its ID" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    var exhausted = store.add(fixtures.plane(10));
    store.pools[0].slots[exhausted.slot].generation = std.math.maxInt(u32);
    exhausted.generation = std.math.maxInt(u32);
    _ = store.add(fixtures.plane(20));

    store.clear(fixtures.Plane);

    const first = store.add(fixtures.plane(30));
    const second = store.add(fixtures.plane(40));

    try testing.expect(first.slot != exhausted.slot);
    try testing.expect(second.slot != exhausted.slot);
    try testing.expect(store.get(fixtures.Plane, exhausted) == null);
    try testing.expectEqual(2, store.count(fixtures.Plane));
}
