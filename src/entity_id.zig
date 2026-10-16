const std = @import("std");

pub const EntityId = struct {
    pool: usize,
    slot: usize,
    generation: u64,
};

pub const vacant_index = std.math.maxInt(usize);

pub const Slot = struct {
    dense_index: usize,
    generation: u64 = 1,
    next_free: usize = vacant_index,
};
