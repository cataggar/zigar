//! WebAssembly module optimizer.
//!
//! Performs deterministic intrafunction optimizations (constant folding,
//! control-flow simplification, dead-code elimination) and module-level
//! dead-function removal with function index remapping.

const std = @import("std");
const types = @import("core_types.zig");
const Mod = @import("Module.zig");
const leb128 = @import("leb128.zig");
const instr = @import("binary/instr.zig");
const reader = @import("binary/reader.zig");
const writer = @import("binary/writer.zig");

pub const CustomSectionPolicy = enum {
    reject,
    strip,
    preserve,
};

pub const OptimizeMode = enum {
    small,
    fast,
};

pub const Options = struct {
    custom_sections: CustomSectionPolicy = .reject,
    optimize_mode: OptimizeMode = .small,
};

pub const Error = error{
    ComponentNotSupported,
    CustomSectionsPresent,
    UnsupportedFeature,
    UnsupportedOpcode,
    InvalidInput,
    InvalidOutput,
    OutOfMemory,
};

const component_version: u32 = 0x0001_000d;
const max_pass_rounds: usize = 8;

/// Optimize a binary WebAssembly module and return the optimized binary bytes.
pub fn optimize(allocator: std.mem.Allocator, wasm_bytes: []const u8, options: Options) Error![]u8 {
    if (wasm_bytes.len >= 8 and
        std.mem.eql(u8, wasm_bytes[0..4], &reader.magic) and
        std.mem.readInt(u32, wasm_bytes[4..8], .little) == component_version)
    {
        return error.ComponentNotSupported;
    }

    var module = reader.readModule(allocator, wasm_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInput,
    };
    defer module.deinit();

    try optimizeModule(allocator, &module, options);

    const out_bytes = writer.writeModule(allocator, &module) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidOutput,
    };
    errdefer allocator.free(out_bytes);

    var out_mod = reader.readModule(allocator, out_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidOutput,
    };
    defer out_mod.deinit();

    return out_bytes;
}

/// Optimize a parsed WebAssembly module in place.
pub fn optimizeModule(allocator: std.mem.Allocator, module: *Mod.Module, options: Options) Error!void {
    try preflightModule(module);

    if (module.customs.items.len > 0) {
        switch (options.custom_sections) {
            .reject => return error.CustomSectionsPresent,
            .strip => {
                for (module.customs.items) |custom| {
                    if (custom.owns_data and custom.data.len > 0) {
                        module.allocator.free(custom.data);
                    }
                }
                module.customs.clearRetainingCapacity();
            },
            .preserve => {
                for (module.customs.items) |custom| {
                    if (std.mem.startsWith(u8, custom.name, "reloc.") or
                        std.mem.startsWith(u8, custom.name, ".debug_"))
                    {
                        return error.CustomSectionsPresent;
                    }
                }
            },
        }
    }

    const locals_compacted = allocator.alloc(bool, module.funcs.items.len) catch return error.OutOfMemory;
    defer allocator.free(locals_compacted);
    @memset(locals_compacted, false);

    for (module.num_func_imports..module.funcs.items.len) |i| {
        const func = &module.funcs.items[i];
        if (func.is_import or func.code_bytes.len == 0) continue;
        if (try optimizeFuncBody(allocator, module, func, options.optimize_mode)) {
            locals_compacted[i] = true;
        }
    }

    const max_inline_rounds: usize = switch (options.optimize_mode) {
        .small => 2,
        .fast => 4,
    };
    if (module.funcs.items.len > module.num_func_imports) {
        const modified_funcs = allocator.alloc(bool, module.funcs.items.len) catch return error.OutOfMemory;
        defer allocator.free(modified_funcs);

        for (0..max_inline_rounds) |_| {
            @memset(modified_funcs, false);
            const any_inlined = try inlineTrivialFunctions(allocator, module, options.optimize_mode, modified_funcs);
            if (!any_inlined) break;
            for (module.num_func_imports..module.funcs.items.len) |i| {
                if (modified_funcs[i]) {
                    if (try optimizeFuncBody(allocator, module, &module.funcs.items[i], options.optimize_mode)) {
                        locals_compacted[i] = true;
                    }
                }
            }
        }
    }

    try removeDeadFunctions(allocator, module, locals_compacted);
}

// ── Preflight validation ─────────────────────────────────────────────────

fn isAllowedValType(vt: types.ValType, type_idx: u32) bool {
    if (type_idx != types.invalid_index) return false;
    return switch (vt) {
        .i32, .i64, .f32, .f64, .v128, .funcref, .externref => true,
        else => false,
    };
}

fn isAllowedValTypeByte(byte: u8) bool {
    return switch (byte) {
        0x7f, // i32
        0x7e, // i64
        0x7d, // f32
        0x7c, // f64
        0x7b, // v128
        0x70, // funcref
        0x6f, // externref
        => true,
        else => false,
    };
}

fn preflightDeclarations(module: *const Mod.Module) Error!void {
    if (module.tags.items.len > 0 or module.num_tag_imports > 0) {
        return error.UnsupportedFeature;
    }
    for (module.imports.items) |imp| {
        if (imp.kind == .tag or imp.tag != null) return error.UnsupportedFeature;
    }
    for (module.exports.items) |exp| {
        if (exp.kind == .tag) return error.UnsupportedFeature;
    }

    if (module.empty_rec_group_positions.items.len > 0) {
        return error.UnsupportedFeature;
    }
    for (module.type_meta.items) |meta| {
        if (meta.kind != .func or meta.is_sub or !meta.is_final or meta.in_rec_group or meta.parent != types.invalid_index) {
            return error.UnsupportedFeature;
        }
    }
    for (module.module_types.items) |entry| {
        switch (entry) {
            .struct_type, .array_type, .cont_type => return error.UnsupportedFeature,
            .func_type => |ft| {
                for (ft.params, 0..) |p, i| {
                    if (!isAllowedValType(p, Mod.FuncSignature.concreteIdxAt(ft.param_type_idxs, i))) {
                        return error.UnsupportedFeature;
                    }
                }
                for (ft.results, 0..) |r, i| {
                    if (!isAllowedValType(r, Mod.FuncSignature.concreteIdxAt(ft.result_type_idxs, i))) {
                        return error.UnsupportedFeature;
                    }
                }
            },
        }
    }

    for (module.funcs.items) |func| {
        for (func.decl.sig.params, 0..) |p, i| {
            const tidx = if (i < func.decl.sig.param_type_idxs.len) func.decl.sig.param_type_idxs[i] else types.invalid_index;
            if (!isAllowedValType(p, tidx)) return error.UnsupportedFeature;
        }
        for (func.decl.sig.results, 0..) |r, i| {
            const tidx = if (i < func.decl.sig.result_type_idxs.len) func.decl.sig.result_type_idxs[i] else types.invalid_index;
            if (!isAllowedValType(r, tidx)) return error.UnsupportedFeature;
        }
        for (func.local_types.items, 0..) |lt, i| {
            const tidx = if (i < func.local_type_idxs.items.len) func.local_type_idxs.items[i] else types.invalid_index;
            if (!isAllowedValType(lt, tidx)) return error.UnsupportedFeature;
        }
    }

    for (module.globals.items) |global| {
        if (!isAllowedValType(global.type.val_type, global.type_idx)) {
            return error.UnsupportedFeature;
        }
    }

    for (module.tables.items) |table| {
        if (!isAllowedValType(table.type.elem_type, table.type_idx)) {
            return error.UnsupportedFeature;
        }
        if (table.type.limits.is_shared or table.type.limits.usesCustomPageSize()) {
            return error.UnsupportedFeature;
        }
    }

    for (module.memories.items) |mem| {
        if (mem.type.limits.usesCustomPageSize()) {
            return error.UnsupportedFeature;
        }
    }

    for (module.imports.items) |imp| {
        switch (imp.kind) {
            .func => if (imp.func) |f| {
                for (f.sig.params, 0..) |p, i| {
                    const tidx = if (i < f.sig.param_type_idxs.len) f.sig.param_type_idxs[i] else types.invalid_index;
                    if (!isAllowedValType(p, tidx)) return error.UnsupportedFeature;
                }
                for (f.sig.results, 0..) |r, i| {
                    const tidx = if (i < f.sig.result_type_idxs.len) f.sig.result_type_idxs[i] else types.invalid_index;
                    if (!isAllowedValType(r, tidx)) return error.UnsupportedFeature;
                }
            },
            .table => if (imp.table) |t| {
                if (!isAllowedValType(t.elem_type, imp.table_type_idx)) return error.UnsupportedFeature;
                if (t.limits.is_shared or t.limits.usesCustomPageSize()) return error.UnsupportedFeature;
            },
            .memory => if (imp.memory) |m| {
                if (m.limits.usesCustomPageSize()) return error.UnsupportedFeature;
            },
            .global => if (imp.global) |g| {
                if (!isAllowedValType(g.val_type, imp.global_type_idx)) return error.UnsupportedFeature;
            },
            .tag => return error.UnsupportedFeature,
        }
    }

    for (module.elem_segments.items) |seg| {
        if (seg.elem_type_idx != types.invalid_index) return error.UnsupportedFeature;
        if (seg.uses_elem_exprs) {
            if (!isAllowedValType(seg.elem_type, seg.elem_type_idx)) return error.UnsupportedFeature;
        } else {
            if (seg.elem_type != .funcref and seg.elem_type != .ref_func and seg.elem_type != .externref) {
                return error.UnsupportedFeature;
            }
        }
    }
}

fn preflightModule(module: *const Mod.Module) Error!void {
    try preflightDeclarations(module);

    for (module.funcs.items[module.num_func_imports..]) |func| {
        if (func.is_import or func.code_bytes.len == 0) continue;
        try preflightInstrBytes(module, func.code_bytes);
    }

    for (module.globals.items) |global| {
        if (!global.is_import and global.init_expr_bytes.len > 0) {
            try preflightInstrBytes(module, global.init_expr_bytes);
        }
    }

    for (module.tables.items) |table| {
        if (!table.is_import and table.hasInitExpr() and table.init_expr_bytes.len > 0) {
            try preflightInstrBytes(module, table.init_expr_bytes);
        }
    }

    for (module.elem_segments.items) |seg| {
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            try preflightInstrBytes(module, seg.offset_expr_bytes);
        }
        if (seg.elem_expr_bytes.len > 0) {
            try preflightInstrBytes(module, seg.elem_expr_bytes);
        }
    }

    for (module.data_segments.items) |seg| {
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            try preflightInstrBytes(module, seg.offset_expr_bytes);
        }
    }
}

fn preflightInstrBytes(module: *const Mod.Module, bytes: []const u8) Error!void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const byte = bytes[pos];
        pos += 1;

        switch (byte) {
            0xfb => return error.UnsupportedOpcode,
            0xfd, 0xfe => {
                pos -= 1;
                const decoded = instr.decode(bytes, &pos) catch return error.InvalidInput;
                instr.skipImmediates(decoded.shape, bytes, &pos) catch return error.InvalidInput;
            },
            0xfc => {
                const sub = readU32(bytes, &pos) catch return error.InvalidInput;
                switch (sub) {
                    0x00...0x07 => {},
                    0x08, 0x0a, 0x0c, 0x0e => {
                        _ = readU32(bytes, &pos) catch return error.InvalidInput;
                        _ = readU32(bytes, &pos) catch return error.InvalidInput;
                    },
                    0x09, 0x0b, 0x0d, 0x0f, 0x10, 0x11 => {
                        _ = readU32(bytes, &pos) catch return error.InvalidInput;
                    },
                    else => return error.UnsupportedOpcode,
                }
            },
            0x00, 0x01, 0x05, 0x0b, 0x0f, 0x1a, 0x1b, 0xd1 => {},
            0x02, 0x03, 0x04 => {
                try preflightBlockType(module, bytes, &pos);
            },
            0x0c, 0x0d, 0x10, 0x12, 0x20...0x26, 0x3f, 0x40, 0xd2 => {
                _ = readU32(bytes, &pos) catch return error.InvalidInput;
            },
            0x0e => {
                const count = readU32(bytes, &pos) catch return error.InvalidInput;
                for (0..@as(usize, count) + 1) |_| {
                    _ = readU32(bytes, &pos) catch return error.InvalidInput;
                }
            },
            0x11, 0x13 => {
                _ = readU32(bytes, &pos) catch return error.InvalidInput;
                _ = readU32(bytes, &pos) catch return error.InvalidInput;
            },
            0x1c => {
                const count = readU32(bytes, &pos) catch return error.InvalidInput;
                if (count != 1) return error.InvalidInput;
                if (pos >= bytes.len) return error.InvalidInput;
                const vt_byte = bytes[pos];
                pos += 1;
                if (!isAllowedValTypeByte(vt_byte)) {
                    return error.UnsupportedFeature;
                }
            },
            0x28...0x3e => {
                const align_flags = readU32(bytes, &pos) catch return error.InvalidInput;
                if ((align_flags & 0x40) != 0) {
                    _ = readU32(bytes, &pos) catch return error.InvalidInput;
                }
                _ = readU64(bytes, &pos) catch return error.InvalidInput;
            },
            0x41 => {
                _ = readS32(bytes, &pos) catch return error.InvalidInput;
            },
            0x42 => {
                _ = readS64(bytes, &pos) catch return error.InvalidInput;
            },
            0x43 => {
                if (pos + 4 > bytes.len) return error.InvalidInput;
                pos += 4;
            },
            0x44 => {
                if (pos + 8 > bytes.len) return error.InvalidInput;
                pos += 8;
            },
            0x45...0xc4 => {},
            0xd0 => {
                const ht = readS33(bytes, &pos) catch return error.InvalidInput;
                if (ht != -0x10 and ht != -0x11) {
                    return error.UnsupportedFeature;
                }
            },
            0x06...0x0a, 0x14, 0x15, 0x18, 0x19, 0x1f, 0xd3...0xd6, 0xe0...0xe6 => {
                return error.UnsupportedOpcode;
            },
            else => return error.InvalidInput,
        }
    }
}

fn preflightBlockType(module: *const Mod.Module, bytes: []const u8, pos: *usize) Error!void {
    if (pos.* >= bytes.len) return error.InvalidInput;
    const byte = bytes[pos.*];
    if (byte == 0x40 or isAllowedValTypeByte(byte)) {
        pos.* += 1;
        return;
    }
    if (byte == reader.ref_null_prefix or byte == reader.ref_prefix) {
        return error.UnsupportedFeature;
    }
    if (byte >= 0x40 and byte < 0x80) {
        return error.UnsupportedFeature;
    }
    const s33 = readS33(bytes, pos) catch return error.InvalidInput;
    if (s33 < 0 or s33 > std.math.maxInt(u32)) return error.InvalidInput;
    const type_idx: u32 = @intCast(s33);
    if (type_idx >= module.module_types.items.len) return error.InvalidInput;
    switch (module.module_types.items[type_idx]) {
        .func_type => {},
        else => return error.UnsupportedFeature,
    }
}

// ── LEB128 helpers ───────────────────────────────────────────────────────

fn readU32(bytes: []const u8, pos: *usize) leb128.ReadError!u32 {
    const r = try leb128.readU32Leb128(bytes[pos.*..]);
    pos.* += r.bytes_read;
    return r.value;
}

fn readU64(bytes: []const u8, pos: *usize) leb128.ReadError!u64 {
    const r = try leb128.readU64Leb128(bytes[pos.*..]);
    pos.* += r.bytes_read;
    return r.value;
}

fn readS32(bytes: []const u8, pos: *usize) leb128.ReadError!i32 {
    const r = try leb128.readS32Leb128(bytes[pos.*..]);
    pos.* += r.bytes_read;
    return r.value;
}

fn readS33(bytes: []const u8, pos: *usize) leb128.ReadError!i64 {
    const r = try leb128.readS33Leb128(bytes[pos.*..]);
    pos.* += r.bytes_read;
    return r.value;
}

fn readS64(bytes: []const u8, pos: *usize) leb128.ReadError!i64 {
    const r = try leb128.readS64Leb128(bytes[pos.*..]);
    pos.* += r.bytes_read;
    return r.value;
}

fn appendU32Leb(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: u32) std.mem.Allocator.Error!void {
    var tmp: [leb128.max_u32_bytes]u8 = undefined;
    const n = leb128.writeU32Leb128(&tmp, v);
    try buf.appendSlice(allocator, tmp[0..n]);
}

fn appendS32Leb(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: i32) std.mem.Allocator.Error!void {
    var tmp: [leb128.max_s32_bytes]u8 = undefined;
    const n = leb128.writeS32Leb128(&tmp, v);
    try buf.appendSlice(allocator, tmp[0..n]);
}

fn appendS64Leb(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: i64) std.mem.Allocator.Error!void {
    var tmp: [leb128.max_s64_bytes]u8 = undefined;
    const n = leb128.writeS64Leb128(&tmp, v);
    try buf.appendSlice(allocator, tmp[0..n]);
}

// ── Intrafunction AST & Passes ───────────────────────────────────────────

const BlockTypeBytes = struct {
    bytes: [leb128.max_s33_bytes]u8 = undefined,
    len: u8 = 0,

    fn slice(self: *const BlockTypeBytes) []const u8 {
        return self.bytes[0..self.len];
    }

    fn isEmpty(self: BlockTypeBytes) bool {
        return self.len == 1 and self.bytes[0] == 0x40;
    }
};

const InstrList = std.ArrayListUnmanaged(Instr);

const BlockInstr = struct {
    block_type: BlockTypeBytes,
    body: InstrList = .empty,
};

const IfInstr = struct {
    block_type: BlockTypeBytes,
    then_body: InstrList = .empty,
    has_else: bool = false,
    else_body: InstrList = .empty,
};

const Instr = union(enum) {
    unreachable_,
    nop,
    block: BlockInstr,
    loop: BlockInstr,
    if_: IfInstr,
    br: u32,
    br_if: u32,
    br_table: []u32,
    return_,
    call: u32,
    return_call: u32,
    return_call_indirect: []const u8,
    local_get: u32,
    local_set: u32,
    local_tee: u32,
    i32_const: i32,
    i64_const: i64,
    ref_func: u32,
    numeric_op: u8,
    raw: []const u8,

    fn isUnconditionalTransfer(self: Instr) bool {
        return switch (self) {
            .unreachable_,
            .br,
            .br_table,
            .return_,
            .return_call,
            .return_call_indirect,
            => true,
            else => false,
        };
    }
};

const EndKind = enum {
    end,
    else_,
};

fn readBlockTypeBytes(bytes: []const u8, pos: *usize) Error!BlockTypeBytes {
    if (pos.* >= bytes.len) return error.InvalidInput;
    const start = pos.*;
    const b = bytes[pos.*];
    if (b < 0x80) {
        pos.* += 1;
    } else {
        _ = readS33(bytes, pos) catch return error.InvalidInput;
    }
    const len = pos.* - start;
    if (len > leb128.max_s33_bytes) return error.InvalidInput;
    var bt = BlockTypeBytes{ .len = @intCast(len) };
    @memcpy(bt.bytes[0..len], bytes[start..pos.*]);
    return bt;
}

fn parseInstrBlock(
    arena: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
    allow_else: bool,
    out_list: *InstrList,
) Error!EndKind {
    while (pos.* < bytes.len) {
        const instr_start = pos.*;
        const b = bytes[pos.*];
        pos.* += 1;

        switch (b) {
            0x0b => return .end,
            0x05 => {
                if (!allow_else) return error.InvalidInput;
                return .else_;
            },
            0x00 => out_list.append(arena, .unreachable_) catch return error.OutOfMemory,
            0x01 => out_list.append(arena, .nop) catch return error.OutOfMemory,
            0x02 => {
                const bt = try readBlockTypeBytes(bytes, pos);
                var body: InstrList = .empty;
                const end_kind = try parseInstrBlock(arena, bytes, pos, false, &body);
                if (end_kind != .end) return error.InvalidInput;
                out_list.append(arena, .{ .block = .{ .block_type = bt, .body = body } }) catch return error.OutOfMemory;
            },
            0x03 => {
                const bt = try readBlockTypeBytes(bytes, pos);
                var body: InstrList = .empty;
                const end_kind = try parseInstrBlock(arena, bytes, pos, false, &body);
                if (end_kind != .end) return error.InvalidInput;
                out_list.append(arena, .{ .loop = .{ .block_type = bt, .body = body } }) catch return error.OutOfMemory;
            },
            0x04 => {
                const bt = try readBlockTypeBytes(bytes, pos);
                var then_body: InstrList = .empty;
                var else_body: InstrList = .empty;
                const end_kind = try parseInstrBlock(arena, bytes, pos, true, &then_body);
                var has_else = false;
                if (end_kind == .else_) {
                    has_else = true;
                    const else_end = try parseInstrBlock(arena, bytes, pos, false, &else_body);
                    if (else_end != .end) return error.InvalidInput;
                }
                out_list.append(arena, .{
                    .if_ = .{
                        .block_type = bt,
                        .then_body = then_body,
                        .has_else = has_else,
                        .else_body = else_body,
                    },
                }) catch return error.OutOfMemory;
            },
            0x0c => {
                const label = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .br = label }) catch return error.OutOfMemory;
            },
            0x0d => {
                const label = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .br_if = label }) catch return error.OutOfMemory;
            },
            0x0e => {
                const count = readU32(bytes, pos) catch return error.InvalidInput;
                const total = @as(usize, count) + 1;
                const targets = arena.alloc(u32, total) catch return error.OutOfMemory;
                for (0..total) |i| {
                    targets[i] = readU32(bytes, pos) catch return error.InvalidInput;
                }
                out_list.append(arena, .{ .br_table = targets }) catch return error.OutOfMemory;
            },
            0x0f => out_list.append(arena, .return_) catch return error.OutOfMemory,
            0x10 => {
                const idx = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .call = idx }) catch return error.OutOfMemory;
            },
            0x12 => {
                const idx = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .return_call = idx }) catch return error.OutOfMemory;
            },
            0x13 => {
                _ = readU32(bytes, pos) catch return error.InvalidInput;
                _ = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .return_call_indirect = bytes[instr_start..pos.*] }) catch return error.OutOfMemory;
            },
            0x20 => {
                const idx = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .local_get = idx }) catch return error.OutOfMemory;
            },
            0x21 => {
                const idx = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .local_set = idx }) catch return error.OutOfMemory;
            },
            0x22 => {
                const idx = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .local_tee = idx }) catch return error.OutOfMemory;
            },
            0x41 => {
                const val = readS32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .i32_const = val }) catch return error.OutOfMemory;
            },
            0x42 => {
                const val = readS64(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .i64_const = val }) catch return error.OutOfMemory;
            },
            0x45...0xc4 => {
                out_list.append(arena, .{ .numeric_op = b }) catch return error.OutOfMemory;
            },
            0xd2 => {
                const idx = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .ref_func = idx }) catch return error.OutOfMemory;
            },
            else => {
                var probe = instr_start;
                const decoded = instr.decode(bytes, &probe) catch return error.InvalidInput;
                instr.skipImmediates(decoded.shape, bytes, &probe) catch return error.InvalidInput;
                pos.* = probe;
                out_list.append(arena, .{ .raw = bytes[instr_start..pos.*] }) catch return error.OutOfMemory;
            },
        }
    }
    return error.InvalidInput;
}

