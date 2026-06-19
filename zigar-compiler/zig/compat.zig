//! Compatibility helpers smoothing over the `std.builtin.Type` (`std.lang.Type`)
//! reshaping in Zig 0.17.
//!
//! 0.17 replaced the per-element descriptor slices of `@typeInfo` aggregates
//! with parallel arrays and removed the `StructField`/`UnionField`/`EnumField`/
//! `Fn.Param` descriptor types:
//!   * `Struct`/`Union`: `fields: []Field` -> `field_names`/`field_types`/`field_attrs`
//!   * `Enum`: `fields`/`is_exhaustive` -> `field_names`/`field_values`/`mode`
//!   * `Fn`: `params` -> `param_types`/`param_attrs`; `calling_convention`/
//!     `is_var_args` -> `attrs.@"callconv"`/`attrs.varargs`
//!   * `*.decls` -> `*.decl_names`
//!
//! These helpers reconstruct the older, single-slice view so the rest of the
//! codebase can keep iterating one slice of richly-typed descriptors. The
//! descriptor types defined here are also the construction-side descriptors
//! consumed by `reify.zig`.

const std = @import("std");
const Type = std.builtin.Type;

pub const StructField = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque = null,
    is_comptime: bool = false,
    alignment: ?usize = null,
};

pub const UnionField = struct {
    name: [:0]const u8,
    type: type,
    alignment: ?usize = null,
};

pub const EnumField = struct {
    name: [:0]const u8,
    value: comptime_int,
};

pub const Param = struct {
    is_generic: bool = false,
    is_noalias: bool = false,
    type: ?type,
};

pub const Declaration = struct {
    name: [:0]const u8,
};

fn FieldOf(comptime InfoT: type) type {
    return switch (InfoT) {
        Type.Struct => StructField,
        Type.Union => UnionField,
        Type.Enum => EnumField,
        else => @compileError("compat.fields: unsupported info type " ++ @typeName(InfoT)),
    };
}

/// Returns the fields of a struct/union/enum type-info in the pre-0.17 shape (a
/// single slice of descriptors). `info` is the payload of e.g.
/// `@typeInfo(T).@"struct"`.
pub inline fn fields(comptime info: anytype) []const FieldOf(@TypeOf(info)) {
    const InfoT = @TypeOf(info);
    comptime {
        if (InfoT == Type.Struct) {
            var arr: [info.field_names.len]StructField = undefined;
            for (0..info.field_names.len) |i| arr[i] = .{
                .name = info.field_names[i],
                .type = info.field_types[i],
                .default_value_ptr = info.field_attrs[i].default_value_ptr,
                .is_comptime = info.field_attrs[i].@"comptime",
                .alignment = info.field_attrs[i].@"align",
            };
            const final = arr;
            return &final;
        } else if (InfoT == Type.Union) {
            var arr: [info.field_names.len]UnionField = undefined;
            for (0..info.field_names.len) |i| arr[i] = .{
                .name = info.field_names[i],
                .type = info.field_types[i],
                .alignment = info.field_attrs[i].@"align",
            };
            const final = arr;
            return &final;
        } else if (InfoT == Type.Enum) {
            var arr: [info.field_names.len]EnumField = undefined;
            for (0..info.field_names.len) |i| arr[i] = .{
                .name = info.field_names[i],
                .value = info.field_values[i],
            };
            const final = arr;
            return &final;
        } else {
            @compileError("compat.fields: unsupported info type " ++ @typeName(InfoT));
        }
    }
}

fn FieldsOfT(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => StructField,
        .@"union" => UnionField,
        .@"enum" => EnumField,
        else => @compileError("compat.fieldsOf: unsupported type " ++ @typeName(T)),
    };
}

/// Replacement for the pre-0.17 `compat.fieldsOf(T)`: returns the fields of a
/// struct/union/enum *type* in the single-slice descriptor shape.
pub inline fn fieldsOf(comptime T: type) []const FieldsOfT(T) {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| fields(s),
        .@"union" => |u| fields(u),
        .@"enum" => |e| fields(e),
        else => @compileError("compat.fieldsOf: unsupported type " ++ @typeName(T)),
    };
}

