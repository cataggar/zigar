//! Comptime Canonical ABI reflection and zero-overhead inlined lift/lower
//! thunk engine for Zig 0.17.0.
//!
//! Uses Zig comptime type reflection (`@typeInfo`, `@Tuple`, `@Fn`) to compute
//! Component Model Canonical ABI memory layouts, flat register representations,
//! variant slot joins, blittable zero-copy fast paths, linear memory load/store,
//! and host/guest lift/lower call thunks.

const std = @import("std");
const builtin = @import("builtin");

pub const fast_abi = @import("fast_abi.zig");
pub const FastLower = fast_abi.FastLower;
pub const FastLift = fast_abi.FastLift;
pub const ZigarAbiMetadata = fast_abi.ZigarAbiMetadata;
pub const detectZigarAbi = fast_abi.detectZigarAbi;

pub const Error = error{
    OutOfMemory,
    OutOfBounds,
    InvalidDiscriminant,
    InvalidChar,
    InvalidUtf8,
    InvalidBool,
    MissingRealloc,
    MissingAllocator,
    AlignmentError,
    UnalignedPointer,
    AsyncCallPending,
    AsyncTaskDidNotReturn,
    ReallocFailed,
};

pub const CanonError = Error;

pub fn PtrInt(comptime is_memory64: bool) type {
    return if (is_memory64) u64 else u32;
}

/// Result type for lifting operations that may return either a Canonical ABI
/// error (`Error`) or, when `T` itself is a Zig error union `E!Payload`, the
/// merged error union `(Error || E)!Payload`.
pub fn CanonResult(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| (Error || eu.error_set)!eu.payload,
        .error_set => (Error || T)!void,
        else => Error!T,
    };
}

// ── Standardized WIT Companion Types ───────────────────────────────────────

/// Component Model linear memory address architecture (`wasm32` vs `wasm64` / `cm64`).
pub const Arch = enum {
    wasm32,
    wasm64,

    pub fn AddrInt(comptime self: Arch) type {
        return switch (self) {
            .wasm32 => u32,
            .wasm64 => u64,
        };
    }

    pub fn FlatAddrType(comptime self: Arch) type {
        return switch (self) {
            .wasm32 => i32,
            .wasm64 => i64,
        };
    }

    pub fn flatAddrValType(comptime self: Arch) FlatValType {
        return switch (self) {
            .wasm32 => .i32,
            .wasm64 => .i64,
        };
    }
};

pub fn AddrInt(comptime arch: Arch) type {
    return arch.AddrInt();
}

pub fn FlatAddrType(comptime arch: Arch) type {
    return arch.FlatAddrType();
}

/// Core Wasm flat register value types used by the Canonical ABI.
pub const FlatValType = enum {
    i32,
    i64,
    f32,
    f64,

    pub fn toZigType(comptime self: FlatValType) type {
        return ToZigType(self);
    }
};

pub fn ToZigType(comptime ft: FlatValType) type {
    return switch (ft) {
        .i32 => i32,
        .i64 => i64,
        .f32 => f32,
        .f64 => f64,
    };
}

/// Canonical ABI `join` operator for overlapping flat payload slots in
/// `variant` and `result` types.
pub fn joinFlatType(a: FlatValType, b: FlatValType) FlatValType {
    if (a == b) return a;
    if ((a == .i32 and b == .f32) or (a == .f32 and b == .i32)) return .i32;
    return .i64;
}

/// Distinct WIT `char` type representing a Unicode Scalar Value.
/// Bare `u21` is also accepted as a WIT `char` in reflection.
pub const Char = enum(u21) {
    _,

    pub const wit_is_char = true;

    pub fn fromCodepoint(cp: u21) Error!Char {
        const valid = try validateChar(cp);
        return @enumFromInt(valid);
    }

    pub fn toCodepoint(self: Char) u21 {
        return @intFromEnum(self);
    }
};

/// Validate that `raw` is a valid Unicode Scalar Value (`< 0x110000` and not
/// in the UTF-16 surrogate range `0xD800..0xDFFF`).
pub fn validateChar(raw: u32) Error!u21 {
    if (raw >= 0x110000) return error.InvalidChar;
    if (raw >= 0xD800 and raw <= 0xDFFF) return error.InvalidChar;
    return @intCast(raw);
}

/// Standardized WIT `result<Ok, Err>` representation as a 2-case tagged union.
/// Use `void` for absent `ok` or `err` payloads.
pub fn Result(comptime Ok: type, comptime Err: type) type {
    return union(enum(u8)) {
        ok: Ok,
        err: Err,

        pub const wit_is_result = true;
        pub const OkType = Ok;
        pub const ErrType = Err;
    };
}

/// Handle kinds for Component Model resources and WASI Preview 3 async handles.
pub const HandleKind = enum {
    own,
    borrow,
    stream,
    future,
    error_context,
};

pub fn Own(comptime R: type) type {
    return extern struct {
        handle: i32,
        pub const Resource = R;
        pub const wit_handle_kind = HandleKind.own;
    };
}

pub fn Borrow(comptime R: type) type {
    return extern struct {
        handle: i32,
        pub const Resource = R;
        pub const wit_handle_kind = HandleKind.borrow;
    };
}

pub fn Stream(comptime T: type) type {
    return extern struct {
        handle: i32,
        pub const Payload = T;
        pub const wit_handle_kind = HandleKind.stream;
    };
}

pub fn Future(comptime T: type) type {
    return extern struct {
        handle: i32,
        pub const Payload = T;
        pub const wit_handle_kind = HandleKind.future;
    };
}

pub const ErrorContext = extern struct {
    handle: i32,
    pub const wit_handle_kind = HandleKind.error_context;
};

/// Optional explicit UTF-8 string wrapper; `[]const u8` and `[:0]const u8` are
/// also treated directly as WIT UTF-8 strings.
pub const WitString = struct {
    bytes: []const u8,
    pub const wit_is_string = true;
};

pub fn String(comptime T: type) type {
    return struct {
        bytes: []const T,
        pub const wit_is_string = true;
        pub const CodeUnit = T;
    };
}

pub fn isHandleType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "wit_handle_kind"),
        else => false,
    };
}

pub fn isStringWrapper(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "wit_is_string") and @hasField(T, "bytes"),
        else => false,
    };
}

pub fn isCharType(comptime T: type) bool {
    if (T == u21 or T == Char) return true;
    return switch (@typeInfo(T)) {
        .@"enum" => |en| (en.tag_type == u21 and en.mode == .nonexhaustive) or @hasDecl(T, "wit_is_char"),
        else => false,
    };
}

pub fn enumToIndex(comptime T: type, val: T) u32 {
    const en = @typeInfo(T).@"enum";
    if (comptime en.mode == .nonexhaustive) {
        return @intCast(@intFromEnum(val));
    }
    inline for (en.field_names, 0..) |fname, case_idx| {
        if (val == @field(T, fname)) {
            return @intCast(case_idx);
        }
    }
    unreachable;
}

pub fn intToEnum(comptime T: type, raw: u32) Error!T {
    const en = @typeInfo(T).@"enum";
    if (comptime en.mode == .nonexhaustive) {
        const TagT = en.tag_type;
        const casted = std.math.cast(TagT, raw) orelse return error.InvalidDiscriminant;
        return @enumFromInt(casted);
    }
    inline for (en.field_names, 0..) |fname, case_idx| {
        if (raw == case_idx) {
            return @field(T, fname);
        }
    }
    return error.InvalidDiscriminant;
}

fn packedFlagsMask(comptime T: type) @Int(.unsigned, @bitSizeOf(@typeInfo(T).@"struct".backing_integer.?)) {
    const st = @typeInfo(T).@"struct";
    const BackingInt = st.backing_integer.?;
    const UnsignedInt = @Int(.unsigned, @bitSizeOf(BackingInt));
    const bit_count: usize = if (@hasDecl(T, "wit_flags_count"))
        T.wit_flags_count
    else
        @bitSizeOf(UnsignedInt);
    if (bit_count == 0) return 0;
    if (bit_count >= @bitSizeOf(UnsignedInt)) return std.math.maxInt(UnsignedInt);
    return (@as(UnsignedInt, 1) << @intCast(bit_count)) - 1;
}

fn flagsWordMask(comptime bit_count: usize, comptime w: usize) u32 {
    const start = w * 32;
    if (bit_count <= start) return 0;
    const rem = bit_count - start;
    if (rem >= 32) return std.math.maxInt(u32);
    return (@as(u32, 1) << @intCast(rem)) - 1;
}

// ── Comptime Canonical ABI Type Reflection ─────────────────────────────────

pub const TypeLayout = struct {
    size: u32,
    alignment: u32,
    flat_count: u32,
    flat_types: []const FlatValType,
    needs_memory: bool = false,
    needs_realloc: bool = false,
    contains_string: bool = false,
    is_blittable: bool = false,
};

pub fn alignForward(offset: u32, alignment: u32) u32 {
    std.debug.assert(alignment >= 1 and std.math.isPowerOfTwo(alignment));
    return (offset + (alignment - 1)) & ~(alignment - 1);
}

pub fn isBlittable(comptime T: type, comptime arch: Arch) bool {
    return (comptime layoutOf(T, arch)).is_blittable;
}

pub fn layoutOf(comptime T: type, comptime arch: Arch) TypeLayout {
    return comptime computeLayout(T, arch);
}

fn computeLayout(comptime T: type, comptime arch: Arch) TypeLayout {
    @setEvalBranchQuota(200_000);
    const is_le = builtin.cpu.arch.endian() == .little;

    if (T == void) {
        return .{
            .size = 0,
            .alignment = 1,
            .flat_count = 0,
            .flat_types = &.{},
            .is_blittable = true,
        };
    }

    if (isCharType(T)) {
        return .{
            .size = 4,
            .alignment = 4,
            .flat_count = 1,
            .flat_types = &.{.i32},
            .is_blittable = false,
        };
    }

    return switch (@typeInfo(T)) {
        .bool => .{
            .size = 1,
            .alignment = 1,
            .flat_count = 1,
            .flat_types = &.{.i32},
            .is_blittable = false,
        },
        .int => |int| switch (int.bits) {
            8 => .{
                .size = 1,
                .alignment = 1,
                .flat_count = 1,
                .flat_types = &.{.i32},
                .is_blittable = is_le and @sizeOf(T) == 1,
            },
            16 => .{
                .size = 2,
                .alignment = 2,
                .flat_count = 1,
                .flat_types = &.{.i32},
                .is_blittable = is_le and @sizeOf(T) == 2 and @alignOf(T) == 2,
            },
            32 => .{
                .size = 4,
                .alignment = 4,
                .flat_count = 1,
                .flat_types = &.{.i32},
                .is_blittable = is_le and @sizeOf(T) == 4 and @alignOf(T) == 4,
            },
            64 => .{
                .size = 8,
                .alignment = 8,
                .flat_count = 1,
                .flat_types = &.{.i64},
                .is_blittable = is_le and @sizeOf(T) == 8 and @alignOf(T) == 8,
            },
            else => @compileError("Unsupported integer width in Canonical ABI: " ++ @typeName(T)),
        },
        .float => |fl| switch (fl.bits) {
            32 => .{
                .size = 4,
                .alignment = 4,
                .flat_count = 1,
                .flat_types = &.{.f32},
                .is_blittable = is_le and @sizeOf(T) == 4 and @alignOf(T) == 4,
            },
            64 => .{
                .size = 8,
                .alignment = 8,
                .flat_count = 1,
                .flat_types = &.{.f64},
                .is_blittable = is_le and @sizeOf(T) == 8 and @alignOf(T) == 8,
            },
            else => @compileError("Unsupported float width in Canonical ABI: " ++ @typeName(T)),
        },
        .@"enum" => |en| blk: {
            const disc_size: u32 = if (en.field_names.len <= 256)
                1
            else if (en.field_names.len <= 65536)
                2
            else
                4;
            break :blk .{
                .size = disc_size,
                .alignment = disc_size,
                .flat_count = 1,
                .flat_types = &.{.i32},
                .is_blittable = false,
            };
        },
        .pointer => |pt| switch (pt.size) {
            .slice => blk: {
                const E = pt.child;
                const elem_layout = computeLayout(E, arch);
                const addr_size: u32 = @sizeOf(AddrInt(arch));
                const addr_ft = arch.flatAddrValType();
                const flat_arr = [2]FlatValType{ addr_ft, addr_ft };
                break :blk .{
                    .size = 2 * addr_size,
                    .alignment = addr_size,
                    .flat_count = 2,
                    .flat_types = &flat_arr,
                    .needs_memory = true,
                    .needs_realloc = true,
                    .contains_string = elem_layout.contains_string,
                    .is_blittable = false,
                };
            },
            else => @compileError("Unsupported non-slice pointer in Canonical ABI: " ++ @typeName(T)),
        },
        .array => |ar| blk: {
            if (ar.len == 0) {
                break :blk .{
                    .size = 0,
                    .alignment = 1,
                    .flat_count = 0,
                    .flat_types = &.{},
                    .is_blittable = true,
                };
            }
            const elem_layout = computeLayout(ar.child, arch);
            const total_flat: u32 = @intCast(ar.len * elem_layout.flat_count);
            var flat_buf: [total_flat]FlatValType = undefined;
            for (0..ar.len) |i| {
                for (0..elem_layout.flat_count) |j| {
                    flat_buf[i * elem_layout.flat_count + j] = elem_layout.flat_types[j];
                }
            }
            const frozen = flat_buf;
            const total_size: u32 = @intCast(ar.len * elem_layout.size);
            break :blk .{
                .size = total_size,
                .alignment = elem_layout.alignment,
                .flat_count = total_flat,
                .flat_types = &frozen,
                .needs_memory = elem_layout.needs_memory,
                .needs_realloc = elem_layout.needs_realloc,
                .contains_string = elem_layout.contains_string,
                .is_blittable = is_le and elem_layout.is_blittable and (@sizeOf(T) == total_size) and (@alignOf(T) == elem_layout.alignment),
            };
        },
        .@"struct" => |st| blk: {
            if (isHandleType(T)) {
                break :blk .{
                    .size = 4,
                    .alignment = 4,
                    .flat_count = 1,
                    .flat_types = &.{.i32},
                    .is_blittable = is_le and @sizeOf(T) == 4 and @alignOf(T) == 4,
                };
            }
            if (isStringWrapper(T)) {
                const slice_layout = computeLayout([]const u8, arch);
                break :blk .{
                    .size = slice_layout.size,
                    .alignment = slice_layout.alignment,
                    .flat_count = slice_layout.flat_count,
                    .flat_types = slice_layout.flat_types,
                    .needs_memory = true,
                    .needs_realloc = true,
                    .contains_string = true,
                    .is_blittable = false,
                };
            }
            if (st.layout == .@"packed") {
                const bit_count: u32 = if (@hasDecl(T, "wit_flags_count"))
                    T.wit_flags_count
                else
                    @bitSizeOf(st.backing_integer.?);

                if (bit_count == 0) {
                    break :blk .{
                        .size = 0,
                        .alignment = 1,
                        .flat_count = 0,
                        .flat_types = &.{},
                        .is_blittable = false,
                    };
                }

                const size: u32 = if (bit_count <= 8)
                    1
                else if (bit_count <= 16)
                    2
                else if (bit_count <= 32)
                    4
                else
                    ((bit_count + 31) / 32) * 4;

                const alignment: u32 = if (bit_count <= 8)
                    1
                else if (bit_count <= 16)
                    2
                else
                    4;

                const flat_count: u32 = (bit_count + 31) / 32;
                var flat_buf: [flat_count]FlatValType = undefined;
                for (0..flat_count) |i| flat_buf[i] = .i32;
                const frozen = flat_buf;
                break :blk .{
                    .size = size,
                    .alignment = alignment,
                    .flat_count = flat_count,
                    .flat_types = &frozen,
                    .is_blittable = false,
                };
            }

            // Record or tuple struct
            var offset: u32 = 0;
            var max_align: u32 = 1;
            var total_flat: u32 = 0;
            var needs_memory = false;
            var needs_realloc = false;
            var contains_string = false;
            var all_fields_blittable = is_le and (st.layout == .@"extern" or st.field_types.len == 0);

            for (st.field_types, 0..) |FT, i| {
                if (st.field_attrs[i].@"comptime") continue;
                const fl = computeLayout(FT, arch);
                offset = alignForward(offset, fl.alignment);
                if (all_fields_blittable) {
                    if (!fl.is_blittable or @offsetOf(T, st.field_names[i]) != offset or @sizeOf(FT) != fl.size) {
                        all_fields_blittable = false;
                    }
                }
                offset += fl.size;
                max_align = @max(max_align, fl.alignment);
                total_flat += fl.flat_count;
                needs_memory = needs_memory or fl.needs_memory;
                needs_realloc = needs_realloc or fl.needs_realloc;
                contains_string = contains_string or fl.contains_string;
            }
            const total_size = alignForward(offset, max_align);
            if (all_fields_blittable) {
                if (needs_memory or @sizeOf(T) != total_size or (total_size > 0 and @alignOf(T) != max_align)) {
                    all_fields_blittable = false;
                }
            }

            var flat_buf: [total_flat]FlatValType = undefined;
            var cursor: usize = 0;
            for (st.field_types, 0..) |FT, i| {
                if (st.field_attrs[i].@"comptime") continue;
                const fl = computeLayout(FT, arch);
                for (fl.flat_types) |ft| {
                    flat_buf[cursor] = ft;
                    cursor += 1;
                }
            }
            const frozen = flat_buf;
            break :blk .{
                .size = total_size,
                .alignment = max_align,
                .flat_count = total_flat,
                .flat_types = &frozen,
                .needs_memory = needs_memory,
                .needs_realloc = needs_realloc,
                .contains_string = contains_string,
                .is_blittable = all_fields_blittable,
            };
        },
        .optional => |op| blk: {
            const payload = computeLayout(op.child, arch);
            const payload_offset = alignForward(1, payload.alignment);
            const alignment = @max(@as(u32, 1), payload.alignment);
            const size = alignForward(payload_offset + payload.size, alignment);
            const flat_count: u32 = @as(u32, 1) + payload.flat_count;
            var flat_buf: [flat_count]FlatValType = undefined;
            flat_buf[0] = .i32;
            for (payload.flat_types, 0..) |ft, i| {
                flat_buf[1 + i] = ft;
            }
            const frozen = flat_buf;
            break :blk .{
                .size = size,
                .alignment = alignment,
                .flat_count = flat_count,
                .flat_types = &frozen,
                .needs_memory = payload.needs_memory,
                .needs_realloc = payload.needs_realloc,
                .contains_string = payload.contains_string,
                .is_blittable = false,
            };
        },
        .@"union" => |un| blk: {
            if (un.tag_type == null) {
                @compileError("Canonical ABI requires tagged unions: " ++ @typeName(T));
            }
            const case_count = un.field_names.len;
            const disc_size = variantDiscSize(case_count);
            const disc_align = disc_size;

            var max_case_align: u32 = 1;
            var max_case_size: u32 = 0;
            var max_case_flat: u32 = 0;
            var needs_memory = false;
            var needs_realloc = false;
            var contains_string = false;

            for (un.field_types) |CaseT| {
                const cl = computeLayout(CaseT, arch);
                max_case_align = @max(max_case_align, cl.alignment);
                max_case_size = @max(max_case_size, cl.size);
                max_case_flat = @max(max_case_flat, cl.flat_count);
                needs_memory = needs_memory or cl.needs_memory;
                needs_realloc = needs_realloc or cl.needs_realloc;
                contains_string = contains_string or cl.contains_string;
            }

            const payload_offset = alignForward(disc_size, max_case_align);
            const alignment = @max(disc_align, max_case_align);
            const size = alignForward(payload_offset + max_case_size, alignment);
            const flat_count: u32 = @as(u32, 1) + max_case_flat;

            var flat_buf: [flat_count]FlatValType = undefined;
            var slot_initialized: [max_case_flat]bool = @splat(false);
            flat_buf[0] = .i32;

            for (un.field_types) |CaseT| {
                const cl = computeLayout(CaseT, arch);
                for (cl.flat_types, 0..) |ft, j| {
                    if (!slot_initialized[j]) {
                        flat_buf[1 + j] = ft;
                        slot_initialized[j] = true;
                    } else {
                        flat_buf[1 + j] = joinFlatType(flat_buf[1 + j], ft);
                    }
                }
            }
            const frozen = flat_buf;
            break :blk .{
                .size = size,
                .alignment = alignment,
                .flat_count = flat_count,
                .flat_types = &frozen,
                .needs_memory = needs_memory,
                .needs_realloc = needs_realloc,
                .contains_string = contains_string,
                .is_blittable = false,
            };
        },
        .error_set => |es| blk: {
            const names = es.error_names orelse @compileError("anyerror is not supported in Canonical ABI; use an explicit error set");
            const count = names.len;
            const disc_size: u32 = if (count <= 256) 1 else if (count <= 65536) 2 else 4;
            break :blk .{
                .size = disc_size,
                .alignment = disc_size,
                .flat_count = 1,
                .flat_types = &.{.i32},
                .is_blittable = false,
            };
        },
        .error_union => |eu| blk: {
            const ok_layout = computeLayout(eu.payload, arch);
            const err_layout = computeLayout(eu.error_set, arch);
            const max_case_align = @max(ok_layout.alignment, err_layout.alignment);
            const max_case_size = @max(ok_layout.size, err_layout.size);
            const max_case_flat = @max(ok_layout.flat_count, err_layout.flat_count);
            const payload_offset = alignForward(1, max_case_align);
            const alignment = @max(@as(u32, 1), max_case_align);
            const size = alignForward(payload_offset + max_case_size, alignment);
            const flat_count: u32 = @as(u32, 1) + max_case_flat;

            var flat_buf: [flat_count]FlatValType = undefined;
            flat_buf[0] = .i32;
            for (0..max_case_flat) |j| {
                if (j < ok_layout.flat_count and j < err_layout.flat_count) {
                    flat_buf[1 + j] = joinFlatType(ok_layout.flat_types[j], err_layout.flat_types[j]);
                } else if (j < ok_layout.flat_count) {
                    flat_buf[1 + j] = ok_layout.flat_types[j];
                } else {
                    flat_buf[1 + j] = err_layout.flat_types[j];
                }
            }
            const frozen = flat_buf;
            break :blk .{
                .size = size,
                .alignment = alignment,
                .flat_count = flat_count,
                .flat_types = &frozen,
                .needs_memory = ok_layout.needs_memory,
                .needs_realloc = ok_layout.needs_realloc,
                .contains_string = ok_layout.contains_string,
                .is_blittable = false,
            };
        },
        else => @compileError("Unsupported Zig type in Canonical ABI: " ++ @typeName(T)),
    };
}