fn encodeInstrList(allocator: std.mem.Allocator, list: []const Instr, buf: *std.ArrayListUnmanaged(u8)) Error!void {
    for (list) |inst| {
        switch (inst) {
            .unreachable_ => buf.append(allocator, 0x00) catch return error.OutOfMemory,
            .nop => buf.append(allocator, 0x01) catch return error.OutOfMemory,
            .block => |b| {
                buf.append(allocator, 0x02) catch return error.OutOfMemory;
                buf.appendSlice(allocator, b.block_type.slice()) catch return error.OutOfMemory;
                try encodeInstrList(allocator, b.body.items, buf);
                buf.append(allocator, 0x0b) catch return error.OutOfMemory;
            },
            .loop => |l| {
                buf.append(allocator, 0x03) catch return error.OutOfMemory;
                buf.appendSlice(allocator, l.block_type.slice()) catch return error.OutOfMemory;
                try encodeInstrList(allocator, l.body.items, buf);
                buf.append(allocator, 0x0b) catch return error.OutOfMemory;
            },
            .if_ => |i| {
                buf.append(allocator, 0x04) catch return error.OutOfMemory;
                buf.appendSlice(allocator, i.block_type.slice()) catch return error.OutOfMemory;
                try encodeInstrList(allocator, i.then_body.items, buf);
                if (i.has_else) {
                    buf.append(allocator, 0x05) catch return error.OutOfMemory;
                    try encodeInstrList(allocator, i.else_body.items, buf);
                }
                buf.append(allocator, 0x0b) catch return error.OutOfMemory;
            },
            .br => |label| {
                buf.append(allocator, 0x0c) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, label);
            },
            .br_if => |label| {
                buf.append(allocator, 0x0d) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, label);
            },
            .br_table => |targets| {
                buf.append(allocator, 0x0e) catch return error.OutOfMemory;
                const count: u32 = @intCast(targets.len - 1);
                try appendU32Leb(allocator, buf, count);
                for (targets) |t| {
                    try appendU32Leb(allocator, buf, t);
                }
            },
            .return_ => buf.append(allocator, 0x0f) catch return error.OutOfMemory,
            .call => |idx| {
                buf.append(allocator, 0x10) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, idx);
            },
            .return_call => |idx| {
                buf.append(allocator, 0x12) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, idx);
            },
            .return_call_indirect => |raw| {
                buf.appendSlice(allocator, raw) catch return error.OutOfMemory;
            },
            .local_get => |idx| {
                buf.append(allocator, 0x20) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, idx);
            },
            .local_set => |idx| {
                buf.append(allocator, 0x21) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, idx);
            },
            .local_tee => |idx| {
                buf.append(allocator, 0x22) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, idx);
            },
            .i32_const => |val| {
                buf.append(allocator, 0x41) catch return error.OutOfMemory;
                try appendS32Leb(allocator, buf, val);
            },
            .i64_const => |val| {
                buf.append(allocator, 0x42) catch return error.OutOfMemory;
                try appendS64Leb(allocator, buf, val);
            },
            .ref_func => |idx| {
                buf.append(allocator, 0xd2) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, idx);
            },
            .numeric_op => |op| {
                buf.append(allocator, op) catch return error.OutOfMemory;
            },
            .raw => |raw| {
                buf.appendSlice(allocator, raw) catch return error.OutOfMemory;
            },
        }
    }
}

fn optimizeFuncBody(
    allocator: std.mem.Allocator,
    module: *const Mod.Module,
    func: *Mod.Func,
    optimize_mode: OptimizeMode,
) Error!bool {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pos: usize = 0;
    var root_list: InstrList = .empty;
    const end_kind = try parseInstrBlock(arena, func.code_bytes, &pos, false, &root_list);
    if (end_kind != .end or pos != func.code_bytes.len) return error.InvalidInput;

    for (0..max_pass_rounds) |_| {
        var changed = false;
        if (eliminateLeafStackCopy(&root_list)) changed = true;
        if (try simplifyLocals(arena, &root_list, optimize_mode)) changed = true;
        if (foldConstants(&root_list)) changed = true;
        if (try simplifyControlFlow(arena, &root_list)) changed = true;
        if (eliminateDeadCode(&root_list)) changed = true;
        if (!changed) break;
    }

    const compacted = compactLocals(arena, module, func, &root_list) catch return error.OutOfMemory;

    var out_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out_buf.deinit(allocator);
    try encodeInstrList(allocator, root_list.items, &out_buf);
    out_buf.append(allocator, 0x0b) catch return error.OutOfMemory;

    const new_bytes = out_buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
    if (func.owns_code_bytes and func.code_bytes.len > 0) {
        allocator.free(func.code_bytes);
    }
    func.code_bytes = new_bytes;
    func.owns_code_bytes = true;
    return compacted;
}

// ── Pass L: Local Simplification and Compaction ──────────────────────────

fn eliminateLeafStackCopy(root_list: *InstrList) bool {
    const items = root_list.items;
    if (items.len < 8) return false;

    // Match stage2_wasm leaf by-value aggregate copy prologue:
    //   0: global.get _       (.raw { 0x23, ... })
    //   1: i32.const n        (n > 0)
    //   2: i32.sub            (.numeric_op 0x6b)
    //   3: local.tee tmp      (.local_tee tmp_local)
    //   4: local.get src      (.local_get src_param, src_param != tmp_local)
    //   5: i32.const n2       (n2 == n)
    //   6: memory.copy 0 0    (.raw { 0xfc, 0x0a, 0x00, 0x00 })
    if (items[0] != .raw or !std.mem.eql(u8, items[0].raw, &.{ 0x23, 0x00 })) return false;
    if (items[1] != .i32_const or items[1].i32_const <= 0) return false;
    const copy_size = items[1].i32_const;
    if (items[2] != .numeric_op or items[2].numeric_op != 0x6b) return false;
    if (items[3] != .local_tee) return false;
    const tmp_local = items[3].local_tee;
    if (items[4] != .local_get) return false;
    const src_param = items[4].local_get;
    if (src_param == tmp_local) return false;
    if (items[5] != .i32_const or items[5].i32_const != copy_size) return false;
    if (items[6] != .raw or !std.mem.eql(u8, items[6].raw, &.{ 0xfc, 0x0a, 0x00, 0x00 })) return false;

    for (items[7..]) |inst| {
        switch (inst) {
            .block, .loop, .if_, .br, .br_if, .br_table, .unreachable_ => return false,
            .call, .return_call, .return_call_indirect => return false,
            .local_set => |idx| if (idx == tmp_local or idx == src_param) return false,
            .local_tee => |idx| if (idx == tmp_local or idx == src_param) return false,
            .raw => |r| {
                if (r.len == 0) return false;
                switch (r[0]) {
                    0x10...0x15, 0x24, 0x36...0x3e, 0x40, 0xfc, 0xfd, 0xfe => return false,
                    else => {},
                }
            },
            else => {},
        }
    }

    for (items[7..]) |*inst| {
        if (inst.* == .local_get and inst.local_get == tmp_local) {
            inst.* = .{ .local_get = src_param };
        }
    }

    const tail_len = items.len - 7;
    std.mem.copyForwards(Instr, root_list.items[0..tail_len], root_list.items[7..]);
    root_list.shrinkRetainingCapacity(tail_len);
    return true;
}

fn isPropagatableInstr(inst: Instr) bool {
    return switch (inst) {
        .i32_const, .i64_const, .ref_func, .local_get => true,
        .raw => |r| r.len > 0 and switch (r[0]) {
            0x43, 0x44, 0xd0 => true,
            else => false,
        },
        else => false,
    };
}

fn isLargeConstantInstr(inst: Instr) bool {
    return switch (inst) {
        .i32_const => |v| v < -64 or v > 63,
        .i64_const => |v| v < -64 or v > 63,
        .raw => |r| r.len > 0 and (r[0] == 0x43 or r[0] == 0x44),
        else => false,
    };
}

fn invalidateLocal(bindings: *std.AutoHashMapUnmanaged(u32, Instr), local_idx: u32) void {
    _ = bindings.remove(local_idx);
    while (true) {
        var victim: ?u32 = null;
        var it = bindings.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .local_get and entry.value_ptr.local_get == local_idx) {
                victim = entry.key_ptr.*;
                break;
            }
        }
        if (victim) |k| {
            _ = bindings.remove(k);
        } else {
            break;
        }
    }
}

fn collectModifiedLocals(
    list: *const InstrList,
    arena: std.mem.Allocator,
    modified: *std.AutoHashMapUnmanaged(u32, void),
) Error!void {
    for (list.items) |inst| {
        switch (inst) {
            .local_set => |x| modified.put(arena, x, {}) catch return error.OutOfMemory,
            .local_tee => |x| modified.put(arena, x, {}) catch return error.OutOfMemory,
            .block => |*b| try collectModifiedLocals(&b.body, arena, modified),
            .loop => |*l| try collectModifiedLocals(&l.body, arena, modified),
            .if_ => |*i| {
                try collectModifiedLocals(&i.then_body, arena, modified);
                if (i.has_else) try collectModifiedLocals(&i.else_body, arena, modified);
            },
            else => {},
        }
    }
}

fn simplifyLocalsBlock(
    arena: std.mem.Allocator,
    list: *InstrList,
    bindings: *std.AutoHashMapUnmanaged(u32, Instr),
    optimize_mode: OptimizeMode,
    initial_reads: *const std.AutoHashMapUnmanaged(u32, u32),
) Error!bool {
    var changed = false;
    var out: InstrList = .empty;
    out.ensureTotalCapacity(arena, list.items.len) catch return error.OutOfMemory;

    for (list.items) |inst| {
        switch (inst) {
            .local_get => |idx| {
                if (out.items.len > 0 and out.items[out.items.len - 1] == .local_set and out.items[out.items.len - 1].local_set == idx) {
                    if (bindings.get(idx)) |repl| {
                        out.append(arena, repl) catch return error.OutOfMemory;
                        changed = true;
                        continue;
                    } else {
                        out.items[out.items.len - 1] = .{ .local_tee = idx };
                        changed = true;
                        continue;
                    }
                }
                if (bindings.get(idx)) |repl| {
                    out.append(arena, repl) catch return error.OutOfMemory;
                    changed = true;
                    continue;
                }
                out.append(arena, inst) catch return error.OutOfMemory;
                continue;
            },
            .local_set => |x| {
                if (out.items.len > 0 and out.items[out.items.len - 1] == .local_get and out.items[out.items.len - 1].local_get == x) {
                    _ = out.pop();
                    changed = true;
                    continue;
                }
                var k: usize = 0;
                while (k < out.items.len and out.items[out.items.len - 1 - k] == .local_set) : (k += 1) {}
                var producer: ?Instr = null;
                if (out.items.len >= 2 * k + 1) {
                    var all_prop = true;
                    for (out.items[out.items.len - 2 * k - 1 .. out.items.len - k]) |item| {
                        if (!isPropagatableInstr(item)) {
                            all_prop = false;
                            break;
                        }
                    }
                    if (all_prop) {
                        const cand = out.items[out.items.len - 2 * k - 1];
                        var valid = true;
                        if (cand == .local_get) {
                            const src = cand.local_get;
                            if (src == x) {
                                valid = false;
                            } else {
                                for (out.items[out.items.len - k ..]) |set_item| {
                                    if (set_item.local_set == src) {
                                        valid = false;
                                        break;
                                    }
                                }
                            }
                        }
                        if (valid) producer = cand;
                    }
                }
                invalidateLocal(bindings, x);
                if (producer) |prod| {
                    const allow_bind = !(optimize_mode == .small and
                        isLargeConstantInstr(prod) and
                        (initial_reads.get(x) orelse 0) > 1);
                    if (allow_bind) {
                        bindings.put(arena, x, prod) catch return error.OutOfMemory;
                    }
                }
                out.append(arena, inst) catch return error.OutOfMemory;
                continue;
            },
            .local_tee => |x| {
                if (out.items.len > 0 and out.items[out.items.len - 1] == .local_get and out.items[out.items.len - 1].local_get == x) {
                    changed = true;
                    continue;
                }
                invalidateLocal(bindings, x);
                if (out.items.len > 0 and isPropagatableInstr(out.items[out.items.len - 1])) {
                    const prev = out.items[out.items.len - 1];
                    const ok = switch (prev) {
                        .local_get => |src| src != x,
                        else => !(optimize_mode == .small and
                            isLargeConstantInstr(prev) and
                            (initial_reads.get(x) orelse 0) > 1),
                    };
                    if (ok) {
                        bindings.put(arena, x, prev) catch return error.OutOfMemory;
                    }
                }
                out.append(arena, inst) catch return error.OutOfMemory;
                continue;
            },
            .block => |b_in| {
                var b = b_in;
                var blk_bindings = bindings.clone(arena) catch return error.OutOfMemory;
                if (try simplifyLocalsBlock(arena, &b.body, &blk_bindings, optimize_mode, initial_reads)) changed = true;
                var modified: std.AutoHashMapUnmanaged(u32, void) = .empty;
                try collectModifiedLocals(&b.body, arena, &modified);
                var mod_it = modified.keyIterator();
                while (mod_it.next()) |k| {
                    invalidateLocal(bindings, k.*);
                }
                out.append(arena, .{ .block = b }) catch return error.OutOfMemory;
                continue;
            },
            .if_ => |if_in| {
                var if_inst = if_in;
                var then_bindings = bindings.clone(arena) catch return error.OutOfMemory;
                if (try simplifyLocalsBlock(arena, &if_inst.then_body, &then_bindings, optimize_mode, initial_reads)) changed = true;
                if (if_inst.has_else) {
                    var else_bindings = bindings.clone(arena) catch return error.OutOfMemory;
                    if (try simplifyLocalsBlock(arena, &if_inst.else_body, &else_bindings, optimize_mode, initial_reads)) changed = true;
                }
                var modified: std.AutoHashMapUnmanaged(u32, void) = .empty;
                try collectModifiedLocals(&if_inst.then_body, arena, &modified);
                if (if_inst.has_else) {
                    try collectModifiedLocals(&if_inst.else_body, arena, &modified);
                }
                var mod_it = modified.keyIterator();
                while (mod_it.next()) |k| {
                    invalidateLocal(bindings, k.*);
                }
                out.append(arena, .{ .if_ = if_inst }) catch return error.OutOfMemory;
                continue;
            },
            .loop => |lp_in| {
                var lp = lp_in;
                var modified: std.AutoHashMapUnmanaged(u32, void) = .empty;
                try collectModifiedLocals(&lp.body, arena, &modified);
                var mod_it = modified.keyIterator();
                while (mod_it.next()) |k| {
                    invalidateLocal(bindings, k.*);
                }
                var lp_bindings = bindings.clone(arena) catch return error.OutOfMemory;
                if (try simplifyLocalsBlock(arena, &lp.body, &lp_bindings, optimize_mode, initial_reads)) changed = true;
                var mod_it2 = modified.keyIterator();
                while (mod_it2.next()) |k| {
                    invalidateLocal(bindings, k.*);
                }
                out.append(arena, .{ .loop = lp }) catch return error.OutOfMemory;
                continue;
            },
            else => {
                out.append(arena, inst) catch return error.OutOfMemory;
                if (inst.isUnconditionalTransfer()) {
                    bindings.clearRetainingCapacity();
                }
                continue;
            },
        }
    }

    list.* = out;
    return changed;
}

fn countLocalReads(
    list: *const InstrList,
    arena: std.mem.Allocator,
    read_counts: *std.AutoHashMapUnmanaged(u32, u32),
) Error!void {
    for (list.items) |inst| {
        switch (inst) {
            .local_get => |x| {
                const gop = read_counts.getOrPutValue(arena, x, 0) catch return error.OutOfMemory;
                gop.value_ptr.* += 1;
            },
            .block => |*b| try countLocalReads(&b.body, arena, read_counts),
            .loop => |*l| try countLocalReads(&l.body, arena, read_counts),
            .if_ => |*i| {
                try countLocalReads(&i.then_body, arena, read_counts);
                if (i.has_else) try countLocalReads(&i.else_body, arena, read_counts);
            },
            else => {},
        }
    }
}

fn eliminateDeadLocalStores(
    arena: std.mem.Allocator,
    list: *InstrList,
    read_counts: *const std.AutoHashMapUnmanaged(u32, u32),
) Error!bool {
    var changed = false;
    var out: InstrList = .empty;
    out.ensureTotalCapacity(arena, list.items.len) catch return error.OutOfMemory;

    for (list.items) |inst| {
        switch (inst) {
            .local_tee => |x| {
                if ((read_counts.get(x) orelse 0) == 0) {
                    changed = true;
                    continue;
                }
                out.append(arena, inst) catch return error.OutOfMemory;
            },
            .local_set => |x| {
                if ((read_counts.get(x) orelse 0) == 0) {
                    if (out.items.len > 0 and isPureZeroPopInstr(out.items[out.items.len - 1])) {
                        _ = out.pop();
                    } else {
                        out.append(arena, .{ .raw = &[_]u8{0x1a} }) catch return error.OutOfMemory;
                    }
                    changed = true;
                    continue;
                }
                out.append(arena, inst) catch return error.OutOfMemory;
            },
            .block => |b_in| {
                var b = b_in;
                if (try eliminateDeadLocalStores(arena, &b.body, read_counts)) changed = true;
                out.append(arena, .{ .block = b }) catch return error.OutOfMemory;
            },
            .loop => |l_in| {
                var l = l_in;
                if (try eliminateDeadLocalStores(arena, &l.body, read_counts)) changed = true;
                out.append(arena, .{ .loop = l }) catch return error.OutOfMemory;
            },
            .if_ => |if_in| {
                var if_inst = if_in;
                if (try eliminateDeadLocalStores(arena, &if_inst.then_body, read_counts)) changed = true;
                if (if_inst.has_else and try eliminateDeadLocalStores(arena, &if_inst.else_body, read_counts)) changed = true;
                out.append(arena, .{ .if_ = if_inst }) catch return error.OutOfMemory;
            },
            else => {
                out.append(arena, inst) catch return error.OutOfMemory;
            },
        }
    }

    list.* = out;
    return changed;
}

fn simplifyLocals(
    arena: std.mem.Allocator,
    root_list: *InstrList,
    optimize_mode: OptimizeMode,
) Error!bool {
    var initial_reads: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    if (optimize_mode == .small) {
        try countLocalReads(root_list, arena, &initial_reads);
    }
    var bindings: std.AutoHashMapUnmanaged(u32, Instr) = .empty;
    var changed = try simplifyLocalsBlock(arena, root_list, &bindings, optimize_mode, &initial_reads);

    while (true) {
        var read_counts: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        try countLocalReads(root_list, arena, &read_counts);
        if (try eliminateDeadLocalStores(arena, root_list, &read_counts)) {
            changed = true;
        } else {
            break;
        }
    }

    return changed;
}

fn markUsedLocals(list: *const InstrList, param_count: u32, used: []bool) void {
    for (list.items) |inst| {
        switch (inst) {
            .local_get, .local_set, .local_tee => |idx| {
                if (idx >= param_count and idx - param_count < used.len) {
                    used[idx - param_count] = true;
                }
            },
            .block => |*b| markUsedLocals(&b.body, param_count, used),
            .loop => |*l| markUsedLocals(&l.body, param_count, used),
            .if_ => |*i| {
                markUsedLocals(&i.then_body, param_count, used);
                if (i.has_else) markUsedLocals(&i.else_body, param_count, used);
            },
            else => {},
        }
    }
}

fn rewriteLocalIndices(list: *InstrList, param_count: u32, remap: []const u32) void {
    for (list.items) |*inst| {
        switch (inst.*) {
            .local_get => |*idx| if (idx.* >= param_count and idx.* - param_count < remap.len) {
                idx.* = remap[idx.* - param_count];
            },
            .local_set => |*idx| if (idx.* >= param_count and idx.* - param_count < remap.len) {
                idx.* = remap[idx.* - param_count];
            },
            .local_tee => |*idx| if (idx.* >= param_count and idx.* - param_count < remap.len) {
                idx.* = remap[idx.* - param_count];
            },
            .block => |*b| rewriteLocalIndices(&b.body, param_count, remap),
            .loop => |*l| rewriteLocalIndices(&l.body, param_count, remap),
            .if_ => |*i| {
                rewriteLocalIndices(&i.then_body, param_count, remap);
                if (i.has_else) rewriteLocalIndices(&i.else_body, param_count, remap);
            },
            else => {},
        }
    }
}

fn compactLocals(
    arena: std.mem.Allocator,
    module: *const Mod.Module,
    func: *Mod.Func,
    root_list: *InstrList,
) std.mem.Allocator.Error!bool {
    const num_locals = func.local_types.items.len;
    if (num_locals == 0) return false;

    const sig = getFuncSignature(module, func) orelse return false;
    const param_count: u32 = @intCast(sig.params.len);

    const used = try arena.alloc(bool, num_locals);
    @memset(used, false);
    markUsedLocals(root_list, param_count, used);

    var all_used = true;
    for (used) |u| {
        if (!u) {
            all_used = false;
            break;
        }
    }
    if (all_used) return false;

    const remap = try arena.alloc(u32, num_locals);
    const has_type_idxs = func.local_type_idxs.items.len == num_locals;
    var write_idx: usize = 0;
    for (0..num_locals) |i| {
        if (used[i]) {
            remap[i] = param_count + @as(u32, @intCast(write_idx));
            func.local_types.items[write_idx] = func.local_types.items[i];
            if (has_type_idxs) {
                func.local_type_idxs.items[write_idx] = func.local_type_idxs.items[i];
            }
            write_idx += 1;
        } else {
            remap[i] = types.invalid_index;
        }
    }
    func.local_types.shrinkRetainingCapacity(write_idx);
    if (has_type_idxs) {
        func.local_type_idxs.shrinkRetainingCapacity(write_idx);
    } else {
        func.local_type_idxs.clearRetainingCapacity();
    }

    rewriteLocalIndices(root_list, param_count, remap);
    return true;
}

// ── Pass A: Constant Folding (i32 and i64) ───────────────────────────────

fn foldI32Unary(a: i32, op: u8) ?Instr {
    const ua: u32 = @bitCast(a);
    return switch (op) {
        0x45 => .{ .i32_const = if (a == 0) 1 else 0 }, // i32.eqz
        0x67 => .{ .i32_const = @intCast(@clz(ua)) }, // i32.clz
        0x68 => .{ .i32_const = @intCast(@ctz(ua)) }, // i32.ctz
        0x69 => .{ .i32_const = @intCast(@popCount(ua)) }, // i32.popcnt
        0xac => .{ .i64_const = @as(i64, a) }, // i64.extend_i32_s
        0xad => .{ .i64_const = @intCast(ua) }, // i64.extend_i32_u
        0xc0 => .{ .i32_const = @as(i32, @as(i8, @truncate(a))) }, // i32.extend8_s
        0xc1 => .{ .i32_const = @as(i32, @as(i16, @truncate(a))) }, // i32.extend16_s
        else => null,
    };
}

