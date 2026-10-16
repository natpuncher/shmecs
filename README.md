# shmecs

Dense component arrays, fixed entity types, and queries by component type.

Each entity type has its own pool. Top-level fields live in separate arrays;
fields within a component stay together.

Register entity types, add a value, and keep its ID:

```zig
const GameWorld = shmecs.World(.{ Plane, Building, Bullet });

var world = GameWorld.init(allocator);
defer world.deinit();

const player_id = try world.add(player_plane);

if (world.get(Plane, player_id)) |plane| {
    plane.health.current -= 10;
}
```

IDs survive storage growth and reordering. `get` returns component pointers,
or `null` for an invalid ID or a different entity type.

Iterate over one entity type:

```zig
{
    var planes = world.pool(Plane).iterator();
    defer planes.deinit();

    while (planes.next()) |plane| {
        plane.motion.x += plane.motion.velocity_x * delta;
    }
}
```

Query shared components across entity types, such as `Health` in planes and buildings:

```zig
_ = try world.add(Building{
    .health = .{ .current = 0, .maximum = 200 },
    .appearance = .{ .sprite = 2 },
});

var query = world.query(.{ .health = Health });
defer query.deinit();

while (query.next()) |components| {
    if (components.health.current <= 0) try query.markForRemoval();
}

_ = try world.flushRemovals();
```

Both iterators expose `id()` and `markForRemoval()` for the current entity.
Use `world.markForRemoval(id)` to mark by ID, or `world.remove(id)` to remove immediately.
Removal invalidates the entity's ID.

Pools also expose `len()`, `components(Component)` for a mutable slice,
and optional `reserve(capacity)`.

- Always close iterators with `deinit()` before flushing removals. Open iterators block structural changes to affected pools.
- Keep IDs for long-lived references; storage growth and removal can invalidate component pointers.
- Component types within an entity must be unique. Do not copy worlds or active iterators.

Complete example: [src/main.zig](src/main.zig).

Build: `zig build`. Run the example: `zig build run`.

Benchmark: `zig build bench -Doptimize=ReleaseFast`.