/// Compute the Canonical ABI byte offset of `field_idx` inside a record or tuple `T`.
pub fn fieldOffset(comptime T: type, comptime arch: Arch, comptime field_idx: usize) u32 {
    return comptime blk: {
        const st = @typeInfo(T).@"struct";
        var offset: u32 = 0;
        for (st.field_types, 0..) |FT, i| {
            if (st.field_attrs[i].@"comptime") {
                if (i == field_idx) break :blk offset;
                continue;
            }
            const fl = layoutOf(FT, arch);
            offset = alignForward(offset, fl.alignment);
            if (i == field_idx) break :blk offset;
            offset += fl.size;
        }
        @compileError("Field index out of bounds in fieldOffset");
    };
}

pub fn optionPayloadOffset(comptime T: type, comptime arch: Arch) u32 {
    return comptime blk: {
        const op = @typeInfo(T).optional;
        const payload = layoutOf(op.child, arch);
        break :blk alignForward(1, payload.alignment);
    };
}

pub fn variantDiscSize(case_count: usize) u32 {
    return if (case_count <= 256) 1 else if (case_count <= 65536) 2 else 4;
}

pub fn variantPayloadOffset(comptime T: type, comptime arch: Arch) u32 {
    return comptime blk: {
        switch (@typeInfo(T)) {
            .@"union" => |un| {
                const disc_size = variantDiscSize(un.field_names.len);
                var max_case_align: u32 = 1;
                for (un.field_types) |CaseT| {
                    const cl = layoutOf(CaseT, arch);
                    max_case_align = @max(max_case_align, cl.alignment);
                }
                break :blk alignForward(disc_size, max_case_align);
            },
            .error_union => |eu| {
                const ok_layout = layoutOf(eu.payload, arch);
                const err_layout = layoutOf(eu.error_set, arch);
                break :blk alignForward(1, @max(ok_layout.alignment, err_layout.alignment));
            },
            else => @compileError("Expected tagged union or error union"),
        }
    };
}

// ── Linear Memory Context & Bump Allocator ─────────────────────────────────

pub const ReallocFn = *const fn (
    ctx: ?*anyopaque,
    orig_ptr: usize,
    orig_size: usize,
    alignment: usize,
    new_size: usize,
) Error!usize;

pub const PostReturnFn = *const fn (ctx: ?*anyopaque, ret_val: usize) void;

pub const AwaitSubtaskFn = *const fn (
    ctx: ?*anyopaque,
    mem_ctx: *MemoryContext,
    packed_status: i32,
) Error!void;

pub const PollTaskFn = *const fn (
    ctx: ?*anyopaque,
    mem_ctx: *MemoryContext,
) Error!void;

pub const MemoryContext = struct {
    memory: []u8,
    base_addr: usize = 0,
    realloc_ctx: ?*anyopaque = null,
    realloc_fn: ?ReallocFn = null,
    post_return_ctx: ?*anyopaque = null,
    post_return_fn: ?PostReturnFn = null,
    task_return_ctx: ?*anyopaque = null,
    task_return_fn: ?PostReturnFn = null,
    await_subtask_ctx: ?*anyopaque = null,
    await_subtask_fn: ?AwaitSubtaskFn = null,
    poll_task_ctx: ?*anyopaque = null,
    poll_task_fn: ?PollTaskFn = null,
    allocator: ?std.mem.Allocator = null,
    zero_copy_slices: bool = true,
    validate_utf8: bool = true,
    strict_utf8_on_u8_slices: bool = false,
    fast_frame_offset: usize = 0,
    fast_bump_cursor: usize = 0,
    fast_scratch_limit: ?usize = null,

    pub inline fn effectiveFastLimit(self: MemoryContext) usize {
        return if (self.fast_scratch_limit) |lim| @min(lim, self.memory.len) else self.memory.len;
    }

    pub fn configureFastScratch(self: *MemoryContext, scratch_addr: usize, scratch_len: usize) Error!void {
        const start_off = try self.addrToOffset(scratch_addr, scratch_len);
        self.fast_frame_offset = start_off;
        self.fast_scratch_limit = start_off + scratch_len;
        self.fast_bump_cursor = start_off;
    }

    pub inline fn addrToOffset(self: MemoryContext, addr: usize, byte_len: usize) Error!usize {
        if (addr < self.base_addr) return error.OutOfBounds;
        const off = addr - self.base_addr;
        if (off > self.memory.len or self.memory.len - off < byte_len) return error.OutOfBounds;
        return off;
    }

    pub fn realloc(self: MemoryContext, alignment: usize, byte_len: usize) Error!usize {
        if (self.realloc_fn) |f| {
            const raw_ptr = try f(self.realloc_ctx, 0, 0, alignment, byte_len);
            const ptr = if (self.base_addr != 0 and raw_ptr < self.base_addr)
                self.base_addr + raw_ptr
            else
                raw_ptr;
            if (alignment > 1 and (ptr % alignment) != 0) return error.AlignmentError;
            _ = try self.addrToOffset(ptr, byte_len);
            return ptr;
        }
        if (byte_len == 0) {
            const aligned_base = if (self.base_addr == 0)
                alignment
            else
                (self.base_addr + (alignment - 1)) & ~(alignment - 1);
            if (aligned_base >= self.base_addr and aligned_base - self.base_addr <= self.memory.len) {
                return aligned_base;
            }
            return self.base_addr;
        }
        return error.MissingRealloc;
    }
};

/// Simple bump allocator over a region of linear memory for use as `cabi_realloc`
/// in tests and standalone host/guest buffers.
pub const BumpAllocator = struct {
    offset: usize = 64,
    limit: usize,

    pub fn init(start_offset: usize, limit: usize) BumpAllocator {
        return .{ .offset = start_offset, .limit = limit };
    }

    pub fn realloc(
        ctx: ?*anyopaque,
        orig_ptr: usize,
        orig_size: usize,
        alignment: usize,
        new_size: usize,
    ) Error!usize {
        _ = orig_ptr;
        _ = orig_size;
        const self: *BumpAllocator = @ptrCast(@alignCast(ctx orelse return error.MissingRealloc));
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.AlignmentError;
        const aligned = (self.offset + (alignment - 1)) & ~(alignment - 1);
        if (aligned > self.limit or self.limit - aligned < new_size) return error.OutOfMemory;
        self.offset = aligned + new_size;
        return aligned;
    }

    pub fn memoryContext(self: *BumpAllocator, memory: []u8) MemoryContext {
        return .{
            .memory = memory,
            .realloc_ctx = self,
            .realloc_fn = &BumpAllocator.realloc,
        };
    }
};

// ── Comptime Inlined Linear Memory Store & Load ────────────────────────────

fn ptrInMemory(ctx: MemoryContext, ptr_addr: usize) bool {
    if (ctx.memory.len == 0) return false;
    const base = @intFromPtr(ctx.memory.ptr);
    return ptr_addr >= base and ptr_addr < base + ctx.memory.len;
}

fn freeLoadedSlices(comptime T: type, ctx: MemoryContext, val: T) void {
    const alloc = ctx.allocator orelse return;
    if (comptime isStringWrapper(T)) {
        freeLoadedSlices([]const u8, ctx, val.bytes);
        return;
    }
    switch (@typeInfo(T)) {
        .pointer => |pt| if (comptime pt.size == .slice) {
            for (val) |elem| {
                freeLoadedSlices(pt.child, ctx, elem);
            }
            if (comptime pt.sentinel_ptr != null) {
                alloc.free(val);
            } else if (val.len > 0 and !ptrInMemory(ctx, @intFromPtr(val.ptr))) {
                alloc.free(val);
            } else if (val.len == 0 and comptime !pt.attrs.@"const") {
                alloc.free(val);
            }
        },
        .array => |ar| {
            for (val) |elem| {
                freeLoadedSlices(ar.child, ctx, elem);
            }
        },
        .@"struct" => |st| {
            if (comptime st.layout == .@"packed" or isHandleType(T)) return;
            inline for (st.field_names, 0..) |fname, i| {
                if (comptime st.field_attrs[i].@"comptime") continue;
                freeLoadedSlices(st.field_types[i], ctx, @field(val, fname));
            }
        },
        .optional => |op| {
            if (val) |payload| {
                freeLoadedSlices(op.child, ctx, payload);
            }
        },
        .@"union" => |un| {
            if (comptime un.tag_type != null) {
                const active = std.meta.activeTag(val);
                inline for (un.field_names, 0..) |fname, idx| {
                    if (active == @field(un.tag_type.?, fname)) {
                        freeLoadedSlices(un.field_types[idx], ctx, @field(val, fname));
                        return;
                    }
                }
            }
        },
        .error_union => |eu| {
            if (val) |ok_val| {
                freeLoadedSlices(eu.payload, ctx, ok_val);
            } else |_| {}
        },
        else => {},
    }
}

fn storeSliceData(comptime E: type, comptime arch: Arch, ctx: MemoryContext, val: []const E) Error!usize {
    if (comptime E == u8) {
        if (ctx.validate_utf8 and ctx.strict_utf8_on_u8_slices and !std.unicode.utf8ValidateSlice(val)) {
            return error.InvalidUtf8;
        }
    }
    const elem_layout = comptime layoutOf(E, arch);
    if (comptime E == u8) {
        if (ctx.validate_utf8 and ctx.strict_utf8_on_u8_slices and !std.unicode.utf8ValidateSlice(val)) {
            return error.InvalidUtf8;
        }
    }
    const byte_len = std.math.mul(usize, val.len, elem_layout.size) catch return error.OutOfBounds;
    if (byte_len > 0x7fff_ffff) return error.OutOfBounds;
    const data_ptr = try ctx.realloc(elem_layout.alignment, byte_len);
    const data_off = try ctx.addrToOffset(data_ptr, byte_len);

    if (comptime elem_layout.is_blittable and @sizeOf(E) == elem_layout.size) {
        if (byte_len > 0) {
            const src_bytes = std.mem.sliceAsBytes(val);
            @memcpy(ctx.memory[data_off..][0..byte_len], src_bytes);
        }
    } else {
        for (val, 0..) |elem, i| {
            try storeToMemory(E, arch, ctx, data_ptr + i * elem_layout.size, elem);
        }
    }
    return data_ptr;
}

fn loadSliceData(comptime SliceT: type, comptime arch: Arch, ctx: MemoryContext, data_ptr: usize, len: usize) Error!SliceT {
    const pt = @typeInfo(SliceT).pointer;
    const E = pt.child;
    const elem_layout = comptime layoutOf(E, arch);
    const byte_len = std.math.mul(usize, len, elem_layout.size) catch return error.OutOfBounds;
    if (byte_len > 0x7fff_ffff) return error.OutOfBounds;
    const data_off = try ctx.addrToOffset(data_ptr, byte_len);
    if (comptime elem_layout.alignment > 1) {
        if ((len > 0 or data_ptr != 0) and (data_ptr % elem_layout.alignment != 0)) {
            return error.UnalignedPointer;
        }
    }

    if (comptime E == u8) {
        const raw_slice = ctx.memory[data_off..][0..len];
        if (ctx.validate_utf8 and ctx.strict_utf8_on_u8_slices and !std.unicode.utf8ValidateSlice(raw_slice)) {
            return error.InvalidUtf8;
        }
        if (comptime pt.sentinel_ptr != null) {
            const alloc = ctx.allocator orelse return error.MissingAllocator;
            const sentinel_val = @as(*const u8, @ptrCast(@alignCast(pt.sentinel_ptr.?))).*;
            const buf = alloc.allocSentinel(u8, raw_slice.len, sentinel_val) catch return error.OutOfMemory;
            @memcpy(buf, raw_slice);
            return buf;
        }
        if (ctx.zero_copy_slices) {
            return raw_slice;
        }
        const alloc = ctx.allocator orelse return error.MissingAllocator;
        return alloc.dupe(u8, raw_slice) catch return error.OutOfMemory;
    }

    if (comptime elem_layout.is_blittable and @sizeOf(E) == elem_layout.size) {
        if (ctx.zero_copy_slices and comptime pt.attrs.@"const" and pt.sentinel_ptr == null) {
            if (len == 0) return &[_]E{};
            const byte_slice = ctx.memory[data_off..][0..byte_len];
            if (@intFromPtr(byte_slice.ptr) % @alignOf(E) == 0) {
                const typed_ptr: [*]const E = @ptrCast(@alignCast(byte_slice.ptr));
                return typed_ptr[0..len];
            } else if (ctx.allocator) |alloc| {
                const out = alloc.alloc(E, len) catch return error.OutOfMemory;
                @memcpy(std.mem.sliceAsBytes(out), byte_slice);
                return out;
            } else {
                return error.AlignmentError;
            }
        }
        const alloc = ctx.allocator orelse return error.MissingAllocator;
        const out = alloc.alloc(E, len) catch return error.OutOfMemory;
        if (byte_len > 0) {
            @memcpy(std.mem.sliceAsBytes(out), ctx.memory[data_off..][0..byte_len]);
        }
        return out;
    }

    if (len == 0) {
        if (comptime pt.attrs.@"const" and pt.sentinel_ptr == null) return &[_]E{};
        const alloc = ctx.allocator orelse return error.MissingAllocator;
        return alloc.alloc(E, 0) catch return error.OutOfMemory;
    }
    const alloc = ctx.allocator orelse return error.MissingAllocator;
    const out = alloc.alloc(E, len) catch return error.OutOfMemory;
    var loaded_count: usize = 0;
    errdefer {
        for (out[0..loaded_count]) |item| {
            freeLoadedSlices(E, ctx, item);
        }
        alloc.free(out);
    }
    for (out, 0..) |*slot, i| {
        slot.* = try loadFromMemory(E, arch, ctx, data_ptr + i * elem_layout.size);
        loaded_count = i + 1;
    }
    return out;
}

fn errorToIndex(comptime ES: type, err: ES) u32 {
    const es = @typeInfo(ES).error_set;
    const names = es.error_names orelse @compileError("anyerror is not supported in Canonical ABI; use an explicit error set");
    inline for (names, 0..) |name, idx| {
        if (err == @field(ES, name)) return @intCast(idx);
    }
    unreachable;
}

fn indexToErrorOut(comptime ES: type, raw: u32, out: *ES) Error!void {
    const es = @typeInfo(ES).error_set;
    const names = es.error_names orelse @compileError("anyerror is not supported in Canonical ABI; use an explicit error set");
    inline for (names, 0..) |name, idx| {
        if (raw == idx) {
            out.* = @field(ES, name);
            return;
        }
    }
    return error.InvalidDiscriminant;
}

fn loadErrorSetFromMemory(comptime ES: type, comptime arch: Arch, ctx: MemoryContext, addr: usize, out: *ES) Error!void {
    const layout = comptime layoutOf(ES, arch);
    const off = try ctx.addrToOffset(addr, layout.size);
    if (comptime layout.alignment > 1) {
        if ((layout.size > 0 or addr != 0) and (addr % layout.alignment != 0)) {
            return error.UnalignedPointer;
        }
    }
    const raw: u32 = switch (layout.size) {
        1 => ctx.memory[off],
        2 => std.mem.readInt(u16, ctx.memory[off..][0..2], .little),
        4 => std.mem.readInt(u32, ctx.memory[off..][0..4], .little),
        else => unreachable,
    };
    return indexToErrorOut(ES, raw, out);
}

fn raiseErrorByIndex(comptime ES: type, raw: u32) (Error || ES)!noreturn {
    const es = @typeInfo(ES).error_set;
    const names = es.error_names orelse @compileError("anyerror is not supported in Canonical ABI; use an explicit error set");
    inline for (names, 0..) |name, idx| {
        if (raw == idx) return @field(ES, name);
    }
    return error.InvalidDiscriminant;
}

fn needsFlagsWordMasking(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "wit_flags_count") and @hasField(T, "words") and (T.wit_flags_count % 32 != 0);
}

