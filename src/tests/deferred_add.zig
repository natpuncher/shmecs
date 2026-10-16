const std = @import("std");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const ThingId = @import("../thing_id.zig").ThingId;
const PoolStorage = @import("../pool_storage.zig").PoolStorage;

test "same type spawning preserves pointers and stays invisible until iteration finishes" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    store.reserve(fixtures.Plane, 1);
    const original = store.add(fixtures.plane(10));
    var added: [128]ThingId = undefined;
    var things = store.things(fixtures.Plane);
    defer things.deinit();
    var visited: usize = 0;

    while (things.next()) |plane| {
        visited += 1;
        try testing.expectEqual(1, visited);

        for (&added, 0..) |*id, index| {
            id.* = store.add(fixtures.plane(@floatFromInt(index + 20)));

            try testing.expect(store.get(fixtures.Plane, id.*) == null);
            try testing.expectEqual(1, store.count(fixtures.Plane));
            try testing.expectEqual(10, plane.health.current);
            try testing.expectEqualDeep(original, things.thingId());
        }

        plane.weapon.ammunition = 42;
    }

    try testing.expectEqual(129, store.count(fixtures.Plane));
    try testing.expectEqual(42, store.get(fixtures.Plane, original).?.weapon.ammunition);

    for (added, 0..) |id, index| {
        const plane = store.get(fixtures.Plane, id) orelse return error.MissingThing;
        const expected = fixtures.plane(@floatFromInt(index + 20));

        try testing.expectEqualDeep(expected.health, plane.health.*);
        try testing.expectEqualDeep(expected.motion, plane.motion.*);
        try testing.expectEqualDeep(expected.weapon, plane.weapon.*);
    }
}

test "nested iterators commit additions only when the last iterator closes" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    _ = store.add(fixtures.plane(10));
    var outer = store.things(fixtures.Plane);
    defer outer.deinit();
    const added = store.add(fixtures.plane(20));
    var inner = store.things(fixtures.Plane);
    defer inner.deinit();
    const row = inner.next() orelse return error.MissingThing;

    outer.deinit();

    try testing.expectEqual(10, row.health.current);
    try testing.expect(store.get(fixtures.Plane, added) == null);
    try testing.expectEqual(1, inner.len);
    try testing.expect(inner.next() == null);
    try testing.expectEqual(20, store.get(fixtures.Plane, added).?.health.current);
}

test "parts iteration defers spawns into matching types that have not been visited" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    _ = store.add(fixtures.plane(10));
    var parts = store.parts(.{ .motion = fixtures.Motion });
    defer parts.deinit();
    _ = parts.next() orelse return error.MissingThing;

    const bullet = store.add(fixtures.bullet(20));
    const building = store.add(fixtures.building(30));

    try testing.expect(store.get(fixtures.Bullet, bullet) == null);
    try testing.expectEqual(0, store.count(fixtures.Bullet));
    try testing.expectEqual(30, store.get(fixtures.Building, building).?.durability.current);
    try testing.expect(parts.next() == null);
    try testing.expectEqual(20, store.get(fixtures.Bullet, bullet).?.movement.x);
}

test "spawning another thing type stays immediate" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    _ = store.add(fixtures.plane(10));
    var things = store.things(fixtures.Plane);
    defer things.deinit();
    const bullet = store.add(fixtures.bullet(20));

    try testing.expectEqual(1, store.count(fixtures.Bullet));
    try testing.expectEqual(20, store.get(fixtures.Bullet, bullet).?.movement.x);
}

test "canceled additions reuse both existing and temporary slots with a new generation" {
    inline for (.{ false, true }) |existing_slot| {
        var store = fixtures.GameStore.init(testing.allocator);
        defer store.deinit();

        if (existing_slot) {
            const old = store.add(fixtures.plane(10));
            _ = store.add(fixtures.plane(20));
            store.remove(old);
        }

        var things = store.things(fixtures.Plane);
        defer things.deinit();
        const canceled = store.add(fixtures.plane(30));
        store.remove(canceled);
        store.remove(canceled);
        const replacement = store.add(fixtures.plane(40));
        store.remove(canceled);

        try testing.expectEqual(canceled.slot, replacement.slot);
        try testing.expect(canceled.generation != replacement.generation);
        try testing.expect(store.get(fixtures.Plane, replacement) == null);

        things.deinit();

        try testing.expect(store.get(fixtures.Plane, canceled) == null);
        try testing.expectEqual(40, store.get(fixtures.Plane, replacement).?.health.current);
        try testing.expectEqual(@as(usize, if (existing_slot) 2 else 1), store.count(fixtures.Plane));
    }
}

