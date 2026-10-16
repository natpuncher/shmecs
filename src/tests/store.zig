const std = @import("std");
const testing = std.testing;
const ThingId = @import("../thing_id.zig").ThingId;
const fixtures = @import("fixtures.zig");

test "store distinguishes entity types whose IDs share a slot" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const plane = store.add(fixtures.plane(25));
    const building = store.add(fixtures.building(50));
    const bullet = store.add(fixtures.bullet(75));

    try testing.expectEqual(plane.slot, building.slot);
    try testing.expectEqual(plane.slot, bullet.slot);
    try testing.expect(plane.pool != building.pool);
    try testing.expect(plane.pool != bullet.pool);

    const plane_health = (store.get(fixtures.Plane, plane) orelse return error.MissingEntity).health;
    const building_health = (store.get(fixtures.Building, building) orelse return error.MissingEntity).durability;
    const bullet_motion = (store.get(fixtures.Bullet, bullet) orelse return error.MissingEntity).movement;

    try testing.expectEqual(25, plane_health.current);
    try testing.expectEqual(50, building_health.current);
    try testing.expectEqual(75, bullet_motion.x);
    try testing.expect(store.get(fixtures.Plane, bullet) == null);
    try testing.expect(store.get(fixtures.Plane, building) == null);
}

test "entity lookup returns mutable component pointers and rejects mismatched types" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const id = store.add(fixtures.plane(40));
    const health = (store.get(fixtures.Plane, id) orelse return error.MissingEntity).health;
    health.current -= 13;
    const updated = store.get(fixtures.Plane, id) orelse return error.MissingEntity;

    try testing.expectEqual(27, updated.health.current);

    try testing.expect(store.get(fixtures.Building, id) == null);
}

test "store removal ignores malformed or deleted IDs and isolates pools" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const plane = store.add(fixtures.plane(10));
    const building = store.add(fixtures.building(20));
    const invalid = [_]ThingId{
        .{ .pool = std.math.maxInt(u32), .slot = plane.slot, .generation = plane.generation },
        .{ .pool = plane.pool, .slot = std.math.maxInt(u32), .generation = plane.generation },
        .{ .pool = plane.pool, .slot = plane.slot, .generation = plane.generation + 1 },
    };

    for (0..invalid.len) |index| {
        try testing.expect(store.get(fixtures.Plane, invalid[index]) == null);
        store.remove(invalid[index]);
    }

    store.remove(plane);

    try testing.expect(store.get(fixtures.Plane, plane) == null);
    store.remove(plane);

    const surviving = (store.get(fixtures.Building, building) orelse return error.MissingEntity).durability;

    try testing.expectEqual(20, surviving.current);
}

test "store lookup follows moved entities through later pool growth" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const first = store.add(fixtures.plane(10));
    const second = store.add(fixtures.plane(20));
    const third = store.add(fixtures.plane(30));

    store.remove(first);

    for (0..100) |index| {
        const value: f32 = @floatFromInt(index + 100);
        _ = store.add(fixtures.plane(value));
    }

    const second_health = (store.get(fixtures.Plane, second) orelse return error.MissingEntity).health;
    const third_motion = (store.get(fixtures.Plane, third) orelse return error.MissingEntity).motion;

    try testing.expectEqual(20, second_health.current);
    try testing.expectEqual(30, third_motion.x);
    try testing.expect(store.get(fixtures.Plane, first) == null);
}

test "finishing a parts iterator removes dead things and invalidates their IDs" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const dead_plane = store.add(fixtures.plane(0));
    const living_plane = store.add(fixtures.plane(10));
    const dead_building = store.add(fixtures.building(-1));
    const living_building = store.add(fixtures.building(20));
    const bullet = store.add(fixtures.bullet(30));

    var parts = store.parts(.{ .hp = fixtures.Health });
    defer parts.deinit();

    while (parts.next()) |components| {
        if (components.hp.current <= 0) store.remove(parts.thingId());
    }

    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(1, store.count(fixtures.Building));

    parts.deinit();

    try testing.expect(store.get(fixtures.Plane, dead_plane) == null);
    try testing.expect(store.get(fixtures.Building, dead_building) == null);
    try testing.expect(store.get(fixtures.Plane, living_plane) != null);
    try testing.expect(store.get(fixtures.Building, living_building) != null);
    try testing.expect(store.get(fixtures.Bullet, bullet) != null);

    const replacement = store.add(fixtures.building(99));

    try testing.expectEqual(dead_building.slot, replacement.slot);
    try testing.expect(store.get(fixtures.Building, dead_building) == null);
}

