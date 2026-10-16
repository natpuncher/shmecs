const std = @import("std");
const schema = @import("schema.zig");
const StorageLayout = @import("storage_layout.zig").StorageLayout;
const ThingsIterator = @import("iterators.zig").ThingsIterator;
const identity = @import("thing_id.zig");
const ThingId = identity.ThingId;
const Slot = identity.Slot;
const invalid_index = identity.invalid_index;

pub fn PoolStorage(comptime Entity: type) type {
    comptime schema.validateEntity(Entity);

    const fields = std.meta.fields(Entity);
    const Columns = schema.Columns(Entity);
    const Layout = StorageLayout(Entity);
    const block_alignment = Layout.memory_alignment;

    return struct {
        const This = @This();

        pub const Iterator = ThingsIterator(This, Entity);

        allocator: std.mem.Allocator,
        memory: []align(block_alignment) u8 = &.{},
        columns: Columns = emptyColumns(),
        removal_flags: []bool = &.{},
        slots: []Slot = &.{},
        dense_to_slot: []usize = &.{},
        slot_count: usize = 0,
        free_slot: usize = invalid_index,
        pool_index: usize = 0,
        len: usize = 0,
        capacity: usize = 0,
        active_iterators: usize = 0,
        pending_removals: usize = 0,
        removal_end: usize = 0,

        pub fn init(allocator: std.mem.Allocator) This {
            return .{ .allocator = allocator };
        }

        pub fn deinit(this: *This) void {
            if (this.active_iterators != 0) @panic("Cannot deinitialize a pool with active iterators");

            const pool_index = this.pool_index;
            this.allocator.free(this.memory);
            this.* = .init(this.allocator);
            this.pool_index = pool_index;
        }

        pub fn reserve(this: *This, capacity: usize) std.mem.Allocator.Error!void {
            std.debug.assert(this.active_iterators == 0);
            if (capacity <= this.capacity) return;

            var replacement = try this.allocate(capacity);
            replacement.copyData(this);

            this.allocator.free(this.memory);
            this.* = replacement;
        }

        pub fn copyFrom(this: *This, source: *const This) std.mem.Allocator.Error!void {
            std.debug.assert(this.active_iterators == 0 and source.active_iterators == 0);
            if (this == source) return;

            if (source.slot_count > this.capacity) {
                var replacement = try this.allocate(try this.growthCapacity(source.slot_count));
                replacement.copyData(source);

                this.allocator.free(this.memory);
                this.* = replacement;
                return;
            }

            this.copyData(source);
        }

        pub fn append(this: *This, entity: Entity) std.mem.Allocator.Error!ThingId {
            std.debug.assert(this.active_iterators == 0);

            if (this.free_slot == invalid_index and this.slot_count == this.capacity) {
                const required = std.math.add(usize, this.slot_count, 1) catch return error.OutOfMemory;
                try this.reserve(try this.growthCapacity(required));
            }

            const slot_index = if (this.free_slot != invalid_index) this.free_slot else this.slot_count;

            if (this.free_slot != invalid_index) {
                this.free_slot = this.slots[slot_index].next_free;
            } else {
                this.slots[slot_index] = .{ .dense_index = this.len };
                this.slot_count += 1;
            }

            const index = this.len;

            inline for (fields, 0..) |field, column_index| {
                this.columns[column_index][index] = @field(entity, field.name);
            }

            this.removal_flags[index] = false;
            this.slots[slot_index].dense_index = index;
            this.slots[slot_index].next_free = invalid_index;
            this.dense_to_slot[index] = slot_index;
            this.len += 1;

            return .{
                .pool = this.pool_index,
                .slot = slot_index,
                .generation = this.slots[slot_index].generation,
            };
        }

        pub fn indexOf(this: *const This, id: ThingId) ?usize {
            if (id.pool != this.pool_index or id.slot >= this.slot_count) return null;

            const slot = this.slots[id.slot];
            if (slot.generation != id.generation or slot.dense_index >= this.len) return null;
            if (this.removal_flags[slot.dense_index]) return null;

            return slot.dense_index;
        }

        pub fn remove(this: *This, id: ThingId) void {
            const index = this.indexOf(id) orelse return;

            if (this.active_iterators != 0) {
                this.removal_flags[index] = true;
                this.pending_removals += 1;
                this.removal_end = @max(this.removal_end, index + 1);
                return;
            }

            this.removeAt(index);
        }

        pub fn components(this: *This, comptime Component: type) []Component {
            const index = comptime schema.fieldIndex(Entity, Component);
            return this.columns[index][0..this.len];
        }

        pub fn iterator(this: *This) Iterator {
            return .init(this);
        }

        pub fn releaseIterator(this: *This) void {
            std.debug.assert(this.active_iterators != 0);
            this.active_iterators -= 1;

            if (this.active_iterators == 0) this.flushRemovals();
        }

        fn flushRemovals(this: *This) void {
            if (this.pending_removals == 0) return;

            if (this.pending_removals == this.len) {
                this.removeAll();
            } else {
                var index = this.removal_end;
                var remaining = this.pending_removals;

                while (remaining != 0) {
                    index -= 1;

                    if (!this.removal_flags[index]) continue;

                    this.removeAt(index);
                    remaining -= 1;
                }
            }

            this.pending_removals = 0;
            this.removal_end = 0;
        }

        fn growthCapacity(this: *const This, required: usize) std.mem.Allocator.Error!usize {
            const increment = @max(this.capacity / 2, 8);
            const capacity = std.math.add(usize, this.capacity, increment) catch return error.OutOfMemory;

            return @max(required, capacity);
        }

        fn allocate(this: *const This, capacity: usize) std.mem.Allocator.Error!This {
            const layout = try Layout.calculate(capacity);
            const memory = try this.allocator.alignedAlloc(u8, .fromByteUnits(block_alignment), layout.size);
            var storage = This.init(this.allocator);

            storage.memory = memory;
            storage.capacity = capacity;
            storage.pool_index = this.pool_index;

            inline for (fields, 0..) |field, index| {
                const pointer: [*]field.type = @ptrCast(@alignCast(memory.ptr + layout.offsets[index]));
                storage.columns[index] = pointer[0..capacity];
            }

            const removal_flags_pointer: [*]bool = @ptrCast(memory.ptr + layout.removal_flags_offset);
            storage.removal_flags = removal_flags_pointer[0..capacity];

            const slot_pointer: [*]Slot = @ptrCast(@alignCast(memory.ptr + layout.slots_offset));
            storage.slots = slot_pointer[0..capacity];

            const dense_to_slot_pointer: [*]usize = @ptrCast(@alignCast(memory.ptr + layout.dense_to_slot_offset));
            storage.dense_to_slot = dense_to_slot_pointer[0..capacity];

            return storage;
        }

        fn copyData(this: *This, source: *const This) void {
            inline for (fields, 0..) |_, index| {
                @memcpy(this.columns[index][0..source.len], source.columns[index][0..source.len]);
            }

            @memcpy(this.slots[0..source.slot_count], source.slots[0..source.slot_count]);
            @memcpy(this.dense_to_slot[0..source.len], source.dense_to_slot[0..source.len]);
            @memcpy(this.removal_flags[0..source.len], source.removal_flags[0..source.len]);

            this.len = source.len;
            this.slot_count = source.slot_count;
            this.free_slot = source.free_slot;
        }

        fn emptyColumns() Columns {
            var columns: Columns = undefined;

            for (fields, 0..) |_, index| columns[index] = &.{};

            return columns;
        }

        fn removeAt(this: *This, index: usize) void {
            const slot_index = this.dense_to_slot[index];
            const last = this.len - 1;

            if (index != last) {
                inline for (fields, 0..) |_, column_index| {
                    this.columns[column_index][index] = this.columns[column_index][last];
                }

                const moved_slot = this.dense_to_slot[last];
                this.dense_to_slot[index] = moved_slot;
                this.slots[moved_slot].dense_index = index;
                this.removal_flags[index] = this.removal_flags[last];
            }

            this.removal_flags[last] = false;
            this.len = last;
            this.free_slot = recycleSlot(&this.slots[slot_index], slot_index, this.free_slot);
        }

        fn removeAll(this: *This) void {
            var index = this.len;
            var free_slot = this.free_slot;

            while (index != 0) {
                index -= 1;
                const slot_index = this.dense_to_slot[index];
                free_slot = recycleSlot(&this.slots[slot_index], slot_index, free_slot);
            }

            @memset(this.removal_flags[0..this.len], false);
            this.len = 0;
            this.free_slot = free_slot;
        }

        fn recycleSlot(slot: *Slot, slot_index: usize, free_slot: usize) usize {
            slot.dense_index = invalid_index;
            if (slot.generation == std.math.maxInt(u64)) return free_slot;

            slot.generation += 1;
            slot.next_free = free_slot;
            return slot_index;
        }
    };
}