/// Store a Zig value `val` of type `T` into `ctx.memory[addr..]` according to
/// the Canonical ABI layout for `arch`.
pub fn storeToMemory(comptime T: type, comptime arch: Arch, ctx: MemoryContext, addr: usize, val: T) Error!void {
    const layout = comptime layoutOf(T, arch);
    const off = try ctx.addrToOffset(addr, layout.size);
    if (comptime layout.alignment > 1) {
        if ((layout.size > 0 or addr != 0) and (addr % layout.alignment != 0)) {
            return error.UnalignedPointer;
        }
    }

    // Fast path: byte-for-byte blittable scalars and extern structs
    if (comptime layout.is_blittable and @sizeOf(T) == layout.size and !needsFlagsWordMasking(T)) {
        if (comptime layout.size > 0) {
            @memcpy(ctx.memory[off..][0..layout.size], std.mem.asBytes(&val));
        }
        return;
    }

    if (T == void) return;

    if (comptime isCharType(T)) {
        const cp: u21 = if (@typeInfo(T) == .@"enum") @intFromEnum(val) else val;
        _ = try validateChar(cp);
        std.mem.writeInt(u32, ctx.memory[off..][0..4], @as(u32, cp), .little);
        return;
    }

    switch (@typeInfo(T)) {
        .bool => {
            ctx.memory[off] = if (val) 1 else 0;
        },
        .int => |int| switch (int.bits) {
            8 => ctx.memory[off] = @bitCast(val),
            16 => std.mem.writeInt(T, ctx.memory[off..][0..2], val, .little),
            32 => std.mem.writeInt(T, ctx.memory[off..][0..4], val, .little),
            64 => std.mem.writeInt(T, ctx.memory[off..][0..8], val, .little),
            else => unreachable,
        },
        .float => |fl| switch (fl.bits) {
            32 => std.mem.writeInt(u32, ctx.memory[off..][0..4], @bitCast(val), .little),
            64 => std.mem.writeInt(u64, ctx.memory[off..][0..8], @bitCast(val), .little),
            else => unreachable,
        },
        .@"enum" => {
            const raw: u32 = enumToIndex(T, val);
            switch (layout.size) {
                1 => ctx.memory[off] = @intCast(raw),
                2 => std.mem.writeInt(u16, ctx.memory[off..][0..2], @intCast(raw), .little),
                4 => std.mem.writeInt(u32, ctx.memory[off..][0..4], raw, .little),
                else => unreachable,
            }
        },
        .pointer => |pt| switch (pt.size) {
            .slice => {
                const data_ptr = try storeSliceData(pt.child, arch, ctx, val);
                const AddrT = AddrInt(arch);
                const addr_size = @sizeOf(AddrT);
                if (data_ptr > std.math.maxInt(AddrT) or val.len > std.math.maxInt(AddrT)) {
                    return error.OutOfBounds;
                }
                std.mem.writeInt(AddrT, ctx.memory[off..][0..addr_size], @intCast(data_ptr), .little);
                std.mem.writeInt(AddrT, ctx.memory[off + addr_size ..][0..addr_size], @intCast(val.len), .little);
            },
            else => unreachable,
        },
        .array => |ar| {
            const elem_layout = comptime layoutOf(ar.child, arch);
            for (val, 0..) |elem, i| {
                try storeToMemory(ar.child, arch, ctx, addr + i * elem_layout.size, elem);
            }
        },
        .@"struct" => |st| {
            if (comptime isHandleType(T)) {
                std.mem.writeInt(i32, ctx.memory[off..][0..4], val.handle, .little);
                return;
            }
            if (comptime isStringWrapper(T)) {
                if (val.bytes.len > 0x7fff_ffff) return error.OutOfBounds;
                if (ctx.validate_utf8 and !std.unicode.utf8ValidateSlice(val.bytes)) {
                    return error.InvalidUtf8;
                }
                return storeToMemory([]const u8, arch, ctx, addr, val.bytes);
            }
            if (comptime st.layout == .@"packed") {
                const BackingInt = st.backing_integer.?;
                const UnsignedInt = @Int(.unsigned, @bitSizeOf(BackingInt));
                const raw: UnsignedInt = (@as(UnsignedInt, @bitCast(val))) & (comptime packedFlagsMask(T));
                switch (layout.size) {
                    0 => {},
                    1 => ctx.memory[off] = @intCast(raw),
                    2 => std.mem.writeInt(u16, ctx.memory[off..][0..2], @intCast(raw), .little),
                    4 => std.mem.writeInt(u32, ctx.memory[off..][0..4], @intCast(raw), .little),
                    8 => std.mem.writeInt(u64, ctx.memory[off..][0..8], @intCast(raw), .little),
                    else => {
                        inline for (0..layout.flat_count) |w| {
                            const shift = w * 32;
                            const word: u32 = if (comptime shift < @bitSizeOf(UnsignedInt))
                                (if (comptime @bitSizeOf(UnsignedInt) <= 32)
                                    @as(u32, raw >> shift)
                                else
                                    @truncate(raw >> shift))
                            else
                                0;
                            std.mem.writeInt(u32, ctx.memory[off + w * 4 ..][0..4], word, .little);
                        }
                    },
                }
                return;
            }
            if (comptime @hasDecl(T, "wit_flags_count") and @hasField(T, "words")) {
                var masked = val;
                inline for (0..masked.words.len) |w| {
                    masked.words[w] &= comptime flagsWordMask(T.wit_flags_count, w);
                }
                try storeToMemory(@TypeOf(masked.words), arch, ctx, addr, masked.words);
                return;
            }
            inline for (st.field_names, 0..) |fname, i| {
                if (comptime st.field_attrs[i].@"comptime") continue;
                const f_off = comptime fieldOffset(T, arch, i);
                try storeToMemory(st.field_types[i], arch, ctx, addr + f_off, @field(val, fname));
            }
        },
        .optional => |op| {
            const pay_off = comptime optionPayloadOffset(T, arch);
            if (val) |payload| {
                ctx.memory[off] = 1;
                try storeToMemory(op.child, arch, ctx, addr + pay_off, payload);
            } else {
                @memset(ctx.memory[off..][0..layout.size], 0);
            }
        },
        .@"union" => |un| {
            const disc_size = comptime variantDiscSize(un.field_names.len);
            const pay_off = comptime variantPayloadOffset(T, arch);
            @memset(ctx.memory[off..][0..layout.size], 0);
            const active_tag = std.meta.activeTag(val);
            inline for (un.field_names, 0..) |fname, case_idx| {
                const tag_val = @field(un.tag_type.?, fname);
                if (active_tag == tag_val) {
                    switch (disc_size) {
                        1 => ctx.memory[off] = @intCast(case_idx),
                        2 => std.mem.writeInt(u16, ctx.memory[off..][0..2], @intCast(case_idx), .little),
                        4 => std.mem.writeInt(u32, ctx.memory[off..][0..4], @intCast(case_idx), .little),
                        else => unreachable,
                    }
                    try storeToMemory(un.field_types[case_idx], arch, ctx, addr + pay_off, @field(val, fname));
                    return;
                }
            }
        },
        .error_set => {
            const raw = errorToIndex(T, val);
            switch (layout.size) {
                1 => ctx.memory[off] = @intCast(raw),
                2 => std.mem.writeInt(u16, ctx.memory[off..][0..2], @intCast(raw), .little),
                4 => std.mem.writeInt(u32, ctx.memory[off..][0..4], raw, .little),
                else => unreachable,
            }
        },
        .error_union => |eu| {
            const pay_off = comptime variantPayloadOffset(T, arch);
            @memset(ctx.memory[off..][0..layout.size], 0);
            if (val) |ok_val| {
                ctx.memory[off] = 0;
                try storeToMemory(eu.payload, arch, ctx, addr + pay_off, ok_val);
            } else |err_val| {
                ctx.memory[off] = 1;
                try storeToMemory(eu.error_set, arch, ctx, addr + pay_off, err_val);
            }
        },
        else => unreachable,
    }
}

/// Load fields of a non-packed, non-wrapper struct `T` directly into `out.*`
/// without unwrapping nested large struct error unions by value (which can
/// exhaust GP registers on `.stage2_aarch64`).
pub fn loadStructFieldsFromMemory(comptime T: type, comptime arch: Arch, ctx: MemoryContext, addr: usize, out: *T) Error!void {
    const layout = comptime layoutOf(T, arch);
    const off = try ctx.addrToOffset(addr, layout.size);
    if (comptime layout.alignment > 1) {
        if ((layout.size > 0 or addr != 0) and (addr % layout.alignment != 0)) {
            return error.UnalignedPointer;
        }
    }
    const st = @typeInfo(T).@"struct";
    inline for (st.field_names, 0..) |fname, i| {
        if (comptime st.field_attrs[i].@"comptime") continue;
        const FT = st.field_types[i];
        const f_off = comptime fieldOffset(T, arch, i);
        if (comptime layoutOf(FT, arch).is_blittable and @sizeOf(FT) == layoutOf(FT, arch).size and !needsFlagsWordMasking(FT)) {
            @field(out.*, fname) = if (comptime @sizeOf(FT) == 0)
                @as(FT, undefined)
            else
                std.mem.bytesToValue(FT, ctx.memory[off + f_off ..][0..@sizeOf(FT)]);
        } else if (comptime @typeInfo(FT) == .error_set) {
            loadErrorSetFromMemory(FT, arch, ctx, addr + f_off, &@field(out.*, fname)) catch |err| {
                inline for (0..i) |prev_i| {
                    if (comptime !st.field_attrs[prev_i].@"comptime") {
                        freeLoadedSlices(st.field_types[prev_i], ctx, @field(out.*, st.field_names[prev_i]));
                    }
                }
                return err;
            };
        } else if (comptime @typeInfo(FT) == .@"struct" and
            !isHandleType(FT) and
            !isStringWrapper(FT) and
            @typeInfo(FT).@"struct".layout != .@"packed" and
            !(@hasDecl(FT, "wit_flags_count") and @hasField(FT, "words")) and
            !(layoutOf(FT, arch).is_blittable and @sizeOf(FT) == layoutOf(FT, arch).size and !needsFlagsWordMasking(FT)))
        {
            loadStructFieldsFromMemory(FT, arch, ctx, addr + f_off, &@field(out.*, fname)) catch |err| {
                inline for (0..i) |prev_i| {
                    if (comptime !st.field_attrs[prev_i].@"comptime") {
                        freeLoadedSlices(st.field_types[prev_i], ctx, @field(out.*, st.field_names[prev_i]));
                    }
                }
                return err;
            };
        } else {
            @field(out.*, fname) = loadFromMemory(FT, arch, ctx, addr + f_off) catch |err| {
                inline for (0..i) |prev_i| {
                    if (comptime !st.field_attrs[prev_i].@"comptime") {
                        freeLoadedSlices(st.field_types[prev_i], ctx, @field(out.*, st.field_names[prev_i]));
                    }
                }
                return err;
            };
        }
    }
}

/// Load a Zig value of type `T` from `ctx.memory[addr..]` according to the
/// Canonical ABI layout for `arch`.
pub fn loadFromMemory(comptime T: type, comptime arch: Arch, ctx: MemoryContext, addr: usize) CanonResult(T) {
    const layout = comptime layoutOf(T, arch);
    const off = try ctx.addrToOffset(addr, layout.size);
    if (comptime layout.alignment > 1) {
        if ((layout.size > 0 or addr != 0) and (addr % layout.alignment != 0)) {
            return error.UnalignedPointer;
        }
    }

    // Fast path: byte-for-byte blittable scalars and extern structs
    if (comptime layout.is_blittable and @sizeOf(T) == layout.size and !needsFlagsWordMasking(T)) {
        if (comptime layout.size == 0) return @as(T, undefined);
        return std.mem.bytesToValue(T, ctx.memory[off..][0..layout.size]);
    }

    if (T == void) return {};

    if (comptime isCharType(T)) {
        const raw = std.mem.readInt(u32, ctx.memory[off..][0..4], .little);
        const cp = try validateChar(raw);
        return if (@typeInfo(T) == .@"enum") @enumFromInt(cp) else cp;
    }

    switch (@typeInfo(T)) {
        .bool => return ctx.memory[off] != 0,
        .int => |int| return switch (int.bits) {
            8 => @bitCast(ctx.memory[off]),
            16 => std.mem.readInt(T, ctx.memory[off..][0..2], .little),
            32 => std.mem.readInt(T, ctx.memory[off..][0..4], .little),
            64 => std.mem.readInt(T, ctx.memory[off..][0..8], .little),
            else => unreachable,
        },
        .float => |fl| return switch (fl.bits) {
            32 => @bitCast(std.mem.readInt(u32, ctx.memory[off..][0..4], .little)),
            64 => @bitCast(std.mem.readInt(u64, ctx.memory[off..][0..8], .little)),
            else => unreachable,
        },
        .@"enum" => {
            const raw: u32 = switch (layout.size) {
                1 => ctx.memory[off],
                2 => std.mem.readInt(u16, ctx.memory[off..][0..2], .little),
                4 => std.mem.readInt(u32, ctx.memory[off..][0..4], .little),
                else => unreachable,
            };
            return intToEnum(T, raw);
        },
        .pointer => |pt| switch (pt.size) {
            .slice => {
                const AddrT = AddrInt(arch);
                const addr_size = @sizeOf(AddrT);
                const raw_ptr = std.mem.readInt(AddrT, ctx.memory[off..][0..addr_size], .little);
                const raw_len = std.mem.readInt(AddrT, ctx.memory[off + addr_size ..][0..addr_size], .little);
                const data_ptr: usize = std.math.cast(usize, raw_ptr) orelse return error.OutOfBounds;
                const len: usize = std.math.cast(usize, raw_len) orelse return error.OutOfBounds;
                return loadSliceData(T, arch, ctx, data_ptr, len);
            },
            else => unreachable,
        },
        .array => |ar| {
            var out: T = undefined;
            var loaded_elems: usize = 0;
            errdefer {
                for (out[0..loaded_elems]) |item| {
                    freeLoadedSlices(ar.child, ctx, item);
                }
            }
            const elem_layout = comptime layoutOf(ar.child, arch);
            for (&out, 0..) |*slot, i| {
                slot.* = try loadFromMemory(ar.child, arch, ctx, addr + i * elem_layout.size);
                loaded_elems = i + 1;
            }
            return out;
        },
        .@"struct" => |st| {
            if (comptime isHandleType(T)) {
                return .{ .handle = std.mem.readInt(i32, ctx.memory[off..][0..4], .little) };
            }
            if (comptime isStringWrapper(T)) {
                const bytes = try loadFromMemory([]const u8, arch, ctx, addr);
                errdefer freeLoadedSlices([]const u8, ctx, bytes);
                if (ctx.validate_utf8 and !std.unicode.utf8ValidateSlice(bytes)) {
                    return error.InvalidUtf8;
                }
                return .{ .bytes = bytes };
            }
            if (comptime st.layout == .@"packed") {
                const BackingInt = st.backing_integer.?;
                const UnsignedInt = @Int(.unsigned, @bitSizeOf(BackingInt));
                const raw: UnsignedInt = switch (layout.size) {
                    0 => 0,
                    1 => @truncate(ctx.memory[off]),
                    2 => @truncate(std.mem.readInt(u16, ctx.memory[off..][0..2], .little)),
                    4 => @truncate(std.mem.readInt(u32, ctx.memory[off..][0..4], .little)),
                    8 => @truncate(std.mem.readInt(u64, ctx.memory[off..][0..8], .little)),
                    else => blk: {
                        var acc: UnsignedInt = 0;
                        inline for (0..layout.flat_count) |w| {
                            const shift = w * 32;
                            if (comptime shift < @bitSizeOf(UnsignedInt)) {
                                const word = std.mem.readInt(u32, ctx.memory[off + w * 4 ..][0..4], .little);
                                const rem_bits = @bitSizeOf(UnsignedInt) - shift;
                                const part: UnsignedInt = if (comptime rem_bits < 32)
                                    @as(UnsignedInt, @as(@Int(.unsigned, rem_bits), @truncate(word)))
                                else
                                    @as(UnsignedInt, word);
                                acc |= part << shift;
                            }
                        }
                        break :blk acc;
                    },
                };
                return @bitCast(raw & (comptime packedFlagsMask(T)));
            }
            if (comptime @hasDecl(T, "wit_flags_count") and @hasField(T, "words")) {
                var out: T = .{ .words = try loadFromMemory(@FieldType(T, "words"), arch, ctx, addr) };
                inline for (0..out.words.len) |w| {
                    out.words[w] &= comptime flagsWordMask(T.wit_flags_count, w);
                }
                return out;
            }
            var out: T = undefined;
            try loadStructFieldsFromMemory(T, arch, ctx, addr, &out);
            return out;
        },
        .optional => |op| {
            const disc = ctx.memory[off];
            const pay_off = comptime optionPayloadOffset(T, arch);
            return switch (disc) {
                0 => null,
                1 => blk: {
                    if (comptime @typeInfo(op.child) == .error_set) {
                        var ev: op.child = undefined;
                        try loadErrorSetFromMemory(op.child, arch, ctx, addr + pay_off, &ev);
                        break :blk ev;
                    }
                    break :blk try loadFromMemory(op.child, arch, ctx, addr + pay_off);
                },
                else => error.InvalidDiscriminant,
            };
        },
        .@"union" => |un| {
            const disc_size = comptime variantDiscSize(un.field_names.len);
            const pay_off = comptime variantPayloadOffset(T, arch);
            const disc: u32 = switch (disc_size) {
                1 => ctx.memory[off],
                2 => std.mem.readInt(u16, ctx.memory[off..][0..2], .little),
                4 => std.mem.readInt(u32, ctx.memory[off..][0..4], .little),
                else => unreachable,
            };
            inline for (un.field_names, 0..) |fname, case_idx| {
                if (disc == case_idx) {
                    const CaseT = un.field_types[case_idx];
                    if (comptime @typeInfo(CaseT) == .error_set) {
                        var ev: CaseT = undefined;
                        try loadErrorSetFromMemory(CaseT, arch, ctx, addr + pay_off, &ev);
                        return @unionInit(T, fname, ev);
                    }
                    const pay = try loadFromMemory(CaseT, arch, ctx, addr + pay_off);
                    return @unionInit(T, fname, pay);
                }
            }
            return error.InvalidDiscriminant;
        },
        .error_set => {
            const raw: u32 = switch (layout.size) {
                1 => ctx.memory[off],
                2 => std.mem.readInt(u16, ctx.memory[off..][0..2], .little),
                4 => std.mem.readInt(u32, ctx.memory[off..][0..4], .little),
                else => unreachable,
            };
            return try raiseErrorByIndex(T, raw);
        },
        .error_union => |eu| {
            const disc = ctx.memory[off];
            const pay_off = comptime variantPayloadOffset(T, arch);
            const err_layout = comptime layoutOf(eu.error_set, arch);
            switch (disc) {
                0 => return try loadFromMemory(eu.payload, arch, ctx, addr + pay_off),
                1 => {
                    const raw: u32 = switch (err_layout.size) {
                        1 => ctx.memory[off + pay_off],
                        2 => std.mem.readInt(u16, ctx.memory[off + pay_off ..][0..2], .little),
                        4 => std.mem.readInt(u32, ctx.memory[off + pay_off ..][0..4], .little),
                        else => unreachable,
                    };
                    return try raiseErrorByIndex(eu.error_set, raw);
                },
                else => return error.InvalidDiscriminant,
            }
        },
        else => unreachable,
    }
}

// ── Comptime Inlined Flat Register Lower & Lift ────────────────────────────

/// Construct the Zig tuple type matching `layoutOf(T, arch).flat_types`.
pub fn FlatTuple(comptime T: type, comptime arch: Arch) type {
    const layout = comptime layoutOf(T, arch);
    var types: [layout.flat_count]type = undefined;
    for (layout.flat_types, 0..) |ft, i| {
        types[i] = ToZigType(ft);
    }
    return @Tuple(&types);
}

pub fn zeroFlatVal(comptime ft: FlatValType) ToZigType(ft) {
    return switch (ft) {
        .i32 => 0,
        .i64 => 0,
        .f32 => 0.0,
        .f64 => 0.0,
    };
}

/// Coerce a case's flat slot value of `src_type` into the variant's joined slot
/// of `dst_type` per the Canonical ABI rules.
pub fn coerceToJoinedSlot(
    comptime src_type: FlatValType,
    comptime dst_type: FlatValType,
    v: ToZigType(src_type),
) ToZigType(dst_type) {
    if (comptime src_type == dst_type) return v;
    if (comptime src_type == .f32 and dst_type == .i32) return @bitCast(v);
    if (comptime src_type == .i32 and dst_type == .i64) return @intCast(@as(u32, @bitCast(v)));
    if (comptime src_type == .f32 and dst_type == .i64) return @intCast(@as(u32, @bitCast(v)));
    if (comptime src_type == .f64 and dst_type == .i64) return @bitCast(v);
    @compileError("Invalid Canonical ABI flat slot coercion");
}

/// Reverse `coerceToJoinedSlot`, extracting `dst_type` from the joined `src_type` slot.
pub fn uncoerceFromJoinedSlot(
    comptime dst_type: FlatValType,
    comptime src_type: FlatValType,
    v: ToZigType(src_type),
) ToZigType(dst_type) {
    if (comptime dst_type == src_type) return v;
    if (comptime dst_type == .f32 and src_type == .i32) return @bitCast(v);
    if (comptime dst_type == .i32 and src_type == .i64) return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(v)))));
    if (comptime dst_type == .f32 and src_type == .i64) return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(v)))));
    if (comptime dst_type == .f64 and src_type == .i64) return @bitCast(v);
    @compileError("Invalid Canonical ABI flat slot uncoercion");
}

