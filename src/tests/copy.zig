const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const PoolStorage = @import("../pool_storage.zig").PoolStorage;

test "copy restores values IDs and dense order across multiple thing types" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    var snapshot = fixtures.GameStore.init(testing.allocator);
    defer snapshot.deinit();

    const first = store.add(fixtures.plane(10));
    const removed = store.add(fixtures.plane(20));
    const third = store.add(fixtures.plane(30));
    const fourth = store.add(fixtures.plane(40));
    const building = store.add(fixtures.building(50));
    const bullet = store.add(fixtures.bullet(60));
    store.remove(removed);
    snapshot.copyFrom(&store);

    store.get(fixtures.Plane, first).?.health.current = 99;
    store.get(fixtures.Building, building).?.durability.current = 88;
    store.remove(bullet);
    const replacement = store.add(fixtures.plane(70));

    try testing.expectEqual(10, snapshot.get(fixtures.Plane, first).?.health.current);
    try testing.expectEqual(50, snapshot.get(fixtures.Building, building).?.durability.current);
    try testing.expect(snapshot.get(fixtures.Bullet, bullet) != null);

    store.copyFrom(&snapshot);

    try testing.expectEqual(3, store.count(fixtures.Plane));
    try testing.expectEqual(1, store.count(fixtures.Building));
    try testing.expectEqual(1, store.count(fixtures.Bullet));
    try testing.expect(store.get(fixtures.Plane, removed) == null);
    try testing.expect(store.get(fixtures.Plane, replacement) == null);
    try testing.expectEqual(10, store.get(fixtures.Plane, first).?.health.current);
    try testing.expectEqual(50, store.get(fixtures.Building, building).?.durability.current);
    try testing.expectEqual(60, store.get(fixtures.Bullet, bullet).?.movement.x);

    var things = store.things(fixtures.Plane);
    defer things.deinit();
    const expected_ids = .{ first, fourth, third };
    const expected_values = .{ fixtures.plane(10), fixtures.plane(40), fixtures.plane(30) };

    inline for (expected_ids, expected_values) |id, expected| {
        const row = things.next() orelse return error.MissingThing;

        try testing.expectEqualDeep(id, things.thingId());
        try testing.expectEqualDeep(expected.health, row.health.*);
        try testing.expectEqualDeep(expected.motion, row.motion.*);
        try testing.expectEqualDeep(expected.weapon, row.weapon.*);
    }

    try testing.expect(things.next() == null);
}

test "copy reuses destination capacity and preserves an independent free chain" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var destination = fixtures.GameStore.init(failing.allocator());
    defer destination.deinit();
    var source = fixtures.GameStore.init(testing.allocator);
    defer source.deinit();

    const first = source.add(fixtures.plane(10));
    const second = source.add(fixtures.plane(20));
    const survivor = source.add(fixtures.plane(30));
    source.remove(first);
    source.remove(second);
    destination.reserve(fixtures.Plane, 16);
    _ = destination.add(fixtures.plane(99));
    failing.fail_index = failing.alloc_index;

    destination.copyFrom(&source);

    const replacement = destination.add(fixtures.plane(40));
    const next = destination.add(fixtures.plane(50));

    try testing.expectEqual(second.slot, replacement.slot);
    try testing.expectEqual(first.slot, next.slot);
    try testing.expectEqual(3, destination.count(fixtures.Plane));
    try testing.expectEqual(1, source.count(fixtures.Plane));
    try testing.expect(source.get(fixtures.Plane, replacement) == null);
    try testing.expect(source.get(fixtures.Plane, next) == null);
    try testing.expectEqual(30, destination.get(fixtures.Plane, survivor).?.health.current);

    destination.get(fixtures.Plane, survivor).?.health.current = 7;

    try testing.expectEqual(30, source.get(fixtures.Plane, survivor).?.health.current);
}

test "copying empty state replaces a populated destination and preserves retired slots" {
    var source = fixtures.GameStore.init(testing.allocator);
    defer source.deinit();
    var destination = fixtures.GameStore.init(testing.allocator);
    defer destination.deinit();

    var exhausted = source.add(fixtures.plane(10));
    source.pools[0].slots[exhausted.slot].generation = std.math.maxInt(u32);
    exhausted.generation = std.math.maxInt(u32);
    source.clear(fixtures.Plane);
    const old = destination.add(fixtures.plane(99));

    destination.copyFrom(&source);

    try testing.expectEqual(0, destination.count(fixtures.Plane));
    try testing.expect(destination.get(fixtures.Plane, old) == null);
    try testing.expect(destination.get(fixtures.Plane, exhausted) == null);

    const replacement = destination.add(fixtures.plane(20));

    try testing.expect(replacement.slot != exhausted.slot);
    try testing.expectEqual(20, destination.get(fixtures.Plane, replacement).?.health.current);
    try testing.expectEqual(0, source.count(fixtures.Plane));
}

test "copying from a never allocated store clears existing rows" {
    var empty = fixtures.GameStore.init(testing.allocator);
    defer empty.deinit();
    var destination = fixtures.GameStore.init(testing.allocator);
    defer destination.deinit();

    const id = destination.add(fixtures.plane(10));
    _ = destination.add(fixtures.building(20));
    destination.copyFrom(&empty);

    try testing.expectEqual(0, destination.count(fixtures.Plane));
    try testing.expectEqual(0, destination.count(fixtures.Building));
    try testing.expect(destination.get(fixtures.Plane, id) == null);
}

test "copying a store to itself preserves values and IDs without allocating" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = fixtures.GameStore.init(failing.allocator());
    defer store.deinit();

    const id = store.add(fixtures.plane(10));
    failing.fail_index = failing.alloc_index;
    store.copyFrom(&store);

    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(10, store.get(fixtures.Plane, id).?.health.current);
}

test "failed pool copy preserves the previous destination state" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var destination = PoolStorage(fixtures.Plane).init(failing.allocator());
    defer destination.deinit();
    var source = PoolStorage(fixtures.Plane).init(testing.allocator);
    defer source.deinit();

    try destination.reserve(1);
    const old = try destination.append(fixtures.plane(10));
    _ = try source.append(fixtures.plane(20));
    _ = try source.append(fixtures.plane(30));

    try testing.expectError(error.OutOfMemory, destination.copyFrom(&source));
    try testing.expectEqual(1, destination.len);
    try testing.expectEqualDeep(fixtures.plane(10), fixtures.planeAt(&destination, destination.indexOf(old).?).?);
}
