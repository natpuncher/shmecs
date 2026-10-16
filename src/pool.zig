const PoolStorage = @import("pool_storage.zig").PoolStorage;

pub fn Pool(comptime Entity: type) type {
    const Storage = PoolStorage(Entity);

    return struct {
        const This = @This();

        storage: *Storage,

        pub fn len(this: This) usize {
            return this.storage.len;
        }

        pub fn components(this: This, comptime Component: type) []Component {
            return this.storage.components(Component);
        }

        pub fn iterator(this: This) Storage.Iterator {
            return this.storage.iterator();
        }

        pub fn reserve(this: This, capacity: usize) Storage.Error!void {
            return this.storage.reserve(capacity);
        }
    };
}