/// Lower a Zig value `val` of type `T` into its flat register tuple for `arch`.
pub inline fn lowerToFlat(comptime T: type, comptime arch: Arch, ctx: MemoryContext, val: T) Error!FlatTuple(T, arch) {
    const layout = comptime layoutOf(T, arch);

    if (T == void) return .{};

    if (comptime isCharType(T)) {
        const cp: u21 = if (@typeInfo(T) == .@"enum") @intFromEnum(val) else val;
        _ = try validateChar(cp);
        return .{@as(i32, @intCast(cp))};
    }

    return switch (@typeInfo(T)) {
        .bool => .{@as(i32, if (val) 1 else 0)},
        .int => |int| switch (int.bits) {
            8, 16, 32 => switch (int.signedness) {
                .unsigned => .{@as(i32, @bitCast(@as(u32, val)))},
                .signed => .{@as(i32, val)},
            },
            64 => .{@as(i64, @bitCast(val))},
            else => unreachable,
        },
        .float => .{val},
        .@"enum" => .{@as(i32, @intCast(enumToIndex(T, val)))},
        .pointer => |pt| switch (pt.size) {
            .slice => blk: {
                const data_ptr = try storeSliceData(pt.child, arch, ctx, val);
                const AddrT = AddrInt(arch);
                const FlatAddrT = FlatAddrType(arch);
                if (data_ptr > std.math.maxInt(AddrT) or val.len > std.math.maxInt(AddrT)) {
                    return error.OutOfBounds;
                }
                const p_flat: FlatAddrT = @bitCast(@as(AddrT, @intCast(data_ptr)));
                const l_flat: FlatAddrT = @bitCast(@as(AddrT, @intCast(val.len)));
                break :blk .{ p_flat, l_flat };
            },
            else => unreachable,
        },
        .array => |ar| blk: {
            var out: FlatTuple(T, arch) = undefined;
            const elem_layout = comptime layoutOf(ar.child, arch);
            inline for (0..ar.len) |i| {
                const sub = try lowerToFlat(ar.child, arch, ctx, val[i]);
                inline for (0..elem_layout.flat_count) |j| {
                    out[i * elem_layout.flat_count + j] = sub[j];
                }
            }
            break :blk out;
        },
        .@"struct" => |st| blk: {
            if (comptime isHandleType(T)) {
                break :blk .{val.handle};
            }
            if (comptime isStringWrapper(T)) {
                if (val.bytes.len > 0x7fff_ffff) return error.OutOfBounds;
                if (ctx.validate_utf8 and !std.unicode.utf8ValidateSlice(val.bytes)) {
                    return error.InvalidUtf8;
                }
                break :blk try lowerToFlat([]const u8, arch, ctx, val.bytes);
            }
            if (comptime st.layout == .@"packed") {
                const BackingInt = st.backing_integer.?;
                const UnsignedInt = @Int(.unsigned, @bitSizeOf(BackingInt));
                const raw: UnsignedInt = (@as(UnsignedInt, @bitCast(val))) & (comptime packedFlagsMask(T));
                var out: FlatTuple(T, arch) = undefined;
                inline for (0..layout.flat_count) |w| {
                    const shift = w * 32;
                    const word: u32 = if (comptime shift < @bitSizeOf(UnsignedInt))
                        (if (comptime @bitSizeOf(UnsignedInt) <= 32)
                            @as(u32, raw >> shift)
                        else
                            @truncate(raw >> shift))
                    else
                        0;
                    out[w] = @bitCast(word);
                }
                break :blk out;
            }
            if (comptime @hasDecl(T, "wit_flags_count") and @hasField(T, "words")) {
                var masked = val;
                inline for (0..masked.words.len) |w| {
                    masked.words[w] &= comptime flagsWordMask(T.wit_flags_count, w);
                }
                break :blk try lowerToFlat(@TypeOf(masked.words), arch, ctx, masked.words);
            }
            var out: FlatTuple(T, arch) = undefined;
            comptime var cursor: usize = 0;
            inline for (st.field_names, 0..) |fname, i| {
                if (comptime st.field_attrs[i].@"comptime") continue;
                const FT = st.field_types[i];
                const fl = comptime layoutOf(FT, arch);
                const sub = try lowerToFlat(FT, arch, ctx, @field(val, fname));
                inline for (0..fl.flat_count) |j| {
                    out[cursor + j] = sub[j];
                }
                cursor += fl.flat_count;
            }
            break :blk out;
        },
        .optional => |op| blk: {
            const payload_layout = comptime layoutOf(op.child, arch);
            var out: FlatTuple(T, arch) = undefined;
            if (val) |payload| {
                out[0] = 1;
                const sub = try lowerToFlat(op.child, arch, ctx, payload);
                inline for (0..payload_layout.flat_count) |j| {
                    out[1 + j] = sub[j];
                }
            } else {
                out[0] = 0;
                inline for (0..payload_layout.flat_count) |j| {
                    out[1 + j] = zeroFlatVal(payload_layout.flat_types[j]);
                }
            }
            break :blk out;
        },
        .@"union" => |un| blk: {
            var runtime_val: T = val;
            _ = &runtime_val;
            var out: FlatTuple(T, arch) = undefined;
            const active_tag = std.meta.activeTag(runtime_val);
            inline for (un.field_names, 0..) |fname, case_idx| {
                const tag_val = @field(un.tag_type.?, fname);
                if (active_tag == tag_val) {
                    out[0] = @intCast(case_idx);
                    const CaseT = un.field_types[case_idx];
                    const cl = comptime layoutOf(CaseT, arch);
                    const sub = try lowerToFlat(CaseT, arch, ctx, @field(runtime_val, fname));
                    inline for (0..cl.flat_count) |j| {
                        out[1 + j] = coerceToJoinedSlot(cl.flat_types[j], layout.flat_types[1 + j], sub[j]);
                    }
                    inline for (cl.flat_count..(layout.flat_count - 1)) |j| {
                        out[1 + j] = zeroFlatVal(layout.flat_types[1 + j]);
                    }
                    break :blk out;
                }
            }
            unreachable;
        },
        .error_set => .{@as(i32, @intCast(errorToIndex(T, val)))},
        .error_union => |eu| blk: {
            var out: FlatTuple(T, arch) = undefined;
            if (val) |ok_val| {
                out[0] = 0;
                const cl = comptime layoutOf(eu.payload, arch);
                const sub = try lowerToFlat(eu.payload, arch, ctx, ok_val);
                inline for (0..cl.flat_count) |j| {
                    out[1 + j] = coerceToJoinedSlot(cl.flat_types[j], layout.flat_types[1 + j], sub[j]);
                }
                inline for (cl.flat_count..(layout.flat_count - 1)) |j| {
                    out[1 + j] = zeroFlatVal(layout.flat_types[1 + j]);
                }
            } else |err_val| {
                out[0] = 1;
                const cl = comptime layoutOf(eu.error_set, arch);
                const sub = try lowerToFlat(eu.error_set, arch, ctx, err_val);
                inline for (0..cl.flat_count) |j| {
                    out[1 + j] = coerceToJoinedSlot(cl.flat_types[j], layout.flat_types[1 + j], sub[j]);
                }
                inline for (cl.flat_count..(layout.flat_count - 1)) |j| {
                    out[1 + j] = zeroFlatVal(layout.flat_types[1 + j]);
                }
            }
            break :blk out;
        },
        else => unreachable,
    };
}

/// Lift a Zig value of type `T` from its flat register tuple `flat` for `arch`.
pub inline fn liftFromFlat(comptime T: type, comptime arch: Arch, ctx: MemoryContext, flat: FlatTuple(T, arch)) CanonResult(T) {
    const layout = comptime layoutOf(T, arch);

    if (T == void) return {};

    if (comptime isCharType(T)) {
        const raw: u32 = @bitCast(flat[0]);
        const cp = try validateChar(raw);
        return if (@typeInfo(T) == .@"enum") @enumFromInt(cp) else cp;
    }

    switch (@typeInfo(T)) {
        .bool => return flat[0] != 0,
        .int => |int| return switch (int.bits) {
            8, 16, 32 => switch (int.signedness) {
                .unsigned => @truncate(@as(u32, @bitCast(flat[0]))),
                .signed => @truncate(flat[0]),
            },
            64 => @bitCast(flat[0]),
            else => unreachable,
        },
        .float => return flat[0],
        .@"enum" => {
            const raw: u32 = @bitCast(flat[0]);
            return intToEnum(T, raw);
        },
        .pointer => |pt| switch (pt.size) {
            .slice => {
                const AddrT = AddrInt(arch);
                const raw_ptr: AddrT = @bitCast(flat[0]);
                const raw_len: AddrT = @bitCast(flat[1]);
                const data_ptr: usize = std.math.cast(usize, raw_ptr) orelse return error.OutOfBounds;
                const len: usize = std.math.cast(usize, raw_len) orelse return error.OutOfBounds;
                return loadSliceData(T, arch, ctx, data_ptr, len);
            },
            else => unreachable,
        },
        .array => |ar| {
            var out: T = undefined;
            const elem_layout = comptime layoutOf(ar.child, arch);
            inline for (0..ar.len) |i| {
                var sub: FlatTuple(ar.child, arch) = undefined;
                inline for (0..elem_layout.flat_count) |j| {
                    sub[j] = flat[i * elem_layout.flat_count + j];
                }
                out[i] = liftFromFlat(ar.child, arch, ctx, sub) catch |err| {
                    inline for (0..i) |prev_i| {
                        freeLoadedSlices(ar.child, ctx, out[prev_i]);
                    }
                    return err;
                };
            }
            return out;
        },
        .@"struct" => |st| {
            if (comptime isHandleType(T)) {
                return .{ .handle = flat[0] };
            }
            if (comptime isStringWrapper(T)) {
                const bytes = try liftFromFlat([]const u8, arch, ctx, flat);
                errdefer freeLoadedSlices([]const u8, ctx, bytes);
                if (ctx.validate_utf8 and !std.unicode.utf8ValidateSlice(bytes)) {
                    return error.InvalidUtf8;
                }
                return .{ .bytes = bytes };
            }
            if (comptime st.layout == .@"packed") {
                const BackingInt = st.backing_integer.?;
                const UnsignedInt = @Int(.unsigned, @bitSizeOf(BackingInt));
                var raw: UnsignedInt = 0;
                inline for (0..layout.flat_count) |w| {
                    const shift = w * 32;
                    if (comptime shift < @bitSizeOf(UnsignedInt)) {
                        const word: u32 = @bitCast(flat[w]);
                        const rem_bits = @bitSizeOf(UnsignedInt) - shift;
                        const part: UnsignedInt = if (comptime rem_bits < 32)
                            @as(UnsignedInt, @as(@Int(.unsigned, rem_bits), @truncate(word)))
                        else
                            @as(UnsignedInt, word);
                        raw |= part << shift;
                    }
                }
                return @bitCast(raw & (comptime packedFlagsMask(T)));
            }
            if (comptime @hasDecl(T, "wit_flags_count") and @hasField(T, "words")) {
                var out: T = .{ .words = try liftFromFlat(@FieldType(T, "words"), arch, ctx, flat) };
                inline for (0..out.words.len) |w| {
                    out.words[w] &= comptime flagsWordMask(T.wit_flags_count, w);
                }
                return out;
            }
            var out: T = undefined;
            comptime var cursor: usize = 0;
            inline for (st.field_names, 0..) |fname, i| {
                if (comptime st.field_attrs[i].@"comptime") continue;
                const FT = st.field_types[i];
                const fl = comptime layoutOf(FT, arch);
                var sub: FlatTuple(FT, arch) = undefined;
                inline for (0..fl.flat_count) |j| {
                    sub[j] = flat[cursor + j];
                }
                if (comptime @typeInfo(FT) == .error_set) {
                    const raw: u32 = @bitCast(sub[0]);
                    indexToErrorOut(FT, raw, &@field(out, fname)) catch |err| {
                        inline for (0..i) |prev_i| {
                            if (comptime !st.field_attrs[prev_i].@"comptime") {
                                freeLoadedSlices(st.field_types[prev_i], ctx, @field(out, st.field_names[prev_i]));
                            }
                        }
                        return err;
                    };
                } else {
                    @field(out, fname) = liftFromFlat(FT, arch, ctx, sub) catch |err| {
                        inline for (0..i) |prev_i| {
                            if (comptime !st.field_attrs[prev_i].@"comptime") {
                                freeLoadedSlices(st.field_types[prev_i], ctx, @field(out, st.field_names[prev_i]));
                            }
                        }
                        return err;
                    };
                }
                cursor += fl.flat_count;
            }
            return out;
        },
        .optional => |op| {
            const disc: u32 = @bitCast(flat[0]);
            const payload_layout = comptime layoutOf(op.child, arch);
            switch (disc) {
                0 => return null,
                1 => {
                    var sub: FlatTuple(op.child, arch) = undefined;
                    inline for (0..payload_layout.flat_count) |j| {
                        sub[j] = flat[1 + j];
                    }
                    if (comptime @typeInfo(op.child) == .error_set) {
                        var ev: op.child = undefined;
                        try indexToErrorOut(op.child, @bitCast(sub[0]), &ev);
                        return ev;
                    }
                    return try liftFromFlat(op.child, arch, ctx, sub);
                },
                else => return error.InvalidDiscriminant,
            }
        },
        .@"union" => |un| {
            const disc: u32 = @bitCast(flat[0]);
            inline for (un.field_names, 0..) |fname, case_idx| {
                if (disc == case_idx) {
                    const CaseT = un.field_types[case_idx];
                    const cl = comptime layoutOf(CaseT, arch);
                    var sub: FlatTuple(CaseT, arch) = undefined;
                    inline for (0..cl.flat_count) |j| {
                        sub[j] = uncoerceFromJoinedSlot(cl.flat_types[j], layout.flat_types[1 + j], flat[1 + j]);
                    }
                    if (comptime @typeInfo(CaseT) == .error_set) {
                        var ev: CaseT = undefined;
                        try indexToErrorOut(CaseT, @bitCast(sub[0]), &ev);
                        return @unionInit(T, fname, ev);
                    }
                    const pay = try liftFromFlat(CaseT, arch, ctx, sub);
                    return @unionInit(T, fname, pay);
                }
            }
            return error.InvalidDiscriminant;
        },
        .error_set => {
            const raw: u32 = @bitCast(flat[0]);
            return try raiseErrorByIndex(T, raw);
        },
        .error_union => |eu| {
            const disc: u32 = @bitCast(flat[0]);
            switch (disc) {
                0 => {
                    const cl = comptime layoutOf(eu.payload, arch);
                    var sub: FlatTuple(eu.payload, arch) = undefined;
                    inline for (0..cl.flat_count) |j| {
                        sub[j] = uncoerceFromJoinedSlot(cl.flat_types[j], layout.flat_types[1 + j], flat[1 + j]);
                    }
                    return try liftFromFlat(eu.payload, arch, ctx, sub);
                },
                1 => {
                    const err_i32 = uncoerceFromJoinedSlot(.i32, layout.flat_types[1], flat[1]);
                    const raw: u32 = @bitCast(err_i32);
                    return try raiseErrorByIndex(eu.error_set, raw);
                },
                else => return error.InvalidDiscriminant,
            }
        },
        else => unreachable,
    }
}

// ── Comptime Function Signature Reflection & Inlined Lift/Lower Thunks ────

pub const MAX_FLAT_PARAMS: u32 = 16;
pub const MAX_FLAT_RESULTS: u32 = 1;
pub const MAX_FLAT_ASYNC_PARAMS: u32 = 4;

pub const Direction = enum {
    lower,
    lift,
};

pub const CallOptions = struct {
    arch: Arch = .wasm32,
    is_async: bool = false,
    direction: Direction = .lower,
    string_encoding_utf8: bool = false,
};

pub const FnClassification = struct {
    params_flat: u32,
    results_flat: u32,
    has_result: bool,
    params_spill: bool,
    results_indirect: bool,
    core_param_types: []const FlatValType,
    core_result_type: ?FlatValType,
    needs_memory: bool,
    needs_realloc: bool,
    lower_needs_realloc: bool,
    lift_needs_realloc: bool,
    contains_string: bool,
    needs_post_return: bool,
    params_record_size: u32,
    params_record_align: u32,
};

pub fn ReturnType(comptime FnType: type) type {
    const f = @typeInfo(FnType).@"fn";
    return f.return_type orelse void;
}

pub fn classifyZigFn(comptime FnType: type, comptime opts: CallOptions) FnClassification {
    return comptime computeFnClassification(FnType, opts);
}

fn computeFnClassification(comptime FnType: type, comptime opts: CallOptions) FnClassification {
    @setEvalBranchQuota(200_000);
    const f = @typeInfo(FnType).@"fn";
    const ArgsT = std.meta.ArgsTuple(FnType);
    const args_layout = layoutOf(ArgsT, opts.arch);

    var params_need_memory = false;
    var params_need_realloc = false;
    var contains_string = opts.string_encoding_utf8;

    for (f.param_types) |maybe_pt| {
        const PT = maybe_pt.?;
        const pl = layoutOf(PT, opts.arch);
        params_need_memory = params_need_memory or pl.needs_memory;
        params_need_realloc = params_need_realloc or pl.needs_realloc;
        contains_string = contains_string or pl.contains_string;
    }

    const RetT = ReturnType(FnType);
    const ret_layout = layoutOf(RetT, opts.arch);
    const has_result = RetT != void and ret_layout.flat_count > 0;
    const results_need_memory = ret_layout.needs_memory;
    const results_need_realloc = ret_layout.needs_realloc;
    contains_string = contains_string or ret_layout.contains_string;

    const max_flat_params: u32 = switch (opts.direction) {
        .lower => if (opts.is_async) MAX_FLAT_ASYNC_PARAMS else MAX_FLAT_PARAMS,
        .lift => MAX_FLAT_PARAMS,
    };
    const params_spill = args_layout.flat_count > max_flat_params;
    const results_indirect: bool = switch (opts.direction) {
        .lower => if (opts.is_async) has_result else (ret_layout.flat_count > MAX_FLAT_RESULTS),
        .lift => if (opts.is_async) false else (ret_layout.flat_count > MAX_FLAT_RESULTS),
    };
    const append_retptr = (opts.direction == .lower) and results_indirect;

    const ptr_ft = opts.arch.flatAddrValType();
    const core_param_len: usize = (if (params_spill) @as(usize, 1) else @as(usize, args_layout.flat_count)) +
        (if (append_retptr) @as(usize, 1) else @as(usize, 0));

    var core_params_buf: [core_param_len]FlatValType = undefined;
    var idx: usize = 0;
    if (params_spill) {
        core_params_buf[idx] = ptr_ft;
        idx += 1;
    } else {
        for (args_layout.flat_types) |ft| {
            core_params_buf[idx] = ft;
            idx += 1;
        }
    }
    if (append_retptr) {
        core_params_buf[idx] = ptr_ft;
        idx += 1;
    }
    const frozen_params = core_params_buf;

    const core_result_type: ?FlatValType = switch (opts.direction) {
        .lower => if (opts.is_async)
            .i32
        else if (!results_indirect and ret_layout.flat_count == 1)
            ret_layout.flat_types[0]
        else
            null,
        .lift => if (opts.is_async)
            null
        else if (results_indirect)
            ptr_ft
        else if (ret_layout.flat_count == 1)
            ret_layout.flat_types[0]
        else
            null,
    };

    const needs_memory = params_need_memory or results_need_memory or params_spill or results_indirect or (ret_layout.flat_count > MAX_FLAT_RESULTS);
    const lower_needs_realloc = results_need_realloc;
    const lift_needs_realloc = params_need_realloc or params_spill;

    return .{
        .params_flat = args_layout.flat_count,
        .results_flat = ret_layout.flat_count,
        .has_result = has_result,
        .params_spill = params_spill,
        .results_indirect = results_indirect,
        .core_param_types = &frozen_params,
        .core_result_type = core_result_type,
        .needs_memory = needs_memory,
        .needs_realloc = lower_needs_realloc or lift_needs_realloc or results_indirect,
        .lower_needs_realloc = lower_needs_realloc,
        .lift_needs_realloc = lift_needs_realloc,
        .contains_string = contains_string,
        .needs_post_return = results_need_realloc and !opts.is_async,
        .params_record_size = args_layout.size,
        .params_record_align = args_layout.alignment,
    };
}

/// Flat core Wasm parameter tuple type for `FnType` under `opts`.
pub fn CoreParamTuple(comptime FnType: type, comptime opts: CallOptions) type {
    const cls = comptime classifyZigFn(FnType, opts);
    var types: [cls.core_param_types.len]type = undefined;
    for (cls.core_param_types, 0..) |ft, i| {
        types[i] = ToZigType(ft);
    }
    return @Tuple(&types);
}

/// Flat core Wasm return type for `FnType` under `opts` (`void`, `i32`, `i64`, `f32`, or `f64`).
pub fn CoreReturnType(comptime FnType: type, comptime opts: CallOptions) type {
    const cls = comptime classifyZigFn(FnType, opts);
    return if (cls.core_result_type) |ft| ToZigType(ft) else void;
}

/// Flat core Wasm function signature type for `FnType` under `opts`, constructed via `@Fn`.
pub fn CoreFnType(comptime FnType: type, comptime opts: CallOptions) type {
    const cls = comptime classifyZigFn(FnType, opts);
    var param_types: [cls.core_param_types.len]type = undefined;
    var param_attrs: [cls.core_param_types.len]std.lang.Type.Fn.ParamAttributes = undefined;
    for (cls.core_param_types, 0..) |ft, i| {
        param_types[i] = ToZigType(ft);
        param_attrs[i] = .{};
    }
    const RetT = CoreReturnType(FnType, opts);
    return @Fn(&param_types, &param_attrs, RetT, .{});
}