/// Returns the parameters of a function type-info in the pre-0.17 shape.
pub inline fn params(comptime f: Type.Fn) []const Param {
    comptime {
        var arr: [f.param_types.len]Param = undefined;
        for (0..f.param_types.len) |i| arr[i] = .{
            .is_generic = f.param_types[i] == null,
            .is_noalias = f.param_attrs[i].@"noalias",
            .type = f.param_types[i],
        };
        const final = arr;
        return &final;
    }
}

/// Calling convention of a function type-info (moved under `attrs` in 0.17).
pub fn callingConvention(comptime f: Type.Fn) std.builtin.CallingConvention {
    return f.attrs.@"callconv";
}

/// Whether a function type-info is variadic (moved under `attrs` in 0.17).
pub fn isVarArgs(comptime f: Type.Fn) bool {
    return f.attrs.varargs;
}

/// Whether an enum type-info is exhaustive (`is_exhaustive` -> `mode` in 0.17).
pub fn isExhaustive(comptime e: Type.Enum) bool {
    return e.mode == .exhaustive;
}

/// Returns the declarations of a container type-info in the pre-0.17 shape
/// (`decls: []Declaration`; backed by `decl_names` in 0.17).
pub inline fn decls(comptime info: anytype) []const Declaration {
    comptime {
        const names = info.decl_names;
        var arr: [names.len]Declaration = undefined;
        for (0..names.len) |i| arr[i] = .{ .name = names[i] };
        const final = arr;
        return &final;
    }
}

/// Replacement for the pre-0.17 `compat.declarations(T)`, which now returns a
/// slice of name strings; this restores the `[]Declaration` shape.
pub inline fn declarations(comptime T: type) []const Declaration {
    comptime {
        const names = std.meta.declarations(T);
        var arr: [names.len]Declaration = undefined;
        for (0..names.len) |i| arr[i] = .{ .name = names[i] };
        const final = arr;
        return &final;
    }
}

// `std.heap.stackFallback`/`StackFallbackAllocator` were removed in Zig 0.17;
// vendored here (a fixed buffer that falls back to a backing allocator).
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

pub fn stackFallback(comptime size: usize, fallback_allocator: Allocator) StackFallbackAllocator(size) {
    return StackFallbackAllocator(size){
        .buffer = undefined,
        .fallback_allocator = fallback_allocator,
        .fixed_buffer_allocator = undefined,
    };
}

pub fn StackFallbackAllocator(comptime size: usize) type {
    return struct {
        const Self = @This();

        buffer: [size]u8,
        fallback_allocator: Allocator,
        fixed_buffer_allocator: FixedBufferAllocator,

        pub fn get(self: *Self) Allocator {
            self.fixed_buffer_allocator = FixedBufferAllocator.init(self.buffer[0..]);
            return .{
                .ptr = self,
                .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return FixedBufferAllocator.alloc(&self.fixed_buffer_allocator, len, alignment, ra) orelse
                self.fallback_allocator.rawAlloc(len, alignment, ra);
        }

        fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
                return FixedBufferAllocator.resize(&self.fixed_buffer_allocator, buf, alignment, new_len, ra);
            } else {
                return self.fallback_allocator.rawResize(buf, alignment, new_len, ra);
            }
        }

        fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.fixed_buffer_allocator.ownsPtr(memory.ptr)) {
                return FixedBufferAllocator.remap(&self.fixed_buffer_allocator, memory, alignment, new_len, ra);
            } else {
                return self.fallback_allocator.rawRemap(memory, alignment, new_len, ra);
            }
        }

        fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ra: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
                return FixedBufferAllocator.free(&self.fixed_buffer_allocator, buf, alignment, ra);
            } else {
                return self.fallback_allocator.rawFree(buf, alignment, ra);
            }
        }
    };
}