fn foldI32Binary(a: i32, b: i32, op: u8) ?Instr {
    const ua: u32 = @bitCast(a);
    const ub: u32 = @bitCast(b);
    const shift: u5 = @truncate(ub);
    return switch (op) {
        0x6a => .{ .i32_const = a +% b }, // i32.add
        0x6b => .{ .i32_const = a -% b }, // i32.sub
        0x6c => .{ .i32_const = a *% b }, // i32.mul
        0x6d => if (b != 0 and !(a == std.math.minInt(i32) and b == -1))
            .{ .i32_const = @divTrunc(a, b) }
        else
            null, // i32.div_s
        0x6e => if (ub != 0) .{ .i32_const = @bitCast(ua / ub) } else null, // i32.div_u
        0x6f => if (b != 0 and !(a == std.math.minInt(i32) and b == -1))
            .{ .i32_const = @rem(a, b) }
        else
            null, // i32.rem_s
        0x70 => if (ub != 0) .{ .i32_const = @bitCast(ua % ub) } else null, // i32.rem_u
        0x71 => .{ .i32_const = a & b }, // i32.and
        0x72 => .{ .i32_const = a | b }, // i32.or
        0x73 => .{ .i32_const = a ^ b }, // i32.xor
        0x74 => .{ .i32_const = @bitCast(ua << shift) }, // i32.shl
        0x75 => .{ .i32_const = a >> shift }, // i32.shr_s
        0x76 => .{ .i32_const = @bitCast(ua >> shift) }, // i32.shr_u
        0x77 => .{ .i32_const = @bitCast(std.math.rotl(u32, ua, shift)) }, // i32.rotl
        0x78 => .{ .i32_const = @bitCast(std.math.rotr(u32, ua, shift)) }, // i32.rotr
        0x46 => .{ .i32_const = if (a == b) 1 else 0 }, // i32.eq
        0x47 => .{ .i32_const = if (a != b) 1 else 0 }, // i32.ne
        0x48 => .{ .i32_const = if (a < b) 1 else 0 }, // i32.lt_s
        0x49 => .{ .i32_const = if (ua < ub) 1 else 0 }, // i32.lt_u
        0x4a => .{ .i32_const = if (a > b) 1 else 0 }, // i32.gt_s
        0x4b => .{ .i32_const = if (ua > ub) 1 else 0 }, // i32.gt_u
        0x4c => .{ .i32_const = if (a <= b) 1 else 0 }, // i32.le_s
        0x4d => .{ .i32_const = if (ua <= ub) 1 else 0 }, // i32.le_u
        0x4e => .{ .i32_const = if (a >= b) 1 else 0 }, // i32.ge_s
        0x4f => .{ .i32_const = if (ua >= ub) 1 else 0 }, // i32.ge_u
        else => null,
    };
}

fn foldI64Unary(a: i64, op: u8) ?Instr {
    const ua: u64 = @bitCast(a);
    return switch (op) {
        0x50 => .{ .i32_const = if (a == 0) 1 else 0 }, // i64.eqz
        0x79 => .{ .i64_const = @intCast(@clz(ua)) }, // i64.clz
        0x7a => .{ .i64_const = @intCast(@ctz(ua)) }, // i64.ctz
        0x7b => .{ .i64_const = @intCast(@popCount(ua)) }, // i64.popcnt
        0xa7 => .{ .i32_const = @bitCast(@as(u32, @truncate(ua))) }, // i32.wrap_i64
        0xc2 => .{ .i64_const = @as(i64, @as(i8, @truncate(a))) }, // i64.extend8_s
        0xc3 => .{ .i64_const = @as(i64, @as(i16, @truncate(a))) }, // i64.extend16_s
        0xc4 => .{ .i64_const = @as(i64, @as(i32, @truncate(a))) }, // i64.extend32_s
        else => null,
    };
}

fn foldI64Binary(a: i64, b: i64, op: u8) ?Instr {
    const ua: u64 = @bitCast(a);
    const ub: u64 = @bitCast(b);
    const shift: u6 = @truncate(ub);
    return switch (op) {
        0x7c => .{ .i64_const = a +% b }, // i64.add
        0x7d => .{ .i64_const = a -% b }, // i64.sub
        0x7e => .{ .i64_const = a *% b }, // i64.mul
        0x7f => if (b != 0 and !(a == std.math.minInt(i64) and b == -1))
            .{ .i64_const = @divTrunc(a, b) }
        else
            null, // i64.div_s
        0x80 => if (ub != 0) .{ .i64_const = @bitCast(ua / ub) } else null, // i64.div_u
        0x81 => if (b != 0 and !(a == std.math.minInt(i64) and b == -1))
            .{ .i64_const = @rem(a, b) }
        else
            null, // i64.rem_s
        0x82 => if (ub != 0) .{ .i64_const = @bitCast(ua % ub) } else null, // i64.rem_u
        0x83 => .{ .i64_const = a & b }, // i64.and
        0x84 => .{ .i64_const = a | b }, // i64.or
        0x85 => .{ .i64_const = a ^ b }, // i64.xor
        0x86 => .{ .i64_const = @bitCast(ua << shift) }, // i64.shl
        0x87 => .{ .i64_const = a >> shift }, // i64.shr_s
        0x88 => .{ .i64_const = @bitCast(ua >> shift) }, // i64.shr_u
        0x89 => .{ .i64_const = @bitCast(std.math.rotl(u64, ua, shift)) }, // i64.rotl
        0x8a => .{ .i64_const = @bitCast(std.math.rotr(u64, ua, shift)) }, // i64.rotr
        0x51 => .{ .i32_const = if (a == b) 1 else 0 }, // i64.eq
        0x52 => .{ .i32_const = if (a != b) 1 else 0 }, // i64.ne
        0x53 => .{ .i32_const = if (a < b) 1 else 0 }, // i64.lt_s
        0x54 => .{ .i32_const = if (ua < ub) 1 else 0 }, // i64.lt_u
        0x55 => .{ .i32_const = if (a > b) 1 else 0 }, // i64.gt_s
        0x56 => .{ .i32_const = if (ua > ub) 1 else 0 }, // i64.gt_u
        0x57 => .{ .i32_const = if (a <= b) 1 else 0 }, // i64.le_s
        0x58 => .{ .i32_const = if (ua <= ub) 1 else 0 }, // i64.le_u
        0x59 => .{ .i32_const = if (a >= b) 1 else 0 }, // i64.ge_s
        0x5a => .{ .i32_const = if (ua >= ub) 1 else 0 }, // i64.ge_u
        else => null,
    };
}

fn isBoolProducer(inst: Instr) bool {
    return switch (inst) {
        .numeric_op => |op| op >= 0x45 and op <= 0x66,
        else => false,
    };
}

fn invertComparisonOp(op: u8) ?u8 {
    return switch (op) {
        0x46 => 0x47, // i32.eq -> i32.ne
        0x47 => 0x46, // i32.ne -> i32.eq
        0x48 => 0x4e, // i32.lt_s -> i32.ge_s
        0x4e => 0x48, // i32.ge_s -> i32.lt_s
        0x49 => 0x4f, // i32.lt_u -> i32.ge_u
        0x4f => 0x49, // i32.ge_u -> i32.lt_u
        0x4a => 0x4c, // i32.gt_s -> i32.le_s
        0x4c => 0x4a, // i32.le_s -> i32.gt_s
        0x4b => 0x4d, // i32.gt_u -> i32.le_u
        0x4d => 0x4b, // i32.le_u -> i32.gt_u
        0x51 => 0x52, // i64.eq -> i64.ne
        0x52 => 0x51, // i64.ne -> i64.eq
        0x53 => 0x59, // i64.lt_s -> i64.ge_s
        0x59 => 0x53, // i64.ge_s -> i64.lt_s
        0x54 => 0x5a, // i64.lt_u -> i64.ge_u
        0x5a => 0x54, // i64.ge_u -> i64.lt_u
        0x55 => 0x57, // i64.gt_s -> i64.le_s
        0x57 => 0x55, // i64.le_s -> i64.gt_s
        0x56 => 0x58, // i64.gt_u -> i64.le_u
        0x58 => 0x56, // i64.le_u -> i64.gt_u
        0x5b => 0x5c, // f32.eq -> f32.ne
        0x5c => 0x5b, // f32.ne -> f32.eq
        0x61 => 0x62, // f64.eq -> f64.ne
        0x62 => 0x61, // f64.ne -> f64.eq
        else => null,
    };
}

fn isPureZeroPopInstr(inst: Instr) bool {
    return switch (inst) {
        .i32_const, .i64_const, .ref_func, .local_get => true,
        .raw => |r| r.len > 0 and switch (r[0]) {
            0x23, 0x43, 0x44, 0xd0 => true,
            else => false,
        },
        else => false,
    };
}

fn emitOrFoldI32Eqz(items: []Instr, out_len: *usize) bool {
    if (out_len.* >= 1) {
        switch (items[out_len.* - 1]) {
            .i32_const => |c| {
                items[out_len.* - 1] = .{ .i32_const = if (c == 0) 1 else 0 };
                return true;
            },
            .numeric_op => |prev_op| {
                if (invertComparisonOp(prev_op)) |inv| {
                    items[out_len.* - 1] = .{ .numeric_op = inv };
                    if (inv == 0x46 and out_len.* >= 2 and items[out_len.* - 2] == .i32_const and items[out_len.* - 2].i32_const == 0) {
                        out_len.* -= 2;
                        _ = emitOrFoldI32Eqz(items, out_len);
                    } else if (inv == 0x51 and out_len.* >= 2 and items[out_len.* - 2] == .i64_const and items[out_len.* - 2].i64_const == 0) {
                        items[out_len.* - 2] = .{ .numeric_op = 0x50 };
                        out_len.* -= 1;
                    }
                    return true;
                }
                if (prev_op == 0x45 and out_len.* >= 2 and isBoolProducer(items[out_len.* - 2])) {
                    out_len.* -= 1;
                    return true;
                }
            },
            else => {},
        }
    }
    items[out_len.*] = .{ .numeric_op = 0x45 };
    out_len.* += 1;
    return false;
}

