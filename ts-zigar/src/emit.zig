const std = @import("std");
const ir = @import("ir.zig");
const naming = @import("naming.zig");
const lower_types = @import("lower_types.zig");

pub const EmittedFile = struct {
    /// POSIX relative path inside `out_dir` (e.g. `"root.zig"`, `"fs/promises.zig"`).
    rel_path: []const u8,
    /// Canonically formatted Zig 0.17 source code verified with `std.zig.Ast.parse`.
    contents: []const u8,

    pub fn deinit(self: EmittedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.rel_path);
        allocator.free(self.contents);
    }
};

pub const EmitBundle = struct {
    files: []EmittedFile,

    pub fn deinit(self: *EmitBundle, allocator: std.mem.Allocator) void {
        for (self.files) |f| f.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }

    pub fn findFile(self: *const EmitBundle, rel_path: []const u8) ?[]const u8 {
        for (self.files) |f| {
            if (std.mem.eql(u8, f.rel_path, rel_path)) return f.contents;
        }
        return null;
    }
};

pub const EmitOutcome = union(enum) {
    ok: EmitBundle,
    ast_error: []u8,

    pub fn deinit(self: *EmitOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*b| b.deinit(allocator),
            .ast_error => |msg| allocator.free(msg),
        }
    }
};

/// Validates `raw_source` with `std.zig.Ast.parse(allocator, source_z, .{ .mode = .zig })` and
/// returns canonically formatted Zig 0.17 code via `tree.renderAlloc(allocator)`, or a detailed
/// diagnostic message containing file, line, column, error tag, and offending source line snippet.
pub const ValidationResult = union(enum) {
    formatted: []u8,
    diagnostic: []u8,
};

pub fn validateAndFormatZigSource(
    allocator: std.mem.Allocator,
    file_label: []const u8,
    raw_source: []const u8,
) std.mem.Allocator.Error!ValidationResult {
    const source_z = try allocator.allocSentinel(u8, raw_source.len, 0);
    @memcpy(source_z, raw_source);
    defer allocator.free(source_z);

    var tree = try std.zig.Ast.parse(allocator, source_z, .{ .mode = .zig });
    defer tree.deinit(allocator);

    if (tree.errors.len > 0) {
        var diag: std.ArrayList(u8) = .empty;
        errdefer diag.deinit(allocator);

        try diag.print(allocator, "Zig 0.17 AST validation failed for '{s}' ({d} error(s)):\n", .{
            file_label,
            tree.errors.len,
        });

        for (tree.errors) |err| {
            const loc = tree.tokenLocation(0, err.token);
            const line_end_rel = std.mem.indexOfScalar(u8, raw_source[loc.line_start..], '\n') orelse
                (raw_source.len - loc.line_start);
            const line_text = raw_source[loc.line_start .. loc.line_start + line_end_rel];

            try diag.print(allocator, "  {s}:{d}:{d}: error ({s})\n", .{
                file_label,
                loc.line + 1,
                loc.column + 1,
                @tagName(err.tag),
            });
            try diag.print(allocator, "    {s}\n    ", .{line_text});
            for (0..loc.column) |_| try diag.append(allocator, ' ');
            try diag.appendSlice(allocator, "^\n");
        }

        return .{ .diagnostic = try diag.toOwnedSlice(allocator) };
    }

    var zir = try std.zig.AstGen.generate(allocator, tree);
    defer zir.deinit(allocator);

    if (zir.hasCompileErrors()) {
        var wip = try std.zig.ErrorBundle.Wip.init(allocator);
        defer wip.deinit();
        try wip.addZirErrorMessages(zir, tree, source_z, file_label);
        var bundle = try wip.toOwnedBundle("");
        defer bundle.deinit(allocator);

        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        aw.writer.print("Zig 0.17 ZIR (AstGen) validation failed for '{s}':\n", .{file_label}) catch return error.OutOfMemory;
        bundle.renderToWriter(.{}, &aw.writer) catch return error.OutOfMemory;
        return .{ .diagnostic = try aw.toOwnedSlice() };
    }

    const formatted = try tree.renderAlloc(allocator);
    return .{ .formatted = formatted };
}

/// Emits and AST-validates all module `.zig` files plus `root.zig` for `pkg`.
pub fn emitPackage(allocator: std.mem.Allocator, pkg: *const ir.PackageIr) std.mem.Allocator.Error!EmitOutcome {
    var files: std.ArrayList(EmittedFile) = .empty;
    errdefer {
        for (files.items) |f| f.deinit(allocator);
        files.deinit(allocator);
    }

    for (pkg.modules) |*mod| {
        const raw_mod = try renderModuleRaw(allocator, pkg, mod);
        defer allocator.free(raw_mod);

        switch (try validateAndFormatZigSource(allocator, mod.rel_zig_path, raw_mod)) {
            .formatted => |fmt_src| {
                const rel_owned = try allocator.dupe(u8, mod.rel_zig_path);
                errdefer allocator.free(rel_owned);
                try files.append(allocator, .{
                    .rel_path = rel_owned,
                    .contents = fmt_src,
                });
            },
            .diagnostic => |diag_msg| {
                for (files.items) |f| f.deinit(allocator);
                files.deinit(allocator);
                return .{ .ast_error = diag_msg };
            },
        }
    }

    const raw_rt = try renderRuntimeRaw(allocator);
    defer allocator.free(raw_rt);

    switch (try validateAndFormatZigSource(allocator, "__zigar_runtime.zig", raw_rt)) {
        .formatted => |fmt_rt| {
            const rel_owned = try allocator.dupe(u8, "__zigar_runtime.zig");
            errdefer allocator.free(rel_owned);
            try files.append(allocator, .{
                .rel_path = rel_owned,
                .contents = fmt_rt,
            });
        },
        .diagnostic => |diag_msg| {
            for (files.items) |f| f.deinit(allocator);
            files.deinit(allocator);
            return .{ .ast_error = diag_msg };
        },
    }

    const raw_root = try renderRootRaw(allocator, pkg);
    defer allocator.free(raw_root);

    switch (try validateAndFormatZigSource(allocator, "root.zig", raw_root)) {
        .formatted => |fmt_root| {
            const rel_owned = try allocator.dupe(u8, "root.zig");
            errdefer allocator.free(rel_owned);
            try files.append(allocator, .{
                .rel_path = rel_owned,
                .contents = fmt_root,
            });
        },
        .diagnostic => |diag_msg| {
            for (files.items) |f| f.deinit(allocator);
            files.deinit(allocator);
            return .{ .ast_error = diag_msg };
        },
    }

    return .{
        .ok = .{
            .files = try files.toOwnedSlice(allocator),
        },
    };
}

/// Writes all emitted `.zig` files in `bundle` to `out_dir_path`, creating subdirectories as needed.
pub fn writeBundleToDisk(
    io: std.Io,
    out_dir_path: []const u8,
    bundle: *const EmitBundle,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, out_dir_path);
    var out_dir = try std.Io.Dir.cwd().openDir(io, out_dir_path, .{});
    defer out_dir.close(io);

    for (bundle.files) |file| {
        if (std.mem.lastIndexOfScalar(u8, file.rel_path, '/')) |slash| {
            const sub_dir = file.rel_path[0..slash];
            if (sub_dir.len > 0) {
                try out_dir.createDirPath(io, sub_dir);
            }
        }
        try out_dir.writeFile(io, .{
            .sub_path = file.rel_path,
            .data = file.contents,
        });
    }
}

/// Appends sanitized `///` Zig doc-comment lines for `jsdoc`.
/// - Normalizes `\r\n` and `\r` to `\n`.
/// - Strips control characters (`< 0x20` except `\t`/`\n`, plus `0x7f`) and invalid UTF-8 bytes.
/// - Always places a space after `///` on non-empty lines so `////` or `//!` can NEVER occur!
pub fn appendJsDocComments(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    jsdoc: ir.JsDocIr,
) !void {
    var has_prev_section = false;

    if (jsdoc.deprecated) |reason| {
        if (reason.len > 0) {
            try appendSanitizedDocBlock(out, allocator, "Deprecated: ", reason);
        } else {
            try out.appendSlice(allocator, "/// Deprecated.\n");
        }
        has_prev_section = true;
    }

    if (jsdoc.summary.len > 0) {
        if (has_prev_section) try out.appendSlice(allocator, "///\n");
        try appendSanitizedDocBlock(out, allocator, "", jsdoc.summary);
        has_prev_section = true;
    }

    if (jsdoc.params.len > 0) {
        if (has_prev_section) try out.appendSlice(allocator, "///\n");
        for (jsdoc.params) |p| {
            const prefix = if (p.description.len > 0)
                try std.fmt.allocPrint(allocator, "@param {s} - ", .{p.name})
            else
                try std.fmt.allocPrint(allocator, "@param {s}", .{p.name});
            defer allocator.free(prefix);
            try appendSanitizedDocBlock(out, allocator, prefix, p.description);
        }
        has_prev_section = true;
    }

    if (jsdoc.returns) |ret_doc| {
        if (ret_doc.len > 0) {
            if (has_prev_section) try out.appendSlice(allocator, "///\n");
            try appendSanitizedDocBlock(out, allocator, "@returns ", ret_doc);
            has_prev_section = true;
        }
    }

    for (jsdoc.throws) |th| {
        if (th.len > 0) {
            if (has_prev_section) try out.appendSlice(allocator, "///\n");
            try appendSanitizedDocBlock(out, allocator, "@throws ", th);
            has_prev_section = true;
        }
    }

    for (jsdoc.examples) |ex| {
        if (ex.len > 0) {
            if (has_prev_section) try out.appendSlice(allocator, "///\n");
            try out.appendSlice(allocator, "/// @example\n");
            try appendSanitizedDocBlock(out, allocator, "", ex);
            has_prev_section = true;
        }
    }
}

fn appendSanitizedDocBlock(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    first_line_prefix: []const u8,
    raw_text: []const u8,
) !void {
    // Normalize `\r\n` and `\r` to `\n`, replace `\t` with spaces, strip invalid control bytes.
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(allocator);

    var i: usize = 0;
    while (i < raw_text.len) {
        const b = raw_text[i];
        if (b == '\r') {
            if (i + 1 < raw_text.len and raw_text[i + 1] == '\n') {
                i += 2;
            } else {
                i += 1;
            }
            try clean.append(allocator, '\n');
            continue;
        }
        if (b == '\n') {
            try clean.append(allocator, '\n');
            i += 1;
            continue;
        }
        if (b == '\t') {
            try clean.appendSlice(allocator, "    ");
            i += 1;
            continue;
        }
        if (b < 0x20 or b == 0x7f) {
            i += 1;
            continue;
        }
        if (b < 0x80) {
            try clean.append(allocator, b);
            i += 1;
            continue;
        }
        // Validate multi-byte UTF-8 sequence; replace invalid byte with '?'.
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            try clean.append(allocator, '?');
            i += 1;
            continue;
        };
        if (i + seq_len <= raw_text.len and std.unicode.utf8ValidateSlice(raw_text[i .. i + seq_len])) {
            try clean.appendSlice(allocator, raw_text[i .. i + seq_len]);
            i += seq_len;
        } else {
            try clean.append(allocator, '?');
            i += 1;
        }
    }

    const text = std.mem.trim(u8, clean.items, "\n");
    if (text.len == 0) {
        const pref_trim = std.mem.trimEnd(u8, first_line_prefix, " ");
        if (pref_trim.len > 0) {
            try out.appendSlice(allocator, "/// ");
            try out.appendSlice(allocator, pref_trim);
            try out.append(allocator, '\n');
        }
        return;
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " ");
        if (first) {
            first = false;
            if (first_line_prefix.len > 0 or line.len > 0) {
                try out.appendSlice(allocator, "/// ");
                try appendSafePrefixAndLine(out, allocator, first_line_prefix, line);
                try out.append(allocator, '\n');
            } else {
                try out.appendSlice(allocator, "///\n");
            }
        } else {
            if (line.len > 0) {
                try out.appendSlice(allocator, "/// ");
                try appendSafePrefixAndLine(out, allocator, "", line);
                try out.append(allocator, '\n');
            } else {
                try out.appendSlice(allocator, "///\n");
            }
        }
    }
}

