const std = @import("std");
const Slot = @import("thing_id.zig").Slot;

pub fn StorageLayout(comptime Entity: type) type {
    const fields = std.meta.fields(Entity);
    const block_alignment = comptime init: {
        var alignment: usize = @max(@alignOf(Slot), @alignOf(usize));

        for (fields) |field| alignment = @max(alignment, @alignOf(field.type));

        break :init alignment;
    };

    return struct {
        const This = @This();

        pub const memory_alignment = block_alignment;

        offsets: [fields.len]usize,
        removal_flags_offset: usize,
        slots_offset: usize,
        dense_to_slot_offset: usize,
        size: usize,

        pub fn calculate(capacity: usize) std.mem.Allocator.Error!This {
            var layout: This = undefined;
            var offset: usize = 0;

            inline for (fields, 0..) |field, index| {
                layout.offsets[index] = try appendRegion(field.type, &offset, capacity);
            }

            layout.slots_offset = try appendRegion(Slot, &offset, capacity);
            layout.dense_to_slot_offset = try appendRegion(usize, &offset, capacity);
            layout.removal_flags_offset = try appendRegion(bool, &offset, capacity);
            layout.size = offset;

            return layout;
        }

        fn appendRegion(comptime Element: type, offset: *usize, capacity: usize) std.mem.Allocator.Error!usize {
            const alignment = @alignOf(Element);
            const misalignment = offset.* % alignment;
            const padding = if (misalignment == 0) 0 else alignment - misalignment;

            const start = std.math.add(usize, offset.*, padding) catch return error.OutOfMemory;
            const size = std.math.mul(usize, @sizeOf(Element), capacity) catch return error.OutOfMemory;
            const end = std.math.add(usize, start, size) catch return error.OutOfMemory;

            offset.* = end;
            return start;
        }
    };
}
