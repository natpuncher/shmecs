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
        const PendingAddition = struct {
            thing: Entity,
            slot: u32,
            generation: u32,
            canceled: bool = false,
        };

        pub const Iterator = ThingsIterator(This, Entity);

        allocator: std.mem.Allocator,
        memory: []align(block_alignment) u8 = &.{},
        columns: Columns = emptyColumns(),
        removal_flags: []bool = &.{},
        slots: []Slot = &.{},
        dense_to_slot: []u32 = &.{},
        slot_count: usize = 0,
        free_slot: u32 = invalid_index,
        pool_index: u32 = 0,
        len: usize = 0,
        capacity: usize = 0,
        active_iterators: usize = 0,
        pending_removals: usize = 0,
        removal_end: usize = 0,
        pending_additions: std.ArrayList(PendingAddition) = .empty,
        pending_slots: std.ArrayList(Slot) = .empty,

        pub fn init(allocator: std.mem.Allocator) This {
            return .{ .allocator = allocator };
        }

        pub fn deinit(this: *This) void {
            if (this.active_iterators != 0) @panic("Cannot deinitialize a pool with active iterators");

            const pool_index = this.pool_index;
            this.allocator.free(this.memory);
            this.pending_additions.deinit(this.allocator);
            this.pending_slots.deinit(this.allocator);
            this.* = .init(this.allocator);
            this.pool_index = pool_index;
        }

        pub fn reserve(this: *This, capacity: usize) std.mem.Allocator.Error!void {
            if (this.active_iterators != 0) @panic("Cannot reserve a pool with active iterators");

            if (capacity <= this.capacity) return;

            var replacement = try this.allocate(capacity);
            replacement.copyData(this);

            this.replace(replacement);
        }

        pub fn copyFrom(this: *This, source: *const This) std.mem.Allocator.Error!void {
            if (this.active_iterators != 0 or source.active_iterators != 0)
                @panic("Cannot copy pools with active iterators");

            if (this == source) return;

            if (source.slot_count > this.capacity) {
                var replacement = try this.allocate(try this.growthCapacity(source.slot_count));
                replacement.copyData(source);

                this.replace(replacement);
                return;
            }

            this.copyData(source);
        }

        pub fn append(this: *This, entity: Entity) std.mem.Allocator.Error!ThingId {
            if (this.active_iterators != 0) return this.deferAppend(entity);

            if (this.free_slot == invalid_index and this.slot_count == this.capacity) {
                const required = std.math.add(usize, this.slot_count, 1) catch return error.OutOfMemory;
                try this.reserve(try this.growthCapacity(required));
            }

            const slot_index: u32 = if (this.free_slot != invalid_index) this.free_slot else @intCast(this.slot_count);

            if (this.free_slot != invalid_index) {
                this.free_slot = this.slots[slot_index].index;
            } else {
                this.slots[slot_index] = .{ .index = @intCast(this.len) };
                this.slot_count += 1;
            }

            this.appendRow(entity, slot_index);

            return .{
                .pool = this.pool_index,
                .slot = slot_index,
                .generation = this.slots[slot_index].generation,
            };
        }

        fn appendRow(this: *This, entity: Entity, slot_index: u32) void {
            const index = this.len;

            inline for (fields, 0..) |field, column_index| {
                this.columns[column_index][index] = @field(entity, field.name);
            }

            this.removal_flags[index] = false;
            this.slots[slot_index].index = @intCast(index);
            this.dense_to_slot[index] = slot_index;
            this.len += 1;
        }

        pub fn indexOf(this: *const This, id: ThingId) ?usize {
            if (id.pool != this.pool_index or id.slot >= this.slot_count) return null;

            const slot = this.slots[id.slot];
            if (slot.generation != id.generation or slot.index >= this.len) return null;
            if (this.dense_to_slot[slot.index] != id.slot or this.removal_flags[slot.index]) return null;

            return slot.index;
        }

        pub fn remove(this: *This, id: ThingId) void {
            const index = this.indexOf(id) orelse {
                this.cancelAddition(id);
                return;
            };

            if (this.active_iterators != 0) {
                this.removal_flags[index] = true;
                this.pending_removals += 1;
                this.removal_end = @max(this.removal_end, index + 1);
                return;
            }

            this.removeAt(index);
        }

        pub fn clear(this: *This) void {
            this.cancelAdditions();

            if (this.active_iterators == 0) {
                this.removeAll();
                return;
            }

            @memset(this.removal_flags[0..this.len], true);
            this.pending_removals = this.len;
            this.removal_end = this.len;
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

            if (this.active_iterators == 0) {
                this.flushRemovals();

                if (this.pending_additions.items.len != 0 or this.pending_slots.items.len != 0)
                    this.flushAdditions() catch @panic("Out of memory");
            }
        }

        noinline fn deferAppend(this: *This, entity: Entity) std.mem.Allocator.Error!ThingId {
            if (this.pending_additions.items.len == invalid_index) return error.OutOfMemory;
            if (this.free_slot == invalid_index and this.pending_slots.items.len >= invalid_index - this.slot_count)
                return error.OutOfMemory;

            try this.pending_additions.ensureUnusedCapacity(this.allocator, 1);

            const slot_index: u32 = if (this.free_slot != invalid_index) this.free_slot else index: {
                const next: u32 = @intCast(this.slot_count + this.pending_slots.items.len);
                try this.pending_slots.append(this.allocator, .{ .index = invalid_index });
                break :index next;
            };
            const slot = this.slotFor(slot_index).?;

            if (this.free_slot != invalid_index) this.free_slot = slot.index;

            slot.index = @intCast(this.pending_additions.items.len);
            this.pending_additions.appendAssumeCapacity(.{
                .thing = entity,
                .slot = slot_index,
                .generation = slot.generation,
            });

            return .{ .pool = this.pool_index, .slot = slot_index, .generation = slot.generation };
        }

        fn slotFor(this: *This, index: u32) ?*Slot {
            if (index < this.slot_count) return &this.slots[index];

            const pending_index = index - this.slot_count;
            if (pending_index >= this.pending_slots.items.len) return null;

            return &this.pending_slots.items[pending_index];
        }

        fn cancelAddition(this: *This, id: ThingId) void {
            if (id.pool != this.pool_index or this.pending_additions.items.len == 0) return;

            const slot = this.slotFor(id.slot) orelse return;
            if (slot.generation != id.generation or slot.index >= this.pending_additions.items.len) return;

            const addition = &this.pending_additions.items[slot.index];
            if (addition.canceled or addition.slot != id.slot or addition.generation != id.generation) return;

            addition.canceled = true;
            this.free_slot = recycleSlot(slot, id.slot, this.free_slot);
        }

        fn cancelAdditions(this: *This) void {
            for (this.pending_additions.items) |addition| {
                if (!addition.canceled) {
                    const slot = this.slotFor(addition.slot).?;
                    this.free_slot = recycleSlot(slot, addition.slot, this.free_slot);
                }
            }

            this.pending_additions.clearRetainingCapacity();
        }

        noinline fn flushAdditions(this: *This) std.mem.Allocator.Error!void {
            const required = this.slot_count + this.pending_slots.items.len;
            if (required > this.capacity) try this.reserve(try this.growthCapacity(required));

            @memcpy(this.slots[this.slot_count..required], this.pending_slots.items);
            this.slot_count = required;
            this.pending_slots.clearRetainingCapacity();

            for (this.pending_additions.items) |addition| {
                if (!addition.canceled) this.appendRow(addition.thing, addition.slot);
            }

            this.pending_additions.clearRetainingCapacity();
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
            if (required > invalid_index) return error.OutOfMemory;

            const increment = @max(this.capacity / 2, 8);
            const capacity = @min(this.capacity +| increment, invalid_index);

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

            const dense_to_slot_pointer: [*]u32 = @ptrCast(@alignCast(memory.ptr + layout.dense_to_slot_offset));
            storage.dense_to_slot = dense_to_slot_pointer[0..capacity];

            return storage;
        }

        fn replace(this: *This, replacement: This) void {
            const pending_additions = this.pending_additions;
            const pending_slots = this.pending_slots;
            this.allocator.free(this.memory);
            this.* = replacement;
            this.pending_additions = pending_additions;
            this.pending_slots = pending_slots;
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
                this.slots[moved_slot].index = @intCast(index);
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

        fn recycleSlot(slot: *Slot, slot_index: u32, free_slot: u32) u32 {
            slot.index = invalid_index;
            if (slot.generation == std.math.maxInt(u32)) return free_slot;

            slot.generation += 1;
            slot.index = free_slot;
            return slot_index;
        }
    };
}
