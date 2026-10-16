const std = @import("std");
const schema = @import("schema.zig");
const EntityId = @import("entity_id.zig").EntityId;
const Slot = @import("entity_id.zig").Slot;

pub fn PoolIterator(comptime PoolType: type, comptime Entity: type) type {
    const fields = std.meta.fields(Entity);

    return struct {
        const This = @This();

        pub const Components = schema.EntityPointers(Entity);

        pool: *PoolType,
        next_index: usize = 0,
        current_index: ?usize = null,
        active: bool = true,

        pub fn init(pool: *PoolType) This {
            pool.active_iterators += 1;

            return .{ .pool = pool };
        }

        pub fn next(this: *This) ?Components {
            this.current_index = null;

            if (!this.active or this.next_index >= this.pool.len) return null;

            const row = this.next_index;
            var result: Components = undefined;

            inline for (fields, 0..) |field, index| {
                @field(result, field.name) = &this.pool.columns[index][row];
            }

            this.next_index += 1;
            this.current_index = row;

            return result;
        }

        pub fn id(this: *const This) ?EntityId {
            const row = this.current_index orelse return null;
            const slot = this.pool.dense_to_slot[row];

            return .{
                .pool = this.pool.pool_index,
                .slot = slot,
                .generation = this.pool.slots[slot].generation,
            };
        }

        pub fn markForRemoval(this: *This) error{NoCurrentEntity}!void {
            const row = this.current_index orelse return error.NoCurrentEntity;

            this.pool.removal_flags[row] = true;
            this.pool.has_pending_removals = true;
        }

        pub fn deinit(this: *This) void {
            if (!this.active) return;

            this.pool.active_iterators -= 1;
            this.current_index = null;
            this.active = false;
        }
    };
}

pub fn Query(comptime WorldType: type, comptime entities: anytype, comptime components: anytype) type {
    const required = comptime schema.queryTypes(components);
    const query_fields = std.meta.fields(@TypeOf(components));
    const Columns = comptime init: {
        var types: [required.len]type = undefined;

        for (required, 0..) |Component, index| types[index] = []Component;

        break :init @Tuple(&types);
    };

    return struct {
        const This = @This();

        pub const Components = schema.ComponentPointers(components);

        world: *WorldType,
        next_pool_index: usize = 0,
        current_pool_index: usize = 0,
        next_index: usize = 0,
        current_index: ?usize = null,
        active: bool = true,
        columns: Columns = emptyColumns(),
        len: usize = 0,
        slots: []const Slot = &.{},
        dense_to_slot: []const usize = &.{},
        removal_flags: []bool = &.{},
        has_pending_removals: *bool = undefined,

        pub fn init(world: *WorldType) This {
            inline for (entities, 0..) |Entity, index| {
                if (comptime schema.matches(Entity, required)) {
                    world.pools[index].active_iterators += 1;
                }
            }

            return .{ .world = world };
        }

        pub fn next(this: *This) ?Components {
            this.current_index = null;

            if (!this.active) return null;
            if (this.next_index >= this.len and !this.advancePool()) return null;

            const row = this.next_index;
            var result: Components = undefined;

            inline for (query_fields, 0..) |field, index| {
                @field(result, field.name) = &this.columns[index][row];
            }

            this.next_index += 1;
            this.current_index = row;

            return result;
        }

        pub fn id(this: *const This) ?EntityId {
            const row = this.current_index orelse return null;
            const slot = this.dense_to_slot[row];

            return .{
                .pool = this.current_pool_index,
                .slot = slot,
                .generation = this.slots[slot].generation,
            };
        }

        pub fn markForRemoval(this: *This) error{NoCurrentEntity}!void {
            const row = this.current_index orelse return error.NoCurrentEntity;

            this.removal_flags[row] = true;
            this.has_pending_removals.* = true;
        }

        pub fn deinit(this: *This) void {
            if (!this.active) return;

            inline for (entities, 0..) |Entity, index| {
                if (comptime schema.matches(Entity, required)) {
                    this.world.pools[index].active_iterators -= 1;
                }
            }

            this.current_index = null;
            this.active = false;
        }

        fn advancePool(this: *This) bool {
            inline for (entities, 0..) |Entity, index| {
                if (comptime schema.matches(Entity, required)) {
                    if (this.next_pool_index <= index) {
                        this.next_pool_index = index + 1;
                        const storage = &this.world.pools[index];

                        if (storage.len != 0) {
                            inline for (required, 0..) |Component, column_index| {
                                this.columns[column_index] = storage.components(Component);
                            }

                            this.current_pool_index = index;
                            this.next_index = 0;
                            this.len = storage.len;
                            this.slots = storage.slots;
                            this.dense_to_slot = storage.dense_to_slot;
                            this.removal_flags = storage.removal_flags;
                            this.has_pending_removals = &storage.has_pending_removals;
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
