const std = @import("std");
const schema = @import("schema.zig");
const EntityId = @import("entity_id.zig").EntityId;

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
        }

        pub fn deinit(this: *This) void {
            if (!this.active) return;

            this.pool.active_iterators -= 1;
            this.current_index = null;
            this.active = false;
        }
    };
}