threadlocal var active_memory_ctx: ?MemoryContext = null;
threadlocal var active_memory_ctx_ptr: ?*const MemoryContext = null;
threadlocal var last_async_task_return_ptr: ?usize = null;
threadlocal var last_async_task_return_in_static_buf: bool = false;
threadlocal var async_task_return_buf: [256]u8 align(16) = @splat(0);

pub fn setActiveMemoryContext(ctx: ?MemoryContext) void {
    active_memory_ctx = ctx;
}

pub fn setActiveMemoryContextPtr(ctx_ptr: ?*const MemoryContext) void {
    active_memory_ctx_ptr = ctx_ptr;
}

pub fn getActiveMemoryContextPtr() ?*const MemoryContext {
    return active_memory_ctx_ptr;
}

pub fn getActiveMemoryContext() ?MemoryContext {
    if (active_memory_ctx) |ctx| return ctx;
    if (active_memory_ctx_ptr) |ptr| return ptr.*;
    return null;
}

pub fn getLastAsyncTaskReturnPtr() ?usize {
    return last_async_task_return_ptr;
}

/// Host-to-Guest or Guest-to-Host call thunk: lowers `args` into flat
/// core Wasm registers (or a spilled parameter block in `ctx.memory`), invokes
/// `core_fn`, and lifts the result according to `opts.direction`:
///   * `.lower`: when `results_indirect`, allocates `retptr` in `ctx.memory`
///     and passes it as the trailing core parameter.
///   * `.lift`: when `results_indirect`, `core_fn` returns `ret_ptr: i32/i64`
///     pointing to the guest's return area; loads the result from
///     `ctx.memory[ret_ptr]` and invokes `ctx.post_return_fn` with `ret_ptr`
///     if non-null.
pub inline fn lowerCall(
    comptime FnType: type,
    comptime opts: CallOptions,
    in_ctx: MemoryContext,
    core_fn: *const CoreFnType(FnType, opts),
    args: std.meta.ArgsTuple(FnType),
) CanonResult(ReturnType(FnType)) {
    var ctx = in_ctx;
    if (comptime opts.string_encoding_utf8) {
        ctx.strict_utf8_on_u8_slices = true;
    }
    const cls = comptime classifyZigFn(FnType, opts);
    const ArgsT = std.meta.ArgsTuple(FnType);
    const RetT = ReturnType(FnType);
    const ret_layout = comptime layoutOf(RetT, opts.arch);
    const AddrT = AddrInt(opts.arch);

    var core_args: CoreParamTuple(FnType, opts) = undefined;

    if (comptime !cls.params_spill) {
        const flat_args = try lowerToFlat(ArgsT, opts.arch, ctx, args);
        inline for (0..cls.params_flat) |i| {
            core_args[i] = flat_args[i];
        }
    } else {
        const args_layout = comptime layoutOf(ArgsT, opts.arch);
        const params_ptr = try ctx.realloc(args_layout.alignment, args_layout.size);
        try storeToMemory(ArgsT, opts.arch, ctx, params_ptr, args);
        if (params_ptr > std.math.maxInt(AddrT)) return error.OutOfBounds;
        core_args[0] = @bitCast(@as(AddrT, @intCast(params_ptr)));
    }

    var ret_ptr: usize = 0;
    if (comptime opts.direction == .lower and cls.results_indirect) {
        ret_ptr = try ctx.realloc(ret_layout.alignment, ret_layout.size);
        if (ret_ptr > std.math.maxInt(AddrT)) return error.OutOfBounds;
        const ret_param_idx = comptime (cls.core_param_types.len - 1);
        core_args[ret_param_idx] = @bitCast(@as(AddrT, @intCast(ret_ptr)));
    }

    const TaskReturnCapture = struct {
        orig_ctx: ?*anyopaque = null,
        orig_fn: ?PostReturnFn = null,
        called: bool = false,
        ret_ptr: usize = 0,

        fn callback(raw_self: ?*anyopaque, ret_val: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw_self.?));
            self.called = true;
            self.ret_ptr = ret_val;
            last_async_task_return_ptr = ret_val;
            if (self.orig_fn) |f| {
                f(self.orig_ctx, ret_val);
            }
        }
    };
    var task_ret_capture = TaskReturnCapture{
        .orig_ctx = ctx.task_return_ctx,
        .orig_fn = ctx.task_return_fn,
    };
    if (comptime opts.direction == .lift and opts.is_async) {
        ctx.task_return_ctx = &task_ret_capture;
        ctx.task_return_fn = &TaskReturnCapture.callback;
    }

    const prev_ctx = active_memory_ctx;
    active_memory_ctx = ctx;
    defer active_memory_ctx = prev_ctx;

    if (comptime opts.direction == .lift and opts.is_async) {
        last_async_task_return_ptr = null;
        last_async_task_return_in_static_buf = false;
    }

    const raw_ret = @call(.auto, core_fn, core_args);

    if (comptime opts.direction == .lower and opts.is_async) {
        const ustatus: u32 = @bitCast(raw_ret);
        const state: u4 = @truncate(ustatus & 0xf);
        // WASI P3 SubtaskState.returned == 2
        if (state != 2) {
            if (ctx.await_subtask_fn) |a_fn| {
                try a_fn(ctx.await_subtask_ctx, &ctx, raw_ret);
                active_memory_ctx = ctx;
            } else {
                return error.AsyncCallPending;
            }
        } else if ((ustatus >> 4) != 0) {
            if (ctx.await_subtask_fn) |a_fn| {
                try a_fn(ctx.await_subtask_ctx, &ctx, raw_ret);
                active_memory_ctx = ctx;
            }
        }
    }

    if (comptime opts.direction == .lift and opts.is_async) {
        if (!task_ret_capture.called and last_async_task_return_ptr == null) {
            if (ctx.poll_task_fn) |p_fn| {
                var poll_iters: usize = 0;
                while (!task_ret_capture.called and last_async_task_return_ptr == null) : (poll_iters += 1) {
                    if (poll_iters >= 100_000) return error.AsyncTaskDidNotReturn;
                    try p_fn(ctx.poll_task_ctx, &ctx);
                    active_memory_ctx = ctx;
                }
            }
        }
        if (!task_ret_capture.called and last_async_task_return_ptr == null) {
            return error.AsyncTaskDidNotReturn;
        }
        if (comptime RetT == void) return {};
        const delivered_ptr = if (task_ret_capture.called)
            task_ret_capture.ret_ptr
        else
            (last_async_task_return_ptr orelse return error.AsyncTaskDidNotReturn);
        if (last_async_task_return_in_static_buf) {
            var tmp_ctx = ctx;
            tmp_ctx.memory = &async_task_return_buf;
            tmp_ctx.base_addr = 0;
            return try loadFromMemory(RetT, opts.arch, tmp_ctx, delivered_ptr);
        }
        return try loadFromMemory(RetT, opts.arch, ctx, delivered_ptr);
    } else if (comptime cls.results_indirect) {
        if (comptime opts.direction == .lift) {
            const raw_addr: AddrT = @bitCast(raw_ret);
            ret_ptr = std.math.cast(usize, raw_addr) orelse return error.OutOfBounds;
        }
        const lifted = try loadFromMemory(RetT, opts.arch, ctx, ret_ptr);
        if (comptime cls.needs_post_return or opts.direction == .lift) {
            if (ctx.post_return_fn) |post_fn| {
                post_fn(ctx.post_return_ctx orelse ctx.realloc_ctx, ret_ptr);
            }
        }
        return lifted;
    } else if (comptime cls.results_flat == 0) {
        return {};
    } else {
        const flat_ret: FlatTuple(RetT, opts.arch) = .{raw_ret};
        const lifted = try liftFromFlat(RetT, opts.arch, ctx, flat_ret);
        if (comptime opts.direction == .lift) {
            if (ctx.post_return_fn) |post_fn| {
                const raw_usize: usize = switch (cls.core_result_type.?) {
                    .i32 => @intCast(@as(u32, @bitCast(raw_ret))),
                    .i64 => @intCast(@as(u64, @bitCast(raw_ret))),
                    .f32 => @intCast(@as(u32, @bitCast(raw_ret))),
                    .f64 => @intCast(@as(u64, @bitCast(raw_ret))),
                };
                post_fn(ctx.post_return_ctx orelse ctx.realloc_ctx, raw_usize);
            }
        }
        return lifted;
    }
}

/// Convenience helper to invoke a lifted guest export (`direction = .lift`).
pub inline fn callLifted(
    comptime FnType: type,
    comptime opts: CallOptions,
    ctx: MemoryContext,
    core_fn: *const CoreFnType(FnType, .{
        .arch = opts.arch,
        .is_async = opts.is_async,
        .direction = .lift,
        .string_encoding_utf8 = opts.string_encoding_utf8,
    }),
    args: std.meta.ArgsTuple(FnType),
) CanonResult(ReturnType(FnType)) {
    const lift_opts = CallOptions{
        .arch = opts.arch,
        .is_async = opts.is_async,
        .direction = .lift,
        .string_encoding_utf8 = opts.string_encoding_utf8,
    };
    return lowerCall(FnType, lift_opts, ctx, core_fn, args);
}

/// Lifting call thunk (`canon lift`): lifts `std.meta.ArgsTuple(FnType)`
/// from `core_args` (or from the spilled parameter pointer in `ctx.memory`),
/// calls `handler`, and lowers the result to the flat return register,
/// indirect `retptr` parameter (`.lower`), or returned return-area pointer (`.lift`).
pub inline fn liftCall(
    comptime FnType: type,
    comptime opts: CallOptions,
    in_ctx: MemoryContext,
    handler: *const FnType,
    core_args: CoreParamTuple(FnType, opts),
) Error!CoreReturnType(FnType, opts) {
    var ctx = in_ctx;
    if (comptime opts.string_encoding_utf8) {
        ctx.strict_utf8_on_u8_slices = true;
    }
    const cls = comptime classifyZigFn(FnType, opts);
    const ArgsT = std.meta.ArgsTuple(FnType);
    const RetT = ReturnType(FnType);
    const AddrT = AddrInt(opts.arch);

    var lift_arena_state: ?std.heap.ArenaAllocator = if (ctx.allocator) |a|
        std.heap.ArenaAllocator.init(a)
    else
        null;
    defer if (lift_arena_state) |*a| a.deinit();
    var arg_ctx = ctx;
    if (lift_arena_state) |*a| {
        arg_ctx.allocator = a.allocator();
    }

    var zig_args: ArgsT = undefined;
    if (comptime !cls.params_spill) {
        var flat_args: FlatTuple(ArgsT, opts.arch) = undefined;
        inline for (0..cls.params_flat) |i| {
            flat_args[i] = core_args[i];
        }
        zig_args = try liftFromFlat(ArgsT, opts.arch, arg_ctx, flat_args);
    } else {
        const raw_ptr: AddrT = @bitCast(core_args[0]);
        const params_ptr: usize = std.math.cast(usize, raw_ptr) orelse return error.OutOfBounds;
        try loadStructFieldsFromMemory(ArgsT, opts.arch, arg_ctx, params_ptr, &zig_args);
    }

    const zig_ret: RetT = @call(.auto, handler, zig_args);

    if (comptime opts.direction == .lift and opts.is_async) {
        if (comptime RetT != void) {
            const ret_layout = comptime layoutOf(RetT, opts.arch);
            if (ctx.realloc_fn != null) {
                const ret_ptr = try ctx.realloc(ret_layout.alignment, ret_layout.size);
                try storeToMemory(RetT, opts.arch, ctx, ret_ptr, zig_ret);
                last_async_task_return_ptr = ret_ptr;
                last_async_task_return_in_static_buf = false;
                if (ctx.task_return_fn) |tr_fn| {
                    tr_fn(ctx.task_return_ctx orelse ctx.realloc_ctx, ret_ptr);
                }
            } else if (comptime ret_layout.size <= async_task_return_buf.len and !ret_layout.needs_memory) {
                var tmp_ctx = ctx;
                tmp_ctx.memory = &async_task_return_buf;
                tmp_ctx.base_addr = 0;
                try storeToMemory(RetT, opts.arch, tmp_ctx, 0, zig_ret);
                last_async_task_return_ptr = 0;
                last_async_task_return_in_static_buf = true;
                if (ctx.task_return_fn) |tr_fn| {
                    tr_fn(ctx.task_return_ctx orelse ctx.realloc_ctx, 0);
                }
            } else {
                return error.MissingRealloc;
            }
        } else {
            last_async_task_return_ptr = 0;
            last_async_task_return_in_static_buf = false;
            if (ctx.task_return_fn) |tr_fn| {
                tr_fn(ctx.task_return_ctx orelse ctx.realloc_ctx, 0);
            }
        }
        return;
    } else if (comptime cls.results_indirect) {
        if (comptime opts.direction == .lower) {
            const ret_param_idx = comptime (cls.core_param_types.len - 1);
            const raw_ret_ptr: AddrT = @bitCast(core_args[ret_param_idx]);
            const ret_ptr: usize = std.math.cast(usize, raw_ret_ptr) orelse return error.OutOfBounds;
            try storeToMemory(RetT, opts.arch, ctx, ret_ptr, zig_ret);
            if (comptime opts.is_async) {
                return @as(i32, 2); // WASI P3 SubtaskState.returned
            } else {
                return;
            }
        } else {
            const ret_layout = comptime layoutOf(RetT, opts.arch);
            const ret_ptr = try ctx.realloc(ret_layout.alignment, ret_layout.size);
            if (ret_ptr > std.math.maxInt(AddrT)) return error.OutOfBounds;
            try storeToMemory(RetT, opts.arch, ctx, ret_ptr, zig_ret);
            return @bitCast(@as(AddrT, @intCast(ret_ptr)));
        }
    } else if (comptime cls.results_flat == 0) {
        if (comptime opts.is_async and opts.direction == .lower) {
            return @as(i32, 2); // WASI P3 SubtaskState.returned
        } else {
            return;
        }
    } else {
        const flat_ret = try lowerToFlat(RetT, opts.arch, ctx, zig_ret);
        return flat_ret[0];
    }
}

/// Create a direct `*const CoreFnType(FnType, opts)` function pointer that
/// lifts arguments from core Wasm registers/memory using the active
/// `MemoryContext` (or native/Wasm linear memory when invoked directly as a
/// standalone export) and invokes `handler`.
pub fn createLiftThunk(
    comptime FnType: type,
    comptime opts: CallOptions,
    comptime handler: *const FnType,
) *const CoreFnType(FnType, opts) {
    const cls = comptime classifyZigFn(FnType, opts);
    const CoreParams = CoreParamTuple(FnType, opts);
    const CoreRet = CoreReturnType(FnType, opts);

    const invoker = struct {
        var fallback_buf: [4096]u8 align(16) = @splat(0);

        inline fn callTuple(core_args: CoreParams) CoreRet {
            if (active_memory_ctx) |*ctx| {
                return liftCall(FnType, opts, ctx.*, handler, core_args) catch @panic("Canonical ABI liftCall trap");
            }
            if (comptime builtin.cpu.arch.isWasm()) {
                const wasm_bytes = @as(usize, @wasmMemorySize(0)) * 65536;
                const buf_base = @intFromPtr(&fallback_buf[0]);
                var bump = BumpAllocator.init(buf_base, buf_base + fallback_buf.len);
                const mem_slice = @as([*]u8, @ptrFromInt(1))[0 .. wasm_bytes - 1];
                var wasm_ctx = bump.memoryContext(mem_slice);
                wasm_ctx.base_addr = 1;
                return liftCall(FnType, opts, wasm_ctx, handler, core_args) catch @panic("Canonical ABI liftCall trap");
            } else {
                var bump = BumpAllocator.init(64, fallback_buf.len);
                var fallback_ctx = bump.memoryContext(&fallback_buf);
                fallback_ctx.base_addr = @intFromPtr(&fallback_buf[0]);
                return liftCall(FnType, opts, fallback_ctx, handler, core_args) catch @panic("Canonical ABI liftCall trap");
            }
        }
    };

    const pyramid = getCoreSpreadPyramid(CoreParams, CoreRet, invoker.callTuple);
    const caller_name = std.fmt.comptimePrint("call{d}", .{cls.core_param_types.len});
    return &@field(pyramid, caller_name);
}

fn CoreTupleElem(comptime TupleT: type, comptime idx: usize) type {
    const fields = @typeInfo(TupleT).@"struct".field_types;
    return if (idx < fields.len) fields[idx] else void;
}

fn getCoreSpreadPyramid(
    comptime PT: type,
    comptime RT: type,
    comptime func: anytype,
) type {
    return struct {
        pub fn call0() RT {
            return func(.{});
        }
        pub fn call1(a0: CoreTupleElem(PT, 0)) RT {
            return func(.{a0});
        }
        pub fn call2(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1)) RT {
            return func(.{ a0, a1 });
        }
        pub fn call3(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2)) RT {
            return func(.{ a0, a1, a2 });
        }
        pub fn call4(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3)) RT {
            return func(.{ a0, a1, a2, a3 });
        }
        pub fn call5(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4)) RT {
            return func(.{ a0, a1, a2, a3, a4 });
        }
        pub fn call6(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5 });
        }
        pub fn call7(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6 });
        }
        pub fn call8(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6), a7: CoreTupleElem(PT, 7)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6, a7 });
        }
        pub fn call9(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6), a7: CoreTupleElem(PT, 7), a8: CoreTupleElem(PT, 8)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8 });
        }
        pub fn call10(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6), a7: CoreTupleElem(PT, 7), a8: CoreTupleElem(PT, 8), a9: CoreTupleElem(PT, 9)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 });
        }
        pub fn call11(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6), a7: CoreTupleElem(PT, 7), a8: CoreTupleElem(PT, 8), a9: CoreTupleElem(PT, 9), a10: CoreTupleElem(PT, 10)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 });
        }
        pub fn call12(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6), a7: CoreTupleElem(PT, 7), a8: CoreTupleElem(PT, 8), a9: CoreTupleElem(PT, 9), a10: CoreTupleElem(PT, 10), a11: CoreTupleElem(PT, 11)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11 });
        }
        pub fn call13(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6), a7: CoreTupleElem(PT, 7), a8: CoreTupleElem(PT, 8), a9: CoreTupleElem(PT, 9), a10: CoreTupleElem(PT, 10), a11: CoreTupleElem(PT, 11), a12: CoreTupleElem(PT, 12)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12 });
        }
        pub fn call14(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6), a7: CoreTupleElem(PT, 7), a8: CoreTupleElem(PT, 8), a9: CoreTupleElem(PT, 9), a10: CoreTupleElem(PT, 10), a11: CoreTupleElem(PT, 11), a12: CoreTupleElem(PT, 12), a13: CoreTupleElem(PT, 13)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13 });
        }
        pub fn call15(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6), a7: CoreTupleElem(PT, 7), a8: CoreTupleElem(PT, 8), a9: CoreTupleElem(PT, 9), a10: CoreTupleElem(PT, 10), a11: CoreTupleElem(PT, 11), a12: CoreTupleElem(PT, 12), a13: CoreTupleElem(PT, 13), a14: CoreTupleElem(PT, 14)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14 });
        }
        pub fn call16(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6), a7: CoreTupleElem(PT, 7), a8: CoreTupleElem(PT, 8), a9: CoreTupleElem(PT, 9), a10: CoreTupleElem(PT, 10), a11: CoreTupleElem(PT, 11), a12: CoreTupleElem(PT, 12), a13: CoreTupleElem(PT, 13), a14: CoreTupleElem(PT, 14), a15: CoreTupleElem(PT, 15)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 });
        }
        pub fn call17(a0: CoreTupleElem(PT, 0), a1: CoreTupleElem(PT, 1), a2: CoreTupleElem(PT, 2), a3: CoreTupleElem(PT, 3), a4: CoreTupleElem(PT, 4), a5: CoreTupleElem(PT, 5), a6: CoreTupleElem(PT, 6), a7: CoreTupleElem(PT, 7), a8: CoreTupleElem(PT, 8), a9: CoreTupleElem(PT, 9), a10: CoreTupleElem(PT, 10), a11: CoreTupleElem(PT, 11), a12: CoreTupleElem(PT, 12), a13: CoreTupleElem(PT, 13), a14: CoreTupleElem(PT, 14), a15: CoreTupleElem(PT, 15), a16: CoreTupleElem(PT, 16)) RT {
            return func(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16 });
        }
    };
}

/// Comptime type reflection bundle for a Zig function signature under `opts`.
pub fn CanonSig(comptime FnType: type, comptime opts: CallOptions) type {
    return struct {
        pub const classification = classifyZigFn(FnType, opts);
        pub const CoreParams = CoreParamTuple(FnType, opts);
        pub const CoreReturn = CoreReturnType(FnType, opts);
        pub const CoreFn = CoreFnType(FnType, opts);
        pub const ZigArgs = std.meta.ArgsTuple(FnType);
        pub const ZigReturn = ReturnType(FnType);
    };
}

