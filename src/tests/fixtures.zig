pub const Health = struct { current: f32, maximum: f32 };
pub const Motion = struct { x: f32, velocity: f32 };
pub const Weapon = struct { ammunition: u32 };
pub const Appearance = struct { sprite: u32 };

pub const Plane = struct {
    health: Health,
    motion: Motion,
    weapon: Weapon,
};

pub const Building = struct {
    durability: Health,
    appearance: Appearance,
};

pub const Bullet = struct {
    movement: Motion,
    appearance: Appearance,
};

pub const GameWorld = @import("../world.zig").World(.{ Plane, Building, Bullet });

pub fn plane(value: f32) Plane {
    return .{
        .health = .{ .current = value, .maximum = 100 },
        .motion = .{ .x = value, .velocity = 2 },
        .weapon = .{ .ammunition = 9 },
    };
}

pub fn building(value: f32) Building {
    return .{
        .durability = .{ .current = value, .maximum = 200 },
        .appearance = .{ .sprite = 77 },
    };
}

pub fn bullet(value: f32) Bullet {
    return .{
        .movement = .{ .x = value, .velocity = 10 },
        .appearance = .{ .sprite = 99 },
    };
}

pub fn planeAt(pool: anytype, index: usize) ?Plane {
    if (index >= pool.len) return null;

    return .{
        .health = pool.components(Health)[index],
        .motion = pool.components(Motion)[index],
        .weapon = pool.components(Weapon)[index],
    };
}

pub fn markAt(pool: anytype, index: usize) !void {
    var iterator = pool.iterator();
    defer iterator.deinit();

    for (0..index) |_| {
        _ = iterator.next() orelse return error.MissingEntity;
    }

    _ = iterator.next() orelse return error.MissingEntity;
    try iterator.markForRemoval();
}