test "clear cancels earlier additions and preserves later spawns" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    const original = store.add(fixtures.plane(10));
    var things = store.things(fixtures.Plane);
    defer things.deinit();
    const row = things.next() orelse return error.MissingThing;
    const canceled = store.add(fixtures.plane(20));
    store.remove(original);
    store.clear(fixtures.Plane);
    store.clear(fixtures.Plane);
    const survivor = store.add(fixtures.plane(30));

    try testing.expectEqual(0, store.count(fixtures.Plane));
    try testing.expectEqual(10, row.health.current);
    try testing.expect(things.next() == null);
    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expect(store.get(fixtures.Plane, original) == null);
    try testing.expect(store.get(fixtures.Plane, canceled) == null);
    try testing.expectEqual(30, store.get(fixtures.Plane, survivor).?.health.current);
}

test "clear all cancels pending additions across matching types" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    const original = store.add(fixtures.plane(10));
    _ = store.add(fixtures.bullet(20));
    var parts = store.parts(.{ .motion = fixtures.Motion });
    defer parts.deinit();
    const plane = store.add(fixtures.plane(30));
    const bullet = store.add(fixtures.bullet(40));
    store.clearAll();
    const survivor = store.add(fixtures.bullet(50));
    parts.deinit();

    try testing.expectEqual(0, store.count(fixtures.Plane));
    try testing.expectEqual(1, store.count(fixtures.Bullet));
    try testing.expect(store.get(fixtures.Plane, original) == null);
    try testing.expect(store.get(fixtures.Plane, plane) == null);
    try testing.expect(store.get(fixtures.Bullet, bullet) == null);
    try testing.expectEqual(50, store.get(fixtures.Bullet, survivor).?.movement.x);
}

test "canceling every addition still invalidates its IDs after the queue closes" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    var things = store.things(fixtures.Plane);
    defer things.deinit();
    const canceled = store.add(fixtures.plane(10));
    store.remove(canceled);
    things.deinit();
    const replacement = store.add(fixtures.plane(20));

    try testing.expectEqual(canceled.slot, replacement.slot);
    try testing.expect(canceled.generation != replacement.generation);
    try testing.expect(store.get(fixtures.Plane, canceled) == null);
    try testing.expectEqual(20, store.get(fixtures.Plane, replacement).?.health.current);
}

test "failed deferred append does not consume a new slot" {
    inline for (.{ 0, 1 }) |failed_allocation| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var pool = PoolStorage(fixtures.Plane).init(failing.allocator());
        defer pool.deinit();
        const original = try pool.append(fixtures.plane(10));
        var things = pool.iterator();
        defer things.deinit();
        failing.fail_index = failing.alloc_index + failed_allocation;

        try testing.expectError(error.OutOfMemory, pool.append(fixtures.plane(20)));
        try testing.expectEqual(1, pool.len);
        try testing.expect(pool.indexOf(original) != null);
        things.deinit();
        failing.fail_index = std.math.maxInt(usize);
        const next = try pool.append(fixtures.plane(30));

        try testing.expectEqual(1, next.slot);
        try testing.expectEqual(2, pool.len);
    }
}

test "failed deferred append preserves an existing free slot" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var pool = PoolStorage(fixtures.Plane).init(failing.allocator());
    defer pool.deinit();
    const removed = try pool.append(fixtures.plane(10));
    _ = try pool.append(fixtures.plane(20));
    pool.remove(removed);
    var things = pool.iterator();
    defer things.deinit();
    failing.fail_index = failing.alloc_index;

    try testing.expectError(error.OutOfMemory, pool.append(fixtures.plane(30)));
    things.deinit();
    failing.fail_index = std.math.maxInt(usize);
    const replacement = try pool.append(fixtures.plane(40));

    try testing.expectEqual(removed.slot, replacement.slot);
    try testing.expectEqual(removed.generation + 1, replacement.generation);
    try testing.expectEqual(2, pool.len);
}

test "malformed IDs cannot cancel a queued spawn" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    var things = store.things(fixtures.Plane);
    defer things.deinit();
    const queued = store.add(fixtures.plane(10));
    const malformed = [_]ThingId{
        .{ .pool = queued.pool, .slot = std.math.maxInt(u32), .generation = queued.generation },
        .{ .pool = queued.pool, .slot = queued.slot, .generation = queued.generation + 1 },
        .{ .pool = std.math.maxInt(u32), .slot = queued.slot, .generation = queued.generation },
    };

    for (malformed) |id| store.remove(id);

    things.deinit();

    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(10, store.get(fixtures.Plane, queued).?.health.current);
}

test "deferred cancellation retires an exhausted generation" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();
    var exhausted = store.add(fixtures.plane(10));
    _ = store.add(fixtures.plane(20));
    exhausted.generation = std.math.maxInt(u32) - 1;
    store.pools[0].slots[exhausted.slot].generation = exhausted.generation;
    store.remove(exhausted);
    var things = store.things(fixtures.Plane);
    defer things.deinit();
    const canceled = store.add(fixtures.plane(30));

    try testing.expectEqual(std.math.maxInt(u32), canceled.generation);
    store.remove(canceled);
    const survivor = store.add(fixtures.plane(40));
    things.deinit();

    try testing.expect(canceled.slot != survivor.slot);
    try testing.expect(store.get(fixtures.Plane, canceled) == null);
    try testing.expectEqual(40, store.get(fixtures.Plane, survivor).?.health.current);
}