fn normalizeCallOptions(comptime opts_or_mem64: anytype) CallOptions {
    const T = @TypeOf(opts_or_mem64);
    if (T == CallOptions) return opts_or_mem64;
    if (T == bool) return .{ .arch = if (opts_or_mem64) .wasm64 else .wasm32 };
    if (T == Arch) return .{ .arch = opts_or_mem64 };
    if (@typeInfo(T) == .enum_literal) {
        return .{ .arch = @as(Arch, opts_or_mem64) };
    }
    if (@typeInfo(T) == .@"struct") {
        var resolved: CallOptions = .{};
        if (@hasField(T, "arch")) resolved.arch = opts_or_mem64.arch;
        if (@hasField(T, "is_async")) resolved.is_async = opts_or_mem64.is_async;
        if (@hasField(T, "direction")) resolved.direction = opts_or_mem64.direction;
        if (@hasField(T, "string_encoding_utf8")) resolved.string_encoding_utf8 = opts_or_mem64.string_encoding_utf8;
        if (@hasField(T, "is_memory64")) resolved.arch = if (opts_or_mem64.is_memory64) .wasm64 else .wasm32;
        return resolved;
    }
    @compileError("Expected CallOptions, Arch, or bool (is_memory64), got " ++ @typeName(T));
}

/// Comptime host-to-guest lowering thunk namespace (`canon lower`).
pub fn CanonLower(comptime FnType: type, comptime opts_or_mem64: anytype) type {
    const opts = comptime normalizeCallOptions(opts_or_mem64);
    const is_memory64 = (opts.arch == .wasm64);
    return struct {
        const Self = @This();
        pub const Sig = CanonSig(FnType, opts);
        pub const CoreFnPtr = *const Sig.CoreFn;
        pub const ArgsTuple = Sig.ZigArgs;
        pub const ZigReturn = Sig.ZigReturn;
        pub const abi_hash: u64 = fast_abi.comptimeAbiHash(FnType, is_memory64);

        pub inline fn call(
            ctx_or_ptr: anytype,
            core_fn: CoreFnPtr,
            args: ArgsTuple,
        ) CanonResult(Sig.ZigReturn) {
            const CtxT = @TypeOf(ctx_or_ptr);
            const ctx: MemoryContext = if (comptime @typeInfo(CtxT) == .pointer) ctx_or_ptr.* else ctx_or_ptr;
            return lowerCall(FnType, opts, ctx, core_fn, args);
        }

        /// Automatically dispatch via the zero-overhead `FastLower` bypass when
        /// `guest_abi` contains a compatible `"zigar:abi"` entry matching
        /// `(interface_name, func_name, abi_hash, frame_size, frame_align, is_memory64)`
        /// and `fast_core_fn` is available; otherwise transparently fall back to
        /// the standard Component Model Canonical ABI (`Self.call`). Also falls
        /// back to `Self.call` if a fast-path store-phase capacity error occurs
        /// before `fast_core_fn` is invoked.
        pub inline fn callAuto(
            mem_ctx: *MemoryContext,
            guest_abi: anytype,
            interface_name: []const u8,
            func_name: []const u8,
            fast_core_fn: ?fast_abi.FastCoreFnPtr(is_memory64),
            canon_core_fn: CoreFnPtr,
            args: ArgsTuple,
        ) CanonResult(Sig.ZigReturn) {
            const GuestAbiT = @TypeOf(guest_abi);
            if (comptime GuestAbiT != @TypeOf(null)) {
                if (fast_core_fn) |fast_fn| {
                    const Fast = fast_abi.FastLower(FnType, is_memory64);
                    const expected_size: u32 = @intCast(Fast.frame_layout.frame_size);
                    const expected_align: u32 = @intCast(Fast.frame_layout.frame_align);
                    const matched = if (comptime @typeInfo(GuestAbiT) == .optional)
                        if (guest_abi) |meta|
                            meta.findCompatibleFuncWithLayout(interface_name, func_name, abi_hash, expected_size, expected_align, is_memory64) != null
                        else
                            false
                    else
                        guest_abi.findCompatibleFuncWithLayout(interface_name, func_name, abi_hash, expected_size, expected_align, is_memory64) != null;

                    if (matched) {
                        switch (Fast.tryCallOrFallback(mem_ctx, fast_fn, args)) {
                            .completed => |res| return res,
                            .fallback_needed => {},
                        }
                    }
                }
            }
            return Self.call(mem_ctx.*, canon_core_fn, args);
        }
    };
}

/// Comptime guest-to-host lifting thunk namespace (`canon lift`).
pub fn CanonLift(comptime FnType: type, comptime opts_or_mem64: anytype) type {
    const opts = comptime normalizeCallOptions(opts_or_mem64);
    return struct {
        pub const Sig = CanonSig(FnType, opts);
        pub const CoreFnPtr = *const Sig.CoreFn;
        pub const ArgsTuple = Sig.ZigArgs;
        pub const ReturnType = Sig.ZigReturn;

        pub inline fn call(
            ctx_or_ptr: anytype,
            handler: *const FnType,
            core_args: Sig.CoreParams,
        ) Error!Sig.CoreReturn {
            const CtxT = @TypeOf(ctx_or_ptr);
            const ctx: MemoryContext = if (comptime @typeInfo(CtxT) == .pointer) ctx_or_ptr.* else ctx_or_ptr;
            return liftCall(FnType, opts, ctx, handler, core_args);
        }

        pub fn thunk(comptime handler: *const FnType) *const Sig.CoreFn {
            return createLiftThunk(FnType, opts, handler);
        }
    };
}

// ── Unit Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "layoutOf and FlatTuple: primitives and Char" {
    const void_l = layoutOf(void, .wasm32);
    try testing.expectEqual(@as(u32, 0), void_l.size);
    try testing.expectEqual(@as(u32, 1), void_l.alignment);
    try testing.expectEqual(@as(u32, 0), void_l.flat_count);
    try testing.expect(void_l.is_blittable);

    const bool_l = layoutOf(bool, .wasm32);
    try testing.expectEqual(@as(u32, 1), bool_l.size);
    try testing.expectEqual(@as(u32, 1), bool_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{.i32}, bool_l.flat_types);
    try testing.expect(!bool_l.is_blittable);

    inline for (.{ u8, i8 }) |T| {
        const l = layoutOf(T, .wasm32);
        try testing.expectEqual(@as(u32, 1), l.size);
        try testing.expectEqual(@as(u32, 1), l.alignment);
        try testing.expectEqualSlices(FlatValType, &.{.i32}, l.flat_types);
        try testing.expect(l.is_blittable);
    }
    inline for (.{ u16, i16 }) |T| {
        const l = layoutOf(T, .wasm32);
        try testing.expectEqual(@as(u32, 2), l.size);
        try testing.expectEqual(@as(u32, 2), l.alignment);
        try testing.expectEqualSlices(FlatValType, &.{.i32}, l.flat_types);
        try testing.expect(l.is_blittable);
    }
    inline for (.{ u32, i32 }) |T| {
        const l = layoutOf(T, .wasm32);
        try testing.expectEqual(@as(u32, 4), l.size);
        try testing.expectEqual(@as(u32, 4), l.alignment);
        try testing.expectEqualSlices(FlatValType, &.{.i32}, l.flat_types);
        try testing.expect(l.is_blittable);
    }
    inline for (.{ u64, i64 }) |T| {
        const l = layoutOf(T, .wasm32);
        try testing.expectEqual(@as(u32, 8), l.size);
        try testing.expectEqual(@as(u32, 8), l.alignment);
        try testing.expectEqualSlices(FlatValType, &.{.i64}, l.flat_types);
        try testing.expect(l.is_blittable);
    }

    const f32_l = layoutOf(f32, .wasm32);
    try testing.expectEqual(@as(u32, 4), f32_l.size);
    try testing.expectEqual(@as(u32, 4), f32_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{.f32}, f32_l.flat_types);
    try testing.expect(f32_l.is_blittable);

    const f64_l = layoutOf(f64, .wasm32);
    try testing.expectEqual(@as(u32, 8), f64_l.size);
    try testing.expectEqual(@as(u32, 8), f64_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{.f64}, f64_l.flat_types);
    try testing.expect(f64_l.is_blittable);

    inline for (.{ Char, u21 }) |T| {
        const l = layoutOf(T, .wasm32);
        try testing.expectEqual(@as(u32, 4), l.size);
        try testing.expectEqual(@as(u32, 4), l.alignment);
        try testing.expectEqualSlices(FlatValType, &.{.i32}, l.flat_types);
        try testing.expect(!l.is_blittable);
    }
}

test "layoutOf: enums, flags, and handles" {
    const SmallEnum = enum(u8) { red, green, blue };
    const WideBackedEnum16 = enum(u16) { a, b, c };
    const WideBackedEnum32 = enum(u32) { x, y };

    const se_l = layoutOf(SmallEnum, .wasm32);
    try testing.expectEqual(@as(u32, 1), se_l.size);
    try testing.expectEqual(@as(u32, 1), se_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{.i32}, se_l.flat_types);
    try testing.expect(!se_l.is_blittable);

    // Canonical ABI enum size & alignment depend strictly on case count (<= 256 -> 1),
    // regardless of the Zig enum's backing integer width.
    const me_l = layoutOf(WideBackedEnum16, .wasm32);
    try testing.expectEqual(@as(u32, 1), me_l.size);
    try testing.expectEqual(@as(u32, 1), me_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{.i32}, me_l.flat_types);

    const le_l = layoutOf(WideBackedEnum32, .wasm32);
    try testing.expectEqual(@as(u32, 1), le_l.size);
    try testing.expectEqual(@as(u32, 1), le_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{.i32}, le_l.flat_types);

    const Flags0 = packed struct(u8) {
        _pad: u8 = 0,
        pub const wit_flags_count: usize = 0;
    };
    const f0_l = layoutOf(Flags0, .wasm32);
    try testing.expectEqual(@as(u32, 0), f0_l.size);
    try testing.expectEqual(@as(u32, 1), f0_l.alignment);
    try testing.expectEqual(@as(u32, 0), f0_l.flat_count);
    try testing.expectEqual(@as(usize, 0), f0_l.flat_types.len);

    const Flags8 = packed struct(u8) { r: bool = false, w: bool = false, x: bool = false, _pad: u5 = 0 };
    const Flags16 = packed struct(u16) { a: bool = false, _pad: u15 = 0 };
    const Flags32 = packed struct(u32) { a: bool = false, _pad: u31 = 0 };
    const Flags64 = packed struct(u64) { a: bool = false, _pad: u62 = 0, hi: bool = false };

    const f8_l = layoutOf(Flags8, .wasm32);
    try testing.expectEqual(@as(u32, 1), f8_l.size);
    try testing.expectEqual(@as(u32, 1), f8_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{.i32}, f8_l.flat_types);

    const f16_l = layoutOf(Flags16, .wasm32);
    try testing.expectEqual(@as(u32, 2), f16_l.size);
    try testing.expectEqual(@as(u32, 2), f16_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{.i32}, f16_l.flat_types);

    const f32_l = layoutOf(Flags32, .wasm32);
    try testing.expectEqual(@as(u32, 4), f32_l.size);
    try testing.expectEqual(@as(u32, 4), f32_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{.i32}, f32_l.flat_types);

    const f64_l = layoutOf(Flags64, .wasm32);
    try testing.expectEqual(@as(u32, 8), f64_l.size);
    try testing.expectEqual(@as(u32, 4), f64_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{ .i32, .i32 }, f64_l.flat_types);

    const DummyRes = opaque {};
    inline for (.{ Own(DummyRes), Borrow(DummyRes), Stream(u8), Future(u32), ErrorContext }) |H| {
        const hl = layoutOf(H, .wasm32);
        try testing.expectEqual(@as(u32, 4), hl.size);
        try testing.expectEqual(@as(u32, 4), hl.alignment);
        try testing.expectEqualSlices(FlatValType, &.{.i32}, hl.flat_types);
        try testing.expect(hl.is_blittable);
    }
}

test "layoutOf: extern struct blittability, nested records, options, results, variants, and wasm64" {
    const Point = extern struct { x: f32, y: f32 };
    const PaddedRecord = extern struct { a: u8, b: u32, c: u16 };
    const NonExternRecord = struct { a: u8, b: u32 };
    const SmallEnum = enum(u8) { r, g, b };
    const EnumExternRecord = extern struct { e: SmallEnum, x: u32 };
    const CharRecord = struct { c: Char, x: u32 };
    const SliceRecord = struct { name: []const u8, count: u32 };

    const pt_l = layoutOf(Point, .wasm32);
    try testing.expectEqual(@as(u32, 8), pt_l.size);
    try testing.expectEqual(@as(u32, 4), pt_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{ .f32, .f32 }, pt_l.flat_types);
    try testing.expect(pt_l.is_blittable);

    const pad_l = layoutOf(PaddedRecord, .wasm32);
    try testing.expectEqual(@as(u32, 12), pad_l.size);
    try testing.expectEqual(@as(u32, 4), pad_l.alignment);
    try testing.expectEqual(@as(u32, 0), fieldOffset(PaddedRecord, .wasm32, 0));
    try testing.expectEqual(@as(u32, 4), fieldOffset(PaddedRecord, .wasm32, 1));
    try testing.expectEqual(@as(u32, 8), fieldOffset(PaddedRecord, .wasm32, 2));
    try testing.expect(pad_l.is_blittable);

    try testing.expect(!layoutOf(NonExternRecord, .wasm32).is_blittable);
    try testing.expect(!layoutOf(EnumExternRecord, .wasm32).is_blittable);
    try testing.expect(!layoutOf(CharRecord, .wasm32).is_blittable);

    const sr_32 = layoutOf(SliceRecord, .wasm32);
    try testing.expectEqual(@as(u32, 12), sr_32.size);
    try testing.expectEqual(@as(u32, 4), sr_32.alignment);
    try testing.expect(sr_32.needs_memory);
    try testing.expect(sr_32.needs_realloc);
    try testing.expect(!sr_32.contains_string);
    try testing.expect(!sr_32.is_blittable);
    try testing.expectEqualSlices(FlatValType, &.{ .i32, .i32, .i32 }, sr_32.flat_types);

    const WitStringRecord = struct { name: WitString, count: u32 };
    const wsr_32 = layoutOf(WitStringRecord, .wasm32);
    try testing.expect(wsr_32.contains_string);

    const sr_64 = layoutOf(SliceRecord, .wasm64);
    try testing.expectEqual(@as(u32, 24), sr_64.size);
    try testing.expectEqual(@as(u32, 8), sr_64.alignment);
    try testing.expectEqualSlices(FlatValType, &.{ .i64, .i64, .i32 }, sr_64.flat_types);

    // Option<u64>: 1 byte disc + 7 padding + 8 payload = 16, align 8, flat [i32, i64]
    const opt_l = layoutOf(?u64, .wasm32);
    try testing.expectEqual(@as(u32, 16), opt_l.size);
    try testing.expectEqual(@as(u32, 8), opt_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{ .i32, .i64 }, opt_l.flat_types);

    // Variant slot joining:
    // Case 0: struct { f32, i32 } -> [f32, i32]
    // Case 1: struct { i32, i64 } -> [i32, i64]
    // Joined payload: [join(f32, i32) = i32, join(i32, i64) = i64]
    // Total flat: [i32 (disc), i32, i64]
    const MyVariant = union(enum) {
        first: extern struct { a: f32, b: i32 },
        second: extern struct { x: i32, y: i64 },
        empty: void,
    };
    const var_l = layoutOf(MyVariant, .wasm32);
    try testing.expectEqual(@as(u32, 24), var_l.size);
    try testing.expectEqual(@as(u32, 8), var_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{ .i32, .i32, .i64 }, var_l.flat_types);

    // f32 joined with f64 -> i64
    const FloatResult = Result(f32, f64);
    const fr_l = layoutOf(FloatResult, .wasm32);
    try testing.expectEqual(@as(u32, 16), fr_l.size);
    try testing.expectEqual(@as(u32, 8), fr_l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{ .i32, .i64 }, fr_l.flat_types);
}

test "storeToMemory and loadFromMemory round-trips and validation" {
    var mem: [4096]u8 align(8) = @splat(0);
    var bump = BumpAllocator.init(256, mem.len);
    var ctx = bump.memoryContext(&mem);
    ctx.allocator = testing.allocator;

    // Blittable extern struct
    const Point = extern struct { x: f32, y: f32 };
    const pt = Point{ .x = 1.5, .y = -4.25 };
    try storeToMemory(Point, .wasm32, ctx, 0, pt);
    const loaded_pt = try loadFromMemory(Point, .wasm32, ctx, 0);
    try testing.expectEqual(pt, loaded_pt);

    // Char validation
    const valid_ch = try Char.fromCodepoint(0x1F980); // crab emoji
    try storeToMemory(Char, .wasm32, ctx, 16, valid_ch);
    try testing.expectEqual(valid_ch, try loadFromMemory(Char, .wasm32, ctx, 16));

    // Invalid surrogate char in memory must fail
    std.mem.writeInt(u32, mem[16..20], 0xD800, .little);
    try testing.expectError(error.InvalidChar, loadFromMemory(Char, .wasm32, ctx, 16));
    std.mem.writeInt(u32, mem[16..20], 0x110000, .little);
    try testing.expectError(error.InvalidChar, loadFromMemory(u21, .wasm32, ctx, 16));

    // Enum validation
    const Color = enum(u8) { red, green, blue };
    try storeToMemory(Color, .wasm32, ctx, 24, .green);
    try testing.expectEqual(Color.green, try loadFromMemory(Color, .wasm32, ctx, 24));
    mem[24] = 99;
    try testing.expectError(error.InvalidDiscriminant, loadFromMemory(Color, .wasm32, ctx, 24));

    // Flags (<= 64 bits)
    const Flags64 = packed struct(u64) {
        low: bool = false,
        _pad: u61 = 0,
        high1: bool = false,
        high2: bool = false,
    };
    const fval = Flags64{ .low = true, .high2 = true };
    try storeToMemory(Flags64, .wasm32, ctx, 32, fval);
    try testing.expectEqual(fval, try loadFromMemory(Flags64, .wasm32, ctx, 32));

    // Zero-copy string & blittable slice vs allocator-copied slice
    const greeting = "hello, canonical ABI!";
    try storeToMemory([]const u8, .wasm32, ctx, 48, greeting);
    const zc_str = try loadFromMemory([]const u8, .wasm32, ctx, 48);
    try testing.expectEqualStrings(greeting, zc_str);
    // Verify zero-copy points directly inside `mem`
    try testing.expect(@intFromPtr(zc_str.ptr) >= @intFromPtr(&mem[0]) and
        @intFromPtr(zc_str.ptr) < @intFromPtr(&mem[0]) + mem.len);

    // Allocator-copied string when zero_copy_slices = false
    var copy_ctx = ctx;
    copy_ctx.zero_copy_slices = false;
    const copied_str = try loadFromMemory([]const u8, .wasm32, copy_ctx, 48);
    defer testing.allocator.free(copied_str);
    try testing.expectEqualStrings(greeting, copied_str);
    try testing.expect(@intFromPtr(copied_str.ptr) < @intFromPtr(&mem[0]) or
        @intFromPtr(copied_str.ptr) >= @intFromPtr(&mem[0]) + mem.len);

    // Blittable slice zero-copy
    const points = [_]Point{ .{ .x = 1.0, .y = 2.0 }, .{ .x = 3.0, .y = 4.0 } };
    try storeToMemory([]const Point, .wasm32, ctx, 64, &points);
    const zc_pts = try loadFromMemory([]const Point, .wasm32, ctx, 64);
    try testing.expectEqualSlices(Point, &points, zc_pts);
    try testing.expect(@intFromPtr(zc_pts.ptr) >= @intFromPtr(&mem[0]) and
        @intFromPtr(zc_pts.ptr) < @intFromPtr(&mem[0]) + mem.len);

    // Option & Result discriminant validation
    const R = Result([]const u8, Color);
    try storeToMemory(R, .wasm32, ctx, 80, R{ .ok = "success" });
    const lifted_r = try loadFromMemory(R, .wasm32, ctx, 80);
    try testing.expectEqualStrings("success", lifted_r.ok);

    mem[80] = 5; // invalid result discriminant
    try testing.expectError(error.InvalidDiscriminant, loadFromMemory(R, .wasm32, ctx, 80));
}