fn foldConstants(list: *InstrList) bool {
    var changed = false;

    for (list.items) |*inst| {
        switch (inst.*) {
            .block => |*b| {
                if (foldConstants(&b.body)) changed = true;
            },
            .loop => |*l| {
                if (foldConstants(&l.body)) changed = true;
            },
            .if_ => |*i| {
                if (foldConstants(&i.then_body)) changed = true;
                if (i.has_else and foldConstants(&i.else_body)) changed = true;
            },
            else => {},
        }
    }

    var out_len: usize = 0;
    for (list.items) |inst| {
        switch (inst) {
            .numeric_op => |op| {
                if (op == 0x45) {
                    if (emitOrFoldI32Eqz(list.items, &out_len)) {
                        changed = true;
                    }
                    continue;
                }
                if (out_len >= 1) {
                    switch (list.items[out_len - 1]) {
                        .i32_const => |a| {
                            if (foldI32Unary(a, op)) |folded| {
                                list.items[out_len - 1] = folded;
                                changed = true;
                                continue;
                            }
                        },
                        .i64_const => |a| {
                            if (foldI64Unary(a, op)) |folded| {
                                list.items[out_len - 1] = folded;
                                changed = true;
                                continue;
                            }
                        },
                        else => {},
                    }
                }
                if (out_len >= 2) {
                    if (list.items[out_len - 2] == .i32_const and list.items[out_len - 1] == .i32_const) {
                        const a = list.items[out_len - 2].i32_const;
                        const b = list.items[out_len - 1].i32_const;
                        if (foldI32Binary(a, b, op)) |folded| {
                            list.items[out_len - 2] = folded;
                            out_len -= 1;
                            changed = true;
                            continue;
                        }
                    } else if (list.items[out_len - 2] == .i64_const and list.items[out_len - 1] == .i64_const) {
                        const a = list.items[out_len - 2].i64_const;
                        const b = list.items[out_len - 1].i64_const;
                        if (foldI64Binary(a, b, op)) |folded| {
                            list.items[out_len - 2] = folded;
                            out_len -= 1;
                            changed = true;
                            continue;
                        }
                    }
                }

                // Constant reassociation: (x +- c1) +- c2 and associative bitwise
                if (out_len >= 3) {
                    if ((op == 0x6a or op == 0x6b) and
                        list.items[out_len - 1] == .i32_const and
                        list.items[out_len - 2] == .numeric_op and
                        (list.items[out_len - 2].numeric_op == 0x6a or list.items[out_len - 2].numeric_op == 0x6b) and
                        list.items[out_len - 3] == .i32_const)
                    {
                        const c1 = list.items[out_len - 3].i32_const;
                        const op1 = list.items[out_len - 2].numeric_op;
                        const c2 = list.items[out_len - 1].i32_const;
                        const d1: i32 = if (op1 == 0x6a) c1 else 0 -% c1;
                        const d2: i32 = if (op == 0x6a) c2 else 0 -% c2;
                        const total: i32 = d1 +% d2;
                        if (total == 0) {
                            out_len -= 3;
                        } else {
                            list.items[out_len - 3] = .{ .i32_const = total };
                            list.items[out_len - 2] = .{ .numeric_op = 0x6a };
                            out_len -= 1;
                        }
                        changed = true;
                        continue;
                    }
                    if ((op == 0x71 or op == 0x72 or op == 0x73) and
                        list.items[out_len - 1] == .i32_const and
                        list.items[out_len - 2] == .numeric_op and
                        list.items[out_len - 2].numeric_op == op and
                        list.items[out_len - 3] == .i32_const)
                    {
                        const c1 = list.items[out_len - 3].i32_const;
                        const c2 = list.items[out_len - 1].i32_const;
                        const combined: i32 = switch (op) {
                            0x71 => c1 & c2,
                            0x72 => c1 | c2,
                            0x73 => c1 ^ c2,
                            else => unreachable,
                        };
                        const is_identity = switch (op) {
                            0x71 => combined == -1,
                            0x72, 0x73 => combined == 0,
                            else => unreachable,
                        };
                        if (is_identity) {
                            out_len -= 3;
                        } else {
                            list.items[out_len - 3] = .{ .i32_const = combined };
                            out_len -= 1;
                        }
                        changed = true;
                        continue;
                    }
                    if ((op == 0x7c or op == 0x7d) and
                        list.items[out_len - 1] == .i64_const and
                        list.items[out_len - 2] == .numeric_op and
                        (list.items[out_len - 2].numeric_op == 0x7c or list.items[out_len - 2].numeric_op == 0x7d) and
                        list.items[out_len - 3] == .i64_const)
                    {
                        const c1 = list.items[out_len - 3].i64_const;
                        const op1 = list.items[out_len - 2].numeric_op;
                        const c2 = list.items[out_len - 1].i64_const;
                        const d1: i64 = if (op1 == 0x7c) c1 else 0 -% c1;
                        const d2: i64 = if (op == 0x7c) c2 else 0 -% c2;
                        const total: i64 = d1 +% d2;
                        if (total == 0) {
                            out_len -= 3;
                        } else {
                            list.items[out_len - 3] = .{ .i64_const = total };
                            list.items[out_len - 2] = .{ .numeric_op = 0x7c };
                            out_len -= 1;
                        }
                        changed = true;
                        continue;
                    }
                    if ((op == 0x83 or op == 0x84 or op == 0x85) and
                        list.items[out_len - 1] == .i64_const and
                        list.items[out_len - 2] == .numeric_op and
                        list.items[out_len - 2].numeric_op == op and
                        list.items[out_len - 3] == .i64_const)
                    {
                        const c1 = list.items[out_len - 3].i64_const;
                        const c2 = list.items[out_len - 1].i64_const;
                        const combined: i64 = switch (op) {
                            0x83 => c1 & c2,
                            0x84 => c1 | c2,
                            0x85 => c1 ^ c2,
                            else => unreachable,
                        };
                        const is_identity = switch (op) {
                            0x83 => combined == -1,
                            0x84, 0x85 => combined == 0,
                            else => unreachable,
                        };
                        if (is_identity) {
                            out_len -= 3;
                        } else {
                            list.items[out_len - 3] = .{ .i64_const = combined };
                            out_len -= 1;
                        }
                        changed = true;
                        continue;
                    }
                }

                // Single-constant right-operand peepholes
                if (out_len >= 1) {
                    switch (list.items[out_len - 1]) {
                        .i32_const => |rhs| {
                            const rhs_u: u32 = @bitCast(rhs);
                            const shift_amt: u5 = @truncate(rhs_u);
                            switch (op) {
                                0x6a, 0x6b, 0x72 => if (rhs == 0) {
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x73 => {
                                    if (rhs == 0) {
                                        out_len -= 1;
                                        changed = true;
                                        continue;
                                    }
                                    if (rhs == 1 and out_len >= 2 and isBoolProducer(list.items[out_len - 2])) {
                                        out_len -= 1;
                                        _ = emitOrFoldI32Eqz(list.items, &out_len);
                                        changed = true;
                                        continue;
                                    }
                                },
                                0x71 => if (rhs == -1 or (out_len >= 2 and isBoolProducer(list.items[out_len - 2]) and (rhs & 1) == 1)) {
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x74, 0x75, 0x76, 0x77, 0x78 => if (shift_amt == 0) {
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x46 => {
                                    if (rhs == 0) {
                                        out_len -= 1;
                                        _ = emitOrFoldI32Eqz(list.items, &out_len);
                                        changed = true;
                                        continue;
                                    }
                                    if (rhs == 1 and out_len >= 2 and isBoolProducer(list.items[out_len - 2])) {
                                        out_len -= 1;
                                        changed = true;
                                        continue;
                                    }
                                },
                                0x47 => {
                                    if (rhs == 0 and out_len >= 2 and isBoolProducer(list.items[out_len - 2])) {
                                        out_len -= 1;
                                        changed = true;
                                        continue;
                                    }
                                    if (rhs == 1 and out_len >= 2 and isBoolProducer(list.items[out_len - 2])) {
                                        out_len -= 1;
                                        _ = emitOrFoldI32Eqz(list.items, &out_len);
                                        changed = true;
                                        continue;
                                    }
                                },
                                0x6c => {
                                    if (rhs == 1) {
                                        out_len -= 1;
                                        changed = true;
                                        continue;
                                    }
                                    if (rhs_u > 1 and std.math.isPowerOfTwo(rhs_u)) {
                                        list.items[out_len - 1] = .{ .i32_const = @intCast(@ctz(rhs_u)) };
                                        list.items[out_len] = .{ .numeric_op = 0x74 };
                                        out_len += 1;
                                        changed = true;
                                        continue;
                                    }
                                },
                                0x6d => if (rhs == 1) {
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x6e => {
                                    if (rhs_u == 1) {
                                        out_len -= 1;
                                        changed = true;
                                        continue;
                                    }
                                    if (rhs_u > 1 and std.math.isPowerOfTwo(rhs_u)) {
                                        list.items[out_len - 1] = .{ .i32_const = @intCast(@ctz(rhs_u)) };
                                        list.items[out_len] = .{ .numeric_op = 0x76 };
                                        out_len += 1;
                                        changed = true;
                                        continue;
                                    }
                                },
                                0x70 => if (rhs_u >= 1 and std.math.isPowerOfTwo(rhs_u)) {
                                    list.items[out_len - 1] = .{ .i32_const = @bitCast(rhs_u - 1) };
                                    list.items[out_len] = .{ .numeric_op = 0x71 };
                                    out_len += 1;
                                    changed = true;
                                    continue;
                                },
                                else => {},
                            }
                        },
                        .i64_const => |rhs| {
                            const rhs_u: u64 = @bitCast(rhs);
                            const shift_amt: u6 = @truncate(rhs_u);
                            switch (op) {
                                0x7c, 0x7d, 0x84, 0x85 => if (rhs == 0) {
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x83 => if (rhs == -1) {
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x86, 0x87, 0x88, 0x89, 0x8a => if (shift_amt == 0) {
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x51 => if (rhs == 0) {
                                    list.items[out_len - 1] = .{ .numeric_op = 0x50 };
                                    changed = true;
                                    continue;
                                },
                                0x7e => {
                                    if (rhs == 1) {
                                        out_len -= 1;
                                        changed = true;
                                        continue;
                                    }
                                    if (rhs_u > 1 and std.math.isPowerOfTwo(rhs_u)) {
                                        list.items[out_len - 1] = .{ .i64_const = @intCast(@ctz(rhs_u)) };
                                        list.items[out_len] = .{ .numeric_op = 0x86 };
                                        out_len += 1;
                                        changed = true;
                                        continue;
                                    }
                                },
                                0x7f => if (rhs == 1) {
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x80 => {
                                    if (rhs_u == 1) {
                                        out_len -= 1;
                                        changed = true;
                                        continue;
                                    }
                                    if (rhs_u > 1 and std.math.isPowerOfTwo(rhs_u)) {
                                        list.items[out_len - 1] = .{ .i64_const = @intCast(@ctz(rhs_u)) };
                                        list.items[out_len] = .{ .numeric_op = 0x88 };
                                        out_len += 1;
                                        changed = true;
                                        continue;
                                    }
                                },
                                0x82 => if (rhs_u >= 1 and std.math.isPowerOfTwo(rhs_u)) {
                                    list.items[out_len - 1] = .{ .i64_const = @bitCast(rhs_u - 1) };
                                    list.items[out_len] = .{ .numeric_op = 0x83 };
                                    out_len += 1;
                                    changed = true;
                                    continue;
                                },
                                else => {},
                            }
                        },
                        else => {},
                    }
                }

                // Commutative left-constant peepholes when RHS is a pure zero-pop instruction
                if (out_len >= 2 and isPureZeroPopInstr(list.items[out_len - 1])) {
                    const rhs_inst = list.items[out_len - 1];
                    switch (list.items[out_len - 2]) {
                        .i32_const => |lhs| {
                            const lhs_u: u32 = @bitCast(lhs);
                            switch (op) {
                                0x6a, 0x72, 0x73 => if (lhs == 0) {
                                    list.items[out_len - 2] = rhs_inst;
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x71 => if (lhs == -1) {
                                    list.items[out_len - 2] = rhs_inst;
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x46 => if (lhs == 0) {
                                    list.items[out_len - 2] = rhs_inst;
                                    list.items[out_len - 1] = .{ .numeric_op = 0x45 };
                                    changed = true;
                                    continue;
                                },
                                0x6c => {
                                    if (lhs == 1) {
                                        list.items[out_len - 2] = rhs_inst;
                                        out_len -= 1;
                                        changed = true;
                                        continue;
                                    }
                                    if (lhs_u > 1 and std.math.isPowerOfTwo(lhs_u)) {
                                        list.items[out_len - 2] = rhs_inst;
                                        list.items[out_len - 1] = .{ .i32_const = @intCast(@ctz(lhs_u)) };
                                        list.items[out_len] = .{ .numeric_op = 0x74 };
                                        out_len += 1;
                                        changed = true;
                                        continue;
                                    }
                                },
                                else => {},
                            }
                        },
                        .i64_const => |lhs| {
                            const lhs_u: u64 = @bitCast(lhs);
                            switch (op) {
                                0x7c, 0x84, 0x85 => if (lhs == 0) {
                                    list.items[out_len - 2] = rhs_inst;
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x83 => if (lhs == -1) {
                                    list.items[out_len - 2] = rhs_inst;
                                    out_len -= 1;
                                    changed = true;
                                    continue;
                                },
                                0x51 => if (lhs == 0) {
                                    list.items[out_len - 2] = rhs_inst;
                                    list.items[out_len - 1] = .{ .numeric_op = 0x50 };
                                    changed = true;
                                    continue;
                                },
                                0x7e => {
                                    if (lhs == 1) {
                                        list.items[out_len - 2] = rhs_inst;
                                        out_len -= 1;
                                        changed = true;
                                        continue;
                                    }
                                    if (lhs_u > 1 and std.math.isPowerOfTwo(lhs_u)) {
                                        list.items[out_len - 2] = rhs_inst;
                                        list.items[out_len - 1] = .{ .i64_const = @intCast(@ctz(lhs_u)) };
                                        list.items[out_len] = .{ .numeric_op = 0x86 };
                                        out_len += 1;
                                        changed = true;
                                        continue;
                                    }
                                },
                                else => {},
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        list.items[out_len] = inst;
        out_len += 1;
    }
    list.shrinkRetainingCapacity(out_len);
    return changed;
}

// ── Pass B: Control-Flow Simplification ──────────────────────────────────

fn hasBranchToDepth(instrs: []const Instr, target_depth: u32) bool {
    for (instrs) |inst| {
        switch (inst) {
            .br => |l| if (l == target_depth) return true,
            .br_if => |l| if (l == target_depth) return true,
            .br_table => |targets| {
                for (targets) |l| {
                    if (l == target_depth) return true;
                }
            },
            .block => |b| if (hasBranchToDepth(b.body.items, target_depth + 1)) return true,
            .loop => |l| if (hasBranchToDepth(l.body.items, target_depth + 1)) return true,
            .if_ => |i| {
                if (hasBranchToDepth(i.then_body.items, target_depth + 1)) return true;
                if (i.has_else and hasBranchToDepth(i.else_body.items, target_depth + 1)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn canInlineBlock(body: []const Instr) bool {
    for (body) |inst| {
        if (inst.isUnconditionalTransfer()) return false;
    }
    return !hasBranchToDepth(body, 0);
}

fn decrementOuterLabels(instrs: []Instr, min_depth: u32) void {
    for (instrs) |*inst| {
        switch (inst.*) {
            .br => |*l| if (l.* > min_depth) {
                l.* -= 1;
            },
            .br_if => |*l| if (l.* > min_depth) {
                l.* -= 1;
            },
            .br_table => |targets| {
                for (targets) |*l| {
                    if (l.* > min_depth) l.* -= 1;
                }
            },
            .block => |*b| decrementOuterLabels(b.body.items, min_depth + 1),
            .loop => |*l| decrementOuterLabels(l.body.items, min_depth + 1),
            .if_ => |*i| {
                decrementOuterLabels(i.then_body.items, min_depth + 1);
                if (i.has_else) decrementOuterLabels(i.else_body.items, min_depth + 1);
            },
            else => {},
        }
    }
}

fn isBranchFreeStraightLine(instrs: []const Instr) bool {
    for (instrs) |inst| {
        switch (inst) {
            .block, .loop, .if_, .br, .br_if, .br_table, .return_, .unreachable_ => return false,
            else => {},
        }
    }
    return true;
}

fn sliceStackDelta(instrs: []const Instr) ?isize {
    var height: isize = 0;
    for (instrs) |inst| {
        const pops_and_pushes: struct { pops: isize, pushes: isize } = switch (inst) {
            .nop => .{ .pops = 0, .pushes = 0 },
            .local_get, .i32_const, .i64_const, .ref_func => .{ .pops = 0, .pushes = 1 },
            .local_set => .{ .pops = 1, .pushes = 0 },
            .local_tee => .{ .pops = 1, .pushes = 1 },
            .numeric_op => |op| switch (op) {
                0x45, 0x50, 0x67...0x69, 0x79...0x7b, 0x8b...0x91, 0x99...0x9f, 0xa7...0xc4 => .{ .pops = 1, .pushes = 1 },
                0x46...0x4f, 0x51...0x66, 0x6a...0x78, 0x7c...0x8a, 0x92...0x98, 0xa0...0xa6 => .{ .pops = 2, .pushes = 1 },
                else => return null,
            },
            .raw => |r| blk: {
                if (r.len == 0) return null;
                break :blk switch (r[0]) {
                    0x1a, 0x24 => .{ .pops = 1, .pushes = 0 },
                    0x1b, 0x1c => .{ .pops = 3, .pushes = 1 },
                    0x36...0x3e => .{ .pops = 2, .pushes = 0 },
                    0x23, 0x3f, 0x43, 0x44, 0xd0 => .{ .pops = 0, .pushes = 1 },
                    0x28...0x35, 0x40, 0xd1 => .{ .pops = 1, .pushes = 1 },
                    else => return null,
                };
            },
            else => return null,
        };
        if (height < pops_and_pushes.pops) return null;
        height = height - pops_and_pushes.pops + pops_and_pushes.pushes;
    }
    return height;
}

fn stripRedundantCondTests(out: *InstrList) bool {
    var stripped = false;
    while (out.items.len >= 2) {
        const prev = out.items[out.items.len - 2];
        const last = out.items[out.items.len - 1];
        if (prev == .i32_const and prev.i32_const == 0 and last == .numeric_op and last.numeric_op == 0x47) {
            out.items.len -= 2;
            stripped = true;
        } else if (prev == .numeric_op and prev.numeric_op == 0x45 and last == .numeric_op and last.numeric_op == 0x45) {
            out.items.len -= 2;
            stripped = true;
        } else {
            break;
        }
    }
    return stripped;
}

fn simplifyControlFlow(arena: std.mem.Allocator, list: *InstrList) Error!bool {
    var changed = false;

    for (list.items) |*inst| {
        switch (inst.*) {
            .block => |*b| {
                if (try simplifyControlFlow(arena, &b.body)) changed = true;
            },
            .loop => |*l| {
                if (try simplifyControlFlow(arena, &l.body)) changed = true;
            },
            .if_ => |*i| {
                if (try simplifyControlFlow(arena, &i.then_body)) changed = true;
                if (i.has_else and try simplifyControlFlow(arena, &i.else_body)) changed = true;
            },
            else => {},
        }
    }

    var out: InstrList = .empty;
    out.ensureTotalCapacity(arena, list.items.len) catch return error.OutOfMemory;

    for (list.items) |inst| {
        switch (inst) {
            .nop => {
                changed = true;
                continue;
            },
            .br_if => |label| {
                if (stripRedundantCondTests(&out)) {
                    changed = true;
                }
                if (out.items.len > 0 and out.items[out.items.len - 1] == .i32_const) {
                    const cond = out.pop().?.i32_const;
                    changed = true;
                    if (cond != 0) {
                        out.append(arena, .{ .br = label }) catch return error.OutOfMemory;
                    }
                    continue;
                }
            },
            .if_ => |if_inst| {
                if (stripRedundantCondTests(&out)) {
                    changed = true;
                }
                if (out.items.len > 0 and out.items[out.items.len - 1] == .i32_const) {
                    const cond = out.pop().?.i32_const;
                    changed = true;
                    const chosen_body = if (cond != 0) if_inst.then_body else if_inst.else_body;
                    if (canInlineBlock(chosen_body.items)) {
                        decrementOuterLabels(chosen_body.items, 0);
                        out.appendSlice(arena, chosen_body.items) catch return error.OutOfMemory;
                    } else {
                        out.append(arena, .{
                            .block = .{
                                .block_type = if_inst.block_type,
                                .body = chosen_body,
                            },
                        }) catch return error.OutOfMemory;
                    }
                    continue;
                }
            },
            .block => |b_inst| {
                if ((b_inst.block_type.isEmpty() and b_inst.body.items.len == 0) or
                    canInlineBlock(b_inst.body.items))
                {
                    changed = true;
                    decrementOuterLabels(b_inst.body.items, 0);
                    out.appendSlice(arena, b_inst.body.items) catch return error.OutOfMemory;
                    continue;
                }
                if (b_inst.block_type.isEmpty()) {
                    const items = b_inst.body.items;
                    if (items.len == 3 and
                        isPureZeroPopInstr(items[0]) and
                        items[1] == .br_if and items[1].br_if == 0 and
                        items[2] == .unreachable_)
                    {
                        var then_body: InstrList = .empty;
                        then_body.append(arena, .unreachable_) catch return error.OutOfMemory;
                        out.append(arena, items[0]) catch return error.OutOfMemory;
                        out.append(arena, .{ .numeric_op = 0x45 }) catch return error.OutOfMemory;
                        out.append(arena, .{
                            .if_ = .{
                                .block_type = b_inst.block_type,
                                .then_body = then_body,
                            },
                        }) catch return error.OutOfMemory;
                        changed = true;
                        continue;
                    }
                    if (items.len == 4 and
                        isPureZeroPopInstr(items[0]) and
                        items[1] == .numeric_op and items[1].numeric_op == 0x45 and
                        items[2] == .br_if and items[2].br_if == 0 and
                        items[3] == .unreachable_)
                    {
                        var then_body: InstrList = .empty;
                        then_body.append(arena, .unreachable_) catch return error.OutOfMemory;
                        out.append(arena, items[0]) catch return error.OutOfMemory;
                        out.append(arena, .{
                            .if_ = .{
                                .block_type = b_inst.block_type,
                                .then_body = then_body,
                            },
                        }) catch return error.OutOfMemory;
                        changed = true;
                        continue;
                    }
                    if (items.len >= 2 and
                        items[items.len - 1] == .unreachable_ and
                        items[items.len - 2] == .block)
                    {
                        const inner_blk = items[items.len - 2].block;
                        const inner_items = inner_blk.body.items;
                        if (inner_blk.block_type.isEmpty() and
                            inner_items.len >= 3 and
                            inner_items[inner_items.len - 2] == .br_if and inner_items[inner_items.len - 2].br_if == 0 and
                            inner_items[inner_items.len - 1] == .br and inner_items[inner_items.len - 1].br == 1)
                        {
                            const setup_slice = items[0 .. items.len - 2];
                            const cond_slice = inner_items[0 .. inner_items.len - 2];
                            if (isBranchFreeStraightLine(setup_slice) and
                                isBranchFreeStraightLine(cond_slice) and
                                sliceStackDelta(setup_slice) == @as(?isize, 0) and
                                sliceStackDelta(cond_slice) == @as(?isize, 1))
                            {
                                var then_body: InstrList = .empty;
                                then_body.append(arena, .unreachable_) catch return error.OutOfMemory;
                                out.appendSlice(arena, setup_slice) catch return error.OutOfMemory;
                                out.appendSlice(arena, cond_slice) catch return error.OutOfMemory;
                                out.append(arena, .{
                                    .if_ = .{
                                        .block_type = b_inst.block_type,
                                        .then_body = then_body,
                                    },
                                }) catch return error.OutOfMemory;
                                changed = true;
                                continue;
                            }
                        }
                    }
                }
            },
            else => {},
        }
        out.append(arena, inst) catch return error.OutOfMemory;
    }

    list.* = out;
    return changed;
}

// ── Pass C: Dead-Code Elimination (Intrafunction) ────────────────────────

fn eliminateDeadCode(list: *InstrList) bool {
    var changed = false;

    for (list.items, 0..) |*inst, i| {
        switch (inst.*) {
            .block => |*b| {
                if (eliminateDeadCode(&b.body)) changed = true;
            },
            .loop => |*l| {
                if (eliminateDeadCode(&l.body)) changed = true;
            },
            .if_ => |*if_inst| {
                if (eliminateDeadCode(&if_inst.then_body)) changed = true;
                if (if_inst.has_else and eliminateDeadCode(&if_inst.else_body)) changed = true;
            },
            else => {},
        }

        if (inst.isUnconditionalTransfer()) {
            if (i + 1 < list.items.len) {
                list.shrinkRetainingCapacity(i + 1);
                changed = true;
            }
            break;
        }
    }

    return changed;
}

// ── Dead-function removal and index remapping ────────────────────────────

fn markLiveFunc(
    num_funcs: usize,
    live: []bool,
    worklist: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
    idx: u32,
) Error!void {
    if (idx >= num_funcs) return;
    if (!live[idx]) {
        live[idx] = true;
        worklist.append(allocator, idx) catch return error.OutOfMemory;
    }
}

fn scanExprFuncRefs(
    bytes: []const u8,
    num_funcs: usize,
    live: []bool,
    worklist: *std.ArrayListUnmanaged(u32),
    uses_table: *bool,
    allocator: std.mem.Allocator,
) Error!void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const decoded = instr.decode(bytes, &pos) catch return error.InvalidInput;
        if (decoded.prefix == 0 and (decoded.code == 0x10 or decoded.code == 0x12 or decoded.code == 0xd2)) {
            const idx = readU32(bytes, &pos) catch return error.InvalidInput;
            try markLiveFunc(num_funcs, live, worklist, allocator, idx);
        } else {
            if ((decoded.prefix == 0 and (decoded.code == 0x11 or decoded.code == 0x13 or decoded.code == 0x25 or decoded.code == 0x26)) or
                (decoded.prefix == 0xfc and decoded.code >= 12 and decoded.code <= 17))
            {
                uses_table.* = true;
            }
            instr.skipImmediates(decoded.shape, bytes, &pos) catch return error.InvalidInput;
        }
    }
}

fn rewriteExprFuncIndices(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    old_to_new: []const u32,
) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    out.ensureTotalCapacity(allocator, bytes.len) catch return error.OutOfMemory;

    var pos: usize = 0;
    while (pos < bytes.len) {
        const start = pos;
        const decoded = instr.decode(bytes, &pos) catch return error.InvalidInput;
        if (decoded.prefix == 0 and (decoded.code == 0x10 or decoded.code == 0x12 or decoded.code == 0xd2)) {
            const old_idx = readU32(bytes, &pos) catch return error.InvalidInput;
            if (old_idx >= old_to_new.len) return error.InvalidInput;
            const new_idx = old_to_new[old_idx];
            out.append(allocator, @intCast(decoded.code)) catch return error.OutOfMemory;
            try appendU32Leb(allocator, &out, new_idx);
        } else {
            instr.skipImmediates(decoded.shape, bytes, &pos) catch return error.InvalidInput;
            out.appendSlice(allocator, bytes[start..pos]) catch return error.OutOfMemory;
        }
    }

    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

const max_inline_params = 6;
const max_inline_locals = 12;
const max_inline_total_locals = max_inline_params + max_inline_locals;

const TrivialLeaf = struct {
    body_bytes: []const u8 = &.{},
    effective_end: usize = 0,
    op_count: u32 = 0,
    param_types: [max_inline_params]types.ValType = undefined,
    param_count: u8 = 0,
    result_types: [1]types.ValType = undefined,
    result_count: u8 = 0,
    local_types: [max_inline_locals]types.ValType = undefined,
    local_count: u8 = 0,
    prefix_params: u8 = 0,
    leading_end_offsets: [max_inline_params]usize = @splat(0),
    needs_local_zero_init: [max_inline_locals]bool = @splat(false),
    needs_result_block: bool = false,
    has_early_return: bool = false,
};

const TrivialKind = union(enum) {
    none,
    leaf: TrivialLeaf,
    forward: struct {
        callee: u32,
        is_tail: bool,
    },
};

fn getFuncSignature(module: *const Mod.Module, func: *const Mod.Func) ?Mod.FuncSignature {
    if (func.decl.type_var == .index and func.decl.type_var.index < module.module_types.items.len) {
        return switch (module.module_types.items[func.decl.type_var.index]) {
            .func_type => |ft| ft,
            else => null,
        };
    }
    if (func.decl.sig.params.len > 0 or func.decl.sig.results.len > 0) {
        return .{ .params = func.decl.sig.params, .results = func.decl.sig.results };
    }
    return null;
}

fn isTrivialTail(tail: []const u8) bool {
    return std.mem.eql(u8, tail, &.{ 0x0f, 0x0b });
}

fn isZeroInitSupportedType(vt: types.ValType) bool {
    return switch (vt) {
        .i32, .i64, .f32, .f64, .v128, .funcref, .externref => true,
        else => false,
    };
}

fn depth0StackDelta(code: u8) ?i32 {
    return switch (code) {
        0x1a, 0x21, 0x24 => -1,
        0x1b, 0x1c, 0x36...0x3e => -2,
        0x20, 0x23, 0x3f, 0x41...0x44, 0xd0, 0xd2 => 1,
        0x22, 0x28...0x35, 0x40, 0x45, 0x50, 0x67...0x69, 0x79...0x7b, 0x8b...0x91, 0x99...0x9f, 0xa7...0xc4, 0xd1 => 0,
        0x46...0x4f, 0x51...0x66, 0x6a...0x78, 0x7c...0x8a, 0x92...0x98, 0xa0...0xa6 => -1,
        else => null,
    };
}

fn classifyTrivialFunc(
    module: *const Mod.Module,
    fidx: u32,
    func: *const Mod.Func,
    optimize_mode: OptimizeMode,
    call_count: u32,
    is_externally_used: bool,
) TrivialKind {
    if (func.is_import or func.code_bytes.len == 0) return .none;
    if (func.local_types.items.len > max_inline_locals) return .none;
    const sig = getFuncSignature(module, func) orelse return .none;
    if (sig.params.len > max_inline_params or sig.results.len > 1) return .none;

    for (sig.params, 0..) |p, i| {
        if (!isAllowedValType(p, Mod.FuncSignature.concreteIdxAt(sig.param_type_idxs, i))) return .none;
    }
    for (sig.results, 0..) |r, i| {
        if (!isAllowedValType(r, Mod.FuncSignature.concreteIdxAt(sig.result_type_idxs, i))) return .none;
    }
    for (func.local_types.items, 0..) |lt, i| {
        const tidx = if (i < func.local_type_idxs.items.len) func.local_type_idxs.items[i] else types.invalid_index;
        if (!isAllowedValType(lt, tidx) or !isZeroInitSupportedType(lt)) return .none;
    }

    const bytes = func.code_bytes;
    if (bytes[bytes.len - 1] != 0x0b) return .none;

    if (sig.params.len == 0 and func.local_types.items.len == 0) {
        var fpos: usize = 0;
        if (instr.decode(bytes, &fpos)) |decoded| {
            if (decoded.prefix == 0 and (decoded.code == 0x10 or decoded.code == 0x12)) {
                if (readU32(bytes, &fpos)) |callee| {
                    if (isTrivialTail(bytes[fpos..]) and callee < module.funcs.items.len and callee != fidx) {
                        if (getFuncSignature(module, &module.funcs.items[callee])) |callee_sig| {
                            if (Mod.FuncSignature.eql(sig, callee_sig)) {
                                return .{ .forward = .{ .callee = callee, .is_tail = decoded.code == 0x12 } };
                            }
                        }
                    }
                } else |_| {}
            }
        } else |_| {}
    }

    const body_end = bytes.len - 1;
    var effective_end: usize = body_end;
    var pos: usize = 0;
    var depth: u32 = 0;
    var block_types: [32]i64 = undefined;
    var op_count: u32 = 0;
    var depth0_stack: i32 = 0;
    var depth0_stack_exact: bool = true;
    var had_trailing_return: bool = false;

    const param_count: u32 = @intCast(sig.params.len);
    const local_count: u32 = @intCast(func.local_types.items.len);
    const total_locals: u32 = param_count + local_count;

    var local_use_counts: [max_inline_total_locals]u32 = @splat(0);
    var local_written_at_depth0: [max_inline_total_locals]bool = @splat(false);
    var needs_local_zero_init: [max_inline_locals]bool = @splat(false);

    var leading_matched: u8 = 0;
    var leading_still_matching: bool = true;
    var leading_end_offsets: [max_inline_params]usize = @splat(0);

    var needs_result_block: bool = false;
    var has_early_return: bool = false;

    while (pos < body_end) {
        const instr_start = pos;
        const decoded = instr.decode(bytes, &pos) catch return .none;
        if (decoded.prefix == 0) {
            switch (decoded.code) {
                0x01 => {
                    leading_still_matching = false;
                    continue;
                },
                0x0b => {
                    if (depth == 0) return .none;
                    depth -= 1;
                    if (depth == 0) {
                        if (block_types[0] < -64) {
                            depth0_stack += 1;
                        } else if (block_types[0] != -64) {
                            depth0_stack_exact = false;
                        }
                    }
                    leading_still_matching = false;
                    continue;
                },
                0x05 => {
                    if (depth == 0) return .none;
                    leading_still_matching = false;
                    continue;
                },
                else => {},
            }
        }

        op_count += 1;
        if (op_count > 91) return .none;

        if (decoded.prefix == 0) {
            switch (decoded.code) {
                0x10, 0x11, 0x12, 0x13 => return .none,
                0x00 => {
                    if (depth == 0) return .none;
                    leading_still_matching = false;
                    continue;
                },
                0x02, 0x03, 0x04 => {
                    leading_still_matching = false;
                    if (depth >= block_types.len or pos >= body_end) return .none;
                    const bt_byte = bytes[pos];
                    var bt_val: i64 = 0;
                    if (bt_byte == 0x40) {
                        pos += 1;
                        bt_val = -64;
                    } else if (bt_byte < 0x80) {
                        pos += 1;
                        bt_val = -@as(i64, bt_byte);
                        if (depth == 0 and bt_byte < 0x40) {
                            depth0_stack_exact = false;
                        }
                    } else {
                        return .none;
                    }
                    if (depth == 0 and decoded.code == 0x04) {
                        depth0_stack -= 1;
                    }
                    block_types[depth] = bt_val;
                    depth += 1;
                    continue;
                },
                0x0f => {
                    leading_still_matching = false;
                    if (depth == 0 and pos == body_end) {
                        had_trailing_return = true;
                        if (!has_early_return and depth0_stack_exact and depth0_stack == @as(i32, @intCast(sig.results.len))) {
                            effective_end = instr_start;
                            op_count -= 1;
                        } else {
                            has_early_return = true;
                            needs_result_block = true;
                        }
                    } else if (depth > 0 and pos < body_end and (bytes[pos] == 0x0b or bytes[pos] == 0x05)) {
                        has_early_return = true;
                        needs_result_block = true;
                    } else {
                        return .none;
                    }
                    continue;
                },
                0x0c, 0x0d => {
                    leading_still_matching = false;
                    const target = readU32(bytes, &pos) catch return .none;
                    if (target > depth) return .none;
                    if (target == depth) needs_result_block = true;
                    if (depth == 0) {
                        if (decoded.code == 0x0d) {
                            depth0_stack -= 1;
                        } else {
                            depth0_stack_exact = false;
                        }
                    }
                    continue;
                },
                0x0e => {
                    leading_still_matching = false;
                    const count = readU32(bytes, &pos) catch return .none;
                    for (0..@as(usize, count) + 1) |_| {
                        const target = readU32(bytes, &pos) catch return .none;
                        if (target > depth) return .none;
                        if (target == depth) needs_result_block = true;
                    }
                    if (depth == 0) depth0_stack_exact = false;
                    continue;
                },
                0x20 => {
                    const idx = readU32(bytes, &pos) catch return .none;
                    if (idx >= total_locals) return .none;
                    local_use_counts[idx] += 1;
                    if (depth == 0) depth0_stack += 1;
                    if (idx >= param_count and !local_written_at_depth0[idx]) {
                        needs_local_zero_init[idx - param_count] = true;
                    }
                    if (leading_still_matching and
                        depth == 0 and
                        op_count == @as(u32, leading_matched) + 1 and
                        idx == @as(u32, leading_matched) and
                        leading_matched < sig.params.len)
                    {
                        leading_end_offsets[leading_matched] = pos;
                        leading_matched += 1;
                    } else {
                        leading_still_matching = false;
                    }
                    continue;
                },
                0x21, 0x22 => {
                    leading_still_matching = false;
                    const idx = readU32(bytes, &pos) catch return .none;
                    if (idx >= total_locals) return .none;
                    local_use_counts[idx] += 1;
                    if (depth == 0) {
                        local_written_at_depth0[idx] = true;
                        if (decoded.code == 0x21) depth0_stack -= 1;
                    }
                    continue;
                },
                else => {
                    if (depth == 0) {
                        if (depth0StackDelta(@intCast(decoded.code))) |delta| {
                            depth0_stack += delta;
                        } else {
                            depth0_stack_exact = false;
                        }
                    }
                },
            }
        } else if (depth == 0) {
            depth0_stack_exact = false;
        }

        leading_still_matching = false;
        instr.skipImmediates(decoded.shape, bytes, &pos) catch return .none;
    }

    if (pos != body_end or depth != 0) return .none;
    if (sig.params.len == 0 and op_count <= 1 and !had_trailing_return and !std.mem.eql(u8, bytes, &.{ 0x01, 0x0b })) {
        return .none;
    }

    var prefix_params: u8 = 0;
    if (!needs_result_block) {
        while (prefix_params < leading_matched) : (prefix_params += 1) {
            if (local_use_counts[prefix_params] != 1) break;
        }
    }

    switch (optimize_mode) {
        .small => {
            _ = call_count;
            _ = is_externally_used;
            if (op_count > 6 or func.local_types.items.len != 0 or sig.params.len > 2) return .none;
            const allowed_params = sig.params.len == 0 or
                prefix_params == sig.params.len or
                (sig.params.len == 1 and op_count <= 4);
            if (!allowed_params) return .none;
        },
        .fast => {
            if (op_count > 90 or sig.params.len > max_inline_params or func.local_types.items.len > max_inline_locals) return .none;
        },
    }

    var leaf = TrivialLeaf{
        .body_bytes = bytes,
        .effective_end = effective_end,
        .op_count = op_count,
        .param_count = @intCast(sig.params.len),
        .result_count = @intCast(sig.results.len),
        .local_count = @intCast(func.local_types.items.len),
        .prefix_params = prefix_params,
        .leading_end_offsets = leading_end_offsets,
        .needs_local_zero_init = needs_local_zero_init,
        .needs_result_block = needs_result_block,
        .has_early_return = has_early_return,
    };
    @memcpy(leaf.param_types[0..sig.params.len], sig.params);
    @memcpy(leaf.result_types[0..sig.results.len], sig.results);
    @memcpy(leaf.local_types[0..func.local_types.items.len], func.local_types.items);
    return .{ .leaf = leaf };
}

fn markExprExternalRefs(
    bytes: []const u8,
    num_funcs: usize,
    is_externally_used: []bool,
) Error!void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const decoded = instr.decode(bytes, &pos) catch return error.InvalidInput;
        if (decoded.prefix == 0 and (decoded.code == 0x10 or decoded.code == 0x12 or decoded.code == 0xd2)) {
            const idx = readU32(bytes, &pos) catch return error.InvalidInput;
            if (idx < num_funcs) is_externally_used[idx] = true;
        } else {
            instr.skipImmediates(decoded.shape, bytes, &pos) catch return error.InvalidInput;
        }
    }
}

fn inlineTrivialFunctions(
    allocator: std.mem.Allocator,
    module: *Mod.Module,
    optimize_mode: OptimizeMode,
    modified_funcs: []bool,
) Error!bool {
    const num_funcs = module.funcs.items.len;
    if (num_funcs <= module.num_func_imports) return false;

    const call_counts = allocator.alloc(u32, num_funcs) catch return error.OutOfMemory;
    defer allocator.free(call_counts);
    @memset(call_counts, 0);

    const is_externally_used = allocator.alloc(bool, num_funcs) catch return error.OutOfMemory;
    defer allocator.free(is_externally_used);
    @memset(is_externally_used, false);

    for (0..module.num_func_imports) |i| {
        is_externally_used[i] = true;
    }
    for (module.exports.items) |exp| {
        if (exp.kind == .func and exp.var_ == .index and exp.var_.index < num_funcs) {
            is_externally_used[exp.var_.index] = true;
        }
    }
    if (module.start_var) |sv| {
        if (sv == .index and sv.index < num_funcs) {
            is_externally_used[sv.index] = true;
        }
    }
    for (module.elem_segments.items) |seg| {
        for (seg.elem_var_indices.items) |v| {
            if (v == .index and v.index < num_funcs) {
                is_externally_used[v.index] = true;
            }
        }
        if (seg.elem_expr_bytes.len > 0) {
            try markExprExternalRefs(seg.elem_expr_bytes, num_funcs, is_externally_used);
        }
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            try markExprExternalRefs(seg.offset_expr_bytes, num_funcs, is_externally_used);
        }
    }
    for (module.globals.items) |g| {
        if (!g.is_import and g.init_expr_bytes.len > 0) {
            try markExprExternalRefs(g.init_expr_bytes, num_funcs, is_externally_used);
        }
    }
    for (module.tables.items) |t| {
        if (!t.is_import and t.hasInitExpr() and t.init_expr_bytes.len > 0) {
            try markExprExternalRefs(t.init_expr_bytes, num_funcs, is_externally_used);
        }
    }
    for (module.funcs.items[module.num_func_imports..]) |func| {
        if (func.is_import or func.code_bytes.len == 0) continue;
        var pos: usize = 0;
        const bytes = func.code_bytes;
        while (pos < bytes.len) {
            const decoded = instr.decode(bytes, &pos) catch return error.InvalidInput;
            if (decoded.prefix == 0 and (decoded.code == 0x10 or decoded.code == 0x12)) {
                const callee = readU32(bytes, &pos) catch return error.InvalidInput;
                if (callee < num_funcs) call_counts[callee] +|= 1;
            } else if (decoded.prefix == 0 and decoded.code == 0xd2) {
                const idx = readU32(bytes, &pos) catch return error.InvalidInput;
                if (idx < num_funcs) is_externally_used[idx] = true;
            } else {
                instr.skipImmediates(decoded.shape, bytes, &pos) catch return error.InvalidInput;
            }
        }
    }

    const trivials = allocator.alloc(TrivialKind, num_funcs) catch return error.OutOfMemory;
    defer allocator.free(trivials);
    @memset(trivials, .none);

    const orig_forwards = allocator.alloc(TrivialKind, num_funcs) catch return error.OutOfMemory;
    defer allocator.free(orig_forwards);
    @memset(orig_forwards, .none);

    var any_trivial = false;
    for (module.num_func_imports..num_funcs) |i| {
        const kind = classifyTrivialFunc(
            module,
            @intCast(i),
            &module.funcs.items[i],
            optimize_mode,
            call_counts[i],
            is_externally_used[i],
        );
        trivials[i] = kind;
        orig_forwards[i] = kind;
        if (kind != .none) any_trivial = true;
    }
    if (!any_trivial) return false;

    // Resolve forwarding chains (e.g. getFactoryThunk -> host.getFactoryThunk -> export.getFactoryThunk).
    for (module.num_func_imports..num_funcs) |i| {
        if (trivials[i] != .forward) continue;
        var curr = trivials[i].forward.callee;
        const orig_tail = trivials[i].forward.is_tail;
        var chain_single_use: bool = (@as(u32, @intFromBool(is_externally_used[i])) + call_counts[i]) <= 1;
        var resolved: TrivialKind = .none;
        for (0..16) |_| {
            if (curr < module.num_func_imports) {
                resolved = .{ .forward = .{ .callee = curr, .is_tail = orig_tail } };
                break;
            }
            if (is_externally_used[curr] or call_counts[curr] > 1) {
                chain_single_use = false;
            }
            switch (trivials[curr]) {
                .leaf => |leaf| {
                    const small_leaf_ok = (optimize_mode == .fast) or
                        chain_single_use or
                        (leaf.op_count <= 6 and leaf.local_count == 0);
                    if (small_leaf_ok and
                        leaf.param_count == 0 and
                        leaf.local_count == 0 and
                        !leaf.needs_result_block and
                        !leaf.has_early_return)
                    {
                        resolved = .{ .leaf = leaf };
                    } else {
                        resolved = .{ .forward = .{ .callee = curr, .is_tail = orig_tail } };
                    }
                    break;
                },
                .forward => |fwd| {
                    if (fwd.callee == i or fwd.callee == curr) {
                        resolved = .none;
                        break;
                    }
                    curr = fwd.callee;
                },
                .none => {
                    resolved = .{ .forward = .{ .callee = curr, .is_tail = orig_tail } };
                    break;
                },
            }
        }
        trivials[i] = resolved;
    }

    var any_inlined = false;

    for (module.num_func_imports..num_funcs) |i| {
        const func = &module.funcs.items[i];
        if (func.is_import or func.code_bytes.len == 0) continue;

        if (orig_forwards[i] == .forward) {
            switch (trivials[i]) {
                .leaf => |leaf| {
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(module.allocator);
                    out.ensureTotalCapacity(module.allocator, leaf.effective_end + 1) catch return error.OutOfMemory;
                    out.appendSliceAssumeCapacity(leaf.body_bytes[0..leaf.effective_end]);
                    out.appendAssumeCapacity(0x0b);
                    const new_bytes = out.toOwnedSlice(module.allocator) catch return error.OutOfMemory;
                    if (func.owns_code_bytes and func.code_bytes.len > 0) {
                        module.allocator.free(func.code_bytes);
                    }
                    func.code_bytes = new_bytes;
                    func.owns_code_bytes = true;
                    any_inlined = true;
                },
                .forward => |fwd| {
                    if (fwd.callee != orig_forwards[i].forward.callee) {
                        var out: std.ArrayListUnmanaged(u8) = .empty;
                        errdefer out.deinit(module.allocator);
                        out.append(module.allocator, if (fwd.is_tail) 0x12 else 0x10) catch return error.OutOfMemory;
                        try appendU32Leb(module.allocator, &out, fwd.callee);
                        out.append(module.allocator, 0x0b) catch return error.OutOfMemory;
                        const new_bytes = out.toOwnedSlice(module.allocator) catch return error.OutOfMemory;
                        if (func.owns_code_bytes and func.code_bytes.len > 0) {
                            module.allocator.free(func.code_bytes);
                        }
                        func.code_bytes = new_bytes;
                        func.owns_code_bytes = true;
                        any_inlined = true;
                    }
                },
                .none => {},
            }
            continue;
        }

        const caller_sig = getFuncSignature(module, func) orelse continue;
        const caller_param_count: u32 = @intCast(caller_sig.params.len);
        const can_inline_leaves = (optimize_mode == .small) or
            (func.code_bytes.len <= 16384 and func.local_types.items.len <= 512);

        // Check whether this non-trivial function calls any trivial function.
        var has_trivial_call = false;
        {
            var pos: usize = 0;
            const bytes = func.code_bytes;
            while (pos < bytes.len) {
                const decoded = instr.decode(bytes, &pos) catch return error.InvalidInput;
                if (decoded.prefix == 0 and (decoded.code == 0x10 or decoded.code == 0x12)) {
                    const callee = readU32(bytes, &pos) catch return error.InvalidInput;
                    if (callee != i and callee >= module.num_func_imports and callee < num_funcs) {
                        switch (trivials[callee]) {
                            .leaf => if (can_inline_leaves) {
                                has_trivial_call = true;
                                break;
                            },
                            .forward => {
                                has_trivial_call = true;
                                break;
                            },
                            .none => {},
                        }
                    }
                } else {
                    instr.skipImmediates(decoded.shape, bytes, &pos) catch return error.InvalidInput;
                }
            }
        }
        if (!has_trivial_call) continue;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(module.allocator);
        out.ensureTotalCapacity(module.allocator, func.code_bytes.len) catch return error.OutOfMemory;

        var inlined_leaf = false;
        var pos: usize = 0;
        const bytes = func.code_bytes;
        while (pos < bytes.len) {
            const start = pos;
            const decoded = instr.decode(bytes, &pos) catch return error.InvalidInput;
            if (decoded.prefix == 0 and (decoded.code == 0x10 or decoded.code == 0x12)) {
                const callee = readU32(bytes, &pos) catch return error.InvalidInput;
                if (callee != i and callee >= module.num_func_imports and callee < num_funcs) {
                    switch (trivials[callee]) {
                        .leaf => |*leaf| {
                            const needed_locals: usize = (leaf.param_count - leaf.prefix_params) + leaf.local_count;
                            const can_inline_site = switch (optimize_mode) {
                                .small => func.local_types.items.len + needed_locals <= 4096,
                                .fast => out.items.len + (bytes.len - pos) <= 16384 and func.local_types.items.len + needed_locals <= 512,
                            };
                            if (can_inline_site) {
                                var local_map: [max_inline_total_locals]u32 = undefined;
                                for (leaf.prefix_params..leaf.param_count) |p| {
                                    const new_idx: u32 = caller_param_count + @as(u32, @intCast(func.local_types.items.len));
                                    if (func.local_type_idxs.items.len == func.local_types.items.len and func.local_type_idxs.items.len > 0) {
                                        func.local_type_idxs.append(module.allocator, types.invalid_index) catch return error.OutOfMemory;
                                    } else {
                                        func.local_type_idxs.clearRetainingCapacity();
                                    }
                                    func.local_types.append(module.allocator, leaf.param_types[p]) catch return error.OutOfMemory;
                                    local_map[p] = new_idx;
                                }
                                for (0..leaf.local_count) |l| {
                                    const new_idx: u32 = caller_param_count + @as(u32, @intCast(func.local_types.items.len));
                                    if (func.local_type_idxs.items.len == func.local_types.items.len and func.local_type_idxs.items.len > 0) {
                                        func.local_type_idxs.append(module.allocator, types.invalid_index) catch return error.OutOfMemory;
                                    } else {
                                        func.local_type_idxs.clearRetainingCapacity();
                                    }
                                    func.local_types.append(module.allocator, leaf.local_types[l]) catch return error.OutOfMemory;
                                    local_map[leaf.param_count + l] = new_idx;
                                }

                                var p: usize = leaf.param_count;
                                while (p > leaf.prefix_params) {
                                    p -= 1;
                                    out.append(module.allocator, 0x21) catch return error.OutOfMemory;
                                    try appendU32Leb(module.allocator, &out, local_map[p]);
                                }

                                for (0..leaf.local_count) |l| {
                                    if (!leaf.needs_local_zero_init[l]) continue;
                                    switch (leaf.local_types[l]) {
                                        .i32 => out.appendSlice(module.allocator, &.{ 0x41, 0x00 }) catch return error.OutOfMemory,
                                        .i64 => out.appendSlice(module.allocator, &.{ 0x42, 0x00 }) catch return error.OutOfMemory,
                                        .f32 => out.appendSlice(module.allocator, &.{ 0x43, 0, 0, 0, 0 }) catch return error.OutOfMemory,
                                        .f64 => out.appendSlice(module.allocator, &.{ 0x44, 0, 0, 0, 0, 0, 0, 0, 0 }) catch return error.OutOfMemory,
                                        .v128 => out.appendSlice(module.allocator, &([_]u8{ 0xfd, 0x0c } ++ (@as([16]u8, @splat(0))))) catch return error.OutOfMemory,
                                        .funcref => out.appendSlice(module.allocator, &.{ 0xd0, 0x70 }) catch return error.OutOfMemory,
                                        .externref => out.appendSlice(module.allocator, &.{ 0xd0, 0x6f }) catch return error.OutOfMemory,
                                        else => unreachable,
                                    }
                                    out.append(module.allocator, 0x21) catch return error.OutOfMemory;
                                    try appendU32Leb(module.allocator, &out, local_map[leaf.param_count + l]);
                                }

                                if (leaf.needs_result_block) {
                                    out.append(module.allocator, 0x02) catch return error.OutOfMemory;
                                    if (leaf.result_count == 0) {
                                        out.append(module.allocator, 0x40) catch return error.OutOfMemory;
                                    } else {
                                        const vt_byte: u8 = @bitCast(@as(i8, @intCast(@backingInt(leaf.result_types[0]))));
                                        out.append(module.allocator, vt_byte) catch return error.OutOfMemory;
                                    }
                                }

                                const body_start: usize = if (leaf.prefix_params > 0)
                                    leaf.leading_end_offsets[leaf.prefix_params - 1]
                                else
                                    0;
                                var bpos: usize = body_start;
                                var inner_depth: u32 = 0;
                                while (bpos < leaf.effective_end) {
                                    const bstart = bpos;
                                    const bdecoded = instr.decode(leaf.body_bytes, &bpos) catch return error.InvalidInput;
                                    if (bdecoded.prefix == 0) {
                                        switch (bdecoded.code) {
                                            0x02, 0x03, 0x04 => {
                                                inner_depth += 1;
                                                instr.skipImmediates(bdecoded.shape, leaf.body_bytes, &bpos) catch return error.InvalidInput;
                                                out.appendSlice(module.allocator, leaf.body_bytes[bstart..bpos]) catch return error.OutOfMemory;
                                                continue;
                                            },
                                            0x0b => {
                                                if (inner_depth > 0) inner_depth -= 1;
                                                out.append(module.allocator, 0x0b) catch return error.OutOfMemory;
                                                continue;
                                            },
                                            0x20, 0x21, 0x22 => {
                                                const old_local = readU32(leaf.body_bytes, &bpos) catch return error.InvalidInput;
                                                out.append(module.allocator, @intCast(bdecoded.code)) catch return error.OutOfMemory;
                                                try appendU32Leb(module.allocator, &out, local_map[old_local]);
                                                continue;
                                            },
                                            0x0f => {
                                                out.append(module.allocator, 0x0c) catch return error.OutOfMemory;
                                                try appendU32Leb(module.allocator, &out, inner_depth);
                                                continue;
                                            },
                                            else => {},
                                        }
                                    }
                                    instr.skipImmediates(bdecoded.shape, leaf.body_bytes, &bpos) catch return error.InvalidInput;
                                    out.appendSlice(module.allocator, leaf.body_bytes[bstart..bpos]) catch return error.OutOfMemory;
                                }

                                if (leaf.needs_result_block) {
                                    out.append(module.allocator, 0x0b) catch return error.OutOfMemory;
                                }
                                if (decoded.code == 0x12) {
                                    out.append(module.allocator, 0x0f) catch return error.OutOfMemory;
                                }
                                inlined_leaf = true;
                                any_inlined = true;
                                continue;
                            }
                        },
                        .forward => |fwd| {
                            out.append(module.allocator, @intCast(decoded.code)) catch return error.OutOfMemory;
                            try appendU32Leb(module.allocator, &out, fwd.callee);
                            if (fwd.callee != callee) any_inlined = true;
                            continue;
                        },
                        .none => {},
                    }
                }
                out.appendSlice(module.allocator, bytes[start..pos]) catch return error.OutOfMemory;
            } else {
                instr.skipImmediates(decoded.shape, bytes, &pos) catch return error.InvalidInput;
                out.appendSlice(module.allocator, bytes[start..pos]) catch return error.OutOfMemory;
            }
        }

        const new_bytes = out.toOwnedSlice(module.allocator) catch return error.OutOfMemory;
        if (func.owns_code_bytes and func.code_bytes.len > 0) {
            module.allocator.free(func.code_bytes);
        }
        func.code_bytes = new_bytes;
        func.owns_code_bytes = true;

        if (inlined_leaf) {
            modified_funcs[i] = true;
        }
    }

    return any_inlined;
}

fn removeDeadFunctions(
    allocator: std.mem.Allocator,
    module: *Mod.Module,
    locals_compacted: []const bool,
) Error!void {
    const num_funcs = module.funcs.items.len;
    if (num_funcs <= module.num_func_imports) return;

    var any_locals_compacted = false;
    for (locals_compacted) |c| {
        if (c) {
            any_locals_compacted = true;
            break;
        }
    }

    const live = allocator.alloc(bool, num_funcs) catch return error.OutOfMemory;
    defer allocator.free(live);
    @memset(live, false);

    var worklist: std.ArrayListUnmanaged(u32) = .empty;
    defer worklist.deinit(allocator);

    for (0..module.num_func_imports) |i| {
        try markLiveFunc(num_funcs, live, &worklist, allocator, @intCast(i));
    }

    var uses_table = module.num_table_imports > 0;
    for (module.exports.items) |exp| {
        if (exp.kind == .func and exp.var_ == .index) {
            try markLiveFunc(num_funcs, live, &worklist, allocator, exp.var_.index);
        } else if (exp.kind == .table) {
            uses_table = true;
        }
    }

    if (module.start_var) |sv| {
        if (sv == .index) {
            try markLiveFunc(num_funcs, live, &worklist, allocator, sv.index);
        }
    }

    for (module.globals.items) |global| {
        if (!global.is_import and global.init_expr_bytes.len > 0) {
            try scanExprFuncRefs(global.init_expr_bytes, num_funcs, live, &worklist, &uses_table, allocator);
        }
    }

    for (module.tables.items) |table| {
        if (!table.is_import and table.hasInitExpr() and table.init_expr_bytes.len > 0) {
            try scanExprFuncRefs(table.init_expr_bytes, num_funcs, live, &worklist, &uses_table, allocator);
        }
    }

    for (module.data_segments.items) |seg| {
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            try scanExprFuncRefs(seg.offset_expr_bytes, num_funcs, live, &worklist, &uses_table, allocator);
        }
    }

    var elems_seeded = false;
    while (true) {
        if (uses_table and !elems_seeded) {
            elems_seeded = true;
            for (module.elem_segments.items) |seg| {
                for (seg.elem_var_indices.items) |v| {
                    if (v == .index and v.index != types.invalid_index) {
                        try markLiveFunc(num_funcs, live, &worklist, allocator, v.index);
                    }
                }
                if (seg.elem_expr_bytes.len > 0) {
                    try scanExprFuncRefs(seg.elem_expr_bytes, num_funcs, live, &worklist, &uses_table, allocator);
                }
                if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
                    try scanExprFuncRefs(seg.offset_expr_bytes, num_funcs, live, &worklist, &uses_table, allocator);
                }
            }
        }
        const fidx = worklist.pop() orelse {
            if (uses_table and !elems_seeded) continue;
            break;
        };
        if (fidx < module.num_func_imports or fidx >= num_funcs) continue;
        const func = module.funcs.items[fidx];
        if (func.code_bytes.len > 0) {
            try scanExprFuncRefs(func.code_bytes, num_funcs, live, &worklist, &uses_table, allocator);
        }
    }

    if (!elems_seeded) {
        for (module.elem_segments.items) |*seg| {
            seg.elem_var_indices.deinit(module.allocator);
            if (seg.owns_offset_expr_bytes and seg.offset_expr_bytes.len > 0) {
                module.allocator.free(seg.offset_expr_bytes);
            }
            if (seg.owns_elem_expr_bytes and seg.elem_expr_bytes.len > 0) {
                module.allocator.free(seg.elem_expr_bytes);
            }
        }
        module.elem_segments.clearRetainingCapacity();

        for (module.tables.items) |*table| {
            if (table.owns_init_expr_bytes and table.init_expr_bytes.len > 0) {
                module.allocator.free(table.init_expr_bytes);
            }
        }
        module.tables.clearRetainingCapacity();
    }

    var all_live = true;
    for (live) |is_live| {
        if (!is_live) {
            all_live = false;
            break;
        }
    }
    if (all_live and !any_locals_compacted) return;

    const old_to_new = allocator.alloc(u32, num_funcs) catch return error.OutOfMemory;
    defer allocator.free(old_to_new);
    var next_idx: u32 = 0;
    for (0..num_funcs) |i| {
        if (live[i]) {
            old_to_new[i] = next_idx;
            next_idx += 1;
        } else {
            old_to_new[i] = types.invalid_index;
        }
    }

    if (all_live) {
        if (module.customs.items.len > 0) {
            var custom_write_idx: usize = 0;
            for (module.customs.items) |custom| {
                if (!std.mem.eql(u8, custom.name, "name")) {
                    module.customs.items[custom_write_idx] = custom;
                    custom_write_idx += 1;
                    continue;
                }
                if (rewriteNameSectionPayload(module.allocator, custom.data, old_to_new, locals_compacted, any_locals_compacted)) |rewritten| {
                    if (custom.owns_data and custom.data.len > 0) {
                        module.allocator.free(custom.data);
                    }
                    var updated = custom;
                    updated.data = rewritten;
                    updated.owns_data = true;
                    module.customs.items[custom_write_idx] = updated;
                    custom_write_idx += 1;
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidNameSection => {
                        if (custom.owns_data and custom.data.len > 0) {
                            module.allocator.free(custom.data);
                        }
                    },
                }
            }
            module.customs.shrinkRetainingCapacity(custom_write_idx);
        }
        return;
    }

    // Rewrite function indices in live defined functions before compacting module.funcs.
    for (module.funcs.items, 0..) |*func, i| {
        if (!live[i] or i < module.num_func_imports or func.code_bytes.len == 0) continue;
        const rewritten = try rewriteExprFuncIndices(module.allocator, func.code_bytes, old_to_new);
        if (func.owns_code_bytes and func.code_bytes.len > 0) {
            module.allocator.free(func.code_bytes);
        }
        func.code_bytes = rewritten;
        func.owns_code_bytes = true;
    }

    for (module.elem_segments.items) |*seg| {
        for (seg.elem_var_indices.items) |*v| {
            if (v.* == .index and v.index < num_funcs) {
                v.index = old_to_new[v.index];
            }
        }
        if (seg.elem_expr_bytes.len > 0) {
            const rewritten = try rewriteExprFuncIndices(module.allocator, seg.elem_expr_bytes, old_to_new);
            if (seg.owns_elem_expr_bytes and seg.elem_expr_bytes.len > 0) {
                module.allocator.free(seg.elem_expr_bytes);
            }
            seg.elem_expr_bytes = rewritten;
            seg.owns_elem_expr_bytes = true;
        }
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            const rewritten = try rewriteExprFuncIndices(module.allocator, seg.offset_expr_bytes, old_to_new);
            if (seg.owns_offset_expr_bytes and seg.offset_expr_bytes.len > 0) {
                module.allocator.free(seg.offset_expr_bytes);
            }
            seg.offset_expr_bytes = rewritten;
            seg.owns_offset_expr_bytes = true;
        }
    }

    for (module.globals.items) |*global| {
        if (!global.is_import and global.init_expr_bytes.len > 0) {
            const rewritten = try rewriteExprFuncIndices(module.allocator, global.init_expr_bytes, old_to_new);
            if (global.owns_init_expr_bytes and global.init_expr_bytes.len > 0) {
                module.allocator.free(global.init_expr_bytes);
            }
            global.init_expr_bytes = rewritten;
            global.owns_init_expr_bytes = true;
        }
    }

    for (module.tables.items) |*table| {
        if (!table.is_import and table.hasInitExpr() and table.init_expr_bytes.len > 0) {
            const rewritten = try rewriteExprFuncIndices(module.allocator, table.init_expr_bytes, old_to_new);
            if (table.owns_init_expr_bytes and table.init_expr_bytes.len > 0) {
                module.allocator.free(table.init_expr_bytes);
            }
            table.init_expr_bytes = rewritten;
            table.owns_init_expr_bytes = true;
        }
    }

    for (module.data_segments.items) |*seg| {
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            const rewritten = try rewriteExprFuncIndices(module.allocator, seg.offset_expr_bytes, old_to_new);
            if (seg.owns_offset_expr_bytes and seg.offset_expr_bytes.len > 0) {
                module.allocator.free(seg.offset_expr_bytes);
            }
            seg.offset_expr_bytes = rewritten;
            seg.owns_offset_expr_bytes = true;
        }
    }

    for (module.exports.items) |*exp| {
        if (exp.kind == .func and exp.var_ == .index and exp.var_.index < num_funcs) {
            exp.var_.index = old_to_new[exp.var_.index];
        }
    }

    if (module.start_var) |*sv| {
        if (sv.* == .index and sv.index < num_funcs) {
            sv.index = old_to_new[sv.index];
        }
    }

    if (next_idx != num_funcs and module.customs.items.len > 0) {
        var custom_write_idx: usize = 0;
        for (module.customs.items) |custom| {
            if (!std.mem.eql(u8, custom.name, "name")) {
                module.customs.items[custom_write_idx] = custom;
                custom_write_idx += 1;
                continue;
            }
            if (rewriteNameSectionPayload(module.allocator, custom.data, old_to_new, locals_compacted, any_locals_compacted)) |rewritten| {
                if (custom.owns_data and custom.data.len > 0) {
                    module.allocator.free(custom.data);
                }
                var updated = custom;
                updated.data = rewritten;
                updated.owns_data = true;
                module.customs.items[custom_write_idx] = updated;
                custom_write_idx += 1;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidNameSection => {
                    if (custom.owns_data and custom.data.len > 0) {
                        module.allocator.free(custom.data);
                    }
                },
            }
        }
        module.customs.shrinkRetainingCapacity(custom_write_idx);
    }

    var write_idx: usize = 0;
    for (module.funcs.items, 0..) |*func, i| {
        if (live[i]) {
            module.funcs.items[write_idx] = func.*;
            write_idx += 1;
        } else {
            func.local_types.deinit(module.allocator);
            func.local_type_idxs.deinit(module.allocator);
            if (func.owns_code_bytes and func.code_bytes.len > 0) {
                module.allocator.free(func.code_bytes);
            }
        }
    }
    module.funcs.shrinkRetainingCapacity(write_idx);
}

const RewriteNameSectionError = std.mem.Allocator.Error || error{InvalidNameSection};

fn rewriteNameSectionPayload(
    allocator: std.mem.Allocator,
    data: []const u8,
    old_to_new: []const u32,
    locals_compacted: []const bool,
    any_locals_compacted: bool,
) RewriteNameSectionError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var entries_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer entries_buf.deinit(allocator);

    var pos: usize = 0;
    while (pos < data.len) {
        const subsec_id = data[pos];
        pos += 1;
        const subsec_size = readU32(data, &pos) catch return error.InvalidNameSection;
        if (subsec_size > data.len - pos) return error.InvalidNameSection;
        const subsec_body = data[pos .. pos + subsec_size];
        pos += subsec_size;

        switch (subsec_id) {
            1 => {
                entries_buf.clearRetainingCapacity();
                var sub_pos: usize = 0;
                const count = readU32(subsec_body, &sub_pos) catch return error.InvalidNameSection;
                var surviving_count: u32 = 0;
                for (0..count) |_| {
                    const func_idx = readU32(subsec_body, &sub_pos) catch return error.InvalidNameSection;
                    const name_len = readU32(subsec_body, &sub_pos) catch return error.InvalidNameSection;
                    if (name_len > subsec_body.len - sub_pos) return error.InvalidNameSection;
                    const name_bytes = subsec_body[sub_pos .. sub_pos + name_len];
                    sub_pos += name_len;

                    if (func_idx < old_to_new.len and old_to_new[func_idx] != types.invalid_index) {
                        try appendU32Leb(allocator, &entries_buf, old_to_new[func_idx]);
                        try appendU32Leb(allocator, &entries_buf, name_len);
                        try entries_buf.appendSlice(allocator, name_bytes);
                        surviving_count += 1;
                    }
                }
                if (sub_pos != subsec_body.len) return error.InvalidNameSection;

                var count_tmp: [leb128.max_u32_bytes]u8 = undefined;
                const count_len = leb128.writeU32Leb128(&count_tmp, surviving_count);
                const new_subsec_size: u32 = @intCast(count_len + entries_buf.items.len);
                try out.append(allocator, subsec_id);
                try appendU32Leb(allocator, &out, new_subsec_size);
                try out.appendSlice(allocator, count_tmp[0..count_len]);
                try out.appendSlice(allocator, entries_buf.items);
            },
            2, 3 => {
                entries_buf.clearRetainingCapacity();
                var sub_pos: usize = 0;
                const count = readU32(subsec_body, &sub_pos) catch return error.InvalidNameSection;
                var surviving_count: u32 = 0;
                for (0..count) |_| {
                    const func_idx = readU32(subsec_body, &sub_pos) catch return error.InvalidNameSection;
                    const inner_start = sub_pos;
                    const inner_count = readU32(subsec_body, &sub_pos) catch return error.InvalidNameSection;
                    for (0..inner_count) |_| {
                        _ = readU32(subsec_body, &sub_pos) catch return error.InvalidNameSection;
                        const name_len = readU32(subsec_body, &sub_pos) catch return error.InvalidNameSection;
                        if (name_len > subsec_body.len - sub_pos) return error.InvalidNameSection;
                        sub_pos += name_len;
                    }
                    const inner_bytes = subsec_body[inner_start..sub_pos];

                    const keep_entry = func_idx < old_to_new.len and
                        old_to_new[func_idx] != types.invalid_index and
                        !(subsec_id == 2 and func_idx < locals_compacted.len and locals_compacted[func_idx]);
                    if (keep_entry) {
                        try appendU32Leb(allocator, &entries_buf, old_to_new[func_idx]);
                        try entries_buf.appendSlice(allocator, inner_bytes);
                        surviving_count += 1;
                    }
                }
                if (sub_pos != subsec_body.len) return error.InvalidNameSection;

                if (surviving_count > 0 or !(subsec_id == 2 and any_locals_compacted)) {
                    var count_tmp: [leb128.max_u32_bytes]u8 = undefined;
                    const count_len = leb128.writeU32Leb128(&count_tmp, surviving_count);
                    const new_subsec_size: u32 = @intCast(count_len + entries_buf.items.len);
                    try out.append(allocator, subsec_id);
                    try appendU32Leb(allocator, &out, new_subsec_size);
                    try out.appendSlice(allocator, count_tmp[0..count_len]);
                    try out.appendSlice(allocator, entries_buf.items);
                }
            },
            else => {
                try out.append(allocator, subsec_id);
                try appendU32Leb(allocator, &out, subsec_size);
                try out.appendSlice(allocator, subsec_body);
            },
        }
    }

    return try out.toOwnedSlice(allocator);
}

// ── Unit Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn buildSingleFuncModule(
    allocator: std.mem.Allocator,
    params: []const types.ValType,
    results: []const types.ValType,
    locals: []const types.ValType,
    code_bytes: []const u8,
) ![]u8 {
    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    const p_copy = try allocator.dupe(types.ValType, params);
    const r_copy = try allocator.dupe(types.ValType, results);
    try mod.module_types.append(allocator, .{ .func_type = .{ .params = p_copy, .results = r_copy } });
    try mod.type_meta.append(allocator, .{});

    var func = Mod.Func{
        .decl = .{
            .type_var = .{ .index = 0 },
            .sig = .{ .params = p_copy, .results = r_copy },
        },
        .code_bytes = code_bytes,
    };
    try func.local_types.appendSlice(allocator, locals);
    try mod.funcs.append(allocator, func);
    try mod.exports.append(allocator, .{
        .name = "f",
        .kind = .func,
        .var_ = .{ .index = 0 },
    });

    return try writer.writeModule(allocator, &mod);
}

test "Optimizer: i32 and i64 constant folding" {
    const allocator = testing.allocator;
    // (i32.add (i32.mul (i32.const 6) (i32.const 7)) (i32.sub (i32.const 10) (i32.const 2))) -> i32.const 50
    const code = [_]u8{
        0x41, 0x06, // i32.const 6
        0x41, 0x07, // i32.const 7
        0x6c, // i32.mul
        0x41, 0x0a, // i32.const 10
        0x41, 0x02, // i32.const 2
        0x6b, // i32.sub
        0x6a, // i32.add
        0x0b, // end
    };
    const wasm = try buildSingleFuncModule(allocator, &.{}, &.{.i32}, &.{}, &code);
    defer allocator.free(wasm);

    const opt_bytes = try optimize(allocator, wasm, .{});
    defer allocator.free(opt_bytes);

    var mod = try reader.readModule(allocator, opt_bytes);
    defer mod.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 50, 0x0b }, mod.funcs.items[0].code_bytes);
}

test "Optimizer: control-flow simplification and intrafunction DCE" {
    const allocator = testing.allocator;
    // nop, (block (result i32) (i32.const 1) (if (result i32) (then (i32.const 42)) (else (i32.const 99)))), return, i32.const 77
    const code = [_]u8{
        0x01, // nop
        0x02, 0x7f, // block (result i32)
        0x41, 0x01, // i32.const 1
        0x04, 0x7f, // if (result i32)
        0x41, 42, // i32.const 42
        0x05, // else
        0x41, 99, // i32.const 99
        0x0b, // end if
        0x0b, // end block
        0x0f, // return
        0x41, 77, // dead i32.const 77
        0x0b, // end func
    };
    const wasm = try buildSingleFuncModule(allocator, &.{}, &.{.i32}, &.{}, &code);
    defer allocator.free(wasm);

    const opt_bytes = try optimize(allocator, wasm, .{});
    defer allocator.free(opt_bytes);

    var mod = try reader.readModule(allocator, opt_bytes);
    defer mod.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 42, 0x0f, 0x0b }, mod.funcs.items[0].code_bytes);
}

test "Optimizer: dead-function removal prunes unreachable stubs and remaps indices" {
    const allocator = testing.allocator;
    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    const r_copy = try allocator.dupe(types.ValType, &.{.i32});
    try mod.module_types.append(allocator, .{ .func_type = .{ .params = &.{}, .results = r_copy } });
    try mod.type_meta.append(allocator, .{});

    const sig = types.FuncType{ .params = &.{}, .results = r_copy };
    // func 0: dead Zig-style stub (unreachable; end)
    try mod.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 }, .sig = sig },
        .code_bytes = &[_]u8{ 0x00, 0x0b },
    });
    // func 1: live helper returning 42
    try mod.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 }, .sig = sig },
        .code_bytes = &[_]u8{ 0x41, 42, 0x0b },
    });
    // func 2: exported caller calling func 1
    try mod.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 }, .sig = sig },
        .code_bytes = &[_]u8{ 0x10, 0x01, 0x0b },
    });
    try mod.exports.append(allocator, .{
        .name = "main",
        .kind = .func,
        .var_ = .{ .index = 2 },
    });

    const wasm = try writer.writeModule(allocator, &mod);
    defer allocator.free(wasm);

    const opt_bytes = try optimize(allocator, wasm, .{});
    defer allocator.free(opt_bytes);

    var opt_mod = try reader.readModule(allocator, opt_bytes);
    defer opt_mod.deinit();

    try testing.expectEqual(@as(usize, 2), opt_mod.funcs.items.len);
    try testing.expectEqual(@as(u32, 1), opt_mod.exports.items[0].var_.index);
    // func 1 (was func 2) now calls func 0 (was func 1)
    try testing.expectEqualSlices(u8, &[_]u8{ 0x10, 0x00, 0x0b }, opt_mod.funcs.items[1].code_bytes);
}

