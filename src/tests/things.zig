const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

test "things length captures stored rows while count tracks live things" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const removed = store.add(fixtures.plane(10));
    _ = store.add(fixtures.plane(20));
    _ = store.add(fixtures.building(30));
    var things = store.things(fixtures.Plane);
    defer things.deinit();

    try testing.expectEqual(2, things.len);
    store.remove(removed);

    try testing.expectEqual(2, things.len);
    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(1, store.count(fixtures.Building));

    var visited: usize = 0;

    while (things.next()) |thing| {
        try testing.expectEqual(20, thing.health.current);
        thing.weapon.ammunition = 5;
        visited += 1;
    }

    try testing.expectEqual(1, visited);

    var fresh = store.things(fixtures.Plane);
    defer fresh.deinit();

    try testing.expectEqual(1, fresh.len);
    try testing.expectEqual(5, fresh.next().?.weapon.ammunition);
}

test "nested things iterators keep removed row pointers valid until the last close" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const removed = store.add(fixtures.plane(10));
    const survivor = store.add(fixtures.plane(20));
    var outer = store.things(fixtures.Plane);
    defer outer.deinit();
    const row = outer.next() orelse return error.MissingThing;
    var inner = store.things(fixtures.Plane);
    defer inner.deinit();

    store.remove(removed);
    store.remove(removed);

    try testing.expectEqual(20, inner.next().?.health.current);
    try testing.expectEqualDeep(survivor, inner.thingId());
    try testing.expect(inner.next() == null);
    try testing.expectEqual(10, row.health.current);
    try testing.expectEqual(1, store.count(fixtures.Plane));

    outer.deinit();
    const replacement = store.add(fixtures.plane(30));

    try testing.expectEqual(removed.slot, replacement.slot);
    try testing.expect(store.get(fixtures.Plane, removed) == null);
    try testing.expectEqual(20, store.get(fixtures.Plane, survivor).?.health.current);
}

test "automatic removal cleans up when an unfinished iterator closes" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const removed = store.add(fixtures.plane(10));
    _ = store.add(fixtures.plane(20));
    var iterator = store.things(fixtures.Plane);
    defer iterator.deinit();

    _ = iterator.next() orelse return error.MissingEntity;
    store.remove(iterator.thingId());
    iterator.deinit();
    iterator.deinit();

    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expect(store.get(fixtures.Plane, removed) == null);
}

test "things iteration skips pending rows and cleans up on exhaustion" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const first = store.add(fixtures.plane(10));
    const skipped = store.add(fixtures.plane(20));
    const last = store.add(fixtures.plane(30));
    var iterator = store.things(fixtures.Plane);
    defer iterator.deinit();

    _ = iterator.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(first, iterator.thingId());
    store.remove(skipped);

    const row = iterator.next() orelse return error.MissingEntity;
    try testing.expectEqualDeep(last, iterator.thingId());
    try testing.expectEqual(30, row.health.current);
    try testing.expect(iterator.next() == null);
    try testing.expectEqual(2, store.count(fixtures.Plane));

    _ = store.add(fixtures.plane(40));
    iterator.deinit();
    try testing.expectEqual(3, store.count(fixtures.Plane));
}
