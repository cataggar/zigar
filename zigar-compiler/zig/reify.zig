const std = @import("std");

// Normalize a field/pointer alignment to the 0.16 convention where `null` means
// "natural alignment". Some call sites still use the 0.15 convention of `0`.
fn normAlign(alignment: ?usize) ?usize {
    return if (alignment) |a| (if (a == 0) null else a) else null;
}


// Zig 0.16 replaced the single `@Type` reification builtin with a family of
// dedicated builtins (`@Int`, `@Struct`, `@Union`, `@Enum`, `@Fn`, `@Pointer`,
// ...). `Reify` re-implements the old `@Type(info)` interface on top of them so
// existing call sites only need to swap `@Type` for `Reify`.
pub fn Reify(comptime info: std.builtin.Type) type {
    return switch (info) {
        .int => |i| @Int(i.signedness, i.bits),
        .float => |f| std.meta.Float(f.bits),
        .vector => |v| @Vector(v.len, v.child),
        .optional => |o| ?o.child,
        .error_union => |eu| eu.error_set!eu.payload,
        .array => |a| if (a.sentinel()) |s| [a.len:s]a.child else [a.len]a.child,
        .pointer => |p| @Pointer(p.size, .{
            .@"const" = p.is_const,
            .@"volatile" = p.is_volatile,
            .@"allowzero" = p.is_allowzero,
            .@"addrspace" = p.address_space,
            .@"align" = normAlign(p.alignment),
        }, p.child, p.sentinel()),
        .@"struct" => |s| reifyStruct(s),
        .@"union" => |u| reifyUnion(u),
        .@"enum" => |e| reifyEnum(e),
        .@"fn" => |f| reifyFn(f),
        else => @compileError("Reify: unsupported type info '" ++ @tagName(info) ++ "'"),
    };
}

fn reifyStruct(comptime s: std.builtin.Type.Struct) type {
    if (s.is_tuple) {
        var types: [s.fields.len]type = undefined;
        for (s.fields, 0..) |f, i| types[i] = f.type;
        return @Tuple(&types);
    }
    var names: [s.fields.len][]const u8 = undefined;
    var types: [s.fields.len]type = undefined;
    var attrs: [s.fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (s.fields, 0..) |f, i| {
        names[i] = f.name;
        types[i] = f.type;
        attrs[i] = .{
            .@"comptime" = f.is_comptime,
            .@"align" = normAlign(f.alignment),
            .default_value_ptr = f.default_value_ptr,
        };
    }
    return @Struct(s.layout, s.backing_integer, &names, &types, &attrs);
}

fn reifyUnion(comptime u: std.builtin.Type.Union) type {
    var names: [u.fields.len][]const u8 = undefined;
    var types: [u.fields.len]type = undefined;
    var attrs: [u.fields.len]std.builtin.Type.UnionField.Attributes = undefined;
    for (u.fields, 0..) |f, i| {
        names[i] = f.name;
        types[i] = f.type;
        attrs[i] = .{ .@"align" = normAlign(f.alignment) };
    }
    return @Union(u.layout, u.tag_type, &names, &types, &attrs);
}

fn reifyEnum(comptime e: std.builtin.Type.Enum) type {
    var names: [e.fields.len][]const u8 = undefined;
    var values: [e.fields.len]e.tag_type = undefined;
    for (e.fields, 0..) |f, i| {
        names[i] = f.name;
        values[i] = f.value;
    }
    return @Enum(e.tag_type, if (e.is_exhaustive) .exhaustive else .nonexhaustive, &names, &values);
}

fn reifyFn(comptime f: std.builtin.Type.Fn) type {
    var types: [f.params.len]type = undefined;
    var attrs: [f.params.len]std.builtin.Type.Fn.Param.Attributes = undefined;
    for (f.params, 0..) |p, i| {
        types[i] = p.type.?;
        attrs[i] = .{ .@"noalias" = p.is_noalias };
    }
    return @Fn(&types, &attrs, f.return_type.?, .{
        .@"callconv" = f.calling_convention,
        .varargs = f.is_var_args,
    });
}