test "Optimizer: CustomSectionPolicy.preserve and SIMD/atomics passthrough" {
    const allocator = testing.allocator;
    // Function with v128 local, 0xfe memory.atomic.notify, and foldable i32.add
    const code = [_]u8{
        0x41, 0x00, // i32.const 0
        0x41, 0x01, // i32.const 1
        0xfe, 0x00, 0x02, 0x00, // memory.atomic.notify align=2 offset=0
        0x1a, // drop
        0x41, 20, // i32.const 20
        0x41, 22, // i32.const 22
        0x6a, // i32.add -> 42
        0x0b, // end
    };

    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    const r_copy = try allocator.dupe(types.ValType, &.{.i32});
    try mod.module_types.append(allocator, .{ .func_type = .{ .params = &.{}, .results = r_copy } });
    try mod.type_meta.append(allocator, .{});

    try mod.memories.append(allocator, .{
        .type = .{ .limits = .{ .initial = 1, .max = 2, .has_max = true, .is_shared = true } },
    });

    var func = Mod.Func{
        .decl = .{ .type_var = .{ .index = 0 }, .sig = .{ .params = &.{}, .results = r_copy } },
        .code_bytes = &code,
    };
    try func.local_types.append(allocator, .v128);
    try mod.funcs.append(allocator, func);
    try mod.exports.append(allocator, .{ .name = "f", .kind = .func, .var_ = .{ .index = 0 } });
    try mod.customs.append(allocator, .{ .name = "component-type:world", .data = &[_]u8{ 1, 2, 3 } });

    const wasm = try writer.writeModule(allocator, &mod);
    defer allocator.free(wasm);

    const opt_bytes = try optimize(allocator, wasm, .{ .custom_sections = .preserve });
    defer allocator.free(opt_bytes);

    var opt_mod = try reader.readModule(allocator, opt_bytes);
    defer opt_mod.deinit();

    try testing.expectEqual(@as(usize, 1), opt_mod.customs.items.len);
    try testing.expectEqualStrings("component-type:world", opt_mod.customs.items[0].name);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x41, 0x00, 0x41, 0x01, 0xfe, 0x00, 0x02, 0x00, 0x1a, 0x41, 42, 0x0b },
        opt_mod.funcs.items[0].code_bytes,
    );
}

