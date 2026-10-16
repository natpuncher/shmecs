const std = @import("std");
const testing = std.testing;
const ThingId = @import("../thing_id.zig").ThingId;
const fixtures = @import("fixtures.zig");

test "world distinguishes entity types whose IDs share a slot" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const plane = world.add(fixtures.plane(25));
    const building = world.add(fixtures.building(50));
    const bullet = world.add(fixtures.bullet(75));

    try testing.expectEqual(plane.slot, building.slot);
    try testing.expectEqual(plane.slot, bullet.slot);
    try testing.expect(plane.pool != building.pool);
    try testing.expect(plane.pool != bullet.pool);

    const plane_health = (world.get(fixtures.Plane, plane) orelse return error.MissingEntity).health;
    const building_health = (world.get(fixtures.Building, building) orelse return error.MissingEntity).durability;
    const bullet_motion = (world.get(fixtures.Bullet, bullet) orelse return error.MissingEntity).movement;

    try testing.expectEqual(25, plane_health.current);
    try testing.expectEqual(50, building_health.current);
    try testing.expectEqual(75, bullet_motion.x);
    try testing.expect(world.get(fixtures.Plane, bullet) == null);
    try testing.expect(world.get(fixtures.Plane, building) == null);
}

test "entity lookup returns mutable component pointers and rejects mismatched types" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const id = world.add(fixtures.plane(40));
    const health = (world.get(fixtures.Plane, id) orelse return error.MissingEntity).health;
    health.current -= 13;
    const pool = world.pool(fixtures.Plane);

    try testing.expectEqual(27, pool.components(fixtures.Health)[0].current);

    try testing.expect(world.get(fixtures.Building, id) == null);
}

test "world removal ignores malformed or deleted IDs and isolates pools" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const plane = world.add(fixtures.plane(10));
    const building = world.add(fixtures.building(20));
    const invalid = [_]ThingId{
        .{ .pool = std.math.maxInt(usize), .slot = plane.slot, .generation = plane.generation },
        .{ .pool = plane.pool, .slot = std.math.maxInt(usize), .generation = plane.generation },
        .{ .pool = plane.pool, .slot = plane.slot, .generation = plane.generation + 1 },
    };

    for (0..invalid.len) |index| {
        try testing.expect(world.get(fixtures.Plane, invalid[index]) == null);
        world.remove(invalid[index]);
    }

    world.remove(plane);

    try testing.expect(world.get(fixtures.Plane, plane) == null);
    world.remove(plane);

    const surviving = (world.get(fixtures.Building, building) orelse return error.MissingEntity).durability;

    try testing.expectEqual(20, surviving.current);
}

test "world lookup follows moved entities through later pool growth" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const first = world.add(fixtures.plane(10));
    const second = world.add(fixtures.plane(20));
    const third = world.add(fixtures.plane(30));

    world.remove(first);

    for (0..100) |index| {
        const value: f32 = @floatFromInt(index + 100);
        _ = world.add(fixtures.plane(value));
    }

    const second_health = (world.get(fixtures.Plane, second) orelse return error.MissingEntity).health;
    const third_motion = (world.get(fixtures.Plane, third) orelse return error.MissingEntity).motion;

    try testing.expectEqual(20, second_health.current);
    try testing.expectEqual(30, third_motion.x);
    try testing.expect(world.get(fixtures.Plane, first) == null);
}

test "finishing a query removes dead entities across pools and invalidates their IDs" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const dead_plane = world.add(fixtures.plane(0));
    const living_plane = world.add(fixtures.plane(10));
    const dead_building = world.add(fixtures.building(-1));
    const living_building = world.add(fixtures.building(20));
    const bullet = world.add(fixtures.bullet(30));

    var query = world.query(.{ .hp = fixtures.Health });
    defer query.deinit();

    while (query.next()) |components| {
        if (components.hp.current <= 0) world.remove(query.thingId());
    }

    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
    try testing.expectEqual(1, world.pool(fixtures.Building).len());

    query.deinit();

    try testing.expect(world.get(fixtures.Plane, dead_plane) == null);
    try testing.expect(world.get(fixtures.Building, dead_building) == null);
    try testing.expect(world.get(fixtures.Plane, living_plane) != null);
    try testing.expect(world.get(fixtures.Building, living_building) != null);
    try testing.expect(world.get(fixtures.Bullet, bullet) != null);

    const replacement = world.add(fixtures.building(99));

    try testing.expectEqual(dead_building.slot, replacement.slot);
    try testing.expect(world.get(fixtures.Building, dead_building) == null);
}

test "removal is immediate outside a query even when another pool is occupied" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const building = world.add(fixtures.building(0));
    const plane = world.add(fixtures.plane(0));
    var query = world.query(.{ .motion = fixtures.Motion });
    defer query.deinit();

    world.remove(building);
    world.remove(plane);

    try testing.expectEqual(0, world.pool(fixtures.Building).len());
    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
    try testing.expect(world.get(fixtures.Plane, plane) == null);

    query.deinit();
    try testing.expectEqual(0, world.pool(fixtures.Plane).len());
}

test "an old ID cannot remove its replacement after deferred cleanup" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const removed = world.add(fixtures.plane(10));
    var iterator = world.pool(fixtures.Plane).iterator();
    defer iterator.deinit();

    world.remove(removed);
    iterator.deinit();
    const replacement = world.add(fixtures.plane(20));
    world.remove(removed);

    try testing.expectEqual(removed.slot, replacement.slot);
    try testing.expect(removed.generation != replacement.generation);
    try testing.expectEqual(1, world.pool(fixtures.Plane).len());
    try testing.expectEqual(20, world.get(fixtures.Plane, replacement).?.health.current);
}

test "mixed world operations agree with a logical entity model" {
    const Record = struct {
        id: ThingId,
        health: f32,
        x: f32,
        live: bool = true,
        pending: bool = false,
    };

    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    var records: [64]?Record = @splat(null);
    var guard: ?@TypeOf(world.pool(fixtures.Plane).iterator()) = null;
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
                        .id = world.add(fixtures.plane(value)),
                        .health = value,
                        .x = value,
                    };
                }
            },

            1 => {
                if (records[selected]) |*record| {
                    if (record.live) {
                        world.remove(record.id);
                        record.live = false;
                        record.pending = guard != null;
                    }
                }
            },

            2 => {
                if (records[selected]) |*record| {
                    if (record.live) {
                        if (guard == null) guard = world.pool(fixtures.Plane).iterator();

                        world.remove(record.id);
                        record.live = false;
                        record.pending = true;
                    }
                }
            },

            3 => {
                if (guard) |*iterator| iterator.deinit();
                guard = null;

                for (0..records.len) |index| {
                    if (records[index]) |*record| record.pending = false;
                }
            },

            4 => {
                if (guard == null) world.pool(fixtures.Plane).reserve(random.uintLessThan(usize, 128) + 1);
            },
            5 => {
                var query = world.query(.{ .hp = fixtures.Health, .movement = fixtures.Motion });
                defer query.deinit();

                while (query.next()) |components| {
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
                if (record.live or record.pending) expected_count += 1;

                if (record.live) {
                    const health = (world.get(fixtures.Plane, record.id) orelse return error.MissingEntity).health;
                    const motion = (world.get(fixtures.Plane, record.id) orelse return error.MissingEntity).motion;

                    try testing.expectEqual(record.health, health.current);
                    try testing.expectEqual(record.x, motion.x);
                } else {
                    try testing.expect(world.get(fixtures.Plane, record.id) == null);
                }
            }
        }

        try testing.expectEqual(expected_count, world.pool(fixtures.Plane).len());
    }
}