test "lowerToFlat and liftFromFlat: variant slot joining and wasm64" {
    var mem: [4096]u8 align(8) = @splat(0);
    var bump = BumpAllocator.init(64, mem.len);
    const ctx = bump.memoryContext(&mem);

    // Test slot joining: (f32 ⊕ i32 -> i32) and (f32 ⊕ f64 -> i64) and (i32 ⊕ i64 -> i64)
    const JoinedVariant = union(enum) {
        f32_and_i32: extern struct { a: f32, b: i32 },
        i32_and_i64: extern struct { x: i32, y: i64 },
        f64_only: f64,
        none: void,
    };

    const cases = [_]JoinedVariant{
        .{ .f32_and_i32 = .{ .a = 3.1415927, .b = -12345 } },
        .{ .i32_and_i64 = .{ .x = 42, .y = -9876543210123 } },
        .{ .f64_only = 2.718281828459045 },
        .{ .none = {} },
    };

    for (cases) |c| {
        const flat = try lowerToFlat(JoinedVariant, .wasm32, ctx, c);
        const roundtrip = try liftFromFlat(JoinedVariant, .wasm32, ctx, flat);
        try testing.expectEqual(c, roundtrip);
    }

    // wasm64 string flat roundtrip ([i64, i64])
    const flat64 = try lowerToFlat([]const u8, .wasm64, ctx, "wasm64-string");
    try testing.expectEqual(@TypeOf(flat64[0]), i64);
    try testing.expectEqual(@TypeOf(flat64[1]), i64);
    const str64 = try liftFromFlat([]const u8, .wasm64, ctx, flat64);
    try testing.expectEqualStrings("wasm64-string", str64);
}

test "lowerCall and liftCall: direct scalar, string/list, indirect retptr, >16 param spill, async >4 spill, and wasm64" {
    var mem: [16384]u8 align(8) = @splat(0);
    var bump = BumpAllocator.init(128, mem.len);
    const ctx = bump.memoryContext(&mem);

    // 1. Direct scalar function (<= 16 flat params, 1 flat result)
    const ScalarHandlers = struct {
        fn addMul(a: i32, b: i32, scale: f32) f32 {
            return @as(f32, @floatFromInt(a + b)) * scale;
        }
    };
    const AddMulFn = @TypeOf(ScalarHandlers.addMul);
    const add_cls = classifyZigFn(AddMulFn, .{});
    try testing.expect(!add_cls.params_spill);
    try testing.expect(!add_cls.results_indirect);
    try testing.expect(!add_cls.needs_memory);
    try testing.expectEqual(@as(u32, 3), add_cls.params_flat);
    try testing.expectEqual(@as(u32, 1), add_cls.results_flat);

    const add_thunk = CanonLift(AddMulFn, .{}).thunk(&ScalarHandlers.addMul);
    const add_res = try CanonLower(AddMulFn, .{}).call(ctx, add_thunk, .{ 10, 20, 2.5 });
    try testing.expectEqual(@as(f32, 75.0), add_res);

    // 2. String + list + Result (> 1 flat results -> indirect retptr!)
    const Point = extern struct { x: i32, y: i32 };
    const ErrCode = enum(u8) { empty_input, bad_point };
    const ProcessResult = Result(Point, ErrCode);
    const ComplexHandlers = struct {
        fn process(label: []const u8, pts: []const Point) ProcessResult {
            if (label.len == 0 or pts.len == 0) return .{ .err = .empty_input };
            var sum = Point{ .x = @intCast(label.len), .y = 0 };
            for (pts) |p| {
                sum.x += p.x;
                sum.y += p.y;
            }
            return .{ .ok = sum };
        }
    };
    const ProcessFn = @TypeOf(ComplexHandlers.process);
    const proc_cls = classifyZigFn(ProcessFn, .{});
    try testing.expect(!proc_cls.params_spill);
    try testing.expect(proc_cls.results_indirect); // Result(Point, ErrCode) has 3 flat slots > 1
    try testing.expect(proc_cls.needs_memory);
    try testing.expect(!proc_cls.contains_string);
    // 2 params * 2 slots + 1 retptr = 5 core i32 params, void core return
    try testing.expectEqual(@as(usize, 5), proc_cls.core_param_types.len);
    try testing.expectEqual(@as(?FlatValType, null), proc_cls.core_result_type);

    const proc_thunk = createLiftThunk(ProcessFn, .{}, &ComplexHandlers.process);
    const pts = [_]Point{ .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 40 } };
    const proc_ok = try lowerCall(ProcessFn, .{}, ctx, proc_thunk, .{ "abc", &pts });
    try testing.expectEqual(ProcessResult{ .ok = .{ .x = 43, .y = 60 } }, proc_ok);

    const proc_err = try lowerCall(ProcessFn, .{}, ctx, proc_thunk, .{ "", &pts });
    try testing.expectEqual(ProcessResult{ .err = .empty_input }, proc_err);

    // 3. Spilled parameters in sync mode (> 16 flat params -> 1 pointer param!)
    const SpillHandlers = struct {
        fn sum18(
            a0: u32, a1: u32, a2: u32, a3: u32, a4: u32, a5: u32,
            a6: u32, a7: u32, a8: u32, a9: u32, a10: u32, a11: u32,
            a12: u32, a13: u32, a14: u32, a15: u32, a16: u32, a17: u32,
        ) u32 {
            return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 +
                a9 + a10 + a11 + a12 + a13 + a14 + a15 + a16 + a17;
        }
    };
    const SpillFn = @TypeOf(SpillHandlers.sum18);
    const spill_cls = classifyZigFn(SpillFn, .{});
    try testing.expectEqual(@as(u32, 18), spill_cls.params_flat);
    try testing.expect(spill_cls.params_spill);
    try testing.expect(!spill_cls.results_indirect);
    try testing.expectEqual(@as(usize, 1), spill_cls.core_param_types.len);
    try testing.expectEqual(@as(?FlatValType, .i32), spill_cls.core_result_type);

    const spill_thunk = createLiftThunk(SpillFn, .{}, &SpillHandlers.sum18);
    const spill_res = try lowerCall(
        SpillFn,
        .{},
        ctx,
        spill_thunk,
        .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 },
    );
    try testing.expectEqual(@as(u32, 171), spill_res);

    // 4. Async mode parameter spill (> 4 flat params) + indirect result
    const AsyncHandlers = struct {
        fn asyncSum5(a: u32, b: u32, c: u32, d: u32, e: u32) u32 {
            return a + b + c + d + e;
        }
    };
    const AsyncFn = @TypeOf(AsyncHandlers.asyncSum5);
    const async_opts = CallOptions{ .arch = .wasm32, .is_async = true };
    const async_cls = classifyZigFn(AsyncFn, async_opts);
    try testing.expectEqual(@as(u32, 5), async_cls.params_flat);
    try testing.expect(async_cls.params_spill);
    try testing.expect(async_cls.results_indirect);
    // 1 spilled param ptr + 1 retptr = 2 i32 core params, i32 status result
    try testing.expectEqualSlices(FlatValType, &.{ .i32, .i32 }, async_cls.core_param_types);
    try testing.expectEqual(@as(?FlatValType, .i32), async_cls.core_result_type);

    const async_thunk = createLiftThunk(AsyncFn, async_opts, &AsyncHandlers.asyncSum5);
    const async_res = try lowerCall(AsyncFn, async_opts, ctx, async_thunk, .{ 10, 20, 30, 40, 50 });
    try testing.expectEqual(@as(u32, 150), async_res);

    // 5. wasm64 (cm64) mode end-to-end
    const cm64_opts = CallOptions{ .arch = .wasm64, .is_async = false };
    const cm64_cls = classifyZigFn(ProcessFn, cm64_opts);
    try testing.expectEqualSlices(FlatValType, &.{ .i64, .i64, .i64, .i64, .i64 }, cm64_cls.core_param_types);
    const cm64_thunk = createLiftThunk(ProcessFn, cm64_opts, &ComplexHandlers.process);
    const cm64_res = try lowerCall(ProcessFn, cm64_opts, ctx, cm64_thunk, .{ "wasm64", &pts });
    try testing.expectEqual(ProcessResult{ .ok = .{ .x = 46, .y = 60 } }, cm64_res);
}

test "native Zig error union support in Canonical ABI" {
    var mem: [1024]u8 align(8) = @splat(0);
    var bump = BumpAllocator.init(64, mem.len);
    const ctx = bump.memoryContext(&mem);

    const MathErr = error{ DivideByZero, Overflow };
    const MathResult = MathErr!u64;

    const l = layoutOf(MathResult, .wasm32);
    try testing.expectEqual(@as(u32, 16), l.size);
    try testing.expectEqual(@as(u32, 8), l.alignment);
    try testing.expectEqualSlices(FlatValType, &.{ .i32, .i64 }, l.flat_types);

    try storeToMemory(MathResult, .wasm32, ctx, 0, @as(MathResult, 999));
    try testing.expectEqual(@as(u64, 999), try loadFromMemory(MathResult, .wasm32, ctx, 0));

    try storeToMemory(MathResult, .wasm32, ctx, 0, MathErr.DivideByZero);
    try testing.expectError(error.DivideByZero, loadFromMemory(MathResult, .wasm32, ctx, 0));

    const Handlers = struct {
        fn safeDiv(a: u64, b: u64) MathResult {
            if (b == 0) return error.DivideByZero;
            return a / b;
        }
    };
    const DivFn = @TypeOf(Handlers.safeDiv);
    const div_thunk = createLiftThunk(DivFn, .{}, &Handlers.safeDiv);
    try testing.expectEqual(@as(u64, 21), try lowerCall(DivFn, .{}, ctx, div_thunk, .{ 84, 4 }));
    try testing.expectError(error.DivideByZero, lowerCall(DivFn, .{}, ctx, div_thunk, .{ 84, 0 }));
}

test "nested lists, tuples, arrays, handles, sentinel strings, and error conditions" {
    var mem: [8192]u8 align(8) = @splat(0);
    var bump = BumpAllocator.init(128, mem.len);
    var ctx = bump.memoryContext(&mem);
    ctx.allocator = testing.allocator;

    // 1. Nested list<string> ([]const []const u8)
    const words = [_][]const u8{ "alpha", "beta", "gamma" };
    try storeToMemory([]const []const u8, .wasm32, ctx, 0, &words);
    const lifted_words = try loadFromMemory([]const []const u8, .wasm32, ctx, 0);
    defer testing.allocator.free(lifted_words);
    try testing.expectEqual(@as(usize, 3), lifted_words.len);
    try testing.expectEqualStrings("alpha", lifted_words[0]);
    try testing.expectEqualStrings("beta", lifted_words[1]);
    try testing.expectEqualStrings("gamma", lifted_words[2]);

    // 2. Fixed-size array [3]u32 (blittable) and tuple struct
    const Arr3 = [3]u32;
    try testing.expect(layoutOf(Arr3, .wasm32).is_blittable);
    const arr_val = Arr3{ 11, 22, 33 };
    try storeToMemory(Arr3, .wasm32, ctx, 16, arr_val);
    try testing.expectEqual(arr_val, try loadFromMemory(Arr3, .wasm32, ctx, 16));
    const arr_flat = try lowerToFlat(Arr3, .wasm32, ctx, arr_val);
    try testing.expectEqual(arr_val, try liftFromFlat(Arr3, .wasm32, ctx, arr_flat));

    const TupleT = @Tuple(&.{ u8, u32, []const u8 });
    const tup_val: TupleT = .{ 7, 1000, "tuple-str" };
    try storeToMemory(TupleT, .wasm32, ctx, 32, tup_val);
    const lifted_tup = try loadFromMemory(TupleT, .wasm32, ctx, 32);
    try testing.expectEqual(@as(u8, 7), lifted_tup[0]);
    try testing.expectEqual(@as(u32, 1000), lifted_tup[1]);
    try testing.expectEqualStrings("tuple-str", lifted_tup[2]);

    // 3. Sentinel-terminated string [:0]const u8 and WitString wrapper
    const cstr: [:0]const u8 = "hello-z";
    try storeToMemory([:0]const u8, .wasm32, ctx, 64, cstr);
    const lifted_cstr = try loadFromMemory([:0]const u8, .wasm32, ctx, 64);
    defer testing.allocator.free(lifted_cstr);
    try testing.expectEqualStrings("hello-z", lifted_cstr);
    try testing.expectEqual(@as(u8, 0), lifted_cstr.ptr[lifted_cstr.len]);

    const ws = WitString{ .bytes = "wrapped-string" };
    try storeToMemory(WitString, .wasm32, ctx, 80, ws);
    const lifted_ws = try loadFromMemory(WitString, .wasm32, ctx, 80);
    try testing.expectEqualStrings("wrapped-string", lifted_ws.bytes);

    // 4. Resource handles & P3 async handles in function call round-trip
    const FileRes = opaque {};
    const HandleHandlers = struct {
        fn transformHandles(
            own_file: Own(FileRes),
            borrow_file: Borrow(FileRes),
            stream_in: Stream(u8),
            fut_in: Future(u32),
            err_ctx: ErrorContext,
        ) Own(FileRes) {
            return .{
                .handle = own_file.handle + borrow_file.handle +
                    stream_in.handle + fut_in.handle + err_ctx.handle,
            };
        }
    };
    const HandleFn = @TypeOf(HandleHandlers.transformHandles);
    const h_thunk = createLiftThunk(HandleFn, .{}, &HandleHandlers.transformHandles);
    const h_res = try lowerCall(
        HandleFn,
        .{},
        ctx,
        h_thunk,
        .{
            Own(FileRes){ .handle = 1 },
            Borrow(FileRes){ .handle = 2 },
            Stream(u8){ .handle = 3 },
            Future(u32){ .handle = 4 },
            ErrorContext{ .handle = 5 },
        },
    );
    try testing.expectEqual(@as(i32, 15), h_res.handle);

    // 5. Error conditions: InvalidUtf8, OutOfBounds, MissingRealloc
    const bad_utf8 = [_]u8{ 0xFF, 0xFE, 0xFD };
    // Bare []const u8 allows arbitrary binary list<u8> bytes by default:
    try storeToMemory([]const u8, .wasm32, ctx, 96, &bad_utf8);
    const lifted_bin = try loadFromMemory([]const u8, .wasm32, ctx, 96);
    try testing.expectEqualSlices(u8, &bad_utf8, lifted_bin);

    // WitString strictly validates UTF-8:
    try testing.expectError(error.InvalidUtf8, storeToMemory(WitString, .wasm32, ctx, 96, .{ .bytes = &bad_utf8 }));
    try testing.expectError(error.InvalidUtf8, loadFromMemory(WitString, .wasm32, ctx, 96));

    // strict_utf8_on_u8_slices = true also validates []const u8:
    var strict_ctx = ctx;
    strict_ctx.strict_utf8_on_u8_slices = true;
    try testing.expectError(error.InvalidUtf8, storeToMemory([]const u8, .wasm32, strict_ctx, 96, &bad_utf8));
    try testing.expectError(error.InvalidUtf8, loadFromMemory([]const u8, .wasm32, strict_ctx, 96));

    try testing.expectError(error.OutOfBounds, storeToMemory(u64, .wasm32, ctx, mem.len - 4, 123));

    const no_realloc_ctx = MemoryContext{ .memory = &mem };
    try testing.expectError(error.MissingRealloc, storeToMemory([]const u8, .wasm32, no_realloc_ctx, 96, "needs-alloc"));
}

test "Direction.lift vs Direction.lower: sync indirect result, post-return, async lift params, and fallback return area" {
    var mem: [16384]u8 align(8) = @splat(0);
    var bump = BumpAllocator.init(128, mem.len);
    var ctx = bump.memoryContext(&mem);

    const Point = extern struct { x: i32, y: i32 };
    const ExportHandlers = struct {
        var last_post_return_ptr: usize = 0;

        fn postReturn(pctx: ?*anyopaque, ret_val: usize) void {
            _ = pctx;
            last_post_return_ptr = ret_val;
        }

        fn makePoint(x: i32, y: i32) Point {
            return .{ .x = x * 2, .y = y * 3 };
        }

        fn asyncLift5(a: u32, b: u32, c: u32, d: u32, e: u32) Point {
            return .{ .x = @intCast(a + b + c), .y = @intCast(d + e) };
        }
    };

    const MakePointFn = @TypeOf(ExportHandlers.makePoint);
    const lower_cls = classifyZigFn(MakePointFn, .{ .direction = .lower });
    const lift_cls = classifyZigFn(MakePointFn, .{ .direction = .lift });

    // lower: (i32, i32, retptr: i32) -> void
    try testing.expectEqualSlices(FlatValType, &.{ .i32, .i32, .i32 }, lower_cls.core_param_types);
    try testing.expectEqual(@as(?FlatValType, null), lower_cls.core_result_type);

    // lift: (i32, i32) -> ret_ptr: i32 (no trailing retptr param!)
    try testing.expectEqualSlices(FlatValType, &.{ .i32, .i32 }, lift_cls.core_param_types);
    try testing.expectEqual(@as(?FlatValType, .i32), lift_cls.core_result_type);

    // Call lifted export with post_return_fn
    ctx.post_return_fn = &ExportHandlers.postReturn;
    const lift_thunk = createLiftThunk(MakePointFn, .{ .direction = .lift }, &ExportHandlers.makePoint);
    const pt = try callLifted(MakePointFn, .{}, ctx, lift_thunk, .{ 7, 11 });
    try testing.expectEqual(Point{ .x = 14, .y = 33 }, pt);
    try testing.expect(ExportHandlers.last_post_return_ptr >= 128);

    // Call createLiftThunk directly WITHOUT active_memory_ctx (uses static fallback return area with base_addr)
    if (@sizeOf(usize) == 4) {
        setActiveMemoryContext(null);
        const fallback_ret_ptr = lift_thunk(5, 9);
        const real_ptr: *const Point = @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(fallback_ret_ptr)))));
        try testing.expectEqual(Point{ .x = 10, .y = 27 }, real_ptr.*);
    } else {
        const lift_thunk64 = createLiftThunk(MakePointFn, .{ .arch = .wasm64, .direction = .lift }, &ExportHandlers.makePoint);
        setActiveMemoryContext(null);
        const fallback_ret_ptr = lift_thunk64(5, 9);
        const real_ptr: *const Point = @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(fallback_ret_ptr)))));
        try testing.expectEqual(Point{ .x = 10, .y = 27 }, real_ptr.*);
    }

    // Async lift: 5 flat params <= 16 (do NOT spill!), core_result_type is null (void),
    // and callLifted receives the delivered [task-return] payload!
    const AsyncLift5Fn = @TypeOf(ExportHandlers.asyncLift5);
    const async_lift_cls = classifyZigFn(AsyncLift5Fn, .{ .direction = .lift, .is_async = true });
    try testing.expect(!async_lift_cls.params_spill);
    try testing.expect(!async_lift_cls.results_indirect);
    try testing.expectEqualSlices(FlatValType, &.{ .i32, .i32, .i32, .i32, .i32 }, async_lift_cls.core_param_types);
    try testing.expectEqual(@as(?FlatValType, null), async_lift_cls.core_result_type);

    const async_lift_thunk = createLiftThunk(AsyncLift5Fn, .{ .direction = .lift, .is_async = true }, &ExportHandlers.asyncLift5);
    const async_pt = try callLifted(AsyncLift5Fn, .{ .is_async = true }, ctx, async_lift_thunk, .{ 1, 2, 3, 4, 5 });
    try testing.expectEqual(Point{ .x = 6, .y = 9 }, async_pt);
}

