pub const Store = @import("store.zig").Store;
pub const EntityId = @import("entity_id.zig").EntityId;

test {
    _ = @import("tests/pool_storage.zig");
    _ = @import("tests/store.zig");
    _ = @import("tests/parts.zig");
}
