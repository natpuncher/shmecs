const std = @import("std");

pub const ThingId = struct {
    pool: u32,
    slot: u32,
    generation: u32,
};

pub const invalid_index = std.math.maxInt(u32);

pub const Slot = struct {
    index: u32,
    generation: u32 = 1,
};
