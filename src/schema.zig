const std = @import("std");

pub fn validateEntity(comptime Entity: type) void {
    const info = @typeInfo(Entity);

    if (info != .@"struct" or info.@"struct".is_tuple) {
        @compileError("An entity must be a named-field struct");
    }

    const fields = std.meta.fields(Entity);

    for (fields, 0..) |field, index| {
        if (field.is_comptime)
            @compileError("Entity fields must be runtime components");

        for (fields[0..index]) |previous| {
            if (field.type == previous.type)
                @compileError("Repeated component type in " ++ @typeName(Entity) ++ ": " ++ @typeName(field.type));
        }
    }
}

pub fn fieldIndex(comptime Entity: type, comptime Component: type) usize {
    for (std.meta.fields(Entity), 0..) |field, index| {
        if (field.type == Component) return index;
    }

    @compileError(@typeName(Entity) ++ " has no component " ++ @typeName(Component));
}

pub fn matches(comptime Entity: type, comptime components: anytype) bool {
    for (components) |Component| {
        var found = false;

        for (std.meta.fields(Entity)) |field| {
            if (field.type == Component) found = true;
        }

        if (!found) return false;
    }

    return true;
}

pub fn Columns(comptime Entity: type) type {
    const fields = std.meta.fields(Entity);
    var types: [fields.len]type = undefined;

    for (fields, 0..) |field, index| types[index] = []field.type;

    return @Tuple(&types);
}

pub fn validateTypes(comptime types: anytype) void {
    if (types.len == 0) @compileError("At least one type is required");

    for (types, 0..) |T, index| {
        if (@TypeOf(T) != type) @compileError("Expected a tuple of types");

        for (types, 0..) |Previous, previous_index| {
            if (previous_index < index and T == Previous)
                @compileError("Repeated type: " ++ @typeName(T));
        }
    }
}

pub fn typeIndex(comptime types: anytype, comptime T: type) usize {
    for (types, 0..) |Candidate, index| {
        if (Candidate == T) return index;
    }

    @compileError("Type is not registered: " ++ @typeName(T));
}

pub fn queryTypes(comptime components: anytype) [std.meta.fields(@TypeOf(components)).len]type {
    const info = @typeInfo(@TypeOf(components));

    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("A query must name its components: .{ .health = Health }");

    const fields = std.meta.fields(@TypeOf(components));
    var types: [fields.len]type = undefined;

    for (fields, 0..) |field, index| {
        if (field.type != type) @compileError("Query fields must contain component types");
        types[index] = @field(components, field.name);
    }

    validateTypes(types);

    return types;
}

pub fn ComponentPointers(comptime components: anytype) type {
    const component_types = queryTypes(components);
    const fields = std.meta.fields(@TypeOf(components));

    return FieldPointers(fields, &component_types);
}

pub fn EntityPointers(comptime Entity: type) type {
    validateEntity(Entity);

    const fields = std.meta.fields(Entity);
    var component_types: [fields.len]type = undefined;

    for (fields, 0..) |field, index| component_types[index] = field.type;

    return FieldPointers(fields, &component_types);
}

fn FieldPointers(comptime fields: []const std.builtin.Type.StructField, comptime component_types: []const type) type {
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    const attributes: [fields.len]std.builtin.Type.StructField.Attributes = @splat(.{});

    for (fields, 0..) |field, index| {
        names[index] = field.name;
        types[index] = *component_types[index];
    }

    return @Struct(.auto, null, &names, &types, &attributes);
}
