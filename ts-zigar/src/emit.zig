const std = @import("std");
const ir = @import("ir.zig");
const naming = @import("naming.zig");
const lower_types = @import("lower_types.zig");
const lower_unions = @import("lower_unions.zig");

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

    fn freshPrivateTypeIdent(
        self: *ModuleEmitCtx,
        sig: ir.SignatureIr,
    ) ![]u8 {
        while (true) {
            self.ret_type_counter += 1;
            const cand = try std.fmt.allocPrint(self.allocator, "__ZigarRet_{d}", .{self.ret_type_counter});
            var collides = self.isIdentTakenInCurrentScope(cand, sig.type_params);
            if (!collides) {
                if (sig.alloc_param_ident) |api| {
                    if (std.mem.eql(u8, unquoteZigIdent(api), cand)) collides = true;
                }
            }
            if (!collides) {
                for (sig.params) |p| {
                    if (std.mem.eql(u8, unquoteZigIdent(p.zig_ident), cand)) {
                        collides = true;
                        break;
                    }
                }
            }
            if (!collides) return cand;
            self.allocator.free(cand);
        }
    }

    fn emitSharedNominalTypeExpr(
        self: *ModuleEmitCtx,
        ty: *const ir.TypeIr,
        sig: ir.SignatureIr,
    ) ![]u8 {
        const type_ident = try self.freshPrivateTypeIdent(sig);
        defer self.allocator.free(type_ident);

        if (sig.type_params.len == 0) {
            try self.out.print(self.allocator, "const {s} = ", .{type_ident});
            try self.emitType(ty);
            try self.out.appendSlice(self.allocator, ";\n");
            return try self.allocator.dupe(u8, type_ident);
        } else {
            try self.out.print(self.allocator, "fn {s}(", .{type_ident});
            for (sig.type_params, 0..) |tp, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
            }
            try self.out.appendSlice(self.allocator, ") type {\n");
            for (sig.type_params) |tp| {
                if (!typeUsesTypeParam(ty, tp.zig_ident)) {
                    try self.out.print(self.allocator, "_ = {s};\n", .{tp.zig_ident});
                }
            }
            try self.out.appendSlice(self.allocator, "return ");
            try self.emitType(ty);
            try self.out.appendSlice(self.allocator, ";\n}\n");

            var expr: std.ArrayList(u8) = .empty;
            errdefer expr.deinit(self.allocator);
            try expr.print(self.allocator, "{s}(", .{type_ident});
            for (sig.type_params, 0..) |tp, idx| {
                if (idx > 0) try expr.appendSlice(self.allocator, ", ");
                try expr.appendSlice(self.allocator, tp.zig_ident);
            }
            try expr.append(self.allocator, ')');
            return try expr.toOwnedSlice(self.allocator);
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

    fn findDeclByZigPath(decls: []const ir.DeclIr, path: []const []const u8) ?*const ir.DeclIr {
        if (path.len == 0) return null;
        const head = unquoteZigIdent(path[0]);
        for (decls) |*d| {
            if (std.mem.eql(u8, unquoteZigIdent(d.zig_ident), head)) {
                if (path.len == 1) return d;
                return switch (d.kind) {
                    .namespace_decl => |sub| findDeclByZigPath(sub, path[1..]),
                    .struct_decl => |st| findDeclByZigPath(st.nested_decls, path[1..]),
                    else => null,
                };
            }
        }
        return null;
    }

    const TypeParamEnv = struct {
        params: []const ir.TypeParamIr,
        args: []const *const ir.TypeIr,
        arg_env: ?*const TypeParamEnv,
    };

    const VisitedDecl = struct {
        key: []const u8,
        prev: ?*const VisitedDecl,
    };

    fn isDeclKeyVisited(visited: ?*const VisitedDecl, key: []const u8) bool {
        var cur = visited;
        while (cur) |v| : (cur = v.prev) {
            if (std.mem.eql(u8, v.key, key)) return true;
        }
        return false;
    }

    const FpVisited = struct {
        mod_idx: u32,
        decl_id: u32,
        prev: ?*const FpVisited,
    };

    fn isFpVisited(visited: ?*const FpVisited, mod_idx: u32, decl_id: u32) bool {
        var cur = visited;
        while (cur) |v| : (cur = v.prev) {
            if (v.mod_idx == mod_idx and v.decl_id == decl_id) return true;
        }
        return false;
    }

    const TargetTypeAlias = struct {
        type_params: []const ir.TypeParamIr,
        target: *const ir.TypeIr,
    };

    fn findTargetTypeAlias(self: *const ModuleEmitCtx, dref: ir.DeclRefIr) ?TargetTypeAlias {
        if (dref.module_index >= self.pkg.modules.len) return null;
        const target_mod = &self.pkg.modules[dref.module_index];
        if (findDeclByZigPath(target_mod.decls, dref.decl_zig_path)) |target_decl| {
            switch (target_decl.kind) {
                .type_alias => |ta| return .{
                    .type_params = ta.type_params,
                    .target = ta.target,
                },
                else => {},
            }
        }
        return null;
    }

    fn findTargetGenericStruct(self: *const ModuleEmitCtx, dref: ir.DeclRefIr) ?ir.StructDeclIr {
        if (dref.module_index >= self.pkg.modules.len) return null;
        const target_mod = &self.pkg.modules[dref.module_index];
        if (findDeclByZigPath(target_mod.decls, dref.decl_zig_path)) |target_decl| {
            switch (target_decl.kind) {
                .struct_decl => |st| {
                    if (st.type_params.len > 0) return st;
                },
                else => {},
            }
        }
        return null;
    }

    fn findTargetGenericUnion(self: *const ModuleEmitCtx, dref: ir.DeclRefIr) ?ir.UnionDeclIr {
        if (dref.module_index >= self.pkg.modules.len) return null;
        const target_mod = &self.pkg.modules[dref.module_index];
        if (findDeclByZigPath(target_mod.decls, dref.decl_zig_path)) |target_decl| {
            switch (target_decl.kind) {
                .union_decl => |un| {
                    if (un.type_params.len > 0) return un;
                },
                else => {},
            }
        }
        return null;
    }

    fn appendNullishFingerprint(
        self: *const ModuleEmitCtx,
        buf: *std.ArrayList(u8),
        ty: *const ir.TypeIr,
        env: ?*const TypeParamEnv,
        fp_visited: ?*const FpVisited,
        depth: usize,
    ) error{OutOfMemory}!void {
        if (depth >= 24) {
            try buf.append(self.allocator, '_');
            return;
        }
        switch (ty.*) {
            .optional => |opt| {
                const tag: []const u8 = switch (opt.nullish_kind) {
                    .undefined_only, .none => "?u(",
                    .null_only, .null_or_undefined => "?n(",
                };
                try buf.appendSlice(self.allocator, tag);
                try self.appendNullishFingerprint(buf, opt.child, env, fp_visited, depth + 1);
                try buf.append(self.allocator, ')');
            },
            .slice => |elem_ty| {
                try buf.append(self.allocator, '[');
                try self.appendNullishFingerprint(buf, elem_ty, env, fp_visited, depth + 1);
                try buf.append(self.allocator, ']');
            },
            .pointer_const => |inner| {
                try self.appendNullishFingerprint(buf, inner, env, fp_visited, depth + 1);
            },
            .anon_struct => |fields| {
                try buf.append(self.allocator, '{');
                for (fields) |f| {
                    try buf.appendSlice(self.allocator, f.logical_name);
                    try buf.append(self.allocator, if (f.is_optional) '?' else ':');
                    try self.appendNullishFingerprint(buf, f.ty, env, fp_visited, depth + 1);
                    try buf.append(self.allocator, ';');
                }
                try buf.append(self.allocator, '}');
            },
            .tuple => |elems| {
                try buf.append(self.allocator, '(');
                for (elems) |el| {
                    if (el.is_variadic) {
                        try buf.appendSlice(self.allocator, "...");
                    } else if (el.is_optional) {
                        try buf.append(self.allocator, '?');
                    }
                    try self.appendNullishFingerprint(buf, el.ty, env, fp_visited, depth + 1);
                    try buf.append(self.allocator, ',');
                }
                try buf.append(self.allocator, ')');
            },
            .tagged_union => |tu| {
                try buf.append(self.allocator, '|');
                for (tu.variants) |v| {
                    try buf.appendSlice(self.allocator, v.logical_name);
                    try buf.append(self.allocator, ':');
                    try self.appendNullishFingerprint(buf, v.payload, env, fp_visited, depth + 1);
                    try buf.append(self.allocator, '|');
                }
            },
            .type_param_ref => |tp_ident| {
                if (env) |e| {
                    for (e.params, 0..) |tp, idx| {
                        if (std.mem.eql(u8, tp.zig_ident, tp_ident)) {
                            if (idx < e.args.len) {
                                try self.appendNullishFingerprint(buf, e.args[idx], e.arg_env, fp_visited, depth + 1);
                                return;
                            }
                            if (tp.default_type) |def_ty| {
                                try self.appendNullishFingerprint(buf, def_ty, e, fp_visited, depth + 1);
                                return;
                            }
                            break;
                        }
                    }
                }
                try buf.append(self.allocator, '@');
                try buf.appendSlice(self.allocator, tp_ident);
            },
            .decl_ref => |dref| {
                if (self.findTargetTypeAlias(dref)) |ta| {
                    if (ta.type_params.len > 0 and isFpVisited(fp_visited, dref.module_index, dref.target_decl_id)) {
                        try buf.print(self.allocator, "^a{d}:{d}", .{ dref.module_index, dref.target_decl_id });
                        return;
                    }
                    const next_fp = FpVisited{
                        .mod_idx = dref.module_index,
                        .decl_id = dref.target_decl_id,
                        .prev = fp_visited,
                    };
                    const next_env = TypeParamEnv{
                        .params = ta.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    try self.appendNullishFingerprint(
                        buf,
                        ta.target,
                        if (ta.type_params.len > 0) &next_env else null,
                        if (ta.type_params.len > 0) &next_fp else fp_visited,
                        depth + 1,
                    );
                    return;
                }
                if (self.findTargetGenericStruct(dref)) |st| {
                    if (isFpVisited(fp_visited, dref.module_index, dref.target_decl_id)) {
                        try buf.print(self.allocator, "^s{d}:{d}", .{ dref.module_index, dref.target_decl_id });
                        return;
                    }
                    const next_fp = FpVisited{
                        .mod_idx = dref.module_index,
                        .decl_id = dref.target_decl_id,
                        .prev = fp_visited,
                    };
                    const self_env = TypeParamEnv{
                        .params = st.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    try buf.print(self.allocator, "s{d}:{d}<", .{ dref.module_index, dref.target_decl_id });
                    for (st.type_params, 0..) |tp, idx| {
                        if (idx > 0) try buf.append(self.allocator, ',');
                        if (idx < dref.type_args.len) {
                            try self.appendNullishFingerprint(buf, dref.type_args[idx], env, &next_fp, depth + 1);
                        } else if (tp.default_type) |def_ty| {
                            try self.appendNullishFingerprint(buf, def_ty, &self_env, &next_fp, depth + 1);
                        } else {
                            try buf.append(self.allocator, '_');
                        }
                    }
                    try buf.append(self.allocator, '>');
                    return;
                }
                if (self.findTargetGenericUnion(dref)) |un| {
                    if (isFpVisited(fp_visited, dref.module_index, dref.target_decl_id)) {
                        try buf.print(self.allocator, "^u{d}:{d}", .{ dref.module_index, dref.target_decl_id });
                        return;
                    }
                    const next_fp = FpVisited{
                        .mod_idx = dref.module_index,
                        .decl_id = dref.target_decl_id,
                        .prev = fp_visited,
                    };
                    const self_env = TypeParamEnv{
                        .params = un.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    try buf.print(self.allocator, "u{d}:{d}<", .{ dref.module_index, dref.target_decl_id });
                    for (un.type_params, 0..) |tp, idx| {
                        if (idx > 0) try buf.append(self.allocator, ',');
                        if (idx < dref.type_args.len) {
                            try self.appendNullishFingerprint(buf, dref.type_args[idx], env, &next_fp, depth + 1);
                        } else if (tp.default_type) |def_ty| {
                            try self.appendNullishFingerprint(buf, def_ty, &self_env, &next_fp, depth + 1);
                        } else {
                            try buf.append(self.allocator, '_');
                        }
                    }
                    try buf.append(self.allocator, '>');
                    return;
                }
                try buf.append(self.allocator, '_');
            },
            else => try buf.append(self.allocator, '_'),
        }
    }

    fn computeDeclSpecKey(
        self: *const ModuleEmitCtx,
        kind_prefix: []const u8,
        dref: ir.DeclRefIr,
        type_params: []const ir.TypeParamIr,
        env: ?*const TypeParamEnv,
    ) error{OutOfMemory}![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        try buf.print(self.allocator, "{s}:{d}:{d}:", .{ kind_prefix, dref.module_index, dref.target_decl_id });
        const self_env = TypeParamEnv{
            .params = type_params,
            .args = dref.type_args,
            .arg_env = env,
        };
        for (type_params, 0..) |tp, idx| {
            if (idx > 0) try buf.append(self.allocator, ',');
            if (idx < dref.type_args.len) {
                try self.appendNullishFingerprint(&buf, dref.type_args[idx], env, null, 0);
            } else if (tp.default_type) |def_ty| {
                try self.appendNullishFingerprint(&buf, def_ty, &self_env, null, 0);
            } else {
                try buf.append(self.allocator, '_');
            }
        }
        return try buf.toOwnedSlice(self.allocator);
    }

    fn genericParamsArgsNeedSpec(
        self: *const ModuleEmitCtx,
        type_params: []const ir.TypeParamIr,
        dref: ir.DeclRefIr,
        env: ?*const TypeParamEnv,
        visited: ?*const VisitedDecl,
        depth: usize,
    ) error{OutOfMemory}!bool {
        const self_env = TypeParamEnv{
            .params = type_params,
            .args = dref.type_args,
            .arg_env = env,
        };
        for (type_params, 0..) |tp, idx| {
            if (idx < dref.type_args.len) {
                if (try self.typeNeedsNullishSpecEnv(dref.type_args[idx], env, visited, depth + 1)) return true;
            } else if (tp.default_type) |def_ty| {
                if (try self.typeNeedsNullishSpecEnv(def_ty, &self_env, visited, depth + 1)) return true;
            }
        }
        return false;
    }

    fn isResolvedOptionalEnv(
        self: *const ModuleEmitCtx,
        ty: *const ir.TypeIr,
        env: ?*const TypeParamEnv,
        depth: usize,
    ) bool {
        if (depth >= 24) return false;
        switch (ty.*) {
            .optional => return true,
            .pointer_const => |inner| return self.isResolvedOptionalEnv(inner, env, depth + 1),
            .type_param_ref => |tp_ident| {
                if (env) |e| {
                    for (e.params, 0..) |tp, idx| {
                        if (std.mem.eql(u8, tp.zig_ident, tp_ident)) {
                            if (idx < e.args.len) {
                                return self.isResolvedOptionalEnv(e.args[idx], e.arg_env, depth + 1);
                            }
                            if (tp.default_type) |def_ty| {
                                return self.isResolvedOptionalEnv(def_ty, e, depth + 1);
                            }
                            return false;
                        }
                    }
                }
                return false;
            },
            .decl_ref => |dref| {
                if (self.findTargetTypeAlias(dref)) |ta| {
                    const next_env = TypeParamEnv{
                        .params = ta.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    return self.isResolvedOptionalEnv(
                        ta.target,
                        if (ta.type_params.len > 0) &next_env else null,
                        depth + 1,
                    );
                }
                return false;
            },
            else => return false,
        }
    }

    fn isResolvedOptional(self: *const ModuleEmitCtx, ty: *const ir.TypeIr) bool {
        return self.isResolvedOptionalEnv(ty, null, 0);
    }

    fn aliasTargetIsKeyableContainer(
        self: *const ModuleEmitCtx,
        ty: *const ir.TypeIr,
        env: ?*const TypeParamEnv,
        depth: usize,
    ) bool {
        if (depth >= 24) return false;
        return switch (ty.*) {
            .anon_struct, .tuple, .tagged_union => true,
            .optional => |opt| self.aliasTargetIsKeyableContainer(opt.child, env, depth + 1),
            .pointer_const => |inner| self.aliasTargetIsKeyableContainer(inner, env, depth + 1),
            .type_param_ref => |tp_ident| blk: {
                if (env) |e| {
                    for (e.params, 0..) |tp, idx| {
                        if (std.mem.eql(u8, tp.zig_ident, tp_ident)) {
                            if (idx < e.args.len) {
                                break :blk self.aliasTargetIsKeyableContainer(e.args[idx], e.arg_env, depth + 1);
                            }
                            if (tp.default_type) |def_ty| {
                                break :blk self.aliasTargetIsKeyableContainer(def_ty, e, depth + 1);
                            }
                            break :blk false;
                        }
                    }
                }
                break :blk false;
            },
            .decl_ref => |dref| blk: {
                if (self.findTargetTypeAlias(dref)) |inner_ta| {
                    if (self.aliasTargetIsKeyableContainer(inner_ta.target, null, depth + 1)) {
                        break :blk false;
                    }
                    const next_env = TypeParamEnv{
                        .params = inner_ta.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    break :blk self.aliasTargetIsKeyableContainer(
                        inner_ta.target,
                        if (inner_ta.type_params.len > 0) &next_env else null,
                        depth + 1,
                    );
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn typeNeedsNullishSpecEnv(
        self: *const ModuleEmitCtx,
        ty: *const ir.TypeIr,
        env: ?*const TypeParamEnv,
        visited: ?*const VisitedDecl,
        depth: usize,
    ) error{OutOfMemory}!bool {
        if (depth >= 24) return false;
        switch (ty.*) {
            .optional => return true,
            .slice => |elem_ty| return self.typeNeedsNullishSpecEnv(elem_ty, env, visited, depth + 1),
            .pointer_const => |inner| return self.typeNeedsNullishSpecEnv(inner, env, visited, depth + 1),
            .anon_struct => |fields| {
                if (env == null) return false;
                for (fields) |f| {
                    if (try self.typeNeedsNullishSpecEnv(f.ty, env, visited, depth + 1)) return true;
                }
                return false;
            },
            .tuple => |elems| {
                if (env == null) return false;
                for (elems) |el| {
                    if (try self.typeNeedsNullishSpecEnv(el.ty, env, visited, depth + 1)) return true;
                }
                return false;
            },
            .tagged_union => |tu| {
                if (env == null) return false;
                for (tu.variants) |v| {
                    if (try self.typeNeedsNullishSpecEnv(v.payload, env, visited, depth + 1)) return true;
                }
                return false;
            },
            .type_param_ref => |tp_ident| {
                if (env) |e| {
                    for (e.params, 0..) |tp, idx| {
                        if (std.mem.eql(u8, tp.zig_ident, tp_ident)) {
                            if (idx < e.args.len) {
                                return self.typeNeedsNullishSpecEnv(e.args[idx], e.arg_env, visited, depth + 1);
                            }
                            if (tp.default_type) |def_ty| {
                                return self.typeNeedsNullishSpecEnv(def_ty, e, visited, depth + 1);
                            }
                            return false;
                        }
                    }
                }
                return false;
            },
            .decl_ref => |dref| {
                if (self.findTargetTypeAlias(dref)) |ta| {
                    if (ta.type_params.len > 0 and self.aliasTargetIsKeyableContainer(ta.target, null, 0)) {
                        if (!try self.genericParamsArgsNeedSpec(ta.type_params, dref, env, visited, depth)) {
                            return self.typeNeedsNullishSpecEnv(ta.target, null, visited, depth + 1);
                        }
                        const key = try self.computeDeclSpecKey("a", dref, ta.type_params, env);
                        defer self.allocator.free(key);
                        if (isDeclKeyVisited(visited, key)) return true;
                        const next_visited = VisitedDecl{ .key = key, .prev = visited };
                        const next_env = TypeParamEnv{
                            .params = ta.type_params,
                            .args = dref.type_args,
                            .arg_env = env,
                        };
                        return try self.typeNeedsNullishSpecEnv(ta.target, &next_env, &next_visited, depth + 1);
                    }
                    const next_env = TypeParamEnv{
                        .params = ta.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    return self.typeNeedsNullishSpecEnv(
                        ta.target,
                        if (ta.type_params.len > 0) &next_env else null,
                        visited,
                        depth + 1,
                    );
                }
                if (self.findTargetGenericStruct(dref)) |st| {
                    if (!try self.genericParamsArgsNeedSpec(st.type_params, dref, env, visited, depth)) return false;
                    const key = try self.computeDeclSpecKey("s", dref, st.type_params, env);
                    defer self.allocator.free(key);
                    if (isDeclKeyVisited(visited, key)) return true;
                    const next_visited = VisitedDecl{ .key = key, .prev = visited };
                    const next_env = TypeParamEnv{
                        .params = st.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    for (st.fields) |f| {
                        if (try self.typeNeedsNullishSpecEnv(f.ty, &next_env, &next_visited, depth + 1)) return true;
                    }
                    return false;
                }
                if (self.findTargetGenericUnion(dref)) |un| {
                    if (!try self.genericParamsArgsNeedSpec(un.type_params, dref, env, visited, depth)) return false;
                    const key = try self.computeDeclSpecKey("u", dref, un.type_params, env);
                    defer self.allocator.free(key);
                    if (isDeclKeyVisited(visited, key)) return true;
                    const next_visited = VisitedDecl{ .key = key, .prev = visited };
                    const next_env = TypeParamEnv{
                        .params = un.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    for (un.variants) |v| {
                        if (try self.typeNeedsNullishSpecEnv(v.payload, &next_env, &next_visited, depth + 1)) return true;
                    }
                    return false;
                }
                return false;
            },
            else => return false,
        }
    }

    fn emitRecurseSpec(self: *ModuleEmitCtx, key: []const u8, is_optional_site: bool) error{OutOfMemory}!void {
        if (is_optional_site) {
            try self.out.appendSlice(self.allocator, ".{ .self = .undefined_only, .child = .{ .recurse = ");
            try self.emitStringLit(key);
            try self.out.appendSlice(self.allocator, " } }");
        } else {
            try self.out.appendSlice(self.allocator, ".{ .recurse = ");
            try self.emitStringLit(key);
            try self.out.appendSlice(self.allocator, " }");
        }
    }

    fn emitFieldsNullishSpecList(
        self: *ModuleEmitCtx,
        fields: []const ir.FieldIr,
        env: *const TypeParamEnv,
        visited: ?*const VisitedDecl,
        spec_id: ?[]const u8,
        self_tag: []const u8,
        depth: usize,
    ) error{OutOfMemory}!void {
        try self.out.appendSlice(self.allocator, ".{ ");
        if (spec_id) |id_str| {
            try self.out.appendSlice(self.allocator, ".id = ");
            try self.emitStringLit(id_str);
            try self.out.appendSlice(self.allocator, ", ");
        }
        try self.out.print(self.allocator, ".self = {s}, .fields = .{{ ", .{self_tag});
        var emitted: usize = 0;
        for (fields) |f| {
            if (!try self.typeNeedsNullishSpecEnv(f.ty, env, visited, depth + 1)) continue;
            if (emitted > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, ".{ .name = ");
            try self.emitStringLit(f.logical_name);
            try self.out.appendSlice(self.allocator, ", .nullish = ");
            try self.emitNullishSpecEnv(f.ty, env, visited, null, f.is_optional, depth + 1);
            try self.out.appendSlice(self.allocator, " }");
            emitted += 1;
        }
        try self.out.appendSlice(self.allocator, " } }");
    }

    fn emitVariantsNullishSpecList(
        self: *ModuleEmitCtx,
        variants: []const ir.UnionVariantIr,
        env: *const TypeParamEnv,
        visited: ?*const VisitedDecl,
        spec_id: ?[]const u8,
        self_tag: []const u8,
        depth: usize,
    ) error{OutOfMemory}!void {
        try self.out.appendSlice(self.allocator, ".{ ");
        if (spec_id) |id_str| {
            try self.out.appendSlice(self.allocator, ".id = ");
            try self.emitStringLit(id_str);
            try self.out.appendSlice(self.allocator, ", ");
        }
        try self.out.print(self.allocator, ".self = {s}, .variants = .{{ ", .{self_tag});
        var emitted: usize = 0;
        for (variants) |v| {
            if (!try self.typeNeedsNullishSpecEnv(v.payload, env, visited, depth + 1)) continue;
            if (emitted > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, ".{ .name = ");
            try self.emitStringLit(v.logical_name);
            try self.out.appendSlice(self.allocator, ", .nullish = ");
            try self.emitNullishSpecEnv(v.payload, env, visited, null, false, depth + 1);
            try self.out.appendSlice(self.allocator, " }");
            emitted += 1;
        }
        try self.out.appendSlice(self.allocator, " } }");
    }

    fn emitNullishSpecEnv(
        self: *ModuleEmitCtx,
        ty: *const ir.TypeIr,
        env: ?*const TypeParamEnv,
        visited: ?*const VisitedDecl,
        pending_id: ?[]const u8,
        is_optional_site: bool,
        depth: usize,
    ) error{OutOfMemory}!void {
        if (depth >= 24) {
            try self.out.appendSlice(self.allocator, if (is_optional_site) ".undefined_only" else ".none");
            return;
        }
        const default_self_tag: []const u8 = if (is_optional_site) ".undefined_only" else ".none";
        switch (ty.*) {
            .optional => |opt| {
                const self_tag: []const u8 = if (is_optional_site)
                    ".undefined_only"
                else switch (opt.nullish_kind) {
                    .undefined_only => ".undefined_only",
                    .null_only, .null_or_undefined => ".null_only",
                    .none => ".undefined_only",
                };
                if (try self.typeNeedsNullishSpecEnv(opt.child, env, visited, depth + 1)) {
                    try self.out.appendSlice(self.allocator, ".{ ");
                    if (pending_id) |id_str| {
                        try self.out.appendSlice(self.allocator, ".id = ");
                        try self.emitStringLit(id_str);
                        try self.out.appendSlice(self.allocator, ", ");
                    }
                    try self.out.print(self.allocator, ".self = {s}, .child = ", .{self_tag});
                    try self.emitNullishSpecEnv(opt.child, env, visited, null, false, depth + 1);
                    try self.out.appendSlice(self.allocator, " }");
                } else {
                    try self.out.appendSlice(self.allocator, self_tag);
                }
            },
            .slice => |elem_ty| {
                if (try self.typeNeedsNullishSpecEnv(elem_ty, env, visited, depth + 1)) {
                    try self.out.print(self.allocator, ".{{ .self = {s}, .elem = ", .{default_self_tag});
                    try self.emitNullishSpecEnv(elem_ty, env, visited, null, false, depth + 1);
                    try self.out.appendSlice(self.allocator, " }");
                } else {
                    try self.out.appendSlice(self.allocator, default_self_tag);
                }
            },
            .anon_struct => |fields| {
                if (env) |e| {
                    if (try self.typeNeedsNullishSpecEnv(ty, e, visited, depth)) {
                        try self.emitFieldsNullishSpecList(fields, e, visited, pending_id, default_self_tag, depth);
                        return;
                    }
                }
                try self.out.appendSlice(self.allocator, default_self_tag);
            },
            .tuple => |elems| {
                if (env) |e| {
                    if (try self.typeNeedsNullishSpecEnv(ty, e, visited, depth)) {
                        try self.out.appendSlice(self.allocator, ".{ ");
                        if (pending_id) |id_str| {
                            try self.out.appendSlice(self.allocator, ".id = ");
                            try self.emitStringLit(id_str);
                            try self.out.appendSlice(self.allocator, ", ");
                        }
                        try self.out.print(self.allocator, ".self = {s}, .tuple = .{{ ", .{default_self_tag});
                        for (elems, 0..) |el, idx| {
                            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                            if (el.is_variadic) {
                                try self.emitSliceElemNullishSpecEnv(el.ty, e, visited, depth + 1);
                            } else {
                                try self.emitNullishSpecEnv(el.ty, e, visited, null, el.is_optional, depth + 1);
                            }
                        }
                        try self.out.appendSlice(self.allocator, " } }");
                        return;
                    }
                }
                try self.out.appendSlice(self.allocator, default_self_tag);
            },
            .tagged_union => |tu| {
                if (env) |e| {
                    if (try self.typeNeedsNullishSpecEnv(ty, e, visited, depth)) {
                        try self.emitVariantsNullishSpecList(tu.variants, e, visited, pending_id, default_self_tag, depth);
                        return;
                    }
                }
                try self.out.appendSlice(self.allocator, default_self_tag);
            },
            .pointer_const => |inner| {
                try self.emitNullishSpecEnv(inner, env, visited, pending_id, is_optional_site, depth + 1);
            },
            .type_param_ref => |tp_ident| {
                if (env) |e| {
                    for (e.params, 0..) |tp, idx| {
                        if (std.mem.eql(u8, tp.zig_ident, tp_ident)) {
                            if (idx < e.args.len) {
                                try self.emitNullishSpecEnv(e.args[idx], e.arg_env, visited, pending_id, is_optional_site, depth + 1);
                                return;
                            }
                            if (tp.default_type) |def_ty| {
                                try self.emitNullishSpecEnv(def_ty, e, visited, pending_id, is_optional_site, depth + 1);
                                return;
                            }
                            break;
                        }
                    }
                }
                try self.out.appendSlice(self.allocator, default_self_tag);
            },
            .decl_ref => |dref| {
                if (self.findTargetTypeAlias(dref)) |ta| {
                    if (ta.type_params.len > 0 and self.aliasTargetIsKeyableContainer(ta.target, null, 0)) {
                        if (try self.genericParamsArgsNeedSpec(ta.type_params, dref, env, visited, depth)) {
                            const key = try self.computeDeclSpecKey("a", dref, ta.type_params, env);
                            defer self.allocator.free(key);
                            if (isDeclKeyVisited(visited, key)) {
                                try self.emitRecurseSpec(key, is_optional_site);
                                return;
                            }
                            const next_visited = VisitedDecl{ .key = key, .prev = visited };
                            const next_env = TypeParamEnv{
                                .params = ta.type_params,
                                .args = dref.type_args,
                                .arg_env = env,
                            };
                            if (try self.typeNeedsNullishSpecEnv(ta.target, &next_env, &next_visited, depth + 1)) {
                                try self.emitNullishSpecEnv(ta.target, &next_env, &next_visited, key, is_optional_site, depth + 1);
                                return;
                            }
                        }
                        try self.emitNullishSpecEnv(ta.target, null, visited, null, is_optional_site, depth + 1);
                        return;
                    }
                    const next_env = TypeParamEnv{
                        .params = ta.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    try self.emitNullishSpecEnv(
                        ta.target,
                        if (ta.type_params.len > 0) &next_env else null,
                        visited,
                        pending_id,
                        is_optional_site,
                        depth + 1,
                    );
                    return;
                }
                if (self.findTargetGenericStruct(dref)) |st| {
                    if (try self.genericParamsArgsNeedSpec(st.type_params, dref, env, visited, depth)) {
                        const key = try self.computeDeclSpecKey("s", dref, st.type_params, env);
                        defer self.allocator.free(key);
                        if (isDeclKeyVisited(visited, key)) {
                            try self.emitRecurseSpec(key, is_optional_site);
                            return;
                        }
                        const next_visited = VisitedDecl{ .key = key, .prev = visited };
                        const next_env = TypeParamEnv{
                            .params = st.type_params,
                            .args = dref.type_args,
                            .arg_env = env,
                        };
                        var has_field_spec = false;
                        for (st.fields) |f| {
                            if (try self.typeNeedsNullishSpecEnv(f.ty, &next_env, &next_visited, depth + 1)) {
                                has_field_spec = true;
                                break;
                            }
                        }
                        if (has_field_spec) {
                            try self.emitFieldsNullishSpecList(st.fields, &next_env, &next_visited, key, default_self_tag, depth);
                            return;
                        }
                    }
                }
                if (self.findTargetGenericUnion(dref)) |un| {
                    if (try self.genericParamsArgsNeedSpec(un.type_params, dref, env, visited, depth)) {
                        const key = try self.computeDeclSpecKey("u", dref, un.type_params, env);
                        defer self.allocator.free(key);
                        if (isDeclKeyVisited(visited, key)) {
                            try self.emitRecurseSpec(key, is_optional_site);
                            return;
                        }
                        const next_visited = VisitedDecl{ .key = key, .prev = visited };
                        const next_env = TypeParamEnv{
                            .params = un.type_params,
                            .args = dref.type_args,
                            .arg_env = env,
                        };
                        var has_variant_spec = false;
                        for (un.variants) |v| {
                            if (try self.typeNeedsNullishSpecEnv(v.payload, &next_env, &next_visited, depth + 1)) {
                                has_variant_spec = true;
                                break;
                            }
                        }
                        if (has_variant_spec) {
                            try self.emitVariantsNullishSpecList(un.variants, &next_env, &next_visited, key, default_self_tag, depth);
                            return;
                        }
                    }
                }
                try self.out.appendSlice(self.allocator, default_self_tag);
            },
            else => {
                try self.out.appendSlice(self.allocator, default_self_tag);
            },
        }
    }

    fn emitNullishSpec(self: *ModuleEmitCtx, ty: *const ir.TypeIr, is_optional_site: bool) error{OutOfMemory}!void {
        try self.emitNullishSpecEnv(ty, null, null, null, is_optional_site, 0);
    }

    fn emitSliceElemNullishSpecEnv(
        self: *ModuleEmitCtx,
        ty: *const ir.TypeIr,
        env: ?*const TypeParamEnv,
        visited: ?*const VisitedDecl,
        depth: usize,
    ) error{OutOfMemory}!void {
        if (depth >= 24) {
            try self.out.appendSlice(self.allocator, ".none");
            return;
        }
        switch (ty.*) {
            .slice => |elem_ty| {
                try self.emitNullishSpecEnv(elem_ty, env, visited, null, false, depth + 1);
            },
            .pointer_const => |inner| {
                try self.emitSliceElemNullishSpecEnv(inner, env, visited, depth + 1);
            },
            .type_param_ref => |tp_ident| {
                if (env) |e| {
                    for (e.params, 0..) |tp, idx| {
                        if (std.mem.eql(u8, tp.zig_ident, tp_ident)) {
                            if (idx < e.args.len) {
                                try self.emitSliceElemNullishSpecEnv(e.args[idx], e.arg_env, visited, depth + 1);
                                return;
                            }
                            if (tp.default_type) |def_ty| {
                                try self.emitSliceElemNullishSpecEnv(def_ty, e, visited, depth + 1);
                                return;
                            }
                            break;
                        }
                    }
                }
                try self.out.appendSlice(self.allocator, ".none");
            },
            .decl_ref => |dref| {
                if (self.findTargetTypeAlias(dref)) |ta| {
                    const next_env = TypeParamEnv{
                        .params = ta.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    try self.emitSliceElemNullishSpecEnv(
                        ta.target,
                        if (ta.type_params.len > 0) &next_env else null,
                        visited,
                        depth + 1,
                    );
                    return;
                }
                try self.out.appendSlice(self.allocator, ".none");
            },
            else => {
                try self.out.appendSlice(self.allocator, ".none");
            },
        }
    }

    fn emitSliceElemNullishSpec(self: *ModuleEmitCtx, ty: *const ir.TypeIr) error{OutOfMemory}!void {
        try self.emitSliceElemNullishSpecEnv(ty, null, null, 0);
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
                for (elems, 0..) |el, idx| {
                    if (el.is_variadic and variadic_idx == null) {
                        variadic_idx = idx;
                    }
                }

                const tup_frame = [_][]const u8{"zigar_js_tuple"};
                try self.nested_decl_scopes.append(self.allocator, &tup_frame);
                defer _ = self.nested_decl_scopes.pop();

                try self.out.appendSlice(self.allocator, "struct { ");
                for (elems, 0..) |el, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.out.print(self.allocator, "{s}: ", .{el.zig_ident});
                    try self.emitType(el.ty);
                    if (el.is_variadic) {
                        try self.out.appendSlice(self.allocator, " = &.{}");
                    } else if (el.is_optional and self.isResolvedOptional(el.ty)) {
                        try self.out.appendSlice(self.allocator, " = null");
                    }
                }
                if (elems.len > 0) try self.out.appendSlice(self.allocator, ", ");
                if (variadic_idx) |vi| {
                    try self.out.print(
                        self.allocator,
                        "pub const zigar_js_tuple = .{{ .variadic_index = @as(?usize, {d}), .fields = .{{ ",
                        .{vi},
                    );
                } else {
                    try self.out.appendSlice(
                        self.allocator,
                        "pub const zigar_js_tuple = .{ .variadic_index = @as(?usize, null), .fields = .{ ",
                    );
                }
                for (elems, 0..) |el, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.out.print(self.allocator, ".{{ .is_optional = {s}, .nullish = ", .{
                        if (el.is_optional) "true" else "false",
                    });
                    if (el.is_variadic) {
                        try self.emitSliceElemNullishSpec(el.ty);
                    } else {
                        try self.emitNullishSpec(el.ty, el.is_optional);
                    }
                    try self.out.appendSlice(self.allocator, " }");
                }
                try self.out.appendSlice(self.allocator, " } }; }");
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
                const anon_frame = [_][]const u8{"zigar_js"};
                try self.nested_decl_scopes.append(self.allocator, &anon_frame);
                defer _ = self.nested_decl_scopes.pop();

                try self.out.appendSlice(self.allocator, "struct {\n");
                for (fields) |f| {
                    if (f.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
                    try self.out.print(self.allocator, "{s}: ", .{f.zig_ident});
                    try self.emitType(f.ty);
                    try self.emitFieldDefaultValue(f);
                    try self.out.appendSlice(self.allocator, ",\n");
                }
                try self.out.appendSlice(self.allocator, "pub const zigar_js = .{\n.fields = .{\n");
                for (fields) |f| {
                    try self.emitFieldDescriptorEntry(f);
                }
                try self.out.appendSlice(self.allocator, "},\n};\n}");
            },
            .inline_enum => |en| {
                try self.emitClosedEnumBody(null, false, en.backing, en.members);
            },
            .open_literal_union => |olu| {
                try self.emitOpenLiteralBody(null, olu);
            },
            .template_pattern => |pat| {
                try self.emitTemplatePatternBody(null, pat);
            },
            .tagged_union => |tu| {
                try self.emitTaggedUnionBody(null, &.{}, tu.discriminant_prop, tu.variants);
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
            self.isResolvedOptional(sig.params[first_trailing_opt - 1].ty))
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
            if (pi >= first_trailing_opt) {
                try self.out.print(
                    self.allocator,
                    "if (__zigar_argc > {d}) try __zigar_js.pushArg(__zigar_args, {s}, ",
                    .{ pi, p.zig_ident },
                );
            } else {
                try self.out.print(
                    self.allocator,
                    "try __zigar_js.pushArg(__zigar_args, {s}, ",
                    .{p.zig_ident},
                );
            }
            try self.emitNullishSpec(p.ty, p.is_optional);
            try self.out.appendSlice(self.allocator, ");\n");
        }
        if (has_rest) {
            const rest_param = sig.params[fixed_len];
            try self.out.print(
                self.allocator,
                "try __zigar_js.pushRestArgs(__zigar_args, {s}, ",
                .{rest_param.zig_ident},
            );
            try self.emitSliceElemNullishSpec(rest_param.ty);
            try self.out.appendSlice(self.allocator, ");\n");
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

        var param_type_exprs = try self.allocator.alloc(?[]u8, sig.params.len);
        @memset(param_type_exprs, null);
        defer {
            for (param_type_exprs) |pte_opt| {
                if (pte_opt) |buf| self.allocator.free(buf);
            }
            self.allocator.free(param_type_exprs);
        }

        if (d.alloc_companion_ident != null) {
            for (sig.params, 0..) |p, pi| {
                if (typeHasInlineNominal(p.ty)) {
                    param_type_exprs[pi] = try self.emitSharedNominalTypeExpr(p.ty, sig);
                }
            }
        }

        var ret_type_expr_opt: ?[]u8 = null;
        defer if (ret_type_expr_opt) |buf| self.allocator.free(buf);

        if (typeHasInlineNominal(sig.return_type)) {
            ret_type_expr_opt = try self.emitSharedNominalTypeExpr(sig.return_type, sig);
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
        for (sig.params, 0..) |p, pi| {
            if (param_count > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s}: ", .{p.zig_ident});
            if (param_type_exprs[pi]) |ptexpr| {
                try self.out.appendSlice(self.allocator, ptexpr);
            } else {
                try self.emitType(p.ty);
            }
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
            try self.out.print(self.allocator, "return @This().{s}(", .{alloc_fn_ident});
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
            for (sig.params, 0..) |p, pi| {
                try self.out.print(self.allocator, ", {s}: ", .{p.zig_ident});
                if (param_type_exprs[pi]) |ptexpr| {
                    try self.out.appendSlice(self.allocator, ptexpr);
                } else {
                    try self.emitType(p.ty);
                }
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

    fn emitFieldDefaultValue(self: *ModuleEmitCtx, f: ir.FieldIr) error{OutOfMemory}!void {
        if (f.is_optional and self.isResolvedOptional(f.ty)) {
            try self.out.appendSlice(self.allocator, " = null");
            return;
        }
        if (!f.is_optional) {
            if (f.literal_constraint) |lc| {
                switch (lc) {
                    .str => |s| {
                        try self.out.appendSlice(self.allocator, " = ");
                        try self.emitStringLit(s);
                    },
                    .num => |n| {
                        if (std.math.isFinite(n)) {
                            try self.out.print(self.allocator, " = {d}", .{n});
                        }
                    },
                    .boolean => |b| {
                        try self.out.print(self.allocator, " = {s}", .{if (b) "true" else "false"});
                    },
                    .bigint_val => |bi| {
                        if (std.fmt.parseInt(i64, bi, 0)) |iv| {
                            try self.out.print(self.allocator, " = {d}", .{iv});
                        } else |_| {}
                    },
                    .enum_member => |em| {
                        try self.out.print(self.allocator, " = .{s}", .{em.tag_zig_ident});
                    },
                }
            }
        }
    }

    fn emitFieldDescriptorEntry(self: *ModuleEmitCtx, f: ir.FieldIr) error{OutOfMemory}!void {
        try self.out.appendSlice(self.allocator, ".{ .name = ");
        try self.emitStringLit(f.logical_name);
        try self.out.appendSlice(self.allocator, ", .js_name = ");
        try self.emitStringLit(f.wire_name);
        try self.out.print(self.allocator, ", .is_optional = {s}, .nullish = ", .{
            if (f.is_optional) "true" else "false",
        });
        try self.emitNullishSpec(f.ty, f.is_optional);
        if (f.literal_constraint) |lc| {
            switch (lc) {
                .str => |s| {
                    try self.out.appendSlice(self.allocator, ", .expected_str = ");
                    try self.emitStringLit(s);
                },
                .num => |n| {
                    if (std.math.isFinite(n)) {
                        try self.out.print(self.allocator, ", .expected_num = @as(f64, {d})", .{n});
                    }
                },
                .boolean => |b| {
                    try self.out.print(self.allocator, ", .expected_bool = {s}", .{if (b) "true" else "false"});
                },
                .bigint_val => |bi| {
                    if (std.fmt.parseInt(i64, bi, 0)) |iv| {
                        try self.out.print(self.allocator, ", .expected_bigint_i64 = @as(i64, {d})", .{iv});
                    } else |_| {
                        try self.out.appendSlice(self.allocator, ", .expected_bigint_str = ");
                        try self.emitStringLit(bi);
                    }
                },
                .enum_member => |em| {
                    try self.out.appendSlice(self.allocator, ", .expected_enum_tag = ");
                    try self.emitStringLit(em.tag_logical_name);
                },
            }
        }
        try self.out.appendSlice(self.allocator, " },\n");
    }

    fn emitStructBody(
        self: *ModuleEmitCtx,
        wire_name: []const u8,
        is_global_scope: bool,
        is_default_export: bool,
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
            try self.emitFieldDefaultValue(f);
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
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitNullishSpec(sp.ty, false);
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

        {
            if (push_owner_seg) {
                try self.ns_wire_path.append(self.allocator, wire_name);
            }
            defer if (push_owner_seg) {
                _ = self.ns_wire_path.pop();
            };

            for (st.nested_decls) |nd| {
                try self.emitDecl(nd);
            }
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
        if (st.is_class) {
            try self.out.appendSlice(self.allocator, ",\n.ctor_target = ");
            try self.emitCallTargetLiteral(is_global_scope, wire_name, is_default_export, null);
        }
        if (st.has_private_constructor) {
            try self.out.appendSlice(self.allocator, ",\n.has_private_constructor = true");
        }
        if (st.has_non_public_members) {
            try self.out.appendSlice(self.allocator, ",\n.has_non_public_members = true");
        }
        try self.out.appendSlice(self.allocator, ",\n.fields = .{\n");
        for (st.fields) |f| {
            try self.emitFieldDescriptorEntry(f);
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

    fn enumMembersHaveLogicalName(members: []const ir.EnumMemberIr, name: []const u8) bool {
        for (members) |m| {
            if (std.mem.eql(u8, m.logical_name, name)) return true;
        }
        return false;
    }

    fn emitEnumValueDescriptorField(self: *ModuleEmitCtx, val: ir.EnumValueIr) error{OutOfMemory}!void {
        switch (val) {
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
            .boolean => |b| {
                try self.out.print(self.allocator, ", .bool_value = {s}", .{if (b) "true" else "false"});
            },
            .bigint_val => |bi| {
                try self.out.appendSlice(self.allocator, ", .bigint_value = ");
                try self.emitStringLit(bi);
            },
        }
    }

    fn emitClosedEnumBody(
        self: *ModuleEmitCtx,
        wire_name: ?[]const u8,
        is_const: bool,
        backing: lower_unions.EnumBackingKind,
        members: []const ir.EnumMemberIr,
    ) error{OutOfMemory}!void {
        switch (backing) {
            .none => try self.out.appendSlice(self.allocator, "enum {\n"),
            .i32 => try self.out.appendSlice(self.allocator, "enum(i32) {\n"),
            .i64 => try self.out.appendSlice(self.allocator, "enum(i64) {\n"),
        }

        var all_primary_str = true;
        var has_primary = false;
        for (members) |m| {
            if (m.alias_of_zig_ident != null) continue;
            has_primary = true;
            if (m.value != .str) {
                all_primary_str = false;
            }
            if (m.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
            if (backing != .none and m.int_backing_val != null) {
                try self.out.print(self.allocator, "{s} = {d},\n", .{ m.zig_ident, m.int_backing_val.? });
            } else {
                try self.out.print(self.allocator, "{s},\n", .{m.zig_ident});
            }
        }

        for (members) |m| {
            if (m.alias_of_zig_ident) |target_ident| {
                if (m.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
                try self.out.print(self.allocator, "pub const {s}: @This() = .{s};\n", .{ m.zig_ident, target_ident });
            }
        }

        if (has_primary and all_primary_str) {
            if (!enumMembersHaveLogicalName(members, "toSlice")) {
                try self.out.appendSlice(self.allocator, "pub fn toSlice(__zigar_self: @This()) []const u8 {\nreturn switch (__zigar_self) {\n");
                for (members) |m| {
                    if (m.alias_of_zig_ident != null) continue;
                    try self.out.print(self.allocator, ".{s} => ", .{m.zig_ident});
                    try self.emitStringLit(m.value.str);
                    try self.out.appendSlice(self.allocator, ",\n");
                }
                try self.out.appendSlice(self.allocator, "};\n}\n");
            }
            if (!enumMembersHaveLogicalName(members, "fromSlice")) {
                try self.out.appendSlice(self.allocator, "pub fn fromSlice(__zigar_val: []const u8) ?@This() {\n");
                for (members) |m| {
                    if (m.alias_of_zig_ident != null) continue;
                    try self.out.appendSlice(self.allocator, "if (@import(\"std\").mem.eql(u8, __zigar_val, ");
                    try self.emitStringLit(m.value.str);
                    try self.out.print(self.allocator, ")) return .{s};\n", .{m.zig_ident});
                }
                try self.out.appendSlice(self.allocator, "return null;\n}\n");
            }
        }

        if (has_primary and backing != .none) {
            const int_ty_name = if (backing == .i32) "i32" else "i64";
            if (!enumMembersHaveLogicalName(members, "toInt")) {
                try self.out.print(
                    self.allocator,
                    "pub fn toInt(__zigar_self: @This()) {s} {{\nreturn @intFromEnum(__zigar_self);\n}}\n",
                    .{int_ty_name},
                );
            }
            if (!enumMembersHaveLogicalName(members, "fromInt")) {
                try self.out.print(
                    self.allocator,
                    "pub fn fromInt(__zigar_val: {s}) ?@This() {{\nreturn switch (__zigar_val) {{\n",
                    .{int_ty_name},
                );
                for (members) |m| {
                    if (m.alias_of_zig_ident != null) continue;
                    if (m.int_backing_val) |iv| {
                        try self.out.print(self.allocator, "{d} => .{s},\n", .{ iv, m.zig_ident });
                    }
                }
                try self.out.appendSlice(self.allocator, "else => null,\n};\n}\n");
            }
        }

        try self.out.appendSlice(self.allocator, "pub const zigar_js = .{\n");
        if (wire_name) |wn| {
            try self.out.appendSlice(self.allocator, ".js_name = ");
            try self.emitStringLit(wn);
            try self.out.appendSlice(self.allocator, ",\n");
        }
        try self.out.print(self.allocator, ".is_const = {s},\n.members = .{{\n", .{
            if (is_const) "true" else "false",
        });
        for (members) |m| {
            try self.out.appendSlice(self.allocator, ".{ .tag = ");
            try self.emitStringLit(m.logical_name);
            try self.out.appendSlice(self.allocator, ", .js_name = ");
            try self.emitStringLit(m.wire_name);
            if (m.alias_of_logical_name) |alias_target| {
                try self.out.appendSlice(self.allocator, ", .is_alias = true, .alias_of = ");
                try self.emitStringLit(alias_target);
            }
            try self.emitEnumValueDescriptorField(m.value);
            try self.out.appendSlice(self.allocator, " },\n");
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
        backing: lower_unions.EnumBackingKind,
        members: []const ir.EnumMemberIr,
    ) error{OutOfMemory}!void {
        if (has_unknown_values) {
            try self.out.appendSlice(self.allocator, "struct {\n__zigar_value: __zigar_js.Any = .{ .handle = 0 },\n");
            for (members) |m| {
                if (m.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
                try self.out.print(self.allocator, "pub const {s}: __zigar_js.GlobalTarget(@This(), ", .{m.zig_ident});
                try self.emitCallTargetLiteral(
                    is_global_scope,
                    m.wire_name,
                    false,
                    if (push_owner_seg) wire_name else null,
                );
                try self.out.appendSlice(self.allocator, ", .none) = .{};\n");
            }
            if (!enumMembersHaveLogicalName(members, "deinit")) {
                try self.out.appendSlice(self.allocator, "pub fn deinit(__zigar_self: @This()) void {\n__zigar_self.__zigar_value.deinit();\n}\n");
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
                if (m.value == .unknown or (m.value == .num and !std.math.isFinite(m.value.num))) {
                    try self.out.appendSlice(self.allocator, ", .is_unknown = true");
                } else {
                    try self.emitEnumValueDescriptorField(m.value);
                }
                try self.out.appendSlice(self.allocator, " },\n");
            }
            try self.out.appendSlice(self.allocator, "},\n};\n}");
            return;
        }

        try self.emitClosedEnumBody(wire_name, is_const, backing, members);
    }

    fn emitOpenLiteralBody(
        self: *ModuleEmitCtx,
        wire_name: ?[]const u8,
        olu: ir.OpenLiteralUnionIr,
    ) error{OutOfMemory}!void {
        var has_from_collision = std.mem.eql(u8, olu.custom_logical_name, "from");
        if (!has_from_collision) {
            for (olu.known_members) |m| {
                if (std.mem.eql(u8, m.logical_name, "from")) {
                    has_from_collision = true;
                    break;
                }
            }
        }

        var frame_buf: [2][]const u8 = .{ "zigar_js", "from" };
        const frame_slice: []const []const u8 = if (has_from_collision) frame_buf[0..1] else frame_buf[0..2];
        try self.nested_decl_scopes.append(self.allocator, frame_slice);
        defer _ = self.nested_decl_scopes.pop();

        try self.out.appendSlice(self.allocator, "union(enum) {\n");
        for (olu.known_members) |m| {
            if (m.alias_of_zig_ident != null) continue;
            try self.out.print(self.allocator, "{s},\n", .{m.zig_ident});
        }
        try self.out.print(self.allocator, "{s}: ", .{olu.custom_tag_ident});
        try self.emitType(olu.custom_payload);
        try self.out.appendSlice(self.allocator, ",\n");

        if (!has_from_collision) {
            switch (olu.base_kind) {
                .str => {
                    try self.out.appendSlice(self.allocator, "pub fn from(__zigar_val: []const u8) @This() {\n");
                    for (olu.known_members) |m| {
                        if (m.alias_of_zig_ident != null) continue;
                        try self.out.appendSlice(self.allocator, "if (@import(\"std\").mem.eql(u8, __zigar_val, ");
                        try self.emitStringLit(m.value.str);
                        try self.out.print(self.allocator, ")) return .{s};\n", .{m.zig_ident});
                    }
                    try self.out.print(self.allocator, "return .{{ .{s} = __zigar_val }};\n}}\n", .{olu.custom_tag_ident});
                },
                .num => {
                    try self.out.appendSlice(self.allocator, "pub fn from(__zigar_val: f64) @This() {\n");
                    for (olu.known_members) |m| {
                        if (m.alias_of_zig_ident != null) continue;
                        if (m.value == .num and std.math.isFinite(m.value.num)) {
                            try self.out.print(self.allocator, "if (__zigar_val == @as(f64, {d})) return .{s};\n", .{ m.value.num, m.zig_ident });
                        }
                    }
                    try self.out.print(self.allocator, "return .{{ .{s} = __zigar_val }};\n}}\n", .{olu.custom_tag_ident});
                },
                .bigint => {
                    try self.out.appendSlice(self.allocator, "pub fn from(__zigar_val: i64) @This() {\n");
                    for (olu.known_members) |m| {
                        if (m.alias_of_zig_ident != null) continue;
                        if (m.value == .bigint_val) {
                            if (std.fmt.parseInt(i64, m.value.bigint_val, 0)) |iv| {
                                try self.out.print(self.allocator, "if (__zigar_val == @as(i64, {d})) return .{s};\n", .{ iv, m.zig_ident });
                            } else |_| {}
                        }
                    }
                    try self.out.print(self.allocator, "return .{{ .{s} = __zigar_val }};\n}}\n", .{olu.custom_tag_ident});
                },
            }
        }

        try self.out.appendSlice(self.allocator, "pub const zigar_js = .{\n");
        if (wire_name) |wn| {
            try self.out.appendSlice(self.allocator, ".js_name = ");
            try self.emitStringLit(wn);
            try self.out.appendSlice(self.allocator, ",\n");
        }
        try self.out.appendSlice(self.allocator, ".is_open_literal = true,\n.variants = .{\n");
        for (olu.known_members) |m| {
            if (m.alias_of_zig_ident != null) continue;
            try self.out.appendSlice(self.allocator, ".{ .tag = ");
            try self.emitStringLit(m.logical_name);
            try self.out.appendSlice(self.allocator, ", .js_name = ");
            try self.emitStringLit(m.wire_name);
            try self.out.appendSlice(self.allocator, ", .is_unit_literal = true");
            try self.emitEnumValueDescriptorField(m.value);
            try self.out.appendSlice(self.allocator, " },\n");
        }
        try self.out.appendSlice(self.allocator, ".{ .tag = ");
        try self.emitStringLit(olu.custom_logical_name);
        try self.out.appendSlice(self.allocator, ", .js_name = ");
        try self.emitStringLit(olu.custom_logical_name);
        try self.out.appendSlice(self.allocator, ", .is_custom = true },\n},\n};\n}");
    }

    fn emitTemplatePatternBody(
        self: *ModuleEmitCtx,
        wire_name: ?[]const u8,
        pat: ir.TemplatePatternIr,
    ) error{OutOfMemory}!void {
        try self.out.appendSlice(self.allocator, "struct {\nraw: []const u8,\npub const zigar_js = .{\n");
        if (wire_name) |wn| {
            try self.out.appendSlice(self.allocator, ".js_name = ");
            try self.emitStringLit(wn);
            try self.out.appendSlice(self.allocator, ",\n");
        }
        try self.out.appendSlice(self.allocator, ".is_template_literal = true,\n.head = ");
        try self.emitStringLit(pat.head);
        try self.out.appendSlice(self.allocator, ",\n.spans = .{\n");
        for (pat.spans) |sp| {
            try self.out.print(self.allocator, ".{{ .placeholder = .{s}, .choices = .{{ ", .{@tagName(sp.placeholder)});
            for (sp.choices, 0..) |ch_str, ci| {
                if (ci > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.emitStringLit(ch_str);
            }
            try self.out.appendSlice(self.allocator, " }, .literal_tail = ");
            try self.emitStringLit(sp.literal_tail);
            try self.out.appendSlice(self.allocator, " },\n");
        }
        try self.out.appendSlice(
            self.allocator,
            "},\n};\npub fn matches(__zigar_val: []const u8) bool {\nreturn __zigar_js.matchTemplatePattern(@This().zigar_js, __zigar_val);\n}\n" ++
                "pub fn from(__zigar_val: []const u8) error{TypeError}!@This() {\nif (!@This().matches(__zigar_val)) return error.TypeError;\nreturn .{ .raw = __zigar_val };\n}\n" ++
                "pub fn initComptime(comptime __zigar_val: []const u8) @This() {\ncomptime {\n@setEvalBranchQuota(20000);\nif (!__zigar_js.matchTemplatePattern(@This().zigar_js, __zigar_val)) {\n" ++
                "@compileError(\"String literal does not match TypeScript template literal pattern\");\n}\n}\nreturn .{ .raw = __zigar_val };\n}\n}",
        );
    }

    fn emitTaggedUnionBody(
        self: *ModuleEmitCtx,
        wire_name: ?[]const u8,
        type_params: []const ir.TypeParamIr,
        discriminant_prop: ?[]const u8,
        variants: []const ir.UnionVariantIr,
    ) error{OutOfMemory}!void {
        var has_from_collision = false;
        for (variants) |v| {
            if (std.mem.eql(u8, v.logical_name, "from")) {
                has_from_collision = true;
                break;
            }
        }

        var frame_buf: [2][]const u8 = .{ "zigar_js", "from" };
        const frame_slice: []const []const u8 = if (has_from_collision) frame_buf[0..1] else frame_buf[0..2];
        try self.nested_decl_scopes.append(self.allocator, frame_slice);
        defer _ = self.nested_decl_scopes.pop();

        try self.out.appendSlice(self.allocator, "union(enum) {\n");
        for (variants) |v| {
            if (v.payload.* == .void_type and v.unit_literal != null) {
                try self.out.print(self.allocator, "{s},\n", .{v.zig_ident});
            } else {
                try self.out.print(self.allocator, "{s}: ", .{v.zig_ident});
                try self.emitType(v.payload);
                try self.out.appendSlice(self.allocator, ",\n");
            }
        }
        if (!has_from_collision) {
            try self.out.appendSlice(self.allocator, "pub fn from(__zigar_val: anytype) @This() {\nreturn __zigar_js.coerceUnion(@This(), __zigar_val);\n}\n");
        }
        try self.out.appendSlice(self.allocator, "pub const zigar_js = .{\n");
        if (wire_name) |wn| {
            try self.out.appendSlice(self.allocator, ".js_name = ");
            try self.emitStringLit(wn);
            try self.out.appendSlice(self.allocator, ",\n");
        }
        if (type_params.len > 0) {
            try self.out.appendSlice(self.allocator, ".type_params = .{ ");
            for (type_params, 0..) |tp, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, tp.zig_ident);
            }
            try self.out.appendSlice(self.allocator, " },\n");
        }
        if (discriminant_prop) |dp| {
            try self.out.appendSlice(self.allocator, ".discriminant = ");
            try self.emitStringLit(dp);
            try self.out.appendSlice(self.allocator, ",\n");
        }
        try self.out.appendSlice(self.allocator, ".variants = .{\n");
        for (variants) |v| {
            try self.out.appendSlice(self.allocator, ".{ .tag = ");
            try self.emitStringLit(v.logical_name);
            try self.out.appendSlice(self.allocator, ", .js_name = ");
            try self.emitStringLit(v.wire_tag);
            if (v.unit_literal) |ul| {
                try self.out.appendSlice(self.allocator, ", .is_unit_literal = true");
                try self.emitEnumValueDescriptorField(ul);
            }
            if (v.disc_values.len > 0) {
                try self.out.appendSlice(self.allocator, ", .disc_values = .{ ");
                for (v.disc_values, 0..) |dv, di| {
                    if (di > 0) try self.out.appendSlice(self.allocator, ", ");
                    switch (dv) {
                        .str => |s| {
                            try self.out.appendSlice(self.allocator, ".{ .str_value = ");
                            try self.emitStringLit(s);
                            try self.out.appendSlice(self.allocator, " }");
                        },
                        .num => |n| {
                            if (std.math.isFinite(n)) {
                                try self.out.print(self.allocator, ".{{ .num_value = @as(f64, {d}) }}", .{n});
                            } else {
                                try self.out.appendSlice(self.allocator, ".{}");
                            }
                        },
                        .boolean => |b| {
                            try self.out.print(self.allocator, ".{{ .bool_value = {s} }}", .{if (b) "true" else "false"});
                        },
                        .bigint_val => |bi| {
                            try self.out.appendSlice(self.allocator, ".{ .bigint_value = ");
                            try self.emitStringLit(bi);
                            try self.out.appendSlice(self.allocator, " }");
                        },
                    }
                }
                try self.out.appendSlice(self.allocator, " }");
            }
            if (type_params.len == 0 and (try self.typeNeedsNullishSpecEnv(v.payload, null, null, 0))) {
                try self.out.appendSlice(self.allocator, ", .nullish = ");
                try self.emitNullishSpec(v.payload, false);
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
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitNullishSpec(gty, false);
                try self.out.appendSlice(self.allocator, ") = .{};\n");
            },
            .struct_decl => |st| {
                const push_owner = true;
                const is_default_cls = !d.is_global_scope and
                    self.ns_wire_path.items.len == 0 and
                    (d.is_default_export or self.isExportEqualsRootDecl(d));
                if (st.type_params.len == 0) {
                    try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                    try self.emitStructBody(d.wire_name, d.is_global_scope, is_default_cls, push_owner, st);
                    try self.out.appendSlice(self.allocator, ";\n");
                } else {
                    try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
                    for (st.type_params, 0..) |tp, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                    }
                    try self.out.appendSlice(self.allocator, ") type {\nreturn ");
                    try self.emitStructBody(d.wire_name, d.is_global_scope, is_default_cls, push_owner, st);
                    try self.out.appendSlice(self.allocator, ";\n}\n");
                }
            },
            .enum_decl => |en| {
                const push_owner = true;
                try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                try self.emitEnumBody(d.wire_name, d.is_global_scope, push_owner, en.is_const, en.has_unknown_values, en.backing, en.members);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .literal_enum_decl => |en| {
                try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                try self.emitClosedEnumBody(d.wire_name, false, en.backing, en.members);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .open_literal_decl => |olu| {
                try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                try self.emitOpenLiteralBody(d.wire_name, olu);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .template_pattern_decl => |pat| {
                try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                try self.emitTemplatePatternBody(d.wire_name, pat);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .union_decl => |un| {
                if (un.type_params.len == 0) {
                    try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                    try self.emitTaggedUnionBody(d.wire_name, &.{}, un.discriminant_prop, un.variants);
                    try self.out.appendSlice(self.allocator, ";\n");
                } else {
                    try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
                    for (un.type_params, 0..) |tp, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                    }
                    try self.out.appendSlice(self.allocator, ") type {\nreturn ");
                    try self.emitTaggedUnionBody(d.wire_name, un.type_params, un.discriminant_prop, un.variants);
                    try self.out.appendSlice(self.allocator, ";\n}\n");
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
        .tuple, .anon_struct, .tagged_union, .inline_enum, .open_literal_union, .template_pattern => true,
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
        .open_literal_union => |olu| typeUsesTypeParam(olu.custom_payload, tp_ident),
        .tagged_union => |tu| blk: {
            for (tu.variants) |v| {
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
        \\pub fn toJsRefWithSpec(comptime T: type, value: T, comptime spec: anytype) CallError!Any {
        \\    if (!has_host) return error.HostUnavailable;
        \\    return try raw_js.toJsRefWithSpec(T, value, spec);
        \\}
        \\
        \\pub fn toJsRefWithNullish(comptime T: type, value: T, comptime nk: NullishKind) CallError!Any {
        \\    return toJsRefWithSpec(T, value, nk);
        \\}
        \\
        \\pub fn toJsRef(comptime T: type, value: T) CallError!Any {
        \\    return toJsRefWithSpec(T, value, .null_or_undefined);
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
        \\pub fn pushArg(args: Args, value: anytype, comptime spec: anytype) CallError!void {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const encoded = try toJsRefWithSpec(@TypeOf(value), value, spec);
        \\    defer encoded.deinit();
        \\    _ = try args.push(encoded);
        \\}
        \\
        \\pub fn pushRestArgs(args: Args, slice_val: anytype, comptime elem_spec: anytype) CallError!void {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const SliceT = @TypeOf(slice_val);
        \\    const ElemT = @typeInfo(SliceT).pointer.child;
        \\    for (slice_val) |item| {
        \\        const encoded = try toJsRefWithSpec(ElemT, item, elem_spec);
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
        \\pub fn GlobalTarget(comptime T: type, comptime target: CallTarget, comptime spec: anytype) type {
        \\    return struct {
        \\        pub const ValueType = T;
        \\        pub const call_target: CallTarget = target;
        \\        pub const nullish_spec = spec;
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
        \\            const encoded = try toJsRefWithSpec(T, value, spec);
        \\            defer encoded.deinit();
        \\            try setGlobalTargetRaw(target, encoded);
        \\        }
        \\    };
        \\}
        \\
        \\pub fn GlobalWithSpec(comptime T: type, comptime spec: anytype) type {
        \\    return struct {
        \\        pub const ValueType = T;
        \\        pub const nullish_spec = spec;
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
        \\            const encoded = try toJsRefWithSpec(T, value, spec);
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
        \\pub const TemplatePlaceholderKind = if (has_host) raw_js.TemplatePlaceholderKind else enum {
        \\    any_string,
        \\    number,
        \\    bigint,
        \\    boolean,
        \\    literal_set,
        \\};
        \\
        \\fn resolveTemplatePlaceholderKind(comptime raw: anytype) TemplatePlaceholderKind {
        \\    const RawT = @TypeOf(raw);
        \\    if (RawT == TemplatePlaceholderKind) return raw;
        \\    return switch (@typeInfo(RawT)) {
        \\        .enum_literal, .@"enum" => @field(TemplatePlaceholderKind, @tagName(raw)),
        \\        else => @compileError("Invalid template placeholder kind: " ++ @typeName(RawT)),
        \\    };
        \\}
        \\
        \\fn slotMatchesBytes(comptime raw_kind: anytype, comptime choices: anytype, seg: []const u8) bool {
        \\    const kind = comptime resolveTemplatePlaceholderKind(raw_kind);
        \\    return switch (kind) {
        \\        .any_string => true,
        \\        .boolean => std.mem.eql(u8, seg, "true") or std.mem.eql(u8, seg, "false"),
        \\        .bigint => blk: {
        \\            if (seg.len == 0) break :blk false;
        \\            const digits = if (seg[0] == '-') seg[1..] else seg;
        \\            if (digits.len == 0 or std.mem.eql(u8, seg, "-0")) break :blk false;
        \\            for (digits) |ch| {
        \\                if (ch < '0' or ch > '9') break :blk false;
        \\            }
        \\            break :blk true;
        \\        },
        \\        .number => blk: {
        \\            if (seg.len == 0) break :blk false;
        \\            if (std.mem.eql(u8, seg, "NaN") or
        \\                std.mem.eql(u8, seg, "Infinity") or
        \\                std.mem.eql(u8, seg, "-Infinity") or
        \\                std.mem.eql(u8, seg, "+Infinity")) break :blk true;
        \\            for (seg) |ch| {
        \\                if (ch <= ' ' or ch == '_') break :blk false;
        \\            }
        \\            if (std.mem.startsWith(u8, seg, "0x") or std.mem.startsWith(u8, seg, "0X") or
        \\                std.mem.startsWith(u8, seg, "0o") or std.mem.startsWith(u8, seg, "0O") or
        \\                std.mem.startsWith(u8, seg, "0b") or std.mem.startsWith(u8, seg, "0B"))
        \\            {
        \\                _ = std.fmt.parseInt(u64, seg, 0) catch break :blk false;
        \\                break :blk true;
        \\            }
        \\            for (seg) |ch| {
        \\                if (std.ascii.isAlphabetic(ch) and ch != 'e' and ch != 'E') break :blk false;
        \\            }
        \\            _ = std.fmt.parseFloat(f64, seg) catch break :blk false;
        \\            break :blk true;
        \\        },
        \\        .literal_set => blk: {
        \\            inline for (choices) |c| {
        \\                if (std.mem.eql(u8, seg, c)) break :blk true;
        \\            }
        \\            break :blk false;
        \\        },
        \\    };
        \\}
        \\
        \\fn matchTemplateSpansAt(
        \\    comptime spans: anytype,
        \\    comptime idx: usize,
        \\    rem: []const u8,
        \\    failed_bits: ?*[spans.len][8]u64,
        \\    steps_left: *usize,
        \\) bool {
        \\    if (idx >= spans.len) return rem.len == 0;
        \\    if (steps_left.* == 0) return false;
        \\    steps_left.* -= 1;
        \\    if (failed_bits) |fb| {
        \\        if (rem.len < 512) {
        \\            const word = rem.len >> 6;
        \\            const bit: u6 = @intCast(rem.len & 63);
        \\            if ((fb[idx][word] & (@as(u64, 1) << bit)) != 0) return false;
        \\        }
        \\    }
        \\    const sp = spans[idx];
        \\    const sep: []const u8 = sp.literal_tail;
        \\    if (idx + 1 == spans.len) {
        \\        if (!std.mem.endsWith(u8, rem, sep)) return false;
        \\        const ok = slotMatchesBytes(sp.placeholder, sp.choices, rem[0 .. rem.len - sep.len]);
        \\        if (!ok) {
        \\            if (failed_bits) |fb| {
        \\                if (rem.len < 512) fb[idx][rem.len >> 6] |= (@as(u64, 1) << @intCast(rem.len & 63));
        \\            }
        \\        }
        \\        return ok;
        \\    }
        \\    if (sep.len == 0) {
        \\        if (comptime (resolveTemplatePlaceholderKind(sp.placeholder) == .any_string and
        \\            resolveTemplatePlaceholderKind(spans[idx + 1].placeholder) == .any_string))
        \\        {
        \\            return matchTemplateSpansAt(spans, idx + 1, rem, failed_bits, steps_left);
        \\        }
        \\        var split: usize = 0;
        \\        while (split <= rem.len) : (split += 1) {
        \\            if (slotMatchesBytes(sp.placeholder, sp.choices, rem[0..split]) and
        \\                matchTemplateSpansAt(spans, idx + 1, rem[split..], failed_bits, steps_left))
        \\            {
        \\                return true;
        \\            }
        \\        }
        \\        if (failed_bits) |fb| {
        \\            if (rem.len < 512) fb[idx][rem.len >> 6] |= (@as(u64, 1) << @intCast(rem.len & 63));
        \\        }
        \\        return false;
        \\    }
        \\    var search_from: usize = 0;
        \\    while (search_from + sep.len <= rem.len) {
        \\        const rel = std.mem.indexOfPos(u8, rem, search_from, sep) orelse break;
        \\        if (slotMatchesBytes(sp.placeholder, sp.choices, rem[0..rel]) and
        \\            matchTemplateSpansAt(spans, idx + 1, rem[rel + sep.len ..], failed_bits, steps_left))
        \\        {
        \\            return true;
        \\        }
        \\        search_from = rel + 1;
        \\    }
        \\    if (failed_bits) |fb| {
        \\        if (rem.len < 512) fb[idx][rem.len >> 6] |= (@as(u64, 1) << @intCast(rem.len & 63));
        \\    }
        \\    return false;
        \\}
        \\
        \\pub fn matchTemplatePattern(comptime spec: anytype, s: []const u8) bool {
        \\    if (has_host) return raw_js.matchTemplatePattern(spec, s);
        \\    const head: []const u8 = spec.head;
        \\    if (!std.mem.startsWith(u8, s, head)) return false;
        \\    var pos: usize = head.len;
        \\    inline for (spec.spans) |sp| {
        \\        if (sp.literal_tail.len > 0) {
        \\            const found = std.mem.indexOfPos(u8, s, pos, sp.literal_tail) orelse return false;
        \\            pos = found + sp.literal_tail.len;
        \\        }
        \\    }
        \\    var steps_left: usize = 65_536;
        \\    if (comptime (spec.spans.len > 0 and spec.spans.len <= 32)) {
        \\        var fb: [spec.spans.len][8]u64 = @splat(@splat(0));
        \\        return matchTemplateSpansAt(spec.spans, 0, s[head.len..], &fb, &steps_left);
        \\    }
        \\    return matchTemplateSpansAt(spec.spans, 0, s[head.len..], null, &steps_left);
        \\}
        \\
        \\fn isStringSliceCoercible(comptime T: type) bool {
        \\    if (T == []const u8 or T == []u8) return true;
        \\    return switch (@typeInfo(T)) {
        \\        .pointer => |pt| pt.size == .one and @typeInfo(pt.child) == .array and @typeInfo(pt.child).array.child == u8,
        \\        else => false,
        \\    };
        \\}
        \\
        \\pub fn coerceUnion(comptime U: type, val: anytype) U {
        \\    if (has_host) return raw_js.coerceUnion(U, val);
        \\    const ValT = @TypeOf(val);
        \\    if (ValT == U) return val;
        \\    const un = @typeInfo(U).@"union";
        \\    comptime var exact_idx: ?usize = null;
        \\    comptime var exact_count: usize = 0;
        \\    inline for (un.field_names, 0..) |_, i| {
        \\        const FT = un.field_types[i];
        \\        if (FT != void and FT == ValT) {
        \\            exact_idx = i;
        \\            exact_count += 1;
        \\        }
        \\    }
        \\    if (exact_count == 1) {
        \\        return @unionInit(U, un.field_names[exact_idx.?], val);
        \\    }
        \\    if (comptime isStringSliceCoercible(ValT)) {
        \\        const slice_val: []const u8 = val;
        \\        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
        \\            inline for (U.zigar_js.variants) |v| {
        \\                if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "str_value")) {
        \\                    if (std.mem.eql(u8, slice_val, v.str_value)) {
        \\                        return @unionInit(U, v.tag, {});
        \\                    }
        \\                }
        \\            }
        \\        }
        \\        comptime var str_idx: ?usize = null;
        \\        comptime var str_count: usize = 0;
        \\        inline for (un.field_names, 0..) |_, i| {
        \\            if (un.field_types[i] == []const u8) {
        \\                str_idx = i;
        \\                str_count += 1;
        \\            }
        \\        }
        \\        if (str_count == 1) {
        \\            return @unionInit(U, un.field_names[str_idx.?], slice_val);
        \\        }
        \\    }
        \\    if (ValT == bool) {
        \\        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
        \\            inline for (U.zigar_js.variants) |v| {
        \\                if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "bool_value")) {
        \\                    if (val == v.bool_value) {
        \\                        return @unionInit(U, v.tag, {});
        \\                    }
        \\                }
        \\            }
        \\        }
        \\    }
        \\    if (ValT == f64) {
        \\        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
        \\            inline for (U.zigar_js.variants) |v| {
        \\                if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "num_value")) {
        \\                    if (val == v.num_value) {
        \\                        return @unionInit(U, v.tag, {});
        \\                    }
        \\                }
        \\            }
        \\        }
        \\    }
        \\    if (ValT == i64) {
        \\        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
        \\            inline for (U.zigar_js.variants) |v| {
        \\                if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "bigint_value")) {
        \\                    if (comptime @as(?i64, std.fmt.parseInt(i64, v.bigint_value, 0) catch null)) |iv| {
        \\                        if (val == iv) return @unionInit(U, v.tag, {});
        \\                    }
        \\                }
        \\            }
        \\        }
        \\    }
        \\    const val_info = @typeInfo(ValT);
        \\    if (val_info == .comptime_int or val_info == .comptime_float) {
        \\        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
        \\            inline for (U.zigar_js.variants) |v| {
        \\                if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "num_value")) {
        \\                    if (@as(f64, val) == v.num_value) {
        \\                        return @unionInit(U, v.tag, {});
        \\                    }
        \\                }
        \\            }
        \\            if (val_info == .comptime_int) {
        \\                inline for (U.zigar_js.variants) |v| {
        \\                    if (@hasField(@TypeOf(v), "is_unit_literal") and @hasField(@TypeOf(v), "bigint_value")) {
        \\                        if (comptime @as(?i64, std.fmt.parseInt(i64, v.bigint_value, 0) catch null)) |iv| {
        \\                            if (val == @as(comptime_int, iv)) return @unionInit(U, v.tag, {});
        \\                        }
        \\                    }
        \\                }
        \\            }
        \\        }
        \\        comptime var num_idx: ?usize = null;
        \\        comptime var num_count: usize = 0;
        \\        inline for (un.field_names, 0..) |_, i| {
        \\            const FT = un.field_types[i];
        \\            if (FT == f64 or (val_info == .comptime_int and (FT == i64 or FT == i32))) {
        \\                num_idx = i;
        \\                num_count += 1;
        \\            }
        \\        }
        \\        if (num_count == 1) {
        \\            const TargetNum = un.field_types[num_idx.?];
        \\            return @unionInit(U, un.field_names[num_idx.?], @as(TargetNum, val));
        \\        }
        \\    }
        \\    @compileError("Cannot unambiguously coerce value of type " ++ @typeName(ValT) ++ " into union " ++ @typeName(U));
        \\}
        \\
        \\pub fn Global(comptime T: type) type {
        \\    return GlobalWithSpec(T, .null_or_undefined);
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
