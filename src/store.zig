const std = @import("std");
const schema = @import("schema.zig");
const PartsIterator = @import("iterators.zig").PartsIterator;
const PoolStorage = @import("pool_storage.zig").PoolStorage;
const identity = @import("entity_id.zig");
const EntityId = identity.EntityId;

pub fn Store(comptime thing_types: anytype) type {
    comptime schema.validateTypes(thing_types);

    const Pools = comptime init: {
        var types: [thing_types.len]type = undefined;

        for (thing_types, 0..) |Thing, index| types[index] = PoolStorage(Thing);
        break :init @Tuple(&types);
    };

    return struct {
        const This = @This();

        pools: Pools,

        pub fn init(allocator: std.mem.Allocator) This {
            var this: This = undefined;

            inline for (thing_types, 0..) |Thing, index| {
                this.pools[index] = PoolStorage(Thing).init(allocator);
                this.pools[index].pool_index = index;
            }

            return this;
        }

        pub fn deinit(this: *This) void {
            inline for (thing_types, 0..) |_, index| {
                if (this.pools[index].active_iterators != 0)
                    @panic("Cannot deinitialize a store with active iterators");
            }

            inline for (thing_types, 0..) |_, index| this.pools[index].deinit();
        }

        pub fn copyFrom(this: *This, source: *const This) void {
            inline for (thing_types, 0..) |_, index| {
                std.debug.assert(this.pools[index].active_iterators == 0);
                std.debug.assert(source.pools[index].active_iterators == 0);
            }

            if (this == source) return;

            inline for (thing_types, 0..) |_, index| {
                this.pools[index].copyFrom(&source.pools[index]) catch @panic("Out of memory");
            }
        }

        pub fn things(this: *This, comptime Thing: type) PoolStorage(Thing).Iterator {
            return this.storageFor(Thing).iterator();
        }

        pub fn parts(this: *This, comptime selection: anytype) PartsIterator(This, thing_types, selection) {
            return PartsIterator(This, thing_types, selection).init(this);
        }

        pub fn count(this: *const This, comptime Thing: type) usize {
            const index = comptime schema.typeIndex(thing_types, Thing);
            return this.pools[index].len;
        }

        pub fn reserve(this: *This, comptime Thing: type, capacity: usize) void {
            this.storageFor(Thing).reserve(capacity) catch @panic("Out of memory");
        }

        pub fn add(this: *This, thing: anytype) EntityId {
            return this.storageFor(@TypeOf(thing)).append(thing) catch @panic("Out of memory");
        }

        pub fn get(this: *This, comptime Thing: type, id: EntityId) ?schema.EntityPointers(Thing) {
            const storage = this.storageFor(Thing);
            const index = storage.indexOf(id) orelse return null;
            var thing: schema.EntityPointers(Thing) = undefined;

            inline for (std.meta.fields(Thing), 0..) |field, column_index| {
                @field(thing, field.name) = &storage.columns[column_index][index];
            }

            return thing;
        }

        pub fn remove(this: *This, id: EntityId) void {
            inline for (thing_types, 0..) |_, index| {
                if (id.pool == index) return this.pools[index].remove(id);
            }
        }

        fn storageFor(this: *This, comptime Thing: type) *PoolStorage(Thing) {
            const index = comptime schema.typeIndex(thing_types, Thing);
            return &this.pools[index];
        }
    };
}
