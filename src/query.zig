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

pub fn Query(comptime WorldType: type, comptime entities: anytype, comptime components: anytype) type {
    const required = comptime schema.queryTypes(components);
    const query_fields = std.meta.fields(@TypeOf(components));

    return struct {
        const This = @This();

        pub const Components = schema.ComponentPointers(components);

        world: *WorldType,
        pool_index: usize = 0,
        next_index: usize = 0,
        current_index: ?usize = null,
        active: bool = true,

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

            inline for (entities, 0..) |Entity, index| {
                if (comptime schema.matches(Entity, required)) {
                    if (this.pool_index <= index) {
                        this.pool_index = index;
                        const storage = &this.world.pools[index];

                        if (this.next_index < storage.len) {
                            const row = this.next_index;
                            this.next_index += 1;
                            var result: Components = undefined;

                            inline for (query_fields) |field| {
                                const Component = @field(components, field.name);
                                @field(result, field.name) = &storage.components(Component)[row];
                            }

                            this.current_index = row;
                            return result;
                        }

                        this.pool_index = index + 1;
                        this.next_index = 0;
                    }
                }
            }

            return null;
        }

        pub fn id(this: *const This) ?EntityId {
            const row = this.current_index orelse return null;

            inline for (entities, 0..) |Entity, index| {
                if (comptime schema.matches(Entity, required)) {
                    if (this.pool_index == index) {
                        const storage = &this.world.pools[index];
                        const slot = storage.dense_to_slot[row];
                        return .{
                            .pool = index,
                            .slot = slot,
                            .generation = storage.slots[slot].generation,
                        };
                    }
                }
            }

            return null;
        }

        pub fn markForRemoval(this: *This) error{NoCurrentEntity}!void {
            const row = this.current_index orelse return error.NoCurrentEntity;

            inline for (entities, 0..) |Entity, index| {
                if (comptime schema.matches(Entity, required)) {
                    if (this.pool_index == index) {
                        this.world.pools[index].removal_flags[row] = true;
                        return;
                    }
                }
            }

            return error.NoCurrentEntity;
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
    };
}
