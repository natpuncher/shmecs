# shmecs

<img src="logo.png" alt="shmecs logo" width="280">

Typed storage with dense arrays. Iterate over things of one type or shared parts across types.

Each thing type has its own storage. Top-level fields live in separate arrays;
fields within a part stay together.

Register thing types, add a value, and keep its ID:

```zig
const GameStore = shmecs.Store(.{ Plane, Building, Bullet });

var store = GameStore.init(allocator);
defer store.deinit();

const player_id = store.add(player_plane);

if (store.get(Plane, player_id)) |plane| {
    plane.health.current -= 10;
}
```

IDs survive storage growth and reordering. `get` returns part pointers,
or `null` for an invalid ID or a different thing type.

Iterate over one thing type:

```zig
var planes = store.things(Plane);
defer planes.deinit();

while (planes.next()) |plane| {
    plane.motion.x += plane.motion.velocity_x * delta;
}
```

Iterate over shared parts across thing types, such as `Health` in planes and buildings:

```zig
_ = store.add(Building{
    .health = .{ .current = 0, .maximum = 200 },
    .appearance = .{ .sprite = 2 },
});

var parts = store.parts(.{ .health = Health });
defer parts.deinit();

while (parts.next()) |part| {
    if (part.health.current <= 0) store.remove(parts.thingId());
}
```

Both iterators expose `thingId()` for the current thing. `store.remove(id)` removes
immediately when its storage is free, or defers physical removal until the last iterator
finishes. Removed things disappear from iterators and `get` immediately; repeated
removal is harmless. No manual flush is needed.

`things` exposes `.len`, the stored row count when the iterator opens.
Use `store.count(Plane)` for the current count without opening an iterator,
and `store.reserve(Plane, capacity)` to preallocate storage.

Copy or restore state between initialized stores of the same type:

```zig
var snapshot = GameStore.init(allocator);
defer snapshot.deinit();

snapshot.copyFrom(&store);
store.copyFrom(&snapshot);
```

`copyFrom` preserves IDs and row order, reuses destination capacity, and requires
both stores to have no active iterators. Part values are copied; pointers and slices
inside parts still refer to their original targets. Reacquire part pointers after restoring.

- Full iteration closes automatically. Keep `defer iterator.deinit()` for early exits; cleanup on `break` happens when its enclosing scope ends.
- Adding or reserving a type with active iterators is a programming error. `add`, `reserve`, and `copyFrom` panic on allocation failure.
- Counts include pending removals until cleanup; iterators skip them immediately.
- Keep IDs for long-lived references; storage growth and removal can invalidate part pointers.
- Part types within a thing must be unique. Do not copy stores by assignment or copy active iterators.

Complete example: [src/main.zig](src/main.zig).

Build: `zig build`. Run the example: `zig build run`.

Benchmark: `zig build bench -Doptimize=ReleaseFast`.
