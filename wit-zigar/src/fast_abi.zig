//! `"zigar:abi"` custom section codec, detector, comptime structural ABI
//! hashing, and direct linear-memory `ArgStruct` comptime bypass (`FastLower` /
//! `FastLift`) for Zig-to-Zig WebAssembly Components.
//!
//! When both caller and callee are compiled with Zigar (`"zigar:abi"` custom
//! section present and `abi_hash` + target architecture match), `FastLower` and
//! `FastLift` bypass the Component Model Canonical ABI's 16-register flattening,
//! variant slot joining, `cabi_realloc` allocations, and `cabi_post_*`
//! callbacks in favor of a single linear-memory `ArgStruct` frame pointer with
//! in-place zero-copy slice passing.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const canon = @import("canon.zig");
const embed = @import("component/wit/embed.zig");

// ── `"zigar:abi"` Custom Section Format Constants & Types ──────────────────

pub const SECTION_NAME = "zigar:abi";
pub const MAGIC: [4]u8 = "ZGAR".*;
pub const FORMAT_VERSION: u16 = 1;

const CORE_WASM_PREAMBLE = "\x00asm\x01\x00\x00\x00";
const COMPONENT_PREAMBLE = "\x00asm\x0d\x00\x01\x00";

pub const FLAG_HAS_INDIRECT_SLICES: u32 = 1 << 0;
pub const FLAG_IS_BLITTABLE_ONLY: u32 = 1 << 1;

pub const Flags = packed struct(u16) {
    is_memory64: bool = false,
    is_big_endian: bool = false,
    zero_copy_slices: bool = true,
    _reserved: u13 = 0,
};

pub const ZigarFuncEntry = struct {
    interface_name: []const u8 = "",
    func_name: []const u8,
    fast_export_name: []const u8,
    abi_hash: u64,
    arg_struct_size: u32,
    arg_struct_align: u32,
    flags: u32 = 0,

    pub fn hasIndirectSlices(self: ZigarFuncEntry) bool {
        return (self.flags & FLAG_HAS_INDIRECT_SLICES) != 0;
    }

    pub fn isBlittableOnly(self: ZigarFuncEntry) bool {
        return (self.flags & FLAG_IS_BLITTABLE_ONLY) != 0;
    }
};

pub const ZigarAbiMetadata = struct {
    version: u16 = FORMAT_VERSION,
    flags: Flags = .{},
    world_hash: u64 = 0,
    entries: []const ZigarFuncEntry = &.{},

    pub fn deinit(self: anytype, alloc: Allocator) void {
        for (self.entries) |entry| {
            alloc.free(entry.interface_name);
            alloc.free(entry.func_name);
            alloc.free(entry.fast_export_name);
        }
        alloc.free(self.entries);
    }

    pub fn isTargetCompatible(self: ZigarAbiMetadata, comptime is_memory64: bool) bool {
        const host_is_big_endian = (builtin.cpu.arch.endian() == .big);
        return self.version == FORMAT_VERSION and
            self.flags.is_memory64 == is_memory64 and
            self.flags.is_big_endian == host_is_big_endian and
            self.flags._reserved == 0;
    }

    pub fn findCompatibleFunc(
        self: ZigarAbiMetadata,
        interface_name: []const u8,
        func_name: []const u8,
        expected_abi_hash: u64,
        comptime is_memory64: bool,
    ) ?ZigarFuncEntry {
        if (!self.isTargetCompatible(is_memory64)) return null;
        for (self.entries) |entry| {
            if (eqlInterfaceName(entry.interface_name, interface_name) and
                std.mem.eql(u8, entry.func_name, func_name) and
                entry.abi_hash == expected_abi_hash)
            {
                return entry;
            }
        }
        return null;
    }

    pub fn findCompatibleFuncWithLayout(
        self: ZigarAbiMetadata,
        interface_name: []const u8,
        func_name: []const u8,
        expected_abi_hash: u64,
        expected_size: u32,
        expected_align: u32,
        comptime is_memory64: bool,
    ) ?ZigarFuncEntry {
        const entry = self.findCompatibleFunc(interface_name, func_name, expected_abi_hash, is_memory64) orelse return null;
        if (entry.arg_struct_size != expected_size or entry.arg_struct_align != expected_align) {
            return null;
        }
        return entry;
    }
};

fn eqlInterfaceName(a: []const u8, b: []const u8) bool {
    const norm_a = if (std.mem.eql(u8, a, "$root")) "" else a;
    const norm_b = if (std.mem.eql(u8, b, "$root")) "" else b;
    return std.mem.eql(u8, norm_a, norm_b);
}

pub const SectionError = error{
    OutOfMemory,
    InvalidMagic,
    UnsupportedVersion,
    InvalidFlags,
    UnexpectedEndOfInput,
    InvalidUtf8,
    CorruptSection,
    TrailingBytes,
    InvalidWasmModule,
    InvalidComponent,
    InvalidWasmBinary,
};

// ── FNV-1a 64-bit Deterministic Hashing ────────────────────────────────────

pub const Fnv1a64 = struct {
    state: u64 = 0xcbf29ce484222325,

    pub fn update(self: *Fnv1a64, bytes: []const u8) void {
        for (bytes) |b| {
            self.state ^= b;
            self.state *%= 0x100000001b3;
        }
    }

    pub fn updateByte(self: *Fnv1a64, b: u8) void {
        self.state ^= b;
        self.state *%= 0x100000001b3;
    }

    pub fn updateU32(self: *Fnv1a64, v: u32) void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        self.update(&buf);
    }

    pub fn updateU64(self: *Fnv1a64, v: u64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        self.update(&buf);
    }
};

pub fn fnv1a64(bytes: []const u8) u64 {
    var h = Fnv1a64{};
    h.update(bytes);
    return h.state;
}

// ── `"zigar:abi"` Binary Section Codec & Detectors ─────────────────────────

/// Encode `ZigarAbiMetadata` into its binary custom-section payload.
pub fn encodeZigarAbiSection(alloc: Allocator, meta: anytype) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    // 20-byte fixed header:
    //   [0..4]   MAGIC ("ZGAR")
    //   [4..6]   version (u16 LE)
    //   [6..8]   flags (u16 LE)
    //   [8..16]  world_hash (u64 LE)
    //   [16..20] entry_count (u32 LE)
    try out.appendSlice(alloc, &MAGIC);
    try appendInt(alloc, &out, u16, meta.version);
    const raw_flags: u16 = @bitCast(Flags{
        .is_memory64 = meta.flags.is_memory64,
        .is_big_endian = meta.flags.is_big_endian,
        .zero_copy_slices = meta.flags.zero_copy_slices,
        ._reserved = meta.flags._reserved,
    });
    try appendInt(alloc, &out, u16, raw_flags);
    try appendInt(alloc, &out, u64, meta.world_hash);
    try appendInt(alloc, &out, u32, @intCast(meta.entries.len));

    for (meta.entries) |entry| {
        try appendString(alloc, &out, entry.interface_name);
        try appendString(alloc, &out, entry.func_name);
        try appendString(alloc, &out, entry.fast_export_name);
        try appendInt(alloc, &out, u64, entry.abi_hash);
        try appendInt(alloc, &out, u32, entry.arg_struct_size);
        try appendInt(alloc, &out, u32, entry.arg_struct_align);
        try appendInt(alloc, &out, u32, entry.flags);
    }

    return out.toOwnedSlice(alloc);
}

/// Decode a `"zigar:abi"` custom-section binary payload into `ZigarAbiMetadata`.
/// Caller owns the returned strings and `entries` slice (`defer meta.deinit(alloc)`).
pub fn decodeZigarAbiSection(alloc: Allocator, payload: []const u8) SectionError!ZigarAbiMetadata {
    if (payload.len < 20) return error.UnexpectedEndOfInput;
    if (!std.mem.eql(u8, payload[0..4], &MAGIC)) return error.InvalidMagic;

    const version = std.mem.readInt(u16, payload[4..6], .little);
    if (version != FORMAT_VERSION) return error.UnsupportedVersion;

    const raw_flags = std.mem.readInt(u16, payload[6..8], .little);
    const flags: Flags = @bitCast(raw_flags);
    if (flags._reserved != 0) return error.InvalidFlags;

    const world_hash = std.mem.readInt(u64, payload[8..16], .little);
    const entry_count = std.mem.readInt(u32, payload[16..20], .little);

    var pos: usize = 20;
    // Each entry requires at least 3 * 4 (string lengths) + 8 + 4 + 4 + 4 = 32 bytes.
    if (entry_count > (payload.len - pos) / 32) return error.UnexpectedEndOfInput;

    var entries = try alloc.alloc(ZigarFuncEntry, entry_count);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |e| {
            alloc.free(e.interface_name);
            alloc.free(e.func_name);
            alloc.free(e.fast_export_name);
        }
        alloc.free(entries);
    }

    for (0..entry_count) |idx| {
        const iface_str = try readValidatedString(payload, &pos);
        const func_str = try readValidatedString(payload, &pos);
        const export_str = try readValidatedString(payload, &pos);
        if (func_str.len == 0 or export_str.len == 0) return error.CorruptSection;

        if (payload.len - pos < 20) return error.UnexpectedEndOfInput;
        const abi_hash = std.mem.readInt(u64, payload[pos..][0..8], .little);
        pos += 8;
        const arg_struct_size = std.mem.readInt(u32, payload[pos..][0..4], .little);
        pos += 4;
        const arg_struct_align = std.mem.readInt(u32, payload[pos..][0..4], .little);
        pos += 4;
        const entry_flags = std.mem.readInt(u32, payload[pos..][0..4], .little);
        pos += 4;

        if (arg_struct_align == 0 or !std.math.isPowerOfTwo(arg_struct_align)) {
            return error.CorruptSection;
        }
        if ((entry_flags & ~(FLAG_HAS_INDIRECT_SLICES | FLAG_IS_BLITTABLE_ONLY)) != 0) {
            return error.CorruptSection;
        }

        const owned_iface = try alloc.dupe(u8, iface_str);
        errdefer alloc.free(owned_iface);
        const owned_func = try alloc.dupe(u8, func_str);
        errdefer alloc.free(owned_func);
        const owned_export = try alloc.dupe(u8, export_str);
        errdefer alloc.free(owned_export);

        entries[idx] = .{
            .interface_name = owned_iface,
            .func_name = owned_func,
            .fast_export_name = owned_export,
            .abi_hash = abi_hash,
            .arg_struct_size = arg_struct_size,
            .arg_struct_align = arg_struct_align,
            .flags = entry_flags,
        };
        initialized = idx + 1;
    }

    if (pos != payload.len) return error.TrailingBytes;

    return .{
        .version = version,
        .flags = flags,
        .world_hash = world_hash,
        .entries = entries,
    };
}

/// Encode `meta` and embed it into `core_wasm_bytes` as custom section `"zigar:abi"`.
/// Existing `"zigar:abi"` sections are replaced idempotently.
pub fn embedZigarAbiSection(
    alloc: Allocator,
    core_wasm_bytes: []const u8,
    meta: anytype,
) ![]u8 {
    const payload = try encodeZigarAbiSection(alloc, meta);
    defer alloc.free(payload);
    return embed.embedCustomSection(alloc, core_wasm_bytes, SECTION_NAME, payload);
}

/// Inspect a core Wasm module (`\x00asm\x01\x00\x00\x00`) for a `"zigar:abi"`
/// custom section. Returns `null` if not present, or an error if the Wasm
/// framing or `"zigar:abi"` payload is corrupt.
pub fn detectZigarAbiInCoreModule(
    alloc: Allocator,
    core_wasm_bytes: []const u8,
) SectionError!?ZigarAbiMetadata {
    if (core_wasm_bytes.len < 8 or !std.mem.eql(u8, core_wasm_bytes[0..8], CORE_WASM_PREAMBLE)) {
        return error.InvalidWasmModule;
    }

    var pos: usize = 8;
    while (pos < core_wasm_bytes.len) {
        const sec_id = core_wasm_bytes[pos];
        pos += 1;
        const sec_len = readU32Leb(core_wasm_bytes, &pos) catch return error.InvalidWasmModule;
        if (sec_len > core_wasm_bytes.len - pos) return error.InvalidWasmModule;
        const body = core_wasm_bytes[pos .. pos + sec_len];
        pos += sec_len;

        if (sec_id == 0) {
            var body_pos: usize = 0;
            const name_len = readU32Leb(body, &body_pos) catch return error.InvalidWasmModule;
            if (name_len > body.len - body_pos) return error.InvalidWasmModule;
            const sec_name = body[body_pos .. body_pos + name_len];
            body_pos += name_len;
            if (std.mem.eql(u8, sec_name, SECTION_NAME)) {
                return try decodeZigarAbiSection(alloc, body[body_pos..]);
            }
        }
    }
    return null;
}