test "copy and growth preserve ownership of reusable addition buffers" {
    var destination = fixtures.GameStore.init(testing.allocator);
    defer destination.deinit();
    var source = fixtures.GameStore.init(testing.allocator);
    defer source.deinit();

    var things = destination.things(fixtures.Plane);
    defer things.deinit();
    _ = destination.add(fixtures.plane(10));
    things.deinit();

    for (0..64) |index| _ = source.add(fixtures.plane(@floatFromInt(index)));

    destination.copyFrom(&source);
    var parts = destination.parts(.{ .health = fixtures.Health });
    defer parts.deinit();
    const added = destination.add(fixtures.plane(100));
    parts.deinit();

    try testing.expectEqual(65, destination.count(fixtures.Plane));
    try testing.expectEqual(64, source.count(fixtures.Plane));
    try testing.expectEqual(100, destination.get(fixtures.Plane, added).?.health.current);
    try testing.expect(source.get(fixtures.Plane, added) == null);
}

test "mixed deferred operations agree with a logical thing model" {
    const State = enum { live, queued, removed };
    const Record = struct { id: ThingId, health: f32, state: State };

    for ([_]u64{ 0x53484d454353, 0x4445464552524544 }) |seed| {
        var store = fixtures.GameStore.init(testing.allocator);
        defer store.deinit();
        var records: [64]?Record = @splat(null);
        var guard: ?@TypeOf(store.things(fixtures.Plane)) = null;
        defer if (guard) |*things| things.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        for (0..2000) |step| {
            const selected = random.uintLessThan(usize, records.len);

            switch (random.uintLessThan(u8, 9)) {
                0, 1 => {
                    const can_add = if (records[selected]) |record| record.state == .removed else true;

                    if (can_add) {
                        const value: f32 = @floatFromInt(step + 1);
                        records[selected] = .{
                            .id = store.add(fixtures.plane(value)),
                            .health = value,
                            .state = if (guard != null) .queued else .live,
                        };
                    }
                },
                2 => {
                    if (records[selected]) |*record| {
                        store.remove(record.id);
                        record.state = .removed;
                    }
                },
                3 => {
                    if (guard == null) guard = store.things(fixtures.Plane);
                },
                4 => {
                    if (guard) |*things| things.deinit();
                    guard = null;

                    for (&records) |*entry| {
                        if (entry.*) |*record| {
                            if (record.state == .queued) record.state = .live;
                        }
                    }
                },
                5 => {
                    store.clear(fixtures.Plane);

                    for (&records) |*entry| {
                        if (entry.*) |*record| record.state = .removed;
                    }
                },
                6 => {
                    if (records[selected]) |*record| {
                        if (record.state == .live) {
                            store.get(fixtures.Plane, record.id).?.health.current += 1;
                            record.health += 1;
                        }
                    }
                },
                7 => {
                    var parts = store.parts(.{ .health = fixtures.Health });
                    defer parts.deinit();
                    const can_add = if (records[selected]) |record| record.state == .removed else true;

                    if (can_add) {
                        const value: f32 = @floatFromInt(step + 1);
                        records[selected] = .{
                            .id = store.add(fixtures.plane(value)),
                            .health = value,
                            .state = if (guard != null) .queued else .live,
                        };
                    }
                },
                8 => {
                    if (guard == null) store.reserve(fixtures.Plane, random.uintLessThan(usize, 128) + 1);
                },
                else => unreachable,
            }

            var expected_count: usize = 0;

            for (records) |entry| {
                if (entry) |record| {
                    const thing = store.get(fixtures.Plane, record.id);

                    if (record.state == .live) {
                        expected_count += 1;
                        const plane = thing orelse return error.MissingThing;

                        try testing.expectEqual(record.health, plane.health.current);
                    } else {
                        try testing.expect(thing == null);
                    }
                }
            }

            try testing.expectEqual(expected_count, store.count(fixtures.Plane));
        }
    }
}

test "deferred spawning supports empty and over-aligned thing types" {
    const Empty = struct {};
    const AlignedPart = struct { bytes: [64]u8 align(64) };
    const Aligned = struct { part: AlignedPart };
    const Store = @import("../store.zig").Store(.{ Empty, Aligned });
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var empty = store.things(Empty);
    defer empty.deinit();
    var aligned = store.things(Aligned);
    defer aligned.deinit();
    const canceled = store.add(Empty{});
    const survivor = store.add(Empty{});
    const value = store.add(Aligned{ .part = .{ .bytes = @splat(7) } });
    store.remove(canceled);
    empty.deinit();
    aligned.deinit();

    try testing.expectEqual(1, store.count(Empty));
    try testing.expect(store.get(Empty, canceled) == null);
    try testing.expect(store.get(Empty, survivor) != null);
    const part = store.get(Aligned, value).?.part;

    try testing.expectEqual(0, @intFromPtr(part) % 64);
    try testing.expectEqualSlices(u8, &@as([64]u8, @splat(7)), &part.bytes);
}
