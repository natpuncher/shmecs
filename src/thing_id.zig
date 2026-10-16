const std = @import("std");

pub const ThingId = struct {
    pool: usize,
    slot: usize,
    generation: u64,
};

pub const invalid_index = std.math.maxInt(usize);

pub const Slot = struct {
    dense_index: usize,
    generation: u64 = 1,
    next_free: usize = invalid_index,
};