test "Optimizer: CustomSectionPolicy.preserve rewrites name section on dead-function removal" {
    const allocator = testing.allocator;
    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    const r_copy = try allocator.dupe(types.ValType, &.{.i32});
    try mod.module_types.append(allocator, .{ .func_type = .{ .params = &.{}, .results = r_copy } });
    try mod.type_meta.append(allocator, .{});

    const sig = types.FuncType{ .params = &.{}, .results = r_copy };

    // func 0: imported function
    try mod.imports.append(allocator, .{
        .module_name = "env",
        .field_name = "imp",
        .kind = .func,
        .func = .{ .type_var = .{ .index = 0 }, .sig = sig },
    });
    try mod.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 }, .sig = sig },
        .is_import = true,
    });
    mod.num_func_imports = 1;

    // func 1: dead function
    try mod.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 }, .sig = sig },
        .code_bytes = &[_]u8{ 0x00, 0x0b },
    });

    // func 2: live helper returning 42
    try mod.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 }, .sig = sig },
        .code_bytes = &[_]u8{ 0x41, 42, 0x0b },
    });

    // func 3: exported caller calling func 0 and func 2
    try mod.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 }, .sig = sig },
        .code_bytes = &[_]u8{ 0x10, 0x00, 0x1a, 0x10, 0x02, 0x0b },
    });

    try mod.exports.append(allocator, .{
        .name = "main",
        .kind = .func,
        .var_ = .{ .index = 3 },
    });

    // Build a "name" custom section with:
    // - subsec 0 (module name): "m"
    // - subsec 1 (function names): 0->"imp", 1->"dead", 2->"live", 3->"main"
    // - subsec 2 (local names): 1->{0->"d0"}, 2->{0->"l0", 1->"l1"}, 3->{0->"m0"}
    // - subsec 7 (global names): 0->"g0"
    // - subsec 9 (data segment names): 0->"dseg"
    const name_payload = [_]u8{
        // subsec 0: module name "m"
        0x00, 0x02, 0x01, 'm',
        // subsec 1: 4 entries:
        // (0, 3, "imp") = 5 bytes
        // (1, 4, "dead") = 6 bytes
        // (2, 4, "live") = 6 bytes
        // (3, 4, "main") = 6 bytes
        // count (1) + 5 + 6 + 6 + 6 = 24 (0x18)
        0x01, 24,   0x04, 0x00,
        0x03, 'i',  'm',  'p',
        0x01, 0x04, 'd',  'e',
        'a',  'd',  0x02, 0x04,
        'l',  'i',  'v',  'e',
        0x03, 0x04, 'm',  'a',
        'i',  'n',
        // subsec 2: 3 entries:
        // func 1: count 1, (0, 2, "d0") -> 1 + 1 + 4 = 6 bytes
        // func 2: count 2, (0, 2, "l0"), (1, 2, "l1") -> 1 + 1 + 4 + 4 = 10 bytes
        // func 3: count 1, (0, 2, "m0") -> 1 + 1 + 4 = 6 bytes
        // count (1) + 6 + 10 + 6 = 23 (0x17)
         0x02, 23,
        0x03, 0x01, 0x01, 0x00,
        0x02, 'd',  '0',  0x02,
        0x02, 0x00, 0x02, 'l',
        '0',  0x01, 0x02, 'l',
        '1',  0x03, 0x01, 0x00,
        0x02, 'm',  '0',
        // subsec 7: global names: count 1, (0, 2, "g0") -> size 5
         0x07,
        0x05, 0x01, 0x00, 0x02,
        'g',  '0',
        // subsec 9: data names: count 1, (0, 4, "dseg") -> size 7
         0x09, 0x07,
        0x01, 0x00, 0x04, 'd',
        's',  'e',  'g',
    };
    try mod.customs.append(allocator, .{ .name = "name", .data = &name_payload });

    const wasm = try writer.writeModule(allocator, &mod);
    defer allocator.free(wasm);

    const opt_bytes = try optimize(allocator, wasm, .{ .custom_sections = .preserve });
    defer allocator.free(opt_bytes);

    var opt_mod = try reader.readModule(allocator, opt_bytes);
    defer opt_mod.deinit();

    // 3 functions survive: 0 (imp), 1 (was 2, live), 2 (was 3, main)
    try testing.expectEqual(@as(usize, 3), opt_mod.funcs.items.len);
    try testing.expectEqual(@as(usize, 1), opt_mod.customs.items.len);
    try testing.expectEqualStrings("name", opt_mod.customs.items[0].name);

    const expected_name_payload = [_]u8{
        // subsec 0: module name "m" preserved verbatim
        0x00, 0x02, 0x01, 'm',
        // subsec 1: 3 entries:
        // (0, 3, "imp") = 5 bytes
        // (1, 4, "live") = 6 bytes
        // (2, 4, "main") = 6 bytes
        // count (1) + 5 + 6 + 6 = 18
        0x01, 18,   0x03, 0x00,
        0x03, 'i',  'm',  'p',
        0x01, 0x04, 'l',  'i',
        'v',  'e',  0x02, 0x04,
        'm',  'a',  'i',  'n',
        // subsec 2: 2 entries:
        // func 1 (was 2): count 2, (0, 2, "l0"), (1, 2, "l1") -> 10 bytes
        // func 2 (was 3): count 1, (0, 2, "m0") -> 6 bytes
        // count (1) + 10 + 6 = 17
        0x02, 17,   0x02, 0x01,
        0x02, 0x00, 0x02, 'l',
        '0',  0x01, 0x02, 'l',
        '1',  0x02, 0x01, 0x00,
        0x02, 'm',  '0',
        // subsec 7: global names preserved verbatim
         0x07,
        0x05, 0x01, 0x00, 0x02,
        'g',  '0',
        // subsec 9: data names preserved verbatim
         0x09, 0x07,
        0x01, 0x00, 0x04, 'd',
        's',  'e',  'g',
    };
    try testing.expectEqualSlices(u8, &expected_name_payload, opt_mod.customs.items[0].data);
}

