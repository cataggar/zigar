//! Type construction layer, decoupled from `std.builtin.Type`'s shape.
//!
//! Two compiler generations reshaped reflection: Zig 0.16 replaced the single
//! `@Type` reification builtin with a family of dedicated builtins (`@Int`,
//! `@Struct`, `@Union`, `@Enum`, `@Fn`, `@Pointer`, ...), and Zig 0.17 reshaped
//! `@typeInfo`'s aggregates into parallel arrays and removed the per-element
//! descriptor types.
//!
//! To insulate the rest of the codebase from this churn, `Reify` accepts a
//! stable, zigar-owned `Type` description matching the pre-0.17 `std.builtin.Type`
//! shape and lowers it to a real type via the 0.16+ builtins. Call sites build
//! the same literals they always have.

const std = @import("std");
const compat = @import("compat.zig");

pub const StructField = compat.StructField;
pub const UnionField = compat.UnionField;
pub const EnumField = compat.EnumField;
pub const Declaration = compat.Declaration;

const ContainerLayout = std.builtin.Type.ContainerLayout;
const Signedness = std.builtin.Signedness;
const CallingConvention = std.builtin.CallingConvention;
const AddressSpace = std.builtin.AddressSpace;
const PointerSize = std.builtin.Type.Pointer.Size;

/// Stable, zigar-owned mirror of the pre-0.17 `std.builtin.Type` for the kinds
/// the codebase constructs.
pub const Type = union(enum) {
    int: Int,
    float: Float,
    @"struct": Struct,
    @"union": Union,
    @"enum": Enum,
    @"fn": Fn,
    pointer: Pointer,
    array: Array,
    optional: Optional,
    error_union: ErrorUnion,
    vector: Vector,

    pub const Int = struct {
        signedness: Signedness,
        bits: u16,
    };
    pub const Float = struct {
        bits: u16,
    };
    pub const Struct = struct {
        layout: ContainerLayout = .auto,
        backing_integer: ?type = null,
        fields: []const StructField,
        decls: []const Declaration = &.{},
        is_tuple: bool = false,
    };
    pub const Union = struct {
        layout: ContainerLayout = .auto,
        tag_type: ?type = null,
        fields: []const UnionField,
        decls: []const Declaration = &.{},
    };
    pub const Enum = struct {
        tag_type: type,
        fields: []const EnumField,
        decls: []const Declaration = &.{},
        is_exhaustive: bool = true,
    };
    pub const FnParam = compat.Param;
    pub const Fn = struct {
        calling_convention: CallingConvention = .auto,
        is_generic: bool = false,
        is_var_args: bool = false,
        return_type: ?type,
        params: []const FnParam,
    };
    pub const Pointer = struct {
        size: PointerSize,
        is_const: bool = false,
        is_volatile: bool = false,
        alignment: ?usize = null,
        address_space: AddressSpace = .generic,
        child: type,
        is_allowzero: bool = false,
        sentinel_ptr: ?*const anyopaque = null,
    };
    pub const Array = struct {
        len: comptime_int,
        child: type,
        sentinel_ptr: ?*const anyopaque = null,
    };
    pub const Optional = struct {
        child: type,
    };
    pub const ErrorUnion = struct {
        error_set: type,
        payload: type,
    };
    pub const Vector = struct {
        len: comptime_int,
        child: type,
    };
};

// The codebase also constructs `Type.Fn.Param`; expose that alias.
pub const Param = Type.FnParam;

fn normAlign(alignment: ?usize) ?usize {
    return if (alignment) |a| (if (a == 0) null else a) else null;
}

/// Reimplements the old `@Type(info)` interface over the 0.16+ builtins, using
/// the stable `Type` description above.
pub fn Reify(comptime info: Type) type {
    return switch (info) {
        .int => |i| @Int(i.signedness, i.bits),
        .float => |f| std.meta.Float(f.bits),
        .vector => |v| @Vector(v.len, v.child),
        .optional => |o| ?o.child,
        .error_union => |eu| eu.error_set!eu.payload,
        .array => |a| reifyArray(a),
        .pointer => |p| reifyPointer(p),
        .@"struct" => |s| reifyStruct(s),
        .@"union" => |u| reifyUnion(u),
        .@"enum" => |e| reifyEnum(e),
        .@"fn" => |f| reifyFn(f),
    };
}

fn loadSentinel(comptime Child: type, comptime ptr: ?*const anyopaque) ?Child {
    const sp: *const Child = @ptrCast(@alignCast(ptr orelse return null));
    return sp.*;
}

fn reifyArray(comptime a: Type.Array) type {
    return if (loadSentinel(a.child, a.sentinel_ptr)) |s| [a.len:s]a.child else [a.len]a.child;
}

fn reifyPointer(comptime p: Type.Pointer) type {
    return @Pointer(p.size, .{
        .@"const" = p.is_const,
        .@"volatile" = p.is_volatile,
        .@"allowzero" = p.is_allowzero,
        .@"addrspace" = p.address_space,
        .@"align" = normAlign(p.alignment),
    }, p.child, loadSentinel(p.child, p.sentinel_ptr));
}

fn reifyStruct(comptime s: Type.Struct) type {
    if (s.is_tuple) {
        var types: [s.fields.len]type = undefined;
        for (s.fields, 0..) |f, i| types[i] = f.type;
        return @Tuple(&types);
    }
    var names: [s.fields.len][]const u8 = undefined;
    var types: [s.fields.len]type = undefined;
    var attrs: [s.fields.len]std.builtin.Type.Struct.FieldAttributes = undefined;
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

fn reifyUnion(comptime u: Type.Union) type {
    var names: [u.fields.len][]const u8 = undefined;
    var types: [u.fields.len]type = undefined;
    var attrs: [u.fields.len]std.builtin.Type.Union.FieldAttributes = undefined;
    for (u.fields, 0..) |f, i| {
        names[i] = f.name;
        types[i] = f.type;
        attrs[i] = .{ .@"align" = normAlign(f.alignment) };
    }
    return @Union(u.layout, u.tag_type, &names, &types, &attrs);
}

fn reifyEnum(comptime e: Type.Enum) type {
    var names: [e.fields.len][]const u8 = undefined;
    var values: [e.fields.len]e.tag_type = undefined;
    for (e.fields, 0..) |f, i| {
        names[i] = f.name;
        values[i] = f.value;
    }
    return @Enum(e.tag_type, if (e.is_exhaustive) .exhaustive else .nonexhaustive, &names, &values);
}

fn reifyFn(comptime f: Type.Fn) type {
    var types: [f.params.len]type = undefined;
    var attrs: [f.params.len]std.builtin.Type.Fn.ParamAttributes = undefined;
    for (f.params, 0..) |p, i| {
        types[i] = p.type.?;
        attrs[i] = .{ .@"noalias" = p.is_noalias };
    }
    return @Fn(&types, &attrs, f.return_type.?, .{
        .@"callconv" = f.calling_convention,
        .varargs = f.is_var_args,
    });
}
