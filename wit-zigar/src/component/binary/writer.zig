//! WebAssembly binary format writer.
//!
//! Serializes a Module IR to the .wasm binary format.

const std = @import("std");
const leb128 = @import("../leb128.zig");
const types = @import("../core_types.zig");
const Mod = @import("../Module.zig");
const reader = @import("reader.zig");

pub const WriteError = error{ OutOfMemory, InvalidLimits };

// ── Public API ──────────────────────────────────────────────────────────

pub fn writeModule(allocator: std.mem.Allocator, module: *const Mod.Module) WriteError![]u8 {
    var w = Writer{ .allocator = allocator, .buf = .empty };
    errdefer w.buf.deinit(allocator);

    try w.appendSlice(&reader.magic);
    try w.writeU32LE(reader.version);

    try w.writeTypeSection(module);
    try w.writeImportSection(module);
    try w.writeFunctionSection(module);
    try w.writeTableSection(module);
    try w.writeMemorySection(module);
    try w.writeTagSection(module);
    try w.writeGlobalSection(module);
    try w.writeExportSection(module);
    try w.writeStartSection(module);
    try w.writeElementSection(module);
    try w.writeDataCountSection(module);
    try w.writeCodeSection(module);
    try w.writeDataSection(module);
    try w.writeCustomSections(module);

    return w.buf.toOwnedSlice(allocator);
}

// ── Internal writer ─────────────────────────────────────────────────────

