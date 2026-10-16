pub const Pool = @import("pool.zig").Pool;
pub const World = @import("world.zig").World;
pub const EntityId = @import("entity_id.zig").EntityId;

test {
    _ = @import("tests/pool.zig");
    _ = @import("tests/world.zig");
    _ = @import("tests/query.zig");
}