test "Optimizer: untyped post-link i32.add and i64.add are not folded into MemArg.offset" {
    const allocator = testing.allocator;
    // Post-link bytecode may contain negative LLVM LSR induction variables added to
    // relocated static addresses (`local.get $neg_iv; i64.const <end_addr>; i64.add; i64.load offset=0`),
    // which rely on wrapping modular addition rather than non-wrapping MemArg.offset addition.
    var code_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer code_buf.deinit(allocator);
    try code_buf.appendSlice(allocator, &[_]u8{ 0x20, 0x00, 0x42 });
    try appendS64Leb(allocator, &code_buf, 74967360);
    try code_buf.appendSlice(allocator, &[_]u8{ 0x7c, 0x29, 0x03, 0x00, 0x0b });

    const wasm = try buildSingleFuncModule(allocator, &.{.i64}, &.{.i64}, &.{}, code_buf.items);
    defer allocator.free(wasm);

    const opt_bytes = try optimize(allocator, wasm, .{});
    defer allocator.free(opt_bytes);

    var mod = try reader.readModule(allocator, opt_bytes);
    defer mod.deinit();
    try testing.expectEqualSlices(u8, code_buf.items, mod.funcs.items[0].code_bytes);
}

test "Optimizer: i32 and i64 additive, bitwise, shift, and rotate identities" {
    const allocator = testing.allocator;

    // i32 right-constant identities and left-constant commutative identities
    // local.get 0; +0; -0; |0; ^0; &-1; <<0; >>_s 0; >>_u 0; rotl 0; rotr 0 -> local.get 0
    const i32_code = [_]u8{
        0x41, 0x00, // i32.const 0 (left identity: 0 + local.get 0)
        0x20, 0x00, // local.get 0
        0x6a, // i32.add
        0x41, 0x00, 0x6a, // + 0
        0x41, 0x00, 0x6b, // - 0
        0x41, 0x00, 0x72, // | 0
        0x41, 0x00, 0x73, // ^ 0
        0x41, 0x7f, 0x71, // & -1
        0x41, 0x00, 0x74, // << 0
        0x41, 0x00, 0x75, // >>_s 0
        0x41, 0x00, 0x76, // >>_u 0
        0x41, 0x00, 0x77, // rotl 0
        0x41, 0x00, 0x78, // rotr 0
        0x0b, // end
    };
    const wasm32 = try buildSingleFuncModule(allocator, &.{.i32}, &.{.i32}, &.{}, &i32_code);
    defer allocator.free(wasm32);
    const opt32 = try optimize(allocator, wasm32, .{});
    defer allocator.free(opt32);
    var mod32 = try reader.readModule(allocator, opt32);
    defer mod32.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x00, 0x0b }, mod32.funcs.items[0].code_bytes);

    // i64 right-constant identities and left-constant commutative identities
    const i64_code = [_]u8{
        0x42, 0x7f, // i64.const -1 (left identity: -1 & local.get 0)
        0x20, 0x00, // local.get 0
        0x83, // i64.and
        0x42, 0x00, 0x7c, // + 0
        0x42, 0x00, 0x7d, // - 0
        0x42, 0x00, 0x84, // | 0
        0x42, 0x00, 0x85, // ^ 0
        0x42, 0x7f, 0x83, // & -1
        0x42, 0x00, 0x86, // << 0
        0x42, 0x00, 0x87, // >>_s 0
        0x42, 0x00, 0x88, // >>_u 0
        0x42, 0x00, 0x89, // rotl 0
        0x42, 0x00, 0x8a, // rotr 0
        0x0b, // end
    };
    const wasm64 = try buildSingleFuncModule(allocator, &.{.i64}, &.{.i64}, &.{}, &i64_code);
    defer allocator.free(wasm64);
    const opt64 = try optimize(allocator, wasm64, .{});
    defer allocator.free(opt64);
    var mod64 = try reader.readModule(allocator, opt64);
    defer mod64.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x00, 0x0b }, mod64.funcs.items[0].code_bytes);
}

test "Optimizer: zero comparison, comparison negation, double-boolean, and condition normalization" {
    const allocator = testing.allocator;

    // 1. x == 0 -> i32.eqz and i64.eqz
    const eq0_code = [_]u8{
        0x20, 0x00, // local.get 0 (i32)
        0x41, 0x00, // i32.const 0
        0x46, // i32.eq -> i32.eqz (0x45)
        0x1a, // drop
        0x20, 0x01, // local.get 1 (i64)
        0x42, 0x00, // i64.const 0
        0x51, // i64.eq -> i64.eqz (0x50)
        0x0b,
    };
    const wasm_eq0 = try buildSingleFuncModule(allocator, &.{ .i32, .i64 }, &.{.i32}, &.{}, &eq0_code);
    defer allocator.free(wasm_eq0);
    const opt_eq0 = try optimize(allocator, wasm_eq0, .{});
    defer allocator.free(opt_eq0);
    var mod_eq0 = try reader.readModule(allocator, opt_eq0);
    defer mod_eq0.deinit();
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x20, 0x00, 0x45, 0x1a, 0x20, 0x01, 0x50, 0x0b },
        mod_eq0.funcs.items[0].code_bytes,
    );

    // 2. <cmp>; i32.eqz -> inverted comparison, and <cmp>; i32.const 0; i32.ne -> <cmp>
    // local.get 0; local.get 1; i32.lt_s; i32.eqz; i32.const 0; i32.ne -> local.get 0; local.get 1; i32.ge_s
    const cmp_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x20, 0x01, // local.get 1
        0x48, // i32.lt_s
        0x45, // i32.eqz -> i32.ge_s (0x4e)
        0x41, 0x00, // i32.const 0
        0x47, // i32.ne -> redundant on bool producer
        0x41, 0x01, // i32.const 1
        0x71, // i32.and -> redundant on bool producer
        0x0b,
    };
    const wasm_cmp = try buildSingleFuncModule(allocator, &.{ .i32, .i32 }, &.{.i32}, &.{}, &cmp_code);
    defer allocator.free(wasm_cmp);
    const opt_cmp = try optimize(allocator, wasm_cmp, .{});
    defer allocator.free(opt_cmp);
    var mod_cmp = try reader.readModule(allocator, opt_cmp);
    defer mod_cmp.deinit();
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x20, 0x00, 0x20, 0x01, 0x4e, 0x0b },
        mod_cmp.funcs.items[0].code_bytes,
    );

    // 3. br_if / if condition normalization:
    // (block
    //   local.get 0; i32.const 0; i32.ne; br_if 0
    //   local.get 0; i32.eqz; i32.eqz; br_if 0
    // )
    // local.get 0; i32.const 0; i32.eq; i32.eqz; if (result i32) (i32.const 10) else (i32.const 20) end
    const br_if_code = [_]u8{
        0x02, 0x40, // block
        0x20, 0x00, // local.get 0
        0x41, 0x00, // i32.const 0
        0x47, // i32.ne
        0x0d, 0x00, // br_if 0
        0x20, 0x00, // local.get 0
        0x45, // i32.eqz
        0x45, // i32.eqz
        0x0d, 0x00, // br_if 0
        0x0b, // end block
        0x20, 0x00, // local.get 0
        0x41, 0x00, // i32.const 0
        0x46, // i32.eq -> i32.eqz
        0x45, // i32.eqz -> i32.eqz; i32.eqz stripped before if
        0x04, 0x7f, // if (result i32)
        0x41, 10,
        0x05, // else
        0x41,
        20,
        0x0b, // end if
        0x0b, // end func
    };
    const wasm_br = try buildSingleFuncModule(allocator, &.{.i32}, &.{.i32}, &.{}, &br_if_code);
    defer allocator.free(wasm_br);
    const opt_br = try optimize(allocator, wasm_br, .{});
    defer allocator.free(opt_br);
    var mod_br = try reader.readModule(allocator, opt_br);
    defer mod_br.deinit();
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x02, 0x40,
            0x20, 0x00,
            0x0d, 0x00,
            0x20, 0x00,
            0x0d, 0x00,
            0x0b, 0x20,
            0x00, 0x04,
            0x7f, 0x41,
            10,   0x05,
            0x41, 20,
            0x0b, 0x0b,
        },
        mod_br.funcs.items[0].code_bytes,
    );
}

test "Optimizer: multiplicative identities, power-of-two strength reductions, and division folding" {
    const allocator = testing.allocator;

    // i32: (local.get 0 * 1 /_s 1 /_u 1 * 8) -> local.get 0; i32.const 3; i32.shl
    //      (local.get 0 /_u 16) -> local.get 0; i32.const 4; i32.shr_u
    //      (local.get 0 %_u 32) -> local.get 0; i32.const 31; i32.and
    const i32_strength_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x41, 0x01, 0x6c, // * 1
        0x41, 0x01, 0x6d, // /_s 1
        0x41, 0x01, 0x6e, // /_u 1
        0x41, 0x08, 0x6c, // * 8 -> << 3
        0x41, 0x10, 0x6e, // /_u 16 -> >>_u 4
        0x41, 0x20, 0x70, // %_u 32 -> & 31
        0x0b,
    };
    const wasm32 = try buildSingleFuncModule(allocator, &.{.i32}, &.{.i32}, &.{}, &i32_strength_code);
    defer allocator.free(wasm32);
    const opt32 = try optimize(allocator, wasm32, .{});
    defer allocator.free(opt32);
    var mod32 = try reader.readModule(allocator, opt32);
    defer mod32.deinit();
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x20, 0x00,
            0x41, 0x03, 0x74, // i32.const 3; i32.shl
            0x41, 0x04, 0x76, // i32.const 4; i32.shr_u
            0x41, 0x1f, 0x71, // i32.const 31; i32.and
            0x0b,
        },
        mod32.funcs.items[0].code_bytes,
    );

    // i64: (4 * local.get 0 * 1 /_s 1 /_u 1 /_u 8 %_u 16)
    const i64_strength_code = [_]u8{
        0x42, 0x04, // i64.const 4
        0x20, 0x00, // local.get 0
        0x7e, // * -> local.get 0; i64.const 2; i64.shl
        0x42, 0x01, 0x7e, // * 1
        0x42, 0x01, 0x7f, // /_s 1
        0x42, 0x01, 0x80, // /_u 1
        0x42, 0x08, 0x80, // /_u 8 -> >>_u 3
        0x42, 0x10, 0x82, // %_u 16 -> & 15
        0x0b,
    };
    const wasm64 = try buildSingleFuncModule(allocator, &.{.i64}, &.{.i64}, &.{}, &i64_strength_code);
    defer allocator.free(wasm64);
    const opt64 = try optimize(allocator, wasm64, .{});
    defer allocator.free(opt64);
    var mod64 = try reader.readModule(allocator, opt64);
    defer mod64.deinit();
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x20, 0x00,
            0x42, 0x02, 0x86, // i64.const 2; i64.shl
            0x42, 0x03, 0x88, // i64.const 3; i64.shr_u
            0x42, 0x0f, 0x83, // i64.const 15; i64.and
            0x0b,
        },
        mod64.funcs.items[0].code_bytes,
    );

    // Two-constant non-trapping division/remainder folding:
    // (-20 /_s 3) = -6, (-20 %_s 3) = -2 -> (-6 + -2 = -8)
    const div_fold_code = [_]u8{
        0x41, 0x6c, // i32.const -20
        0x41, 0x03, // i32.const 3
        0x6d, // i32.div_s -> -6
        0x41, 0x6c, // i32.const -20
        0x41, 0x03, // i32.const 3
        0x6f, // i32.rem_s -> -2
        0x6a, // i32.add -> -8 (0x78)
        0x0b,
    };
    const wasm_div = try buildSingleFuncModule(allocator, &.{}, &.{.i32}, &.{}, &div_fold_code);
    defer allocator.free(wasm_div);
    const opt_div = try optimize(allocator, wasm_div, .{});
    defer allocator.free(opt_div);
    var mod_div = try reader.readModule(allocator, opt_div);
    defer mod_div.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x78, 0x0b }, mod_div.funcs.items[0].code_bytes);
}

test "Optimizer: constant reassociation without folding into MemArg.offset" {
    const allocator = testing.allocator;

    // 1. Cancelling reassociation: (x + 12) - 12 -> x
    const cancel_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x41, 12, // i32.const 12
        0x6a, // i32.add
        0x41, 12, // i32.const 12
        0x6b, // i32.sub
        0x0b,
    };
    const wasm_cancel = try buildSingleFuncModule(allocator, &.{.i32}, &.{.i32}, &.{}, &cancel_code);
    defer allocator.free(wasm_cancel);
    const opt_cancel = try optimize(allocator, wasm_cancel, .{});
    defer allocator.free(opt_cancel);
    var mod_cancel = try reader.readModule(allocator, opt_cancel);
    defer mod_cancel.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x00, 0x0b }, mod_cancel.funcs.items[0].code_bytes);

    // 2. (x + 16) - 4 before i32.load reassociates to (x + 12) without folding into MemArg.offset
    const mem_reassoc_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x41, 16, // i32.const 16
        0x6a, // i32.add
        0x41, 0x04, // i32.const 4
        0x6b, // i32.sub -> reassociates to (local.get 0 + 12)
        0x28, 0x02, 0x04, // i32.load align=2 offset=4
        0x0b,
    };
    const wasm_mem = try buildSingleFuncModule(allocator, &.{.i32}, &.{.i32}, &.{}, &mem_reassoc_code);
    defer allocator.free(wasm_mem);
    const opt_mem = try optimize(allocator, wasm_mem, .{});
    defer allocator.free(opt_mem);
    var mod_mem = try reader.readModule(allocator, opt_mem);
    defer mod_mem.deinit();
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x20, 0x00, 0x41, 12, 0x6a, 0x28, 0x02, 0x04, 0x0b },
        mod_mem.funcs.items[0].code_bytes,
    );
}

test "Optimizer: trivial 0-param constant and forwarding callee chain inlining" {
    const allocator = testing.allocator;

    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    const r_i32 = try allocator.dupe(types.ValType, &.{.i32});
    try mod.module_types.append(allocator, .{ .func_type = .{ .params = &.{}, .results = r_i32 } });
    try mod.type_meta.append(allocator, .{});

    // func 0 (getFactoryThunk): call 1; return; end
    const code0 = [_]u8{ 0x10, 0x01, 0x0f, 0x0b };
    // func 1 (host.getFactoryThunk): call 2; return; end
    const code1 = [_]u8{ 0x10, 0x02, 0x0f, 0x0b };
    // func 2 (export.getFactoryThunk): i32.const 1; return; end
    const code2 = [_]u8{ 0x41, 0x01, 0x0f, 0x0b };
    // func 3 (caller arithmetic): call 0; i32.const 41; i32.add; end
    const code3 = [_]u8{ 0x10, 0x00, 0x41, 41, 0x6a, 0x0b };

    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &code0 });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &code1 });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &code2 });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &code3 });

    try mod.exports.append(allocator, .{ .name = "getFactoryThunk", .kind = .func, .var_ = .{ .index = 0 } });
    try mod.exports.append(allocator, .{ .name = "compute", .kind = .func, .var_ = .{ .index = 3 } });

    const wasm = try writer.writeModule(allocator, &mod);
    defer allocator.free(wasm);

    const opt_bytes = try optimize(allocator, wasm, .{});
    defer allocator.free(opt_bytes);

    var opt_mod = try reader.readModule(allocator, opt_bytes);
    defer opt_mod.deinit();

    // Intermediate funcs 1 and 2 are pruned; only getFactoryThunk (0) and compute (1) remain.
    try testing.expectEqual(@as(usize, 2), opt_mod.funcs.items.len);
    // getFactoryThunk collapsed to `i32.const 1; end` (0x41 0x01 0x0b).
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x01, 0x0b }, opt_mod.funcs.items[0].code_bytes);
    // compute inlined `call 0` -> `i32.const 1` and folded `1 + 41` -> `i32.const 42; end`.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 42, 0x0b }, opt_mod.funcs.items[1].code_bytes);
}

test "Optimizer: 1-parameter leaf inlining (field load, std.debug.assert, and std.math.isNan)" {
    const allocator = testing.allocator;

    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    try mod.memories.append(allocator, .{
        .type = .{ .limits = .{ .initial = 1 } },
    });

    // Type 0: (param i32) -> (result f32)
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.i32}),
        .results = try allocator.dupe(types.ValType, &.{.f32}),
    } });
    try mod.type_meta.append(allocator, .{});

    // Type 1: (param i32) -> ()
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.i32}),
        .results = &.{},
    } });
    try mod.type_meta.append(allocator, .{});

    // Type 2: (param f32) -> (result i32)
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.f32}),
        .results = try allocator.dupe(types.ValType, &.{.i32}),
    } });
    try mod.type_meta.append(allocator, .{});

    // Type 3: (param i32, i32) -> (result i32)
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{ .i32, .i32 }),
        .results = try allocator.dupe(types.ValType, &.{.i32}),
    } });
    try mod.type_meta.append(allocator, .{});

    // func 0 (Rect.x): local.get 0; f32.load align=2 offset=4; return; end
    const rect_x_code = [_]u8{ 0x20, 0x00, 0x2a, 0x02, 0x04, 0x0f, 0x0b };
    // func 1 (std.debug.assert): block (empty) { local.get 0; br_if 0; unreachable } end; return; end
    const assert_code = [_]u8{ 0x02, 0x40, 0x20, 0x00, 0x0d, 0x00, 0x00, 0x0b, 0x0f, 0x0b };
    // func 2 (std.math.isNan): local.get 0; local.get 0; f32.ne; return; end
    const is_nan_code = [_]u8{ 0x20, 0x00, 0x20, 0x00, 0x5c, 0x0f, 0x0b };
    // func 3 (caller_pure):
    //   local.get 0; local.get 1; i32.lt_u; call $assert;
    //   local.get 0; call $rect_x; call $is_nan; end
    const caller_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x20, 0x01, // local.get 1
        0x49, // i32.lt_u
        0x10, 0x01, // call $assert
        0x20, 0x00, // local.get 0
        0x10, 0x00, // call $rect_x
        0x10, 0x02, // call $is_nan
        0x0b, // end
    };
    // func 4 (caller_pure_isnan): local.get 0; call $is_nan; end
    const caller_pure_isnan_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x10, 0x02, // call $is_nan
        0x0b, // end
    };

    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &rect_x_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 1 } }, .code_bytes = &assert_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 2 } }, .code_bytes = &is_nan_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 3 } }, .code_bytes = &caller_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 2 } }, .code_bytes = &caller_pure_isnan_code });

    try mod.exports.append(allocator, .{ .name = "caller", .kind = .func, .var_ = .{ .index = 3 } });
    try mod.exports.append(allocator, .{ .name = "caller_pure_isnan", .kind = .func, .var_ = .{ .index = 4 } });

    const wasm = try writer.writeModule(allocator, &mod);
    defer allocator.free(wasm);

    const opt_bytes = try optimize(allocator, wasm, .{});
    defer allocator.free(opt_bytes);

    var opt_mod = try reader.readModule(allocator, opt_bytes);
    defer opt_mod.deinit();

    // Helpers 0, 1, 2 were inlined and pruned; only the 2 exported callers remain.
    try testing.expectEqual(@as(usize, 2), opt_mod.funcs.items.len);

    // caller (func 0):
    // - `local.get 0; local.get 1; i32.lt_u; call $assert` inlined with zero scratch locals and
    //   folded `i32.lt_u; i32.eqz` -> `i32.ge_u; if (empty) { unreachable } end`
    // - `local.get 0; call $rect_x` inlined with zero scratch locals -> `local.get 0; f32.load align=2 offset=4`
    // - `call $is_nan` on non-pure `f32.load` folded `local.set 2; local.get 2` -> `local.tee 2; local.get 2; f32.ne`
    try testing.expectEqualSlices(types.ValType, &.{.f32}, opt_mod.funcs.items[0].local_types.items);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x20, 0x00, // local.get 0
            0x20, 0x01, // local.get 1
            0x4f, // i32.ge_u
            0x04, 0x40, // if (empty)
            0x00, // unreachable
            0x0b, // end
            0x20, 0x00, // local.get 0
            0x2a, 0x02, 0x04, // f32.load align=2 offset=4
            0x22, 0x02, // local.tee 2
            0x20, 0x02, // local.get 2
            0x5c, // f32.ne
            0x0b, // end
        },
        opt_mod.funcs.items[0].code_bytes,
    );

    // caller_pure_isnan (func 1):
    // `local.get 0; call $is_nan` propagated `local.get 0` to both uses and compacted away the scratch local!
    try testing.expectEqual(@as(usize, 0), opt_mod.funcs.items[1].local_types.items.len);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x20, 0x00, // local.get 0
            0x20, 0x00, // local.get 0
            0x5c, // f32.ne
            0x0b, // end
        },
        opt_mod.funcs.items[1].code_bytes,
    );
}

test "Optimizer: multi-parameter leaf inlining with simplifyLocals and compactLocals" {
    const allocator = testing.allocator;

    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    try mod.memories.append(allocator, .{
        .type = .{ .limits = .{ .initial = 1 } },
    });

    // Type 0: (param i32, i32) -> (result i32)
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{ .i32, .i32 }),
        .results = try allocator.dupe(types.ValType, &.{.i32}),
    } });
    try mod.type_meta.append(allocator, .{});

    // Type 1: (param i32, i32, i32) -> (result i32)
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{ .i32, .i32, .i32 }),
        .results = try allocator.dupe(types.ValType, &.{.i32}),
    } });
    try mod.type_meta.append(allocator, .{});

    // Type 2: (param i32) -> (result i32)
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.i32}),
        .results = try allocator.dupe(types.ValType, &.{.i32}),
    } });
    try mod.type_meta.append(allocator, .{});

    // func 0 (sub2): local.get 0; local.get 1; i32.sub; return; end (prefix_params = 2)
    const sub2_code = [_]u8{ 0x20, 0x00, 0x20, 0x01, 0x6b, 0x0f, 0x0b };
    // func 1 (fma_reuse): (a * b) + (c - a)
    // Uses param 0 (`a`) twice and accesses `c` then `a`, so params 0..2 use scratch locals on inline.
    const fma_code = [_]u8{
        0x20, 0x00, // local.get 0 (a)
        0x20, 0x01, // local.get 1 (b)
        0x6c, // i32.mul
        0x20, 0x02, // local.get 2 (c)
        0x20, 0x00, // local.get 0 (a)
        0x6b, // i32.sub
        0x6a, // i32.add
        0x0f, // return
        0x0b, // end
    };
    // func 2 (exported caller):
    //   local.get 0; i32.const 4; i32.const 20; call $fma_reuse;
    //   i32.const 5; call $sub2; end
    // Expected after inlining + simplifyLocals + foldConstants + compactLocals:
    //   ((x << 2) + (20 - x)) - 5, with 0 scratch locals remaining!
    const caller_code = [_]u8{
        0x20, 0x00, // local.get 0 (x)
        0x41, 0x04, // i32.const 4
        0x41, 20, // i32.const 20
        0x10, 0x01, // call $fma_reuse
        0x41, 0x05, // i32.const 5
        0x10, 0x00, // call $sub2
        0x0b, // end
    };

    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &sub2_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 1 } }, .code_bytes = &fma_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 2 } }, .code_bytes = &caller_code });

    try mod.exports.append(allocator, .{ .name = "compute", .kind = .func, .var_ = .{ .index = 2 } });

    const wasm = try writer.writeModule(allocator, &mod);
    defer allocator.free(wasm);

    const opt_bytes = try optimize(allocator, wasm, .{ .optimize_mode = .fast });
    defer allocator.free(opt_bytes);

    var opt_mod = try reader.readModule(allocator, opt_bytes);
    defer opt_mod.deinit();

    try testing.expectEqual(@as(usize, 1), opt_mod.funcs.items.len);
    // All 3 temporary parameter locals from $fma_reuse were propagated and compacted away!
    try testing.expectEqual(@as(usize, 0), opt_mod.funcs.items[0].local_types.items.len);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x20, 0x00, // local.get 0
            0x41, 0x02, // i32.const 2 (strength-reduced from * 4)
            0x74, // i32.shl
            0x41, 20, // i32.const 20
            0x20, 0x00, // local.get 0
            0x6b, // i32.sub
            0x6a, // i32.add
            0x41, 0x05, // i32.const 5
            0x6b, // i32.sub
            0x0b, // end
        },
        opt_mod.funcs.items[0].code_bytes,
    );
}