fn appendSafePrefixAndLine(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
    line: []const u8,
) !void {
    for (prefix) |ch| {
        if (ch >= 0x20 and ch != 0x7f) try out.append(allocator, ch);
    }
    try out.appendSlice(allocator, line);
}

fn unquoteZigIdent(ident: []const u8) []const u8 {
    if (ident.len >= 3 and std.mem.startsWith(u8, ident, "@\"") and ident[ident.len - 1] == '"') {
        return ident[2 .. ident.len - 1];
    }
    return ident;
}

const ModuleEmitCtx = struct {
    allocator: std.mem.Allocator,
    pkg: *const ir.PackageIr,
    mod: *const ir.ModuleIr,
    out: std.ArrayList(u8) = .empty,
    nested_decl_scopes: std.ArrayList([]const []const u8) = .empty,
    ns_wire_path: std.ArrayList([]const u8) = .empty,
    active_source_decls: std.AutoHashMapUnmanaged(u32, void) = .empty,
    emit_depth: usize = 0,
    ret_type_counter: u32 = 0,
    used_self_mod_alias: bool = false,

    fn deinit(self: *ModuleEmitCtx) void {
        self.out.deinit(self.allocator);
        self.nested_decl_scopes.deinit(self.allocator);
        self.ns_wire_path.deinit(self.allocator);
        self.active_source_decls.deinit(self.allocator);
    }

    fn isExportEqualsRootDecl(self: *const ModuleEmitCtx, d: ir.DeclIr) bool {
        if (self.ns_wire_path.items.len != 0) return false;
        const eq_wire = self.mod.export_equals_wire_name orelse return false;
        return std.mem.eql(u8, eq_wire, d.wire_name);
    }

    fn emitCallTargetLiteral(
        self: *ModuleEmitCtx,
        is_global_scope: bool,
        wire_name: []const u8,
        is_default_call: bool,
        extra_seg: ?[]const u8,
    ) !void {
        try self.out.appendSlice(self.allocator, ".{ ");
        if (!is_global_scope) {
            try self.out.appendSlice(self.allocator, ".module = ");
            try self.emitStringLit(self.mod.wire_specifier);
            try self.out.appendSlice(self.allocator, ", ");
        }
        var from_default = false;
        var ns_start: usize = 0;
        var skip_extra_seg = false;
        if (!is_global_scope) {
            if (self.mod.export_equals_wire_name) |eq_name| {
                if (self.ns_wire_path.items.len > 0) {
                    if (std.mem.eql(u8, self.ns_wire_path.items[0], eq_name)) {
                        from_default = true;
                        ns_start = 1;
                    }
                } else if (extra_seg) |es| {
                    if (std.mem.eql(u8, es, eq_name)) {
                        from_default = true;
                        skip_extra_seg = true;
                    }
                }
            }
        }
        const rem_ns = self.ns_wire_path.items[ns_start..];
        const eff_extra: ?[]const u8 = if (skip_extra_seg) null else extra_seg;
        if (rem_ns.len > 0 or eff_extra != null) {
            try self.out.appendSlice(self.allocator, ".ns_path = &.{ ");
            var seg_i: usize = 0;
            for (rem_ns) |seg| {
                if (seg_i > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.emitStringLit(seg);
                seg_i += 1;
            }
            if (eff_extra) |es| {
                if (seg_i > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.emitStringLit(es);
            }
            try self.out.appendSlice(self.allocator, " }, ");
        }
        try self.out.appendSlice(self.allocator, ".name = ");
        try self.emitStringLit(wire_name);
        if (is_default_call) {
            try self.out.appendSlice(self.allocator, ", .is_default = true");
        }
        if (from_default) {
            try self.out.appendSlice(self.allocator, ", .from_default = true");
        }
        try self.out.appendSlice(self.allocator, " }");
    }

    fn lookupImportAlias(self: *const ModuleEmitCtx, target_mod_idx: u32) ?[]const u8 {
        for (self.mod.imports) |imp| {
            if (imp.target_module_index == target_mod_idx) return imp.local_alias;
        }
        return null;
    }

    fn isShadowedInNestedScope(self: *const ModuleEmitCtx, ident: []const u8) bool {
        const needle = unquoteZigIdent(ident);
        for (self.nested_decl_scopes.items) |frame| {
            for (frame) |cand| {
                if (std.mem.eql(u8, unquoteZigIdent(cand), needle)) return true;
            }
        }
        return false;
    }

    fn isIdentTakenInCurrentScope(
        self: *const ModuleEmitCtx,
        ident: []const u8,
        type_params: []const ir.TypeParamIr,
    ) bool {
        if (self.isShadowedInNestedScope(ident)) return true;
        for (type_params) |tp| {
            if (std.mem.eql(u8, unquoteZigIdent(tp.zig_ident), ident)) return true;
        }
        for (self.mod.imports) |imp| {
            if (std.mem.eql(u8, unquoteZigIdent(imp.local_alias), ident)) return true;
        }
        for (self.mod.decls) |decl| {
            if (std.mem.eql(u8, unquoteZigIdent(decl.zig_ident), ident)) return true;
            if (decl.alloc_companion_ident) |aci| {
                if (std.mem.eql(u8, unquoteZigIdent(aci), ident)) return true;
            }
        }
        return false;
    }

    fn freshPrivateRetTypeIdent(
        self: *ModuleEmitCtx,
        type_params: []const ir.TypeParamIr,
    ) ![]u8 {
        while (true) {
            self.ret_type_counter += 1;
            const cand = try std.fmt.allocPrint(self.allocator, "__ZigarRet_{d}", .{self.ret_type_counter});
            if (!self.isIdentTakenInCurrentScope(cand, type_params)) return cand;
            self.allocator.free(cand);
        }
    }

    fn emitIdentSegment(self: *ModuleEmitCtx, seg: []const u8) !void {
        if (seg.len >= 3 and std.mem.startsWith(u8, seg, "@\"") and seg[seg.len - 1] == '"') {
            try self.out.appendSlice(self.allocator, seg);
            return;
        }
        const formatted = try naming.formatIdentifier(self.allocator, seg);
        defer self.allocator.free(formatted);
        try self.out.appendSlice(self.allocator, formatted);
    }

    fn emitStringLit(self: *ModuleEmitCtx, s: []const u8) !void {
        const lit = try naming.formatStringLiteral(self.allocator, s);
        defer self.allocator.free(lit);
        try self.out.appendSlice(self.allocator, lit);
    }

    fn emitType(self: *ModuleEmitCtx, ty: *const ir.TypeIr) error{OutOfMemory}!void {
        switch (ty.*) {
            .void_type => try self.out.appendSlice(self.allocator, "void"),
            .noreturn_type => try self.out.appendSlice(self.allocator, "noreturn"),
            .bool_type => try self.out.appendSlice(self.allocator, "bool"),
            .f64_type => try self.out.appendSlice(self.allocator, "f64"),
            .i64_type => try self.out.appendSlice(self.allocator, "i64"),
            .string_type, .bytes_type => try self.out.appendSlice(self.allocator, "[]const u8"),
            .typed_slice => |el| try self.out.print(self.allocator, "[]const {s}", .{@tagName(el)}),
            .js_value, .js_any => try self.out.appendSlice(self.allocator, "__zigar_js.Any"),
            .js_unknown => try self.out.appendSlice(self.allocator, "__zigar_js.Unknown"),
            .js_object => try self.out.appendSlice(self.allocator, "__zigar_js.Object"),
            .js_symbol => try self.out.appendSlice(self.allocator, "__zigar_js.Symbol"),
            .js_bigint => try self.out.appendSlice(self.allocator, "__zigar_js.BigInt"),
            .js_string => try self.out.appendSlice(self.allocator, "__zigar_js.String"),
            .binary_view => |bvk| try self.out.print(self.allocator, "__zigar_js.{s}", .{bvk.zigTypeIdent()}),
            .self_type => |sid| try self.emitIdentSegment(sid),
            .type_param_ref => |tp_ident| try self.out.appendSlice(self.allocator, tp_ident),
            .optional => |opt| {
                try self.out.append(self.allocator, '?');
                try self.emitType(opt.child);
            },
            .pointer_const => |inner| {
                try self.out.appendSlice(self.allocator, "*const ");
                try self.emitType(inner);
            },
            .slice => |inner| {
                try self.out.appendSlice(self.allocator, "[]const ");
                try self.emitType(inner);
            },
            .promise => |inner| {
                try self.out.appendSlice(self.allocator, "__zigar_js.Promise(");
                try self.emitType(inner);
                try self.out.append(self.allocator, ')');
            },
            .js_map => |m| {
                try self.out.appendSlice(self.allocator, "__zigar_js.Map(");
                try self.emitType(m.key);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitType(m.value);
                try self.out.append(self.allocator, ')');
            },
            .tuple => |elems| {
                var variadic_idx: ?usize = null;
                var optional_mask: u64 = 0;
                var null_only_mask: u64 = 0;
                for (elems, 0..) |el, idx| {
                    if (el.is_variadic) {
                        if (variadic_idx == null) variadic_idx = idx;
                    } else if (idx < 64) {
                        if (el.is_optional) {
                            optional_mask |= (@as(u64, 1) << @intCast(idx));
                        } else if (el.nullish_kind == .null_only) {
                            null_only_mask |= (@as(u64, 1) << @intCast(idx));
                        }
                    }
                }

                try self.out.appendSlice(self.allocator, "struct { ");
                for (elems, 0..) |el, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.out.print(self.allocator, "{s}: ", .{el.zig_ident});
                    try self.emitType(el.ty);
                    if (el.is_variadic) {
                        try self.out.appendSlice(self.allocator, " = &.{}");
                    } else if (el.ty.* == .optional) {
                        try self.out.appendSlice(self.allocator, " = null");
                    }
                }
                if (elems.len > 0) try self.out.appendSlice(self.allocator, ", ");
                if (variadic_idx) |vi| {
                    try self.out.print(
                        self.allocator,
                        "pub const zigar_js_tuple = .{{ .variadic_index = @as(?usize, {d}), .optional_mask = @as(u64, 0x{x}), .null_only_mask = @as(u64, 0x{x}) }};",
                        .{ vi, optional_mask, null_only_mask },
                    );
                } else {
                    try self.out.print(
                        self.allocator,
                        "pub const zigar_js_tuple = .{{ .variadic_index = @as(?usize, null), .optional_mask = @as(u64, 0x{x}), .null_only_mask = @as(u64, 0x{x}) }};",
                        .{ optional_mask, null_only_mask },
                    );
                }
                try self.out.appendSlice(self.allocator, " }");
            },
            .fn_ptr => |fp| {
                try self.out.appendSlice(self.allocator, "*const fn (");
                for (fp.params, 0..) |pt, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.emitType(pt);
                }
                try self.out.appendSlice(self.allocator, ") ");
                try self.emitType(fp.return_type);
            },
            .anon_struct => |fields| {
                try self.out.appendSlice(self.allocator, "struct {\n");
                for (fields) |f| {
                    if (f.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
                    try self.out.print(self.allocator, "{s}: ", .{f.zig_ident});
                    try self.emitType(f.ty);
                    if (f.ty.* == .optional) {
                        try self.out.appendSlice(self.allocator, " = null");
                    }
                    try self.out.appendSlice(self.allocator, ",\n");
                }
                try self.out.append(self.allocator, '}');
            },
            .tagged_union => |vars| {
                try self.out.appendSlice(self.allocator, "union(enum) {\n");
                for (vars) |v| {
                    try self.out.print(self.allocator, "{s}: ", .{v.zig_ident});
                    try self.emitType(v.payload);
                    try self.out.appendSlice(self.allocator, ",\n");
                }
                try self.out.append(self.allocator, '}');
            },
            .decl_ref => |dref| {
                if (dref.indirect) {
                    try self.out.appendSlice(self.allocator, "*const ");
                }
                if (dref.module_index != self.mod.index) {
                    if (self.lookupImportAlias(dref.module_index)) |alias| {
                        try self.out.print(self.allocator, "{s}.", .{alias});
                    }
                } else if (dref.decl_zig_path.len > 0 and self.isShadowedInNestedScope(dref.decl_zig_path[0])) {
                    self.used_self_mod_alias = true;
                    try self.out.appendSlice(self.allocator, "__zigar_mod.");
                }
                for (dref.decl_zig_path, 0..) |seg, idx| {
                    if (idx > 0) try self.out.append(self.allocator, '.');
                    try self.emitIdentSegment(seg);
                }
                if (dref.type_args.len > 0) {
                    try self.out.append(self.allocator, '(');
                    for (dref.type_args, 0..) |ta, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.emitType(ta);
                    }
                    try self.out.append(self.allocator, ')');
                }
            },
        }
    }

    fn emitLiteralConst(
        self: *ModuleEmitCtx,
        pub_kw: []const u8,
        zig_ident: []const u8,
        ty: *const ir.TypeIr,
        lit: ir.LiteralValueIr,
    ) !void {
        switch (lit) {
            .str => |s| {
                try self.out.print(self.allocator, "{s}const {s}: []const u8 = ", .{ pub_kw, zig_ident });
                try self.emitStringLit(s);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .boolean => |b| {
                try self.out.print(self.allocator, "{s}const {s}: bool = {s};\n", .{
                    pub_kw,
                    zig_ident,
                    if (b) "true" else "false",
                });
            },
            .num => |n| {
                try self.out.print(self.allocator, "{s}const {s}: f64 = ", .{ pub_kw, zig_ident });
                if (std.math.isNan(n)) {
                    try self.out.appendSlice(self.allocator, "@bitCast(@as(u64, 0x7ff8000000000000))");
                } else if (std.math.isPositiveInf(n)) {
                    try self.out.appendSlice(self.allocator, "@bitCast(@as(u64, 0x7ff0000000000000))");
                } else if (std.math.isNegativeInf(n)) {
                    try self.out.appendSlice(self.allocator, "@bitCast(@as(u64, 0xfff0000000000000))");
                } else {
                    try self.out.print(self.allocator, "{d}", .{n});
                }
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .bigint_val => |raw_bi| {
                _ = ty;
                const clean_bi = try lower_types.normalizeBigIntLiteral(self.allocator, raw_bi);
                defer self.allocator.free(clean_bi);
                if (std.fmt.parseInt(i64, clean_bi, 0)) |parsed_i64| {
                    try self.out.print(self.allocator, "{s}const {s}: i64 = {d};\n", .{ pub_kw, zig_ident, parsed_i64 });
                } else |_| if (std.fmt.parseInt(i128, clean_bi, 0)) |parsed_i128| {
                    try self.out.print(self.allocator, "{s}const {s}: i128 = {d};\n", .{ pub_kw, zig_ident, parsed_i128 });
                } else |_| {
                    try self.out.print(self.allocator, "{s}const {s}: []const u8 = ", .{ pub_kw, zig_ident });
                    try self.emitStringLit(clean_bi);
                    try self.out.appendSlice(self.allocator, ";\n");
                }
            },
        }
    }

    fn emitFunction(
        self: *ModuleEmitCtx,
        pub_kw: []const u8,
        zig_ident: []const u8,
        self_param_type: ?[]const u8,
        sig: ir.SignatureIr,
    ) !void {
        try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, zig_ident });
        var param_count: usize = 0;

        for (sig.type_params) |tp| {
            if (param_count > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
            param_count += 1;
        }

        const recv_ident = sig.self_param_ident orelse "self";
        if (self_param_type) |spt| {
            if (param_count > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s}: {s}", .{ recv_ident, spt });
            param_count += 1;
        }

        for (sig.params) |p| {
            if (param_count > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s}: ", .{p.zig_ident});
            try self.emitType(p.ty);
            param_count += 1;
        }

        try self.out.appendSlice(self.allocator, ") ");
        try self.emitType(sig.return_type);
        try self.out.appendSlice(self.allocator, " {\n");

        for (sig.type_params) |tp| {
            if (!signatureUsesTypeParam(sig, tp.zig_ident)) {
                try self.out.print(self.allocator, "_ = {s};\n", .{tp.zig_ident});
            }
        }
        if (self_param_type != null) {
            try self.out.print(self.allocator, "_ = {s};\n", .{recv_ident});
        }
        for (sig.params) |p| {
            try self.out.print(self.allocator, "_ = {s};\n", .{p.zig_ident});
        }
        try self.out.appendSlice(self.allocator, "@panic(\"ts-zigar host stub\");\n}\n");
    }

    fn paramNullishEmitTag(p: ir.ParamIr) []const u8 {
        if (p.is_optional) return "undefined_only";
        return switch (p.nullish_kind) {
            .none => "none",
            .undefined_only => "undefined_only",
            .null_only, .null_or_undefined => "null_only",
        };
    }

    fn emitCallableFunctionBody(
        self: *ModuleEmitCtx,
        d: ir.DeclIr,
        sig: ir.SignatureIr,
        alloc_ident_opt: ?[]const u8,
        ret_type_expr_opt: ?[]const u8,
        is_default_call: bool,
    ) !void {
        for (sig.type_params) |tp| {
            if (!signatureUsesTypeParam(sig, tp.zig_ident)) {
                try self.out.print(self.allocator, "_ = {s};\n", .{tp.zig_ident});
            }
        }

        const has_rest = sig.params.len > 0 and sig.params[sig.params.len - 1].is_rest;
        const fixed_len = if (has_rest) sig.params.len - 1 else sig.params.len;

        var first_trailing_opt: usize = fixed_len;
        while (first_trailing_opt > 0 and
            sig.params[first_trailing_opt - 1].is_optional and
            sig.params[first_trailing_opt - 1].ty.* == .optional)
        {
            first_trailing_opt -= 1;
        }

        try self.out.appendSlice(self.allocator, "const __zigar_args = try __zigar_js.initArgs();\ndefer __zigar_args.deinit();\n");
        if (first_trailing_opt < fixed_len) {
            try self.out.print(self.allocator, "var __zigar_argc: usize = {d};\n", .{fixed_len});
            if (has_rest) {
                try self.out.print(self.allocator, "if ({s}.len == 0) {{\n", .{sig.params[fixed_len].zig_ident});
            }
            var rev: usize = fixed_len;
            while (rev > first_trailing_opt) {
                rev -= 1;
                try self.out.print(
                    self.allocator,
                    "if (__zigar_argc == {d} and {s} == null) __zigar_argc = {d};\n",
                    .{ rev + 1, sig.params[rev].zig_ident, rev },
                );
            }
            if (has_rest) {
                try self.out.appendSlice(self.allocator, "}\n");
            }
        }
        for (sig.params[0..fixed_len], 0..) |p, pi| {
            const nk = paramNullishEmitTag(p);
            if (pi >= first_trailing_opt) {
                try self.out.print(
                    self.allocator,
                    "if (__zigar_argc > {d}) try __zigar_js.pushArg(__zigar_args, {s}, .{s});\n",
                    .{ pi, p.zig_ident, nk },
                );
            } else {
                try self.out.print(
                    self.allocator,
                    "try __zigar_js.pushArg(__zigar_args, {s}, .{s});\n",
                    .{ p.zig_ident, nk },
                );
            }
        }
        if (has_rest) {
            try self.out.print(
                self.allocator,
                "try __zigar_js.pushRestArgs(__zigar_args, {s});\n",
                .{sig.params[fixed_len].zig_ident},
            );
        }

        if (alloc_ident_opt) |alloc_param| {
            try self.out.appendSlice(self.allocator, "return __zigar_js.invokeTargetAlloc(");
            if (ret_type_expr_opt) |rtexpr| {
                try self.out.appendSlice(self.allocator, rtexpr);
            } else {
                try self.emitType(sig.return_type);
            }
            try self.out.print(self.allocator, ", {s}, ", .{alloc_param});
            try self.emitCallTargetLiteral(d.is_global_scope, d.wire_name, is_default_call, null);
            try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
        } else {
            try self.out.appendSlice(self.allocator, "return __zigar_js.invokeTarget(");
            if (ret_type_expr_opt) |rtexpr| {
                try self.out.appendSlice(self.allocator, rtexpr);
            } else {
                try self.emitType(sig.return_type);
            }
            try self.out.appendSlice(self.allocator, ", ");
            try self.emitCallTargetLiteral(d.is_global_scope, d.wire_name, is_default_call, null);
            try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
        }
    }

    fn emitCallableFunction(
        self: *ModuleEmitCtx,
        pub_kw: []const u8,
        d: ir.DeclIr,
        sig: ir.SignatureIr,
    ) !void {
        const is_default_call = !d.is_global_scope and
            self.ns_wire_path.items.len == 0 and
            (d.is_default_export or self.isExportEqualsRootDecl(d));

        var ret_type_expr_opt: ?[]u8 = null;
        defer if (ret_type_expr_opt) |buf| self.allocator.free(buf);

        if (typeHasInlineNominal(sig.return_type)) {
            const ret_ident = try self.freshPrivateRetTypeIdent(sig.type_params);
            defer self.allocator.free(ret_ident);

            if (sig.type_params.len == 0) {
                try self.out.print(self.allocator, "const {s} = ", .{ret_ident});
                try self.emitType(sig.return_type);
                try self.out.appendSlice(self.allocator, ";\n");
                ret_type_expr_opt = try self.allocator.dupe(u8, ret_ident);
            } else {
                try self.out.print(self.allocator, "fn {s}(", .{ret_ident});
                for (sig.type_params, 0..) |tp, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                }
                try self.out.appendSlice(self.allocator, ") type {\n");
                for (sig.type_params) |tp| {
                    if (!typeUsesTypeParam(sig.return_type, tp.zig_ident)) {
                        try self.out.print(self.allocator, "_ = {s};\n", .{tp.zig_ident});
                    }
                }
                try self.out.appendSlice(self.allocator, "return ");
                try self.emitType(sig.return_type);
                try self.out.appendSlice(self.allocator, ";\n}\n");

                var expr: std.ArrayList(u8) = .empty;
                errdefer expr.deinit(self.allocator);
                try expr.print(self.allocator, "{s}(", .{ret_ident});
                for (sig.type_params, 0..) |tp, idx| {
                    if (idx > 0) try expr.appendSlice(self.allocator, ", ");
                    try expr.appendSlice(self.allocator, tp.zig_ident);
                }
                try expr.append(self.allocator, ')');
                ret_type_expr_opt = try expr.toOwnedSlice(self.allocator);
            }
        }

        if (d.jsdoc) |jd| {
            try appendJsDocComments(&self.out, self.allocator, jd);
        }

        try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
        var param_count: usize = 0;
        for (sig.type_params) |tp| {
            if (param_count > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
            param_count += 1;
        }
        for (sig.params) |p| {
            if (param_count > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s}: ", .{p.zig_ident});
            try self.emitType(p.ty);
            param_count += 1;
        }
        try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
        if (ret_type_expr_opt) |rtexpr| {
            try self.out.appendSlice(self.allocator, rtexpr);
        } else {
            try self.emitType(sig.return_type);
        }
        try self.out.appendSlice(self.allocator, " {\n");

        if (d.alloc_companion_ident) |alloc_fn_ident| {
            try self.out.print(self.allocator, "return {s}(", .{alloc_fn_ident});
            var call_idx: usize = 0;
            for (sig.type_params) |tp| {
                if (call_idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, tp.zig_ident);
                call_idx += 1;
            }
            if (call_idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, "try __zigar_js.defaultAllocator()");
            call_idx += 1;
            for (sig.params) |p| {
                try self.out.print(self.allocator, ", {s}", .{p.zig_ident});
            }
            try self.out.appendSlice(self.allocator, ");\n}\n");

            const alloc_param = sig.alloc_param_ident orelse "allocator";
            try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, alloc_fn_ident });
            var ap_count: usize = 0;
            for (sig.type_params) |tp| {
                if (ap_count > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                ap_count += 1;
            }
            if (ap_count > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s}: @import(\"std\").mem.Allocator", .{alloc_param});
            ap_count += 1;
            for (sig.params) |p| {
                try self.out.print(self.allocator, ", {s}: ", .{p.zig_ident});
                try self.emitType(p.ty);
            }
            try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
            if (ret_type_expr_opt) |rtexpr| {
                try self.out.appendSlice(self.allocator, rtexpr);
            } else {
                try self.emitType(sig.return_type);
            }
            try self.out.appendSlice(self.allocator, " {\n");
            try self.emitCallableFunctionBody(d, sig, alloc_param, ret_type_expr_opt, is_default_call);
            try self.out.appendSlice(self.allocator, "}\n");
        } else {
            try self.emitCallableFunctionBody(d, sig, null, ret_type_expr_opt, is_default_call);
            try self.out.appendSlice(self.allocator, "}\n");
        }
    }

    fn emitStructBody(
        self: *ModuleEmitCtx,
        wire_name: []const u8,
        is_global_scope: bool,
        push_owner_seg: bool,
        st: ir.StructDeclIr,
    ) error{OutOfMemory}!void {
        var extra_alloc_companions: usize = 0;
        for (st.nested_decls) |nd| {
            if (nd.alloc_companion_ident != null) extra_alloc_companions += 1;
        }
        const frame_count = 2 + st.static_props.len + st.constructors.len + st.methods.len + st.nested_decls.len + extra_alloc_companions;
        var frame = try self.allocator.alloc([]const u8, frame_count);
        defer self.allocator.free(frame);
        var fi: usize = 0;
        frame[fi] = st.self_ident;
        fi += 1;
        frame[fi] = "zigar_js";
        fi += 1;
        for (st.static_props) |sp| {
            frame[fi] = sp.zig_ident;
            fi += 1;
        }
        for (st.constructors) |ctor| {
            frame[fi] = ctor.zig_ident;
            fi += 1;
        }
        for (st.methods) |m| {
            frame[fi] = m.zig_ident;
            fi += 1;
        }
        for (st.nested_decls) |nd| {
            frame[fi] = nd.zig_ident;
            fi += 1;
            if (nd.alloc_companion_ident) |aci| {
                frame[fi] = aci;
                fi += 1;
            }
        }
        try self.nested_decl_scopes.append(self.allocator, frame);
        defer _ = self.nested_decl_scopes.pop();

        try self.out.appendSlice(self.allocator, "struct {\n");
        try self.out.print(self.allocator, "const {s} = @This();\n", .{st.self_ident});

        for (st.fields) |f| {
            if (f.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
            try self.out.print(self.allocator, "{s}: ", .{f.zig_ident});
            try self.emitType(f.ty);
            if (f.ty.* == .optional) {
                try self.out.appendSlice(self.allocator, " = null");
            }
            try self.out.appendSlice(self.allocator, ",\n");
        }

        for (st.static_props) |sp| {
            if (sp.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
            if (sp.literal) |lit| {
                try self.emitLiteralConst("pub ", sp.zig_ident, sp.ty, lit);
            } else {
                try self.out.print(self.allocator, "pub const {s}: __zigar_js.GlobalTarget(", .{sp.zig_ident});
                try self.emitType(sp.ty);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitCallTargetLiteral(
                    is_global_scope,
                    sp.wire_name,
                    false,
                    if (push_owner_seg) wire_name else null,
                );
                try self.out.appendSlice(self.allocator, ") = .{};\n");
            }
        }

        for (st.constructors) |ctor| {
            if (ctor.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
            try self.emitFunction("pub ", ctor.zig_ident, null, ctor.signature);
        }

        const self_ptr_ty = try std.fmt.allocPrint(self.allocator, "*const {s}", .{st.self_ident});
        defer self.allocator.free(self_ptr_ty);

        for (st.methods) |m| {
            if (m.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
            const self_ty: ?[]const u8 = if (m.is_static) null else self_ptr_ty;
            try self.emitFunction("pub ", m.zig_ident, self_ty, m.signature);
        }

        if (push_owner_seg) {
            try self.ns_wire_path.append(self.allocator, wire_name);
        }
        defer if (push_owner_seg) {
            _ = self.ns_wire_path.pop();
        };

        for (st.nested_decls) |nd| {
            try self.emitDecl(nd);
        }

        try self.out.appendSlice(self.allocator, "pub const zigar_js = .{\n.js_name = ");
        try self.emitStringLit(wire_name);
        if (st.type_params.len > 0) {
            try self.out.appendSlice(self.allocator, ",\n.type_params = .{ ");
            for (st.type_params, 0..) |tp, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, tp.zig_ident);
            }
            try self.out.appendSlice(self.allocator, " }");
        }
        try self.out.print(self.allocator, ",\n.is_class = {s}", .{
            if (st.is_class) "true" else "false",
        });
        if (st.has_private_constructor) {
            try self.out.appendSlice(self.allocator, ",\n.has_private_constructor = true");
        }
        if (st.has_non_public_members) {
            try self.out.appendSlice(self.allocator, ",\n.has_non_public_members = true");
        }
        try self.out.appendSlice(self.allocator, ",\n.fields = .{\n");
        for (st.fields) |f| {
            try self.out.appendSlice(self.allocator, ".{ .name = ");
            try self.emitStringLit(f.logical_name);
            try self.out.appendSlice(self.allocator, ", .js_name = ");
            try self.emitStringLit(f.wire_name);
            try self.out.appendSlice(self.allocator, " },\n");
        }
        try self.out.appendSlice(self.allocator, "},\n.methods = .{\n");
        for (st.methods) |m| {
            try self.out.appendSlice(self.allocator, ".{ .name = ");
            try self.emitStringLit(m.logical_name);
            try self.out.appendSlice(self.allocator, ", .js_name = ");
            try self.emitStringLit(m.wire_name);
            try self.out.print(self.allocator, ", .is_static = {s} }},\n", .{
                if (m.is_static) "true" else "false",
            });
        }
        try self.out.appendSlice(self.allocator, "},\n};\n}");
    }

    fn emitEnumBody(
        self: *ModuleEmitCtx,
        wire_name: []const u8,
        is_global_scope: bool,
        push_owner_seg: bool,
        is_const: bool,
        has_unknown_values: bool,
        members: []const ir.EnumMemberIr,
    ) !void {
        if (has_unknown_values) {
            try self.out.appendSlice(self.allocator, "struct {\n__zigar_value: __zigar_js.Any = .{ .handle = 0 },\n");
            for (members) |m| {
                if (m.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
                switch (m.value) {
                    .unknown => {
                        try self.out.print(self.allocator, "pub const {s}: __zigar_js.GlobalTarget(@This(), ", .{m.zig_ident});
                        try self.emitCallTargetLiteral(
                            is_global_scope,
                            m.wire_name,
                            false,
                            if (push_owner_seg) wire_name else null,
                        );
                        try self.out.appendSlice(self.allocator, ") = .{};\n");
                    },
                    .str => |s| {
                        try self.out.print(self.allocator, "pub const {s}: []const u8 = ", .{m.zig_ident});
                        try self.emitStringLit(s);
                        try self.out.appendSlice(self.allocator, ";\n");
                    },
                    .num => |n| {
                        if (std.math.isFinite(n)) {
                            try self.out.print(self.allocator, "pub const {s}: f64 = {d};\n", .{ m.zig_ident, n });
                        } else {
                            try self.out.print(self.allocator, "pub const {s}: __zigar_js.GlobalTarget(@This(), ", .{m.zig_ident});
                            try self.emitCallTargetLiteral(
                                is_global_scope,
                                m.wire_name,
                                false,
                                if (push_owner_seg) wire_name else null,
                            );
                            try self.out.appendSlice(self.allocator, ") = .{};\n");
                        }
                    },
                }
            }
            try self.out.appendSlice(self.allocator, "pub const zigar_js = .{\n.js_name = ");
            try self.emitStringLit(wire_name);
            try self.out.print(self.allocator, ",\n.is_enum = true,\n.is_const = {s},\n.has_unknown_values = true,\n.members = .{{\n", .{
                if (is_const) "true" else "false",
            });
            for (members) |m| {
                try self.out.appendSlice(self.allocator, ".{ .tag = ");
                try self.emitStringLit(m.logical_name);
                try self.out.appendSlice(self.allocator, ", .js_name = ");
                try self.emitStringLit(m.wire_name);
                switch (m.value) {
                    .unknown => try self.out.appendSlice(self.allocator, ", .is_unknown = true"),
                    .str => |s| {
                        try self.out.appendSlice(self.allocator, ", .str_value = ");
                        try self.emitStringLit(s);
                    },
                    .num => |n| {
                        if (std.math.isFinite(n)) {
                            try self.out.print(self.allocator, ", .num_value = @as(f64, {d})", .{n});
                        } else {
                            try self.out.appendSlice(self.allocator, ", .is_unknown = true");
                        }
                    },
                }
                try self.out.appendSlice(self.allocator, " },\n");
            }
            try self.out.appendSlice(self.allocator, "},\n};\n}");
            return;
        }

        try self.out.appendSlice(self.allocator, "enum {\n");
        for (members) |m| {
            if (m.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
            try self.out.print(self.allocator, "{s},\n", .{m.zig_ident});
        }
        try self.out.appendSlice(self.allocator, "pub const zigar_js = .{\n.js_name = ");
        try self.emitStringLit(wire_name);
        try self.out.print(self.allocator, ",\n.is_const = {s},\n.members = .{{\n", .{
            if (is_const) "true" else "false",
        });
        for (members) |m| {
            try self.out.appendSlice(self.allocator, ".{ .tag = ");
            try self.emitStringLit(m.logical_name);
            try self.out.appendSlice(self.allocator, ", .js_name = ");
            try self.emitStringLit(m.wire_name);
            switch (m.value) {
                .unknown => {},
                .str => |s| {
                    try self.out.appendSlice(self.allocator, ", .str_value = ");
                    try self.emitStringLit(s);
                },
                .num => |n| {
                    if (std.math.isFinite(n)) {
                        try self.out.print(self.allocator, ", .num_value = @as(f64, {d})", .{n});
                    }
                },
            }
            try self.out.appendSlice(self.allocator, " },\n");
        }
        try self.out.appendSlice(self.allocator, "},\n};\n}");
    }

    fn emitDecl(self: *ModuleEmitCtx, d: ir.DeclIr) error{OutOfMemory}!void {
        if (self.emit_depth >= 128) return;
        const track_cycle = (d.kind == .namespace_decl or d.kind == .struct_decl) and d.source_decl_id != null;
        if (track_cycle) {
            const sid = d.source_decl_id.?;
            if (self.active_source_decls.contains(sid)) return;
            try self.active_source_decls.put(self.allocator, sid, {});
        }
        defer if (track_cycle) {
            _ = self.active_source_decls.remove(d.source_decl_id.?);
        };
        self.emit_depth += 1;
        defer self.emit_depth -= 1;

        if (d.kind != .function_decl) {
            if (d.jsdoc) |jd| {
                try appendJsDocComments(&self.out, self.allocator, jd);
            }
        }
        const pub_kw = if (d.is_exported) "pub " else "";

        switch (d.kind) {
            .function_decl => |sig| {
                try self.emitCallableFunction(pub_kw, d, sig);
            },
            .const_literal => |cl| {
                try self.emitLiteralConst(pub_kw, d.zig_ident, cl.ty, cl.value);
            },
            .global_var => |gty| {
                try self.out.print(self.allocator, "{s}const {s}: __zigar_js.GlobalTarget(", .{ pub_kw, d.zig_ident });
                try self.emitType(gty);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitCallTargetLiteral(d.is_global_scope, d.wire_name, false, null);
                try self.out.appendSlice(self.allocator, ") = .{};\n");
            },
            .struct_decl => |st| {
                const push_owner = true;
                if (st.type_params.len == 0) {
                    try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                    try self.emitStructBody(d.wire_name, d.is_global_scope, push_owner, st);
                    try self.out.appendSlice(self.allocator, ";\n");
                } else {
                    try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
                    for (st.type_params, 0..) |tp, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                    }
                    try self.out.appendSlice(self.allocator, ") type {\nreturn ");
                    try self.emitStructBody(d.wire_name, d.is_global_scope, push_owner, st);
                    try self.out.appendSlice(self.allocator, ";\n}\n");
                }
            },
            .enum_decl => |en| {
                const push_owner = true;
                try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                try self.emitEnumBody(d.wire_name, d.is_global_scope, push_owner, en.is_const, en.has_unknown_values, en.members);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .string_enum_decl => |members| {
                try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                try self.emitEnumBody(d.wire_name, d.is_global_scope, false, false, false, members);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .union_decl => |un| {
                if (un.type_params.len == 0) {
                    try self.out.print(self.allocator, "{s}const {s} = union(enum) {{\n", .{ pub_kw, d.zig_ident });
                    for (un.variants) |v| {
                        try self.out.print(self.allocator, "{s}: ", .{v.zig_ident});
                        try self.emitType(v.payload);
                        try self.out.appendSlice(self.allocator, ",\n");
                    }
                    try self.out.appendSlice(self.allocator, "pub const zigar_js = .{ .js_name = ");
                    try self.emitStringLit(d.wire_name);
                    try self.out.appendSlice(self.allocator, " };\n};\n");
                } else {
                    try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
                    for (un.type_params, 0..) |tp, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                    }
                    try self.out.appendSlice(self.allocator, ") type {\nreturn union(enum) {\n");
                    for (un.variants) |v| {
                        try self.out.print(self.allocator, "{s}: ", .{v.zig_ident});
                        try self.emitType(v.payload);
                        try self.out.appendSlice(self.allocator, ",\n");
                    }
                    try self.out.appendSlice(self.allocator, "pub const zigar_js = .{ .js_name = ");
                    try self.emitStringLit(d.wire_name);
                    try self.out.appendSlice(self.allocator, ", .type_params = .{ ");
                    for (un.type_params, 0..) |tp, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.appendSlice(self.allocator, tp.zig_ident);
                    }
                    try self.out.appendSlice(self.allocator, " } };\n};\n}\n");
                }
            },
            .type_alias => |ta| {
                if (ta.type_params.len == 0) {
                    try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                    try self.emitType(ta.target);
                    try self.out.appendSlice(self.allocator, ";\n");
                } else {
                    try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
                    for (ta.type_params, 0..) |tp, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                    }
                    try self.out.appendSlice(self.allocator, ") type {\n");
                    for (ta.type_params) |tp| {
                        if (!typeUsesTypeParam(ta.target, tp.zig_ident)) {
                            try self.out.print(self.allocator, "_ = {s};\n", .{tp.zig_ident});
                        }
                    }
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitType(ta.target);
                    try self.out.appendSlice(self.allocator, ";\n}\n");
                }
            },
            .namespace_decl => |children| {
                var extra_allocs: usize = 0;
                for (children) |cd| {
                    if (cd.alloc_companion_ident != null) extra_allocs += 1;
                }
                const frame = try self.allocator.alloc([]const u8, children.len + extra_allocs + 1);
                defer self.allocator.free(frame);
                var fi: usize = 0;
                for (children) |cd| {
                    frame[fi] = cd.zig_ident;
                    fi += 1;
                    if (cd.alloc_companion_ident) |aci| {
                        frame[fi] = aci;
                        fi += 1;
                    }
                }
                frame[fi] = "zigar_js";
                try self.nested_decl_scopes.append(self.allocator, frame);
                defer _ = self.nested_decl_scopes.pop();

                try self.ns_wire_path.append(self.allocator, d.wire_name);
                defer _ = self.ns_wire_path.pop();

                try self.out.print(self.allocator, "{s}const {s} = struct {{\n", .{ pub_kw, d.zig_ident });
                for (children) |cd| {
                    try self.emitDecl(cd);
                }
                try self.out.appendSlice(self.allocator, "pub const zigar_js = .{ .js_name = ");
                try self.emitStringLit(d.wire_name);
                try self.out.appendSlice(self.allocator, " };\n};\n");
            },
            .re_export_decl => |re| {
                if (re.target_zig_path.len > 0) {
                    if (re.target_module_index != self.mod.index) {
                        if (self.lookupImportAlias(re.target_module_index)) |alias| {
                            try self.out.print(self.allocator, "{s}const {s} = {s}", .{
                                pub_kw,
                                d.zig_ident,
                                alias,
                            });
                            for (re.target_zig_path) |seg| {
                                try self.out.append(self.allocator, '.');
                                try self.emitIdentSegment(seg);
                            }
                            try self.out.appendSlice(self.allocator, ";\n");
                        }
                    } else {
                        try self.out.print(self.allocator, "{s}const {s} = ", .{
                            pub_kw,
                            d.zig_ident,
                        });
                        if (self.isShadowedInNestedScope(re.target_zig_path[0])) {
                            self.used_self_mod_alias = true;
                            try self.out.appendSlice(self.allocator, "__zigar_mod.");
                        }
                        for (re.target_zig_path, 0..) |seg, idx| {
                            if (idx > 0) try self.out.append(self.allocator, '.');
                            try self.emitIdentSegment(seg);
                        }
                        try self.out.appendSlice(self.allocator, ";\n");
                    }
                }
            },
            .namespace_re_export => |nre| {
                if (self.lookupImportAlias(nre.target_module_index)) |alias| {
                    try self.out.print(self.allocator, "{s}const {s} = {s};\n", .{
                        pub_kw,
                        d.zig_ident,
                        alias,
                    });
                }
            },
        }
    }
};

fn typeHasInlineNominal(ty: *const ir.TypeIr) bool {
    return switch (ty.*) {
        .tuple, .anon_struct, .tagged_union => true,
        .optional => |opt| typeHasInlineNominal(opt.child),
        .pointer_const, .slice, .promise => |inner| typeHasInlineNominal(inner),
        .js_map => |m| typeHasInlineNominal(m.key) or typeHasInlineNominal(m.value),
        .fn_ptr => |fp| blk: {
            for (fp.params) |pt| {
                if (typeHasInlineNominal(pt)) break :blk true;
            }
            break :blk typeHasInlineNominal(fp.return_type);
        },
        .decl_ref => |dref| blk: {
            for (dref.type_args) |ta| {
                if (typeHasInlineNominal(ta)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn signatureUsesTypeParam(sig: ir.SignatureIr, tp_ident: []const u8) bool {
    for (sig.params) |p| {
        if (typeUsesTypeParam(p.ty, tp_ident)) return true;
    }
    return typeUsesTypeParam(sig.return_type, tp_ident);
}

fn typeUsesTypeParam(ty: *const ir.TypeIr, tp_ident: []const u8) bool {
    return switch (ty.*) {
        .type_param_ref => |ref_id| std.mem.eql(u8, ref_id, tp_ident),
        .optional => |opt| typeUsesTypeParam(opt.child, tp_ident),
        .pointer_const, .slice, .promise => |inner| typeUsesTypeParam(inner, tp_ident),
        .js_map => |m| typeUsesTypeParam(m.key, tp_ident) or typeUsesTypeParam(m.value, tp_ident),
        .tuple => |elems| blk: {
            for (elems) |el| {
                if (typeUsesTypeParam(el.ty, tp_ident)) break :blk true;
            }
            break :blk false;
        },
        .fn_ptr => |fp| blk: {
            for (fp.params) |pt| {
                if (typeUsesTypeParam(pt, tp_ident)) break :blk true;
            }
            break :blk typeUsesTypeParam(fp.return_type, tp_ident);
        },
        .anon_struct => |fields| blk: {
            for (fields) |f| {
                if (typeUsesTypeParam(f.ty, tp_ident)) break :blk true;
            }
            break :blk false;
        },
        .tagged_union => |vars| blk: {
            for (vars) |v| {
                if (typeUsesTypeParam(v.payload, tp_ident)) break :blk true;
            }
            break :blk false;
        },
        .decl_ref => |dref| blk: {
            for (dref.type_args) |ta| {
                if (typeUsesTypeParam(ta, tp_ident)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn renderModuleRaw(
    allocator: std.mem.Allocator,
    pkg: *const ir.PackageIr,
    mod: *const ir.ModuleIr,
) ![]u8 {
    var ctx = ModuleEmitCtx{
        .allocator = allocator,
        .pkg = pkg,
        .mod = mod,
    };
    defer ctx.deinit();

    try ctx.out.appendSlice(allocator, "\npub const zigar_js = .{\n.specifier = ");
    try ctx.emitStringLit(mod.specifier);
    try ctx.out.appendSlice(allocator, ",\n.wire_specifier = ");
    try ctx.emitStringLit(mod.wire_specifier);
    if (mod.export_equals_ident) |eq_ident| {
        try ctx.out.appendSlice(allocator, ",\n.export_equals = ");
        try ctx.emitStringLit(eq_ident);
    }
    try ctx.out.appendSlice(allocator, ",\n.exports = .{\n");
    for (mod.decls) |d| {
        if (!d.is_exported or !d.is_js_exported) continue;
        try ctx.out.appendSlice(allocator, ".{ .name = ");
        try ctx.emitStringLit(d.logical_name);
        try ctx.out.appendSlice(allocator, ", .js_name = ");
        try ctx.emitStringLit(d.wire_name);
        if (d.is_default_export) {
            try ctx.out.appendSlice(allocator, ", .is_default = true");
        }
        try ctx.out.appendSlice(allocator, " },\n");
    }
    try ctx.out.appendSlice(allocator, "},\n};\n\n");

    for (mod.decls) |d| {
        try ctx.emitDecl(d);
        try ctx.out.append(allocator, '\n');
    }

    var header: std.ArrayList(u8) = .empty;
    errdefer header.deinit(allocator);

    try header.appendSlice(allocator, "// Generated by ts-zigar (TypeScript 7.1). Do not edit manually.\n\n");

    if (mod.needs_root_runtime) {
        const rel_to_root = try naming.relativeImportPath(allocator, mod.rel_zig_path, "root.zig");
        defer allocator.free(rel_to_root);
        const rel_lit = try naming.formatStringLiteral(allocator, rel_to_root);
        defer allocator.free(rel_lit);
        try header.print(allocator, "const __zigar_js = @import({s}).zigar_js;\n", .{rel_lit});
    }

    for (mod.imports) |imp| {
        const imp_lit = try naming.formatStringLiteral(allocator, imp.rel_import_path);
        defer allocator.free(imp_lit);
        try header.print(allocator, "const {s} = @import({s});\n", .{ imp.local_alias, imp_lit });
    }

    if (ctx.used_self_mod_alias) {
        try header.appendSlice(allocator, "const __zigar_mod = @This();\n");
    }

    try header.appendSlice(allocator, ctx.out.items);
    return try header.toOwnedSlice(allocator);
}

fn renderRootRaw(
    allocator: std.mem.Allocator,
    pkg: *const ir.PackageIr,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var root_scope = naming.ScopeNamer.initContainer(allocator, null);
    defer root_scope.deinit();
    try root_scope.reserve("zigar_js");

    var primary_count: usize = 0;
    var single_primary: ?*const ir.ModuleIr = null;
    var index_primary: ?*const ir.ModuleIr = null;

    for (pkg.modules) |*m| {
        if (!m.is_primary) continue;
        primary_count += 1;
        single_primary = m;
        if (std.mem.eql(u8, m.specifier, "index")) {
            index_primary = m;
        }
        try root_scope.reserve(m.root_export_logical_name);
    }

    // Re-export top-level symbols directly on `root.zig` (without `usingnamespace`, which does not
    // exist in Zig 0.17) when there is a single primary module or an `index` entry module!
    const barrel_mod = if (primary_count == 1) single_primary else index_primary;
    var barrel_exports: std.ArrayList([]const u8) = .empty;
    defer barrel_exports.deinit(allocator);
    if (barrel_mod) |bm| {
        for (bm.decls) |d| {
            if (!d.is_exported or !d.is_js_exported) continue;
            if (!root_scope.isTaken(d.logical_name)) {
                try root_scope.reserve(d.logical_name);
                try barrel_exports.append(allocator, d.zig_ident);
            }
            if (d.alloc_companion_ident) |aci| {
                if (!root_scope.isTaken(aci)) {
                    try root_scope.reserve(aci);
                    try barrel_exports.append(allocator, aci);
                }
            }
        }
    }

    try out.appendSlice(
        allocator,
        \\// Generated by ts-zigar (TypeScript 7.1). Do not edit manually.
        \\
        \\pub const zigar_js = @import("__zigar_runtime.zig");
        \\
        \\
    );

    for (pkg.modules) |*m| {
        if (!m.is_primary) continue;
        const path_lit = try naming.formatStringLiteral(allocator, m.rel_zig_path);
        defer allocator.free(path_lit);
        try out.print(allocator, "pub const {s} = @import({s});\n", .{ m.root_export_ident, path_lit });
    }

    if (barrel_mod) |bm| {
        if (barrel_exports.items.len > 0) {
            try out.append(allocator, '\n');
            for (barrel_exports.items) |export_ident| {
                try out.print(allocator, "pub const {s} = {s}.{s};\n", .{
                    export_ident,
                    bm.root_export_ident,
                    export_ident,
                });
            }
        }
    }

    try out.appendSlice(allocator, "\ntest \"ts-zigar generated module graph\" {\n");
    try out.appendSlice(allocator, "    @import(\"std\").testing.refAllDecls(@This());\n");
    for (pkg.modules) |*m| {
        if (!m.is_primary) continue;
        try out.print(allocator, "    @import(\"std\").testing.refAllDecls({s});\n", .{m.root_export_ident});
    }
    try out.appendSlice(allocator, "}\n");

    return try out.toOwnedSlice(allocator);
}

fn renderRuntimeRaw(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(
        u8,
        \\// Generated by ts-zigar (TypeScript 7.1). Do not edit manually.
        \\
        \\const std = @import("std");
        \\const root = @import("root");
        \\
        \\pub const has_host: bool = @hasDecl(root, "host") and @TypeOf(root.host) == type and @hasDecl(root.host, "js");
        \\const raw_js = if (has_host) root.host.js else struct {};
        \\
        \\pub const OfflineError = error{
        \\    OffJsThread,
        \\    HostUnavailable,
        \\    JsException,
        \\    Unexpected,
        \\};
        \\
        \\pub const OfflineCallError = OfflineError || std.mem.Allocator.Error || error{
        \\    TypeError,
        \\    RangeError,
        \\    SyntaxError,
        \\    ReferenceError,
        \\    NotCallable,
        \\    NotConstructable,
        \\    IntegerOverflow,
        \\};
        \\
        \\pub const OfflineOverflowError = OfflineError || error{
        \\    TypeError,
        \\    IntegerOverflow,
        \\};
        \\
        \\pub const OfflineAllocError = OfflineError || std.mem.Allocator.Error || error{
        \\    TypeError,
        \\    RangeError,
        \\    IntegerOverflow,
        \\};
        \\
        \\pub const Error = if (has_host) raw_js.Error else OfflineError;
        \\pub const CallError = if (has_host) raw_js.CallError else OfflineCallError;
        \\pub const OverflowError = if (has_host) raw_js.OverflowError else OfflineOverflowError;
        \\pub const AllocError = if (has_host) raw_js.AllocError else OfflineAllocError;
        \\
        \\pub const OfflineJsType = enum(u32) {
        \\    undefined = 0,
        \\    object = 1,
        \\    boolean = 2,
        \\    number = 3,
        \\    bigint = 4,
        \\    string = 5,
        \\    symbol = 6,
        \\    function = 7,
        \\    invalid = 0xffffffff,
        \\};
        \\
        \\pub const JsType = if (has_host) raw_js.JsType else OfflineJsType;
        \\
        \\pub const OfflineNullishKind = enum {
        \\    none,
        \\    undefined_only,
        \\    null_only,
        \\    null_or_undefined,
        \\};
        \\
        \\pub const NullishKind = if (has_host) raw_js.NullishKind else OfflineNullishKind;
        \\
        \\pub fn StubNullable(comptime T: type) type {
        \\    return union(enum) {
        \\        pub const is_zigar_nullable = true;
        \\        pub const Payload = T;
        \\
        \\        undefined: void,
        \\        null: void,
        \\        value: T,
        \\
        \\        pub fn isUndefined(self: @This()) bool {
        \\            return self == .undefined;
        \\        }
        \\
        \\        pub fn isNull(self: @This()) bool {
        \\            return self == .null;
        \\        }
        \\
        \\        pub fn isNullOrUndefined(self: @This()) bool {
        \\            return self != .value;
        \\        }
        \\
        \\        pub fn hasValue(self: @This()) bool {
        \\            return self == .value;
        \\        }
        \\
        \\        pub fn toOptional(self: @This()) ?T {
        \\            return switch (self) {
        \\                .value => |v| v,
        \\                .undefined, .null => null,
        \\            };
        \\        }
        \\
        \\        pub fn orElse(self: @This(), default_val: T) T {
        \\            return switch (self) {
        \\                .value => |v| v,
        \\                .undefined, .null => default_val,
        \\            };
        \\        }
        \\    };
        \\}
        \\
        \\pub const Nullable = if (has_host) raw_js.Nullable else StubNullable;
        \\
        \\pub fn StubRef(comptime T: type) type {
        \\    return extern struct {
        \\        const Self = @This();
        \\        pub const Target = T;
        \\        pub const is_js_value = true;
        \\
        \\        handle: u32 = 0,
        \\
        \\        pub const @"undefined": Self = .{ .handle = 0 };
        \\        pub const @"null": Self = .{ .handle = 1 };
        \\        pub const @"false": Self = .{ .handle = 2 };
        \\        pub const @"true": Self = .{ .handle = 3 };
        \\        pub const globalThis: Self = .{ .handle = 4 };
        \\
        \\        pub fn fromBool(v: bool) Self {
        \\            return if (v) Self.@"true" else Self.@"false";
        \\        }
        \\
        \\        pub fn isUndefined(self: Self) bool {
        \\            return self.handle == 0;
        \\        }
        \\
        \\        pub fn isNull(self: Self) bool {
        \\            return self.handle == 1;
        \\        }
        \\
        \\        pub fn isNullOrUndefined(self: Self) bool {
        \\            return self.handle <= 1;
        \\        }
        \\
        \\        pub fn clone(self: Self) Self {
        \\            return self;
        \\        }
        \\
        \\        pub fn tryClone(self: Self) Error!Self {
        \\            return self;
        \\        }
        \\
        \\        pub fn deinit(_: Self) void {}
        \\
        \\        pub fn tryDeinit(_: Self) Error!void {}
        \\
        \\        pub fn eql(self: Self, other: anytype) bool {
        \\            return self.handle == other.handle;
        \\        }
        \\
        \\        pub fn tryEql(_: Self, _: anytype) Error!bool {
        \\            return error.HostUnavailable;
        \\        }
        \\
        \\        pub fn tryTypeof(_: Self) Error!JsType {
        \\            return error.HostUnavailable;
        \\        }
        \\
        \\        pub fn cast(self: Self, comptime U: type) StubRef(U) {
        \\            return .{ .handle = self.handle };
        \\        }
        \\    };
        \\}
        \\
        \\pub const RawAny = if (has_host) raw_js.Any else opaque {};
        \\pub const RawUnknown = if (has_host) raw_js.Unknown else opaque {};
        \\pub const RawObject = if (has_host) raw_js.Object else opaque {};
        \\pub const RawSymbol = if (has_host) raw_js.Symbol else opaque {};
        \\pub const RawFunction = if (has_host) raw_js.Function else opaque {};
        \\
        \\pub const Ref = if (has_host) raw_js.Ref else StubRef;
        \\
        \\pub const Any = Ref(RawAny);
        \\pub const Unknown = Ref(RawUnknown);
        \\pub const Object = Ref(RawObject);
        \\pub const Symbol = Ref(RawSymbol);
        \\pub const Function = Ref(RawFunction);
        \\
        \\pub const JsValue = Any;
        \\pub const JsObject = Object;
        \\pub const JsSymbol = Symbol;
        \\
        \\pub const StubHandle = extern struct {
        \\    const Self = @This();
        \\    pub const is_js_value = true;
        \\
        \\    handle: u32 = 0,
        \\
        \\    pub const @"undefined": Self = .{ .handle = 0 };
        \\    pub const @"null": Self = .{ .handle = 1 };
        \\
        \\    pub fn isUndefined(self: Self) bool {
        \\        return self.handle == 0;
        \\    }
        \\
        \\    pub fn isNull(self: Self) bool {
        \\        return self.handle == 1;
        \\    }
        \\
        \\    pub fn isNullOrUndefined(self: Self) bool {
        \\        return self.handle <= 1;
        \\    }
        \\
        \\    pub fn clone(self: Self) Self {
        \\        return self;
        \\    }
        \\
        \\    pub fn tryClone(self: Self) Error!Self {
        \\        return self;
        \\    }
        \\
        \\    pub fn deinit(_: Self) void {}
        \\
        \\    pub fn tryDeinit(_: Self) Error!void {}
        \\
        \\    pub fn eql(self: Self, other: anytype) bool {
        \\        return self.handle == other.handle;
        \\    }
        \\
        \\    pub fn tryEql(_: Self, _: anytype) Error!bool {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn ref(self: Self) Any {
        \\        return .{ .handle = self.handle };
        \\    }
        \\
        \\    pub fn toRef(self: Self) Any {
        \\        return .{ .handle = self.handle };
        \\    }
        \\
        \\    pub fn fromRef(v: anytype) Self {
        \\        return .{ .handle = v.handle };
        \\    }
        \\};
        \\
        \\pub const StubString = extern struct {
        \\    const Self = @This();
        \\    pub const is_js_value = true;
        \\    pub const is_js_string = true;
        \\
        \\    handle: u32 = 0,
        \\
        \\    pub fn fromSlice(_: []const u8) CallError!Self {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn byteLen(_: Self) CallError!usize {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn utf16Len(_: Self) CallError!usize {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn isEmpty(_: Self) CallError!bool {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn toSliceAlloc(_: Self, _: std.mem.Allocator) AllocError![]u8 {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn clone(self: Self) Self {
        \\        return self;
        \\    }
        \\
        \\    pub fn deinit(_: Self) void {}
        \\
        \\    pub fn eql(self: Self, other: anytype) bool {
        \\        return self.handle == other.handle;
        \\    }
        \\};
        \\
        \\pub const StubBigInt = extern struct {
        \\    const Self = @This();
        \\    pub const is_js_value = true;
        \\
        \\    handle: u32 = 0,
        \\
        \\    pub fn fromI64(_: i64) Error!Self {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn fromU64(_: u64) Error!Self {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn fromI128(_: i128) Error!Self {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn fromU128(_: u128) Error!Self {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn fromString(_: []const u8) Error!Self {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn toI64(_: Self) OverflowError!i64 {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn toU64(_: Self) OverflowError!u64 {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn toI128(_: Self) OverflowError!i128 {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn toU128(_: Self) OverflowError!u128 {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn toStringAlloc(_: Self, _: std.mem.Allocator, _: u8) AllocError![]u8 {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn clone(self: Self) Self {
        \\        return self;
        \\    }
        \\
        \\    pub fn deinit(_: Self) void {}
        \\
        \\    pub fn eql(self: Self, other: anytype) bool {
        \\        return self.handle == other.handle;
        \\    }
        \\};
        \\
        \\pub const String = if (has_host) raw_js.String else StubString;
        \\pub const BigInt = if (has_host) raw_js.BigInt else StubBigInt;
        \\pub const Date = if (has_host) raw_js.Date else StubHandle;
        \\pub const RegExp = if (has_host) raw_js.RegExp else StubHandle;
        \\
        \\pub const Buffer = if (has_host) raw_js.Buffer else StubHandle;
        \\pub const Uint8Array = if (has_host) raw_js.Uint8Array else StubHandle;
        \\pub const Uint8ClampedArray = if (has_host) raw_js.Uint8ClampedArray else StubHandle;
        \\pub const Int8Array = if (has_host) raw_js.Int8Array else StubHandle;
        \\pub const Uint16Array = if (has_host) raw_js.Uint16Array else StubHandle;
        \\pub const Int16Array = if (has_host) raw_js.Int16Array else StubHandle;
        \\pub const Uint32Array = if (has_host) raw_js.Uint32Array else StubHandle;
        \\pub const Int32Array = if (has_host) raw_js.Int32Array else StubHandle;
        \\pub const BigUint64Array = if (has_host) raw_js.BigUint64Array else StubHandle;
        \\pub const BigInt64Array = if (has_host) raw_js.BigInt64Array else StubHandle;
        \\pub const Float32Array = if (has_host) raw_js.Float32Array else StubHandle;
        \\pub const Float64Array = if (has_host) raw_js.Float64Array else StubHandle;
        \\pub const ArrayBuffer = if (has_host) raw_js.ArrayBuffer else StubHandle;
        \\pub const SharedArrayBuffer = if (has_host) raw_js.SharedArrayBuffer else StubHandle;
        \\pub const DataView = if (has_host) raw_js.DataView else StubHandle;
        \\
        \\pub fn StubPromise(comptime T: type) type {
        \\    return extern struct {
        \\        const Self = @This();
        \\        pub const Payload = T;
        \\        pub const is_js_value = true;
        \\
        \\        handle: u32 = 0,
        \\
        \\        pub fn clone(self: Self) Self {
        \\            return self;
        \\        }
        \\
        \\        pub fn deinit(_: Self) void {}
        \\    };
        \\}
        \\
        \\pub fn StubArray(comptime T: type) type {
        \\    return extern struct {
        \\        const Self = @This();
        \\        pub const Elem = T;
        \\        pub const is_js_value = true;
        \\
        \\        handle: u32 = 0,
        \\
        \\        pub fn init() CallError!Self {
        \\            return error.HostUnavailable;
        \\        }
        \\
        \\        pub fn initCapacity(_: usize) CallError!Self {
        \\            return error.HostUnavailable;
        \\        }
        \\
        \\        pub fn len(_: Self) CallError!usize {
        \\            return error.HostUnavailable;
        \\        }
        \\
        \\        pub fn get(_: Self, _: usize) CallError!T {
        \\            return error.HostUnavailable;
        \\        }
        \\
        \\        pub fn getAlloc(_: Self, _: std.mem.Allocator, _: usize) AllocError!T {
        \\            return error.HostUnavailable;
        \\        }
        \\
        \\        pub fn set(_: Self, _: usize, _: anytype) CallError!void {
        \\            return error.HostUnavailable;
        \\        }
        \\
        \\        pub fn push(_: Self, _: anytype) CallError!usize {
        \\            return error.HostUnavailable;
        \\        }
        \\
        \\        pub fn clone(self: Self) Self {
        \\            return self;
        \\        }
        \\
        \\        pub fn deinit(_: Self) void {}
        \\    };
        \\}
        \\
        \\pub fn StubMap(comptime K: type, comptime V: type) type {
        \\    return extern struct {
        \\        const Self = @This();
        \\        pub const Key = K;
        \\        pub const Value = V;
        \\        pub const is_js_value = true;
        \\
        \\        handle: u32 = 0,
        \\
        \\        pub fn clone(self: Self) Self {
        \\            return self;
        \\        }
        \\
        \\        pub fn deinit(_: Self) void {}
        \\    };
        \\}
        \\
        \\pub fn StubSet(comptime T: type) type {
        \\    return extern struct {
        \\        const Self = @This();
        \\        pub const Elem = T;
        \\        pub const is_js_value = true;
        \\
        \\        handle: u32 = 0,
        \\
        \\        pub fn clone(self: Self) Self {
        \\            return self;
        \\        }
        \\
        \\        pub fn deinit(_: Self) void {}
        \\    };
        \\}
        \\
        \\pub fn StubRecord(comptime K: type, comptime V: type) type {
        \\    return extern struct {
        \\        const Self = @This();
        \\        pub const Key = K;
        \\        pub const Value = V;
        \\        pub const is_js_value = true;
        \\
        \\        handle: u32 = 0,
        \\
        \\        pub fn clone(self: Self) Self {
        \\            return self;
        \\        }
        \\
        \\        pub fn deinit(_: Self) void {}
        \\    };
        \\}
        \\
        \\pub fn StubIterator(comptime T: type) type {
        \\    return extern struct {
        \\        const Self = @This();
        \\        pub const Elem = T;
        \\        pub const is_js_value = true;
        \\
        \\        handle: u32 = 0,
        \\
        \\        pub fn clone(self: Self) Self {
        \\            return self;
        \\        }
        \\
        \\        pub fn deinit(_: Self) void {}
        \\    };
        \\}
        \\
        \\pub fn StubAsyncIterator(comptime T: type) type {
        \\    return extern struct {
        \\        const Self = @This();
        \\        pub const Elem = T;
        \\        pub const is_js_value = true;
        \\
        \\        handle: u32 = 0,
        \\
        \\        pub fn clone(self: Self) Self {
        \\            return self;
        \\        }
        \\
        \\        pub fn deinit(_: Self) void {}
        \\    };
        \\}
        \\
        \\pub const StubJsException = struct {
        \\    raw: Any = Any.@"undefined",
        \\
        \\    pub fn value(self: @This()) Any {
        \\        return self.raw;
        \\    }
        \\
        \\    pub fn deinit(_: anytype) void {}
        \\
        \\    pub fn message(_: @This(), _: std.mem.Allocator) Error!?[]const u8 {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn name(_: @This(), _: std.mem.Allocator) Error!?[]const u8 {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn code(_: @This(), _: std.mem.Allocator) Error!?[]const u8 {
        \\        return error.HostUnavailable;
        \\    }
        \\
        \\    pub fn stack(_: @This(), _: std.mem.Allocator) Error!?[]const u8 {
        \\        return error.HostUnavailable;
        \\    }
        \\};
        \\
        \\pub const Promise = if (has_host) raw_js.Promise else StubPromise;
        \\pub const Array = if (has_host) raw_js.Array else StubArray;
        \\pub const Map = if (has_host) raw_js.Map else StubMap;
        \\pub const JsMap = Map;
        \\pub const Set = if (has_host) raw_js.Set else StubSet;
        \\pub const Record = if (has_host) raw_js.Record else StubRecord;
        \\pub const Iterator = if (has_host) raw_js.Iterator else StubIterator;
        \\pub const AsyncIterator = if (has_host) raw_js.AsyncIterator else StubAsyncIterator;
        \\pub const JsException = if (has_host) raw_js.JsException else StubJsException;
        \\
        \\pub fn activeHandleCount() u32 {
        \\    if (has_host) return raw_js.activeHandleCount();
        \\    return 0;
        \\}
        \\
        \\pub fn lastError() ?JsException {
        \\    if (has_host) return raw_js.lastError();
        \\    return null;
        \\}
        \\
        \\pub fn takeLastError() ?JsException {
        \\    if (has_host) return raw_js.takeLastError();
        \\    return null;
        \\}
        \\
        \\pub fn hasLastError() bool {
        \\    if (has_host) return raw_js.hasLastError();
        \\    return false;
        \\}
        \\
        \\pub fn clearLastError() void {
        \\    if (has_host) raw_js.clearLastError();
        \\}
        \\
        \\pub fn symbolFor(key: []const u8) CallError!Symbol {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const sym_ctor = try raw_js.getGlobal(CallError!Any, "Symbol");
        \\    defer sym_ctor.deinit();
        \\    return try raw_js.callMethod(fn ([]const u8) CallError!Symbol, sym_ctor, "for", .{key});
        \\}
        \\
        \\pub fn createSymbol(description: ?[]const u8) CallError!Symbol {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const sym_ctor = try raw_js.getGlobal(CallError!Function, "Symbol");
        \\    defer sym_ctor.deinit();
        \\    if (description) |desc| {
        \\        return try raw_js.callFn(fn ([]const u8) CallError!Symbol, sym_ctor, .{desc});
        \\    }
        \\    return try raw_js.callFn(fn () CallError!Symbol, sym_ctor, .{});
        \\}
        \\
        \\pub fn symbolKeyFor(allocator: std.mem.Allocator, sym: Symbol) CallError!?[]const u8 {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const sym_ctor = try raw_js.getGlobal(CallError!Any, "Symbol");
        \\    defer sym_ctor.deinit();
        \\    return try raw_js.callMethod(fn (std.mem.Allocator, Symbol) CallError!?[]const u8, sym_ctor, "keyFor", .{ allocator, sym });
        \\}
        \\
        \\pub fn defaultAllocator() CallError!std.mem.Allocator {
        \\    if (has_host and @hasDecl(root.host, "default_allocator")) {
        \\        return root.host.default_allocator;
        \\    }
        \\    return error.HostUnavailable;
        \\}
        \\
        \\pub const CallTarget = struct {
        \\    module: ?[]const u8 = null,
        \\    ns_path: []const []const u8 = &.{},
        \\    name: []const u8 = "",
        \\    is_default: bool = false,
        \\    from_default: bool = false,
        \\};
        \\
        \\pub const Args = Array(Any);
        \\
        \\pub fn initArgs() CallError!Args {
        \\    if (!has_host) return error.HostUnavailable;
        \\    return try Args.init();
        \\}
        \\
        \\pub fn toJsRefWithNullish(comptime T: type, value: T, comptime nk: NullishKind) CallError!Any {
        \\    if (!has_host) return error.HostUnavailable;
        \\    return try raw_js.toJsRefWithNullish(T, value, nk);
        \\}
        \\
        \\pub fn toJsRef(comptime T: type, value: T) CallError!Any {
        \\    return toJsRefWithNullish(T, value, .null_or_undefined);
        \\}
        \\
        \\pub fn fromJsRefAlloc(comptime T: type, allocator: std.mem.Allocator, value: anytype) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    return try raw_js.fromJsRefAlloc(T, allocator, value);
        \\}
        \\
        \\pub fn fromJsRef(comptime T: type, value: anytype) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    return try raw_js.fromJsRef(T, value);
        \\}
        \\
        \\pub fn needsDecodeAllocator(comptime T: type) bool {
        \\    if (has_host) return raw_js.needsDecodeAllocator(T);
        \\    return switch (@typeInfo(T)) {
        \\        .optional => |opt| needsDecodeAllocator(opt.child),
        \\        .pointer => |pt| switch (pt.size) {
        \\            .slice => true,
        \\            .one => @typeInfo(pt.child) != .@"fn",
        \\            else => false,
        \\        },
        \\        .@"struct" => |st| blk: {
        \\            if (@hasDecl(T, "is_js_value") and T.is_js_value) break :blk false;
        \\            for (st.field_types) |ft| {
        \\                if (needsDecodeAllocator(ft)) break :blk true;
        \\            }
        \\            break :blk false;
        \\        },
        \\        .@"union" => |un| blk: {
        \\            for (un.field_types) |ft| {
        \\                if (needsDecodeAllocator(ft)) break :blk true;
        \\            }
        \\            break :blk false;
        \\        },
        \\        else => false,
        \\    };
        \\}
        \\
        \\pub fn freeDecoded(comptime T: type, allocator: std.mem.Allocator, value: T) void {
        \\    if (has_host) {
        \\        raw_js.freeDecoded(T, allocator, value);
        \\        return;
        \\    }
        \\    switch (@typeInfo(T)) {
        \\        .optional => |opt| {
        \\            if (value) |v| freeDecoded(opt.child, allocator, v);
        \\        },
        \\        .pointer => |pt| switch (pt.size) {
        \\            .slice => {
        \\                if (pt.child != u8) {
        \\                    for (value) |elem| freeDecoded(pt.child, allocator, elem);
        \\                }
        \\                allocator.free(value);
        \\            },
        \\            .one => {
        \\                if (@typeInfo(pt.child) != .@"fn") {
        \\                    freeDecoded(pt.child, allocator, value.*);
        \\                    allocator.destroy(value);
        \\                }
        \\            },
        \\            else => {},
        \\        },
        \\        .@"struct" => |st| {
        \\            if (@hasDecl(T, "is_js_value") and T.is_js_value) {
        \\                value.deinit();
        \\                return;
        \\            }
        \\            inline for (st.field_names, 0..) |fname, fi| {
        \\                freeDecoded(st.field_types[fi], allocator, @field(value, fname));
        \\            }
        \\        },
        \\        .@"union" => |un| {
        \\            if (un.tag_type != null) {
        \\                switch (value) {
        \\                    inline else => |payload| freeDecoded(@TypeOf(payload), allocator, payload),
        \\                }
        \\            }
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\
        \\pub fn pushArg(args: Args, value: anytype, comptime nk: NullishKind) CallError!void {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const encoded = try toJsRefWithNullish(@TypeOf(value), value, nk);
        \\    defer encoded.deinit();
        \\    _ = try args.push(encoded);
        \\}
        \\
        \\pub fn pushRestArgs(args: Args, slice_val: anytype) CallError!void {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const SliceT = @TypeOf(slice_val);
        \\    const ElemT = @typeInfo(SliceT).pointer.child;
        \\    for (slice_val) |item| {
        \\        const encoded = try toJsRefWithNullish(ElemT, item, .null_or_undefined);
        \\        defer encoded.deinit();
        \\        _ = try args.push(encoded);
        \\    }
        \\}
        \\
        \\fn invokeRawTarget(comptime target: CallTarget, args: Args) CallError!Any {
        \\    if (!has_host) return error.HostUnavailable;
        \\    var callee: Any = Any.@"undefined";
        \\    var recv: Any = Any.@"undefined";
        \\
        \\    if (comptime (target.is_default and target.module != null and target.ns_path.len == 0)) {
        \\        callee = try raw_js.importModuleDefaultAs(CallError!Any, target.module.?);
        \\    } else {
        \\        var cur: Any = if (comptime (target.from_default and target.module != null))
        \\            try raw_js.importModuleDefaultAs(CallError!Any, target.module.?)
        \\        else if (comptime (target.module != null))
        \\            .{ .handle = (try raw_js.importModule(target.module.?)).handle }
        \\        else
        \\            Any.globalThis;
        \\        errdefer cur.deinit();
        \\
        \\        inline for (target.ns_path) |seg| {
        \\            const next = try raw_js.getProp(CallError!Any, cur, seg);
        \\            cur.deinit();
        \\            cur = next;
        \\        }
        \\        callee = try raw_js.getProp(CallError!Any, cur, target.name);
        \\        if (comptime (!target.from_default and target.ns_path.len == 0)) {
        \\            cur.deinit();
        \\            recv = Any.@"undefined";
        \\        } else {
        \\            recv = cur;
        \\        }
        \\    }
        \\    defer callee.deinit();
        \\    defer recv.deinit();
        \\
        \\    if ((try callee.tryTypeof()) != .function) {
        \\        return error.NotCallable;
        \\    }
        \\
        \\    const reflect = try raw_js.getGlobal(CallError!Object, "Reflect");
        \\    defer reflect.deinit();
        \\    return try raw_js.callMethod(
        \\        fn (Any, Any, Args) CallError!Any,
        \\        reflect,
        \\        "apply",
        \\        .{ callee, recv, args },
        \\    );
        \\}
        \\
        \\pub fn invokeTarget(comptime T: type, comptime target: CallTarget, args: Args) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try invokeRawTarget(target, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) {
        \\        return error.Unexpected;
        \\    }
        \\    return try fromJsRef(T, raw);
        \\}
        \\
        \\pub fn invokeTargetAlloc(
        \\    comptime T: type,
        \\    allocator: std.mem.Allocator,
        \\    comptime target: CallTarget,
        \\    args: Args,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try invokeRawTarget(target, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) {
        \\        return error.Unexpected;
        \\    }
        \\    return try fromJsRefAlloc(T, allocator, raw);
        \\}
        \\
        \\pub fn invokeTargetNoreturn(comptime target: CallTarget, args: Args) noreturn {
        \\    if (has_host) {
        \\        const raw = invokeRawTarget(target, args) catch {
        \\            args.deinit();
        \\            @panic("ts-zigar noreturn function threw");
        \\        };
        \\        raw.deinit();
        \\        args.deinit();
        \\        @panic("ts-zigar noreturn function returned");
        \\    }
        \\    args.deinit();
        \\    @panic("ts-zigar host unavailable");
        \\}
        \\
        \\fn getGlobalTargetRaw(comptime target: CallTarget) CallError!Any {
        \\    if (!has_host) return error.HostUnavailable;
        \\    if (comptime (target.is_default and target.module != null and target.ns_path.len == 0)) {
        \\        return try raw_js.importModuleDefaultAs(CallError!Any, target.module.?);
        \\    }
        \\    var cur: Any = if (comptime (target.from_default and target.module != null))
        \\        try raw_js.importModuleDefaultAs(CallError!Any, target.module.?)
        \\    else if (comptime (target.module != null))
        \\        .{ .handle = (try raw_js.importModule(target.module.?)).handle }
        \\    else
        \\        Any.globalThis;
        \\    errdefer cur.deinit();
        \\
        \\    inline for (target.ns_path) |seg| {
        \\        const next = try raw_js.getProp(CallError!Any, cur, seg);
        \\        cur.deinit();
        \\        cur = next;
        \\    }
        \\    const out = try raw_js.getProp(CallError!Any, cur, target.name);
        \\    cur.deinit();
        \\    return out;
        \\}
        \\
        \\fn setGlobalTargetRaw(comptime target: CallTarget, val: Any) CallError!void {
        \\    if (!has_host) return error.HostUnavailable;
        \\    var cur: Any = if (comptime (target.from_default and target.module != null))
        \\        try raw_js.importModuleDefaultAs(CallError!Any, target.module.?)
        \\    else if (comptime (target.module != null))
        \\        .{ .handle = (try raw_js.importModule(target.module.?)).handle }
        \\    else
        \\        Any.globalThis;
        \\    errdefer cur.deinit();
        \\
        \\    inline for (target.ns_path) |seg| {
        \\        const next = try raw_js.getProp(CallError!Any, cur, seg);
        \\        cur.deinit();
        \\        cur = next;
        \\    }
        \\    try raw_js.trySetProp(cur, target.name, val);
        \\    cur.deinit();
        \\}
        \\
        \\pub fn GlobalTarget(comptime T: type, comptime target: CallTarget) type {
        \\    return struct {
        \\        pub const ValueType = T;
        \\        pub const call_target: CallTarget = target;
        \\
        \\        js_name: []const u8 = target.name,
        \\
        \\        pub fn get(_: @This()) CallError!T {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const raw = try getGlobalTargetRaw(target);
        \\            defer raw.deinit();
        \\            return try fromJsRef(T, raw);
        \\        }
        \\
        \\        pub fn getAlloc(_: @This(), allocator: std.mem.Allocator) CallError!T {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const raw = try getGlobalTargetRaw(target);
        \\            defer raw.deinit();
        \\            return try fromJsRefAlloc(T, allocator, raw);
        \\        }
        \\
        \\        pub fn set(_: @This(), value: T) CallError!void {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const encoded = try toJsRefWithNullish(T, value, .null_or_undefined);
        \\            defer encoded.deinit();
        \\            try setGlobalTargetRaw(target, encoded);
        \\        }
        \\    };
        \\}
        \\
        \\pub fn Global(comptime T: type) type {
        \\    return struct {
        \\        pub const ValueType = T;
        \\
        \\        js_name: []const u8,
        \\        module: ?[]const u8 = null,
        \\
        \\        pub fn get(self: @This()) CallError!T {
        \\            if (!has_host) return error.HostUnavailable;
        \\            var cur: Any = if (self.module) |m|
        \\                .{ .handle = (try raw_js.importModuleDynamic(m)).handle }
        \\            else
        \\                Any.globalThis;
        \\            defer cur.deinit();
        \\            const raw = try raw_js.getPropDynamic(CallError!Any, cur, self.js_name);
        \\            defer raw.deinit();
        \\            return try fromJsRef(T, raw);
        \\        }
        \\
        \\        pub fn getAlloc(self: @This(), allocator: std.mem.Allocator) CallError!T {
        \\            if (!has_host) return error.HostUnavailable;
        \\            var cur: Any = if (self.module) |m|
        \\                .{ .handle = (try raw_js.importModuleDynamic(m)).handle }
        \\            else
        \\                Any.globalThis;
        \\            defer cur.deinit();
        \\            const raw = try raw_js.getPropDynamic(CallError!Any, cur, self.js_name);
        \\            defer raw.deinit();
        \\            return try fromJsRefAlloc(T, allocator, raw);
        \\        }
        \\
        \\        pub fn set(self: @This(), value: T) CallError!void {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const encoded = try toJsRefWithNullish(T, value, .null_or_undefined);
        \\            defer encoded.deinit();
        \\            var cur: Any = if (self.module) |m|
        \\                .{ .handle = (try raw_js.importModuleDynamic(m)).handle }
        \\            else
        \\                Any.globalThis;
        \\            defer cur.deinit();
        \\            try raw_js.trySetPropDynamic(cur, self.js_name, encoded);
        \\        }
        \\    };
        \\}
        \\
    );
}

test "appendJsDocComments normalizes CRLF, @param/@returns/@deprecated, and avoids //! or ////" {
    const alloc = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const params = [_]ir.JsDocParamIr{
        .{ .name = "url", .description = "Target endpoint\r\nwith second line" },
    };
    const jd = ir.JsDocIr{
        .summary = "!Leading bang\r\n/Leading slash\rLone CR\x00Control",
        .params = &params,
        .returns = "Response payload",
        .deprecated = "Use fetchV2 instead.",
        .throws = &.{"NetworkError"},
        .examples = &.{"fetchV1(\"/api\")"},
    };

    try appendJsDocComments(&out, alloc, jd);
    try out.appendSlice(alloc, "pub const x: u32 = 1;\n");

    try std.testing.expect(std.mem.indexOfScalar(u8, out.items, '\r') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.items, 0) == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "//!") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "////") == null);

    const res = try validateAndFormatZigSource(alloc, "jsdoc_test.zig", out.items);
    switch (res) {
        .formatted => |fmt| {
            defer alloc.free(fmt);
            try std.testing.expect(std.mem.indexOf(u8, fmt, "/// Deprecated: Use fetchV2 instead.") != null);
            try std.testing.expect(std.mem.indexOf(u8, fmt, "/// !Leading bang") != null);
            try std.testing.expect(std.mem.indexOf(u8, fmt, "/// /Leading slash") != null);
            try std.testing.expect(std.mem.indexOf(u8, fmt, "/// @param url - Target endpoint") != null);
            try std.testing.expect(std.mem.indexOf(u8, fmt, "/// @returns Response payload") != null);
        },
        .diagnostic => |diag| {
            defer alloc.free(diag);
            return error.TestUnexpectedResult;
        },
    }
}

test "validateAndFormatZigSource reports detailed line, column, and snippet on invalid Zig syntax" {
    const alloc = std.testing.allocator;
    const bad = "pub const ok = 1;\npub const broken =\n";
    const res = try validateAndFormatZigSource(alloc, "broken.zig", bad);
    switch (res) {
        .formatted => |fmt| {
            alloc.free(fmt);
            return error.TestUnexpectedResult;
        },
        .diagnostic => |diag| {
            defer alloc.free(diag);
            try std.testing.expect(std.mem.indexOf(u8, diag, "broken.zig:") != null);
            try std.testing.expect(std.mem.indexOf(u8, diag, "^") != null);
        },
    }
}

test "validateAndFormatZigSource catches ZIR errors via AstGen (duplicate struct members and parameter shadowing)" {
    const alloc = std.testing.allocator;

    const dup_struct =
        \\pub const Bad = struct {
        \\    init: bool,
        \\    pub fn init() void {}
        \\};
    ;
    switch (try validateAndFormatZigSource(alloc, "dup_struct.zig", dup_struct)) {
        .formatted => |fmt| {
            alloc.free(fmt);
            return error.TestUnexpectedResult;
        },
        .diagnostic => |diag| {
            defer alloc.free(diag);
            try std.testing.expect(std.mem.indexOf(u8, diag, "AstGen") != null);
            try std.testing.expect(std.mem.indexOf(u8, diag, "duplicate struct member") != null);
        },
    }

    const shadow_param =
        \\pub const self: u32 = 1;
        \\pub const A = struct {
        \\    pub fn m(self: *const @This()) void {
        \\        _ = self;
        \\    }
        \\};
    ;
    switch (try validateAndFormatZigSource(alloc, "shadow_param.zig", shadow_param)) {
        .formatted => |fmt| {
            alloc.free(fmt);
            return error.TestUnexpectedResult;
        },
        .diagnostic => |diag| {
            defer alloc.free(diag);
            try std.testing.expect(std.mem.indexOf(u8, diag, "AstGen") != null);
            try std.testing.expect(std.mem.indexOf(u8, diag, "function parameter shadows") != null);
        },
    }
}
