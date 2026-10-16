const std = @import("std");
const shmecs = @import("shmecs");

const Health = struct { current: f32, maximum: f32 };
const Motion = struct { x: f32, y: f32, velocity_x: f32, velocity_y: f32 };
const Weapon = struct { cooldown: f32, ammunition: u32 };
const Appearance = struct { sprite: u32 };

const Plane = struct {
    health: Health,
    motion: Motion,
    weapon: Weapon,
    appearance: Appearance,
};

const Building = struct {
    health: Health,
    appearance: Appearance,
};

const Bullet = struct {
    motion: Motion,
    appearance: Appearance,
};

const GameWorld = shmecs.World(.{ Plane, Building, Bullet });

pub fn main() !void {
    var world = GameWorld.init(std.heap.page_allocator);
    defer world.deinit();

    try world.pool(Plane).reserve(64);

    const plane_id = try world.add(Plane{
        .health = .{ .current = 50, .maximum = 100 },
        .motion = .{ .x = 0, .y = 0, .velocity_x = 10, .velocity_y = 0 },
        .weapon = .{ .cooldown = 0, .ammunition = 20 },
        .appearance = .{ .sprite = 1 },
    });
    const building_id = try world.add(Building{
        .health = .{ .current = 150, .maximum = 200 },
        .appearance = .{ .sprite = 2 },
    });
    const bullet_id = try world.add(Bullet{
        .motion = .{ .x = 5, .y = 0, .velocity_x = 100, .velocity_y = 0 },
        .appearance = .{ .sprite = 3 },
    });

    regenerate(&world, 5);
    move(&world, 0.016);
    updatePlanes(&world, 0.016);

    if (world.get(Plane, plane_id)) |plane| {
        std.debug.print("Plane: hp={d}/{d}\n", .{ plane.health.current, plane.health.maximum });
    }

    if (world.get(Building, building_id)) |building| building.health.current -= 10;
    try world.markForRemoval(bullet_id);

    try markDestroyed(&world);
    const removed = try world.flushRemovals();
    std.debug.print("Removed: {d}, planes: {d}\n", .{ removed, world.pool(Plane).len() });
}

fn regenerate(world: *GameWorld, amount: f32) void {
    var query = world.query(.{ .health = Health });
    defer query.deinit();

    while (query.next()) |components| {
        const health = components.health;
        health.current = @min(health.maximum, health.current + amount);

        if (query.id()) |id| {
            std.debug.print("Entity {d}:{d}: hp={d}\n", .{ id.pool, id.slot, health.current });
        }
    }
}

fn move(world: *GameWorld, delta: f32) void {
    var query = world.query(.{ .motion = Motion });
    defer query.deinit();

    while (query.next()) |components| {
        components.motion.x += components.motion.velocity_x * delta;
        components.motion.y += components.motion.velocity_y * delta;
    }
}

fn updatePlanes(world: *GameWorld, delta: f32) void {
    var planes = world.pool(Plane).iterator();
    defer planes.deinit();

    while (planes.next()) |plane| {
        if (plane.health.current <= 0) {
            plane.motion.velocity_x = 0;
            plane.motion.velocity_y = 0;
        }

        plane.weapon.cooldown = @max(0, plane.weapon.cooldown - delta);
    }
}

fn markDestroyed(world: *GameWorld) !void {
    var query = world.query(.{ .health = Health });
    defer query.deinit();

    while (query.next()) |components| {
        if (components.health.current <= 0) try query.markForRemoval();
    }
}
