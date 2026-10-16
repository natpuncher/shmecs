const std = @import("std");
const testing = std.testing;
const World = @import("../world.zig").World;
const EntityId = @import("../entity_id.zig").EntityId;
const fixtures = @import("fixtures.zig");

test "world distinguishes entity types whose IDs share a slot" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const plane = try world.add(fixtures.plane(25));
    const building = try world.add(fixtures.building(50));
    const bullet = try world.add(fixtures.bullet(75));

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

    const id = try world.add(fixtures.plane(40));
    const health = (world.get(fixtures.Plane, id) orelse return error.MissingEntity).health;
    health.current -= 13;
    const pool = world.pool(fixtures.Plane);

    try testing.expectEqual(27, pool.components(fixtures.Health)[0].current);

    try testing.expect(world.get(fixtures.Building, id) == null);
}

test "world removal isolates pools and rejects malformed or deleted IDs" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const plane = try world.add(fixtures.plane(10));
    const building = try world.add(fixtures.building(20));
    const invalid = [_]EntityId{
        .{ .pool = std.math.maxInt(usize), .slot = plane.slot, .generation = plane.generation },
        .{ .pool = plane.pool, .slot = std.math.maxInt(usize), .generation = plane.generation },
        .{ .pool = plane.pool, .slot = plane.slot, .generation = plane.generation + 1 },
    };

    for (0..invalid.len) |index| {
        try testing.expect(world.get(fixtures.Plane, invalid[index]) == null);
        try testing.expectError(error.InvalidEntity, world.remove(invalid[index]));
    }

    try world.remove(plane);

    try testing.expect(world.get(fixtures.Plane, plane) == null);
    try testing.expectError(error.InvalidEntity, world.remove(plane));

    const surviving = (world.get(fixtures.Building, building) orelse return error.MissingEntity).durability;

    try testing.expectEqual(20, surviving.current);
}

test "world lookup follows moved entities through later pool growth" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const first = try world.add(fixtures.plane(10));
    const second = try world.add(fixtures.plane(20));
    const third = try world.add(fixtures.plane(30));

    try world.remove(first);

    for (0..100) |index| {
        const value: f32 = @floatFromInt(index + 100);
        _ = try world.add(fixtures.plane(value));
    }

    const second_health = (world.get(fixtures.Plane, second) orelse return error.MissingEntity).health;
    const third_motion = (world.get(fixtures.Plane, third) orelse return error.MissingEntity).motion;

    try testing.expectEqual(20, second_health.current);
    try testing.expectEqual(30, third_motion.x);
    try testing.expect(world.get(fixtures.Plane, first) == null);
}

test "world flush removes marked entities across pools and invalidates their IDs" {
    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    const dead_plane = try world.add(fixtures.plane(0));
    const living_plane = try world.add(fixtures.plane(10));
    const dead_building = try world.add(fixtures.building(-1));
    const living_building = try world.add(fixtures.building(20));
    const bullet = try world.add(fixtures.bullet(30));

    var query = world.query(.{ .hp = fixtures.Health });
    defer query.deinit();

    while (query.next()) |components| {
        if (components.hp.current <= 0) try query.markForRemoval();
    }

    try testing.expect(world.get(fixtures.Plane, dead_plane) != null);
    try testing.expect(world.get(fixtures.Building, dead_building) != null);

    query.deinit();

    try testing.expectEqual(2, try world.flushRemovals());
    try testing.expectEqual(0, try world.flushRemovals());
    try testing.expect(world.get(fixtures.Plane, dead_plane) == null);
    try testing.expect(world.get(fixtures.Building, dead_building) == null);
    try testing.expect(world.get(fixtures.Plane, living_plane) != null);
    try testing.expect(world.get(fixtures.Building, living_building) != null);
    try testing.expect(world.get(fixtures.Bullet, bullet) != null);

    const replacement = try world.add(fixtures.building(99));

    try testing.expectEqual(dead_building.slot, replacement.slot);
    try testing.expect(world.get(fixtures.Building, dead_building) == null);
}

test "blocked world flush leaves earlier unlocked pools untouched" {
    const GameWorld = World(.{ fixtures.Building, fixtures.Plane, fixtures.Bullet });

    var world = GameWorld.init(testing.allocator);
    defer world.deinit();

    const building = try world.add(fixtures.building(0));
    const plane = try world.add(fixtures.plane(0));

    try world.markForRemoval(building);
    try world.markForRemoval(plane);

    var query = world.query(.{ .motion = fixtures.Motion });
    defer query.deinit();

    try testing.expectError(error.PoolInUse, world.flushRemovals());
    try testing.expect(world.get(fixtures.Building, building) != null);
    try testing.expect(world.get(fixtures.Plane, plane) != null);

    query.deinit();

    try testing.expectEqual(2, try world.flushRemovals());
    try testing.expect(world.get(fixtures.Building, building) == null);
    try testing.expect(world.get(fixtures.Plane, plane) == null);
}

test "failed world insertion leaves other pools intact and can be retried" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var world = fixtures.GameWorld.init(failing.allocator());
    defer world.deinit();

    const plane = try world.add(fixtures.plane(10));

    try testing.expectError(error.OutOfMemory, world.add(fixtures.building(20)));
    try testing.expectEqual(0, world.pool(fixtures.Building).len());

    const health = (world.get(fixtures.Plane, plane) orelse return error.MissingEntity).health;

    try testing.expectEqual(10, health.current);

    failing.fail_index = std.math.maxInt(usize);
    const building = try world.add(fixtures.building(20));

    try testing.expect(world.get(fixtures.Building, building) != null);
}

test "mixed world operations agree with a logical entity model" {
    const Record = struct {
        id: EntityId,
        health: f32,
        x: f32,
        live: bool = true,
        pending: bool = false,
    };

    var world = fixtures.GameWorld.init(testing.allocator);
    defer world.deinit();

    var records: [64]?Record = @splat(null);
    var prng = std.Random.DefaultPrng.init(0x53484d454353);
    const random = prng.random();

    for (0..1000) |step| {
        const selected = random.uintLessThan(usize, records.len);

        switch (random.uintLessThan(u8, 6)) {
            0 => {
                const can_add = if (records[selected]) |record| !record.live else true;

                if (can_add) {
                    const value: f32 = @floatFromInt(step + 1);
                    records[selected] = .{
                        .id = try world.add(fixtures.plane(value)),
                        .health = value,
                        .x = value,
                    };
                }
            },

            1 => {
                if (records[selected]) |*record| {
                    if (record.live) {
                        try world.remove(record.id);
                        record.live = false;
                        record.pending = false;
                    }
                }
            },

            2 => {
                if (records[selected]) |*record| {
                    if (record.live) {
                        try world.markForRemoval(record.id);
                        record.pending = true;
                    }
                }
            },

            3 => {
                const removed = try world.flushRemovals();
                var expected: usize = 0;

                for (0..records.len) |index| {
                    if (records[index]) |*record| {
                        if (record.live and record.pending) {
                            record.live = false;
                            record.pending = false;
                            expected += 1;
                        }
                    }
                }

                try testing.expectEqual(expected, removed);
            },

            4 => try world.pool(fixtures.Plane).reserve(random.uintLessThan(usize, 128) + 1),
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
                if (record.live) {
                    expected_count += 1;
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
