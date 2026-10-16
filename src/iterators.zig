const std = @import("std");
const schema = @import("schema.zig");
const ThingId = @import("thing_id.zig").ThingId;
const Slot = @import("thing_id.zig").Slot;

pub fn ThingsIterator(comptime PoolType: type, comptime Thing: type) type {
    const fields = std.meta.fields(Thing);

    return struct {
        const This = @This();

        pub const Parts = schema.EntityPointers(Thing);

        pool: *PoolType,
        len: usize,
        next_index: usize = 0,
        current_index: ?usize = null,
        active: bool = true,

        pub fn init(pool: *PoolType) This {
            pool.active_iterators += 1;

            return .{ .pool = pool, .len = pool.len };
        }

        pub fn next(this: *This) ?Parts {
            this.current_index = null;

            if (!this.active) return null;

            while (this.next_index < this.len) {
                const row = this.next_index;
                this.next_index += 1;

                if (this.pool.removal_flags[row]) continue;

                var result: Parts = undefined;

                inline for (fields, 0..) |field, index| {
                    @field(result, field.name) = &this.pool.columns[index][row];
                }

                this.current_index = row;
                return result;
            }

            this.deinit();
            return null;
        }

        pub fn thingId(this: *const This) ThingId {
            std.debug.assert(this.active and this.current_index != null);
            const row = this.current_index.?;
            const slot = this.pool.dense_to_slot[row];

            return .{
                .pool = this.pool.pool_index,
                .slot = slot,
                .generation = this.pool.slots[slot].generation,
            };
        }

        pub inline fn deinit(this: *This) void {
            if (!this.active) return;

            this.current_index = null;
            this.active = false;
            this.pool.releaseIterator();
        }
    };
}

pub fn PartsIterator(comptime StoreType: type, comptime thing_types: anytype, comptime selection: anytype) type {
    const required = comptime schema.queryTypes(selection);
    const selection_fields = std.meta.fields(@TypeOf(selection));
    const Columns = comptime init: {
        var types: [required.len]type = undefined;

        for (required, 0..) |Component, index| types[index] = []Component;

        break :init @Tuple(&types);
    };

    return struct {
        const This = @This();

        pub const Parts = schema.ComponentPointers(selection);

        store: *StoreType,
        next_pool_index: usize = 0,
        current_pool_index: usize = 0,
        next_index: usize = 0,
        current_index: ?usize = null,
        active: bool = true,
        columns: Columns = emptyColumns(),
        pool_len: usize = 0,
        slots: []const Slot = &.{},
        dense_to_slot: []const usize = &.{},
        removal_flags: []bool = &.{},

        pub fn init(store: *StoreType) This {
            inline for (thing_types, 0..) |Thing, index| {
                if (comptime schema.matches(Thing, required)) {
                    store.pools[index].active_iterators += 1;
                }
            }

            return .{ .store = store };
        }

        pub fn next(this: *This) ?Parts {
            this.current_index = null;

            if (!this.active) return null;

            while (true) {
                if (this.next_index >= this.pool_len and !this.advancePool()) {
                    this.deinit();
                    return null;
                }

                const row = this.next_index;
                this.next_index += 1;

                if (this.removal_flags[row]) continue;

                var result: Parts = undefined;

                inline for (selection_fields, 0..) |field, index| {
                    @field(result, field.name) = &this.columns[index][row];
                }

                this.current_index = row;
                return result;
            }
        }

        pub fn thingId(this: *const This) ThingId {
            std.debug.assert(this.active and this.current_index != null);
            const row = this.current_index.?;
            const slot = this.dense_to_slot[row];

            return .{
                .pool = this.current_pool_index,
                .slot = slot,
                .generation = this.slots[slot].generation,
            };
        }

        pub inline fn deinit(this: *This) void {
            if (!this.active) return;

            this.current_index = null;
            this.active = false;

            inline for (thing_types, 0..) |Thing, index| {
                if (comptime schema.matches(Thing, required)) {
                    this.store.pools[index].releaseIterator();
                }
            }
        }

        fn advancePool(this: *This) bool {
            inline for (thing_types, 0..) |Thing, index| {
                if (comptime schema.matches(Thing, required)) {
                    if (this.next_pool_index <= index) {
                        this.next_pool_index = index + 1;
                        const storage = &this.store.pools[index];

                        if (storage.len != 0) {
                            inline for (required, 0..) |Component, column_index| {
                                this.columns[column_index] = storage.components(Component);
                            }

                            this.current_pool_index = index;
                            this.next_index = 0;
                            this.pool_len = storage.len;
                            this.slots = storage.slots;
                            this.dense_to_slot = storage.dense_to_slot;
                            this.removal_flags = storage.removal_flags;
                            return true;
                        }
                    }
                }
            }

            return false;
        }

        fn emptyColumns() Columns {
            var columns: Columns = undefined;

            inline for (required, 0..) |_, index| columns[index] = &.{};

            return columns;
        }
    };
}