test "Optimizer: OptimizeMode.small vs OptimizeMode.fast leaf inlining thresholds" {
    const allocator = testing.allocator;

    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    // Type 0: (param i32) -> (result i32)
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.i32}),
        .results = try allocator.dupe(types.ValType, &.{.i32}),
    } });
    try mod.type_meta.append(allocator, .{});

    // func 0: 13-op leaf hash step (exceeds .small multi-call limit of 6 ops, within .fast limit of 64 ops)
    const medium_leaf_code = [_]u8{
        0x20, 0x00, // 1: local.get 0
        0x41, 16, // 2: i32.const 16
        0x76, // 3: i32.shr_u
        0x20, 0x00, // 4: local.get 0
        0x73, // 5: i32.xor
        0x41, 0x45, // 6: i32.const 0x45
        0x6c, // 7: i32.mul
        0x20, 0x00, // 8: local.get 0
        0x41, 0x07, // 9: i32.const 7
        0x77, // 10: i32.rotl
        0x73, // 11: i32.xor
        0x41, 0x01, // 12: i32.const 1
        0x6a, // 13: i32.add
        0x0f, // return
        0x0b, // end
    };

    // func 1 (exported caller calling func 0 twice):
    const dual_caller_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x10, 0x00, // call 0
        0x10, 0x00, // call 0
        0x0b, // end
    };

    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &medium_leaf_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &dual_caller_code });
    try mod.exports.append(allocator, .{ .name = "hash2", .kind = .func, .var_ = .{ .index = 1 } });

    const wasm = try writer.writeModule(allocator, &mod);
    defer allocator.free(wasm);

    // In .small mode, func 0 has 2 call sites and 13 ops (> 6), so it is NOT inlined.
    const opt_small = try optimize(allocator, wasm, .{ .optimize_mode = .small });
    defer allocator.free(opt_small);
    var mod_small = try reader.readModule(allocator, opt_small);
    defer mod_small.deinit();
    try testing.expectEqual(@as(usize, 2), mod_small.funcs.items.len);
    try testing.expectEqualSlices(u8, &dual_caller_code, mod_small.funcs.items[1].code_bytes);

    // In .fast mode, func 0 (13 ops <= 64) IS inlined at both call sites and pruned!
    const opt_fast = try optimize(allocator, wasm, .{ .optimize_mode = .fast });
    defer allocator.free(opt_fast);
    var mod_fast = try reader.readModule(allocator, opt_fast);
    defer mod_fast.deinit();
    try testing.expectEqual(@as(usize, 1), mod_fast.funcs.items.len);
}

test "Optimizer: early return, depth-0 br_if, return_call, and zero-init local in loop" {
    const allocator = testing.allocator;

    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    // Type 0: (param i32) -> (result i32)
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.i32}),
        .results = try allocator.dupe(types.ValType, &.{.i32}),
    } });
    try mod.type_meta.append(allocator, .{});

    // Type 1: (param i32) -> ()
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.i32}),
        .results = &.{},
    } });
    try mod.type_meta.append(allocator, .{});

    // func 0 (early_ret_1):
    //   local.get 0; if (empty) { i32.const 99; return } end; local.get 0; i32.const 1; i32.add; return; end
    const early_ret_1_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x04, 0x40, // if (empty)
        0x41, 99, // i32.const 99
        0x0f, // return -> rewritten to `br 1` inside `block (result i32)`
        0x0b, // end
        0x20, 0x00, // local.get 0
        0x41, 0x01, // i32.const 1
        0x6a, // i32.add
        0x0f, // return
        0x0b, // end
    };

    // func 1 (depth0_br_if_0):
    //   local.get 0; br_if 0; nop; return; end (0-result, depth-0 br_if triggers needs_result_block)
    const depth0_br_if_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x0d, 0x00, // br_if 0 (targets function root -> needs_result_block = true)
        0x0f, // return
        0x0b, // end
    };

    // func 2 (zero_init_local):
    //   has 1 non-param local (local 1: i32) read before write at depth 0:
    //   local.get 1; local.get 0; i32.add; local.tee 1; return; end
    const zero_init_code = [_]u8{
        0x20, 0x01, // local.get 1 (unwritten non-param local -> needs_local_zero_init[0] = true)
        0x20, 0x00, // local.get 0
        0x6a, // i32.add
        0x0f, // return
        0x0b, // end
    };

    // func 3 (tail_callee): local.get 0; i32.const 7; i32.add; return; end
    const tail_callee_code = [_]u8{ 0x20, 0x00, 0x41, 0x07, 0x6a, 0x0f, 0x0b };

    // func 4 (exported caller exercising early return, depth-0 br_if, zero-init inside loop, and return_call):
    const caller_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x10, 0x01, // call $depth0_br_if_0
        0x03, 0x40, // loop (empty)
        0x20, 0x00, // local.get 0
        0x10, 0x02, // call $zero_init_local
        0x1a, // drop
        0x0b, // end loop
        0x20, 0x00, // local.get 0
        0x10, 0x00, // call $early_ret_1
        0x12, 0x03, // return_call $tail_callee -> emits `<spliced>; return`
        0x0b, // end
    };

    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &early_ret_1_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 1 } }, .code_bytes = &depth0_br_if_code });
    var func2 = Mod.Func{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &zero_init_code };
    try func2.local_types.append(allocator, .i32);
    try mod.funcs.append(allocator, func2);
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &tail_callee_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &caller_code });

    try mod.exports.append(allocator, .{ .name = "run", .kind = .func, .var_ = .{ .index = 4 } });

    const wasm = try writer.writeModule(allocator, &mod);
    defer allocator.free(wasm);

    const opt_bytes = try optimize(allocator, wasm, .{ .optimize_mode = .fast });
    defer allocator.free(opt_bytes);

    var opt_mod = try reader.readModule(allocator, opt_bytes);
    defer opt_mod.deinit();

    // All 4 helpers were inlined into `run` and pruned!
    try testing.expectEqual(@as(usize, 1), opt_mod.funcs.items.len);
    // Verify `return_call $tail_callee` emitted trailing `0x0f` (`return`) before `0x0b` (`end`).
    const run_bytes = opt_mod.funcs.items[0].code_bytes;
    try testing.expect(run_bytes.len >= 2);
    try testing.expectEqual(@as(u8, 0x0f), run_bytes[run_bytes.len - 2]);
    try testing.expectEqual(@as(u8, 0x0b), run_bytes[run_bytes.len - 1]);

    // Trailing `return` (0x0f) with extra stack values (`i32.const 1; local.get 0; return; end`)
    // is wrapped in `block (result i32)` and rewritten to `br 0` so extra stack values are unwound!
    var mod_stack = Mod.Module.init(allocator);
    defer mod_stack.deinit();
    try mod_stack.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.i32}),
        .results = try allocator.dupe(types.ValType, &.{.i32}),
    } });
    try mod_stack.type_meta.append(allocator, .{});

    const extra_stack_callee = [_]u8{
        0x41, 0x01, // i32.const 1 (extra stack value)
        0x20, 0x00, // local.get 0 (actual return value)
        0x0f, // return (unwinds extra i32.const 1)
        0x0b, // end
    };
    const extra_stack_caller = [_]u8{
        0x20, 0x00, // local.get 0
        0x10, 0x00, // call 0
        0x0b, // end
    };
    try mod_stack.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &extra_stack_callee });
    try mod_stack.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &extra_stack_caller });
    try mod_stack.exports.append(allocator, .{ .name = "f", .kind = .func, .var_ = .{ .index = 1 } });

    const wasm_stack = try writer.writeModule(allocator, &mod_stack);
    defer allocator.free(wasm_stack);
    const opt_stack = try optimize(allocator, wasm_stack, .{ .optimize_mode = .fast });
    defer allocator.free(opt_stack);
    var mod_stack_opt = try reader.readModule(allocator, opt_stack);
    defer mod_stack_opt.deinit();

    try testing.expectEqual(@as(usize, 1), mod_stack_opt.funcs.items.len);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x02, 0x7f, // block (result i32)
            0x41, 0x01, // i32.const 1
            0x20, 0x00, // local.get 0
            0x0c, 0x00, // br 0
            0x0b, // end block
            0x0b, // end func
        },
        mod_stack_opt.funcs.items[0].code_bytes,
    );
}

test "Optimizer: multi-caller forwarder to single-use medium leaf and large constant preservation in .small mode" {
    const allocator = testing.allocator;

    // 1. Multi-caller forwarder F -> 10-op single-use leaf L in .small mode:
    //    F is called twice, L is called once (by F). Resolving F -> L must NOT inline L twice in .small mode.
    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = &.{},
        .results = try allocator.dupe(types.ValType, &.{.i32}),
    } });
    try mod.type_meta.append(allocator, .{});

    try mod.globals.append(allocator, .{
        .type = .{ .val_type = .i32, .mutability = .mutable },
        .init_expr_bytes = &[_]u8{ 0x41, 0x00 },
    });

    // func 0 (L): 9-op leaf reading global 0 (cannot be constant-folded, > 6 ops)
    const leaf_code = [_]u8{
        0x23, 0x00, // 1: global.get 0
        0x41, 0x03, // 2: i32.const 3
        0x73, // 3: i32.xor
        0x23, 0x00, // 4: global.get 0
        0x6a, // 5: i32.add
        0x23, 0x00, // 6: global.get 0
        0x73, // 7: i32.xor
        0x23, 0x00, // 8: global.get 0
        0x6a, // 9: i32.add
        0x0f, // return
        0x0b, // end
    };
    // func 1 (F): forwarder `call 0; return; end`
    const fwd_code = [_]u8{ 0x10, 0x00, 0x0f, 0x0b };
    // func 2 (exported caller): calls F twice (`call 1; call 1; i32.add; end`)
    const caller_code = [_]u8{ 0x10, 0x01, 0x10, 0x01, 0x6a, 0x0b };

    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &leaf_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &fwd_code });
    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &caller_code });
    try mod.exports.append(allocator, .{ .name = "main", .kind = .func, .var_ = .{ .index = 2 } });

    const wasm = try writer.writeModule(allocator, &mod);
    defer allocator.free(wasm);

    const opt_small = try optimize(allocator, wasm, .{ .optimize_mode = .small });
    defer allocator.free(opt_small);
    var mod_small = try reader.readModule(allocator, opt_small);
    defer mod_small.deinit();

    // Forwarder F (func 1) was bypassed and pruned, but L (func 0) was NOT inlined twice in .small mode!
    try testing.expectEqual(@as(usize, 2), mod_small.funcs.items.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x10, 0x00, 0x10, 0x00, 0x6a, 0x0b }, mod_small.funcs.items[1].code_bytes);

    // 2. Large constant local read 3 times is kept in a local in .small mode, but propagated in .fast mode:
    const large_const_code = [_]u8{
        0x41, 0x80, 0x80, 0x04, // i32.const 65536 (4 bytes)
        0x21, 0x00, // local.set 0
        0x20, 0x00, // local.get 0
        0x20, 0x00, // local.get 0
        0x20, 0x00, // local.get 0
        0x6c, // i32.mul
        0x6a, // i32.add
        0x0b, // end
    };
    const wasm_lc = try buildSingleFuncModule(allocator, &.{}, &.{.i32}, &.{.i32}, &large_const_code);
    defer allocator.free(wasm_lc);

    const opt_lc_small = try optimize(allocator, wasm_lc, .{ .optimize_mode = .small });
    defer allocator.free(opt_lc_small);
    var mod_lc_small = try reader.readModule(allocator, opt_lc_small);
    defer mod_lc_small.deinit();
    // In .small mode, local 0 is kept (`local.tee 0; local.get 0; local.get 0; i32.mul; i32.add`).
    try testing.expectEqual(@as(usize, 1), mod_lc_small.funcs.items[0].local_types.items.len);

    const opt_lc_fast = try optimize(allocator, wasm_lc, .{ .optimize_mode = .fast });
    defer allocator.free(opt_lc_fast);
    var mod_lc_fast = try reader.readModule(allocator, opt_lc_fast);
    defer mod_lc_fast.deinit();
    // In .fast mode, local 0 is propagated, constant-folded, and compacted away!
    try testing.expectEqual(@as(usize, 0), mod_lc_fast.funcs.items[0].local_types.items.len);
}

test "Optimizer: stage2_wasm assert inner-block and Rect.x shadow-stack copy inlining in .small mode" {
    const allocator = testing.allocator;

    var mod = Mod.Module.init(allocator);
    defer mod.deinit();

    try mod.memories.append(allocator, .{
        .type = .{ .limits = .{ .initial = 1 } },
    });
    try mod.globals.append(allocator, .{
        .type = .{ .val_type = .i32, .mutability = .mutable },
        .init_expr_bytes = &[_]u8{ 0x41, 0x00 },
    });

    // Type 0: (param i32) -> ()  (std.debug.assert)
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.i32}),
        .results = &.{},
    } });
    try mod.type_meta.append(allocator, .{});

    // Type 1: (param i32) -> (result f32)  (Rect.y)
    try mod.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.i32}),
        .results = try allocator.dupe(types.ValType, &.{.f32}),
    } });
    try mod.type_meta.append(allocator, .{});

    // func 0: stage2_wasm lowering of `std.debug.assert(ok: bool)`:
    //   (local i32)
    //   block (0x40)
    //     local.get 0; i32.eqz; local.set 1;
    //     block (0x40)
    //       local.get 1; br_if 0; br 1
    //     end
    //     unreachable
    //   end
    //   return; end
    const stage2_assert_code = [_]u8{
        0x02, 0x40, // block (empty)
        0x20, 0x00, // local.get 0
        0x45, // i32.eqz
        0x21, 0x01, // local.set 1
        0x02, 0x40, // block (empty)
        0x20, 0x01, // local.get 1
        0x0d, 0x00, // br_if 0
        0x0c, 0x01, // br 1
        0x0b, // end inner block
        0x00, // unreachable
        0x0b, // end outer block
        0x0f, // return
        0x0b, // end
    };

    // func 1: stage2_wasm lowering of `Rect.y(self: Rect) f32` with 16-byte shadow-stack copy:
    //   (local i32)
    //   global.get 0; i32.const 16; i32.sub; local.tee 1;
    //   local.get 0; i32.const 16; memory.copy 0 0;
    //   local.get 1; f32.load align=2 offset=4; return; end
    const stage2_rect_y_code = [_]u8{
        0x23, 0x00, // global.get 0
        0x41, 16, // i32.const 16
        0x6b, // i32.sub
        0x22, 0x01, // local.tee 1
        0x20, 0x00, // local.get 0
        0x41, 16, // i32.const 16
        0xfc, 0x0a, 0x00, 0x00, // memory.copy 0 0
        0x20, 0x01, // local.get 1
        0x2a, 0x02, 0x04, // f32.load align=2 offset=4
        0x0f, // return
        0x0b, // end
    };

    // func 2 (exported caller):
    //   local.get 0; i32.const 0; i32.ne; call $assert;
    //   local.get 0; call $rect_y; end
    const caller_code = [_]u8{
        0x20, 0x00, // local.get 0
        0x41, 0x00, // i32.const 0
        0x47, // i32.ne
        0x10, 0x00, // call $assert
        0x20, 0x00, // local.get 0
        0x10, 0x01, // call $rect_y
        0x0b, // end
    };

    var f0 = Mod.Func{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &stage2_assert_code };
    try f0.local_types.append(allocator, .i32);
    try mod.funcs.append(allocator, f0);

    var f1 = Mod.Func{ .decl = .{ .type_var = .{ .index = 1 } }, .code_bytes = &stage2_rect_y_code };
    try f1.local_types.append(allocator, .i32);
    try mod.funcs.append(allocator, f1);

    try mod.funcs.append(allocator, .{ .decl = .{ .type_var = .{ .index = 1 } }, .code_bytes = &caller_code });
    try mod.exports.append(allocator, .{ .name = "get_y", .kind = .func, .var_ = .{ .index = 2 } });

    const wasm = try writer.writeModule(allocator, &mod);
    defer allocator.free(wasm);

    const opt_small = try optimize(allocator, wasm, .{ .optimize_mode = .small });
    defer allocator.free(opt_small);

    var opt_mod = try reader.readModule(allocator, opt_small);
    defer opt_mod.deinit();

    // Both `std.debug.assert` and `Rect.y` were simplified to 0-local prefix_params=1 leaves,
    // inlined into `get_y` in .small mode, and pruned!
    try testing.expectEqual(@as(usize, 1), opt_mod.funcs.items.len);
    try testing.expectEqual(@as(usize, 0), opt_mod.funcs.items[0].local_types.items.len);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x20, 0x00, // local.get 0
            0x45, // i32.eqz (folded from `i32.const 0; i32.ne; i32.eqz`)
            0x04, 0x40, // if (empty)
            0x00, // unreachable
            0x0b, // end
            0x20, 0x00, // local.get 0
            0x2a, 0x02, 0x04, // f32.load align=2 offset=4
            0x0b, // end
        },
        opt_mod.funcs.items[0].code_bytes,
    );

    // 2. `eliminateLeafStackCopy` must NOT strip the prologue if the tail contains a 0xfd SIMD store (`v128.store`):
    var mod_simd = Mod.Module.init(allocator);
    defer mod_simd.deinit();
    try mod_simd.memories.append(allocator, .{ .type = .{ .limits = .{ .initial = 1 } } });
    try mod_simd.globals.append(allocator, .{
        .type = .{ .val_type = .i32, .mutability = .mutable },
        .init_expr_bytes = &[_]u8{ 0x41, 0x00 },
    });
    try mod_simd.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{ .i32, .v128 }),
        .results = try allocator.dupe(types.ValType, &.{.f32}),
    } });
    try mod_simd.type_meta.append(allocator, .{});

    const simd_store_code = [_]u8{
        0x23, 0x00, // global.get 0
        0x41, 16, // i32.const 16
        0x6b, // i32.sub
        0x22, 0x02, // local.tee 2
        0x20, 0x00, // local.get 0
        0x41, 16, // i32.const 16
        0xfc, 0x0a, 0x00, 0x00, // memory.copy 0 0
        0x20, 0x00, // local.get 0
        0x20, 0x01, // local.get 1 (v128)
        0xfd, 0x0b, 0x04, 0x00, // v128.store align=4 offset=0
        0x20, 0x02, // local.get 2
        0x2a, 0x02, 0x00, // f32.load align=2 offset=0
        0x0b, // end
    };
    var f_simd = Mod.Func{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &simd_store_code };
    try f_simd.local_types.append(allocator, .i32);
    try mod_simd.funcs.append(allocator, f_simd);
    try mod_simd.exports.append(allocator, .{ .name = "simd_fn", .kind = .func, .var_ = .{ .index = 0 } });

    const wasm_simd = try writer.writeModule(allocator, &mod_simd);
    defer allocator.free(wasm_simd);
    const opt_simd = try optimize(allocator, wasm_simd, .{ .optimize_mode = .small });
    defer allocator.free(opt_simd);
    var mod_simd_opt = try reader.readModule(allocator, opt_simd);
    defer mod_simd_opt.deinit();
    // Prologue and scratch local 2 are preserved because of `v128.store`!
    try testing.expectEqual(@as(usize, 1), mod_simd_opt.funcs.items[0].local_types.items.len);
    try testing.expectEqualSlices(u8, &simd_store_code, mod_simd_opt.funcs.items[0].code_bytes);

    // 3. `rewriteNameSectionPayload` on the `all_live` path (no dead functions removed) prunes
    //    stale subsection 2 (local names) when `compactLocals` removes an unused local:
    var mod_names = Mod.Module.init(allocator);
    defer mod_names.deinit();
    try mod_names.module_types.append(allocator, .{ .func_type = .{
        .params = try allocator.dupe(types.ValType, &.{.i32}),
        .results = try allocator.dupe(types.ValType, &.{.i32}),
    } });
    try mod_names.type_meta.append(allocator, .{});

    // Exported function 0 has 1 unused non-parameter local (local 1: i32) that `compactLocals` removes.
    const unused_local_code = [_]u8{ 0x20, 0x00, 0x0b };
    var f_names = Mod.Func{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &unused_local_code };
    try f_names.local_types.append(allocator, .i32);
    try mod_names.funcs.append(allocator, f_names);
    try mod_names.exports.append(allocator, .{ .name = "id", .kind = .func, .var_ = .{ .index = 0 } });

    // Name section with subsec 1 (func 0 -> "id") and subsec 2 (func 0 -> { local 0 -> "x", local 1 -> "unused" })
    const name_sec = [_]u8{
        1, 5, 1, 0, 2, 'i', 'd', // subsec 1: 1 entry (func 0 -> "id")
        2, 14, 1, 0, 2, 0, 1, 'x', 1, 6, 'u', 'n', 'u', 's', 'e', 'd', // subsec 2: 1 func (0) with 2 local names
    };
    try mod_names.customs.append(allocator, .{ .name = "name", .data = &name_sec });

    const wasm_names = try writer.writeModule(allocator, &mod_names);
    defer allocator.free(wasm_names);
    const opt_names = try optimize(allocator, wasm_names, .{ .custom_sections = .preserve, .optimize_mode = .small });
    defer allocator.free(opt_names);
    var mod_names_opt = try reader.readModule(allocator, opt_names);
    defer mod_names_opt.deinit();

    try testing.expectEqual(@as(usize, 0), mod_names_opt.funcs.items[0].local_types.items.len);
    try testing.expectEqual(@as(usize, 1), mod_names_opt.customs.items.len);
    // Subsec 1 (func names) is preserved, while stale subsec 2 (local names for compacted func 0) is dropped!
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 5, 1, 0, 2, 'i', 'd' }, mod_names_opt.customs.items[0].data);
}