test "removal in an unrelated type is immediate while a parts iterator is active" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const building = store.add(fixtures.building(0));
    const plane = store.add(fixtures.plane(0));
    var parts = store.parts(.{ .motion = fixtures.Motion });
    defer parts.deinit();

    store.remove(building);
    store.remove(plane);

    try testing.expectEqual(0, store.count(fixtures.Building));
    try testing.expectEqual(0, store.count(fixtures.Plane));
    try testing.expect(store.get(fixtures.Plane, plane) == null);

    parts.deinit();
    try testing.expectEqual(0, store.count(fixtures.Plane));
}

test "an old ID cannot remove its replacement after deferred cleanup" {
    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    const removed = store.add(fixtures.plane(10));
    var iterator = store.things(fixtures.Plane);
    defer iterator.deinit();

    store.remove(removed);
    iterator.deinit();
    const replacement = store.add(fixtures.plane(20));
    store.remove(removed);

    try testing.expectEqual(removed.slot, replacement.slot);
    try testing.expect(removed.generation != replacement.generation);
    try testing.expectEqual(1, store.count(fixtures.Plane));
    try testing.expectEqual(20, store.get(fixtures.Plane, replacement).?.health.current);
}

test "mixed store operations agree with a logical thing model" {
    const Record = struct {
        id: ThingId,
        health: f32,
        x: f32,
        live: bool = true,
    };

    var store = fixtures.GameStore.init(testing.allocator);
    defer store.deinit();

    var records: [64]?Record = @splat(null);
    var guard: ?@TypeOf(store.things(fixtures.Plane)) = null;
    defer if (guard) |*iterator| iterator.deinit();
    var prng = std.Random.DefaultPrng.init(0x53484d454353);
    const random = prng.random();

    for (0..1000) |step| {
        const selected = random.uintLessThan(usize, records.len);

        switch (random.uintLessThan(u8, 6)) {
            0 => {
                const can_add = if (records[selected]) |record| !record.live else true;

                if (can_add and guard == null) {
                    const value: f32 = @floatFromInt(step + 1);
                    records[selected] = .{
                        .id = store.add(fixtures.plane(value)),
                        .health = value,
                        .x = value,
                    };
                }
            },

            1 => {
                if (records[selected]) |*record| {
                    if (record.live) {
                        store.remove(record.id);
                        record.live = false;
                    }
                }
            },

            2 => {
                if (records[selected]) |*record| {
                    if (record.live) {
                        if (guard == null) guard = store.things(fixtures.Plane);

                        store.remove(record.id);
                        record.live = false;
                    }
                }
            },

            3 => {
                if (guard) |*iterator| iterator.deinit();
                guard = null;
            },

            4 => {
                if (guard == null) store.reserve(fixtures.Plane, random.uintLessThan(usize, 128) + 1);
            },
            5 => {
                var parts = store.parts(.{ .hp = fixtures.Health, .movement = fixtures.Motion });
                defer parts.deinit();

                while (parts.next()) |components| {
                    components.hp.current += 1;
                    components.movement.x += 2;
                }

                for (0..records.len) |index| {
                    if (records[index]) |*record| {
                        if (record.live) {
                            record.health += 1;
                            record.x += 2;
                        }
                    }
                }
            },
            else => unreachable,
        }

        var expected_count: usize = 0;

        for (0..records.len) |index| {
            if (records[index]) |record| {
                if (record.live) expected_count += 1;

                if (record.live) {
                    const health = (store.get(fixtures.Plane, record.id) orelse return error.MissingEntity).health;
                    const motion = (store.get(fixtures.Plane, record.id) orelse return error.MissingEntity).motion;

                    try testing.expectEqual(record.health, health.current);
                    try testing.expectEqual(record.x, motion.x);
                } else {
                    try testing.expect(store.get(fixtures.Plane, record.id) == null);
                }
            }
        }

        try testing.expectEqual(expected_count, store.count(fixtures.Plane));
    }
}