const Writer = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),

    // -- primitives --

    fn appendByte(self: *Writer, b: u8) WriteError!void {
        try self.buf.append(self.allocator, b);
    }

    fn appendSlice(self: *Writer, s: []const u8) WriteError!void {
        try self.buf.appendSlice(self.allocator, s);
    }

    fn writeU32LE(self: *Writer, v: u32) WriteError!void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        try self.appendSlice(&tmp);
    }

    fn writeU32Leb(self: *Writer, v: u32) WriteError!void {
        var tmp: [leb128.max_u32_bytes]u8 = undefined;
        const n = leb128.writeU32Leb128(&tmp, v);
        try self.appendSlice(tmp[0..n]);
    }

    fn writeS32Leb(self: *Writer, v: i32) WriteError!void {
        var tmp: [leb128.max_s32_bytes]u8 = undefined;
        const n = leb128.writeS32Leb128(&tmp, v);
        try self.appendSlice(tmp[0..n]);
    }

    fn writeS64Leb(self: *Writer, v: i64) WriteError!void {
        var tmp: [leb128.max_s64_bytes]u8 = undefined;
        const n = leb128.writeS64Leb128(&tmp, v);
        try self.appendSlice(tmp[0..n]);
    }

    fn writeName(self: *Writer, name: []const u8) WriteError!void {
        try self.writeU32Leb(@intCast(name.len));
        try self.appendSlice(name);
    }

    fn writeValType(self: *Writer, vt: types.ValType) WriteError!void {
        try self.writeValTypeWithTidx(vt, 0xFFFFFFFF);
    }

    fn writeValTypeWithTidx(self: *Writer, vt: types.ValType, tidx: u32) WriteError!void {
        if ((vt == .concrete_ref_null or vt == .concrete_ref) and tidx != 0xFFFFFFFF) {
            // Concrete typed ref: write prefix + type index
            try self.appendByte(if (vt == .concrete_ref_null) reader.ref_null_prefix else reader.ref_prefix);
            try self.writeS64Leb(@intCast(tidx));
        } else if (vt == .ref_func) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x70); // func
        } else if (vt == .ref_extern) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x6F); // extern
        } else if (vt == .ref_any) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x6E); // any
        } else if (vt == .ref_none) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x71); // none
        } else if (vt == .ref_nofunc) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x73); // nofunc
        } else if (vt == .ref_noextern) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x72); // noextern
        } else if (vt == .ref_eq) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x6D); // eq
        } else if (vt == .ref_i31) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x6C); // i31
        } else if (vt == .ref_struct) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x6B); // struct
        } else if (vt == .ref_array) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x6A); // array
        } else if (vt == .ref_exn) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x69); // exn
        } else if (vt == .ref_noexn) {
            try self.appendByte(reader.ref_prefix); // ref
            try self.appendByte(0x74); // noexn
        } else {
            try self.appendByte(@bitCast(@as(i8, @intCast(@backingInt(vt)))));
        }
    }

    const LimitsKind = enum { table, memory };

    fn validateMemoryLimits(limits: types.Limits) WriteError!void {
        const max_pages = types.memoryMaxPages(limits.is_64, limits.page_size) orelse
            return error.InvalidLimits;
        if (limits.initial > max_pages) return error.InvalidLimits;
        if (limits.has_max and
            (limits.max > max_pages or limits.max < limits.initial))
            return error.InvalidLimits;
    }

    fn writeLimits(
        self: *Writer,
        limits: types.Limits,
        kind: LimitsKind,
    ) WriteError!void {
        if (kind == .table and limits.is_shared) return error.InvalidLimits;
        if (limits.is_shared and !limits.has_max) return error.InvalidLimits;
        if (kind == .memory) {
            try validateMemoryLimits(limits);
        } else if (limits.usesCustomPageSize()) {
            return error.InvalidLimits;
        }

        var flags: u8 = 0;
        if (limits.has_max) flags |= 0x01;
        if (limits.is_shared) flags |= 0x02;
        // Auto-detect 64-bit: if values exceed u32 range, force 64-bit encoding
        const needs_64 = limits.is_64 or limits.initial > std.math.maxInt(u32) or
            (limits.has_max and limits.max > std.math.maxInt(u32));
        if (needs_64) flags |= 0x04;
        const custom_page_size = kind == .memory and limits.usesCustomPageSize();
        const page_size_log2 = if (custom_page_size)
            types.memoryPageSizeLog2(limits.page_size) orelse
                return error.InvalidLimits
        else
            0;
        if (custom_page_size) flags |= 0x08;
        try self.appendByte(flags);

        if (needs_64) {
            var tmp: [leb128.max_u64_bytes]u8 = undefined;
            var n = leb128.writeU64Leb128(&tmp, limits.initial);
            try self.appendSlice(tmp[0..n]);
            if (limits.has_max) {
                n = leb128.writeU64Leb128(&tmp, limits.max);
                try self.appendSlice(tmp[0..n]);
            }
        } else {
            try self.writeU32Leb(@intCast(limits.initial));
            if (limits.has_max) try self.writeU32Leb(@intCast(limits.max));
        }

        if (custom_page_size) try self.writeU32Leb(page_size_log2);
    }

    // -- section helpers --

    fn beginSection(self: *Writer, id: u8) WriteError!usize {
        try self.appendByte(id);
        const placeholder = self.buf.items.len;
        // Reserve 5 bytes for section size (fixed-length LEB128)
        try self.appendSlice(&[5]u8{ 0, 0, 0, 0, 0 });
        return placeholder;
    }

    fn endSection(self: *Writer, placeholder: usize) void {
        const size: u32 = @intCast(self.buf.items.len - placeholder - 5);
        var tmp: [5]u8 = undefined;
        leb128.writeFixedU32Leb128(&tmp, size);
        @memcpy(self.buf.items[placeholder .. placeholder + 5], &tmp);
    }

    // -- sections --

    fn writeTypeSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const empty_rec_group_positions = module.empty_rec_group_positions.items;
        if (module.module_types.items.len == 0 and empty_rec_group_positions.len == 0) return;
        const ph = try self.beginSection(1);
        // Count top-level entries: each rec group counts as 1 however many
        // types it holds, and each standalone type counts as 1. A group of one
        // is still a group, so the span is taken from `in_rec_group` rather
        // than from the group size.
        var top_count: u32 = 0;
        {
            var i: usize = 0;
            while (i < module.module_types.items.len) {
                const m = if (i < module.type_meta.items.len) module.type_meta.items[i] else Mod.TypeMeta{};
                i += if (m.in_rec_group) m.rec_group_size else 1;
                top_count += 1;
            }
        }
        top_count += @intCast(empty_rec_group_positions.len);
        try self.writeU32Leb(top_count);
        var idx: usize = 0;
        var empty_rec_group_index: usize = 0;
        while (idx < module.module_types.items.len) {
            while (empty_rec_group_index < empty_rec_group_positions.len and
                @as(usize, @intCast(empty_rec_group_positions[empty_rec_group_index])) <= idx)
            {
                try self.appendByte(0x4E); // empty rec group marker
                try self.writeU32Leb(0);
                empty_rec_group_index += 1;
            }
            const meta = if (idx < module.type_meta.items.len) module.type_meta.items[idx] else Mod.TypeMeta{};
            if (meta.in_rec_group) {
                try self.appendByte(0x4E); // rec group marker
                try self.writeU32Leb(meta.rec_group_size);
                var ri: u32 = 0;
                while (ri < meta.rec_group_size) : (ri += 1) {
                    const sub_idx = idx + ri;
                    const sub_meta = if (sub_idx < module.type_meta.items.len) module.type_meta.items[sub_idx] else Mod.TypeMeta{};
                    try self.writeOneType(module, sub_idx, sub_meta);
                }
                idx += meta.rec_group_size;
            } else {
                try self.writeOneType(module, idx, meta);
                idx += 1;
            }
        }
        while (empty_rec_group_index < empty_rec_group_positions.len) : (empty_rec_group_index += 1) {
            try self.appendByte(0x4E); // empty rec group marker
            try self.writeU32Leb(0);
        }
        self.endSection(ph);
    }

    fn writeOneType(self: *Writer, module: *const Mod.Module, idx: usize, meta: Mod.TypeMeta) WriteError!void {
        if (meta.is_sub or !meta.is_final or meta.parent != std.math.maxInt(u32)) {
            // sub/sub final type
            try self.appendByte(if (meta.is_final) 0x4F else 0x50);
            if (meta.parent != std.math.maxInt(u32)) {
                try self.writeU32Leb(1);
                try self.writeU32Leb(meta.parent);
            } else {
                try self.writeU32Leb(0);
            }
        }
        if (idx < module.module_types.items.len) {
            switch (module.module_types.items[idx]) {
                .func_type => |ft| {
                    try self.appendByte(0x60);
                    try self.writeU32Leb(@intCast(ft.params.len));
                    for (ft.params, 0..) |p, pi| {
                        const tidx: u32 = if (pi < ft.param_type_idxs.len) ft.param_type_idxs[pi] else 0xFFFFFFFF;
                        try self.writeValTypeWithTidx(p, tidx);
                    }
                    try self.writeU32Leb(@intCast(ft.results.len));
                    for (ft.results, 0..) |r, ri| {
                        const tidx: u32 = if (ri < ft.result_type_idxs.len) ft.result_type_idxs[ri] else 0xFFFFFFFF;
                        try self.writeValTypeWithTidx(r, tidx);
                    }
                },
                .struct_type => |st| {
                    try self.appendByte(0x5F);
                    try self.writeU32Leb(@intCast(st.fields.items.len));
                    for (st.fields.items) |f| {
                        try self.writeValTypeWithTidx(f.type, f.type_idx);
                        try self.appendByte(if (f.mutable) 1 else 0);
                    }
                },
                .array_type => |at| {
                    try self.appendByte(0x5E);
                    try self.writeValTypeWithTidx(at.field.type, at.field.type_idx);
                    try self.appendByte(if (at.field.mutable) 1 else 0);
                },
            }
        }
    }

    fn writeImportSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        if (module.imports.items.len == 0) return;
        const ph = try self.beginSection(2);
        try self.writeU32Leb(@intCast(module.imports.items.len));
        var tag_import_idx: usize = 0;
        for (module.imports.items) |imp| {
            try self.writeName(imp.module_name);
            try self.writeName(imp.field_name);
            try self.appendByte(@backingInt(imp.kind));
            switch (imp.kind) {
                .func => try self.writeU32Leb(if (imp.func) |f| f.type_var.index else 0),
                .table => {
                    if (imp.table) |t| {
                        try self.writeValTypeWithTidx(t.elem_type, imp.table_type_idx);
                        try self.writeLimits(t.limits, .table);
                    }
                },
                .memory => {
                    if (imp.memory) |m| try self.writeLimits(m.limits, .memory);
                },
                .global => {
                    if (imp.global) |g| {
                        try self.writeValTypeWithTidx(g.val_type, imp.global_type_idx);
                        try self.appendByte(if (g.mutability == .mutable) @as(u8, 1) else 0);
                    }
                },
                .tag => {
                    // The signature index lives on the `Tag`, not the
                    // `Import`, so the nth tag import has to be paired with
                    // the nth imported entry of `module.tags`. Selecting it
                    // by `is_import` rather than by position is what makes
                    // that pairing hold: the text parser appends tags in
                    // source order, so `(tag $a ...) (import ... (tag $b))`
                    // leaves the import *second*, and slicing off the first
                    // `num_tag_imports` entries would hand each tag the
                    // other one's signature.
                    try self.appendByte(0); // attribute: 0 = exception
                    const tag = nthImportedTag(module, tag_import_idx);
                    tag_import_idx += 1;
                    try self.writeU32Leb(if (tag) |t| tagTypeIndex(module, t) else 0);
                },
            }
        }
        self.endSection(ph);
    }

    fn writeFunctionSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.funcs.items.len - module.num_func_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(3);
        try self.writeU32Leb(@intCast(defined));
        for (module.funcs.items[module.num_func_imports..]) |func| {
            try self.writeU32Leb(func.decl.type_var.index);
        }
        self.endSection(ph);
    }

    fn writeTableSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.tables.items.len - module.num_table_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(4);
        try self.writeU32Leb(@intCast(defined));
        for (module.tables.items[module.num_table_imports..]) |table| {
            const et = table.type.elem_type;
            if (table.hasInitExpr()) {
                // Table with init expression: 0x40 0x00 reftype limits expr
                try self.appendByte(0x40);
                try self.appendByte(0x00);
                try self.writeValTypeWithTidx(et, table.type_idx);
                try self.writeLimits(table.type.limits, .table);
                try self.appendSlice(table.init_expr_bytes);
                try self.appendByte(0x0b);
            } else if ((et == .concrete_ref_null or et == .concrete_ref) and table.type_idx != 0xFFFFFFFF) {
                // Typed reference: write prefix + concrete type index
                try self.appendByte(if (et == .concrete_ref_null) reader.ref_null_prefix else reader.ref_prefix);
                try self.writeS64Leb(@intCast(table.type_idx));
                try self.writeLimits(table.type.limits, .table);
            } else {
                try self.writeValType(et);
                try self.writeLimits(table.type.limits, .table);
            }
        }
        self.endSection(ph);
    }

    fn writeMemorySection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.memories.items.len - module.num_memory_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(5);
        try self.writeU32Leb(@intCast(defined));
        for (module.memories.items[module.num_memory_imports..]) |mem| {
            try self.writeLimits(mem.type.limits, .memory);
        }
        self.endSection(ph);
    }

    /// Signature index to write for a tag: the one it was read or parsed
    /// with, falling back to a structural match when the tag was built
    /// without one. Shared by the import and tag sections so an imported and
    /// a defined tag with the same signature cannot resolve differently.
    fn tagTypeIndex(module: *const Mod.Module, tag: Mod.Tag) u32 {
        if (tag.type_idx != std.math.maxInt(u32)) return tag.type_idx;
        return findMatchingType(module, tag.type.sig.params, tag.type.sig.results) orelse 0;
    }

    /// The `idx`th imported tag in import order. Imported and defined tags
    /// share one list and the text parser interleaves them, so they can only
    /// be told apart by `is_import`.
    fn nthImportedTag(module: *const Mod.Module, idx: usize) ?Mod.Tag {
        var seen: usize = 0;
        for (module.tags.items) |tag| {
            if (!tag.is_import) continue;
            if (seen == idx) return tag;
            seen += 1;
        }
        return null;
    }

    fn writeTagSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.tags.items.len - module.num_tag_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(13); // tag section ID
        try self.writeU32Leb(@intCast(defined));
        for (module.tags.items) |tag| {
            if (tag.is_import) continue;
            try self.appendByte(0); // attribute: 0 = exception
            try self.writeU32Leb(tagTypeIndex(module, tag));
        }
        self.endSection(ph);
    }

    fn findMatchingType(module: *const Mod.Module, params: []const types.ValType, results: []const types.ValType) ?u32 {
        for (module.module_types.items, 0..) |entry, i| {
            switch (entry) {
                .func_type => |ft| {
                    if (ft.params.len == params.len and ft.results.len == results.len) {
                        var match = true;
                        for (ft.params, params) |a, b| {
                            if (a != b) {
                                match = false;
                                break;
                            }
                        }
                        if (match) {
                            for (ft.results, results) |a, b| {
                                if (a != b) {
                                    match = false;
                                    break;
                                }
                            }
                        }
                        if (match) return @intCast(i);
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn writeGlobalSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.globals.items.len - module.num_global_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(6);
        try self.writeU32Leb(@intCast(defined));
        for (module.globals.items[module.num_global_imports..]) |global| {
            try self.writeValTypeWithTidx(global.type.val_type, global.type_idx);
            try self.appendByte(if (global.type.mutability == .mutable) @as(u8, 1) else 0);
            // Write init expression
            if (global.init_expr_bytes.len > 0) {
                try self.appendSlice(global.init_expr_bytes);
                try self.appendByte(0x0b);
            } else {
                // Empty init expression: emit just end opcode (invalid per spec)
                try self.appendByte(0x0b);
            }
        }
        self.endSection(ph);
    }

    fn writeExportSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        if (module.exports.items.len == 0) return;
        const ph = try self.beginSection(7);
        try self.writeU32Leb(@intCast(module.exports.items.len));
        for (module.exports.items) |exp| {
            try self.writeName(exp.name);
            try self.appendByte(@backingInt(exp.kind));
            try self.writeU32Leb(exp.var_.index);
        }
        self.endSection(ph);
    }

    fn writeStartSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const sv = module.start_var orelse return;
        const ph = try self.beginSection(8);
        try self.writeU32Leb(sv.index);
        self.endSection(ph);
    }

    fn writeElementSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        if (module.elem_segments.items.len == 0) return;
        const ph = try self.beginSection(9);
        try self.writeU32Leb(@intCast(module.elem_segments.items.len));
        for (module.elem_segments.items) |seg| {
            // `table 0` can be explicit too. Preserve that distinction after
            // text or binary round trips, while still accepting callers that
            // only populated the non-default table index in the legacy IR.
            const has_table_idx = seg.kind == .active and
                (seg.has_explicit_table_index or seg.table_var.index != 0);
            // A segment that names a reference type holds expressions even
            // when it holds none of them: an empty segment of some other
            // type still has to say which type, and only the expression
            // form has anywhere to say it.
            const has_exprs = seg.elem_expr_bytes.len > 0 or seg.uses_elem_exprs;

            // The eight element flags are distinct encodings, not independent
            // bits: a passive function-index segment is flag 1, while flag 3
            // is declarative. Expression segments whose active table is
            // implicit only use flag 4 for funcref; every other reference type
            // needs flag 6 so its reftype has a place in the binary.
            const needs_explicit_reftype = has_exprs and seg.elem_type != .funcref;
            const flags: u32 = switch (seg.kind) {
                .active => if (has_exprs)
                    if (has_table_idx or needs_explicit_reftype) 6 else 4
                else if (has_table_idx) 2 else 0,
                .passive => if (has_exprs) 5 else 1,
                .declared => if (has_exprs) 7 else 3,
            };
            try self.writeU32Leb(flags);

            // Table index (for active with explicit table — bit 1 set)
            if (seg.kind == .active and (flags & 2) != 0) {
                try self.writeU32Leb(seg.table_var.index);
            }

            // Offset expression (only for active segments)
            if (seg.kind == .active) {
                if (seg.offset_expr_bytes.len > 0) {
                    try self.appendSlice(seg.offset_expr_bytes);
                    try self.appendByte(0x0b);
                } else {
                    // Empty offset expression: emit just end opcode (invalid per spec)
                    try self.appendByte(0x0b);
                }
            }

            if (has_exprs) {
                // Elem expressions: reftype + count + expression bytes
                if (flags & 3 != 0 or needs_explicit_reftype) {
                    // Non-active, explicit table, or non-default reftype: write reftype
                    try self.writeValTypeWithTidx(seg.elem_type, seg.elem_type_idx);
                }
                try self.writeU32Leb(seg.elem_expr_count);
                try self.appendSlice(seg.elem_expr_bytes);
            } else {
                // Function indices
                if (flags & 3 != 0) {
                    // Non-active or explicit table: write elemkind (0x00 = funcref)
                    try self.appendByte(0x00);
                }
                try self.writeU32Leb(@intCast(seg.elem_var_indices.items.len));
                for (seg.elem_var_indices.items) |v| {
                    try self.writeU32Leb(v.index);
                }
            }
        }
        self.endSection(ph);
    }

    fn writeDataCountSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        if (module.data_segments.items.len == 0) return;
        const ph = try self.beginSection(12); // data count section ID
        try self.writeU32Leb(@intCast(module.data_segments.items.len));
        self.endSection(ph);
    }

    fn writeCodeSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.funcs.items.len - module.num_func_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(10);
        try self.writeU32Leb(@intCast(defined));
        for (module.funcs.items[module.num_func_imports..]) |func| {
            const body_ph = self.buf.items.len;
            try self.appendSlice(&[5]u8{ 0, 0, 0, 0, 0 }); // body size placeholder
            const body_start = self.buf.items.len;

            // Write compressed local declarations (run-length encoded)
            const locals = func.local_types.items;
            if (locals.len == 0) {
                try self.writeU32Leb(0);
            } else {
                // Count runs of same type
                var num_decls: u32 = 1;
                for (1..locals.len) |i| {
                    if (locals[i] != locals[i - 1]) num_decls += 1;
                }
                try self.writeU32Leb(num_decls);
                var run_start: usize = 0;
                while (run_start < locals.len) {
                    var run_end = run_start + 1;
                    while (run_end < locals.len and locals[run_end] == locals[run_start]) : (run_end += 1) {}
                    try self.writeU32Leb(@intCast(run_end - run_start));
                    const tidx: u32 = if (run_start < func.local_type_idxs.items.len) func.local_type_idxs.items[run_start] else 0xFFFFFFFF;
                    try self.writeValTypeWithTidx(locals[run_start], tidx);
                    run_start = run_end;
                }
            }

            // Write instruction bytes (includes final 0x0b end)
            if (func.code_bytes.len > 0) {
                try self.appendSlice(func.code_bytes);
            } else {
                try self.appendByte(0x0b); // bare end for empty bodies
            }

            const body_size: u32 = @intCast(self.buf.items.len - body_start);
            var tmp: [5]u8 = undefined;
            leb128.writeFixedU32Leb128(&tmp, body_size);
            @memcpy(self.buf.items[body_ph .. body_ph + 5], &tmp);
        }
        self.endSection(ph);
    }

    fn writeDataSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        if (module.data_segments.items.len == 0) return;
        const ph = try self.beginSection(11);
        try self.writeU32Leb(@intCast(module.data_segments.items.len));
        for (module.data_segments.items) |seg| {
            if (seg.kind == .passive) {
                try self.writeU32Leb(1); // flags: passive
            } else {
                const mem_idx = seg.memory_var.index;
                if (mem_idx != 0) {
                    try self.writeU32Leb(2); // flags: active, explicit memory index
                    try self.writeU32Leb(mem_idx);
                } else {
                    try self.writeU32Leb(0); // flags: active, memory 0 (implicit)
                }
                // Write offset expression
                if (seg.offset_expr_bytes.len > 0) {
                    try self.appendSlice(seg.offset_expr_bytes);
                    try self.appendByte(0x0b);
                } else {
                    // Empty offset expression: emit just end opcode (invalid per spec)
                    try self.appendByte(0x0b);
                }
            }
            try self.writeU32Leb(@intCast(seg.data.len));
            try self.appendSlice(seg.data);
        }
        self.endSection(ph);
    }

    fn writeCustomSections(self: *Writer, module: *const Mod.Module) WriteError!void {
        for (module.customs.items) |custom| {
            const ph = try self.beginSection(0);
            try self.writeName(custom.name);
            try self.appendSlice(custom.data);
            self.endSection(ph);
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "write empty module" {
    const allocator = std.testing.allocator;
    var module = Mod.Module.init(allocator);
    defer module.deinit();

    const bytes = try writeModule(allocator, &module);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    try std.testing.expect(std.mem.eql(u8, bytes[0..4], &reader.magic));
}

test "round-trip type section" {
    const allocator = std.testing.allocator;
    const input = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    };
    var module = try reader.readModule(allocator, &input);
    defer module.deinit();

    const output = try writeModule(allocator, &module);
    defer allocator.free(output);

    // Should contain type section
    try std.testing.expect(output.len > 8);
    try std.testing.expectEqual(@as(usize, 1), module.module_types.items.len);
}
