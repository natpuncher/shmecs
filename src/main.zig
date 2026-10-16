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

const GameStore = shmecs.Store(.{ Plane, Building, Bullet });

pub fn main() void {
    var store = GameStore.init(std.heap.page_allocator);
    defer store.deinit();

    store.reserve(Plane, 64);

    const initial_plane = Plane{
        .health = .{ .current = 50, .maximum = 100 },
        .motion = .{ .x = 0, .y = 0, .velocity_x = 10, .velocity_y = 0 },
        .weapon = .{ .cooldown = 0, .ammunition = 20 },
        .appearance = .{ .sprite = 1 },
    };

    const initial_building = Building{
        .health = .{ .current = 150, .maximum = 200 },
        .appearance = .{ .sprite = 2 },
    };

    const initial_bullet = Bullet{
        .motion = .{ .x = 5, .y = 0, .velocity_x = 100, .velocity_y = 0 },
        .appearance = .{ .sprite = 3 },
    };

    const plane_id = store.add(initial_plane);
    const building_id = store.add(initial_building);
    const bullet_id = store.add(initial_bullet);

    const dt = 0.016;
    const regen = 5;

    regenerate(&store, regen);
    move(&store, dt);
    updatePlanes(&store, dt);

    if (store.get(Plane, plane_id)) |plane| {
        std.debug.print("Plane: hp={d}/{d}\n", .{ plane.health.current, plane.health.maximum });
    }

    if (store.get(Building, building_id)) |building| {
        building.health.current -= 10;
    }
    store.remove(bullet_id);

    var parts = store.parts(.{ .health = Health });
    defer parts.deinit();

    while (parts.next()) |part| {
        if (part.health.current <= 0) {
            store.remove(parts.thingId());
        }
    }

    std.debug.print("Planes: {d}, bullets: {d}\n", .{ store.count(Plane), store.count(Bullet) });
}

fn regenerate(store: *GameStore, amount: f32) void {
    var parts = store.parts(.{ .health = Health });
    defer parts.deinit();

    while (parts.next()) |part| {
        const health = part.health;
        health.current = @min(health.maximum, health.current + amount);

        const id = parts.thingId();
        std.debug.print("Entity {d}:{d}: hp={d}\n", .{ id.pool, id.slot, health.current });
    }
}

fn move(store: *GameStore, delta: f32) void {
    var parts = store.parts(.{ .motion = Motion });
    defer parts.deinit();

    while (parts.next()) |part| {
        part.motion.x += part.motion.velocity_x * delta;
        part.motion.y += part.motion.velocity_y * delta;
    }
}

fn updatePlanes(store: *GameStore, delta: f32) void {
    var planes = store.things(Plane);
    defer planes.deinit();

    while (planes.next()) |plane| {
        if (plane.health.current <= 0) {
            plane.motion.velocity_x = 0;
            plane.motion.velocity_y = 0;
        }

        plane.weapon.cooldown = @max(0, plane.weapon.cooldown - delta);
    }
}