test "non-sequential/signed enum case-index encoding, flags high-bit masking, alignment checks, errdefer cleanup, and error_set" {
    var mem: [4096]u8 align(8) = @splat(0);
    var bump = BumpAllocator.init(128, mem.len);
    var ctx = bump.memoryContext(&mem);
    ctx.allocator = testing.allocator;

    // 1. Non-sequential and signed enum encoded by declaration case index (0..N-1)
    const SignedNonSeqEnum = enum(i16) {
        neg = -100,
        zero = 0,
        big = 1000,
    };
    try testing.expectEqual(@as(u32, 1), layoutOf(SignedNonSeqEnum, .wasm32).size);
    try storeToMemory(SignedNonSeqEnum, .wasm32, ctx, 0, .neg);
    try testing.expectEqual(@as(u8, 0), mem[0]);
    try testing.expectEqual(SignedNonSeqEnum.neg, try loadFromMemory(SignedNonSeqEnum, .wasm32, ctx, 0));

    try storeToMemory(SignedNonSeqEnum, .wasm32, ctx, 1, .big);
    try testing.expectEqual(@as(u8, 2), mem[1]);
    try testing.expectEqual(SignedNonSeqEnum.big, try loadFromMemory(SignedNonSeqEnum, .wasm32, ctx, 1));

    const enum_flat = try lowerToFlat(SignedNonSeqEnum, .wasm32, ctx, .big);
    try testing.expectEqual(@as(i32, 2), enum_flat[0]);
    try testing.expectEqual(SignedNonSeqEnum.big, try liftFromFlat(SignedNonSeqEnum, .wasm32, ctx, enum_flat));

    // 2. Unused high-bit masking in packed flags and extern words flags
    const Flags3 = packed struct(u8) {
        f0: bool = false,
        f1: bool = false,
        f2: bool = false,
        _pad: u5 = 0,
        pub const wit_flags_count: usize = 3;
    };
    const dirty_f3: Flags3 = @bitCast(@as(u8, 0b1111_1101));
    try storeToMemory(Flags3, .wasm32, ctx, 8, dirty_f3);
    try testing.expectEqual(@as(u8, 0b0000_0101), mem[8]);
    mem[8] = 0b1111_0010;
    const loaded_f3 = try loadFromMemory(Flags3, .wasm32, ctx, 8);
    try testing.expectEqual(@as(u8, 0b0000_0010), @as(u8, @bitCast(loaded_f3)));

    const f3_flat = try lowerToFlat(Flags3, .wasm32, ctx, dirty_f3);
    try testing.expectEqual(@as(i32, 0b101), f3_flat[0]);
    const lifted_f3_flat = try liftFromFlat(Flags3, .wasm32, ctx, .{@as(i32, 0xFF)});
    try testing.expectEqual(@as(u8, 0b111), @as(u8, @bitCast(lifted_f3_flat)));

    const Flags40 = extern struct {
        words: [2]u32 = @splat(0),
        pub const wit_flags_count: usize = 40;
    };
    const dirty_f40 = Flags40{ .words = .{ 0xFFFF_FFFF, 0xFFFF_FFAA } };
    try storeToMemory(Flags40, .wasm32, ctx, 16, dirty_f40);
    try testing.expectEqual(@as(u32, 0x0000_00AA), std.mem.readInt(u32, mem[20..24], .little));
    std.mem.writeInt(u32, mem[20..24], 0xDEAD_BE55, .little);
    const loaded_f40 = try loadFromMemory(Flags40, .wasm32, ctx, 16);
    try testing.expectEqual(@as(u32, 0x0000_0055), loaded_f40.words[1]);

    // 3. UnalignedPointer checks on storeToMemory, loadFromMemory, and loadSliceData
    try testing.expectError(error.UnalignedPointer, storeToMemory(u32, .wasm32, ctx, 3, 42));
    try testing.expectError(error.UnalignedPointer, loadFromMemory(u32, .wasm32, ctx, 3));
    std.mem.writeInt(u32, mem[32..36], 130, .little); // misaligned u32 slice ptr = 130
    std.mem.writeInt(u32, mem[36..40], 2, .little);
    try testing.expectError(error.UnalignedPointer, loadFromMemory([]const u32, .wasm32, ctx, 32));

    // 4. Leak-free errdefer cleanup in loadSliceData when an element fails mid-loop
    var copy_ctx = ctx;
    copy_ctx.zero_copy_slices = false;
    // Construct a slice of 2 WitStrings at offset 200 where element 0 is valid and element 1 has invalid UTF-8
    const s0_ptr: u32 = 300;
    @memcpy(mem[s0_ptr..][0..5], "hello");
    const s1_ptr: u32 = 316;
    mem[s1_ptr] = 0xFF;
    mem[s1_ptr + 1] = 0xFE;
    const list_ptr: u32 = 200;
    std.mem.writeInt(u32, mem[list_ptr..][0..4], s0_ptr, .little);
    std.mem.writeInt(u32, mem[list_ptr + 4 ..][0..4], 5, .little);
    std.mem.writeInt(u32, mem[list_ptr + 8 ..][0..4], s1_ptr, .little);
    std.mem.writeInt(u32, mem[list_ptr + 12 ..][0..4], 2, .little);
    std.mem.writeInt(u32, mem[48..52], list_ptr, .little);
    std.mem.writeInt(u32, mem[52..56], 2, .little);
    try testing.expectError(error.InvalidUtf8, loadFromMemory([]const WitString, .wasm32, copy_ctx, 48));

    // 4b. Leak-free errdefer cleanup in loadFromMemory and liftFromFlat for struct and array when a later field fails
    const PartialRecord = struct {
        tags: []const WitString,
        ch: Char,
    };
    const valid_list_ptr: u32 = 340;
    std.mem.writeInt(u32, mem[valid_list_ptr..][0..4], s0_ptr, .little);
    std.mem.writeInt(u32, mem[valid_list_ptr + 4 ..][0..4], 5, .little);
    // Write PartialRecord at offset 360: tags = (valid_list_ptr, 1), ch = 0x110000 (invalid Char!)
    std.mem.writeInt(u32, mem[360..364], valid_list_ptr, .little);
    std.mem.writeInt(u32, mem[364..368], 1, .little);
    std.mem.writeInt(u32, mem[368..372], 0x110000, .little);
    try testing.expectError(error.InvalidChar, loadFromMemory(PartialRecord, .wasm32, copy_ctx, 360));
    try testing.expectError(error.InvalidChar, liftFromFlat(PartialRecord, .wasm32, copy_ctx, .{
        @as(i32, @intCast(valid_list_ptr)),
        @as(i32, 1),
        @as(i32, 0x110000),
    }));
    const PartialArray = [2][]const WitString;
    // Element 0 is valid (valid_list_ptr, 1); Element 1 is invalid (list_ptr, 2)
    std.mem.writeInt(u32, mem[380..384], valid_list_ptr, .little);
    std.mem.writeInt(u32, mem[384..388], 1, .little);
    std.mem.writeInt(u32, mem[388..392], list_ptr, .little);
    std.mem.writeInt(u32, mem[392..396], 2, .little);
    try testing.expectError(error.InvalidUtf8, loadFromMemory(PartialArray, .wasm32, copy_ctx, 380));

    // 5. Standalone .error_set and Result(u32, MyErr) store/load and lower/lift
    const MyErr = error{ First, Second, Third };
    try storeToMemory(MyErr, .wasm32, ctx, 64, error.Second);
    try testing.expectError(error.Second, loadFromMemory(MyErr, .wasm32, ctx, 64));
    const err_flat = try lowerToFlat(MyErr, .wasm32, ctx, error.Third);
    try testing.expectError(error.Third, liftFromFlat(MyErr, .wasm32, ctx, err_flat));

    const ResWithErrSet = Result(u32, MyErr);
    try storeToMemory(ResWithErrSet, .wasm32, ctx, 72, .{ .err = error.Second });
    const loaded_res = try loadFromMemory(ResWithErrSet, .wasm32, ctx, 72);
    try testing.expectEqual(error.Second, loaded_res.err);
    const res_flat = try lowerToFlat(ResWithErrSet, .wasm32, ctx, .{ .err = error.Third });
    const lifted_res = try liftFromFlat(ResWithErrSet, .wasm32, ctx, res_flat);
    try testing.expectEqual(error.Third, lifted_res.err);
}

test "CanonLower.callAuto: fast-path dispatch (0 reallocs) and transparent Canonical ABI fallback" {
    var mem: [8192]u8 align(16) = undefined;
    @memset(&mem, 0);

    const CountingAllocator = struct {
        bump: BumpAllocator,
        realloc_count: usize = 0,

        fn realloc(
            raw_ctx: ?*anyopaque,
            orig_ptr: usize,
            orig_size: usize,
            alignment: usize,
            new_size: usize,
        ) Error!usize {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            self.realloc_count += 1;
            return BumpAllocator.realloc(&self.bump, orig_ptr, orig_size, alignment, new_size);
        }
    };

    var counting = CountingAllocator{ .bump = BumpAllocator.init(512, mem.len) };
    var ctx = MemoryContext{
        .memory = &mem,
        .base_addr = if (builtin.cpu.arch.isWasm()) @intFromPtr(&mem) else 0,
        .realloc_ctx = &counting,
        .realloc_fn = CountingAllocator.realloc,
        .allocator = testing.allocator,
        .fast_frame_offset = 64,
    };

    const GreetFn = fn (name: []const u8, repeat: u32) u32;
    const GuestImpl = struct {
        fn greet(name: []const u8, repeat: u32) u32 {
            return @as(u32, @intCast(name.len)) * repeat;
        }
    };

    const Lower = CanonLower(GreetFn, false);
    const LiftCanon = CanonLift(GreetFn, false);
    const LiftFast = FastLift(GreetFn, GuestImpl.greet, false);

    // Prepare active context for Canonical ABI thunk
    setActiveMemoryContext(ctx);
    defer setActiveMemoryContext(null);

    const canon_thunk = LiftCanon.thunk(&GuestImpl.greet);
    const fast_thunk = LiftFast.thunk();

    const entries = [_]fast_abi.ZigarFuncEntry{.{
        .interface_name = "zigar:test/greeter",
        .func_name = "greet",
        .fast_export_name = "__zigar_fast_zigar:test/greeter#greet",
        .abi_hash = Lower.abi_hash,
        .arg_struct_size = @intCast(LiftFast.frame_layout.frame_size),
        .arg_struct_align = @intCast(LiftFast.frame_layout.frame_align),
        .flags = LiftFast.frame_layout.flags,
    }};
    const matching_meta = fast_abi.ZigarAbiMetadata{
        .world_hash = 0x42,
        .entries = &entries,
    };

    // 1. Matching `guest_abi` + `fast_core_fn` -> takes fast path (`realloc_count == 0`!)
    counting.realloc_count = 0;
    const fast_res = try Lower.callAuto(
        &ctx,
        matching_meta,
        "zigar:test/greeter",
        "greet",
        fast_thunk,
        canon_thunk,
        .{ "hello-zigar", 3 },
    );
    try testing.expectEqual(@as(u32, 33), fast_res);
    try testing.expectEqual(@as(usize, 0), counting.realloc_count);

    // 2. `guest_abi == null` -> falls back to Canonical ABI (`realloc_count > 0` for string lowering)
    counting.realloc_count = 0;
    const fallback_null = try Lower.callAuto(
        &ctx,
        null,
        "zigar:test/greeter",
        "greet",
        fast_thunk,
        canon_thunk,
        .{ "hello-zigar", 3 },
    );
    try testing.expectEqual(@as(u32, 33), fallback_null);
    try testing.expect(counting.realloc_count > 0);

    // 3. Function / interface name missing in `guest_abi` -> falls back to Canonical ABI
    counting.realloc_count = 0;
    const fallback_missing = try Lower.callAuto(
        &ctx,
        matching_meta,
        "zigar:test/other-iface",
        "greet",
        fast_thunk,
        canon_thunk,
        .{ "hello-zigar", 4 },
    );
    try testing.expectEqual(@as(u32, 44), fallback_missing);
    try testing.expect(counting.realloc_count > 0);

    // 4. Mismatched `abi_hash` -> falls back to Canonical ABI
    const mismatched_entries = [_]fast_abi.ZigarFuncEntry{.{
        .interface_name = "zigar:test/greeter",
        .func_name = "greet",
        .fast_export_name = "__zigar_fast_zigar:test/greeter#greet",
        .abi_hash = Lower.abi_hash ^ 1,
        .arg_struct_size = @intCast(LiftFast.frame_layout.frame_size),
        .arg_struct_align = @intCast(LiftFast.frame_layout.frame_align),
        .flags = LiftFast.frame_layout.flags,
    }};
    const mismatched_meta = fast_abi.ZigarAbiMetadata{ .entries = &mismatched_entries };
    counting.realloc_count = 0;
    const fallback_hash = try Lower.callAuto(
        &ctx,
        mismatched_meta,
        "zigar:test/greeter",
        "greet",
        fast_thunk,
        canon_thunk,
        .{ "hello-zigar", 5 },
    );
    try testing.expectEqual(@as(u32, 55), fallback_hash);
    try testing.expect(counting.realloc_count > 0);

    // 5. N3a: Mismatched `arg_struct_size` / `arg_struct_align` -> falls back to Canonical ABI
    const bad_size_entries = [_]fast_abi.ZigarFuncEntry{.{
        .interface_name = "zigar:test/greeter",
        .func_name = "greet",
        .fast_export_name = "__zigar_fast_zigar:test/greeter#greet",
        .abi_hash = Lower.abi_hash,
        .arg_struct_size = @intCast(LiftFast.frame_layout.frame_size + 8),
        .arg_struct_align = @intCast(LiftFast.frame_layout.frame_align),
        .flags = LiftFast.frame_layout.flags,
    }};
    const bad_size_meta = fast_abi.ZigarAbiMetadata{ .entries = &bad_size_entries };
    counting.realloc_count = 0;
    const fallback_size = try Lower.callAuto(
        &ctx,
        bad_size_meta,
        "zigar:test/greeter",
        "greet",
        fast_thunk,
        canon_thunk,
        .{ "hello-zigar", 6 },
    );
    try testing.expectEqual(@as(u32, 66), fallback_size);
    try testing.expect(counting.realloc_count > 0);

    // 6. N3b: Store-phase `OutOfBounds` in `FastLower` (e.g. `fast_frame_offset` past end of memory)
    // transparently falls back to Canonical ABI `Self.call` before `fast_fn` is invoked!
    ctx.fast_frame_offset = mem.len - 4;
    defer ctx.fast_frame_offset = 64;
    counting.realloc_count = 0;
    const fallback_oob = try Lower.callAuto(
        &ctx,
        matching_meta,
        "zigar:test/greeter",
        "greet",
        fast_thunk,
        canon_thunk,
        .{ "hello-zigar", 7 },
    );
    try testing.expectEqual(@as(u32, 77), fallback_oob);
    try testing.expect(counting.realloc_count > 0);

    // 7. `configureFastScratch` with a tight `fast_scratch_limit`: when argument payload exceeds
    // `fast_scratch_limit`, `FastLower` returns `error.OutOfBounds` and `CanonLower.callAuto`
    // transparently falls back to Canonical ABI (`realloc_count > 0`)!
    try ctx.configureFastScratch(ctx.base_addr + 64, LiftFast.frame_layout.frame_size + 4);
    defer ctx.fast_scratch_limit = null;
    try testing.expectError(
        error.OutOfBounds,
        FastLower(GreetFn, false).call(&ctx, fast_thunk, .{ "payload-exceeding-4-byte-scratch-tail", 8 }),
    );
    counting.realloc_count = 0;
    const fallback_scratch_limit = try Lower.callAuto(
        &ctx,
        matching_meta,
        "zigar:test/greeter",
        "greet",
        fast_thunk,
        canon_thunk,
        .{ "payload-exceeding-4-byte-scratch-tail", 8 },
    );
    try testing.expectEqual(@as(u32, 37 * 8), fallback_scratch_limit);
    try testing.expect(counting.realloc_count > 0);
}

test "canon async lowerCall await_subtask_fn and callLifted poll_task_fn" {
    var mem: [4096]u8 align(16) = @splat(0);
    var bump = BumpAllocator.init(64, mem.len);

    // 1. Async lowerCall with pending subtask resolved via ctx.await_subtask_fn
    const PendingSubtaskEnv = struct {
        saved_arg: u32 = 0,
        saved_ret_ptr: usize = 0,
        awaited_status: i32 = 0,
        await_calls: usize = 0,

        var current: ?*@This() = null;

        fn coreImport(x: i32, ret_ptr: i32) i32 {
            const env = current.?;
            env.saved_arg = @bitCast(x);
            env.saved_ret_ptr = @intCast(@as(u32, @bitCast(ret_ptr)));
            // Return SubtaskState.started (1) with subtask handle 7: 1 | (7 << 4)
            return @as(i32, 1 | (7 << 4));
        }

        fn coreImmediateWithHandle(x: i32, ret_ptr: i32) i32 {
            const env = current.?;
            const mctx = getActiveMemoryContext().?;
            const ptr: usize = @intCast(@as(u32, @bitCast(ret_ptr)));
            const val: u32 = @as(u32, @bitCast(x)) + 100;
            storeToMemory(u32, .wasm32, mctx, ptr, val) catch unreachable;
            env.saved_ret_ptr = ptr;
            // Return SubtaskState.returned (2) with non-zero handle 9: 2 | (9 << 4)
            return @as(i32, 2 | (9 << 4));
        }

        fn awaitSubtask(raw_ctx: ?*anyopaque, mem_ctx: *MemoryContext, packed_status: i32) Error!void {
            const env: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            env.awaited_status = packed_status;
            env.await_calls += 1;
            const ustatus: u32 = @bitCast(packed_status);
            const state: u4 = @truncate(ustatus & 0xf);
            if (state != 2) {
                try storeToMemory(u32, .wasm32, mem_ctx.*, env.saved_ret_ptr, env.saved_arg * 3 + 1);
            }
        }
    };

    var sub_env = PendingSubtaskEnv{};
    PendingSubtaskEnv.current = &sub_env;
    defer PendingSubtaskEnv.current = null;

    const AsyncImportFn = fn (x: u32) u32;
    const lower_async_opts = CallOptions{
        .arch = .wasm32,
        .is_async = true,
        .direction = .lower,
    };

    const no_await_ctx = MemoryContext{
        .memory = &mem,
        .realloc_ctx = &bump,
        .realloc_fn = BumpAllocator.realloc,
    };
    try testing.expectError(
        error.AsyncCallPending,
        lowerCall(AsyncImportFn, lower_async_opts, no_await_ctx, &PendingSubtaskEnv.coreImport, .{14}),
    );

    var await_ctx = no_await_ctx;
    await_ctx.await_subtask_ctx = &sub_env;
    await_ctx.await_subtask_fn = &PendingSubtaskEnv.awaitSubtask;

    const async_res = try lowerCall(AsyncImportFn, lower_async_opts, await_ctx, &PendingSubtaskEnv.coreImport, .{14});
    try testing.expectEqual(@as(u32, 43), async_res);
    try testing.expectEqual(@as(usize, 1), sub_env.await_calls);
    try testing.expectEqual(@as(i32, 1 | (7 << 4)), sub_env.awaited_status);

    // State == 2 with handle != 0 also invokes await_subtask_fn to drop the handle
    const imm_res = try lowerCall(AsyncImportFn, lower_async_opts, await_ctx, &PendingSubtaskEnv.coreImmediateWithHandle, .{25});
    try testing.expectEqual(@as(u32, 125), imm_res);
    try testing.expectEqual(@as(usize, 2), sub_env.await_calls);
    try testing.expectEqual(@as(i32, 2 | (9 << 4)), sub_env.awaited_status);

    // 2. Async callLifted with deferred [task-return] driven by ctx.poll_task_fn
    const DeferredLiftEnv = struct {
        pending_arg: u32 = 0,
        polls: usize = 0,

        var current: ?*@This() = null;

        fn coreDeferredExport(x: i32) void {
            const env = current.?;
            env.pending_arg = @bitCast(x);
            // Does NOT call task_return_fn during initial invocation!
        }

        fn pollTask(raw_ctx: ?*anyopaque, mem_ctx: *MemoryContext) Error!void {
            const env: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            env.polls += 1;
            if (env.polls >= 2) {
                const ret_ptr = try mem_ctx.realloc(4, 4);
                try storeToMemory(u32, .wasm32, mem_ctx.*, ret_ptr, env.pending_arg + 500);
                if (mem_ctx.task_return_fn) |tr_fn| {
                    tr_fn(mem_ctx.task_return_ctx, ret_ptr);
                }
            }
        }
    };

    var lift_env = DeferredLiftEnv{};
    DeferredLiftEnv.current = &lift_env;
    defer DeferredLiftEnv.current = null;

    try testing.expectError(
        error.AsyncTaskDidNotReturn,
        callLifted(AsyncImportFn, .{ .arch = .wasm32, .is_async = true }, no_await_ctx, &DeferredLiftEnv.coreDeferredExport, .{42}),
    );

    var poll_ctx = no_await_ctx;
    poll_ctx.poll_task_ctx = &lift_env;
    poll_ctx.poll_task_fn = &DeferredLiftEnv.pollTask;

    const lifted_res = try callLifted(
        AsyncImportFn,
        .{ .arch = .wasm32, .is_async = true },
        poll_ctx,
        &DeferredLiftEnv.coreDeferredExport,
        .{42},
    );
    try testing.expectEqual(@as(u32, 542), lifted_res);
    try testing.expectEqual(@as(usize, 2), lift_env.polls);
}