pub const MAX_COMPONENT_NESTING_DEPTH: usize = 64;

/// Inspect a WebAssembly Component binary (`\x00asm\x0d\x00\x01\x00`) for a
/// `"zigar:abi"` custom section either at the component top level (`id == 0`)
/// or inside any embedded `core_module` section (`id == 1`) or nested
/// component section (`id == 4`).
pub fn detectZigarAbiInComponent(
    alloc: Allocator,
    component_bytes: []const u8,
) SectionError!?ZigarAbiMetadata {
    return detectZigarAbiInComponentBounded(alloc, component_bytes, 0);
}

pub fn detectZigarAbiInComponentBounded(
    alloc: Allocator,
    component_bytes: []const u8,
    depth: usize,
) SectionError!?ZigarAbiMetadata {
    if (depth > MAX_COMPONENT_NESTING_DEPTH) return error.InvalidComponent;
    if (component_bytes.len < 8 or !std.mem.eql(u8, component_bytes[0..8], COMPONENT_PREAMBLE)) {
        return error.InvalidComponent;
    }

    var pos: usize = 8;
    while (pos < component_bytes.len) {
        const sec_id = component_bytes[pos];
        pos += 1;
        const sec_len = readU32Leb(component_bytes, &pos) catch return error.InvalidComponent;
        if (sec_len > component_bytes.len - pos) return error.InvalidComponent;
        const body = component_bytes[pos .. pos + sec_len];
        pos += sec_len;

        switch (sec_id) {
            0 => {
                var body_pos: usize = 0;
                const name_len = readU32Leb(body, &body_pos) catch return error.InvalidComponent;
                if (name_len > body.len - body_pos) return error.InvalidComponent;
                const sec_name = body[body_pos .. body_pos + name_len];
                body_pos += name_len;
                if (std.mem.eql(u8, sec_name, SECTION_NAME)) {
                    return try decodeZigarAbiSection(alloc, body[body_pos..]);
                }
            },
            1 => {
                if (try detectZigarAbiInCoreModule(alloc, body)) |meta| {
                    return meta;
                }
            },
            4 => {
                if (try detectZigarAbiInComponentBounded(alloc, body, depth + 1)) |meta| {
                    return meta;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Unified detector for both core Wasm modules and WebAssembly Components.
pub fn detectZigarAbi(
    alloc: Allocator,
    wasm_or_component_bytes: []const u8,
) SectionError!?ZigarAbiMetadata {
    if (wasm_or_component_bytes.len < 8 or !std.mem.eql(u8, wasm_or_component_bytes[0..4], "\x00asm")) {
        return error.InvalidWasmBinary;
    }
    if (std.mem.eql(u8, wasm_or_component_bytes[4..8], "\x01\x00\x00\x00")) {
        return detectZigarAbiInCoreModule(alloc, wasm_or_component_bytes);
    }
    if (std.mem.eql(u8, wasm_or_component_bytes[4..8], "\x0d\x00\x01\x00")) {
        return detectZigarAbiInComponent(alloc, wasm_or_component_bytes);
    }
    return error.InvalidWasmBinary;
}

fn appendInt(alloc: Allocator, out: *std.ArrayList(u8), comptime IntT: type, v: IntT) Allocator.Error!void {
    var buf: [@sizeOf(IntT)]u8 = undefined;
    std.mem.writeInt(IntT, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

fn appendString(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try appendInt(alloc, out, u32, @intCast(s.len));
    try out.appendSlice(alloc, s);
}

fn readValidatedString(payload: []const u8, pos: *usize) SectionError![]const u8 {
    if (payload.len - pos.* < 4) return error.UnexpectedEndOfInput;
    const len = std.mem.readInt(u32, payload[pos.*..][0..4], .little);
    pos.* += 4;
    if (len > payload.len - pos.*) return error.UnexpectedEndOfInput;
    const slice = payload[pos.* .. pos.* + len];
    pos.* += len;
    if (!std.unicode.utf8ValidateSlice(slice)) return error.InvalidUtf8;
    return slice;
}

fn readU32Leb(buf: []const u8, pos: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    var i: usize = pos.*;
    while (i < buf.len) : (i += 1) {
        const b = buf[i];
        result |= @as(u32, b & 0x7f) << shift;
        if ((b & 0x80) == 0) {
            pos.* = i + 1;
            return result;
        }
        if (shift >= 25) return error.LebOverflow;
        shift += 7;
    }
    return error.LebTruncated;
}

// ── Comptime Wire Layout & Deterministic Structural ABI Hashing ────────────

pub fn PtrInt(comptime is_memory64: bool) type {
    return if (is_memory64) u64 else u32;
}

pub const Layout = struct {
    size: u32,
    alignment: u32,
    has_indirect_slices: bool = false,
    is_blittable: bool = false,
};

pub fn wireLayoutOf(comptime T: type, comptime is_memory64: bool) Layout {
    const arch: canon.Arch = if (is_memory64) .wasm64 else .wasm32;
    const cl = comptime canon.layoutOf(T, arch);
    return .{
        .size = cl.size,
        .alignment = cl.alignment,
        .has_indirect_slices = cl.needs_memory,
        .is_blittable = cl.is_blittable,
    };
}

/// Deterministic comptime structural 64-bit FNV-1a hash of a Zig type `T`'s
/// wire representation for `is_memory64`.
pub fn comptimeTypeAbiHash(comptime T: type, comptime is_memory64: bool) u64 {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        var h = Fnv1a64{};
        hashTypeStructure(T, is_memory64, &h);
        break :blk h.state;
    };
}

/// Deterministic comptime 64-bit FNV-1a hash of a Zig function signature
/// `FnType` (parameter wire layouts + return wire layout + memory64 flag).
pub fn comptimeAbiHash(comptime FnType: type, comptime is_memory64: bool) u64 {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        const f = @typeInfo(FnType).@"fn";
        var h = Fnv1a64{};
        h.update("zigar:fn:v1");
        h.updateByte(if (is_memory64) 1 else 0);
        h.updateU32(@intCast(f.param_types.len));
        for (f.param_types) |maybe_pt| {
            const PT = maybe_pt.?;
            h.updateU64(comptimeTypeAbiHash(PT, is_memory64));
        }
        const RetT = f.return_type orelse void;
        h.updateU64(comptimeTypeAbiHash(RetT, is_memory64));
        break :blk h.state;
    };
}

fn hashTypeStructure(comptime T: type, comptime is_memory64: bool, h: *Fnv1a64) void {
    const wl = wireLayoutOf(T, is_memory64);

    if (T == void) {
        h.update("void");
        return;
    }

    if (canon.isCharType(T)) {
        h.update("char:u21");
        return;
    }

    switch (@typeInfo(T)) {
        .bool => h.update("bool"),
        .int => |int| {
            h.update(if (int.signedness == .signed) "sint:" else "uint:");
            h.updateU32(int.bits);
        },
        .float => |fl| {
            h.update("float:");
            h.updateU32(fl.bits);
        },
        .@"enum" => |en| {
            h.update("enum:");
            h.updateU32(@intCast(en.field_names.len));
            h.updateU32(wl.size);
        },
        .pointer => |pt| switch (pt.size) {
            .slice => {
                h.update("slice:");
                h.updateU32(@sizeOf(PtrInt(is_memory64)));
                hashTypeStructure(pt.child, is_memory64, h);
            },
            else => @compileError("Unsupported pointer in fast_abi: " ++ @typeName(T)),
        },
        .array => |ar| {
            h.update("array:");
            h.updateU32(@intCast(ar.len));
            hashTypeStructure(ar.child, is_memory64, h);
        },
        .@"struct" => |st| {
            if (canon.isHandleType(T)) {
                h.update("handle:");
                h.update(@tagName(T.wit_handle_kind));
                return;
            }
            if (canon.isStringWrapper(T)) {
                h.update("slice:");
                h.updateU32(@sizeOf(PtrInt(is_memory64)));
                const ElemT = if (@hasDecl(T, "CodeUnit")) T.CodeUnit else u8;
                hashTypeStructure(ElemT, is_memory64, h);
                return;
            }
            if (st.layout == .@"packed" or @hasDecl(T, "wit_flags_count")) {
                const bit_count: u32 = if (@hasDecl(T, "wit_flags_count"))
                    T.wit_flags_count
                else
                    @bitSizeOf(st.backing_integer.?);
                h.update("flags:");
                h.updateU32(bit_count);
                h.updateU32(wl.size);
                h.updateU32(wl.alignment);
                return;
            }

            const arch: canon.Arch = if (is_memory64) .wasm64 else .wasm32;
            h.update("struct:");
            h.updateU32(wl.size);
            h.updateU32(wl.alignment);
            var runtime_fields: u32 = 0;
            for (st.field_attrs) |attr| {
                if (!attr.@"comptime") runtime_fields += 1;
            }
            h.updateU32(runtime_fields);
            for (st.field_types, 0..) |FT, i| {
                if (st.field_attrs[i].@"comptime") continue;
                h.updateU32(canon.fieldOffset(T, arch, i));
                hashTypeStructure(FT, is_memory64, h);
            }
        },
        .optional => |op| {
            h.update("option:");
            h.updateU32(wl.size);
            h.updateU32(wl.alignment);
            hashTypeStructure(op.child, is_memory64, h);
        },
        .@"union" => |un| {
            if (@hasDecl(T, "wit_is_result") and @hasDecl(T, "OkType") and @hasDecl(T, "ErrType")) {
                h.update("result:");
                h.updateU32(wl.size);
                h.updateU32(wl.alignment);
                hashTypeStructure(T.OkType, is_memory64, h);
                hashTypeStructure(T.ErrType, is_memory64, h);
                return;
            }
            h.update("variant:");
            h.updateU32(wl.size);
            h.updateU32(wl.alignment);
            h.updateU32(@intCast(un.field_names.len));
            for (un.field_types) |CaseT| {
                hashTypeStructure(CaseT, is_memory64, h);
            }
        },
        .error_set => |es| {
            const names = es.error_names orelse @compileError("anyerror is not supported in fast_abi");
            h.update("errset:");
            h.updateU32(@intCast(names.len));
            h.updateU32(wl.size);
        },
        .error_union => |eu| {
            h.update("result:");
            h.updateU32(wl.size);
            h.updateU32(wl.alignment);
            hashTypeStructure(eu.payload, is_memory64, h);
            hashTypeStructure(eu.error_set, is_memory64, h);
        },
        else => @compileError("Unsupported type in fast_abi: " ++ @typeName(T)),
    }
}

/// Returns true when a slice `[]const Elem` has an identical in-memory byte
/// representation in native Zig memory and wire linear memory, enabling
/// zero-copy in-place slice passing without copying bytes.
pub fn isDirectSliceCompatible(comptime Elem: type, comptime is_memory64: bool) bool {
    const wl = comptime wireLayoutOf(Elem, is_memory64);
    if (Elem == u8 or Elem == i8) return true;
    const is_le = builtin.cpu.arch.endian() == .little;
    return is_le and wl.is_blittable and !wl.has_indirect_slices and
        (@sizeOf(Elem) == wl.size) and (@alignOf(Elem) == wl.alignment);
}

/// Returns true when `[]const Elem` can be lifted as a zero-copy slice view
/// pointing directly into `mem_ctx.memory`.
pub fn isZeroCopySliceElem(comptime Elem: type, comptime is_memory64: bool) bool {
    return isDirectSliceCompatible(Elem, is_memory64);
}

pub fn FrameLayout(comptime FnType: type) type {
    const f = @typeInfo(FnType).@"fn";
    return struct {
        header_bump_offset: usize,
        header_limit_offset: usize,
        header_size: usize,
        has_return: bool,
        ret_offset: usize,
        param_offsets: [f.param_types.len]usize,
        frame_size: usize,
        frame_align: usize,
        has_indirect_slices: bool,
        is_blittable_only: bool,
        flags: u32,
    };
}

/// Compute the contiguous `ArgStruct` frame layout for `FnType`.
/// Reserves `2 * @sizeOf(PtrInt)` at the start of the frame header for
/// `(bump_cursor, scratch_limit)` so callee thunks (including standalone Wasm
/// exports) append return slices after caller argument slices without collision.
pub fn ArgStructLayout(comptime FnType: type, comptime is_memory64: bool) FrameLayout(FnType) {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        const f = @typeInfo(FnType).@"fn";
        const RetT = f.return_type orelse void;
        const ptr_size: u32 = @sizeOf(PtrInt(is_memory64));

        var offset: u32 = 2 * ptr_size;
        var max_align: u32 = ptr_size;
        var has_indirect_slices = false;
        var is_blittable_only = true;
        var ret_offset: usize = 2 * ptr_size;

        const has_return = (RetT != void);
        if (has_return) {
            const rl = wireLayoutOf(RetT, is_memory64);
            offset = canon.alignForward(offset, rl.alignment);
            ret_offset = offset;
            offset += rl.size;
            max_align = @max(max_align, rl.alignment);
            has_indirect_slices = has_indirect_slices or rl.has_indirect_slices;
            is_blittable_only = is_blittable_only and rl.is_blittable;
        }

        var param_offsets: [f.param_types.len]usize = undefined;
        for (f.param_types, 0..) |maybe_pt, i| {
            const PT = maybe_pt.?;
            const pl = wireLayoutOf(PT, is_memory64);
            offset = canon.alignForward(offset, pl.alignment);
            param_offsets[i] = offset;
            offset += pl.size;
            max_align = @max(max_align, pl.alignment);
            has_indirect_slices = has_indirect_slices or pl.has_indirect_slices;
            is_blittable_only = is_blittable_only and pl.is_blittable;
        }

        const frame_size = canon.alignForward(offset, max_align);
        var flags: u32 = 0;
        if (has_indirect_slices) flags |= FLAG_HAS_INDIRECT_SLICES;
        if (is_blittable_only) flags |= FLAG_IS_BLITTABLE_ONLY;

        break :blk .{
            .header_bump_offset = 0,
            .header_limit_offset = ptr_size,
            .header_size = 2 * ptr_size,
            .has_return = has_return,
            .ret_offset = ret_offset,
            .param_offsets = param_offsets,
            .frame_size = frame_size,
            .frame_align = max_align,
            .has_indirect_slices = has_indirect_slices,
            .is_blittable_only = is_blittable_only,
            .flags = flags,
        };
    };
}

// ── Direct Linear-Memory `ArgStruct` Store & Load (Zero `cabi_realloc`) ────

fn sliceInMemory(ctx: canon.MemoryContext, ptr: anytype, byte_len: usize) ?usize {
    if (ctx.memory.len == 0) return null;
    const mem_start = @intFromPtr(ctx.memory.ptr);
    const mem_end = mem_start + ctx.memory.len;
    const p = @intFromPtr(ptr);
    if (p >= mem_start and p <= mem_end and byte_len <= mem_end - p) {
        return p - mem_start;
    }
    return null;
}

fn alignSizeForward(offset: usize, alignment: usize) usize {
    std.debug.assert(alignment >= 1 and std.math.isPowerOfTwo(alignment));
    return (offset + (alignment - 1)) & ~(alignment - 1);
}

fn allocScratchOffset(
    mem_len: usize,
    bump_off: *usize,
    alignment: usize,
    byte_len: usize,
) canon.Error!usize {
    const aligned = alignSizeForward(bump_off.*, alignment);
    if (aligned > mem_len or mem_len - aligned < byte_len) {
        return error.OutOfBounds;
    }
    bump_off.* = aligned + byte_len;
    return aligned;
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

fn needsFlagsWordMasking(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "wit_flags_count") and @hasField(T, "words") and (T.wit_flags_count % 32 != 0);
}

fn errorToIndex(comptime ES: type, err: ES) u32 {
    const es = @typeInfo(ES).error_set;
    const names = es.error_names orelse @compileError("anyerror is not supported in fast_abi");
    inline for (names, 0..) |name, idx| {
        if (err == @field(ES, name)) return @intCast(idx);
    }
    unreachable;
}

/// Store a Zig value `val` of type `T` into `mem_ctx.memory` at linear-memory
/// address `addr`, writing any out-of-band variable-length slice data into the
/// scratch bump region tracked by `bump_off` (or referencing the slice in-place
/// with zero copy if it already resides inside `mem_ctx.memory`).
/// Never invokes `cabi_realloc`.
pub fn storeFastValue(
    comptime T: type,
    comptime is_memory64: bool,
    mem_ctx: *canon.MemoryContext,
    addr: usize,
    val: T,
    bump_off: *usize,
) canon.Error!void {
    const arch: canon.Arch = if (is_memory64) .wasm64 else .wasm32;
    const layout = comptime wireLayoutOf(T, is_memory64);
    const off = try mem_ctx.addrToOffset(addr, layout.size);
    if (comptime layout.alignment > 1) {
        if ((layout.size > 0 or addr != 0) and (addr % layout.alignment != 0)) {
            return error.UnalignedPointer;
        }
    }

    if (comptime layout.is_blittable and !layout.has_indirect_slices and @sizeOf(T) == layout.size and !needsFlagsWordMasking(T)) {
        if (comptime layout.size > 0) {
            @memcpy(mem_ctx.memory[off..][0..layout.size], std.mem.asBytes(&val));
        }
        return;
    }

    if (T == void) return;

    if (comptime canon.isCharType(T)) {
        const cp: u21 = if (@typeInfo(T) == .@"enum") @intFromEnum(val) else val;
        _ = try canon.validateChar(cp);
        std.mem.writeInt(u32, mem_ctx.memory[off..][0..4], @as(u32, cp), .little);
        return;
    }

    switch (@typeInfo(T)) {
        .bool => {
            mem_ctx.memory[off] = if (val) 1 else 0;
        },
        .int => |int| switch (int.bits) {
            8 => mem_ctx.memory[off] = @bitCast(val),
            16 => std.mem.writeInt(T, mem_ctx.memory[off..][0..2], val, .little),
            32 => std.mem.writeInt(T, mem_ctx.memory[off..][0..4], val, .little),
            64 => std.mem.writeInt(T, mem_ctx.memory[off..][0..8], val, .little),
            else => unreachable,
        },
        .float => |fl| switch (fl.bits) {
            32 => std.mem.writeInt(u32, mem_ctx.memory[off..][0..4], @bitCast(val), .little),
            64 => std.mem.writeInt(u64, mem_ctx.memory[off..][0..8], @bitCast(val), .little),
            else => unreachable,
        },
        .@"enum" => {
            const raw: u32 = canon.enumToIndex(T, val);
            switch (layout.size) {
                1 => mem_ctx.memory[off] = @intCast(raw),
                2 => std.mem.writeInt(u16, mem_ctx.memory[off..][0..2], @intCast(raw), .little),
                4 => std.mem.writeInt(u32, mem_ctx.memory[off..][0..4], raw, .little),
                else => unreachable,
            }
        },
        .pointer => |pt| switch (pt.size) {
            .slice => {
                const E = pt.child;
                if (comptime E == u8) {
                    if (mem_ctx.validate_utf8 and mem_ctx.strict_utf8_on_u8_slices and !std.unicode.utf8ValidateSlice(val)) {
                        return error.InvalidUtf8;
                    }
                }
                const elem_layout = comptime wireLayoutOf(E, is_memory64);
                const byte_len = std.math.mul(usize, val.len, elem_layout.size) catch return error.OutOfBounds;
                if (byte_len > 0x7fff_ffff) return error.OutOfBounds;

                const PtrT = PtrInt(is_memory64);
                const ptr_size = @sizeOf(PtrT);

                // In-place zero-copy check: if `val` already lives in `mem_ctx.memory`
                // and `E` has a direct wire representation, reuse its existing offset!
                if (comptime isDirectSliceCompatible(E, is_memory64)) {
                    if (sliceInMemory(mem_ctx.*, val.ptr, byte_len)) |existing_off| {
                        const existing_addr = mem_ctx.base_addr + existing_off;
                        if (elem_layout.alignment == 1 or (existing_addr % elem_layout.alignment == 0)) {
                            if (existing_addr > std.math.maxInt(PtrT) or val.len > std.math.maxInt(PtrT)) {
                                return error.OutOfBounds;
                            }
                            std.mem.writeInt(PtrT, mem_ctx.memory[off..][0..ptr_size], @intCast(existing_addr), .little);
                            std.mem.writeInt(PtrT, mem_ctx.memory[off + ptr_size ..][0..ptr_size], @intCast(val.len), .little);
                            return;
                        }
                    }

                    // External host memory slice of direct-compatible elements:
                    // copy directly into the contiguous scratch bump region (no cabi_realloc!).
                    const effective_limit = mem_ctx.effectiveFastLimit();
                    const extra_sentinel: usize = if (comptime pt.sentinel_ptr != null and E == u8) 1 else 0;
                    const data_off = try allocScratchOffset(
                        effective_limit,
                        bump_off,
                        elem_layout.alignment,
                        byte_len + extra_sentinel,
                    );
                    if (byte_len > 0) {
                        const src_bytes = std.mem.sliceAsBytes(val);
                        @memcpy(mem_ctx.memory[data_off..][0..byte_len], src_bytes);
                    }
                    if (comptime extra_sentinel == 1) {
                        const sentinel_val = @as(*const u8, @ptrCast(@alignCast(pt.sentinel_ptr.?))).*;
                        mem_ctx.memory[data_off + byte_len] = sentinel_val;
                    }
                    const data_addr = mem_ctx.base_addr + data_off;
                    if (data_addr > std.math.maxInt(PtrT) or val.len > std.math.maxInt(PtrT)) {
                        return error.OutOfBounds;
                    }
                    std.mem.writeInt(PtrT, mem_ctx.memory[off..][0..ptr_size], @intCast(data_addr), .little);
                    std.mem.writeInt(PtrT, mem_ctx.memory[off + ptr_size ..][0..ptr_size], @intCast(val.len), .little);
                    return;
                }

                // Non-blittable / nested-slice elements: reserve the contiguous element array
                // in the scratch bump region first, then recursively serialize each element.
                const effective_limit = mem_ctx.effectiveFastLimit();
                const data_off = try allocScratchOffset(
                    effective_limit,
                    bump_off,
                    elem_layout.alignment,
                    byte_len,
                );
                const data_addr = mem_ctx.base_addr + data_off;
                if (data_addr > std.math.maxInt(PtrT) or val.len > std.math.maxInt(PtrT)) {
                    return error.OutOfBounds;
                }
                for (val, 0..) |elem, i| {
                    try storeFastValue(
                        E,
                        is_memory64,
                        mem_ctx,
                        data_addr + i * elem_layout.size,
                        elem,
                        bump_off,
                    );
                }
                std.mem.writeInt(PtrT, mem_ctx.memory[off..][0..ptr_size], @intCast(data_addr), .little);
                std.mem.writeInt(PtrT, mem_ctx.memory[off + ptr_size ..][0..ptr_size], @intCast(val.len), .little);
            },
            else => unreachable,
        },
        .array => |ar| {
            const elem_layout = comptime wireLayoutOf(ar.child, is_memory64);
            for (val, 0..) |elem, i| {
                try storeFastValue(ar.child, is_memory64, mem_ctx, addr + i * elem_layout.size, elem, bump_off);
            }
        },
        .@"struct" => |st| {
            if (comptime canon.isHandleType(T)) {
                std.mem.writeInt(i32, mem_ctx.memory[off..][0..4], val.handle, .little);
                return;
            }
            if (comptime canon.isStringWrapper(T)) {
                if (val.bytes.len > 0x7fff_ffff) return error.OutOfBounds;
                if (mem_ctx.validate_utf8 and !std.unicode.utf8ValidateSlice(val.bytes)) {
                    return error.InvalidUtf8;
                }
                return storeFastValue([]const u8, is_memory64, mem_ctx, addr, val.bytes, bump_off);
            }
            if (comptime st.layout == .@"packed") {
                const BackingInt = st.backing_integer.?;
                const UnsignedInt = @Int(.unsigned, @bitSizeOf(BackingInt));
                const raw: UnsignedInt = (@as(UnsignedInt, @bitCast(val))) & (comptime packedFlagsMask(T));
                switch (layout.size) {
                    0 => {},
                    1 => mem_ctx.memory[off] = @intCast(raw),
                    2 => std.mem.writeInt(u16, mem_ctx.memory[off..][0..2], @intCast(raw), .little),
                    4 => std.mem.writeInt(u32, mem_ctx.memory[off..][0..4], @intCast(raw), .little),
                    8 => std.mem.writeInt(u64, mem_ctx.memory[off..][0..8], @intCast(raw), .little),
                    else => {
                        const word_count = layout.size / 4;
                        inline for (0..word_count) |w| {
                            const shift = w * 32;
                            const word: u32 = if (comptime shift < @bitSizeOf(UnsignedInt))
                                (if (comptime @bitSizeOf(UnsignedInt) <= 32)
                                    @as(u32, raw >> shift)
                                else
                                    @truncate(raw >> shift))
                            else
                                0;
                            std.mem.writeInt(u32, mem_ctx.memory[off + w * 4 ..][0..4], word, .little);
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
                try storeFastValue(@TypeOf(masked.words), is_memory64, mem_ctx, addr, masked.words, bump_off);
                return;
            }
            inline for (st.field_names, 0..) |fname, i| {
                if (comptime st.field_attrs[i].@"comptime") continue;
                const f_off = comptime canon.fieldOffset(T, arch, i);
                try storeFastValue(st.field_types[i], is_memory64, mem_ctx, addr + f_off, @field(val, fname), bump_off);
            }
        },
        .optional => |op| {
            const pay_off = comptime canon.optionPayloadOffset(T, arch);
            if (val) |payload| {
                mem_ctx.memory[off] = 1;
                try storeFastValue(op.child, is_memory64, mem_ctx, addr + pay_off, payload, bump_off);
            } else {
                @memset(mem_ctx.memory[off..][0..layout.size], 0);
            }
        },
        .@"union" => |un| {
            const disc_size = comptime canon.variantDiscSize(un.field_names.len);
            const pay_off = comptime canon.variantPayloadOffset(T, arch);
            @memset(mem_ctx.memory[off..][0..layout.size], 0);
            const active_tag = std.meta.activeTag(val);
            inline for (un.field_names, 0..) |fname, case_idx| {
                const tag_val = @field(un.tag_type.?, fname);
                if (active_tag == tag_val) {
                    switch (disc_size) {
                        1 => mem_ctx.memory[off] = @intCast(case_idx),
                        2 => std.mem.writeInt(u16, mem_ctx.memory[off..][0..2], @intCast(case_idx), .little),
                        4 => std.mem.writeInt(u32, mem_ctx.memory[off..][0..4], @intCast(case_idx), .little),
                        else => unreachable,
                    }
                    try storeFastValue(un.field_types[case_idx], is_memory64, mem_ctx, addr + pay_off, @field(val, fname), bump_off);
                    return;
                }
            }
        },
        .error_set => {
            const raw = errorToIndex(T, val);
            switch (layout.size) {
                1 => mem_ctx.memory[off] = @intCast(raw),
                2 => std.mem.writeInt(u16, mem_ctx.memory[off..][0..2], @intCast(raw), .little),
                4 => std.mem.writeInt(u32, mem_ctx.memory[off..][0..4], raw, .little),
                else => unreachable,
            }
        },
        .error_union => |eu| {
            const pay_off = comptime canon.variantPayloadOffset(T, arch);
            @memset(mem_ctx.memory[off..][0..layout.size], 0);
            if (val) |ok_val| {
                mem_ctx.memory[off] = 0;
                try storeFastValue(eu.payload, is_memory64, mem_ctx, addr + pay_off, ok_val, bump_off);
            } else |err_val| {
                mem_ctx.memory[off] = 1;
                try storeFastValue(eu.error_set, is_memory64, mem_ctx, addr + pay_off, err_val, bump_off);
            }
        },
        else => unreachable,
    }
}

/// Load a Zig value of type `T` from `mem_ctx.memory` at linear-memory address
/// `addr`. Strings and blittable slices (`[]const u8`, `[]const Elem`) are
/// returned as zero-copy views directly into `mem_ctx.memory` without allocation.
pub fn loadFastValue(
    comptime T: type,
    comptime is_memory64: bool,
    mem_ctx: *const canon.MemoryContext,
    addr: usize,
) canon.CanonResult(T) {
    const arch: canon.Arch = if (is_memory64) .wasm64 else .wasm32;
    return canon.loadFromMemory(T, arch, mem_ctx.*, addr);
}

/// Store all function parameters of `FnType` into the `ArgStruct` frame at
/// `frame_offset` in `mem_ctx.memory`, and record the resulting `bump_cursor`
/// in the frame header.
pub fn storeFastFrame(
    comptime FnType: type,
    comptime is_memory64: bool,
    mem_ctx: *canon.MemoryContext,
    frame_offset: usize,
    args: std.meta.ArgsTuple(FnType),
    bump_off: *usize,
) canon.Error!void {
    const fl = comptime ArgStructLayout(FnType, is_memory64);
    const f = @typeInfo(FnType).@"fn";
    const PtrT = PtrInt(is_memory64);
    const ptr_size = @sizeOf(PtrT);
    const effective_limit = mem_ctx.effectiveFastLimit();
    if (frame_offset > effective_limit or effective_limit - frame_offset < fl.frame_size) {
        return error.OutOfBounds;
    }
    const frame_addr = mem_ctx.base_addr + frame_offset;
    if (fl.frame_align > 1 and (frame_addr % fl.frame_align != 0)) {
        return error.UnalignedPointer;
    }
    @memset(mem_ctx.memory[frame_offset..][0..fl.header_size], 0);
    if (fl.has_return and fl.frame_size > 0) {
        const RetT = f.return_type orelse void;
        const rl = comptime wireLayoutOf(RetT, is_memory64);
        @memset(mem_ctx.memory[frame_offset + fl.ret_offset ..][0..rl.size], 0);
    }
    inline for (0..f.param_types.len) |i| {
        const PT = f.param_types[i].?;
        try storeFastValue(
            PT,
            is_memory64,
            mem_ctx,
            frame_addr + fl.param_offsets[i],
            args[i],
            bump_off,
        );
    }
    if (bump_off.* > effective_limit) return error.OutOfBounds;
    const bump_addr = mem_ctx.base_addr + bump_off.*;
    const limit_addr = mem_ctx.base_addr + effective_limit;
    if (bump_addr > std.math.maxInt(PtrT)) return error.OutOfBounds;
    std.mem.writeInt(PtrT, mem_ctx.memory[frame_offset + fl.header_bump_offset ..][0..ptr_size], @intCast(bump_addr), .little);
    const encoded_limit: PtrT = if (limit_addr <= std.math.maxInt(PtrT)) @intCast(limit_addr) else 0;
    std.mem.writeInt(PtrT, mem_ctx.memory[frame_offset + fl.header_limit_offset ..][0..ptr_size], encoded_limit, .little);
}

/// Load all function parameters of `FnType` from the `ArgStruct` frame at
/// `frame_offset` in `mem_ctx.memory`.
pub fn loadFastFrame(
    comptime FnType: type,
    comptime is_memory64: bool,
    mem_ctx: *const canon.MemoryContext,
    frame_offset: usize,
) canon.Error!std.meta.ArgsTuple(FnType) {
    const fl = comptime ArgStructLayout(FnType, is_memory64);
    const f = @typeInfo(FnType).@"fn";
    const ArgsTuple = std.meta.ArgsTuple(FnType);

    if (frame_offset > mem_ctx.memory.len or mem_ctx.memory.len - frame_offset < fl.frame_size) {
        return error.OutOfBounds;
    }
    const frame_addr = mem_ctx.base_addr + frame_offset;
    if (fl.frame_align > 1 and (frame_addr % fl.frame_align != 0)) {
        return error.UnalignedPointer;
    }

    var out: ArgsTuple = undefined;
    inline for (0..f.param_types.len) |i| {
        const PT = f.param_types[i].?;
        out[i] = try loadFastValue(PT, is_memory64, mem_ctx, frame_addr + fl.param_offsets[i]);
    }
    return out;
}

/// Compute the maximum end offset in `mem_ctx.memory` of any in-place slice
/// contained in `val` that starts at or before `horizon_end`. Used so automatic
/// frame placement in `FastLower.call` never overwrites an in-place input slice
/// placed by the caller at the beginning of `mem_ctx.memory`.
fn maxInPlaceSliceEnd(
    comptime T: type,
    comptime is_memory64: bool,
    ctx: canon.MemoryContext,
    val: T,
) usize {
    if (comptime canon.isStringWrapper(T)) {
        return maxInPlaceSliceEnd([]const u8, is_memory64, ctx, val.bytes);
    }
    return switch (@typeInfo(T)) {
        .pointer => |pt| if (comptime pt.size == .slice) blk: {
            const elem_size = comptime wireLayoutOf(pt.child, is_memory64).size;
            const byte_len = val.len * elem_size;
            var max_end: usize = 0;
            if (sliceInMemory(ctx, val.ptr, byte_len)) |off| {
                max_end = off + byte_len;
            }
            if (comptime !isDirectSliceCompatible(pt.child, is_memory64)) {
                for (val) |elem| {
                    max_end = @max(max_end, maxInPlaceSliceEnd(pt.child, is_memory64, ctx, elem));
                }
            }
            break :blk max_end;
        } else 0,
        .array => |ar| blk: {
            var max_end: usize = 0;
            for (val) |elem| {
                max_end = @max(max_end, maxInPlaceSliceEnd(ar.child, is_memory64, ctx, elem));
            }
            break :blk max_end;
        },
        .@"struct" => |st| blk: {
            if (comptime st.layout == .@"packed" or canon.isHandleType(T)) break :blk 0;
            var max_end: usize = 0;
            inline for (st.field_names, 0..) |fname, i| {
                if (comptime st.field_attrs[i].@"comptime") continue;
                max_end = @max(max_end, maxInPlaceSliceEnd(st.field_types[i], is_memory64, ctx, @field(val, fname)));
            }
            break :blk max_end;
        },
        .optional => |op| if (val) |payload| maxInPlaceSliceEnd(op.child, is_memory64, ctx, payload) else 0,
        .@"union" => |un| blk: {
            if (comptime un.tag_type == null) break :blk 0;
            const active = std.meta.activeTag(val);
            inline for (un.field_names, 0..) |fname, i| {
                if (active == @field(un.tag_type.?, fname)) {
                    break :blk maxInPlaceSliceEnd(un.field_types[i], is_memory64, ctx, @field(val, fname));
                }
            }
            break :blk 0;
        },
        .error_union => |eu| if (val) |ok_val| maxInPlaceSliceEnd(eu.payload, is_memory64, ctx, ok_val) else |_| 0,
        else => 0,
    };
}

// ── Fast-Path Call & Lift Wrappers (`FastLower` & `FastLift`) ──────────────

pub fn FastCoreFnPtr(comptime is_memory64: bool) type {
    return *const fn (PtrInt(is_memory64)) callconv(.c) void;
}

pub const DEFAULT_FAST_SCRATCH_LEN: usize = 65536;
pub var default_fast_scratch: [DEFAULT_FAST_SCRATCH_LEN]u8 align(16) = undefined;

pub fn fastScratchPtr() callconv(.c) usize {
    return @intFromPtr(&default_fast_scratch);
}

pub fn fastScratchLen() callconv(.c) usize {
    return default_fast_scratch.len;
}

/// Stack-buffer-first allocator backed by `std.heap.BufferFirstAllocator`.
/// Allocates up to `size` bytes from an inline stack buffer and falls back to
/// `fallback_allocator` (e.g. `std.heap.wasm_allocator` on Wasm or
/// `std.heap.page_allocator` on non-Wasm) when exceeded.
pub fn StackFallbackAllocator(comptime size: usize) type {
    return struct {
        buffer: [size]u8 align(16) = undefined,
        bfa: std.heap.BufferFirstAllocator = undefined,

        pub fn get(self: *@This(), fallback_allocator: Allocator) Allocator {
            self.bfa = std.heap.BufferFirstAllocator.init(&self.buffer, fallback_allocator);
            return self.bfa.allocator();
        }
    };
}

threadlocal var active_fast_memory_ctx: ?*canon.MemoryContext = null;

pub fn setActiveFastMemoryContext(ctx: ?*canon.MemoryContext) void {
    active_fast_memory_ctx = ctx;
}

pub fn getActiveFastMemoryContext() ?*canon.MemoryContext {
    return active_fast_memory_ctx;
}

/// Comptime caller-side fast-path lowering wrapper (`FastLower`).
/// Serializes parameters into a single contiguous `ArgStruct` frame in
/// `mem_ctx.memory`, invokes `fast_fn(frame_addr)`, and lifts the return value
/// with 0 `cabi_realloc` calls and 0 `cabi_post` calls.
pub fn FastLower(comptime FnType: type, comptime is_memory64: bool) type {
    return struct {
        pub const abi_hash: u64 = comptimeAbiHash(FnType, is_memory64);
        pub const frame_layout = ArgStructLayout(FnType, is_memory64);
        pub const ArgsTuple = std.meta.ArgsTuple(FnType);
        pub const ReturnType = canon.ReturnType(FnType);
        pub const PtrT = PtrInt(is_memory64);

        pub const CallOrFallbackResult = union(enum) {
            completed: canon.CanonResult(ReturnType),
            fallback_needed: canon.Error,
        };

        pub fn resolveFrameOffset(
            mem_ctx: *const canon.MemoryContext,
            args: ArgsTuple,
        ) canon.Error!usize {
            const effective_limit = mem_ctx.effectiveFastLimit();
            var base_off = alignSizeForward(mem_ctx.fast_frame_offset, frame_layout.frame_align);
            if (comptime frame_layout.has_indirect_slices) {
                const in_place_end = maxInPlaceSliceEnd(ArgsTuple, is_memory64, mem_ctx.*, args);
                if (in_place_end > base_off) {
                    const after_in_place = alignSizeForward(in_place_end, frame_layout.frame_align);
                    if (after_in_place > effective_limit or effective_limit - after_in_place < frame_layout.frame_size) {
                        return error.OutOfBounds;
                    }
                    base_off = after_in_place;
                }
            }
            if (base_off > effective_limit or effective_limit - base_off < frame_layout.frame_size) {
                return error.OutOfBounds;
            }
            return base_off;
        }

        pub inline fn call(
            mem_ctx: *canon.MemoryContext,
            fast_fn: FastCoreFnPtr(is_memory64),
            args: ArgsTuple,
        ) canon.CanonResult(ReturnType) {
            const base_off = try resolveFrameOffset(mem_ctx, args);
            return callAtOffset(mem_ctx, base_off, fast_fn, args);
        }

        /// Invoke `FastLower.call` on an isolated `TaskContext` shadow stack.
        pub inline fn callOnShadowStack(
            mem_ctx: *canon.MemoryContext,
            task_ctx: anytype,
            fast_fn: FastCoreFnPtr(is_memory64),
            args: ArgsTuple,
        ) canon.CanonResult(ReturnType) {
            const Runner = struct {
                fn invoke(m: *canon.MemoryContext, f: FastCoreFnPtr(is_memory64), a: *const ArgsTuple) canon.CanonResult(ReturnType) {
                    return call(m, f, a.*);
                }
            };
            return task_ctx.run(Runner.invoke, .{ mem_ctx, fast_fn, &args });
        }

        pub inline fn callAtOffset(
            mem_ctx: *canon.MemoryContext,
            frame_offset: usize,
            fast_fn: FastCoreFnPtr(is_memory64),
            args: ArgsTuple,
        ) canon.CanonResult(ReturnType) {
            const effective_limit = mem_ctx.effectiveFastLimit();
            const aligned_frame_off = alignSizeForward(frame_offset, frame_layout.frame_align);
            var bump_off: usize = aligned_frame_off + frame_layout.frame_size;

            try storeFastFrame(FnType, is_memory64, mem_ctx, aligned_frame_off, args, &bump_off);
            mem_ctx.fast_bump_cursor = bump_off;

            const frame_addr = mem_ctx.base_addr + aligned_frame_off;
            if (frame_addr > std.math.maxInt(PtrT)) return error.OutOfBounds;

            const prev_fast = active_fast_memory_ctx;
            setActiveFastMemoryContext(mem_ctx);
            defer setActiveFastMemoryContext(prev_fast);

            fast_fn(@intCast(frame_addr));

            const updated_bump_addr: usize = @intCast(std.mem.readInt(
                PtrT,
                mem_ctx.memory[aligned_frame_off + frame_layout.header_bump_offset ..][0..@sizeOf(PtrT)],
                .little,
            ));
            if (updated_bump_addr >= mem_ctx.base_addr) {
                const updated_off = updated_bump_addr - mem_ctx.base_addr;
                if (updated_off <= effective_limit) {
                    mem_ctx.fast_bump_cursor = @max(bump_off, updated_off);
                }
            }

            if (comptime ReturnType == void) {
                return;
            } else {
                const ret_addr = frame_addr + frame_layout.ret_offset;
                return loadFastValue(ReturnType, is_memory64, mem_ctx, ret_addr);
            }
        }

        /// Attempt the store phase of `FastLower.call`. If a store-phase layout
        /// or capacity error (`OutOfBounds`, `UnalignedPointer`, `MissingAllocator`,
        /// `OutOfMemory`, etc.) occurs BEFORE `fast_fn` is invoked, restores
        /// `mem_ctx.fast_bump_cursor` and returns `.fallback_needed` so
        /// `CanonLower.callAuto` can cleanly fall back to the Canonical ABI.
        pub inline fn tryCallOrFallback(
            mem_ctx: *canon.MemoryContext,
            fast_fn: FastCoreFnPtr(is_memory64),
            args: ArgsTuple,
        ) CallOrFallbackResult {
            const effective_limit = mem_ctx.effectiveFastLimit();
            const saved_bump = mem_ctx.fast_bump_cursor;
            const base_off = resolveFrameOffset(mem_ctx, args) catch |err| {
                mem_ctx.fast_bump_cursor = saved_bump;
                return .{ .fallback_needed = err };
            };
            const aligned_frame_off = alignSizeForward(base_off, frame_layout.frame_align);
            var bump_off: usize = aligned_frame_off + frame_layout.frame_size;

            storeFastFrame(FnType, is_memory64, mem_ctx, aligned_frame_off, args, &bump_off) catch |err| switch (err) {
                error.InvalidUtf8, error.InvalidChar => {
                    mem_ctx.fast_bump_cursor = saved_bump;
                    return .{ .completed = err };
                },
                else => {
                    mem_ctx.fast_bump_cursor = saved_bump;
                    return .{ .fallback_needed = err };
                },
            };

            const frame_addr = mem_ctx.base_addr + aligned_frame_off;
            if (frame_addr > std.math.maxInt(PtrT)) {
                mem_ctx.fast_bump_cursor = saved_bump;
                return .{ .fallback_needed = error.OutOfBounds };
            }
            mem_ctx.fast_bump_cursor = bump_off;

            const prev_fast = active_fast_memory_ctx;
            setActiveFastMemoryContext(mem_ctx);
            defer setActiveFastMemoryContext(prev_fast);

            fast_fn(@intCast(frame_addr));

            const updated_bump_addr: usize = @intCast(std.mem.readInt(
                PtrT,
                mem_ctx.memory[aligned_frame_off + frame_layout.header_bump_offset ..][0..@sizeOf(PtrT)],
                .little,
            ));
            if (updated_bump_addr >= mem_ctx.base_addr) {
                const updated_off = updated_bump_addr - mem_ctx.base_addr;
                if (updated_off <= effective_limit) {
                    mem_ctx.fast_bump_cursor = @max(bump_off, updated_off);
                }
            }

            if (comptime ReturnType == void) {
                return .{ .completed = {} };
            } else {
                const ret_addr = frame_addr + frame_layout.ret_offset;
                return .{ .completed = loadFastValue(ReturnType, is_memory64, mem_ctx, ret_addr) };
            }
        }
    };
}

/// Comptime callee-side fast-path lifting wrapper (`FastLift`).
/// Lifts arguments directly from `frame_addr` in `mem_ctx.memory` (with
/// zero-copy slices for strings and blittable arrays), invokes `impl_fn`,
/// and stores the return value into the `retval` slot of `frame_addr`.
pub fn FastLift(comptime FnType: type, comptime impl_fn: FnType, comptime is_memory64: bool) type {
    return struct {
        pub const abi_hash: u64 = comptimeAbiHash(FnType, is_memory64);
        pub const frame_layout = ArgStructLayout(FnType, is_memory64);
        pub const ArgsTuple = std.meta.ArgsTuple(FnType);
        pub const ReturnType = canon.ReturnType(FnType);
        pub const PtrT = PtrInt(is_memory64);

        pub fn callFromMemory(
            mem_ctx: *canon.MemoryContext,
            frame_addr: PtrT,
        ) canon.Error!void {
            const addr_usize: usize = std.math.cast(usize, frame_addr) orelse return error.OutOfBounds;
            if (frame_layout.frame_align > 1 and (addr_usize % frame_layout.frame_align != 0)) {
                return error.UnalignedPointer;
            }
            const frame_offset = try mem_ctx.addrToOffset(addr_usize, frame_layout.frame_size);

            const ptr_size = @sizeOf(PtrT);
            const raw_bump_addr: usize = @intCast(std.mem.readInt(
                PtrT,
                mem_ctx.memory[frame_offset + frame_layout.header_bump_offset ..][0..ptr_size],
                .little,
            ));
            const raw_limit_addr: usize = @intCast(std.mem.readInt(
                PtrT,
                mem_ctx.memory[frame_offset + frame_layout.header_limit_offset ..][0..ptr_size],
                .little,
            ));
            var header_bump_off: usize = 0;
            if (raw_bump_addr != 0) {
                if (raw_bump_addr < mem_ctx.base_addr) return error.OutOfBounds;
                header_bump_off = raw_bump_addr - mem_ctx.base_addr;
                if (header_bump_off > mem_ctx.memory.len) return error.OutOfBounds;
            }

            // Use a 4 KB stack buffer backed by `wasm_allocator` on Wasm (or
            // `page_allocator` on non-Wasm) when `mem_ctx.allocator == null`,
            // so large nested slices never fail with `OutOfMemory` at 4 KB.
            const default_fallback = if (comptime builtin.cpu.arch.isWasm())
                std.heap.wasm_allocator
            else
                std.heap.page_allocator;
            var sfa = StackFallbackAllocator(4096){};
            const backing_alloc = mem_ctx.allocator orelse sfa.get(default_fallback);
            var lift_arena = std.heap.ArenaAllocator.init(backing_alloc);
            defer lift_arena.deinit();

            var lift_ctx = mem_ctx.*;
            lift_ctx.allocator = lift_arena.allocator();

            const prev_canon_ctx = canon.getActiveMemoryContext();
            canon.setActiveMemoryContext(mem_ctx.*);
            defer canon.setActiveMemoryContext(prev_canon_ctx);

            const args = try loadFastFrame(FnType, is_memory64, &lift_ctx, frame_offset);
            const ret_val: ReturnType = @call(.auto, impl_fn, args);

            if (comptime ReturnType != void) {
                const min_bump = frame_offset + frame_layout.frame_size;
                var bump_off: usize = if (raw_bump_addr != 0)
                    @max(header_bump_off, min_bump)
                else
                    @max(mem_ctx.fast_bump_cursor, min_bump);

                var store_ctx = mem_ctx.*;
                if (raw_limit_addr != 0) {
                    if (raw_limit_addr < mem_ctx.base_addr) return error.OutOfBounds;
                    const limit_off = raw_limit_addr - mem_ctx.base_addr;
                    if (limit_off > mem_ctx.memory.len or limit_off < min_bump) return error.OutOfBounds;
                    store_ctx.fast_scratch_limit = limit_off;
                    store_ctx.memory = mem_ctx.memory[0..limit_off];
                }

                const ret_addr = addr_usize + frame_layout.ret_offset;
                try storeFastValue(ReturnType, is_memory64, &store_ctx, ret_addr, ret_val, &bump_off);
                mem_ctx.fast_bump_cursor = bump_off;
                const new_bump_addr = mem_ctx.base_addr + bump_off;
                if (new_bump_addr > std.math.maxInt(PtrT)) return error.OutOfBounds;
                std.mem.writeInt(
                    PtrT,
                    mem_ctx.memory[frame_offset + frame_layout.header_bump_offset ..][0..ptr_size],
                    @intCast(new_bump_addr),
                    .little,
                );
            }
        }

        /// Invoke `FastLift.callFromMemory` on an isolated `TaskContext` shadow stack.
        pub fn callFromMemoryOnShadowStack(
            mem_ctx: *canon.MemoryContext,
            task_ctx: anytype,
            frame_addr: PtrT,
        ) canon.Error!void {
            return task_ctx.run(callFromMemory, .{ mem_ctx, frame_addr });
        }

        pub const callOnShadowStack = callFromMemoryOnShadowStack;

        pub fn createThunk(comptime mem_ctx_ptr: *canon.MemoryContext) FastCoreFnPtr(is_memory64) {
            const Thunk = struct {
                pub fn call(frame_addr: PtrT) callconv(.c) void {
                    callFromMemory(mem_ctx_ptr, frame_addr) catch @trap();
                }
            };
            return &Thunk.call;
        }

        pub fn thunk() FastCoreFnPtr(is_memory64) {
            const ActiveThunk = struct {
                pub fn call(frame_addr: PtrT) callconv(.c) void {
                    if (active_fast_memory_ctx) |ctx_ptr| {
                        callFromMemory(ctx_ptr, frame_addr) catch @trap();
                        return;
                    }
                    if (comptime builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64) {
                        const wasm_bytes = @as(usize, @wasmMemorySize(0)) * 65536;
                        if (wasm_bytes <= 1) @trap();
                        const mem_slice = @as([*]u8, @ptrFromInt(1))[0 .. wasm_bytes - 1];
                        var wasm_ctx = canon.MemoryContext{
                            .memory = mem_slice,
                            .base_addr = 1,
                        };
                        callFromMemory(&wasm_ctx, frame_addr) catch @trap();
                        return;
                    }
                    @trap();
                }
            };
            return &ActiveThunk.call;
        }
    };
}

// ── Unit Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "zigar:abi section encode/decode round-trip, corrupt payload rejection, and target compatibility" {
    const alloc = testing.allocator;

    const entries = [_]ZigarFuncEntry{
        .{
            .interface_name = "",
            .func_name = "compute-stats",
            .fast_export_name = "__zigar_fast_compute_stats",
            .abi_hash = 0x1122_3344_5566_7788,
            .arg_struct_size = 24,
            .arg_struct_align = 8,
            .flags = FLAG_IS_BLITTABLE_ONLY,
        },
        .{
            .interface_name = "zigar:sample/guest-service@0.1.0",
            .func_name = "inspect-record",
            .fast_export_name = "__zigar_fast_zigar:sample/guest-service@0.1.0#inspect_record",
            .abi_hash = 0xAABB_CCDD_EEFF_0011,
            .arg_struct_size = 64,
            .arg_struct_align = 8,
            .flags = FLAG_HAS_INDIRECT_SLICES,
        },
    };

    const meta = ZigarAbiMetadata{
        .version = FORMAT_VERSION,
        .flags = .{ .is_memory64 = false, .is_big_endian = false, .zero_copy_slices = true },
        .world_hash = fnv1a64("zigar:sample/sample-world@0.1.0"),
        .entries = &entries,
    };

    const encoded = try encodeZigarAbiSection(alloc, meta);
    defer alloc.free(encoded);

    const decoded = try decodeZigarAbiSection(alloc, encoded);
    defer decoded.deinit(alloc);

    try testing.expectEqual(FORMAT_VERSION, decoded.version);
    try testing.expectEqual(meta.flags, decoded.flags);
    try testing.expectEqual(meta.world_hash, decoded.world_hash);
    try testing.expectEqual(@as(usize, 2), decoded.entries.len);

    try testing.expectEqualStrings("", decoded.entries[0].interface_name);
    try testing.expectEqualStrings("compute-stats", decoded.entries[0].func_name);
    try testing.expectEqualStrings("__zigar_fast_compute_stats", decoded.entries[0].fast_export_name);
    try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), decoded.entries[0].abi_hash);
    try testing.expectEqual(@as(u32, 24), decoded.entries[0].arg_struct_size);
    try testing.expectEqual(@as(u32, 8), decoded.entries[0].arg_struct_align);
    try testing.expect(decoded.entries[0].isBlittableOnly());
    try testing.expect(!decoded.entries[0].hasIndirectSlices());

    try testing.expectEqualStrings("zigar:sample/guest-service@0.1.0", decoded.entries[1].interface_name);
    try testing.expect(decoded.entries[1].hasIndirectSlices());

    // Target compatibility & function lookup
    try testing.expect(decoded.isTargetCompatible(false));
    try testing.expect(!decoded.isTargetCompatible(true));
    try testing.expect(decoded.findCompatibleFunc("", "compute-stats", 0x1122_3344_5566_7788, false) != null);
    try testing.expect(decoded.findCompatibleFunc("$root", "compute-stats", 0x1122_3344_5566_7788, false) != null);
    // Mismatched hash, name, or arch returns null
    try testing.expect(decoded.findCompatibleFunc("", "compute-stats", 0xDEAD, false) == null);
    try testing.expect(decoded.findCompatibleFunc("", "unknown-fn", 0x1122_3344_5566_7788, false) == null);
    try testing.expect(decoded.findCompatibleFunc("", "compute-stats", 0x1122_3344_5566_7788, true) == null);

    // Corrupt payload tests
    try testing.expectError(error.UnexpectedEndOfInput, decodeZigarAbiSection(alloc, encoded[0..10]));
    var bad_magic = try alloc.dupe(u8, encoded);
    defer alloc.free(bad_magic);
    bad_magic[0] = 'X';
    try testing.expectError(error.InvalidMagic, decodeZigarAbiSection(alloc, bad_magic));

    var bad_ver = try alloc.dupe(u8, encoded);
    defer alloc.free(bad_ver);
    std.mem.writeInt(u16, bad_ver[4..6], 99, .little);
    try testing.expectError(error.UnsupportedVersion, decodeZigarAbiSection(alloc, bad_ver));

    var bad_flags = try alloc.dupe(u8, encoded);
    defer alloc.free(bad_flags);
    std.mem.writeInt(u16, bad_flags[6..8], 0x8000, .little);
    try testing.expectError(error.InvalidFlags, decodeZigarAbiSection(alloc, bad_flags));

    // Truncated mid-entry (verifies errdefer frees partially decoded entries without leak!)
    try testing.expectError(error.UnexpectedEndOfInput, decodeZigarAbiSection(alloc, encoded[0 .. encoded.len - 5]));
}

test "embedZigarAbiSection idempotence, detectZigarAbiInCoreModule, detectZigarAbiInComponent, and detectZigarAbi" {
    const alloc = testing.allocator;

    const minimal_core = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
    };

    // Core module without "zigar:abi" returns null
    try testing.expect((try detectZigarAbi(alloc, &minimal_core)) == null);

    const entry1 = [_]ZigarFuncEntry{.{
        .interface_name = "math",
        .func_name = "add",
        .fast_export_name = "__zigar_fast_math#add",
        .abi_hash = 0x1234,
        .arg_struct_size = 12,
        .arg_struct_align = 4,
        .flags = FLAG_IS_BLITTABLE_ONLY,
    }};
    const meta1 = ZigarAbiMetadata{ .world_hash = 111, .entries = &entry1 };

    const core_v1 = try embedZigarAbiSection(alloc, &minimal_core, meta1);
    defer alloc.free(core_v1);

    // Re-embed with updated metadata to verify idempotence (replaces existing "zigar:abi" section)
    const entry2 = [_]ZigarFuncEntry{.{
        .interface_name = "math",
        .func_name = "mul",
        .fast_export_name = "__zigar_fast_math#mul",
        .abi_hash = 0x5678,
        .arg_struct_size = 16,
        .arg_struct_align = 8,
        .flags = FLAG_IS_BLITTABLE_ONLY,
    }};
    const meta2 = ZigarAbiMetadata{ .world_hash = 222, .entries = &entry2 };
    const core_v2 = try embedZigarAbiSection(alloc, core_v1, meta2);
    defer alloc.free(core_v2);

    const detected_core = (try detectZigarAbi(alloc, core_v2)).?;
    defer detected_core.deinit(alloc);
    try testing.expectEqual(@as(u64, 222), detected_core.world_hash);
    try testing.expectEqual(@as(usize, 1), detected_core.entries.len);
    try testing.expectEqualStrings("mul", detected_core.entries[0].func_name);

    // 1. Component with nested `core_module` section (id == 1) containing `core_v2`
    var comp_with_core = std.ArrayList(u8).empty;
    defer comp_with_core.deinit(alloc);
    try comp_with_core.appendSlice(alloc, COMPONENT_PREAMBLE);
    try comp_with_core.append(alloc, 1); // SECTION_CORE_MODULE
    // LEB128 length of core_v2 (fits in 1 byte if < 128)
    try testing.expect(core_v2.len < 128);
    try comp_with_core.append(alloc, @intCast(core_v2.len));
    try comp_with_core.appendSlice(alloc, core_v2);

    const detected_comp_core = (try detectZigarAbi(alloc, comp_with_core.items)).?;
    defer detected_comp_core.deinit(alloc);
    try testing.expectEqual(@as(u64, 222), detected_comp_core.world_hash);
    try testing.expectEqualStrings("__zigar_fast_math#mul", detected_comp_core.entries[0].fast_export_name);

    // 2. Component with top-level custom section (id == 0) named "zigar:abi"
    const raw_payload1 = try encodeZigarAbiSection(alloc, meta1);
    defer alloc.free(raw_payload1);
    const comp_custom = try embed.embedCustomSection(alloc, COMPONENT_PREAMBLE, SECTION_NAME, raw_payload1);
    defer alloc.free(comp_custom);

    const detected_comp_top = (try detectZigarAbiInComponent(alloc, comp_custom)).?;
    defer detected_comp_top.deinit(alloc);
    try testing.expectEqual(@as(u64, 111), detected_comp_top.world_hash);
    try testing.expectEqualStrings("add", detected_comp_top.entries[0].func_name);
}

test "FastLower and FastLift round-trips: scalars, enums, flags, Char, Own/Borrow, variants, options, error unions, Result, and high-arity (>16 params)" {
    var mem: [8192]u8 align(16) = undefined;
    @memset(&mem, 0);

    const ReallocTracker = struct {
        var calls: usize = 0;
        fn realloc(_: ?*anyopaque, _: usize, _: usize, _: usize, _: usize) CanonError!usize {
            calls += 1;
            return error.ReallocFailed;
        }
        const CanonError = canon.Error;
    };
    ReallocTracker.calls = 0;

    var ctx = canon.MemoryContext{
        .memory = &mem,
        .base_addr = if (builtin.cpu.arch.isWasm()) @intFromPtr(&mem) else 0,
        .realloc_fn = ReallocTracker.realloc,
        .allocator = testing.allocator,
    };

    const Color = enum(u8) { red, green, blue };
    const Perms = packed struct(u8) {
        read: bool = false,
        write: bool = false,
        exec: bool = false,
        _pad: u5 = 0,
        pub const wit_flags_count: usize = 3;
    };
    const Shape = union(enum) {
        circle: f64,
        rect: struct { w: u32, h: u32 },
        empty: void,
    };
    const MathErr = error{ DivideByZero, Overflow };
    const ResType = canon.Result(i64, Color);

    // 1. Scalars + Enum + Flags + Char + Own/Borrow + Option + Variant
    const ComplexFn = fn (
        a: i32,
        b: f64,
        col: Color,
        perms: Perms,
        ch: canon.Char,
        own_h: canon.Own(u32),
        bor_h: canon.Borrow(u32),
        opt_v: ?u64,
        shape: Shape,
    ) ResType;

    const ComplexImpl = struct {
        fn run(
            a: i32,
            b: f64,
            col: Color,
            perms: Perms,
            ch: canon.Char,
            own_h: canon.Own(u32),
            bor_h: canon.Borrow(u32),
            opt_v: ?u64,
            shape: Shape,
        ) ResType {
            if (col == .red and !perms.read) return .{ .err = .red };
            const area: i64 = switch (shape) {
                .circle => |r| @intFromFloat(r * b),
                .rect => |rc| @as(i64, rc.w) * @as(i64, rc.h),
                .empty => 0,
            };
            const extra: i64 = @intCast(opt_v orelse 0);
            const ch_val: i64 = @intCast(@intFromEnum(ch));
            return .{
                .ok = @as(i64, a) + area + extra + ch_val + own_h.handle + bor_h.handle,
            };
        }
    };

    const LowerComplex = FastLower(ComplexFn, false);
    const LiftComplex = FastLift(ComplexFn, ComplexImpl.run, false);
    try testing.expectEqual(LowerComplex.abi_hash, LiftComplex.abi_hash);

    const res1 = try LowerComplex.call(&ctx, LiftComplex.thunk(), .{
        10,
        2.5,
        Color.green,
        Perms{ .read = true, .exec = true },
        @as(canon.Char, @enumFromInt('A')),
        canon.Own(u32){ .handle = 7 },
        canon.Borrow(u32){ .handle = 3 },
        @as(?u64, 100),
        Shape{ .rect = .{ .w = 4, .h = 5 } },
    });
    try testing.expect(res1 == .ok);
    try testing.expectEqual(@as(i64, 10 + 20 + 100 + 65 + 7 + 3), res1.ok);
    try testing.expectEqual(@as(usize, 0), ReallocTracker.calls);

    // 2. Zig error union (!T)
    const ErrUnionFn = fn (num: i64, den: i64) MathErr!i64;
    const ErrUnionImpl = struct {
        fn div(num: i64, den: i64) MathErr!i64 {
            if (den == 0) return error.DivideByZero;
            return @divTrunc(num, den);
        }
    };
    const LowerErr = FastLower(ErrUnionFn, false);
    const LiftErr = FastLift(ErrUnionFn, ErrUnionImpl.div, false);
    try testing.expectEqual(@as(i64, 21), try LowerErr.call(&ctx, LiftErr.thunk(), .{ 84, 4 }));
    try testing.expectError(error.DivideByZero, LowerErr.call(&ctx, LiftErr.thunk(), .{ 84, 0 }));
    try testing.expectEqual(@as(usize, 0), ReallocTracker.calls);

    // 3. High-arity (>16 parameters) — Canonical ABI spills to cabi_realloc, FastLower uses 0 reallocs!
    const HighArityFn = fn (
        p0: u64, p1: u64, p2: u64, p3: u64, p4: u64, p5: u64,
        p6: u64, p7: u64, p8: u64, p9: u64, p10: u64, p11: u64,
        p12: u64, p13: u64, p14: u64, p15: u64, p16: u64, p17: u64,
    ) u64;
    const HighArityImpl = struct {
        fn sum18(
            p0: u64, p1: u64, p2: u64, p3: u64, p4: u64, p5: u64,
            p6: u64, p7: u64, p8: u64, p9: u64, p10: u64, p11: u64,
            p12: u64, p13: u64, p14: u64, p15: u64, p16: u64, p17: u64,
        ) u64 {
            return p0 + p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8 +
                p9 + p10 + p11 + p12 + p13 + p14 + p15 + p16 + p17;
        }
    };
    const sum = try FastLower(HighArityFn, false).call(
        &ctx,
        FastLift(HighArityFn, HighArityImpl.sum18, false).thunk(),
        .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 },
    );
    try testing.expectEqual(@as(u64, 171), sum);
    try testing.expectEqual(@as(usize, 0), ReallocTracker.calls);
}

test "FastLower and FastLift: zero-copy in-place linear-memory slices and nested records with slices" {
    var mem: [16384]u8 align(16) = undefined;
    @memset(&mem, 0);

    const ReallocTracker = struct {
        var calls: usize = 0;
        fn realloc(_: ?*anyopaque, _: usize, _: usize, _: usize, _: usize) canon.Error!usize {
            calls += 1;
            return error.ReallocFailed;
        }
    };
    ReallocTracker.calls = 0;

    var ctx = canon.MemoryContext{
        .memory = &mem,
        .base_addr = if (builtin.cpu.arch.isWasm()) @intFromPtr(&mem) else 0,
        .realloc_fn = ReallocTracker.realloc,
        .allocator = testing.allocator,
        .fast_frame_offset = 256,
    };

    // Place a string and a u32 slice directly inside `mem` at known offsets
    const in_place_str_off: usize = 32;
    const raw_msg = "zero-copy-in-place-zigar-slice";
    @memcpy(mem[in_place_str_off..][0..raw_msg.len], raw_msg);
    const in_place_str: []const u8 = mem[in_place_str_off..][0..raw_msg.len];

    const in_place_nums_off: usize = 96;
    const nums_slice_mem: []u32 = @alignCast(std.mem.bytesAsSlice(u32, mem[in_place_nums_off..][0..16]));
    nums_slice_mem[0] = 10;
    nums_slice_mem[1] = 20;
    nums_slice_mem[2] = 30;
    nums_slice_mem[3] = 40;
    const in_place_nums: []const u32 = nums_slice_mem;

    const Point = extern struct { x: i32, y: i32 };
    const NestedItem = struct {
        label: []const u8,
        points: []const Point,
        tag: ?u32,
    };

    const ZeroCopyObserver = struct {
        var observed_str_ptr: usize = 0;
        var observed_nums_ptr: usize = 0;

        fn inspect(
            msg: []const u8,
            nums: []const u32,
            items: []const NestedItem,
        ) []const u8 {
            observed_str_ptr = @intFromPtr(msg.ptr);
            observed_nums_ptr = @intFromPtr(nums.ptr);
            // Return a subslice of `msg` (which also resides inside `mem_ctx.memory`!)
            if (items.len > 0 and items[0].points.len > 0 and nums.len == 4) {
                return msg[0..9]; // "zero-copy"
            }
            return "";
        }
    };

    const InspectFn = fn ([]const u8, []const u32, []const NestedItem) []const u8;
    const pts = [_]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const items = [_]NestedItem{
        .{ .label = "external-item", .points = &pts, .tag = 77 },
    };

    const ret_slice = try FastLower(InspectFn, false).call(
        &ctx,
        FastLift(InspectFn, ZeroCopyObserver.inspect, false).thunk(),
        .{ in_place_str, in_place_nums, &items },
    );

    // 1. Verify zero cabi_realloc calls occurred
    try testing.expectEqual(@as(usize, 0), ReallocTracker.calls);
    // 2. Verify the guest received a slice pointing to the EXACT same address in `mem`!
    try testing.expectEqual(@intFromPtr(in_place_str.ptr), ZeroCopyObserver.observed_str_ptr);
    try testing.expectEqual(@intFromPtr(in_place_nums.ptr), ZeroCopyObserver.observed_nums_ptr);
    // 3. Verify the returned subslice also points directly to `in_place_str.ptr` with zero copy!
    try testing.expectEqualStrings("zero-copy", ret_slice);
    try testing.expectEqual(@intFromPtr(in_place_str.ptr), @intFromPtr(ret_slice.ptr));
}

test "Adversarial review edge cases: B2 (>4KB nested slice lift), B3 (frame header bump cursor & scratch), B4 (alignment/bounds), N1 (in-place overlap), S1 (max component depth)" {
    const alloc = testing.allocator;

    // ── B3a: Guest static scratch region exports/helpers ──────────────────
    try testing.expect(fastScratchPtr() != 0);
    try testing.expectEqual(DEFAULT_FAST_SCRATCH_LEN, fastScratchLen());
    try testing.expectEqual(@as(usize, 0), fastScratchPtr() % 16);

    // ── B2: >4 KB nested non-blittable slice lift with `mem_ctx.allocator == null` ──
    const BigNestedItem = struct {
        title: []const u8,
        subtitle: []const u8,
        metric: ?u64,
    };
    const BigListFn = fn ([]const BigNestedItem) u64;
    const BigListImpl = struct {
        fn sumMetrics(items: []const BigNestedItem) u64 {
            var total: u64 = 0;
            for (items) |it| {
                total += @as(u64, @intCast(it.title.len + it.subtitle.len)) + (it.metric orelse 0);
            }
            return total;
        }
    };

    var big_items: [200]BigNestedItem = undefined;
    for (&big_items, 0..) |*slot, i| {
        slot.* = .{
            .title = "record-title",
            .subtitle = "record-subtitle",
            .metric = @intCast(i + 1),
        };
    }
    // Verify 200 items exceed the 4 KB stack buffer (`200 * @sizeOf(BigNestedItem) > 4096`)
    try testing.expect(200 * @sizeOf(BigNestedItem) > 4096);

    var big_mem: [32768]u8 align(16) = @splat(0);
    // Notice `allocator = null` here: `FastLift.callFromMemory` uses `StackFallbackAllocator(4096)`
    // backed by `wasm_allocator` / `page_allocator` and must succeed without OutOfMemory!
    var big_ctx = canon.MemoryContext{
        .memory = &big_mem,
        .base_addr = if (builtin.cpu.arch.isWasm()) @intFromPtr(&big_mem) else 0,
        .allocator = null,
        .fast_frame_offset = 64,
    };
    const big_sum = try FastLower(BigListFn, false).call(
        &big_ctx,
        FastLift(BigListFn, BigListImpl.sumMetrics, false).thunk(),
        .{&big_items},
    );
    // 200 * (12 + 15) = 5400; sum(1..200) = 20100; total = 25500
    try testing.expectEqual(@as(u64, 25500), big_sum);

    // ── B3b: Frame header `bump_cursor` prevents return slice from overwriting non-in-place arg slices ──
    const EchoPairFn = fn ([]const u8, []const u8) []const u8;
    const EchoPairImpl = struct {
        fn combine(a: []const u8, b: []const u8) []const u8 {
            _ = a;
            _ = b;
            // Return an external literal slice (not inside `big_mem`) so `FastLift` must
            // serialize it into `big_mem` using the frame header's `bump_cursor`.
            return "callee-returned-external-payload";
        }
    };
    var bump_mem: [4096]u8 align(16) = @splat(0);
    const BumpCtxHolder = struct {
        var ctx: canon.MemoryContext = undefined;
    };
    BumpCtxHolder.ctx = canon.MemoryContext{
        .memory = &bump_mem,
        .base_addr = if (builtin.cpu.arch.isWasm()) @intFromPtr(&bump_mem) else 0,
        .fast_frame_offset = 64,
    };
    const ext_arg_a = "external-arg-alpha-0123456789";
    const ext_arg_b = "external-arg-bravo-9876543210";
    const EchoLower = FastLower(EchoPairFn, false);
    const EchoLift = FastLift(EchoPairFn, EchoPairImpl.combine, false);
    const echo_ret = try EchoLower.call(&BumpCtxHolder.ctx, EchoLift.createThunk(&BumpCtxHolder.ctx), .{ ext_arg_a, ext_arg_b });
    try testing.expectEqualStrings("callee-returned-external-payload", echo_ret);

    // Verify that `ext_arg_a` serialized at `frame_end` (`64 + EchoLower.frame_layout.frame_size`)
    // was NOT overwritten by `echo_ret`!
    const arg_a_off = 64 + EchoLower.frame_layout.frame_size;
    try testing.expectEqualStrings(ext_arg_a, bump_mem[arg_a_off..][0..ext_arg_a.len]);
    // And `echo_ret` lies strictly after both `ext_arg_a` and `ext_arg_b`:
    const ret_off = @intFromPtr(echo_ret.ptr) - @intFromPtr(&bump_mem);
    try testing.expect(ret_off >= arg_a_off + ext_arg_a.len + ext_arg_b.len);

    // Also verify `header_limit_offset` bounds-checks the callee's return slice write:
    var limit_ctx = canon.MemoryContext{
        .memory = &bump_mem,
        .fast_frame_offset = 64,
    };
    var manual_bump: usize = 64 + EchoLower.frame_layout.frame_size;
    try storeFastFrame(EchoPairFn, false, &limit_ctx, 64, .{ ext_arg_a, ext_arg_b }, &manual_bump);
    // Set `header_limit_offset` to `manual_bump + 4` (too small for 32-byte return string!)
    std.mem.writeInt(
        u32,
        bump_mem[64 + EchoLower.frame_layout.header_limit_offset ..][0..4],
        @intCast(manual_bump + 4),
        .little,
    );
    try testing.expectError(error.OutOfBounds, EchoLift.callFromMemory(&limit_ctx, 64));

    // ── B4: Unaligned frame/slice pointers, unaligned host backing buffer fallback, Char & 0x7fff_ffff ──
    // 1. Unaligned frame address in `FastLift.callFromMemory` -> `error.UnalignedPointer`
    try testing.expectError(error.UnalignedPointer, EchoLift.callFromMemory(&BumpCtxHolder.ctx, @intCast(BumpCtxHolder.ctx.base_addr + 65)));

    // 2. Unaligned `[]const u32` `data_addr` in linear memory -> `error.UnalignedPointer`
    var align_mem: [512]u8 align(16) = @splat(0);
    var align_ctx = canon.MemoryContext{
        .memory = &align_mem,
        .allocator = alloc,
    };
    // Write slice header `(ptr = 101, len = 2)` at offset 16; `101 % 4 != 0` -> `error.UnalignedPointer`
    std.mem.writeInt(u32, align_mem[16..20], 101, .little);
    std.mem.writeInt(u32, align_mem[20..24], 2, .little);
    try testing.expectError(error.UnalignedPointer, loadFastValue([]const u32, false, &align_ctx, 16));

    // 3. Unaligned host buffer (`align_mem[1..]` with `base_addr = 0`):
    // Guest address `64` is 4-byte aligned (`64 % 4 == 0`), but its host address is `&align_mem[1 + 64]`
    // (`&align_mem[65]`, which is odd on the host!).
    // `loadFastValue` must fall back to allocating an aligned slice from `odd_host_ctx.allocator`.
    var odd_host_ctx = canon.MemoryContext{
        .memory = align_mem[1..],
        .base_addr = 0,
        .allocator = alloc,
    };
    // Offset 16 in `align_mem[1..]` -> `align_mem[17..25]`
    // Offset 64 in `align_mem[1..]` -> `align_mem[65..73]`
    std.mem.writeInt(u32, odd_host_ctx.memory[16..20], 64, .little);
    std.mem.writeInt(u32, odd_host_ctx.memory[20..24], 2, .little);
    std.mem.writeInt(u32, odd_host_ctx.memory[64..68], 0x11223344, .little);
    std.mem.writeInt(u32, odd_host_ctx.memory[68..72], 0x55667788, .little);
    const copied_u32 = try loadFastValue([]const u32, false, &odd_host_ctx, 16);
    defer alloc.free(copied_u32);
    try testing.expectEqual(@as(usize, 2), copied_u32.len);
    try testing.expectEqual(@as(u32, 0x11223344), copied_u32[0]);
    try testing.expectEqual(@as(u32, 0x55667788), copied_u32[1]);

    // 4. `0x7fff_ffff` byte-length cap on slice load -> `error.OutOfBounds`
    std.mem.writeInt(u32, align_mem[16..20], 64, .little);
    std.mem.writeInt(u32, align_mem[20..24], 0x4000_0000, .little); // 0x4000_0000 * 4 > 0x7fff_ffff
    try testing.expectError(error.OutOfBounds, loadFastValue([]const u32, false, &align_ctx, 16));

    // 5. Invalid `Char` surrogate (`0xD800`) rejected in both store and load
    std.mem.writeInt(u32, align_mem[32..36], 0xD800, .little);
    try testing.expectError(error.InvalidChar, loadFastValue(canon.Char, false, &align_ctx, 32));

    // ── N1: In-place input slice near end of memory returns `error.OutOfBounds` ──
    var small_mem: [128]u8 align(16) = @splat(0);
    var small_ctx = canon.MemoryContext{
        .memory = &small_mem,
        .base_addr = if (builtin.cpu.arch.isWasm()) @intFromPtr(&small_mem) else 0,
        .fast_frame_offset = 0,
    };
    // Place an in-place slice ending at offset 124 (leaving only 4 bytes before `small_mem.len`,
    // which is smaller than `EchoLower.frame_layout.frame_size`!)
    const tail_in_place = small_mem[100..124];
    try testing.expectError(
        error.OutOfBounds,
        EchoLower.call(&small_ctx, EchoLift.thunk(), .{ tail_in_place, "ok" }),
    );

    // ── S1: `detectZigarAbiInComponent` rejects > 64 nested components ──
    var nested_comp = try alloc.dupe(u8, COMPONENT_PREAMBLE);
    defer alloc.free(nested_comp);
    var depth: usize = 0;
    while (depth <= MAX_COMPONENT_NESTING_DEPTH + 2) : (depth += 1) {
        var wrapper = std.ArrayList(u8).empty;
        errdefer wrapper.deinit(alloc);
        try wrapper.appendSlice(alloc, COMPONENT_PREAMBLE);
        try wrapper.append(alloc, 4); // SECTION_COMPONENT
        // ULEB128 encode `nested_comp.len`
        var rem = nested_comp.len;
        while (true) {
            var byte: u8 = @intCast(rem & 0x7f);
            rem >>= 7;
            if (rem != 0) byte |= 0x80;
            try wrapper.append(alloc, byte);
            if (rem == 0) break;
        }
        try wrapper.appendSlice(alloc, nested_comp);
        alloc.free(nested_comp);
        nested_comp = try wrapper.toOwnedSlice(alloc);
    }
    try testing.expectError(error.InvalidComponent, detectZigarAbiInComponent(alloc, nested_comp));

    // ── Follow-up 1: 1,000-iteration loop across separate `caller_ctx` and `callee_ctx` ──
    // Verifies `callee_ctx.fast_bump_cursor` does NOT grow monotonically across calls when
    // the caller's frame header supplies `header_bump_offset` in a small 4 KB buffer!
    var loop_mem: [4096]u8 align(16) = @splat(0);
    var caller_ctx = canon.MemoryContext{
        .memory = &loop_mem,
        .base_addr = if (builtin.cpu.arch.isWasm()) @intFromPtr(&loop_mem) else 0,
        .fast_frame_offset = 64,
    };
    const CalleeCtxHolder = struct {
        var ctx: canon.MemoryContext = undefined;
    };
    CalleeCtxHolder.ctx = canon.MemoryContext{
        .memory = &loop_mem,
        .base_addr = caller_ctx.base_addr,
        .fast_frame_offset = 64,
    };
    var iter: usize = 0;
    while (iter < 1000) : (iter += 1) {
        const res_str = try EchoLower.call(
            &caller_ctx,
            EchoLift.createThunk(&CalleeCtxHolder.ctx),
            .{ "loop-arg-alpha-payload", "loop-arg-bravo-payload" },
        );
        try testing.expectEqualStrings("callee-returned-external-payload", res_str);
    }

    // ── Follow-up 2: `configureFastScratch` & `fast_scratch_limit` enforcement ──
    var scratch_ctx = canon.MemoryContext{
        .memory = &loop_mem,
        .base_addr = caller_ctx.base_addr,
    };
    // Configure a tight 64-byte scratch window at offset 128..192 (too small for frame + two 22-byte strings)
    try scratch_ctx.configureFastScratch(scratch_ctx.base_addr + 128, 64);
    try testing.expectEqual(@as(usize, 128), scratch_ctx.fast_frame_offset);
    try testing.expectEqual(@as(?usize, 192), scratch_ctx.fast_scratch_limit);
    try testing.expectError(
        error.OutOfBounds,
        EchoLower.call(&scratch_ctx, EchoLift.createThunk(&CalleeCtxHolder.ctx), .{
            "first-22-byte-argument",
            "second-23-byte-argument",
        }),
    );
}

test "FastLower and FastLift callOnShadowStack with ShadowStackPool and async WIT subtask" {
    const async_runtime = @import("async_runtime.zig");
    const alloc = testing.allocator;

    var sched = async_runtime.AsyncScheduler.init(alloc);
    defer sched.deinit();

    var mem: [4096]u8 align(16) = @splat(0);
    var bump = canon.BumpAllocator.init(512, mem.len);
    var mem_ctx = canon.MemoryContext{
        .memory = &mem,
        .base_addr = if (builtin.cpu.arch.isWasm()) @intFromPtr(&mem) else 0,
        .realloc_ctx = &bump,
        .realloc_fn = canon.BumpAllocator.realloc,
        .fast_frame_offset = 64,
    };
    sched.configureMemoryContext(&mem_ctx);

    const HostImportFn = fn (n: u32) u32;
    const GuestFastFn = fn (label: []const u8, factor: u32) u32;

    const AsyncBridgeEnv = struct {
        sched_ptr: *async_runtime.AsyncScheduler,
        mem_ctx_ptr: *canon.MemoryContext,
        pending_arg: u32 = 0,
        ret_ptr: usize = 0,
        steps: u32 = 0,
        sp_during_suspend: usize = 0,

        var current: ?*@This() = null;

        fn step(raw_ctx: ?*anyopaque, s: *async_runtime.AsyncScheduler, _: i32) !async_runtime.SubtaskState {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            self.steps += 1;
            self.sp_during_suspend = s.sp_binding.get();
            if (self.steps < 2) return .started;
            try canon.storeToMemory(u32, .wasm32, self.mem_ctx_ptr.*, self.ret_ptr, self.pending_arg + 10);
            return .returned;
        }

        fn hostAsyncCore(n: i32, ret_ptr: i32) i32 {
            const self = current.?;
            self.pending_arg = @bitCast(n);
            self.ret_ptr = @intCast(@as(u32, @bitCast(ret_ptr)));
            const h = self.sched_ptr.spawnAsyncSubtask(self, step) catch unreachable;
            return async_runtime.SubtaskState.started.pack(@intCast(h));
        }

        fn guestFastImpl(label: []const u8, factor: u32) u32 {
            const mctx = canon.getActiveMemoryContext().?;
            const imported = canon.lowerCall(
                HostImportFn,
                .{ .arch = .wasm32, .is_async = true, .direction = .lower },
                mctx,
                &hostAsyncCore,
                .{@as(u32, @intCast(label.len)) * factor},
            ) catch unreachable;
            return imported * 2;
        }
    };

    var env = AsyncBridgeEnv{
        .sched_ptr = &sched,
        .mem_ctx_ptr = &mem_ctx,
    };
    AsyncBridgeEnv.current = &env;
    defer AsyncBridgeEnv.current = null;

    var host_sp: usize = 0x7000_0000;
    sched.sp_binding = async_runtime.StackPointerBinding.fromHostSlot(&host_sp);

    const stack = try sched.stack_pool.acquire(alloc);
    defer sched.stack_pool.release(alloc, stack) catch {};
    var task_ctx = async_runtime.TaskContext.init(stack, sched.sp_binding);

    const LowerFast = FastLower(GuestFastFn, false);
    const LiftFast = FastLift(GuestFastFn, AsyncBridgeEnv.guestFastImpl, false);

    // ("zigar".len * 6 + 10) * 2 = 80
    const res = try LowerFast.callOnShadowStack(&mem_ctx, &task_ctx, LiftFast.thunk(), .{ "zigar", 6 });
    try testing.expectEqual(@as(u32, 80), res);
    try testing.expectEqual(@as(u32, 2), env.steps);
    try testing.expectEqual(@as(usize, 0x7000_0000), env.sp_during_suspend);
    try testing.expectEqual(@as(usize, 0x7000_0000), host_sp);
    try testing.expectEqual(async_runtime.TaskContext.State.completed, task_ctx.state);
}
