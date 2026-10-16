const std = @import("std");
const schema = @import("schema.zig");
const QueryIterator = @import("query.zig").Query;
const Pool = @import("pool.zig").Pool;
const PoolStorage = @import("pool_storage.zig").PoolStorage;
const identity = @import("entity_id.zig");
const EntityId = identity.EntityId;

pub fn World(comptime entities: anytype) type {
    comptime schema.validateTypes(entities);

    const Pools = comptime init: {
        var types: [entities.len]type = undefined;

        for (entities, 0..) |Entity, index| types[index] = PoolStorage(Entity);
        break :init @Tuple(&types);
    };

    return struct {
        const This = @This();

        pools: Pools,

        pub fn init(allocator: std.mem.Allocator) This {
            var this: This = undefined;

            inline for (entities, 0..) |Entity, index| {
                this.pools[index] = PoolStorage(Entity).init(allocator);
                this.pools[index].pool_index = index;
            }

            return this;
        }

        pub fn deinit(this: *This) void {
            inline for (entities, 0..) |_, index| {
                if (this.pools[index].active_iterators != 0)
                    @panic("Cannot deinitialize a world with active iterators");
            }

            inline for (entities, 0..) |_, index| this.pools[index].deinit();
        }

        pub fn pool(this: *This, comptime Entity: type) Pool(Entity) {
            return .{ .storage = this.storageFor(Entity) };
        }

        pub fn add(this: *This, entity: anytype) !EntityId {
            return this.storageFor(@TypeOf(entity)).append(entity);
        }

        pub fn get(this: *This, comptime Entity: type, id: EntityId) ?schema.EntityPointers(Entity) {
            const storage = this.storageFor(Entity);
            const index = storage.indexOf(id) orelse return null;
            var entity: schema.EntityPointers(Entity) = undefined;

            inline for (std.meta.fields(Entity), 0..) |field, column_index| {
                @field(entity, field.name) = &storage.columns[column_index][index];
            }

            return entity;
        }

        pub fn remove(this: *This, id: EntityId) error{ PoolInUse, InvalidEntity }!void {
            inline for (entities, 0..) |_, index| {
                if (id.pool == index) return this.pools[index].remove(id);
            }

            return error.InvalidEntity;
        }

        pub fn markForRemoval(this: *This, id: EntityId) error{InvalidEntity}!void {
            inline for (entities, 0..) |_, index| {
                if (id.pool == index) {
                    const storage = &this.pools[index];
                    const row = storage.indexOf(id) orelse return error.InvalidEntity;

                    storage.removal_flags[row] = true;
                    return;
                }
            }

            return error.InvalidEntity;
        }

        pub fn query(this: *This, comptime components: anytype) Query(components) {
            return Query(components).init(this);
        }

        pub fn flushRemovals(this: *This) error{PoolInUse}!usize {
            inline for (entities, 0..) |_, index| {
                if (this.pools[index].active_iterators != 0) return error.PoolInUse;
            }

            var removed: usize = 0;

            inline for (entities, 0..) |_, index| {
                removed += try this.pools[index].flushRemovals();
            }

            return removed;
        }

        fn storageFor(this: *This, comptime Entity: type) *PoolStorage(Entity) {
            const index = comptime schema.typeIndex(entities, Entity);
            return &this.pools[index];
        }

        fn Query(comptime components: anytype) type {
            return QueryIterator(This, entities, components);
        }
    };
}
