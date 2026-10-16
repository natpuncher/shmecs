pub const Store = @import("store.zig").Store;
pub const ThingId = @import("thing_id.zig").ThingId;

test {
    _ = @import("tests/pool_storage.zig");
    _ = @import("tests/store.zig");
    _ = @import("tests/parts.zig");
}
