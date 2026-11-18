const std = @import("std");
const ir = @import("ir.zig");
const naming = @import("naming.zig");
const lower_types = @import("lower_types.zig");
const lower_unions = @import("lower_unions.zig");
const lower_generics = @import("lower_generics.zig");
const type_ops = @import("type_ops.zig");

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
    active_default_owner_wire: ?[]const u8 = null,
    type_param_subst: ?[]const TypeParamSubst = null,

    const TypeParamSubst = struct {
        zig_ident: []const u8,
        expr: []const u8,
    };

    const SharedTypeHelper = struct {
        helper_ident: ?[]u8 = null,
        call_expr: ?[]u8 = null,

        fn deinit(self: SharedTypeHelper, allocator: std.mem.Allocator) void {
            if (self.helper_ident) |h| allocator.free(h);
            if (self.call_expr) |c| allocator.free(c);
        }
    };

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
            const def_root_opt: ?[]const u8 = self.mod.export_equals_wire_name orelse self.active_default_owner_wire;
            if (def_root_opt) |eq_name| {
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
            const comp_opts = [_]?[]const u8{
                decl.alloc_companion_ident,
                decl.slice_companion_ident,
                decl.slice_alloc_companion_ident,
                decl.narrow_companion_ident,
                decl.narrow_alloc_companion_ident,
                decl.default_companion_ident,
                decl.default_alloc_companion_ident,
                decl.with_companion_ident,
                decl.infer_companion_ident,
                decl.infer_alloc_companion_ident,
            };
            for (comp_opts) |co| {
                if (co) |ci| {
                    if (std.mem.eql(u8, unquoteZigIdent(ci), ident)) return true;
                }
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
                if (sig.self_param_ident) |spi| {
                    if (std.mem.eql(u8, unquoteZigIdent(spi), cand)) collides = true;
                }
            }
            if (!collides) {
                if (sig.this_param) |thp| {
                    if (std.mem.eql(u8, unquoteZigIdent(thp.zig_ident), cand)) collides = true;
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

    fn freshPrivateSpecIdent(self: *ModuleEmitCtx) ![]u8 {
        while (true) {
            self.ret_type_counter += 1;
            const cand = try std.fmt.allocPrint(self.allocator, "__ZigarOv_{d}", .{self.ret_type_counter});
            if (!self.isIdentTakenInCurrentScope(cand, &.{})) return cand;
            self.allocator.free(cand);
        }
    }

    fn emitSharedNominalTypeHelper(
        self: *ModuleEmitCtx,
        ty: *const ir.TypeIr,
        sig: ir.SignatureIr,
    ) !SharedTypeHelper {
        const type_ident = try self.freshPrivateTypeIdent(sig);
        errdefer self.allocator.free(type_ident);

        if (!typeUsesAnyTypeParam(ty, sig.type_params)) {
            try self.out.print(self.allocator, "const {s} = ", .{type_ident});
            try self.emitType(ty);
            try self.out.appendSlice(self.allocator, ";\n");
            return .{
                .helper_ident = null,
                .call_expr = type_ident,
            };
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
            const call_expr = try expr.toOwnedSlice(self.allocator);
            return .{
                .helper_ident = type_ident,
                .call_expr = call_expr,
            };
        }
    }

    fn emitSharedNominalTypeExpr(
        self: *ModuleEmitCtx,
        ty: *const ir.TypeIr,
        sig: ir.SignatureIr,
    ) ![]u8 {
        const helper = try self.emitSharedNominalTypeHelper(ty, sig);
        if (helper.helper_ident) |h| self.allocator.free(h);
        return helper.call_expr.?;
    }

    fn emitResolvedSharedType(
        self: *ModuleEmitCtx,
        ty: *const ir.TypeIr,
        sig: ir.SignatureIr,
        shared: SharedTypeHelper,
    ) error{OutOfMemory}!void {
        if (self.type_param_subst) |substs| {
            if (shared.helper_ident) |hid| {
                try self.out.print(self.allocator, "{s}(", .{hid});
                for (sig.type_params, 0..) |tp, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    if (lookupTypeParamSubst(substs, tp.zig_ident)) |sub_expr| {
                        try self.out.appendSlice(self.allocator, sub_expr);
                    } else {
                        try self.out.appendSlice(self.allocator, tp.zig_ident);
                    }
                }
                try self.out.append(self.allocator, ')');
                return;
            }
            if (shared.call_expr) |ce| {
                try self.out.appendSlice(self.allocator, ce);
                return;
            }
            try self.emitType(ty);
            return;
        }
        if (shared.call_expr) |ce| {
            try self.out.appendSlice(self.allocator, ce);
        } else {
            try self.emitType(ty);
        }
    }

    fn renderTypeToOwnedSlice(
        self: *ModuleEmitCtx,
        ty: *const ir.TypeIr,
        subst_opt: ?[]const TypeParamSubst,
    ) error{OutOfMemory}![]u8 {
        const saved_len = self.out.items.len;
        const prev_subst = self.type_param_subst;
        self.type_param_subst = subst_opt;
        defer {
            self.type_param_subst = prev_subst;
            self.out.shrinkRetainingCapacity(saved_len);
        }
        try self.emitType(ty);
        return try self.allocator.dupe(u8, self.out.items[saved_len..]);
    }

    fn lookupTypeParamSubst(substs: []const TypeParamSubst, tp_ident: []const u8) ?[]const u8 {
        for (substs) |s| {
            if (std.mem.eql(u8, s.zig_ident, tp_ident)) return s.expr;
        }
        return null;
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
                    .namespace_decl => |sub| findDeclByZigPath(sub.children, path[1..]),
                    .struct_decl => |st| findDeclByZigPath(st.nested_decls, path[1..]),
                    .enum_decl => |en| findDeclByZigPath(en.nested_decls, path[1..]),
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
            .js_record => |r| {
                try buf.appendSlice(self.allocator, "rec(");
                try self.appendNullishFingerprint(buf, r.key, env, fp_visited, depth + 1);
                try buf.append(self.allocator, ',');
                try self.appendNullishFingerprint(buf, r.value, env, fp_visited, depth + 1);
                try buf.append(self.allocator, ')');
            },
            .mapped_values_op => |mv| {
                try buf.appendSlice(self.allocator, "mval(");
                try self.appendNullishFingerprint(buf, mv.target, env, fp_visited, depth + 1);
                try buf.append(self.allocator, ',');
                try self.appendNullishFingerprint(buf, mv.value, env, fp_visited, depth + 1);
                try buf.append(self.allocator, ')');
            },
            .unary_type_op => |uo| {
                try buf.print(self.allocator, "{s}(", .{@tagName(uo.op)});
                try self.appendNullishFingerprint(buf, uo.operand, env, fp_visited, depth + 1);
                try buf.append(self.allocator, ')');
            },
            .key_filter_op => |kfo| {
                try buf.print(self.allocator, "{s}(", .{@tagName(kfo.kind)});
                try self.appendNullishFingerprint(buf, kfo.target, env, fp_visited, depth + 1);
                try buf.append(self.allocator, ')');
            },
            .index_access_op => |iao| {
                try buf.appendSlice(self.allocator, "idx(");
                try self.appendNullishFingerprint(buf, iao.object_ty, env, fp_visited, depth + 1);
                try buf.append(self.allocator, ')');
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
            .unary_type_op => |uo| return switch (uo.op) {
                .non_nullable => false,
                .readonly_type => self.isResolvedOptionalEnv(uo.operand, env, depth + 1),
                else => false,
            },
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

    const OptionalSiteMode = enum {
        none,
        undefined_only,
        preserve_null,
    };

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
            try self.emitNullishSpecEnvMode(f.ty, env, visited, null, if (f.is_optional) .preserve_null else .none, depth + 1);
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
        return self.emitNullishSpecEnvMode(
            ty,
            env,
            visited,
            pending_id,
            if (is_optional_site) .undefined_only else .none,
            depth,
        );
    }

    fn emitNullishSpecEnvMode(
        self: *ModuleEmitCtx,
        ty: *const ir.TypeIr,
        env: ?*const TypeParamEnv,
        visited: ?*const VisitedDecl,
        pending_id: ?[]const u8,
        opt_site: OptionalSiteMode,
        depth: usize,
    ) error{OutOfMemory}!void {
        const is_optional_site = (opt_site != .none);
        if (depth >= 24) {
            try self.out.appendSlice(self.allocator, if (is_optional_site) ".undefined_only" else ".none");
            return;
        }
        const default_self_tag: []const u8 = if (is_optional_site) ".undefined_only" else ".none";
        switch (ty.*) {
            .optional => |opt| {
                const self_tag: []const u8 = switch (opt_site) {
                    .undefined_only => ".undefined_only",
                    .preserve_null => switch (opt.nullish_kind) {
                        .null_only, .null_or_undefined => ".null_or_undefined",
                        .undefined_only, .none => ".undefined_only",
                    },
                    .none => switch (opt.nullish_kind) {
                        .undefined_only => ".undefined_only",
                        .null_only, .null_or_undefined => ".null_only",
                        .none => ".undefined_only",
                    },
                };
                if (try self.typeNeedsNullishSpecEnv(opt.child, env, visited, depth + 1)) {
                    try self.out.appendSlice(self.allocator, ".{ ");
                    if (pending_id) |id_str| {
                        try self.out.appendSlice(self.allocator, ".id = ");
                        try self.emitStringLit(id_str);
                        try self.out.appendSlice(self.allocator, ", ");
                    }
                    try self.out.print(self.allocator, ".self = {s}, .child = ", .{self_tag});
                    try self.emitNullishSpecEnvMode(opt.child, env, visited, null, .none, depth + 1);
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
                try self.emitNullishSpecEnvMode(inner, env, visited, pending_id, opt_site, depth + 1);
            },
            .type_param_ref => |tp_ident| {
                if (env) |e| {
                    for (e.params, 0..) |tp, idx| {
                        if (std.mem.eql(u8, tp.zig_ident, tp_ident)) {
                            if (idx < e.args.len) {
                                try self.emitNullishSpecEnvMode(e.args[idx], e.arg_env, visited, pending_id, opt_site, depth + 1);
                                return;
                            }
                            if (tp.default_type) |def_ty| {
                                try self.emitNullishSpecEnvMode(def_ty, e, visited, pending_id, opt_site, depth + 1);
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
                                try self.emitNullishSpecEnvMode(ta.target, &next_env, &next_visited, key, opt_site, depth + 1);
                                return;
                            }
                        }
                        try self.emitNullishSpecEnvMode(ta.target, null, visited, null, opt_site, depth + 1);
                        return;
                    }
                    const next_env = TypeParamEnv{
                        .params = ta.type_params,
                        .args = dref.type_args,
                        .arg_env = env,
                    };
                    try self.emitNullishSpecEnvMode(
                        ta.target,
                        if (ta.type_params.len > 0) &next_env else null,
                        visited,
                        pending_id,
                        opt_site,
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
            .js_function => try self.out.appendSlice(self.allocator, "__zigar_js.JsFunction"),
            .js_symbol => try self.out.appendSlice(self.allocator, "__zigar_js.Symbol"),
            .js_bigint => try self.out.appendSlice(self.allocator, "__zigar_js.BigInt"),
            .js_string => try self.out.appendSlice(self.allocator, "__zigar_js.String"),
            .binary_view => |bvk| try self.out.print(self.allocator, "__zigar_js.{s}", .{bvk.zigTypeIdent()}),
            .self_type => |sid| try self.emitIdentSegment(sid),
            .type_param_ref => |tp_ident| {
                if (self.type_param_subst) |substs| {
                    if (lookupTypeParamSubst(substs, tp_ident)) |sub_expr| {
                        try self.out.appendSlice(self.allocator, sub_expr);
                        return;
                    }
                }
                try self.out.appendSlice(self.allocator, tp_ident);
            },
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
            .js_record => |r| {
                try self.out.appendSlice(self.allocator, "__zigar_js.Record(");
                try self.emitType(r.key);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitType(r.value);
                try self.out.append(self.allocator, ')');
            },
            .mapped_values_op => |mv| {
                if (mv.value.* != .type_param_ref and try self.typeNeedsNullishSpecEnv(mv.value, null, null, 0)) {
                    try self.out.appendSlice(self.allocator, "__zigar_js.MappedValuesSpec(");
                    try self.emitType(mv.target);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitType(mv.value);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitNullishSpecEnvMode(mv.value, null, null, null, .none, 0);
                    try self.out.append(self.allocator, ')');
                } else {
                    try self.out.appendSlice(self.allocator, "__zigar_js.MappedValues(");
                    try self.emitType(mv.target);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitType(mv.value);
                    try self.out.append(self.allocator, ')');
                }
            },
            .unary_type_op => |uo| {
                try self.out.print(self.allocator, "__zigar_js.{s}(", .{uo.op.runtimeHelperName()});
                try self.emitType(uo.operand);
                try self.out.append(self.allocator, ')');
            },
            .key_filter_op => |kfo| {
                try self.out.print(self.allocator, "__zigar_js.{s}(", .{kfo.kind.runtimeHelperName()});
                try self.emitType(kfo.target);
                try self.out.appendSlice(self.allocator, ", ");
                switch (kfo.keys) {
                    .str_lit => |s| try self.emitStringLit(s),
                    .str_list => |list| {
                        try self.out.appendSlice(self.allocator, "&.{ ");
                        for (list, 0..) |s, idx| {
                            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                            try self.emitStringLit(s);
                        }
                        try self.out.appendSlice(self.allocator, " }");
                    },
                    .ty => |te| try self.emitType(te),
                }
                try self.out.append(self.allocator, ')');
            },
            .index_access_op => |iao| {
                try self.out.appendSlice(self.allocator, "__zigar_js.IndexAccess(");
                try self.emitType(iao.object_ty);
                try self.out.appendSlice(self.allocator, ", ");
                switch (iao.index_spec) {
                    .str_lit => |s| try self.emitStringLit(s),
                    .str_list => |list| {
                        try self.out.appendSlice(self.allocator, "&.{ ");
                        for (list, 0..) |s, idx| {
                            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                            try self.emitStringLit(s);
                        }
                        try self.out.appendSlice(self.allocator, " }");
                    },
                    .int_lit => |i| try self.out.print(self.allocator, "{d}", .{i}),
                    .ty => |te| try self.emitType(te),
                }
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
                if (fp.this_param) |thp| {
                    try self.out.appendSlice(self.allocator, "__zigar_js.CallableWithThis(");
                    try self.emitType(thp);
                    try self.out.appendSlice(self.allocator, ", fn (");
                } else {
                    try self.out.appendSlice(self.allocator, "__zigar_js.Callable(fn (");
                }
                for (fp.params, 0..) |pt, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.emitType(pt);
                }
                try self.out.appendSlice(self.allocator, ") ");
                try self.emitType(fp.return_type);
                try self.out.append(self.allocator, ')');
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
                try self.emitClosedEnumBody(null, false, false, en.backing, en.members, &.{});
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

    const RecvSpec = struct { ident: []const u8, self_ty: []const u8 };

    fn emitSigHeaderParams(
        self: *ModuleEmitCtx,
        sig: ir.SignatureIr,
        recv_opt: ?RecvSpec,
        alloc_param_opt: ?[]const u8,
        this_type_expr_opt: ?[]const u8,
        param_type_exprs: []const ?[]u8,
        is_slice_companion: bool,
    ) error{OutOfMemory}!void {
        var param_count: usize = 0;
        if (recv_opt) |rv| {
            try self.out.print(self.allocator, "{s}: {s}", .{ rv.ident, rv.self_ty });
            param_count += 1;
        }
        for (sig.type_params) |tp| {
            if (param_count > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
            param_count += 1;
        }
        if (alloc_param_opt) |alloc_param| {
            if (param_count > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s}: @import(\"std\").mem.Allocator", .{alloc_param});
            param_count += 1;
        }
        if (sig.this_param) |thp| {
            if (param_count > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s}: ", .{thp.zig_ident});
            if (this_type_expr_opt) |ttexpr| {
                try self.out.appendSlice(self.allocator, ttexpr);
            } else {
                try self.emitType(thp.ty);
            }
            param_count += 1;
        }
        for (sig.params, 0..) |p, pi| {
            if (param_count > 0) try self.out.appendSlice(self.allocator, ", ");
            if (p.callback_sig != null or (p.is_rest and !is_slice_companion)) {
                try self.out.print(self.allocator, "{s}: anytype", .{p.zig_ident});
            } else {
                try self.out.print(self.allocator, "{s}: ", .{p.zig_ident});
                if (param_type_exprs[pi]) |ptexpr| {
                    try self.out.appendSlice(self.allocator, ptexpr);
                } else {
                    try self.emitType(p.ty);
                }
            }
            param_count += 1;
        }
    }

    fn emitSigForwardArgs(
        self: *ModuleEmitCtx,
        sig: ir.SignatureIr,
        recv_ident_opt: ?[]const u8,
        alloc_expr_opt: ?[]const u8,
    ) error{OutOfMemory}!void {
        var call_idx: usize = 0;
        if (recv_ident_opt) |recv_ident| {
            try self.out.appendSlice(self.allocator, recv_ident);
            call_idx += 1;
        }
        for (sig.type_params) |tp| {
            if (call_idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, tp.zig_ident);
            call_idx += 1;
        }
        if (alloc_expr_opt) |alloc_expr| {
            if (call_idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, alloc_expr);
            call_idx += 1;
        }
        if (sig.this_param) |thp| {
            if (call_idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, thp.zig_ident);
            call_idx += 1;
        }
        for (sig.params) |p| {
            if (call_idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, p.zig_ident);
            call_idx += 1;
        }
    }

    fn emitNarrowCompanions(
        self: *ModuleEmitCtx,
        pub_kw: []const u8,
        primary_ident: []const u8,
        narrow_ident: []const u8,
        narrow_alloc_ident_opt: ?[]const u8,
        sig: ir.SignatureIr,
        recv_opt: ?RecvSpec,
        this_type_expr_opt: ?[]const u8,
        param_type_exprs: []const ?[]u8,
    ) error{OutOfMemory}!void {
        const tpt = sig.type_predicate_target orelse return;
        const target_ty = tpt.target_ty;
        const subject_ident: []const u8 = switch (tpt.subject) {
            .param_index => |pidx| if (pidx < sig.params.len) sig.params[pidx].zig_ident else return,
            .self_receiver => if (recv_opt) |rv| rv.ident else return,
            .explicit_this => if (sig.this_param) |thp| thp.zig_ident else return,
        };

        var target_expr_opt: ?[]u8 = null;
        defer if (target_expr_opt) |buf| self.allocator.free(buf);
        if (typeHasInlineNominal(target_ty)) {
            target_expr_opt = try self.emitSharedNominalTypeExpr(target_ty, sig);
        }

        try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, narrow_ident });
        try self.emitSigHeaderParams(sig, recv_opt, null, this_type_expr_opt, param_type_exprs, false);
        try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
        if (!sig.type_predicate_asserts) try self.out.append(self.allocator, '?');
        if (target_expr_opt) |texpr| {
            try self.out.appendSlice(self.allocator, texpr);
        } else {
            try self.emitType(target_ty);
        }
        try self.out.appendSlice(self.allocator, " {\n");

        const recv_id_only: ?[]const u8 = if (recv_opt) |rv| rv.ident else null;
        if (narrow_alloc_ident_opt) |narrow_alloc_id| {
            try self.out.print(self.allocator, "return @This().{s}(", .{narrow_alloc_id});
            try self.emitSigForwardArgs(sig, recv_id_only, "try __zigar_js.defaultAllocator()");
            try self.out.appendSlice(self.allocator, ");\n}\n");

            const alloc_param = sig.alloc_param_ident orelse "allocator";
            try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, narrow_alloc_id });
            try self.emitSigHeaderParams(sig, recv_opt, alloc_param, this_type_expr_opt, param_type_exprs, false);
            try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
            if (!sig.type_predicate_asserts) try self.out.append(self.allocator, '?');
            if (target_expr_opt) |texpr| {
                try self.out.appendSlice(self.allocator, texpr);
            } else {
                try self.emitType(target_ty);
            }
            try self.out.appendSlice(self.allocator, " {\n");
            if (sig.type_predicate_asserts) {
                try self.out.print(self.allocator, "try @This().{s}(", .{primary_ident});
                try self.emitSigForwardArgs(sig, recv_id_only, null);
                try self.out.appendSlice(self.allocator, ");\nreturn try __zigar_js.narrowJsValueAlloc(");
            } else {
                try self.out.print(self.allocator, "if (!(try @This().{s}(", .{primary_ident});
                try self.emitSigForwardArgs(sig, recv_id_only, null);
                try self.out.appendSlice(self.allocator, "))) return null;\nreturn try __zigar_js.narrowJsValueAlloc(");
            }
            if (target_expr_opt) |texpr| {
                try self.out.appendSlice(self.allocator, texpr);
            } else {
                try self.emitType(target_ty);
            }
            try self.out.print(self.allocator, ", {s}, {s});\n}}\n", .{ alloc_param, subject_ident });
        } else {
            if (sig.type_predicate_asserts) {
                try self.out.print(self.allocator, "try @This().{s}(", .{primary_ident});
                try self.emitSigForwardArgs(sig, recv_id_only, null);
                try self.out.appendSlice(self.allocator, ");\nreturn try __zigar_js.narrowJsValue(");
            } else {
                try self.out.print(self.allocator, "if (!(try @This().{s}(", .{primary_ident});
                try self.emitSigForwardArgs(sig, recv_id_only, null);
                try self.out.appendSlice(self.allocator, "))) return null;\nreturn try __zigar_js.narrowJsValue(");
            }
            if (target_expr_opt) |texpr| {
                try self.out.appendSlice(self.allocator, texpr);
            } else {
                try self.emitType(target_ty);
            }
            try self.out.print(self.allocator, ", {s});\n}}\n", .{subject_ident});
        }
    }

    fn emitOverloadDispatcher(
        self: *ModuleEmitCtx,
        pub_kw: []const u8,
        od: ir.OverloadDispatchIr,
        recv_opt: ?RecvSpec,
    ) error{OutOfMemory}!void {
        const spec_ident = try self.freshPrivateSpecIdent();
        defer self.allocator.free(spec_ident);

        try self.out.print(self.allocator, "const {s} = .{{\n", .{spec_ident});
        for (od.candidates) |cand| {
            const csig = cand.signature;
            const has_rest = csig.params.len > 0 and csig.params[csig.params.len - 1].is_rest;
            const fixed_len = if (has_rest) csig.params.len - 1 else csig.params.len;
            const has_this = csig.this_param != null;

            var first_trailing_opt: usize = fixed_len;
            while (first_trailing_opt > 0 and
                csig.params[first_trailing_opt - 1].is_optional and
                self.isResolvedOptional(csig.params[first_trailing_opt - 1].ty))
            {
                first_trailing_opt -= 1;
            }
            const min_arity: usize = first_trailing_opt + @intFromBool(has_this);

            try self.out.appendSlice(self.allocator, ".{ .fn_name = ");
            try self.emitStringLit(cand.target_ident);
            try self.out.appendSlice(self.allocator, ", .alloc_fn_name = @as(?[]const u8, ");
            if (cand.alloc_target_ident) |afn| {
                try self.emitStringLit(afn);
            } else {
                try self.out.appendSlice(self.allocator, "null");
            }
            try self.out.appendSlice(self.allocator, "), .slice_fn_name = @as(?[]const u8, ");
            if (cand.slice_target_ident) |sfn| {
                try self.emitStringLit(sfn);
            } else {
                try self.out.appendSlice(self.allocator, "null");
            }
            try self.out.appendSlice(self.allocator, "), .infer_fn_name = @as(?[]const u8, ");
            if (cand.infer_target_ident) |ifn| {
                try self.emitStringLit(ifn);
            } else {
                try self.out.appendSlice(self.allocator, "null");
            }
            try self.out.appendSlice(self.allocator, "), .infer_alloc_fn_name = @as(?[]const u8, ");
            if (cand.infer_alloc_target_ident) |iafn| {
                try self.emitStringLit(iafn);
            } else {
                try self.out.appendSlice(self.allocator, "null");
            }
            try self.out.print(
                self.allocator,
                "), .type_param_count = @as(usize, {d}), .tp_constraints = .{{ ",
                .{csig.type_params.len},
            );
            for (csig.type_params, 0..) |tp, tpi| {
                if (tpi > 0) try self.out.appendSlice(self.allocator, ", ");
                if (tp.enforce_constraint) {
                    if (tp.constraint) |ct| {
                        if (!typeUsesAnyTypeParam(ct, csig.type_params)) {
                            try self.out.appendSlice(self.allocator, "@as(?type, ");
                            try self.emitType(ct);
                            try self.out.append(self.allocator, ')');
                            continue;
                        }
                    }
                }
                try self.out.appendSlice(self.allocator, "@as(?type, null)");
            }
            try self.out.print(
                self.allocator,
                " }}, .has_this_param = {s}, .has_rest = {s}, .min_arity = @as(usize, {d}), .fixed_params = .{{ ",
                .{
                    if (has_this) "true" else "false",
                    if (has_rest) "true" else "false",
                    min_arity,
                },
            );
            var emitted_fp: usize = 0;
            if (csig.this_param) |thp| {
                const gp = classifyOverloadGenericParam(thp.ty, csig.type_params);
                try self.out.print(
                    self.allocator,
                    ".{{ .kind = .typed, .nullable = {s}, .cb_arity = @as(?usize, null), .tp_idx = ",
                    .{if (self.isResolvedOptional(thp.ty)) "true" else "false"},
                );
                if (gp.tp_idx) |tpi| {
                    try self.out.print(self.allocator, "@as(?usize, {d})", .{tpi});
                } else {
                    try self.out.appendSlice(self.allocator, "@as(?usize, null)");
                }
                try self.out.print(self.allocator, ", .tp_mode = .{s} }}", .{@tagName(gp.mode)});
                emitted_fp += 1;
            }
            for (csig.params[0..fixed_len]) |p| {
                if (emitted_fp > 0) try self.out.appendSlice(self.allocator, ", ");
                const nullable = p.is_optional or self.isResolvedOptional(p.ty);
                const kind_str = if (p.callback_sig != null) ".callback" else ".typed";
                const gp = if (p.callback_sig != null)
                    lower_generics.OverloadGenericParamRef{}
                else
                    classifyOverloadGenericParam(p.ty, csig.type_params);
                if (p.callback_sig) |cbs| {
                    const cb_arity = cbs.params.len + @intFromBool(cbs.this_param != null);
                    try self.out.print(
                        self.allocator,
                        ".{{ .kind = {s}, .nullable = {s}, .cb_arity = @as(?usize, {d}), .tp_idx = @as(?usize, null), .tp_mode = .none }}",
                        .{ kind_str, if (nullable) "true" else "false", cb_arity },
                    );
                } else {
                    try self.out.print(
                        self.allocator,
                        ".{{ .kind = {s}, .nullable = {s}, .cb_arity = @as(?usize, null), .tp_idx = ",
                        .{ kind_str, if (nullable) "true" else "false" },
                    );
                    if (gp.tp_idx) |tpi| {
                        try self.out.print(self.allocator, "@as(?usize, {d})", .{tpi});
                    } else {
                        try self.out.appendSlice(self.allocator, "@as(?usize, null)");
                    }
                    try self.out.print(self.allocator, ", .tp_mode = .{s} }}", .{@tagName(gp.mode)});
                }
                emitted_fp += 1;
            }
            try self.out.appendSlice(self.allocator, " } },\n");
        }
        try self.out.appendSlice(self.allocator, "};\n");

        if (od.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);

        if (recv_opt) |rv| {
            try self.out.print(
                self.allocator,
                "{s}inline fn {s}({s}: {s}, __zigar_ov_args: anytype) __zigar_js.OverloadMethodReturn(@This(), {s}, {s}, if (@typeInfo(@TypeOf(__zigar_ov_args)) == .enum_literal) @TypeOf(.{{__zigar_ov_args}}) else @TypeOf(__zigar_ov_args), false) {{\nreturn __zigar_js.dispatchOverloadMethod(@This(), {s}, {s}, __zigar_ov_args, null);\n}}\n",
                .{ pub_kw, od.zig_ident, rv.ident, rv.self_ty, rv.self_ty, spec_ident, rv.ident, spec_ident },
            );
            if (od.alloc_companion_ident) |alloc_disp_id| {
                try self.out.print(
                    self.allocator,
                    "{s}inline fn {s}({s}: {s}, {s}: @import(\"std\").mem.Allocator, __zigar_ov_args: anytype) __zigar_js.OverloadMethodReturn(@This(), {s}, {s}, if (@typeInfo(@TypeOf(__zigar_ov_args)) == .enum_literal) @TypeOf(.{{__zigar_ov_args}}) else @TypeOf(__zigar_ov_args), true) {{\nreturn __zigar_js.dispatchOverloadMethod(@This(), {s}, {s}, __zigar_ov_args, {s});\n}}\n",
                    .{ pub_kw, alloc_disp_id, rv.ident, rv.self_ty, od.alloc_param_ident, rv.self_ty, spec_ident, rv.ident, spec_ident, od.alloc_param_ident },
                );
            }
        } else {
            try self.out.print(
                self.allocator,
                "{s}inline fn {s}(__zigar_ov_args: anytype) __zigar_js.OverloadReturn(@This(), {s}, if (@typeInfo(@TypeOf(__zigar_ov_args)) == .enum_literal) @TypeOf(.{{__zigar_ov_args}}) else @TypeOf(__zigar_ov_args), false) {{\nreturn __zigar_js.dispatchOverload(@This(), {s}, __zigar_ov_args, null);\n}}\n",
                .{ pub_kw, od.zig_ident, spec_ident, spec_ident },
            );
            if (od.alloc_companion_ident) |alloc_disp_id| {
                try self.out.print(
                    self.allocator,
                    "{s}inline fn {s}({s}: @import(\"std\").mem.Allocator, __zigar_ov_args: anytype) __zigar_js.OverloadReturn(@This(), {s}, if (@typeInfo(@TypeOf(__zigar_ov_args)) == .enum_literal) @TypeOf(.{{__zigar_ov_args}}) else @TypeOf(__zigar_ov_args), true) {{\nreturn __zigar_js.dispatchOverload(@This(), {s}, __zigar_ov_args, {s});\n}}\n",
                    .{ pub_kw, alloc_disp_id, od.alloc_param_ident, spec_ident, spec_ident, od.alloc_param_ident },
                );
            }
        }
    }

    fn emitTypeParamsDocComments(self: *ModuleEmitCtx, tps: []const ir.TypeParamIr) error{OutOfMemory}!void {
        for (tps) |tp| {
            const ct_str: ?[]u8 = if (tp.constraint) |ct|
                if (typeHasInlineNominal(ct)) null else try self.renderTypeToOwnedSlice(ct, null)
            else
                null;
            defer if (ct_str) |s| self.allocator.free(s);

            const def_str: ?[]u8 = if (tp.default_type) |dt|
                if (typeHasInlineNominal(dt)) null else try self.renderTypeToOwnedSlice(dt, null)
            else
                null;
            defer if (def_str) |s| self.allocator.free(s);

            if (try lower_generics.formatTypeParamDocLine(
                self.allocator,
                tp.wire_name,
                tp.is_const,
                tp.variance,
                ct_str,
                def_str,
            )) |doc_line| {
                defer self.allocator.free(doc_line);
                try self.out.print(self.allocator, "/// {s}\n", .{doc_line});
            }
        }
    }

    fn emitTypeParamConstraintChecks(self: *ModuleEmitCtx, tps: []const ir.TypeParamIr) error{OutOfMemory}!void {
        var any = false;
        for (tps) |tp| {
            if (tp.enforce_constraint and tp.constraint != null) {
                any = true;
                break;
            }
        }
        if (!any) return;
        try self.out.appendSlice(self.allocator, "comptime {\n");
        for (tps) |tp| {
            if (tp.enforce_constraint) {
                if (tp.constraint) |ct| {
                    try self.out.print(self.allocator, "__zigar_js.checkTypeConstraint({s}, ", .{tp.zig_ident});
                    try self.emitType(ct);
                    try self.out.appendSlice(self.allocator, ");\n");
                }
            }
        }
        try self.out.appendSlice(self.allocator, "}\n");
    }

    fn emitGenericTypeCompanions(
        self: *ModuleEmitCtx,
        pub_kw: []const u8,
        primary_ident: []const u8,
        default_ident_opt: ?[]const u8,
        with_ident_opt: ?[]const u8,
        tps: []const ir.TypeParamIr,
    ) error{OutOfMemory}!void {
        if (tps.len == 0) return;

        if (default_ident_opt) |def_ident| {
            var has_defs = try self.allocator.alloc(bool, tps.len);
            defer self.allocator.free(has_defs);
            for (tps, 0..) |tp, idx| has_defs[idx] = tp.default_type != null;
            const dp = lower_generics.analyzeDefaultPrefix(has_defs);

            try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, def_ident });
            for (tps[0..dp.required_count], 0..) |tp, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
            }
            try self.out.appendSlice(self.allocator, ") type {\n");
            for (tps[dp.required_count..]) |tp| {
                try self.out.print(self.allocator, "const {s} = ", .{tp.zig_ident});
                if (tp.default_type) |dt| {
                    try self.emitType(dt);
                } else {
                    try self.out.appendSlice(self.allocator, "__zigar_js.Any");
                }
                try self.out.appendSlice(self.allocator, ";\n");
            }
            try self.out.print(self.allocator, "return @This().{s}(", .{primary_ident});
            for (tps, 0..) |tp, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, tp.zig_ident);
            }
            try self.out.appendSlice(self.allocator, ");\n}\n");
        }

        if (with_ident_opt) |with_ident| {
            const ov_ident = "__zigar_tp_overrides";
            try self.out.print(self.allocator, "{s}fn {s}(comptime {s}: anytype) type {{\n@setEvalBranchQuota(200_000);\n", .{
                pub_kw,
                with_ident,
                ov_ident,
            });
            for (tps) |tp| {
                try self.out.print(self.allocator, "const {s} = if (@hasField(@TypeOf({s}), ", .{
                    tp.zig_ident,
                    ov_ident,
                });
                try self.emitStringLit(tp.wire_name);
                if (tp.default_type) |dt| {
                    try self.out.print(self.allocator, ") and @TypeOf(@field({s}, ", .{ov_ident});
                    try self.emitStringLit(tp.wire_name);
                    try self.out.print(self.allocator, ")) != @TypeOf(.from_default)) @field({s}, ", .{ov_ident});
                    try self.emitStringLit(tp.wire_name);
                    try self.out.appendSlice(self.allocator, ") else ");
                    try self.emitType(dt);
                } else {
                    try self.out.print(self.allocator, ")) @field({s}, ", .{ov_ident});
                    try self.emitStringLit(tp.wire_name);
                    try self.out.appendSlice(self.allocator, ") else ");
                    const err_msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Missing required type parameter '.{s}' in {s}",
                        .{ tp.wire_name, with_ident },
                    );
                    defer self.allocator.free(err_msg);
                    try self.out.appendSlice(self.allocator, "@compileError(");
                    try self.emitStringLit(err_msg);
                    try self.out.append(self.allocator, ')');
                }
                try self.out.appendSlice(self.allocator, ";\n");
            }
            try self.out.print(self.allocator, "return @This().{s}(", .{primary_ident});
            for (tps, 0..) |tp, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, tp.zig_ident);
            }
            try self.out.appendSlice(self.allocator, ");\n}\n");
        }
    }

    fn emitGenericSigCompanions(
        self: *ModuleEmitCtx,
        pub_kw: []const u8,
        primary_ident: []const u8,
        alloc_primary_ident_opt: ?[]const u8,
        default_ident_opt: ?[]const u8,
        default_alloc_ident_opt: ?[]const u8,
        infer_ident_opt: ?[]const u8,
        infer_alloc_ident_opt: ?[]const u8,
        sig: ir.SignatureIr,
        recv_opt: ?RecvSpec,
        this_shared: SharedTypeHelper,
        param_shared: []const SharedTypeHelper,
        ret_shared: SharedTypeHelper,
    ) error{OutOfMemory}!void {
        const recv_id_only: ?[]const u8 = if (recv_opt) |rv| rv.ident else null;

        if (default_ident_opt) |def_ident| {
            const dp = sig.default_prefix;
            {
                var substs: std.ArrayList(TypeParamSubst) = .empty;
                defer {
                    for (substs.items) |s| self.allocator.free(s.expr);
                    substs.deinit(self.allocator);
                }

                for (sig.type_params[dp.required_count..]) |tp| {
                    const expr = if (tp.default_type) |dt|
                        try self.renderTypeToOwnedSlice(dt, substs.items)
                    else
                        try self.allocator.dupe(u8, "__zigar_js.Any");
                    errdefer self.allocator.free(expr);
                    try substs.append(self.allocator, .{
                        .zig_ident = tp.zig_ident,
                        .expr = expr,
                    });
                }

                const prev_subst = self.type_param_subst;
                self.type_param_subst = substs.items;
                defer self.type_param_subst = prev_subst;

                try self.emitDefaultSigVariant(
                    pub_kw,
                    def_ident,
                    primary_ident,
                    null,
                    sig,
                    dp.required_count,
                    recv_opt,
                    recv_id_only,
                    substs.items,
                    this_shared,
                    param_shared,
                    ret_shared,
                );

                if (default_alloc_ident_opt) |def_alloc_id| {
                    if (alloc_primary_ident_opt) |alloc_prim_id| {
                        const alloc_param = sig.alloc_param_ident orelse "allocator";
                        try self.emitDefaultSigVariant(
                            pub_kw,
                            def_alloc_id,
                            alloc_prim_id,
                            alloc_param,
                            sig,
                            dp.required_count,
                            recv_opt,
                            recv_id_only,
                            substs.items,
                            this_shared,
                            param_shared,
                            ret_shared,
                        );
                    }
                }
            }
        }

        if (infer_ident_opt) |inf_ident| {
            if (sig.infer_bindings) |bindings| {
                var substs: std.ArrayList(TypeParamSubst) = .empty;
                defer {
                    for (substs.items) |s| self.allocator.free(s.expr);
                    substs.deinit(self.allocator);
                }

                for (sig.type_params, 0..) |tp, tp_idx| {
                    const b = bindings[tp_idx];
                    const expr: []u8 = switch (b.mode) {
                        .from_default => if (tp.default_type) |dt|
                            try self.renderTypeToOwnedSlice(dt, substs.items)
                        else
                            try self.allocator.dupe(u8, "__zigar_js.Any"),
                        .direct => blk: {
                            const p_ident = sig.params[b.param_index].zig_ident;
                            const helper_fn = if (tp.is_const) "InferConstJsType" else "InferJsType";
                            const base_expr = try std.fmt.allocPrint(
                                self.allocator,
                                "__zigar_js.{s}(@TypeOf({s}))",
                                .{ helper_fn, p_ident },
                            );
                            if (tp.constraint) |ct| {
                                if (!typeUsesAnyTypeParam(ct, sig.type_params[tp_idx..]) and !typeHasInlineNominal(ct)) {
                                    defer self.allocator.free(base_expr);
                                    const ct_rendered = try self.renderTypeToOwnedSlice(ct, substs.items);
                                    defer self.allocator.free(ct_rendered);
                                    break :blk try std.fmt.allocPrint(
                                        self.allocator,
                                        "(if (@typeInfo(@TypeOf({s})) == .enum_literal) ({s}) else {s})",
                                        .{ p_ident, ct_rendered, base_expr },
                                    );
                                }
                            }
                            break :blk base_expr;
                        },
                        .slice_elem => try std.fmt.allocPrint(
                            self.allocator,
                            "__zigar_js.InferSliceElem(@TypeOf({s}))",
                            .{sig.params[b.param_index].zig_ident},
                        ),
                        .promise_payload => try std.fmt.allocPrint(
                            self.allocator,
                            "__zigar_js.Awaited(@TypeOf({s}))",
                            .{sig.params[b.param_index].zig_ident},
                        ),
                        .optional_child => blk: {
                            const p_ident = sig.params[b.param_index].zig_ident;
                            if (tp.default_type) |dt| {
                                if (!typeUsesAnyTypeParam(dt, sig.type_params[tp_idx..]) and !typeHasInlineNominal(dt)) {
                                    const dt_rendered = try self.renderTypeToOwnedSlice(dt, substs.items);
                                    defer self.allocator.free(dt_rendered);
                                    break :blk try std.fmt.allocPrint(
                                        self.allocator,
                                        "(if (@TypeOf({s}) == @TypeOf(null)) ({s}) else __zigar_js.InferOptionalChild(@TypeOf({s})))",
                                        .{ p_ident, dt_rendered, p_ident },
                                    );
                                }
                            }
                            break :blk try std.fmt.allocPrint(
                                self.allocator,
                                "__zigar_js.InferOptionalChild(@TypeOf({s}))",
                                .{p_ident},
                            );
                        },
                    };
                    errdefer self.allocator.free(expr);
                    try substs.append(self.allocator, .{
                        .zig_ident = tp.zig_ident,
                        .expr = expr,
                    });
                }

                const prev_subst = self.type_param_subst;
                self.type_param_subst = substs.items;
                defer self.type_param_subst = prev_subst;

                try self.emitInferSigVariant(
                    pub_kw,
                    inf_ident,
                    primary_ident,
                    null,
                    sig,
                    recv_opt,
                    recv_id_only,
                    substs.items,
                    this_shared,
                    param_shared,
                    ret_shared,
                );

                if (infer_alloc_ident_opt) |inf_alloc_id| {
                    if (alloc_primary_ident_opt) |alloc_prim_id| {
                        const alloc_param = sig.alloc_param_ident orelse "allocator";
                        try self.emitInferSigVariant(
                            pub_kw,
                            inf_alloc_id,
                            alloc_prim_id,
                            alloc_param,
                            sig,
                            recv_opt,
                            recv_id_only,
                            substs.items,
                            this_shared,
                            param_shared,
                            ret_shared,
                        );
                    }
                }
            }
        }
    }

    fn emitDefaultSigVariant(
        self: *ModuleEmitCtx,
        pub_kw: []const u8,
        fn_ident: []const u8,
        target_ident: []const u8,
        alloc_param_opt: ?[]const u8,
        sig: ir.SignatureIr,
        req_tp_len: usize,
        recv_opt: ?RecvSpec,
        recv_id_only: ?[]const u8,
        substs: []const TypeParamSubst,
        this_shared: SharedTypeHelper,
        param_shared: []const SharedTypeHelper,
        ret_shared: SharedTypeHelper,
    ) error{OutOfMemory}!void {
        try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, fn_ident });
        var pcount: usize = 0;
        if (recv_opt) |rv| {
            try self.out.print(self.allocator, "{s}: {s}", .{ rv.ident, rv.self_ty });
            pcount += 1;
        }
        for (sig.type_params[0..req_tp_len]) |tp| {
            if (pcount > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
            pcount += 1;
        }
        if (alloc_param_opt) |ap| {
            if (pcount > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s}: @import(\"std\").mem.Allocator", .{ap});
            pcount += 1;
        }
        if (sig.this_param) |thp| {
            if (pcount > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s}: ", .{thp.zig_ident});
            try self.emitResolvedSharedType(thp.ty, sig, this_shared);
            pcount += 1;
        }
        for (sig.params, 0..) |p, pi| {
            if (pcount > 0) try self.out.appendSlice(self.allocator, ", ");
            if (p.callback_sig != null or p.is_rest) {
                try self.out.print(self.allocator, "{s}: anytype", .{p.zig_ident});
            } else {
                try self.out.print(self.allocator, "{s}: ", .{p.zig_ident});
                try self.emitResolvedSharedType(p.ty, sig, param_shared[pi]);
            }
            pcount += 1;
        }
        try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
        try self.emitResolvedSharedType(sig.return_type, sig, ret_shared);
        try self.out.print(self.allocator, " {{\nreturn @This().{s}(", .{target_ident});

        var cidx: usize = 0;
        if (recv_id_only) |rid| {
            try self.out.appendSlice(self.allocator, rid);
            cidx += 1;
        }
        for (sig.type_params[0..req_tp_len]) |tp| {
            if (cidx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, tp.zig_ident);
            cidx += 1;
        }
        for (substs) |s| {
            if (cidx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, s.expr);
            cidx += 1;
        }
        if (alloc_param_opt) |ap| {
            if (cidx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, ap);
            cidx += 1;
        }
        if (sig.this_param) |thp| {
            if (cidx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, thp.zig_ident);
            cidx += 1;
        }
        for (sig.params) |p| {
            if (cidx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, p.zig_ident);
            cidx += 1;
        }
        try self.out.appendSlice(self.allocator, ");\n}\n");
    }

    fn emitInferSigVariant(
        self: *ModuleEmitCtx,
        pub_kw: []const u8,
        fn_ident: []const u8,
        target_ident: []const u8,
        alloc_param_opt: ?[]const u8,
        sig: ir.SignatureIr,
        recv_opt: ?RecvSpec,
        recv_id_only: ?[]const u8,
        substs: []const TypeParamSubst,
        this_shared: SharedTypeHelper,
        param_shared: []const SharedTypeHelper,
        ret_shared: SharedTypeHelper,
    ) error{OutOfMemory}!void {
        try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, fn_ident });
        var pcount: usize = 0;
        if (recv_opt) |rv| {
            try self.out.print(self.allocator, "{s}: {s}", .{ rv.ident, rv.self_ty });
            pcount += 1;
        }
        if (alloc_param_opt) |ap| {
            if (pcount > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s}: @import(\"std\").mem.Allocator", .{ap});
            pcount += 1;
        }
        if (sig.this_param) |thp| {
            if (pcount > 0) try self.out.appendSlice(self.allocator, ", ");
            if (typeUsesAnyTypeParam(thp.ty, sig.type_params)) {
                try self.out.print(self.allocator, "{s}: anytype", .{thp.zig_ident});
            } else {
                try self.out.print(self.allocator, "{s}: ", .{thp.zig_ident});
                try self.emitResolvedSharedType(thp.ty, sig, this_shared);
            }
            pcount += 1;
        }
        for (sig.params, 0..) |p, pi| {
            if (pcount > 0) try self.out.appendSlice(self.allocator, ", ");
            if (p.callback_sig != null or p.is_rest or typeUsesAnyTypeParam(p.ty, sig.type_params)) {
                try self.out.print(self.allocator, "{s}: anytype", .{p.zig_ident});
            } else {
                try self.out.print(self.allocator, "{s}: ", .{p.zig_ident});
                try self.emitResolvedSharedType(p.ty, sig, param_shared[pi]);
            }
            pcount += 1;
        }
        try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
        try self.emitResolvedSharedType(sig.return_type, sig, ret_shared);
        try self.out.print(self.allocator, " {{\nreturn @This().{s}(", .{target_ident});

        var cidx: usize = 0;
        if (recv_id_only) |rid| {
            try self.out.appendSlice(self.allocator, rid);
            cidx += 1;
        }
        for (substs) |s| {
            if (cidx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, s.expr);
            cidx += 1;
        }
        if (alloc_param_opt) |ap| {
            if (cidx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, ap);
            cidx += 1;
        }
        if (sig.this_param) |thp| {
            if (cidx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, thp.zig_ident);
            cidx += 1;
        }
        for (sig.params) |p| {
            if (cidx > 0) try self.out.appendSlice(self.allocator, ", ");
            var is_const_tp_direct = false;
            if (p.ty.* == .type_param_ref) {
                for (sig.type_params) |tp| {
                    if (tp.is_const and std.mem.eql(u8, tp.zig_ident, p.ty.type_param_ref)) {
                        is_const_tp_direct = true;
                        break;
                    }
                }
            }
            if (is_const_tp_direct) {
                try self.out.print(
                    self.allocator,
                    "if (comptime __zigar_js.isConstArrayPtr(@TypeOf({s}))) {s}.* else {s}",
                    .{ p.zig_ident, p.zig_ident, p.zig_ident },
                );
            } else {
                try self.out.appendSlice(self.allocator, p.zig_ident);
            }
            cidx += 1;
        }
        try self.out.appendSlice(self.allocator, ");\n}\n");
    }

    fn emitPackedArgsPrologue(
        self: *ModuleEmitCtx,
        sig: ir.SignatureIr,
        is_slice_companion: bool,
    ) !void {
        try self.emitTypeParamConstraintChecks(sig.type_params);
        for (sig.type_params) |tp| {
            if (!emittedSigUsesTypeParam(sig, tp.zig_ident) and !typeParamsCheckUsesIdent(sig.type_params, tp.zig_ident)) {
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
        for (sig.params[0..fixed_len], 0..) |p, pi| {
            if (p.callback_sig) |cbs| {
                try self.out.print(
                    self.allocator,
                    "var __zigar_cb_{d} = __zigar_js.ScopedCallback({s}, @TypeOf({s})){{}};\ndefer __zigar_cb_{d}.deinit();\n",
                    .{ pi, if (cbs.this_param != null) "true" else "false", p.zig_ident, pi },
                );
            }
        }
        if (first_trailing_opt < fixed_len) {
            try self.out.print(self.allocator, "var __zigar_argc: usize = {d};\n", .{fixed_len});
            if (has_rest) {
                if (is_slice_companion) {
                    try self.out.print(self.allocator, "if ({s}.len == 0) {{\n", .{sig.params[fixed_len].zig_ident});
                } else {
                    try self.out.appendSlice(self.allocator, "if (__zigar_js.variadicIsEmpty(__zigar_js.SliceElem(");
                    try self.emitType(sig.params[fixed_len].ty);
                    try self.out.print(self.allocator, "), {s})) {{\n", .{sig.params[fixed_len].zig_ident});
                }
            }
            var rev: usize = fixed_len;
            while (rev > first_trailing_opt) {
                rev -= 1;
                if (sig.params[rev].callback_sig != null) {
                    try self.out.print(
                        self.allocator,
                        "if (__zigar_argc == {d} and __zigar_js.isNullArg({s})) __zigar_argc = {d};\n",
                        .{ rev + 1, sig.params[rev].zig_ident, rev },
                    );
                } else {
                    try self.out.print(
                        self.allocator,
                        "if (__zigar_argc == {d} and {s} == null) __zigar_argc = {d};\n",
                        .{ rev + 1, sig.params[rev].zig_ident, rev },
                    );
                }
            }
            if (has_rest) {
                try self.out.appendSlice(self.allocator, "}\n");
            }
        }
        for (sig.params[0..fixed_len], 0..) |p, pi| {
            if (pi >= first_trailing_opt) {
                try self.out.print(self.allocator, "if (__zigar_argc > {d}) ", .{pi});
            }
            if (p.callback_sig != null) {
                try self.out.print(
                    self.allocator,
                    "try __zigar_cb_{d}.push(__zigar_args, {s}, ",
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
            if (is_slice_companion) {
                try self.out.print(
                    self.allocator,
                    "try __zigar_js.pushRestArgs(__zigar_args, {s}, ",
                    .{rest_param.zig_ident},
                );
            } else {
                try self.out.appendSlice(self.allocator, "try __zigar_js.pushVariadicArgs(__zigar_js.SliceElem(");
                try self.emitType(rest_param.ty);
                try self.out.print(
                    self.allocator,
                    "), __zigar_args, {s}, ",
                    .{rest_param.zig_ident},
                );
            }
            try self.emitSliceElemNullishSpec(rest_param.ty);
            try self.out.appendSlice(self.allocator, ");\n");
        }
    }

    fn emitCallableFunctionBody(
        self: *ModuleEmitCtx,
        d: ir.DeclIr,
        sig: ir.SignatureIr,
        is_slice_companion: bool,
        alloc_ident_opt: ?[]const u8,
        ret_type_expr_opt: ?[]const u8,
        is_default_call: bool,
    ) !void {
        try self.emitPackedArgsPrologue(sig, is_slice_companion);

        if (sig.this_param) |thp| {
            if (alloc_ident_opt) |alloc_param| {
                try self.out.appendSlice(self.allocator, "return __zigar_js.invokeTargetWithThisAlloc(");
                if (ret_type_expr_opt) |rtexpr| {
                    try self.out.appendSlice(self.allocator, rtexpr);
                } else {
                    try self.emitType(sig.return_type);
                }
                try self.out.print(self.allocator, ", {s}, ", .{alloc_param});
                try self.emitCallTargetLiteral(d.is_global_scope, d.wire_name, is_default_call, null);
                try self.out.print(self.allocator, ", {s}, ", .{thp.zig_ident});
                try self.emitNullishSpec(thp.ty, false);
                try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
            } else {
                try self.out.appendSlice(self.allocator, "return __zigar_js.invokeTargetWithThis(");
                if (ret_type_expr_opt) |rtexpr| {
                    try self.out.appendSlice(self.allocator, rtexpr);
                } else {
                    try self.emitType(sig.return_type);
                }
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitCallTargetLiteral(d.is_global_scope, d.wire_name, is_default_call, null);
                try self.out.print(self.allocator, ", {s}, ", .{thp.zig_ident});
                try self.emitNullishSpec(thp.ty, false);
                try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
            }
            return;
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
            (d.is_default_export or self.isExportEqualsRootDecl(d) or std.mem.eql(u8, d.wire_name, "default"));

        var param_shared = try self.allocator.alloc(SharedTypeHelper, sig.params.len);
        @memset(param_shared, .{});
        defer {
            for (param_shared) |psh| psh.deinit(self.allocator);
            self.allocator.free(param_shared);
        }

        var param_type_exprs = try self.allocator.alloc(?[]u8, sig.params.len);
        @memset(param_type_exprs, null);
        defer self.allocator.free(param_type_exprs);

        var this_shared: SharedTypeHelper = .{};
        defer this_shared.deinit(self.allocator);

        const has_any_companion = d.alloc_companion_ident != null or
            d.slice_companion_ident != null or
            d.narrow_companion_ident != null or
            d.default_companion_ident != null or
            d.infer_companion_ident != null;

        if (has_any_companion) {
            if (sig.this_param) |thp| {
                if (typeHasInlineNominal(thp.ty)) {
                    this_shared = try self.emitSharedNominalTypeHelper(thp.ty, sig);
                }
            }
            for (sig.params, 0..) |p, pi| {
                if (p.callback_sig != null) continue;
                if (typeHasInlineNominal(p.ty)) {
                    param_shared[pi] = try self.emitSharedNominalTypeHelper(p.ty, sig);
                    param_type_exprs[pi] = param_shared[pi].call_expr;
                }
            }
        }
        const this_type_expr_opt: ?[]u8 = this_shared.call_expr;

        var ret_shared: SharedTypeHelper = .{};
        defer ret_shared.deinit(self.allocator);

        if (typeHasInlineNominal(sig.return_type)) {
            ret_shared = try self.emitSharedNominalTypeHelper(sig.return_type, sig);
        }
        const ret_type_expr_opt: ?[]u8 = ret_shared.call_expr;

        if (d.jsdoc) |jd| {
            try appendJsDocComments(&self.out, self.allocator, jd);
        }
        try self.emitTypeParamsDocComments(sig.type_params);

        try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
        try self.emitSigHeaderParams(sig, null, null, this_type_expr_opt, param_type_exprs, false);
        try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
        if (ret_type_expr_opt) |rtexpr| {
            try self.out.appendSlice(self.allocator, rtexpr);
        } else {
            try self.emitType(sig.return_type);
        }
        try self.out.appendSlice(self.allocator, " {\n");

        if (d.alloc_companion_ident) |alloc_fn_ident| {
            try self.out.print(self.allocator, "return @This().{s}(", .{alloc_fn_ident});
            try self.emitSigForwardArgs(sig, null, "try __zigar_js.defaultAllocator()");
            try self.out.appendSlice(self.allocator, ");\n}\n");

            const alloc_param = sig.alloc_param_ident orelse "allocator";
            try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, alloc_fn_ident });
            try self.emitSigHeaderParams(sig, null, alloc_param, this_type_expr_opt, param_type_exprs, false);
            try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
            if (ret_type_expr_opt) |rtexpr| {
                try self.out.appendSlice(self.allocator, rtexpr);
            } else {
                try self.emitType(sig.return_type);
            }
            try self.out.appendSlice(self.allocator, " {\n");
            try self.emitCallableFunctionBody(d, sig, false, alloc_param, ret_type_expr_opt, is_default_call);
            try self.out.appendSlice(self.allocator, "}\n");
        } else {
            try self.emitCallableFunctionBody(d, sig, false, null, ret_type_expr_opt, is_default_call);
            try self.out.appendSlice(self.allocator, "}\n");
        }

        if (d.slice_companion_ident) |slice_fn_ident| {
            try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, slice_fn_ident });
            try self.emitSigHeaderParams(sig, null, null, this_type_expr_opt, param_type_exprs, true);
            try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
            if (ret_type_expr_opt) |rtexpr| {
                try self.out.appendSlice(self.allocator, rtexpr);
            } else {
                try self.emitType(sig.return_type);
            }
            try self.out.appendSlice(self.allocator, " {\n");

            if (d.slice_alloc_companion_ident) |slice_alloc_ident| {
                try self.out.print(self.allocator, "return @This().{s}(", .{slice_alloc_ident});
                try self.emitSigForwardArgs(sig, null, "try __zigar_js.defaultAllocator()");
                try self.out.appendSlice(self.allocator, ");\n}\n");

                const alloc_param = sig.alloc_param_ident orelse "allocator";
                try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, slice_alloc_ident });
                try self.emitSigHeaderParams(sig, null, alloc_param, this_type_expr_opt, param_type_exprs, true);
                try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
                if (ret_type_expr_opt) |rtexpr| {
                    try self.out.appendSlice(self.allocator, rtexpr);
                } else {
                    try self.emitType(sig.return_type);
                }
                try self.out.appendSlice(self.allocator, " {\n");
                try self.emitCallableFunctionBody(d, sig, true, alloc_param, ret_type_expr_opt, is_default_call);
                try self.out.appendSlice(self.allocator, "}\n");
            } else {
                try self.emitCallableFunctionBody(d, sig, true, null, ret_type_expr_opt, is_default_call);
                try self.out.appendSlice(self.allocator, "}\n");
            }
        }

        if (d.narrow_companion_ident) |narrow_fn_ident| {
            try self.emitNarrowCompanions(
                pub_kw,
                d.zig_ident,
                narrow_fn_ident,
                d.narrow_alloc_companion_ident,
                sig,
                null,
                this_type_expr_opt,
                param_type_exprs,
            );
        }

        try self.emitGenericSigCompanions(
            pub_kw,
            d.zig_ident,
            d.alloc_companion_ident,
            d.default_companion_ident,
            d.default_alloc_companion_ident,
            d.infer_companion_ident,
            d.infer_alloc_companion_ident,
            sig,
            null,
            this_shared,
            param_shared,
            ret_shared,
        );
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
        try self.emitNullishSpecEnvMode(f.ty, null, null, null, if (f.is_optional) .preserve_null else .none, 0);
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

    fn emitStructConstructor(
        self: *ModuleEmitCtx,
        wire_name: []const u8,
        is_global_scope: bool,
        is_default_export: bool,
        ctor: ir.ConstructorIr,
    ) error{OutOfMemory}!void {
        const sig = ctor.signature;
        var param_type_exprs = try self.allocator.alloc(?[]u8, sig.params.len);
        @memset(param_type_exprs, null);
        defer {
            for (param_type_exprs) |pte_opt| {
                if (pte_opt) |buf| self.allocator.free(buf);
            }
            self.allocator.free(param_type_exprs);
        }

        if (ctor.slice_companion_ident != null) {
            for (sig.params, 0..) |p, pi| {
                if (p.callback_sig != null) continue;
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

        if (ctor.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
        try self.emitTypeParamsDocComments(sig.type_params);

        try self.out.print(self.allocator, "pub fn {s}(", .{ctor.zig_ident});
        try self.emitSigHeaderParams(sig, null, null, null, param_type_exprs, false);
        try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
        if (ret_type_expr_opt) |rtexpr| {
            try self.out.appendSlice(self.allocator, rtexpr);
        } else {
            try self.emitType(sig.return_type);
        }
        try self.out.appendSlice(self.allocator, " {\n");
        try self.emitPackedArgsPrologue(sig, false);
        try self.out.appendSlice(self.allocator, "return __zigar_js.constructTarget(");
        if (ret_type_expr_opt) |rtexpr| {
            try self.out.appendSlice(self.allocator, rtexpr);
        } else {
            try self.emitType(sig.return_type);
        }
        try self.out.appendSlice(self.allocator, ", ");
        try self.emitCallTargetLiteral(is_global_scope, wire_name, is_default_export, null);
        try self.out.appendSlice(self.allocator, ", __zigar_args);\n}\n");

        if (ctor.slice_companion_ident) |slice_ident| {
            try self.out.print(self.allocator, "pub fn {s}(", .{slice_ident});
            try self.emitSigHeaderParams(sig, null, null, null, param_type_exprs, true);
            try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
            if (ret_type_expr_opt) |rtexpr| {
                try self.out.appendSlice(self.allocator, rtexpr);
            } else {
                try self.emitType(sig.return_type);
            }
            try self.out.appendSlice(self.allocator, " {\n");
            try self.emitPackedArgsPrologue(sig, true);
            try self.out.appendSlice(self.allocator, "return __zigar_js.constructTarget(");
            if (ret_type_expr_opt) |rtexpr| {
                try self.out.appendSlice(self.allocator, rtexpr);
            } else {
                try self.emitType(sig.return_type);
            }
            try self.out.appendSlice(self.allocator, ", ");
            try self.emitCallTargetLiteral(is_global_scope, wire_name, is_default_export, null);
            try self.out.appendSlice(self.allocator, ", __zigar_args);\n}\n");
        }
    }

    fn emitStructMethodCallTail(
        self: *ModuleEmitCtx,
        wire_name: []const u8,
        is_global_scope: bool,
        push_owner_seg: bool,
        st: ir.StructDeclIr,
        m: ir.MethodIr,
        is_slice_companion: bool,
        recv_ident: []const u8,
        alloc_ident_opt: ?[]const u8,
        ret_type_expr_opt: ?[]const u8,
    ) error{OutOfMemory}!void {
        const sig = m.signature;
        try self.emitPackedArgsPrologue(sig, is_slice_companion);

        if (m.is_static) {
            if (sig.this_param) |thp| {
                if (alloc_ident_opt) |alloc_param| {
                    try self.out.appendSlice(self.allocator, "return __zigar_js.invokeTargetWithThisAlloc(");
                    if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                    try self.out.print(self.allocator, ", {s}, ", .{alloc_param});
                    try self.emitCallTargetLiteral(is_global_scope, m.wire_name, false, if (push_owner_seg) wire_name else null);
                    try self.out.print(self.allocator, ", {s}, ", .{thp.zig_ident});
                    try self.emitNullishSpec(thp.ty, false);
                    try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
                } else {
                    try self.out.appendSlice(self.allocator, "return __zigar_js.invokeTargetWithThis(");
                    if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitCallTargetLiteral(is_global_scope, m.wire_name, false, if (push_owner_seg) wire_name else null);
                    try self.out.print(self.allocator, ", {s}, ", .{thp.zig_ident});
                    try self.emitNullishSpec(thp.ty, false);
                    try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
                }
                return;
            }
            if (alloc_ident_opt) |alloc_param| {
                try self.out.appendSlice(self.allocator, "return __zigar_js.invokeTargetAlloc(");
                if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                try self.out.print(self.allocator, ", {s}, ", .{alloc_param});
                try self.emitCallTargetLiteral(is_global_scope, m.wire_name, false, if (push_owner_seg) wire_name else null);
                try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
            } else {
                try self.out.appendSlice(self.allocator, "return __zigar_js.invokeTarget(");
                if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitCallTargetLiteral(is_global_scope, m.wire_name, false, if (push_owner_seg) wire_name else null);
                try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
            }
            return;
        }

        switch (m.call_kind) {
            .method => {
                if (alloc_ident_opt) |alloc_param| {
                    try self.out.appendSlice(self.allocator, "return __zigar_js.invokeMethodAlloc(");
                    if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                    try self.out.print(self.allocator, ", {s}, {s}.{s}, ", .{ alloc_param, recv_ident, st.ref_field_ident });
                    try self.emitStringLit(m.wire_name);
                    try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
                } else {
                    try self.out.appendSlice(self.allocator, "return __zigar_js.invokeMethod(");
                    if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                    try self.out.print(self.allocator, ", {s}.{s}, ", .{ recv_ident, st.ref_field_ident });
                    try self.emitStringLit(m.wire_name);
                    try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
                }
            },
            .call_sig => {
                if (sig.this_param) |thp| {
                    if (alloc_ident_opt) |alloc_param| {
                        try self.out.appendSlice(self.allocator, "return __zigar_js.invokeCallableWithThisAlloc(");
                        if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                        try self.out.print(self.allocator, ", {s}, {s}.{s}, {s}, ", .{ alloc_param, recv_ident, st.ref_field_ident, thp.zig_ident });
                        try self.emitNullishSpec(thp.ty, false);
                        try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
                    } else {
                        try self.out.appendSlice(self.allocator, "return __zigar_js.invokeCallableWithThis(");
                        if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                        try self.out.print(self.allocator, ", {s}.{s}, {s}, ", .{ recv_ident, st.ref_field_ident, thp.zig_ident });
                        try self.emitNullishSpec(thp.ty, false);
                        try self.out.appendSlice(self.allocator, ", __zigar_args);\n");
                    }
                } else {
                    if (alloc_ident_opt) |alloc_param| {
                        try self.out.appendSlice(self.allocator, "return __zigar_js.invokeCallableAlloc(");
                        if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                        try self.out.print(self.allocator, ", {s}, {s}.{s}, __zigar_args);\n", .{ alloc_param, recv_ident, st.ref_field_ident });
                    } else {
                        try self.out.appendSlice(self.allocator, "return __zigar_js.invokeCallable(");
                        if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                        try self.out.print(self.allocator, ", {s}.{s}, __zigar_args);\n", .{ recv_ident, st.ref_field_ident });
                    }
                }
            },
            .construct_sig => {
                if (alloc_ident_opt) |alloc_param| {
                    try self.out.appendSlice(self.allocator, "return __zigar_js.constructCallableAlloc(");
                    if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                    try self.out.print(self.allocator, ", {s}, {s}.{s}, __zigar_args);\n", .{ alloc_param, recv_ident, st.ref_field_ident });
                } else {
                    try self.out.appendSlice(self.allocator, "return __zigar_js.constructCallable(");
                    if (ret_type_expr_opt) |rtexpr| try self.out.appendSlice(self.allocator, rtexpr) else try self.emitType(sig.return_type);
                    try self.out.print(self.allocator, ", {s}.{s}, __zigar_args);\n", .{ recv_ident, st.ref_field_ident });
                }
            },
        }
    }

    fn emitStructMethod(
        self: *ModuleEmitCtx,
        wire_name: []const u8,
        is_global_scope: bool,
        push_owner_seg: bool,
        st: ir.StructDeclIr,
        m: ir.MethodIr,
    ) error{OutOfMemory}!void {
        const sig = m.signature;
        const recv_ident = sig.self_param_ident orelse "self";
        const recv_opt: ?RecvSpec = if (m.is_static)
            null
        else
            .{ .ident = recv_ident, .self_ty = st.self_ident };
        const recv_id_only: ?[]const u8 = if (m.is_static) null else recv_ident;

        var param_shared = try self.allocator.alloc(SharedTypeHelper, sig.params.len);
        @memset(param_shared, .{});
        defer {
            for (param_shared) |psh| psh.deinit(self.allocator);
            self.allocator.free(param_shared);
        }

        var param_type_exprs = try self.allocator.alloc(?[]u8, sig.params.len);
        @memset(param_type_exprs, null);
        defer self.allocator.free(param_type_exprs);

        var this_shared: SharedTypeHelper = .{};
        defer this_shared.deinit(self.allocator);

        const has_any_companion = m.alloc_companion_ident != null or
            m.slice_companion_ident != null or
            m.narrow_companion_ident != null or
            m.default_companion_ident != null or
            m.infer_companion_ident != null;

        if (has_any_companion) {
            if (sig.this_param) |thp| {
                if (typeHasInlineNominal(thp.ty)) {
                    this_shared = try self.emitSharedNominalTypeHelper(thp.ty, sig);
                }
            }
            for (sig.params, 0..) |p, pi| {
                if (p.callback_sig != null) continue;
                if (typeHasInlineNominal(p.ty)) {
                    param_shared[pi] = try self.emitSharedNominalTypeHelper(p.ty, sig);
                    param_type_exprs[pi] = param_shared[pi].call_expr;
                }
            }
        }
        const this_type_expr_opt: ?[]u8 = this_shared.call_expr;

        var ret_shared: SharedTypeHelper = .{};
        defer ret_shared.deinit(self.allocator);
        if (typeHasInlineNominal(sig.return_type)) {
            ret_shared = try self.emitSharedNominalTypeHelper(sig.return_type, sig);
        }
        const ret_type_expr_opt: ?[]u8 = ret_shared.call_expr;

        if (m.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
        try self.emitTypeParamsDocComments(sig.type_params);

        try self.out.print(self.allocator, "pub fn {s}(", .{m.zig_ident});
        try self.emitSigHeaderParams(sig, recv_opt, null, this_type_expr_opt, param_type_exprs, false);
        try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
        if (ret_type_expr_opt) |rtexpr| {
            try self.out.appendSlice(self.allocator, rtexpr);
        } else {
            try self.emitType(sig.return_type);
        }
        try self.out.appendSlice(self.allocator, " {\n");

        if (m.alloc_companion_ident) |alloc_fn_ident| {
            try self.out.print(self.allocator, "return @This().{s}(", .{alloc_fn_ident});
            try self.emitSigForwardArgs(sig, recv_id_only, "try __zigar_js.defaultAllocator()");
            try self.out.appendSlice(self.allocator, ");\n}\n");

            const alloc_param = sig.alloc_param_ident orelse "allocator";
            try self.out.print(self.allocator, "pub fn {s}(", .{alloc_fn_ident});
            try self.emitSigHeaderParams(sig, recv_opt, alloc_param, this_type_expr_opt, param_type_exprs, false);
            try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
            if (ret_type_expr_opt) |rtexpr| {
                try self.out.appendSlice(self.allocator, rtexpr);
            } else {
                try self.emitType(sig.return_type);
            }
            try self.out.appendSlice(self.allocator, " {\n");
            try self.emitStructMethodCallTail(
                wire_name,
                is_global_scope,
                push_owner_seg,
                st,
                m,
                false,
                recv_ident,
                alloc_param,
                ret_type_expr_opt,
            );
            try self.out.appendSlice(self.allocator, "}\n");
        } else {
            try self.emitStructMethodCallTail(
                wire_name,
                is_global_scope,
                push_owner_seg,
                st,
                m,
                false,
                recv_ident,
                null,
                ret_type_expr_opt,
            );
            try self.out.appendSlice(self.allocator, "}\n");
        }

        if (m.slice_companion_ident) |slice_fn_ident| {
            try self.out.print(self.allocator, "pub fn {s}(", .{slice_fn_ident});
            try self.emitSigHeaderParams(sig, recv_opt, null, this_type_expr_opt, param_type_exprs, true);
            try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
            if (ret_type_expr_opt) |rtexpr| {
                try self.out.appendSlice(self.allocator, rtexpr);
            } else {
                try self.emitType(sig.return_type);
            }
            try self.out.appendSlice(self.allocator, " {\n");

            if (m.slice_alloc_companion_ident) |slice_alloc_ident| {
                try self.out.print(self.allocator, "return @This().{s}(", .{slice_alloc_ident});
                try self.emitSigForwardArgs(sig, recv_id_only, "try __zigar_js.defaultAllocator()");
                try self.out.appendSlice(self.allocator, ");\n}\n");

                const alloc_param = sig.alloc_param_ident orelse "allocator";
                try self.out.print(self.allocator, "pub fn {s}(", .{slice_alloc_ident});
                try self.emitSigHeaderParams(sig, recv_opt, alloc_param, this_type_expr_opt, param_type_exprs, true);
                try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
                if (ret_type_expr_opt) |rtexpr| {
                    try self.out.appendSlice(self.allocator, rtexpr);
                } else {
                    try self.emitType(sig.return_type);
                }
                try self.out.appendSlice(self.allocator, " {\n");
                try self.emitStructMethodCallTail(
                    wire_name,
                    is_global_scope,
                    push_owner_seg,
                    st,
                    m,
                    true,
                    recv_ident,
                    alloc_param,
                    ret_type_expr_opt,
                );
                try self.out.appendSlice(self.allocator, "}\n");
            } else {
                try self.emitStructMethodCallTail(
                    wire_name,
                    is_global_scope,
                    push_owner_seg,
                    st,
                    m,
                    true,
                    recv_ident,
                    null,
                    ret_type_expr_opt,
                );
                try self.out.appendSlice(self.allocator, "}\n");
            }
        }

        if (m.narrow_companion_ident) |narrow_fn_ident| {
            try self.emitNarrowCompanions(
                "pub ",
                m.zig_ident,
                narrow_fn_ident,
                m.narrow_alloc_companion_ident,
                sig,
                recv_opt,
                this_type_expr_opt,
                param_type_exprs,
            );
        }

        try self.emitGenericSigCompanions(
            "pub ",
            m.zig_ident,
            m.alloc_companion_ident,
            m.default_companion_ident,
            m.default_alloc_companion_ident,
            m.infer_companion_ident,
            m.infer_alloc_companion_ident,
            sig,
            recv_opt,
            this_shared,
            param_shared,
            ret_shared,
        );
    }

    fn emitStructInstanceProp(
        self: *ModuleEmitCtx,
        st: ir.StructDeclIr,
        ip: ir.InstancePropIr,
    ) error{OutOfMemory}!void {
        var shared_get_ty_expr_opt: ?[]u8 = null;
        defer if (shared_get_ty_expr_opt) |buf| self.allocator.free(buf);
        if (ip.getter_ty) |get_ty| {
            if (typeHasInlineNominal(get_ty)) {
                const synth_setter_param = [_]ir.ParamIr{.{
                    .zig_ident = ip.setter_param_ident,
                    .logical_name = ip.setter_param_ident,
                    .wire_name = ip.setter_param_ident,
                    .ty = get_ty,
                    .is_optional = false,
                    .is_rest = false,
                }};
                shared_get_ty_expr_opt = try self.emitSharedNominalTypeExpr(get_ty, .{
                    .type_params = &.{},
                    .self_param_ident = st.self_param_ident,
                    .alloc_param_ident = ip.getter_alloc_param_ident,
                    .params = &synth_setter_param,
                    .return_type = get_ty,
                    .has_type_predicate = false,
                    .type_predicate_asserts = false,
                    .jsdoc = null,
                });
            }
        }

        if (ip.getter_ident) |getter_id| {
            const get_ty = ip.getter_ty.?;
            if (ip.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);

            try self.out.print(
                self.allocator,
                "pub fn {s}({s}: {s}) __zigar_js.CallError!",
                .{ getter_id, st.self_param_ident, st.self_ident },
            );
            if (shared_get_ty_expr_opt) |rtexpr| {
                try self.out.appendSlice(self.allocator, rtexpr);
            } else {
                try self.emitType(get_ty);
            }
            try self.out.appendSlice(self.allocator, " {\n");

            if (ip.getter_alloc_ident) |alloc_id| {
                try self.out.print(
                    self.allocator,
                    "return @This().{s}({s}, try __zigar_js.defaultAllocator());\n}}\n",
                    .{ alloc_id, st.self_param_ident },
                );
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: {s}, {s}: @import(\"std\").mem.Allocator) __zigar_js.CallError!",
                    .{ alloc_id, st.self_param_ident, st.self_ident, ip.getter_alloc_param_ident },
                );
                if (shared_get_ty_expr_opt) |rtexpr| {
                    try self.out.appendSlice(self.allocator, rtexpr);
                } else {
                    try self.emitType(get_ty);
                }
                try self.out.appendSlice(self.allocator, " {\nreturn __zigar_js.getInstancePropAlloc(");
                if (shared_get_ty_expr_opt) |rtexpr| {
                    try self.out.appendSlice(self.allocator, rtexpr);
                } else {
                    try self.emitType(get_ty);
                }
                try self.out.print(
                    self.allocator,
                    ", {s}, {s}.{s}, ",
                    .{ ip.getter_alloc_param_ident, st.self_param_ident, st.ref_field_ident },
                );
                try self.emitStringLit(ip.wire_name);
                try self.out.appendSlice(self.allocator, ");\n}\n");
            } else {
                try self.out.appendSlice(self.allocator, "return __zigar_js.getInstanceProp(");
                if (shared_get_ty_expr_opt) |rtexpr| {
                    try self.out.appendSlice(self.allocator, rtexpr);
                } else {
                    try self.emitType(get_ty);
                }
                try self.out.print(
                    self.allocator,
                    ", {s}.{s}, ",
                    .{ st.self_param_ident, st.ref_field_ident },
                );
                try self.emitStringLit(ip.wire_name);
                try self.out.appendSlice(self.allocator, ");\n}\n");
            }
        }

        if (ip.setter_ident) |setter_id| {
            const set_ty = ip.setter_ty.?;
            if (ip.getter_ident == null) {
                if (ip.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
            }
            try self.out.print(
                self.allocator,
                "pub fn {s}({s}: {s}, {s}: ",
                .{ setter_id, st.self_param_ident, st.self_ident, ip.setter_param_ident },
            );
            if (shared_get_ty_expr_opt != null and ip.getter_ty != null and set_ty == ip.getter_ty.?) {
                try self.out.appendSlice(self.allocator, shared_get_ty_expr_opt.?);
            } else {
                try self.emitType(set_ty);
            }
            try self.out.print(
                self.allocator,
                ") __zigar_js.CallError!void {{\nreturn __zigar_js.setInstanceProp(@TypeOf({s}), {s}.{s}, ",
                .{ ip.setter_param_ident, st.self_param_ident, st.ref_field_ident },
            );
            try self.emitStringLit(ip.wire_name);
            try self.out.print(self.allocator, ", {s}, ", .{ip.setter_param_ident});
            try self.emitNullishSpec(set_ty, ip.setter_is_optional);
            try self.out.appendSlice(self.allocator, ");\n}\n");
        }
    }

    fn emitStructIndexAccessor(
        self: *ModuleEmitCtx,
        st: ir.StructDeclIr,
        ia: ir.IndexAccessorIr,
    ) error{OutOfMemory}!void {
        const synth_params = [_]ir.ParamIr{
            .{
                .zig_ident = ia.key_param_ident,
                .logical_name = ia.key_param_ident,
                .wire_name = ia.key_param_ident,
                .ty = ia.key_ty,
                .is_optional = false,
                .is_rest = false,
            },
            .{
                .zig_ident = ia.setter_val_param_ident,
                .logical_name = ia.setter_val_param_ident,
                .wire_name = ia.setter_val_param_ident,
                .ty = ia.setter_ty,
                .is_optional = false,
                .is_rest = false,
            },
        };
        const synth_sig = ir.SignatureIr{
            .type_params = &.{},
            .self_param_ident = st.self_param_ident,
            .alloc_param_ident = ia.getter_alloc_param_ident,
            .params = &synth_params,
            .return_type = ia.getter_ty,
            .has_type_predicate = false,
            .type_predicate_asserts = false,
            .jsdoc = null,
        };

        var shared_key_expr_opt: ?[]u8 = null;
        defer if (shared_key_expr_opt) |buf| self.allocator.free(buf);
        if (typeHasInlineNominal(ia.key_ty)) {
            shared_key_expr_opt = try self.emitSharedNominalTypeExpr(ia.key_ty, synth_sig);
        }

        var shared_set_expr_opt: ?[]u8 = null;
        defer if (shared_set_expr_opt) |buf| self.allocator.free(buf);
        var shared_get_expr_opt: ?[]u8 = null;
        defer if (shared_get_expr_opt) |buf| self.allocator.free(buf);

        const getter_wraps_setter = ia.getter_ty.* == .optional and ia.getter_ty.optional.child == ia.setter_ty;
        if (typeHasInlineNominal(ia.setter_ty)) {
            shared_set_expr_opt = try self.emitSharedNominalTypeExpr(ia.setter_ty, synth_sig);
        } else if (typeHasInlineNominal(ia.getter_ty)) {
            shared_get_expr_opt = try self.emitSharedNominalTypeExpr(ia.getter_ty, synth_sig);
        }

        try self.out.print(
            self.allocator,
            "pub fn {s}({s}: {s}, {s}: ",
            .{ ia.getter_ident, st.self_param_ident, st.self_ident, ia.key_param_ident },
        );
        if (shared_key_expr_opt) |kexpr| {
            try self.out.appendSlice(self.allocator, kexpr);
        } else {
            try self.emitType(ia.key_ty);
        }
        try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
        if (shared_set_expr_opt) |sexpr| {
            if (getter_wraps_setter) try self.out.append(self.allocator, '?');
            try self.out.appendSlice(self.allocator, sexpr);
        } else if (shared_get_expr_opt) |gexpr| {
            try self.out.appendSlice(self.allocator, gexpr);
        } else {
            try self.emitType(ia.getter_ty);
        }
        try self.out.appendSlice(self.allocator, " {\n");

        const strict_lit = if (ia.strict_undefined_missing) "true" else "false";
        if (ia.getter_alloc_ident) |alloc_id| {
            try self.out.print(
                self.allocator,
                "return @This().{s}({s}, try __zigar_js.defaultAllocator(), {s});\n}}\n",
                .{ alloc_id, st.self_param_ident, ia.key_param_ident },
            );
            try self.out.print(
                self.allocator,
                "pub fn {s}({s}: {s}, {s}: @import(\"std\").mem.Allocator, {s}: ",
                .{ alloc_id, st.self_param_ident, st.self_ident, ia.getter_alloc_param_ident, ia.key_param_ident },
            );
            if (shared_key_expr_opt) |kexpr| {
                try self.out.appendSlice(self.allocator, kexpr);
            } else {
                try self.emitType(ia.key_ty);
            }
            try self.out.appendSlice(self.allocator, ") __zigar_js.CallError!");
            if (shared_set_expr_opt) |sexpr| {
                if (getter_wraps_setter) try self.out.append(self.allocator, '?');
                try self.out.appendSlice(self.allocator, sexpr);
            } else if (shared_get_expr_opt) |gexpr| {
                try self.out.appendSlice(self.allocator, gexpr);
            } else {
                try self.emitType(ia.getter_ty);
            }
            try self.out.appendSlice(self.allocator, " {\nreturn __zigar_js.getIndexedPropAlloc(");
            if (shared_set_expr_opt) |sexpr| {
                if (getter_wraps_setter) try self.out.append(self.allocator, '?');
                try self.out.appendSlice(self.allocator, sexpr);
            } else if (shared_get_expr_opt) |gexpr| {
                try self.out.appendSlice(self.allocator, gexpr);
            } else {
                try self.emitType(ia.getter_ty);
            }
            try self.out.print(
                self.allocator,
                ", {s}, {s}.{s}, {s}, {s});\n}}\n",
                .{ ia.getter_alloc_param_ident, st.self_param_ident, st.ref_field_ident, ia.key_param_ident, strict_lit },
            );
        } else {
            try self.out.appendSlice(self.allocator, "return __zigar_js.getIndexedProp(");
            if (shared_set_expr_opt) |sexpr| {
                if (getter_wraps_setter) try self.out.append(self.allocator, '?');
                try self.out.appendSlice(self.allocator, sexpr);
            } else if (shared_get_expr_opt) |gexpr| {
                try self.out.appendSlice(self.allocator, gexpr);
            } else {
                try self.emitType(ia.getter_ty);
            }
            try self.out.print(
                self.allocator,
                ", {s}.{s}, {s}, {s});\n}}\n",
                .{ st.self_param_ident, st.ref_field_ident, ia.key_param_ident, strict_lit },
            );
        }

        if (ia.setter_ident) |setter_id| {
            try self.out.print(
                self.allocator,
                "pub fn {s}({s}: {s}, {s}: ",
                .{ setter_id, st.self_param_ident, st.self_ident, ia.setter_key_param_ident },
            );
            if (shared_key_expr_opt) |kexpr| {
                try self.out.appendSlice(self.allocator, kexpr);
            } else {
                try self.emitType(ia.key_ty);
            }
            try self.out.print(self.allocator, ", {s}: ", .{ia.setter_val_param_ident});
            if (shared_set_expr_opt) |sexpr| {
                try self.out.appendSlice(self.allocator, sexpr);
            } else {
                try self.emitType(ia.setter_ty);
            }
            try self.out.print(
                self.allocator,
                ") __zigar_js.CallError!void {{\nreturn __zigar_js.setIndexedProp(@TypeOf({s}), {s}.{s}, {s}, {s}, ",
                .{ ia.setter_val_param_ident, st.self_param_ident, st.ref_field_ident, ia.setter_key_param_ident, ia.setter_val_param_ident },
            );
            try self.emitNullishSpec(ia.setter_ty, false);
            try self.out.appendSlice(self.allocator, ");\n}\n");
        }
    }

    fn appendDeclIdentsToScopeFrame(
        frame_list: *std.ArrayList([]const u8),
        allocator: std.mem.Allocator,
        d: ir.DeclIr,
    ) error{OutOfMemory}!void {
        try frame_list.append(allocator, d.zig_ident);
        if (d.alloc_companion_ident) |aci| try frame_list.append(allocator, aci);
        if (d.slice_companion_ident) |sci| try frame_list.append(allocator, sci);
        if (d.slice_alloc_companion_ident) |saci| try frame_list.append(allocator, saci);
        if (d.narrow_companion_ident) |nci| try frame_list.append(allocator, nci);
        if (d.narrow_alloc_companion_ident) |naci| try frame_list.append(allocator, naci);
        if (d.default_companion_ident) |dci| try frame_list.append(allocator, dci);
        if (d.default_alloc_companion_ident) |daci| try frame_list.append(allocator, daci);
        if (d.with_companion_ident) |wci| try frame_list.append(allocator, wci);
        if (d.infer_companion_ident) |ici| try frame_list.append(allocator, ici);
        if (d.infer_alloc_companion_ident) |iaci| try frame_list.append(allocator, iaci);
    }

    fn emitStructBody(
        self: *ModuleEmitCtx,
        wire_name: []const u8,
        is_global_scope: bool,
        is_default_export: bool,
        push_owner_seg: bool,
        st: ir.StructDeclIr,
    ) error{OutOfMemory}!void {
        var frame_list: std.ArrayList([]const u8) = .empty;
        defer frame_list.deinit(self.allocator);

        try frame_list.append(self.allocator, st.self_ident);
        try frame_list.append(self.allocator, "zigar_js");
        for (st.type_params) |tp| {
            try frame_list.append(self.allocator, tp.zig_ident);
        }
        for (st.static_props) |sp| {
            try frame_list.append(self.allocator, sp.zig_ident);
        }
        for (st.constructors) |ctor| {
            try frame_list.append(self.allocator, ctor.zig_ident);
            if (ctor.slice_companion_ident) |sci| try frame_list.append(self.allocator, sci);
        }
        if (st.ctor_dispatch) |cd| {
            try frame_list.append(self.allocator, cd.zig_ident);
        }
        if (st.empty_init_ident) |eii| {
            try frame_list.append(self.allocator, eii);
        }
        for (st.methods) |m| {
            try frame_list.append(self.allocator, m.zig_ident);
            if (m.alloc_companion_ident) |aci| try frame_list.append(self.allocator, aci);
            if (m.slice_companion_ident) |sci| try frame_list.append(self.allocator, sci);
            if (m.slice_alloc_companion_ident) |saci| try frame_list.append(self.allocator, saci);
            if (m.narrow_companion_ident) |nci| try frame_list.append(self.allocator, nci);
            if (m.narrow_alloc_companion_ident) |naci| try frame_list.append(self.allocator, naci);
            if (m.default_companion_ident) |dci| try frame_list.append(self.allocator, dci);
            if (m.default_alloc_companion_ident) |daci| try frame_list.append(self.allocator, daci);
            if (m.infer_companion_ident) |ici| try frame_list.append(self.allocator, ici);
            if (m.infer_alloc_companion_ident) |iaci| try frame_list.append(self.allocator, iaci);
        }
        for (st.method_dispatches) |md| {
            try frame_list.append(self.allocator, md.zig_ident);
            if (md.alloc_companion_ident) |aci| try frame_list.append(self.allocator, aci);
        }
        for (st.instance_props) |ip| {
            if (ip.getter_ident) |gi| try frame_list.append(self.allocator, gi);
            if (ip.getter_alloc_ident) |gai| try frame_list.append(self.allocator, gai);
            if (ip.setter_ident) |si| try frame_list.append(self.allocator, si);
        }
        for (st.index_accessors) |ia| {
            try frame_list.append(self.allocator, ia.getter_ident);
            if (ia.getter_alloc_ident) |gai| try frame_list.append(self.allocator, gai);
            if (ia.setter_ident) |si| try frame_list.append(self.allocator, si);
        }
        if (st.deinit_ident) |di| try frame_list.append(self.allocator, di);
        if (st.clone_ident) |ci| try frame_list.append(self.allocator, ci);
        if (st.as_ident) |ai| try frame_list.append(self.allocator, ai);
        if (st.try_as_ident) |tai| try frame_list.append(self.allocator, tai);
        if (st.to_js_ref_ident) |ti| try frame_list.append(self.allocator, ti);
        if (st.from_js_ref_ident) |fi_id| try frame_list.append(self.allocator, fi_id);
        if (st.from_js_ref_alloc_ident) |fai_id| try frame_list.append(self.allocator, fai_id);
        for (st.merged_call_fns) |cf| {
            try appendDeclIdentsToScopeFrame(&frame_list, self.allocator, cf);
        }
        for (st.nested_decls) |nd| {
            try appendDeclIdentsToScopeFrame(&frame_list, self.allocator, nd);
        }
        try self.nested_decl_scopes.append(self.allocator, frame_list.items);
        defer _ = self.nested_decl_scopes.pop();

        try self.out.appendSlice(self.allocator, "struct {\n");
        try self.out.print(self.allocator, "const {s} = @This();\n", .{st.self_ident});

        if (st.repr == .handle_wrapper) {
            const backing_ty = if (st.is_callable_handle) "__zigar_js.JsFunction" else "__zigar_js.JsObject";
            try self.out.print(self.allocator, "{s}: {s},\n", .{ st.ref_field_ident, backing_ty });
        } else {
            for (st.fields) |f| {
                if (f.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
                try self.out.print(self.allocator, "{s}: ", .{f.zig_ident});
                try self.emitType(f.ty);
                try self.emitFieldDefaultValue(f);
                try self.out.appendSlice(self.allocator, ",\n");
            }
        }

        for (st.static_props) |sp| {
            if (sp.jsdoc) |jd| try appendJsDocComments(&self.out, self.allocator, jd);
            if (sp.literal) |lit| {
                try self.emitLiteralConst("pub ", sp.zig_ident, sp.ty, lit);
            } else {
                const owner_seg: ?[]const u8 = if (push_owner_seg) wire_name else null;
                switch (sp.access_kind) {
                    .read_write => {
                        try self.out.print(self.allocator, "pub const {s}: __zigar_js.GlobalTarget(", .{sp.zig_ident});
                        try self.emitType(sp.ty);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitCallTargetLiteral(is_global_scope, sp.wire_name, false, owner_seg);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitNullishSpec(sp.ty, false);
                        try self.out.appendSlice(self.allocator, ") = .{};\n");
                    },
                    .read_only => {
                        try self.out.print(self.allocator, "pub const {s}: __zigar_js.ReadonlyGlobalTarget(", .{sp.zig_ident});
                        try self.emitType(sp.ty);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitCallTargetLiteral(is_global_scope, sp.wire_name, false, owner_seg);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitNullishSpec(sp.ty, false);
                        try self.out.appendSlice(self.allocator, ") = .{};\n");
                    },
                    .write_only => {
                        const w_ty = sp.setter_ty orelse sp.ty;
                        try self.out.print(self.allocator, "pub const {s}: __zigar_js.WriteOnlyGlobalTarget(", .{sp.zig_ident});
                        try self.emitType(w_ty);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitCallTargetLiteral(is_global_scope, sp.wire_name, false, owner_seg);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitNullishSpec(w_ty, false);
                        try self.out.appendSlice(self.allocator, ") = .{};\n");
                    },
                    .divergent_read_write => {
                        const w_ty = sp.setter_ty orelse sp.ty;
                        try self.out.print(self.allocator, "pub const {s}: __zigar_js.AccessorGlobalTarget(", .{sp.zig_ident});
                        try self.emitType(sp.ty);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitType(w_ty);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitCallTargetLiteral(is_global_scope, sp.wire_name, false, owner_seg);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitNullishSpec(sp.ty, false);
                        try self.out.appendSlice(self.allocator, ", ");
                        try self.emitNullishSpec(w_ty, false);
                        try self.out.appendSlice(self.allocator, ") = .{};\n");
                    },
                }
            }
        }

        for (st.constructors) |ctor| {
            try self.emitStructConstructor(wire_name, is_global_scope, is_default_export, ctor);
        }
        if (st.ctor_dispatch) |cd| {
            try self.emitOverloadDispatcher("pub ", cd, null);
        }
        if (st.empty_init_ident) |eii| {
            try self.out.print(
                self.allocator,
                "pub fn {s}() __zigar_js.CallError!{s} {{\nreturn __zigar_js.initEmptyHandle({s});\n}}\n",
                .{ eii, st.self_ident, st.self_ident },
            );
        }

        for (st.methods) |m| {
            try self.emitStructMethod(wire_name, is_global_scope, push_owner_seg, st, m);
        }
        for (st.method_dispatches) |md| {
            const recv_opt: ?RecvSpec = if (md.is_static)
                null
            else
                .{ .ident = md.self_param_ident, .self_ty = st.self_ident };
            try self.emitOverloadDispatcher("pub ", md, recv_opt);
        }

        for (st.instance_props) |ip| {
            try self.emitStructInstanceProp(st, ip);
        }

        for (st.index_accessors) |ia| {
            try self.emitStructIndexAccessor(st, ia);
        }

        if (st.repr == .handle_wrapper) {
            if (st.deinit_ident) |di| {
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: {s}) void {{\n{s}.{s}.deinit();\n}}\n",
                    .{ di, st.self_param_ident, st.self_ident, st.self_param_ident, st.ref_field_ident },
                );
            }
            if (st.clone_ident) |ci| {
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: {s}) __zigar_js.CallError!{s} {{\nreturn __zigar_js.cloneHandle({s}, {s});\n}}\n",
                    .{ ci, st.self_param_ident, st.self_ident, st.self_ident, st.self_ident, st.self_param_ident },
                );
            }
            if (st.as_ident) |ai| {
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: {s}, comptime {s}: type) {s} {{\nreturn __zigar_js.upcastValue({s}, {s}, {s});\n}}\n",
                    .{ ai, st.self_param_ident, st.self_ident, st.base_type_param_ident, st.base_type_param_ident, st.self_ident, st.self_param_ident, st.base_type_param_ident },
                );
            }
            if (st.try_as_ident) |tai| {
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: {s}, comptime {s}: type) __zigar_js.CallError!?{s} {{\nreturn __zigar_js.downcastHandle({s}, {s}.{s});\n}}\n",
                    .{ tai, st.self_param_ident, st.self_ident, st.sub_type_param_ident, st.sub_type_param_ident, st.sub_type_param_ident, st.self_param_ident, st.ref_field_ident },
                );
            }
            if (st.to_js_ref_ident) |ti| {
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: {s}) __zigar_js.Any {{\nreturn .{{ .handle = {s}.{s}.handle }};\n}}\n",
                    .{ ti, st.self_param_ident, st.self_ident, st.self_param_ident, st.ref_field_ident },
                );
            }
            if (st.from_js_ref_ident) |fi_id| {
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: anytype) __zigar_js.CallError!{s} {{\nreturn __zigar_js.fromJsRef({s}, {s});\n}}\n",
                    .{ fi_id, st.raw_param_ident, st.self_ident, st.self_ident, st.raw_param_ident },
                );
            }
        } else {
            if (st.as_ident) |ai| {
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: {s}, comptime {s}: type) {s} {{\nreturn __zigar_js.upcastValue({s}, {s}, {s});\n}}\n",
                    .{ ai, st.self_param_ident, st.self_ident, st.base_type_param_ident, st.base_type_param_ident, st.self_ident, st.self_param_ident, st.base_type_param_ident },
                );
            }
            if (st.to_js_ref_ident) |ti| {
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: {s}) __zigar_js.CallError!__zigar_js.Any {{\nreturn __zigar_js.toJsRef({s}, {s});\n}}\n",
                    .{ ti, st.self_param_ident, st.self_ident, st.self_ident, st.self_param_ident },
                );
            }
            if (st.from_js_ref_ident) |fi_id| {
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: anytype) __zigar_js.CallError!{s} {{\nreturn __zigar_js.fromJsRef({s}, {s});\n}}\n",
                    .{ fi_id, st.raw_param_ident, st.self_ident, st.self_ident, st.raw_param_ident },
                );
            }
            if (st.from_js_ref_alloc_ident) |fai_id| {
                try self.out.print(
                    self.allocator,
                    "pub fn {s}({s}: @import(\"std\").mem.Allocator, {s}: anytype) __zigar_js.CallError!{s} {{\nreturn __zigar_js.fromJsRefAlloc({s}, {s}, {s});\n}}\n",
                    .{ fai_id, st.alloc_param_ident, st.raw_param_ident, st.self_ident, st.self_ident, st.alloc_param_ident, st.raw_param_ident },
                );
            }
        }

        for (st.merged_call_fns) |cf| {
            try self.emitDecl(cf);
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
        if (st.bases.len > 0) {
            try self.out.appendSlice(self.allocator, ",\n.bases = .{ ");
            for (st.bases, 0..) |bty, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.emitType(bty);
            }
            try self.out.appendSlice(self.allocator, " }");
        }
        if (st.repr == .handle_wrapper) {
            try self.out.appendSlice(self.allocator, ",\n.is_handle = true,\n.ref_field = ");
            try self.emitStringLit(unquoteZigIdent(st.ref_field_ident));
            if (st.is_callable_handle) {
                try self.out.appendSlice(self.allocator, ",\n.is_callable_handle = true");
            }
            if (!st.is_class and st.required_methods.len > 0) {
                try self.out.appendSlice(self.allocator, ",\n.required_methods = &[_][]const u8{ ");
                for (st.required_methods, 0..) |rm, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.emitStringLit(rm);
                }
                try self.out.appendSlice(self.allocator, " }");
            }
            if (!st.is_class and st.required_props.len > 0) {
                try self.out.appendSlice(self.allocator, ",\n.required_props = &[_][]const u8{ ");
                for (st.required_props, 0..) |rp, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.emitStringLit(rp);
                }
                try self.out.appendSlice(self.allocator, " }");
            }
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
        push_owner_seg: bool,
        is_const: bool,
        backing: lower_unions.EnumBackingKind,
        members: []const ir.EnumMemberIr,
        nested_decls: []const ir.DeclIr,
    ) error{OutOfMemory}!void {
        var frame_list: std.ArrayList([]const u8) = .empty;
        defer frame_list.deinit(self.allocator);
        if (nested_decls.len > 0) {
            try frame_list.append(self.allocator, "zigar_js");
            for (members) |m| try frame_list.append(self.allocator, m.zig_ident);
            try frame_list.append(self.allocator, "toSlice");
            try frame_list.append(self.allocator, "fromSlice");
            try frame_list.append(self.allocator, "toInt");
            try frame_list.append(self.allocator, "fromInt");
            for (nested_decls) |nd| {
                try appendDeclIdentsToScopeFrame(&frame_list, self.allocator, nd);
            }
            try self.nested_decl_scopes.append(self.allocator, frame_list.items);
        }
        defer if (nested_decls.len > 0) {
            _ = self.nested_decl_scopes.pop();
        };

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

        if (nested_decls.len > 0) {
            const push_seg = push_owner_seg and wire_name != null;
            if (push_seg) {
                try self.ns_wire_path.append(self.allocator, wire_name.?);
            }
            defer if (push_seg) {
                _ = self.ns_wire_path.pop();
            };
            for (nested_decls) |nd| {
                try self.emitDecl(nd);
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
        nested_decls: []const ir.DeclIr,
    ) error{OutOfMemory}!void {
        if (has_unknown_values) {
            var frame_list: std.ArrayList([]const u8) = .empty;
            defer frame_list.deinit(self.allocator);
            if (nested_decls.len > 0) {
                try frame_list.append(self.allocator, "zigar_js");
                try frame_list.append(self.allocator, "__zigar_value");
                try frame_list.append(self.allocator, "deinit");
                for (members) |m| try frame_list.append(self.allocator, m.zig_ident);
                for (nested_decls) |nd| {
                    try appendDeclIdentsToScopeFrame(&frame_list, self.allocator, nd);
                }
                try self.nested_decl_scopes.append(self.allocator, frame_list.items);
            }
            defer if (nested_decls.len > 0) {
                _ = self.nested_decl_scopes.pop();
            };

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
            if (nested_decls.len > 0) {
                if (push_owner_seg) {
                    try self.ns_wire_path.append(self.allocator, wire_name);
                }
                defer if (push_owner_seg) {
                    _ = self.ns_wire_path.pop();
                };
                for (nested_decls) |nd| {
                    try self.emitDecl(nd);
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

        try self.emitClosedEnumBody(wire_name, push_owner_seg, is_const, backing, members, nested_decls);
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
            .overload_dispatch => |od| {
                try self.emitOverloadDispatcher(pub_kw, od, null);
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
                var has_default_merged_call = false;
                for (st.merged_call_fns) |cf| {
                    if (cf.is_default_export) {
                        has_default_merged_call = true;
                        break;
                    }
                }
                const is_default_cls = !d.is_global_scope and
                    self.ns_wire_path.items.len == 0 and
                    (d.is_default_export or has_default_merged_call or self.isExportEqualsRootDecl(d));
                const set_def_owner = is_default_cls and (d.is_default_export or has_default_merged_call) and self.mod.export_equals_wire_name == null;
                const prev_def_owner = self.active_default_owner_wire;
                if (set_def_owner) self.active_default_owner_wire = d.wire_name;
                defer if (set_def_owner) {
                    self.active_default_owner_wire = prev_def_owner;
                };
                if (st.type_params.len == 0) {
                    try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                    try self.emitStructBody(d.wire_name, d.is_global_scope, is_default_cls, push_owner, st);
                    try self.out.appendSlice(self.allocator, ";\n");
                } else {
                    try self.emitTypeParamsDocComments(st.type_params);
                    try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
                    for (st.type_params, 0..) |tp, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                    }
                    try self.out.appendSlice(self.allocator, ") type {\n");
                    try self.emitTypeParamConstraintChecks(st.type_params);
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitStructBody(d.wire_name, d.is_global_scope, is_default_cls, push_owner, st);
                    try self.out.appendSlice(self.allocator, ";\n}\n");
                    try self.emitGenericTypeCompanions(
                        pub_kw,
                        d.zig_ident,
                        d.default_companion_ident,
                        d.with_companion_ident,
                        st.type_params,
                    );
                }
            },
            .enum_decl => |en| {
                const push_owner = true;
                try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                try self.emitEnumBody(d.wire_name, d.is_global_scope, push_owner, en.is_const, en.has_unknown_values, en.backing, en.members, en.nested_decls);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .literal_enum_decl => |en| {
                try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                try self.emitClosedEnumBody(d.wire_name, false, false, en.backing, en.members, &.{});
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
                    try self.emitTypeParamsDocComments(un.type_params);
                    try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
                    for (un.type_params, 0..) |tp, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                    }
                    try self.out.appendSlice(self.allocator, ") type {\n");
                    try self.emitTypeParamConstraintChecks(un.type_params);
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitTaggedUnionBody(d.wire_name, un.type_params, un.discriminant_prop, un.variants);
                    try self.out.appendSlice(self.allocator, ";\n}\n");
                    try self.emitGenericTypeCompanions(
                        pub_kw,
                        d.zig_ident,
                        d.default_companion_ident,
                        d.with_companion_ident,
                        un.type_params,
                    );
                }
            },
            .type_alias => |ta| {
                if (ta.type_params.len == 0) {
                    try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                    try self.emitType(ta.target);
                    try self.out.appendSlice(self.allocator, ";\n");
                } else {
                    try self.emitTypeParamsDocComments(ta.type_params);
                    try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
                    for (ta.type_params, 0..) |tp, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                    }
                    try self.out.appendSlice(self.allocator, ") type {\n");
                    try self.emitTypeParamConstraintChecks(ta.type_params);
                    for (ta.type_params) |tp| {
                        if (!typeUsesTypeParam(ta.target, tp.zig_ident) and !typeParamsCheckUsesIdent(ta.type_params, tp.zig_ident)) {
                            try self.out.print(self.allocator, "_ = {s};\n", .{tp.zig_ident});
                        }
                    }
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitType(ta.target);
                    try self.out.appendSlice(self.allocator, ";\n}\n");
                    try self.emitGenericTypeCompanions(
                        pub_kw,
                        d.zig_ident,
                        d.default_companion_ident,
                        d.with_companion_ident,
                        ta.type_params,
                    );
                }
            },
            .namespace_decl => |ns| {
                var has_default_merged_call = false;
                for (ns.merged_call_fns) |cf| {
                    if (cf.is_default_export) {
                        has_default_merged_call = true;
                        break;
                    }
                }
                const set_def_owner = !d.is_global_scope and
                    self.ns_wire_path.items.len == 0 and
                    (d.is_default_export or has_default_merged_call) and
                    self.mod.export_equals_wire_name == null;
                const prev_def_owner = self.active_default_owner_wire;
                if (set_def_owner) self.active_default_owner_wire = d.wire_name;
                defer if (set_def_owner) {
                    self.active_default_owner_wire = prev_def_owner;
                };

                var frame_list: std.ArrayList([]const u8) = .empty;
                defer frame_list.deinit(self.allocator);
                for (ns.merged_call_fns) |cf| {
                    try appendDeclIdentsToScopeFrame(&frame_list, self.allocator, cf);
                }
                for (ns.children) |cd| {
                    try appendDeclIdentsToScopeFrame(&frame_list, self.allocator, cd);
                }
                try frame_list.append(self.allocator, "zigar_js");
                try self.nested_decl_scopes.append(self.allocator, frame_list.items);
                defer _ = self.nested_decl_scopes.pop();

                try self.out.print(self.allocator, "{s}const {s} = struct {{\n", .{ pub_kw, d.zig_ident });
                for (ns.merged_call_fns) |cf| {
                    try self.emitDecl(cf);
                }
                {
                    try self.ns_wire_path.append(self.allocator, d.wire_name);
                    defer _ = self.ns_wire_path.pop();
                    for (ns.children) |cd| {
                        try self.emitDecl(cd);
                    }
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
        .js_record => |r| typeHasInlineNominal(r.key) or typeHasInlineNominal(r.value),
        .mapped_values_op => |mv| typeHasInlineNominal(mv.target) or typeHasInlineNominal(mv.value),
        .unary_type_op => |uo| typeHasInlineNominal(uo.operand),
        .key_filter_op => |kfo| typeHasInlineNominal(kfo.target) or
            (kfo.keys == .ty and typeHasInlineNominal(kfo.keys.ty)),
        .index_access_op => |iao| typeHasInlineNominal(iao.object_ty) or
            (iao.index_spec == .ty and typeHasInlineNominal(iao.index_spec.ty)),
        .fn_ptr => |fp| blk: {
            if (fp.this_param) |thp_ty| {
                if (typeHasInlineNominal(thp_ty)) break :blk true;
            }
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

fn classifyOverloadGenericParam(
    ty: *const ir.TypeIr,
    tps: []const ir.TypeParamIr,
) lower_generics.OverloadGenericParamRef {
    switch (ty.*) {
        .type_param_ref => |ref_id| {
            for (tps, 0..) |tp, idx| {
                if (std.mem.eql(u8, tp.zig_ident, ref_id)) {
                    return .{ .tp_idx = idx, .mode = .direct };
                }
            }
        },
        .optional => |opt| {
            if (opt.child.* == .type_param_ref) {
                for (tps, 0..) |tp, idx| {
                    if (std.mem.eql(u8, tp.zig_ident, opt.child.type_param_ref)) {
                        return .{ .tp_idx = idx, .mode = .optional_child };
                    }
                }
            }
        },
        .slice => |elem_ty| {
            if (elem_ty.* == .type_param_ref) {
                for (tps, 0..) |tp, idx| {
                    if (std.mem.eql(u8, tp.zig_ident, elem_ty.type_param_ref)) {
                        return .{ .tp_idx = idx, .mode = .slice_elem };
                    }
                }
            }
        },
        .promise => |prom_ty| {
            if (prom_ty.* == .type_param_ref) {
                for (tps, 0..) |tp, idx| {
                    if (std.mem.eql(u8, tp.zig_ident, prom_ty.type_param_ref)) {
                        return .{ .tp_idx = idx, .mode = .promise_payload };
                    }
                }
            }
        },
        else => {},
    }
    return .{};
}

fn typeUsesAnyTypeParam(ty: *const ir.TypeIr, tps: []const ir.TypeParamIr) bool {
    for (tps) |tp| {
        if (typeUsesTypeParam(ty, tp.zig_ident)) return true;
    }
    return false;
}

fn typeParamsCheckUsesIdent(tps: []const ir.TypeParamIr, tp_ident: []const u8) bool {
    for (tps) |tp| {
        if (!tp.enforce_constraint) continue;
        if (tp.constraint) |ct| {
            if (std.mem.eql(u8, tp.zig_ident, tp_ident)) return true;
            if (typeUsesTypeParam(ct, tp_ident)) return true;
        }
    }
    return false;
}

fn emittedSigUsesTypeParam(sig: ir.SignatureIr, tp_ident: []const u8) bool {
    if (sig.this_param) |thp| {
        if (typeUsesTypeParam(thp.ty, tp_ident)) return true;
    }
    for (sig.params) |p| {
        if (p.callback_sig != null) continue;
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
        .js_record => |r| typeUsesTypeParam(r.key, tp_ident) or typeUsesTypeParam(r.value, tp_ident),
        .mapped_values_op => |mv| typeUsesTypeParam(mv.target, tp_ident) or typeUsesTypeParam(mv.value, tp_ident),
        .unary_type_op => |uo| typeUsesTypeParam(uo.operand, tp_ident),
        .key_filter_op => |kfo| typeUsesTypeParam(kfo.target, tp_ident) or
            (kfo.keys == .ty and typeUsesTypeParam(kfo.keys.ty, tp_ident)),
        .index_access_op => |iao| typeUsesTypeParam(iao.object_ty, tp_ident) or
            (iao.index_spec == .ty and typeUsesTypeParam(iao.index_spec.ty, tp_ident)),
        .tuple => |elems| blk: {
            for (elems) |el| {
                if (typeUsesTypeParam(el.ty, tp_ident)) break :blk true;
            }
            break :blk false;
        },
        .fn_ptr => |fp| blk: {
            if (fp.this_param) |thp_ty| {
                if (typeUsesTypeParam(thp_ty, tp_ident)) break :blk true;
            }
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
            const is_barrel_visible = d.is_exported and
                (d.is_js_exported or (d.kind == .overload_dispatch and !d.is_global_scope));
            if (!is_barrel_visible) continue;
            if (!root_scope.isTaken(d.logical_name)) {
                try root_scope.reserve(d.logical_name);
                try barrel_exports.append(allocator, d.zig_ident);
            }
            const companions = [_]?[]const u8{
                d.alloc_companion_ident,
                d.slice_companion_ident,
                d.slice_alloc_companion_ident,
                d.narrow_companion_ident,
                d.narrow_alloc_companion_ident,
            };
            for (companions) |comp_opt| {
                if (comp_opt) |ci| {
                    if (!root_scope.isTaken(ci)) {
                        try root_scope.reserve(ci);
                        try barrel_exports.append(allocator, ci);
                    }
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
        \\        pub const Value = T;
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
        \\pub const JsFunction = Function;
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
        \\    pub const is_js_bigint = true;
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
        \\        pub const is_js_promise = true;
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
        \\        pub const Element = T;
        \\        pub const Elem = T;
        \\        pub const is_js_array = true;
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
        \\        pub const is_js_map = true;
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
        \\        pub const Element = T;
        \\        pub const Elem = T;
        \\        pub const is_js_set = true;
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
        \\    if (@typeInfo(K) == .@"enum" and @typeInfo(K).@"enum".mode == .exhaustive) {
        \\        return standaloneEnumRecord(K, V);
        \\    }
        \\    return extern struct {
        \\        const Self = @This();
        \\        pub const Key = K;
        \\        pub const Value = V;
        \\        pub const is_js_record = true;
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
        \\pub const Partial = if (has_host) raw_js.Partial else standalonePartial;
        \\pub const Required = if (has_host) raw_js.Required else standaloneRequired;
        \\pub const Readonly = if (has_host) raw_js.Readonly else standaloneReadonly;
        \\pub const Pick = if (has_host) raw_js.Pick else standalonePick;
        \\pub const Omit = if (has_host) raw_js.Omit else standaloneOmit;
        \\pub const EnumRecord = if (has_host) raw_js.EnumRecord else standaloneEnumRecord;
        \\pub const NonNullable = if (has_host) raw_js.NonNullable else standaloneNonNullable;
        \\pub const Awaited = if (has_host) raw_js.Awaited else standaloneAwaited;
        \\pub const KeyOf = if (has_host) raw_js.KeyOf else standaloneKeyOf;
        \\pub const MappedValues = if (has_host) raw_js.MappedValues else standaloneMappedValues;
        \\pub const MappedValuesSpec = if (has_host) raw_js.MappedValuesSpec else standaloneMappedValuesSpec;
        \\pub const IndexAccess = if (has_host) raw_js.IndexAccess else standaloneIndexAccess;
        \\pub const InferJsType = if (has_host) raw_js.InferJsType else standaloneInferJsType;
        \\pub const InferConstJsType = if (has_host) raw_js.InferConstJsType else standaloneInferConstJsType;
        \\pub const isConstArrayPtr = if (has_host) raw_js.isConstArrayPtr else standaloneIsConstArrayPtr;
        \\pub const InferSliceElem = if (has_host) raw_js.InferSliceElem else standaloneInferSliceElem;
        \\pub const InferOptionalChild = if (has_host) raw_js.InferOptionalChild else standaloneInferOptionalChild;
        \\pub const satisfiesTypeConstraint = if (has_host) raw_js.satisfiesTypeConstraint else standaloneSatisfiesTypeConstraint;
        \\pub const checkTypeConstraint = if (has_host) raw_js.checkTypeConstraint else standaloneCheckTypeConstraint;
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
        \\        .array => |ar| needsDecodeAllocator(ar.child),
        \\        .pointer => |pt| switch (pt.size) {
        \\            .slice => true,
        \\            .one => @typeInfo(pt.child) != .@"fn",
        \\            else => false,
        \\        },
        \\        .@"struct" => |st| blk: {
        \\            if ((@hasDecl(T, "is_js_value") and T.is_js_value) or isGeneratedHandleStruct(T)) break :blk false;
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
        \\        .array => |ar| {
        \\            for (value) |elem| freeDecoded(ar.child, allocator, elem);
        \\        },
        \\        .pointer => |pt| switch (pt.size) {
        \\            .slice => {
        \\                if (pt.child != u8) {
        \\                    for (value) |elem| freeDecoded(pt.child, allocator, elem);
        \\                }
        \\                allocator.free(value);
        \\            },
        \\            .one => {
        \\                if (comptime (@typeInfo(pt.child) != .@"fn")) {
        \\                    freeDecoded(pt.child, allocator, value.*);
        \\                    allocator.destroy(value);
        \\                }
        \\            },
        \\            else => {},
        \\        },
        \\        .@"struct" => |st| {
        \\            if (comptime ((@hasDecl(T, "is_js_value") and T.is_js_value) or isGeneratedHandleStruct(T))) {
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
        \\pub fn ReadonlyGlobalTarget(comptime T: type, comptime target: CallTarget, comptime spec: anytype) type {
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
        \\    };
        \\}
        \\
        \\pub fn WriteOnlyGlobalTarget(comptime T: type, comptime target: CallTarget, comptime spec: anytype) type {
        \\    return struct {
        \\        pub const ValueType = T;
        \\        pub const SetValueType = T;
        \\        pub const call_target: CallTarget = target;
        \\        pub const nullish_spec = spec;
        \\
        \\        js_name: []const u8 = target.name,
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
        \\pub fn AccessorGlobalTarget(
        \\    comptime GetT: type,
        \\    comptime SetT: type,
        \\    comptime target: CallTarget,
        \\    comptime get_spec: anytype,
        \\    comptime set_spec: anytype,
        \\) type {
        \\    return struct {
        \\        pub const ValueType = GetT;
        \\        pub const SetValueType = SetT;
        \\        pub const call_target: CallTarget = target;
        \\        pub const nullish_spec = get_spec;
        \\        pub const set_nullish_spec = set_spec;
        \\
        \\        js_name: []const u8 = target.name,
        \\
        \\        pub fn get(_: @This()) CallError!GetT {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const raw = try getGlobalTargetRaw(target);
        \\            defer raw.deinit();
        \\            return try fromJsRef(GetT, raw);
        \\        }
        \\
        \\        pub fn getAlloc(_: @This(), allocator: std.mem.Allocator) CallError!GetT {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const raw = try getGlobalTargetRaw(target);
        \\            defer raw.deinit();
        \\            return try fromJsRefAlloc(GetT, allocator, raw);
        \\        }
        \\
        \\        pub fn set(_: @This(), value: SetT) CallError!void {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const encoded = try toJsRefWithSpec(SetT, value, set_spec);
        \\            defer encoded.deinit();
        \\            try setGlobalTargetRaw(target, encoded);
        \\        }
        \\    };
        \\}
        \\
        \\fn constructRawTarget(comptime target: CallTarget, args: Args) CallError!Any {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const ctor = try getGlobalTargetRaw(target);
        \\    defer ctor.deinit();
        \\    if ((try ctor.tryTypeof()) != .function) {
        \\        return error.NotCallable;
        \\    }
        \\    const reflect = try raw_js.getGlobal(CallError!Object, "Reflect");
        \\    defer reflect.deinit();
        \\    return try raw_js.callMethod(
        \\        fn (Any, Args) CallError!Any,
        \\        reflect,
        \\        "construct",
        \\        .{ ctor, args },
        \\    );
        \\}
        \\
        \\pub fn constructTarget(comptime T: type, comptime target: CallTarget, args: Args) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try constructRawTarget(target, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) {
        \\        return error.Unexpected;
        \\    }
        \\    return try fromJsRef(T, raw);
        \\}
        \\
        \\fn invokeRawMethod(self_ref: anytype, comptime method_name: []const u8, args: Args) CallError!Any {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const recv: Any = .{ .handle = self_ref.handle };
        \\    const callee = try raw_js.getProp(CallError!Any, recv, method_name);
        \\    defer callee.deinit();
        \\    if ((try callee.tryTypeof()) != .function) {
        \\        return error.NotCallable;
        \\    }
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
        \\pub fn invokeMethod(
        \\    comptime T: type,
        \\    self_ref: anytype,
        \\    comptime method_name: []const u8,
        \\    args: Args,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try invokeRawMethod(self_ref, method_name, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) {
        \\        return error.Unexpected;
        \\    }
        \\    return try fromJsRef(T, raw);
        \\}
        \\
        \\pub fn invokeMethodAlloc(
        \\    comptime T: type,
        \\    allocator: std.mem.Allocator,
        \\    self_ref: anytype,
        \\    comptime method_name: []const u8,
        \\    args: Args,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try invokeRawMethod(self_ref, method_name, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) {
        \\        return error.Unexpected;
        \\    }
        \\    return try fromJsRefAlloc(T, allocator, raw);
        \\}
        \\
        \\fn invokeRawCallable(self_ref: anytype, args: Args) CallError!Any {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const callee: Any = .{ .handle = self_ref.handle };
        \\    if ((try callee.tryTypeof()) != .function) {
        \\        return error.NotCallable;
        \\    }
        \\    const reflect = try raw_js.getGlobal(CallError!Object, "Reflect");
        \\    defer reflect.deinit();
        \\    return try raw_js.callMethod(
        \\        fn (Any, Any, Args) CallError!Any,
        \\        reflect,
        \\        "apply",
        \\        .{ callee, Any.@"undefined", args },
        \\    );
        \\}
        \\
        \\pub fn invokeCallable(comptime T: type, self_ref: anytype, args: Args) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try invokeRawCallable(self_ref, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) {
        \\        return error.Unexpected;
        \\    }
        \\    return try fromJsRef(T, raw);
        \\}
        \\
        \\pub fn invokeCallableAlloc(
        \\    comptime T: type,
        \\    allocator: std.mem.Allocator,
        \\    self_ref: anytype,
        \\    args: Args,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try invokeRawCallable(self_ref, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) {
        \\        return error.Unexpected;
        \\    }
        \\    return try fromJsRefAlloc(T, allocator, raw);
        \\}
        \\
        \\fn constructRawCallable(self_ref: anytype, args: Args) CallError!Any {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const ctor: Any = .{ .handle = self_ref.handle };
        \\    if ((try ctor.tryTypeof()) != .function) {
        \\        return error.NotCallable;
        \\    }
        \\    const reflect = try raw_js.getGlobal(CallError!Object, "Reflect");
        \\    defer reflect.deinit();
        \\    return try raw_js.callMethod(
        \\        fn (Any, Args) CallError!Any,
        \\        reflect,
        \\        "construct",
        \\        .{ ctor, args },
        \\    );
        \\}
        \\
        \\pub fn constructCallable(comptime T: type, self_ref: anytype, args: Args) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try constructRawCallable(self_ref, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) {
        \\        return error.Unexpected;
        \\    }
        \\    return try fromJsRef(T, raw);
        \\}
        \\
        \\pub fn constructCallableAlloc(
        \\    comptime T: type,
        \\    allocator: std.mem.Allocator,
        \\    self_ref: anytype,
        \\    args: Args,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try constructRawCallable(self_ref, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) {
        \\        return error.Unexpected;
        \\    }
        \\    return try fromJsRefAlloc(T, allocator, raw);
        \\}
        \\
        \\pub fn getInstanceProp(
        \\    comptime T: type,
        \\    self_ref: anytype,
        \\    comptime prop_name: []const u8,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const recv: Any = .{ .handle = self_ref.handle };
        \\    const raw = try raw_js.getProp(CallError!Any, recv, prop_name);
        \\    defer raw.deinit();
        \\    return try fromJsRef(T, raw);
        \\}
        \\
        \\pub fn getInstancePropAlloc(
        \\    comptime T: type,
        \\    allocator: std.mem.Allocator,
        \\    self_ref: anytype,
        \\    comptime prop_name: []const u8,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const recv: Any = .{ .handle = self_ref.handle };
        \\    const raw = try raw_js.getProp(CallError!Any, recv, prop_name);
        \\    defer raw.deinit();
        \\    return try fromJsRefAlloc(T, allocator, raw);
        \\}
        \\
        \\pub fn setInstanceProp(
        \\    comptime T: type,
        \\    self_ref: anytype,
        \\    comptime prop_name: []const u8,
        \\    value: T,
        \\    comptime spec: anytype,
        \\) CallError!void {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const recv: Any = .{ .handle = self_ref.handle };
        \\    const encoded = try toJsRefWithSpec(T, value, spec);
        \\    defer encoded.deinit();
        \\    try raw_js.trySetProp(recv, prop_name, encoded);
        \\}
        \\
        \\fn isGeneratedHandleStruct(comptime T: type) bool {
        \\    return switch (@typeInfo(T)) {
        \\        .@"struct" => @hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_handle") and T.zigar_js.is_handle,
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn generatedHandleRefFieldName(comptime T: type) []const u8 {
        \\    if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "ref_field")) {
        \\        return T.zigar_js.ref_field;
        \\    }
        \\    return "ref";
        \\}
        \\
        \\fn isTemplateLiteralStruct(comptime T: type) bool {
        \\    return switch (@typeInfo(T)) {
        \\        .@"struct" => @hasDecl(T, "zigar_js") and
        \\            @hasField(@TypeOf(T.zigar_js), "is_template_literal") and
        \\            T.zigar_js.is_template_literal and
        \\            @hasField(T, "raw"),
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn isJsValueStruct(comptime T: type) bool {
        \\    if (@typeInfo(T) != .@"struct") return false;
        \\    if (@hasDecl(T, "is_js_value") and T.is_js_value) return true;
        \\    if (@hasDecl(T, "internal_type") and @typeInfo(@TypeOf(T.internal_type)) == .@"enum" and std.mem.eql(u8, @tagName(T.internal_type), "js_value")) return true;
        \\    return false;
        \\}
        \\
        \\fn assertValidDynamicKeyType(comptime K: type) void {
        \\    if (K == []const u8 or K == []u8 or isStringSliceCoercible(K) or isTemplateLiteralStruct(K)) return;
        \\    if (isJsValueStruct(K) or isGeneratedHandleStruct(K)) return;
        \\    switch (@typeInfo(K)) {
        \\        .float, .comptime_float, .int, .comptime_int => return,
        \\        .@"enum" => {
        \\            if (@hasDecl(K, "toSlice") or @hasDecl(K, "toInt")) return;
        \\        },
        \\        .pointer => |pt| {
        \\            if (pt.size == .slice and pt.child == u8) return;
        \\            if (pt.size == .many and pt.sentinel_ptr != null and pt.child == u8) return;
        \\            if (pt.size == .one and (isJsValueStruct(pt.child) or isGeneratedHandleStruct(pt.child) or isTemplateLiteralStruct(pt.child))) return;
        \\        },
        \\        else => {},
        \\    }
        \\    @compileError("Dynamic JS property key must be `[]const u8`, numeric, template literal, or JS handle, received " ++ @typeName(K));
        \\}
        \\
        \\pub fn getIndexedProp(
        \\    comptime T: type,
        \\    self_ref: anytype,
        \\    key: anytype,
        \\    comptime strict_undefined_missing: bool,
        \\) CallError!T {
        \\    comptime assertValidDynamicKeyType(@TypeOf(key));
        \\    if (!has_host) return error.HostUnavailable;
        \\    return try raw_js.getIndexedProp(T, self_ref, key, strict_undefined_missing);
        \\}
        \\
        \\pub fn getIndexedPropAlloc(
        \\    comptime T: type,
        \\    allocator: std.mem.Allocator,
        \\    self_ref: anytype,
        \\    key: anytype,
        \\    comptime strict_undefined_missing: bool,
        \\) CallError!T {
        \\    comptime assertValidDynamicKeyType(@TypeOf(key));
        \\    if (!has_host) return error.HostUnavailable;
        \\    return try raw_js.getIndexedPropAlloc(T, allocator, self_ref, key, strict_undefined_missing);
        \\}
        \\
        \\pub fn setIndexedProp(
        \\    comptime T: type,
        \\    self_ref: anytype,
        \\    key: anytype,
        \\    value: T,
        \\    comptime spec: anytype,
        \\) CallError!void {
        \\    comptime assertValidDynamicKeyType(@TypeOf(key));
        \\    if (!has_host) return error.HostUnavailable;
        \\    try raw_js.setIndexedProp(T, self_ref, key, value, spec);
        \\}
        \\
        \\pub fn initEmptyHandle(comptime SelfT: type) CallError!SelfT {
        \\    comptime {
        \\        if (!isGeneratedHandleStruct(SelfT)) {
        \\            @compileError("initEmptyHandle requires a JS handle wrapper struct, received " ++ @typeName(SelfT));
        \\        }
        \\    }
        \\    if (!has_host) return error.HostUnavailable;
        \\    return try raw_js.initEmptyHandle(SelfT);
        \\}
        \\
        \\pub fn isAssignableType(comptime Derived: type, comptime Base: type) bool {
        \\    if (has_host) return raw_js.isAssignableType(Derived, Base);
        \\    return isAssignableTypeDepth(Derived, Base, 0);
        \\}
        \\
        \\fn isAssignableTypeDepth(comptime Derived: type, comptime Base: type, comptime depth: usize) bool {
        \\    @setEvalBranchQuota(10_000);
        \\    if (Derived == Base) return true;
        \\    if (depth >= 32) return false;
        \\    if (@typeInfo(Derived) != .@"struct") return false;
        \\    if (!@hasDecl(Derived, "zigar_js")) return false;
        \\    if (!@hasField(@TypeOf(Derived.zigar_js), "bases")) return false;
        \\    inline for (Derived.zigar_js.bases) |DirectBase| {
        \\        if (isAssignableTypeDepth(DirectBase, Base, depth + 1)) return true;
        \\    }
        \\    return false;
        \\}
        \\
        \\fn structWireNameForField(comptime T: type, comptime zig_field_name: []const u8) []const u8 {
        \\    if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "fields")) {
        \\        for (T.zigar_js.fields) |fm| {
        \\            const fm_zig = if (@hasField(@TypeOf(fm), "zig_name")) fm.zig_name else fm.name;
        \\            if (std.mem.eql(u8, fm_zig, zig_field_name)) return fm.name;
        \\        }
        \\    }
        \\    return zig_field_name;
        \\}
        \\
        \\fn findStructFieldByWireName(comptime T: type, comptime wire_name: []const u8) ?[]const u8 {
        \\    if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "fields")) {
        \\        for (T.zigar_js.fields) |fm| {
        \\            if (std.mem.eql(u8, fm.name, wire_name)) {
        \\                return if (@hasField(@TypeOf(fm), "zig_name")) fm.zig_name else fm.name;
        \\            }
        \\        }
        \\    }
        \\    if (@hasField(T, wire_name)) return wire_name;
        \\    return null;
        \\}
        \\
        \\fn projectFieldValue(comptime DstT: type, src_val: anytype) DstT {
        \\    const SrcT = @TypeOf(src_val);
        \\    if (SrcT == DstT) return src_val;
        \\    if (@typeInfo(DstT) == .optional and @typeInfo(SrcT) == .optional) {
        \\        const ChildT = @typeInfo(DstT).optional.child;
        \\        return if (src_val) |sv| projectFieldValue(ChildT, sv) else null;
        \\    }
        \\    if (@typeInfo(DstT) == .optional) {
        \\        const ChildT = @typeInfo(DstT).optional.child;
        \\        return projectFieldValue(ChildT, src_val);
        \\    }
        \\    if (@typeInfo(DstT) == .@"enum" and @typeInfo(SrcT) == .@"enum") {
        \\        return switch (src_val) {
        \\            inline else => |tag| @field(DstT, @tagName(tag)),
        \\        };
        \\    }
        \\    if (@typeInfo(DstT) == .@"union") {
        \\        if (@typeInfo(SrcT) == .@"union" and @typeInfo(SrcT).@"union".tag_type != null and @typeInfo(DstT).@"union".tag_type != null) {
        \\            return switch (src_val) {
        \\                inline else => |payload, tag| @unionInit(
        \\                    DstT,
        \\                    @tagName(tag),
        \\                    projectFieldValue(@FieldType(DstT, @tagName(tag)), payload),
        \\                ),
        \\            };
        \\        }
        \\        return coerceUnion(DstT, src_val);
        \\    }
        \\    if (@typeInfo(DstT) == .@"struct" and @typeInfo(SrcT) == .@"struct") {
        \\        if (comptime (isJsValueStruct(SrcT) and isJsValueStruct(DstT))) {
        \\            return .{ .handle = src_val.handle };
        \\        }
        \\        if (comptime (isGeneratedHandleStruct(SrcT) and isGeneratedHandleStruct(DstT))) {
        \\            const src_rf = comptime generatedHandleRefFieldName(SrcT);
        \\            const dst_rf = comptime generatedHandleRefFieldName(DstT);
        \\            var out_h: DstT = undefined;
        \\            @field(out_h, dst_rf) = .{ .handle = @field(src_val, src_rf).handle };
        \\            return out_h;
        \\        }
        \\        var out_s: DstT = undefined;
        \\        const dst_info = @typeInfo(DstT).@"struct";
        \\        inline for (dst_info.field_names, 0..) |df_name, dfi| {
        \\            const FieldT = dst_info.field_types[dfi];
        \\            const wire = comptime structWireNameForField(DstT, df_name);
        \\            if (comptime findStructFieldByWireName(SrcT, wire)) |src_fname| {
        \\                @field(out_s, df_name) = projectFieldValue(FieldT, @field(src_val, src_fname));
        \\            } else if (dst_info.field_attrs[dfi].default_value_ptr) |opaque_ptr| {
        \\                const def_ptr: *const FieldT = @ptrCast(@alignCast(opaque_ptr));
        \\                @field(out_s, df_name) = def_ptr.*;
        \\            } else if (@typeInfo(FieldT) == .optional) {
        \\                @field(out_s, df_name) = null;
        \\            } else {
        \\                @compileError("Cannot project missing required base field '" ++ df_name ++ "' from " ++ @typeName(SrcT) ++ " to " ++ @typeName(DstT));
        \\            }
        \\        }
        \\        return out_s;
        \\    }
        \\    return src_val;
        \\}
        \\
        \\pub fn upcastValue(comptime SelfT: type, self: SelfT, comptime Base: type) Base {
        \\    if (has_host) return raw_js.upcastValue(SelfT, self, Base);
        \\    comptime {
        \\        if (!isAssignableType(SelfT, Base)) {
        \\            @compileError(@typeName(SelfT) ++ " does not inherit from or implement " ++ @typeName(Base));
        \\        }
        \\    }
        \\    return projectFieldValue(Base, self);
        \\}
        \\
        \\pub fn cloneHandle(comptime SelfT: type, self: SelfT) CallError!SelfT {
        \\    comptime {
        \\        if (!isGeneratedHandleStruct(SelfT)) {
        \\            @compileError("cloneHandle requires a JS handle wrapper struct, received " ++ @typeName(SelfT));
        \\        }
        \\    }
        \\    if (!has_host) return error.HostUnavailable;
        \\    return try raw_js.cloneHandle(SelfT, self);
        \\}
        \\
        \\pub fn downcastHandle(comptime Sub: type, self_ref: anytype) CallError!?Sub {
        \\    comptime {
        \\        if (!isGeneratedHandleStruct(Sub)) {
        \\            @compileError("tryAs target " ++ @typeName(Sub) ++ " must be a JS handle wrapper struct");
        \\        }
        \\    }
        \\    if (!has_host) return error.HostUnavailable;
        \\    return try raw_js.downcastHandle(Sub, self_ref);
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
        \\pub fn StubCallback(comptime JsFnSig: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        pub const is_zig_callback = true;
        \\        pub const FnPtr = *const JsFnSig;
        \\        pub fn Signature() type {
        \\            return JsFnSig;
        \\        }
        \\
        \\        id: u32 = 0,
        \\        func: Function = Function.@"undefined",
        \\
        \\        pub fn tryInitFn(comptime _: anytype) CallError!Self {
        \\            return error.HostUnavailable;
        \\        }
        \\        pub fn initFn(comptime _: anytype) Self {
        \\            @panic("ts-zigar host unavailable");
        \\        }
        \\        pub fn tryOnceFn(comptime _: anytype) CallError!Self {
        \\            return error.HostUnavailable;
        \\        }
        \\        pub fn onceFn(comptime _: anytype) Self {
        \\            @panic("ts-zigar host unavailable");
        \\        }
        \\        pub fn tryInitFnPtr(_: anytype) CallError!Self {
        \\            return error.HostUnavailable;
        \\        }
        \\        pub fn initFnPtr(_: anytype) Self {
        \\            @panic("ts-zigar host unavailable");
        \\        }
        \\        pub fn tryOnceFnPtr(_: anytype) CallError!Self {
        \\            return error.HostUnavailable;
        \\        }
        \\        pub fn onceFnPtr(_: anytype) Self {
        \\            @panic("ts-zigar host unavailable");
        \\        }
        \\        pub fn ref(self: Self) Function {
        \\            return self.func;
        \\        }
        \\        pub fn toRef(self: Self) Function {
        \\            return self.func;
        \\        }
        \\        pub fn value(self: Self) Function {
        \\            return self.func;
        \\        }
        \\        pub fn isValid(self: Self) bool {
        \\            return self.id != 0;
        \\        }
        \\        pub fn isActive(self: Self) bool {
        \\            return self.id != 0;
        \\        }
        \\        pub fn deinit(_: anytype) void {}
        \\    };
        \\}
        \\
        \\pub fn StubClosure(comptime Ctx: type, comptime FnOrSig: anytype) type {
        \\    return struct {
        \\        const Self = @This();
        \\        pub const is_zig_callback = true;
        \\        pub const Context = Ctx;
        \\        pub const HandlerSpec = FnOrSig;
        \\
        \\        id: u32 = 0,
        \\        func: Function = Function.@"undefined",
        \\
        \\        pub fn tryInit(_: Ctx) CallError!Self {
        \\            return error.HostUnavailable;
        \\        }
        \\        pub fn init(_: Ctx) Self {
        \\            @panic("ts-zigar host unavailable");
        \\        }
        \\        pub fn tryOnce(_: Ctx) CallError!Self {
        \\            return error.HostUnavailable;
        \\        }
        \\        pub fn once(_: Ctx) Self {
        \\            @panic("ts-zigar host unavailable");
        \\        }
        \\        pub fn ref(self: Self) Function {
        \\            return self.func;
        \\        }
        \\        pub fn toRef(self: Self) Function {
        \\            return self.func;
        \\        }
        \\        pub fn value(self: Self) Function {
        \\            return self.func;
        \\        }
        \\        pub fn isValid(self: Self) bool {
        \\            return self.id != 0;
        \\        }
        \\        pub fn isActive(self: Self) bool {
        \\            return self.id != 0;
        \\        }
        \\        pub fn deinit(_: anytype) void {}
        \\    };
        \\}
        \\
        \\fn CallbackHost(comptime JsFnSig: type) type {
        \\    return raw_js.CallbackWithOptions(JsFnSig, .{ .ref_codec = true });
        \\}
        \\
        \\fn CallbackWithThisHost(comptime JsFnSig: type) type {
        \\    return raw_js.CallbackWithOptions(JsFnSig, .{ .pass_this = true, .ref_codec = true });
        \\}
        \\
        \\fn ClosureHost(comptime Ctx: type, comptime FnOrSig: anytype) type {
        \\    return raw_js.ClosureWithOptions(Ctx, FnOrSig, .{ .ref_codec = true });
        \\}
        \\
        \\pub const Callback = if (has_host) CallbackHost else StubCallback;
        \\pub const CallbackWithThis = if (has_host) CallbackWithThisHost else StubCallback;
        \\pub const Closure = if (has_host) ClosureHost else StubClosure;
        \\pub const ClosureWithThis = if (has_host) raw_js.ClosureWithThis else StubClosure;
        \\
        \\pub fn activeCallbackCount() u32 {
        \\    if (has_host) return raw_js.activeCallbackCount();
        \\    return 0;
        \\}
        \\
        \\fn UnwrapCallbackFnType(comptime T: type) type {
        \\    return switch (@typeInfo(T)) {
        \\        .@"fn" => T,
        \\        .pointer => |pt| if (pt.size == .one and @typeInfo(pt.child) == .@"fn")
        \\            pt.child
        \\        else
        \\            @compileError("Expected Zig function or `*const fn`, received " ++ @typeName(T)),
        \\        else => @compileError("Expected Zig function or `*const fn`, received " ++ @typeName(T)),
        \\    };
        \\}
        \\
        \\fn NormalizeCallbackFnSig(comptime FnT: type) type {
        \\    const f = @typeInfo(UnwrapCallbackFnType(FnT)).@"fn";
        \\    var param_types: [f.param_types.len]type = undefined;
        \\    var param_attrs: [f.param_types.len]std.builtin.Type.Fn.ParamAttributes = undefined;
        \\    for (f.param_types, 0..) |maybe_pt, i| {
        \\        param_types[i] = maybe_pt orelse @compileError("Callback parameter types cannot be `anytype`");
        \\        param_attrs[i] = .{};
        \\    }
        \\    const raw_rt = f.return_type orelse void;
        \\    const norm_rt = switch (@typeInfo(raw_rt)) {
        \\        .error_union => |eu| if (@typeInfo(eu.error_set).error_set.error_names == null) eu.payload else raw_rt,
        \\        else => raw_rt,
        \\    };
        \\    return @Fn(&param_types, &param_attrs, norm_rt, .{});
        \\}
        \\
        \\pub fn OnceFn(comptime FnT: type) type {
        \\    return struct {
        \\        pub const is_zigar_once_fn = true;
        \\        pub const FnType = FnT;
        \\        ptr: *const FnT,
        \\    };
        \\}
        \\
        \\pub fn once(cb: anytype) OnceFn(UnwrapCallbackFnType(@TypeOf(cb))) {
        \\    const T = @TypeOf(cb);
        \\    return switch (@typeInfo(T)) {
        \\        .@"fn" => .{ .ptr = &cb },
        \\        .pointer => .{ .ptr = cb },
        \\        else => unreachable,
        \\    };
        \\}
        \\
        \\pub fn InlineClosure(comptime CtxPtrT: type, comptime handler: anytype, comptime once_mode: bool) type {
        \\    return struct {
        \\        pub const is_zigar_inline_closure = true;
        \\        pub const is_once = once_mode;
        \\        pub const ContextPtr = CtxPtrT;
        \\        pub const handler_fn = switch (@typeInfo(@TypeOf(handler))) {
        \\            .pointer => handler.*,
        \\            .@"fn" => handler,
        \\            else => @compileError("Expected handler function in closure(), received " ++ @typeName(@TypeOf(handler))),
        \\        };
        \\        ctx: CtxPtrT,
        \\    };
        \\}
        \\
        \\pub fn closure(ctx_ptr: anytype, comptime handler: anytype) InlineClosure(@TypeOf(ctx_ptr), handler, false) {
        \\    return .{ .ctx = ctx_ptr };
        \\}
        \\
        \\pub fn onceClosure(ctx_ptr: anytype, comptime handler: anytype) InlineClosure(@TypeOf(ctx_ptr), handler, true) {
        \\    return .{ .ctx = ctx_ptr };
        \\}
        \\
        \\pub fn ScopedCallback(comptime expects_this: bool, comptime ArgT: type) type {
        \\    const Mode = enum {
        \\        null_lit,
        \\        optional_arg,
        \\        once_fn,
        \\        inline_closure_sync,
        \\        inline_closure_once,
        \\        sync_bare_fn,
        \\        sync_fn_ptr,
        \\        passthrough,
        \\    };
        \\    const mode: Mode = blk: {
        \\        if (ArgT == @TypeOf(null)) break :blk .null_lit;
        \\        switch (@typeInfo(ArgT)) {
        \\            .optional => break :blk .optional_arg,
        \\            .@"fn" => break :blk .sync_bare_fn,
        \\            .pointer => |pt| {
        \\                if (pt.size == .one and @typeInfo(pt.child) == .@"fn") break :blk .sync_fn_ptr;
        \\                break :blk .passthrough;
        \\            },
        \\            .@"struct" => {
        \\                if (@hasDecl(ArgT, "is_zigar_once_fn") and ArgT.is_zigar_once_fn) break :blk .once_fn;
        \\                if (@hasDecl(ArgT, "is_zigar_inline_closure") and ArgT.is_zigar_inline_closure) {
        \\                    break :blk if (ArgT.is_once) .inline_closure_once else .inline_closure_sync;
        \\                }
        \\                break :blk .passthrough;
        \\            },
        \\            else => break :blk .passthrough,
        \\        }
        \\    };
        \\
        \\    const RegType = switch (mode) {
        \\        .optional_arg => ScopedCallback(expects_this, @typeInfo(ArgT).optional.child),
        \\        .once_fn => if (has_host)
        \\            raw_js.CallbackWithOptions(NormalizeCallbackFnSig(ArgT.FnType), .{ .pass_this = expects_this, .ref_codec = true })
        \\        else
        \\            StubCallback(NormalizeCallbackFnSig(ArgT.FnType)),
        \\        .sync_bare_fn => if (has_host)
        \\            raw_js.CallbackWithOptions(NormalizeCallbackFnSig(ArgT), .{ .pass_this = expects_this, .ref_codec = true })
        \\        else
        \\            StubCallback(NormalizeCallbackFnSig(ArgT)),
        \\        .sync_fn_ptr => if (has_host)
        \\            raw_js.CallbackWithOptions(NormalizeCallbackFnSig(@typeInfo(ArgT).pointer.child), .{ .pass_this = expects_this, .ref_codec = true })
        \\        else
        \\            StubCallback(NormalizeCallbackFnSig(@typeInfo(ArgT).pointer.child)),
        \\        .inline_closure_sync, .inline_closure_once => if (has_host)
        \\            raw_js.ClosureWithOptions(ArgT.ContextPtr, ArgT.handler_fn, .{ .pass_this = expects_this, .ref_codec = true })
        \\        else
        \\            StubClosure(ArgT.ContextPtr, ArgT.handler_fn),
        \\        .null_lit, .passthrough => void,
        \\    };
        \\
        \\    return struct {
        \\        const Self = @This();
        \\        state: switch (mode) {
        \\            .optional_arg => RegType,
        \\            .sync_bare_fn, .sync_fn_ptr, .inline_closure_sync => ?RegType,
        \\            else => void,
        \\        } = switch (mode) {
        \\            .optional_arg => .{},
        \\            .sync_bare_fn, .sync_fn_ptr, .inline_closure_sync => null,
        \\            else => {},
        \\        },
        \\
        \\        pub fn push(self: *Self, args: Args, value: ArgT, comptime spec: anytype) CallError!void {
        \\            if (!has_host) return error.HostUnavailable;
        \\            switch (mode) {
        \\                .null_lit => try pushArg(args, value, spec),
        \\                .optional_arg => {
        \\                    if (value) |inner| {
        \\                        try self.state.push(args, inner, spec);
        \\                    } else {
        \\                        try pushArg(args, @as(ArgT, null), spec);
        \\                    }
        \\                },
        \\                .once_fn => {
        \\                    var reg = try RegType.tryOnceFnPtr(value.ptr);
        \\                    errdefer reg.deinit();
        \\                    _ = try args.push(Any{ .handle = reg.func.handle });
        \\                },
        \\                .inline_closure_once => {
        \\                    var reg = try RegType.tryOnce(value.ctx);
        \\                    errdefer reg.deinit();
        \\                    _ = try args.push(Any{ .handle = reg.func.handle });
        \\                },
        \\                .inline_closure_sync => {
        \\                    self.state = try RegType.tryInit(value.ctx);
        \\                    _ = try args.push(Any{ .handle = self.state.?.func.handle });
        \\                },
        \\                .sync_bare_fn => {
        \\                    self.state = try RegType.tryInitFnPtr(&value);
        \\                    _ = try args.push(Any{ .handle = self.state.?.func.handle });
        \\                },
        \\                .sync_fn_ptr => {
        \\                    self.state = try RegType.tryInitFnPtr(value);
        \\                    _ = try args.push(Any{ .handle = self.state.?.func.handle });
        \\                },
        \\                .passthrough => try pushArg(args, value, spec),
        \\            }
        \\        }
        \\
        \\        pub fn deinit(self: *Self) void {
        \\            switch (mode) {
        \\                .optional_arg => self.state.deinit(),
        \\                .sync_bare_fn, .sync_fn_ptr, .inline_closure_sync => {
        \\                    if (self.state) |*r| {
        \\                        r.deinit();
        \\                        self.state = null;
        \\                    }
        \\                },
        \\                else => {},
        \\            }
        \\        }
        \\    };
        \\}
        \\
        \\fn isTupleType(comptime T: type) bool {
        \\    return switch (@typeInfo(T)) {
        \\        .@"struct" => |st| st.is_tuple,
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn pushCallableTupleArgs(comptime FnSig: type, js_args: Args, call_args: anytype) CallError!void {
        \\    const fni = @typeInfo(FnSig).@"fn";
        \\    const param_len = fni.param_types.len;
        \\    const CallArgsT = @TypeOf(call_args);
        \\    if (comptime (param_len == 1 and !isTupleType(CallArgsT))) {
        \\        const P0 = fni.param_types[0].?;
        \\        const coerced = coerceArgToParam(P0, call_args);
        \\        try pushArg(js_args, coerced, .null_or_undefined);
        \\        return;
        \\    }
        \\    if (comptime !isTupleType(CallArgsT)) {
        \\        @compileError("Expected tuple of arguments `.{ ... }` for Callable.call, received " ++ @typeName(CallArgsT));
        \\    }
        \\    const tst = @typeInfo(CallArgsT).@"struct";
        \\    const argc = tst.field_types.len;
        \\    if (comptime argc > param_len) {
        \\        @compileError("Too many arguments passed to Callable.call");
        \\    }
        \\    inline for (0..argc) |i| {
        \\        const ParamT = fni.param_types[i].?;
        \\        const coerced = coerceArgToParam(ParamT, call_args[i]);
        \\        try pushArg(js_args, coerced, .null_or_undefined);
        \\    }
        \\    inline for (argc..param_len) |i| {
        \\        const ParamT = fni.param_types[i].?;
        \\        if (comptime @typeInfo(ParamT) != .optional) {
        \\            @compileError("Missing required argument in Callable.call");
        \\        }
        \\    }
        \\}
        \\
        \\fn CallableReturnPayload(comptime FnSig: type) type {
        \\    const fni = switch (@typeInfo(FnSig)) {
        \\        .@"fn" => |fi| fi,
        \\        else => @compileError("Callable expects `fn (...) Ret`, received " ++ @typeName(FnSig)),
        \\    };
        \\    return fni.return_type orelse void;
        \\}
        \\
        \\pub fn Callable(comptime FnSig: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        pub const FnPtr = *const FnSig;
        \\        pub fn Signature() type {
        \\            return FnSig;
        \\        }
        \\        pub fn ReturnPayload() type {
        \\            return CallableReturnPayload(FnSig);
        \\        }
        \\        pub const zigar_js = .{
        \\            .is_handle = true,
        \\            .is_callable_handle = true,
        \\            .ref_field = "ref",
        \\        };
        \\
        \\        ref: JsFunction = JsFunction.@"undefined",
        \\
        \\        pub fn deinit(self: Self) void {
        \\            self.ref.deinit();
        \\        }
        \\
        \\        pub fn clone(self: Self) CallError!Self {
        \\            return try cloneHandle(Self, self);
        \\        }
        \\
        \\        pub fn toRef(self: Self) Any {
        \\            return .{ .handle = self.ref.handle };
        \\        }
        \\
        \\        pub fn fromRef(raw: anytype) CallError!Self {
        \\            return try fromJsRef(Self, raw);
        \\        }
        \\
        \\        pub fn fromCallback(cb: anytype) CallError!Self {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const CbT = @TypeOf(cb);
        \\            const fn_ref = switch (@typeInfo(CbT)) {
        \\                .pointer => cb.*.func,
        \\                else => cb.func,
        \\            };
        \\            const cloned = try fn_ref.tryClone();
        \\            return .{ .ref = .{ .handle = cloned.handle } };
        \\        }
        \\
        \\        pub fn fromOnceFn(cb: anytype) CallError!Self {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const FnT = UnwrapCallbackFnType(@TypeOf(cb));
        \\            const RegT = CallbackHost(NormalizeCallbackFnSig(FnT));
        \\            const ptr: *const FnT = switch (@typeInfo(@TypeOf(cb))) {
        \\                .@"fn" => &cb,
        \\                .pointer => cb,
        \\                else => unreachable,
        \\            };
        \\            var reg = try RegT.tryOnceFnPtr(ptr);
        \\            errdefer reg.deinit();
        \\            const cloned = try reg.func.tryClone();
        \\            return .{ .ref = .{ .handle = cloned.handle } };
        \\        }
        \\
        \\        pub fn fromOnceClosure(ctx_ptr: anytype, comptime handler: anytype) CallError!Self {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const h_fn = switch (@typeInfo(@TypeOf(handler))) {
        \\                .pointer => handler.*,
        \\                .@"fn" => handler,
        \\                else => @compileError("Expected handler function"),
        \\            };
        \\            const RegT = ClosureHost(@TypeOf(ctx_ptr), h_fn);
        \\            var reg = try RegT.tryOnce(ctx_ptr);
        \\            errdefer reg.deinit();
        \\            const cloned = try reg.func.tryClone();
        \\            return .{ .ref = .{ .handle = cloned.handle } };
        \\        }
        \\
        \\        pub fn call(self: Self, call_args: anytype) CallError!CallableReturnPayload(FnSig) {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const RetPayload = CallableReturnPayload(FnSig);
        \\            const js_args = try initArgs();
        \\            defer js_args.deinit();
        \\            try pushCallableTupleArgs(FnSig, js_args, call_args);
        \\            return try invokeCallable(RetPayload, self.ref, js_args);
        \\        }
        \\
        \\        pub fn callAlloc(self: Self, allocator: std.mem.Allocator, call_args: anytype) CallError!CallableReturnPayload(FnSig) {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const RetPayload = CallableReturnPayload(FnSig);
        \\            const js_args = try initArgs();
        \\            defer js_args.deinit();
        \\            try pushCallableTupleArgs(FnSig, js_args, call_args);
        \\            return try invokeCallableAlloc(RetPayload, allocator, self.ref, js_args);
        \\        }
        \\    };
        \\}
        \\
        \\pub fn CallableWithThis(comptime ThisT: type, comptime FnSig: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        pub const ThisType = ThisT;
        \\        pub const FnPtr = *const FnSig;
        \\        pub fn Signature() type {
        \\            return FnSig;
        \\        }
        \\        pub fn ReturnPayload() type {
        \\            return CallableReturnPayload(FnSig);
        \\        }
        \\        pub const zigar_js = .{
        \\            .is_handle = true,
        \\            .is_callable_handle = true,
        \\            .ref_field = "ref",
        \\        };
        \\
        \\        ref: JsFunction = JsFunction.@"undefined",
        \\
        \\        pub fn deinit(self: Self) void {
        \\            self.ref.deinit();
        \\        }
        \\
        \\        pub fn clone(self: Self) CallError!Self {
        \\            return try cloneHandle(Self, self);
        \\        }
        \\
        \\        pub fn toRef(self: Self) Any {
        \\            return .{ .handle = self.ref.handle };
        \\        }
        \\
        \\        pub fn fromRef(raw: anytype) CallError!Self {
        \\            return try fromJsRef(Self, raw);
        \\        }
        \\
        \\        pub fn fromCallback(cb: anytype) CallError!Self {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const CbT = @TypeOf(cb);
        \\            const fn_ref = switch (@typeInfo(CbT)) {
        \\                .pointer => cb.*.func,
        \\                else => cb.func,
        \\            };
        \\            const cloned = try fn_ref.tryClone();
        \\            return .{ .ref = .{ .handle = cloned.handle } };
        \\        }
        \\
        \\        pub fn fromOnceFn(cb: anytype) CallError!Self {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const FnT = UnwrapCallbackFnType(@TypeOf(cb));
        \\            const RegT = CallbackWithThisHost(NormalizeCallbackFnSig(FnT));
        \\            const ptr: *const FnT = switch (@typeInfo(@TypeOf(cb))) {
        \\                .@"fn" => &cb,
        \\                .pointer => cb,
        \\                else => unreachable,
        \\            };
        \\            var reg = try RegT.tryOnceFnPtr(ptr);
        \\            errdefer reg.deinit();
        \\            const cloned = try reg.func.tryClone();
        \\            return .{ .ref = .{ .handle = cloned.handle } };
        \\        }
        \\
        \\        pub fn fromOnceClosure(ctx_ptr: anytype, comptime handler: anytype) CallError!Self {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const h_fn = switch (@typeInfo(@TypeOf(handler))) {
        \\                .pointer => handler.*,
        \\                .@"fn" => handler,
        \\                else => @compileError("Expected handler function"),
        \\            };
        \\            const RegT = raw_js.ClosureWithThis(@TypeOf(ctx_ptr), h_fn);
        \\            var reg = try RegT.tryOnce(ctx_ptr);
        \\            errdefer reg.deinit();
        \\            const cloned = try reg.func.tryClone();
        \\            return .{ .ref = .{ .handle = cloned.handle } };
        \\        }
        \\
        \\        pub fn call(self: Self, this_arg: ThisT, call_args: anytype) CallError!CallableReturnPayload(FnSig) {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const RetPayload = CallableReturnPayload(FnSig);
        \\            const js_args = try initArgs();
        \\            defer js_args.deinit();
        \\            try pushCallableTupleArgs(FnSig, js_args, call_args);
        \\            return try invokeCallableWithThis(RetPayload, self.ref, this_arg, .null_or_undefined, js_args);
        \\        }
        \\
        \\        pub fn callAlloc(self: Self, allocator: std.mem.Allocator, this_arg: ThisT, call_args: anytype) CallError!CallableReturnPayload(FnSig) {
        \\            if (!has_host) return error.HostUnavailable;
        \\            const RetPayload = CallableReturnPayload(FnSig);
        \\            const js_args = try initArgs();
        \\            defer js_args.deinit();
        \\            try pushCallableTupleArgs(FnSig, js_args, call_args);
        \\            return try invokeCallableWithThisAlloc(RetPayload, allocator, self.ref, this_arg, .null_or_undefined, js_args);
        \\        }
        \\    };
        \\}
        \\
        \\pub fn isNullArg(val: anytype) bool {
        \\    const T = @TypeOf(val);
        \\    if (T == @TypeOf(null)) return true;
        \\    return switch (@typeInfo(T)) {
        \\        .optional => val == null,
        \\        else => false,
        \\    };
        \\}
        \\
        \\pub fn SliceElem(comptime T: type) type {
        \\    return switch (@typeInfo(T)) {
        \\        .pointer => |pt| if (pt.size == .slice) pt.child else u8,
        \\        else => u8,
        \\    };
        \\}
        \\
        \\pub fn variadicIsEmpty(comptime ElemT: type, rest: anytype) bool {
        \\    const RestT = @TypeOf(rest);
        \\    if (comptime isTupleType(RestT)) {
        \\        return @typeInfo(RestT).@"struct".field_types.len == 0;
        \\    }
        \\    if (comptime (@typeInfo(RestT) == .pointer and @typeInfo(RestT).pointer.size == .one and isTupleType(@typeInfo(RestT).pointer.child))) {
        \\        return @typeInfo(@typeInfo(RestT).pointer.child).@"struct".field_types.len == 0;
        \\    }
        \\    if (comptime (RestT == []const ElemT or RestT == []ElemT)) {
        \\        return rest.len == 0;
        \\    }
        \\    if (comptime (@typeInfo(RestT) == .pointer and @typeInfo(RestT).pointer.size == .one and @typeInfo(@typeInfo(RestT).pointer.child) == .array and @typeInfo(@typeInfo(RestT).pointer.child).array.child == ElemT)) {
        \\        return @typeInfo(@typeInfo(RestT).pointer.child).array.len == 0;
        \\    }
        \\    return false;
        \\}
        \\
        \\pub fn pushVariadicArgs(
        \\    comptime ElemT: type,
        \\    args: Args,
        \\    rest: anytype,
        \\    comptime elem_spec: anytype,
        \\) CallError!void {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const RestT = @TypeOf(rest);
        \\    if (comptime isTupleType(RestT)) {
        \\        const tst = @typeInfo(RestT).@"struct";
        \\        inline for (0..tst.field_types.len) |i| {
        \\            if (comptime (ElemT == Any or ElemT == Unknown)) {
        \\                try pushArg(args, rest[i], elem_spec);
        \\            } else {
        \\                const coerced = coerceArgToParam(ElemT, rest[i]);
        \\                try pushArg(args, coerced, elem_spec);
        \\            }
        \\        }
        \\        return;
        \\    }
        \\    if (comptime (@typeInfo(RestT) == .pointer and @typeInfo(RestT).pointer.size == .one and isTupleType(@typeInfo(RestT).pointer.child))) {
        \\        const tst = @typeInfo(@typeInfo(RestT).pointer.child).@"struct";
        \\        inline for (0..tst.field_types.len) |i| {
        \\            if (comptime (ElemT == Any or ElemT == Unknown)) {
        \\                try pushArg(args, rest.*[i], elem_spec);
        \\            } else {
        \\                const coerced = coerceArgToParam(ElemT, rest.*[i]);
        \\                try pushArg(args, coerced, elem_spec);
        \\            }
        \\        }
        \\        return;
        \\    }
        \\    if (comptime (RestT == []const ElemT or RestT == []ElemT)) {
        \\        for (rest) |item| {
        \\            try pushArg(args, item, elem_spec);
        \\        }
        \\        return;
        \\    }
        \\    if (comptime (@typeInfo(RestT) == .pointer and @typeInfo(RestT).pointer.size == .one and @typeInfo(@typeInfo(RestT).pointer.child) == .array and @typeInfo(@typeInfo(RestT).pointer.child).array.child == ElemT)) {
        \\        for (rest) |item| {
        \\            try pushArg(args, item, elem_spec);
        \\        }
        \\        return;
        \\    }
        \\    if (comptime (ElemT == Any or ElemT == Unknown)) {
        \\        try pushArg(args, rest, elem_spec);
        \\    } else {
        \\        const coerced = coerceArgToParam(ElemT, rest);
        \\        try pushArg(args, coerced, elem_spec);
        \\    }
        \\}
        \\
        \\fn invokeRawTargetWithThis(
        \\    comptime target: CallTarget,
        \\    this_arg: anytype,
        \\    comptime this_spec: anytype,
        \\    args: Args,
        \\) CallError!Any {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const callee = try getGlobalTargetRaw(target);
        \\    defer callee.deinit();
        \\    if ((try callee.tryTypeof()) != .function) {
        \\        return error.NotCallable;
        \\    }
        \\    const recv = try toJsRefWithSpec(@TypeOf(this_arg), this_arg, this_spec);
        \\    defer recv.deinit();
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
        \\pub fn invokeTargetWithThis(
        \\    comptime T: type,
        \\    comptime target: CallTarget,
        \\    this_arg: anytype,
        \\    comptime this_spec: anytype,
        \\    args: Args,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try invokeRawTargetWithThis(target, this_arg, this_spec, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) return error.Unexpected;
        \\    return try fromJsRef(T, raw);
        \\}
        \\
        \\pub fn invokeTargetWithThisAlloc(
        \\    comptime T: type,
        \\    allocator: std.mem.Allocator,
        \\    comptime target: CallTarget,
        \\    this_arg: anytype,
        \\    comptime this_spec: anytype,
        \\    args: Args,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try invokeRawTargetWithThis(target, this_arg, this_spec, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) return error.Unexpected;
        \\    return try fromJsRefAlloc(T, allocator, raw);
        \\}
        \\
        \\fn invokeRawCallableWithThis(
        \\    self_ref: anytype,
        \\    this_arg: anytype,
        \\    comptime this_spec: anytype,
        \\    args: Args,
        \\) CallError!Any {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const callee: Any = .{ .handle = self_ref.handle };
        \\    if ((try callee.tryTypeof()) != .function) {
        \\        return error.NotCallable;
        \\    }
        \\    const recv = try toJsRefWithSpec(@TypeOf(this_arg), this_arg, this_spec);
        \\    defer recv.deinit();
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
        \\pub fn invokeCallableWithThis(
        \\    comptime T: type,
        \\    self_ref: anytype,
        \\    this_arg: anytype,
        \\    comptime this_spec: anytype,
        \\    args: Args,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try invokeRawCallableWithThis(self_ref, this_arg, this_spec, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) return error.Unexpected;
        \\    return try fromJsRef(T, raw);
        \\}
        \\
        \\pub fn invokeCallableWithThisAlloc(
        \\    comptime T: type,
        \\    allocator: std.mem.Allocator,
        \\    self_ref: anytype,
        \\    this_arg: anytype,
        \\    comptime this_spec: anytype,
        \\    args: Args,
        \\) CallError!T {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const raw = try invokeRawCallableWithThis(self_ref, this_arg, this_spec, args);
        \\    defer raw.deinit();
        \\    if (T == noreturn) return error.Unexpected;
        \\    return try fromJsRefAlloc(T, allocator, raw);
        \\}
        \\
        \\pub fn narrowJsValue(comptime TargetT: type, subject: anytype) CallError!TargetT {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const SubjectT = @TypeOf(subject);
        \\    if (comptime isJsValueStruct(SubjectT)) {
        \\        const raw: Any = .{ .handle = subject.handle };
        \\        return try fromJsRef(TargetT, raw);
        \\    }
        \\    if (comptime isGeneratedHandleStruct(SubjectT)) {
        \\        const rf = comptime generatedHandleRefFieldName(SubjectT);
        \\        const raw: Any = .{ .handle = @field(subject, rf).handle };
        \\        return try fromJsRef(TargetT, raw);
        \\    }
        \\    const raw = try toJsRef(SubjectT, subject);
        \\    defer raw.deinit();
        \\    return try fromJsRef(TargetT, raw);
        \\}
        \\
        \\pub fn narrowJsValueAlloc(comptime TargetT: type, allocator: std.mem.Allocator, subject: anytype) CallError!TargetT {
        \\    if (!has_host) return error.HostUnavailable;
        \\    const SubjectT = @TypeOf(subject);
        \\    if (comptime isJsValueStruct(SubjectT)) {
        \\        const raw: Any = .{ .handle = subject.handle };
        \\        return try fromJsRefAlloc(TargetT, allocator, raw);
        \\    }
        \\    if (comptime isGeneratedHandleStruct(SubjectT)) {
        \\        const rf = comptime generatedHandleRefFieldName(SubjectT);
        \\        const raw: Any = .{ .handle = @field(subject, rf).handle };
        \\        return try fromJsRefAlloc(TargetT, allocator, raw);
        \\    }
        \\    const raw = try toJsRef(SubjectT, subject);
        \\    defer raw.deinit();
        \\    return try fromJsRefAlloc(TargetT, allocator, raw);
        \\}
        \\
        \\fn isCallbackLikeArg(comptime ArgT: type) bool {
        \\    return switch (@typeInfo(ArgT)) {
        \\        .@"fn" => true,
        \\        .pointer => |pt| pt.size == .one and (
        \\            @typeInfo(pt.child) == .@"fn" or
        \\            (@typeInfo(pt.child) == .@"struct" and @hasDecl(pt.child, "is_zig_callback"))
        \\        ),
        \\        .@"struct" => @hasDecl(ArgT, "is_zig_callback") or
        \\            @hasDecl(ArgT, "is_zigar_once_fn") or
        \\            @hasDecl(ArgT, "is_zigar_inline_closure") or
        \\            (isJsValueStruct(ArgT) and (ArgT == Function or ArgT == Any or ArgT == Unknown)) or
        \\            (isGeneratedHandleStruct(ArgT) and @hasField(@TypeOf(ArgT.zigar_js), "is_callable_handle") and ArgT.zigar_js.is_callable_handle),
        \\        .optional => |opt| isCallbackLikeArg(opt.child),
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn canCoerceToUnion(comptime U: type, comptime ArgT: type) bool {
        \\    const un = @typeInfo(U).@"union";
        \\    comptime var exact_count: usize = 0;
        \\    inline for (un.field_types) |FT| {
        \\        if (FT != void and FT == ArgT) exact_count += 1;
        \\    }
        \\    if (exact_count == 1) return true;
        \\    if (isStringSliceCoercible(ArgT)) {
        \\        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
        \\            for (U.zigar_js.variants) |v| {
        \\                if (@hasField(@TypeOf(v), "str_value")) return true;
        \\            }
        \\        }
        \\        comptime var str_count: usize = 0;
        \\        inline for (un.field_types) |FT| {
        \\            if (FT == []const u8) str_count += 1;
        \\        }
        \\        if (str_count == 1) return true;
        \\    }
        \\    const ai = @typeInfo(ArgT);
        \\    if (ArgT == f64 or ai == .comptime_float or ai == .comptime_int) {
        \\        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
        \\            for (U.zigar_js.variants) |v| {
        \\                if (@hasField(@TypeOf(v), "num_value")) return true;
        \\                if (ai == .comptime_int and @hasField(@TypeOf(v), "bigint_value")) return true;
        \\            }
        \\        }
        \\        comptime var num_count: usize = 0;
        \\        inline for (un.field_types) |FT| {
        \\            if (FT == f64 or (ai == .comptime_int and (FT == i64 or FT == i32))) num_count += 1;
        \\        }
        \\        if (num_count == 1) return true;
        \\    }
        \\    if (ArgT == bool) {
        \\        if (@hasDecl(U, "zigar_js") and @hasField(@TypeOf(U.zigar_js), "variants")) {
        \\            for (U.zigar_js.variants) |v| {
        \\                if (@hasField(@TypeOf(v), "bool_value")) return true;
        \\            }
        \\        }
        \\    }
        \\    return false;
        \\}
        \\
        \\const OverloadMatchTier = enum(u8) {
        \\    none = 0,
        \\    coerced = 1,
        \\    exact = 2,
        \\    literal_exact = 3,
        \\};
        \\
        \\fn callbackArgMatchScore(comptime ArgT: type, comptime expected_arity: ?usize) ?usize {
        \\    if (!isCallbackLikeArg(ArgT)) return null;
        \\    const unwrapped = switch (@typeInfo(ArgT)) {
        \\        .optional => |opt| opt.child,
        \\        else => ArgT,
        \\    };
        \\    const ea = expected_arity orelse return 20;
        \\    return switch (@typeInfo(unwrapped)) {
        \\        .@"fn" => |fni| if (fni.param_types.len == ea) 25 else null,
        \\        .pointer => |pt| if (pt.size == .one and @typeInfo(pt.child) == .@"fn")
        \\            (if (@typeInfo(pt.child).@"fn".param_types.len == ea) 25 else null)
        \\        else
        \\            20,
        \\        else => 20,
        \\    };
        \\}
        \\
        \\fn argMatchTier(comptime ParamT: type, comptime ArgT: type, comptime arg_attr: ?std.builtin.Type.Struct.FieldAttributes) OverloadMatchTier {
        \\    if (ArgT == ParamT) return .exact;
        \\    if (ArgT == @TypeOf(null)) {
        \\        return if (@typeInfo(ParamT) == .optional) .exact else .none;
        \\    }
        \\    if (@typeInfo(ParamT) == .optional) {
        \\        const ChildT = @typeInfo(ParamT).optional.child;
        \\        if (@typeInfo(ArgT) == .optional) {
        \\            return argMatchTier(ChildT, @typeInfo(ArgT).optional.child, null);
        \\        }
        \\        return argMatchTier(ChildT, ArgT, arg_attr);
        \\    }
        \\    if (ParamT == Any or ParamT == Unknown) {
        \\        if (isJsValueStruct(ArgT) or isGeneratedHandleStruct(ArgT)) return .coerced;
        \\        return .none;
        \\    }
        \\    if (ParamT == []const u8 and isStringSliceCoercible(ArgT)) return .exact;
        \\    switch (@typeInfo(ParamT)) {
        \\        .float => {
        \\            if (@typeInfo(ArgT) == .float or @typeInfo(ArgT) == .comptime_float) return .exact;
        \\            if (@typeInfo(ArgT) == .comptime_int) return .coerced;
        \\        },
        \\        .int => {
        \\            if (@typeInfo(ArgT) == .comptime_int) return .exact;
        \\        },
        \\        .@"enum" => {
        \\            if (@typeInfo(ArgT) == .enum_literal) {
        \\                if (arg_attr) |attr| {
        \\                    if (attr.defaultValue(ArgT)) |lit_val| {
        \\                        return if (@hasField(ParamT, @tagName(lit_val))) .literal_exact else .none;
        \\                    }
        \\                }
        \\                return .coerced;
        \\            }
        \\            if (isStringSliceCoercible(ArgT) and @hasDecl(ParamT, "fromSlice")) {
        \\                if (arg_attr) |attr| {
        \\                    if (attr.defaultValue(ArgT)) |lit_str| {
        \\                        return if (ParamT.fromSlice(lit_str) != null) .literal_exact else .none;
        \\                    }
        \\                }
        \\            }
        \\        },
        \\        .@"union" => {
        \\            if (canCoerceToUnion(ParamT, ArgT)) return .coerced;
        \\        },
        \\        .pointer => |pt| {
        \\            if (pt.size == .slice and pt.attrs.@"const") {
        \\                switch (@typeInfo(ArgT)) {
        \\                    .pointer => |apt| {
        \\                        if (apt.size == .slice and apt.child == pt.child) return .exact;
        \\                        if (apt.size == .one and @typeInfo(apt.child) == .array and @typeInfo(apt.child).array.child == pt.child) return .exact;
        \\                    },
        \\                    else => {},
        \\                }
        \\            }
        \\        },
        \\        .@"struct" => |pst| {
        \\            if (isGeneratedHandleStruct(ParamT)) {
        \\                if (isGeneratedHandleStruct(ArgT) and isAssignableType(ArgT, ParamT)) return .coerced;
        \\                return .none;
        \\            }
        \\            if (isJsValueStruct(ParamT)) return .none;
        \\            if (!pst.is_tuple and @typeInfo(ArgT) == .@"struct") {
        \\                const ast = @typeInfo(ArgT).@"struct";
        \\                if (!ast.is_tuple and !isGeneratedHandleStruct(ArgT) and !isJsValueStruct(ArgT)) {
        \\                    inline for (ast.field_names, 0..) |af_name, afi| {
        \\                        if (!@hasField(ParamT, af_name)) return .none;
        \\                        if (argMatchTier(@FieldType(ParamT, af_name), ast.field_types[afi], ast.field_attrs[afi]) == .none) return .none;
        \\                    }
        \\                    inline for (pst.field_names, 0..) |pf_name, pfi| {
        \\                        if (!@hasField(ArgT, pf_name)) {
        \\                            if (pst.field_attrs[pfi].default_value_ptr == null and @typeInfo(pst.field_types[pfi]) != .optional) {
        \\                                return .none;
        \\                            }
        \\                        }
        \\                    }
        \\                    return .coerced;
        \\                }
        \\            }
        \\        },
        \\        else => {},
        \\    }
        \\    return .none;
        \\}
        \\
        \\fn coerceArgToParam(comptime ParamT: type, arg: anytype) ParamT {
        \\    const ArgT = @TypeOf(arg);
        \\    if (ArgT == ParamT) return arg;
        \\    if (ArgT == @TypeOf(null)) return null;
        \\    if (@typeInfo(ParamT) == .optional) {
        \\        const ChildT = @typeInfo(ParamT).optional.child;
        \\        if (@typeInfo(ArgT) == .optional) {
        \\            return if (arg) |v| coerceArgToParam(ChildT, v) else null;
        \\        }
        \\        return coerceArgToParam(ChildT, arg);
        \\    }
        \\    if (comptime (ParamT == Any or ParamT == Unknown)) {
        \\        if (comptime isJsValueStruct(ArgT)) return .{ .handle = arg.handle };
        \\        if (comptime isGeneratedHandleStruct(ArgT)) {
        \\            const rf = comptime generatedHandleRefFieldName(ArgT);
        \\            return .{ .handle = @field(arg, rf).handle };
        \\        }
        \\    }
        \\    if (ParamT == []const u8 and comptime isStringSliceCoercible(ArgT)) return arg;
        \\    switch (@typeInfo(ParamT)) {
        \\        .float => return @as(ParamT, arg),
        \\        .int => return @as(ParamT, arg),
        \\        .@"enum" => {
        \\            if (comptime (isStringSliceCoercible(ArgT) and @hasDecl(ParamT, "fromSlice"))) {
        \\                return ParamT.fromSlice(arg).?;
        \\            }
        \\            return @as(ParamT, arg);
        \\        },
        \\        .@"union" => return coerceUnion(ParamT, arg),
        \\        .pointer => |pt| {
        \\            if (pt.size == .slice and pt.attrs.@"const") return arg;
        \\        },
        \\        .@"struct" => |pst| {
        \\            if (comptime isGeneratedHandleStruct(ParamT)) {
        \\                return upcastValue(ArgT, arg, ParamT);
        \\            }
        \\            if (!pst.is_tuple and @typeInfo(ArgT) == .@"struct") {
        \\                var out: ParamT = undefined;
        \\                inline for (pst.field_names, 0..) |pf_name, pfi| {
        \\                    const FieldT = pst.field_types[pfi];
        \\                    if (@hasField(ArgT, pf_name)) {
        \\                        @field(out, pf_name) = coerceArgToParam(FieldT, @field(arg, pf_name));
        \\                    } else if (pst.field_attrs[pfi].defaultValue(FieldT)) |def_val| {
        \\                        @field(out, pf_name) = def_val;
        \\                    } else if (@typeInfo(FieldT) == .optional) {
        \\                        @field(out, pf_name) = null;
        \\                    } else {
        \\                        unreachable;
        \\                    }
        \\                }
        \\                return out;
        \\            }
        \\        },
        \\        else => {},
        \\    }
        \\    return arg;
        \\}
        \\
        \\fn dummyForType(comptime T: type) T {
        \\    if (T == type) return u8;
        \\    if (T == @TypeOf(null)) return null;
        \\    if (T == comptime_int) return 0;
        \\    if (T == comptime_float) return 0.0;
        \\    if (@typeInfo(T) == .enum_literal) return .zigar_dummy;
        \\    if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
        \\        var out: T = undefined;
        \\        const st = @typeInfo(T).@"struct";
        \\        inline for (0..st.field_types.len) |i| {
        \\            if (!st.field_attrs[i].@"comptime") {
        \\                out[i] = dummyForType(st.field_types[i]);
        \\            }
        \\        }
        \\        return out;
        \\    }
        \\    return undefined;
        \\}
        \\
        \\fn readComptimeDefault(comptime FT: type, comptime attr: std.builtin.Type.Struct.FieldAttributes) FT {
        \\    if (attr.defaultValue(FT)) |v| return v;
        \\    return dummyForType(FT);
        \\}
        \\
        \\fn candidateUsesExplicitTypeParams(comptime cand: anytype, comptime TupT: type) bool {
        \\    const tp_n: usize = cand.type_param_count;
        \\    if (tp_n == 0) return false;
        \\    const tst = @typeInfo(TupT).@"struct";
        \\    if (tst.field_types.len < tp_n) return false;
        \\    inline for (0..tp_n) |ti| {
        \\        if (tst.field_types[ti] != type or !tst.field_attrs[ti].@"comptime") return false;
        \\    }
        \\    return true;
        \\}
        \\
        \\fn tryInferOverloadParamType(
        \\    comptime mode: anytype,
        \\    comptime ArgT: type,
        \\    comptime arg_attr: std.builtin.Type.Struct.FieldAttributes,
        \\    comptime nullable: bool,
        \\    comptime ConstraintOpt: ?type,
        \\) ?type {
        \\    return switch (mode) {
        \\        .none => null,
        \\        .direct => blk: {
        \\            if (ArgT == @TypeOf(null) and !nullable) break :blk null;
        \\            if (@typeInfo(ArgT) == .enum_literal) {
        \\                if (ConstraintOpt) |CT| {
        \\                    if (argMatchTier(CT, ArgT, arg_attr) != .none) break :blk CT;
        \\                    break :blk null;
        \\                }
        \\                break :blk Any;
        \\            }
        \\            break :blk InferJsType(ArgT);
        \\        },
        \\        .optional_child => blk: {
        \\            if (ArgT == @TypeOf(null)) break :blk Any;
        \\            break :blk InferOptionalChild(ArgT);
        \\        },
        \\        .slice_elem => switch (@typeInfo(ArgT)) {
        \\            .pointer => |p| if (p.size == .slice)
        \\                p.child
        \\            else if (p.size == .one and @typeInfo(p.child) == .array)
        \\                @typeInfo(p.child).array.child
        \\            else
        \\                null,
        \\            .array => |a| a.child,
        \\            else => null,
        \\        },
        \\        .promise_payload => if (@typeInfo(ArgT) == .@"struct" and
        \\            @hasDecl(ArgT, "is_js_promise") and ArgT.is_js_promise and @hasDecl(ArgT, "Payload"))
        \\            ArgT.Payload
        \\        else
        \\            null,
        \\        else => null,
        \\    };
        \\}
        \\
        \\fn candidateScore(
        \\    comptime Owner: type,
        \\    comptime has_self: bool,
        \\    comptime cand: anytype,
        \\    comptime TupT: type,
        \\) ?usize {
        \\    const tst = @typeInfo(TupT).@"struct";
        \\    const tp_n: usize = cand.type_param_count;
        \\    const explicit_tps = candidateUsesExplicitTypeParams(cand, TupT);
        \\    if (tp_n > 0 and !explicit_tps) {
        \\        if (!@hasField(@TypeOf(cand), "infer_fn_name") or cand.infer_fn_name == null) return null;
        \\    }
        \\    const eff_tp_n: usize = if (explicit_tps) tp_n else 0;
        \\    if (explicit_tps) {
        \\        inline for (0..tp_n) |ti| {
        \\            if (@hasField(@TypeOf(cand), "tp_constraints") and ti < cand.tp_constraints.len) {
        \\                if (cand.tp_constraints[ti]) |ConstraintT| {
        \\                    if (tst.field_attrs[ti].defaultValue(type)) |TpT| {
        \\                        if (!satisfiesTypeConstraint(TpT, ConstraintT, 0)) return null;
        \\                    }
        \\                }
        \\            }
        \\        }
        \\    }
        \\    const val_argc: usize = tst.field_types.len - eff_tp_n;
        \\    const fixed_len: usize = cand.fixed_params.len;
        \\    if (val_argc < cand.min_arity) return null;
        \\    if (!cand.has_rest and val_argc > fixed_len) return null;
        \\
        \\    const BaseFn = @field(Owner, cand.fn_name);
        \\    const base_params = @typeInfo(@TypeOf(BaseFn)).@"fn".param_types;
        \\    const param_base: usize = @intFromBool(has_self) + tp_n;
        \\
        \\    comptime var score: usize = 1000;
        \\    const deduced_cap = if (tp_n > 0) tp_n else 1;
        \\    comptime var deduced_tps: [deduced_cap]?type = @splat(null);
        \\    const check_fixed = @min(val_argc, fixed_len);
        \\    inline for (0..check_fixed) |fi| {
        \\        const ArgT = tst.field_types[eff_tp_n + fi];
        \\        const arg_attr = tst.field_attrs[eff_tp_n + fi];
        \\        const pspec = cand.fixed_params[fi];
        \\        if (pspec.kind == .callback) {
        \\            if (ArgT == @TypeOf(null)) {
        \\                if (!pspec.nullable) return null;
        \\                score += 10;
        \\            } else if (callbackArgMatchScore(ArgT, pspec.cb_arity)) |cb_sc| {
        \\                score += cb_sc;
        \\            } else {
        \\                return null;
        \\            }
        \\        } else {
        \\            if (base_params[param_base + fi]) |ParamT| {
        \\                switch (argMatchTier(ParamT, ArgT, arg_attr)) {
        \\                    .literal_exact => score += 25,
        \\                    .exact => score += 20,
        \\                    .coerced => score += 10,
        \\                    .none => return null,
        \\                }
        \\            } else if (@hasField(@TypeOf(pspec), "tp_idx") and pspec.tp_idx != null) {
        \\                const tp_i = pspec.tp_idx.?;
        \\                const ConstraintOpt: ?type = if (@hasField(@TypeOf(cand), "tp_constraints") and tp_i < cand.tp_constraints.len)
        \\                    cand.tp_constraints[tp_i]
        \\                else
        \\                    null;
        \\                if (explicit_tps) {
        \\                    if (tst.field_attrs[tp_i].defaultValue(type)) |TpT| {
        \\                        const ExpectedT = switch (pspec.tp_mode) {
        \\                            .optional_child => if (@typeInfo(TpT) == .optional) TpT else ?TpT,
        \\                            .slice_elem => []const TpT,
        \\                            .promise_payload => Promise(TpT),
        \\                            else => TpT,
        \\                        };
        \\                        switch (argMatchTier(ExpectedT, ArgT, arg_attr)) {
        \\                            .literal_exact => score += 25,
        \\                            .exact => score += 20,
        \\                            .coerced => score += 10,
        \\                            .none => return null,
        \\                        }
        \\                    } else {
        \\                        score += 15;
        \\                    }
        \\                } else {
        \\                    const DeducedT = tryInferOverloadParamType(pspec.tp_mode, ArgT, arg_attr, pspec.nullable, ConstraintOpt) orelse return null;
        \\                    if (ConstraintOpt) |ConstraintT| {
        \\                        if (!satisfiesTypeConstraint(DeducedT, ConstraintT, 0)) return null;
        \\                    }
        \\                    if (deduced_tps[tp_i]) |PrevT| {
        \\                        if (PrevT != DeducedT and
        \\                            argMatchTier(PrevT, DeducedT, arg_attr) == .none and
        \\                            argMatchTier(DeducedT, PrevT, .{}) == .none)
        \\                        {
        \\                            return null;
        \\                        }
        \\                    } else {
        \\                        deduced_tps[tp_i] = DeducedT;
        \\                    }
        \\                    score += if (ConstraintOpt != null) 14 else 12;
        \\                }
        \\            } else {
        \\                score += 15;
        \\            }
        \\        }
        \\    }
        \\
        \\    if (cand.has_rest and val_argc > fixed_len) {
        \\        if (cand.slice_fn_name) |sfn| {
        \\            const SliceFn = @field(Owner, sfn);
        \\            const slice_params = @typeInfo(@TypeOf(SliceFn)).@"fn".param_types;
        \\            if (slice_params[param_base + fixed_len]) |RestSliceT| {
        \\                const ElemT = SliceElem(RestSliceT);
        \\                if (ElemT == Any or ElemT == Unknown) {
        \\                    score += (val_argc - fixed_len) * 2;
        \\                } else if (val_argc == fixed_len + 1 and argMatchTier(RestSliceT, tst.field_types[eff_tp_n + fixed_len], tst.field_attrs[eff_tp_n + fixed_len]) != .none) {
        \\                    score += 15;
        \\                } else {
        \\                    inline for (fixed_len..val_argc) |ri| {
        \\                        const RArgT = tst.field_types[eff_tp_n + ri];
        \\                        switch (argMatchTier(ElemT, RArgT, tst.field_attrs[eff_tp_n + ri])) {
        \\                            .literal_exact => score += 6,
        \\                            .exact => score += 5,
        \\                            .coerced => score += 2,
        \\                            .none => return null,
        \\                        }
        \\                    }
        \\                }
        \\            } else {
        \\                score += 5;
        \\            }
        \\        }
        \\    } else if (cand.has_rest) {
        \\        if (score > 0) score -= 1;
        \\    }
        \\
        \\    return score;
        \\}
        \\
        \\fn selectCandidateIndex(
        \\    comptime Owner: type,
        \\    comptime has_self: bool,
        \\    comptime specs: anytype,
        \\    comptime TupT: type,
        \\) usize {
        \\    @setEvalBranchQuota(200_000);
        \\    comptime var best_idx: ?usize = null;
        \\    comptime var best_score: usize = 0;
        \\    inline for (0..specs.len) |ci| {
        \\        if (comptime candidateScore(Owner, has_self, specs[ci], TupT)) |sc| {
        \\            if (best_idx == null or sc > best_score) {
        \\                best_idx = ci;
        \\                best_score = sc;
        \\            }
        \\        }
        \\    }
        \\    return best_idx orelse @compileError("No overload of " ++ @typeName(Owner) ++ " matches argument types " ++ @typeName(TupT));
        \\}
        \\
        \\inline fn packRestStep(prefix: anytype, tup: anytype, comptime idx: usize) PackRestStepType(@TypeOf(prefix), @TypeOf(tup), idx) {
        \\    const tst = @typeInfo(@TypeOf(tup)).@"struct";
        \\    if (comptime idx >= tst.field_types.len) return prefix;
        \\    if (comptime tst.field_attrs[idx].@"comptime") {
        \\        const cv = comptime readComptimeDefault(tst.field_types[idx], tst.field_attrs[idx]);
        \\        return packRestStep(prefix ++ .{cv}, tup, idx + 1);
        \\    }
        \\    return packRestStep(prefix ++ .{tup[idx]}, tup, idx + 1);
        \\}
        \\
        \\fn tupleHasComptimeField(comptime TupT: type) bool {
        \\    const st = @typeInfo(TupT).@"struct";
        \\    for (st.field_attrs) |attr| {
        \\        if (attr.@"comptime") return true;
        \\    }
        \\    return false;
        \\}
        \\
        \\fn AppendRuntimeTupleElem(comptime PrefixT: type, comptime ElemT: type) type {
        \\    if (!tupleHasComptimeField(PrefixT) and !isComptimeOnlyArgType(ElemT)) {
        \\        const Probe = struct {
        \\            fn f(p: PrefixT, e: ElemT) @TypeOf(p ++ .{e}) {
        \\                unreachable;
        \\            }
        \\        };
        \\        return @typeInfo(@TypeOf(Probe.f)).@"fn".return_type.?;
        \\    }
        \\    return @TypeOf(dummyForType(PrefixT) ++ .{dummyForType(ElemT)});
        \\}
        \\
        \\fn AppendComptimeTupleElem(comptime PrefixT: type, comptime cv: anytype) type {
        \\    if (!tupleHasComptimeField(PrefixT)) {
        \\        const Probe = struct {
        \\            fn f(p: PrefixT) @TypeOf(p ++ .{cv}) {
        \\                unreachable;
        \\            }
        \\        };
        \\        return @typeInfo(@TypeOf(Probe.f)).@"fn".return_type.?;
        \\    }
        \\    return @TypeOf(dummyForType(PrefixT) ++ .{cv});
        \\}
        \\
        \\fn ReturnTypeOfTupleCall(comptime Fn: anytype, comptime CallTupT: type) type {
        \\    if (!tupleHasComptimeField(CallTupT)) {
        \\        const Probe = struct {
        \\            fn f(t: CallTupT) @TypeOf(@call(.auto, Fn, t)) {
        \\                unreachable;
        \\            }
        \\        };
        \\        return @typeInfo(@TypeOf(Probe.f)).@"fn".return_type.?;
        \\    }
        \\    return @TypeOf(@call(.auto, Fn, dummyForType(CallTupT)));
        \\}
        \\
        \\fn PackRestStepType(comptime PrefixT: type, comptime TupT: type, comptime idx: usize) type {
        \\    const tst = @typeInfo(TupT).@"struct";
        \\    if (idx >= tst.field_types.len) return PrefixT;
        \\    const FT = tst.field_types[idx];
        \\    const attr = tst.field_attrs[idx];
        \\    if (attr.@"comptime") {
        \\        const cv = readComptimeDefault(FT, attr);
        \\        return PackRestStepType(AppendComptimeTupleElem(PrefixT, cv), TupT, idx + 1);
        \\    }
        \\    return PackRestStepType(AppendRuntimeTupleElem(PrefixT, FT), TupT, idx + 1);
        \\}
        \\
        \\fn BuildCallTupleType(
        \\    comptime TargetFn: anytype,
        \\    comptime has_self: bool,
        \\    comptime SelfT: type,
        \\    comptime pass_alloc: bool,
        \\    comptime cand: anytype,
        \\    comptime TupT: type,
        \\    comptime stage: usize,
        \\    comptime PrefixT: type,
        \\) type {
        \\    const tst = @typeInfo(TupT).@"struct";
        \\    const tp_n: usize = if (candidateUsesExplicitTypeParams(cand, TupT)) cand.type_param_count else 0;
        \\    const fixed_len: usize = cand.fixed_params.len;
        \\    const val_argc: usize = tst.field_types.len - tp_n;
        \\    const target_params = @typeInfo(@TypeOf(TargetFn)).@"fn".param_types;
        \\    const fixed_param_base: usize = @intFromBool(has_self) + tp_n + @intFromBool(pass_alloc);
        \\
        \\    if (stage < tp_n) {
        \\        const cv = readComptimeDefault(type, tst.field_attrs[stage]);
        \\        return BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, stage + 1, AppendComptimeTupleElem(PrefixT, cv));
        \\    }
        \\    if (pass_alloc and stage == tp_n) {
        \\        return BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, stage + 1, AppendRuntimeTupleElem(PrefixT, std.mem.Allocator));
        \\    }
        \\    const fi: usize = stage - tp_n - @intFromBool(pass_alloc);
        \\    if (fi < fixed_len) {
        \\        const pspec = cand.fixed_params[fi];
        \\        if (fi < val_argc) {
        \\            const idx = tp_n + fi;
        \\            const ArgT = tst.field_types[idx];
        \\            const attr = tst.field_attrs[idx];
        \\            if (pspec.kind == .callback) {
        \\                if (attr.@"comptime") {
        \\                    const cv = readComptimeDefault(ArgT, attr);
        \\                    return BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, stage + 1, AppendComptimeTupleElem(PrefixT, cv));
        \\                }
        \\                return BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, stage + 1, AppendRuntimeTupleElem(PrefixT, ArgT));
        \\            } else if (target_params[fixed_param_base + fi]) |ParamT| {
        \\                return BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, stage + 1, AppendRuntimeTupleElem(PrefixT, ParamT));
        \\            } else {
        \\                if (attr.@"comptime") {
        \\                    const cv = readComptimeDefault(ArgT, attr);
        \\                    return BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, stage + 1, AppendComptimeTupleElem(PrefixT, cv));
        \\                }
        \\                return BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, stage + 1, AppendRuntimeTupleElem(PrefixT, ArgT));
        \\            }
        \\        } else {
        \\            if (pspec.kind == .callback) {
        \\                return BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, stage + 1, AppendComptimeTupleElem(PrefixT, null));
        \\            } else if (target_params[fixed_param_base + fi]) |ParamT| {
        \\                return BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, stage + 1, AppendRuntimeTupleElem(PrefixT, ParamT));
        \\            } else {
        \\                return BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, stage + 1, AppendComptimeTupleElem(PrefixT, null));
        \\            }
        \\        }
        \\    }
        \\    if (cand.has_rest and fi == fixed_len) {
        \\        const SubT = PackRestStepType(@TypeOf(.{}), TupT, tp_n + fixed_len);
        \\        return AppendRuntimeTupleElem(PrefixT, SubT);
        \\    }
        \\    return PrefixT;
        \\}
        \\
        \\fn candidatePassAlloc(comptime cand: anytype, comptime TupT: type, comptime caller_has_alloc: bool) bool {
        \\    if (!caller_has_alloc) return false;
        \\    const use_infer = cand.type_param_count > 0 and !candidateUsesExplicitTypeParams(cand, TupT);
        \\    if (use_infer) {
        \\        return @hasField(@TypeOf(cand), "infer_alloc_fn_name") and cand.infer_alloc_fn_name != null;
        \\    }
        \\    return cand.alloc_fn_name != null;
        \\}
        \\
        \\fn candidateTargetFnName(comptime cand: anytype, comptime TupT: type, comptime pass_alloc: bool) []const u8 {
        \\    const use_infer = cand.type_param_count > 0 and !candidateUsesExplicitTypeParams(cand, TupT);
        \\    if (use_infer) {
        \\        return if (pass_alloc) cand.infer_alloc_fn_name.? else cand.infer_fn_name.?;
        \\    }
        \\    return if (pass_alloc) cand.alloc_fn_name.? else cand.fn_name;
        \\}
        \\
        \\fn CandidateCallReturnType(
        \\    comptime Owner: type,
        \\    comptime has_self: bool,
        \\    comptime SelfT: type,
        \\    comptime cand: anytype,
        \\    comptime TupT: type,
        \\    comptime caller_has_alloc: bool,
        \\) type {
        \\    const pass_alloc = candidatePassAlloc(cand, TupT, caller_has_alloc);
        \\    const TargetFn = @field(Owner, candidateTargetFnName(cand, TupT, pass_alloc));
        \\    const fni = @typeInfo(@TypeOf(TargetFn)).@"fn";
        \\    if (fni.return_type) |rt| return rt;
        \\    const InitPrefixT = if (has_self) AppendRuntimeTupleElem(@TypeOf(.{}), SelfT) else @TypeOf(.{});
        \\    const FullTupT = BuildCallTupleType(TargetFn, has_self, SelfT, pass_alloc, cand, TupT, 0, InitPrefixT);
        \\    return ReturnTypeOfTupleCall(TargetFn, FullTupT);
        \\}
        \\
        \\inline fn invokeStep(
        \\    comptime Owner: type,
        \\    comptime TargetFn: anytype,
        \\    comptime has_self: bool,
        \\    comptime SelfT: type,
        \\    comptime pass_alloc: bool,
        \\    alloc_val: std.mem.Allocator,
        \\    comptime cand: anytype,
        \\    comptime TupT: type,
        \\    tup: anytype,
        \\    comptime stage: usize,
        \\    prefix: anytype,
        \\) CandidateCallReturnType(Owner, has_self, SelfT, cand, TupT, pass_alloc) {
        \\    const tst = @typeInfo(TupT).@"struct";
        \\    const actual_tst = @typeInfo(@TypeOf(tup)).@"struct";
        \\    const tp_n: usize = if (comptime candidateUsesExplicitTypeParams(cand, TupT)) cand.type_param_count else 0;
        \\    const fixed_len: usize = cand.fixed_params.len;
        \\    const tup_len: usize = tst.field_types.len;
        \\    const val_argc: usize = tup_len - tp_n;
        \\    const target_params = @typeInfo(@TypeOf(TargetFn)).@"fn".param_types;
        \\    const fixed_param_base: usize = @intFromBool(has_self) + tp_n + @intFromBool(pass_alloc);
        \\
        \\    if (comptime stage < tp_n) {
        \\        const TpVal = comptime readComptimeDefault(type, actual_tst.field_attrs[stage]);
        \\        return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{TpVal});
        \\    }
        \\    if (comptime (pass_alloc and stage == tp_n)) {
        \\        return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{alloc_val});
        \\    }
        \\    const fi: usize = stage - tp_n - @intFromBool(pass_alloc);
        \\    if (comptime fi < fixed_len) {
        \\        const pspec = cand.fixed_params[fi];
        \\        if (comptime fi < val_argc) {
        \\            const arg_idx = tp_n + fi;
        \\            if (comptime actual_tst.field_attrs[arg_idx].@"comptime") {
        \\                const comptime_arg = comptime readComptimeDefault(actual_tst.field_types[arg_idx], actual_tst.field_attrs[arg_idx]);
        \\                if (comptime pspec.kind == .callback) {
        \\                    return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{comptime_arg});
        \\                } else if (comptime target_params[fixed_param_base + fi]) |ParamT| {
        \\                    const coerced = coerceArgToParam(ParamT, comptime_arg);
        \\                    return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{coerced});
        \\                } else {
        \\                    return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{comptime_arg});
        \\                }
        \\            }
        \\            const raw_arg = tup[arg_idx];
        \\            if (comptime pspec.kind == .callback) {
        \\                return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{raw_arg});
        \\            } else if (comptime target_params[fixed_param_base + fi]) |ParamT| {
        \\                const coerced = coerceArgToParam(ParamT, raw_arg);
        \\                return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{coerced});
        \\            } else {
        \\                return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{raw_arg});
        \\            }
        \\        } else {
        \\            if (comptime pspec.kind == .callback) {
        \\                return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{null});
        \\            } else if (comptime target_params[fixed_param_base + fi]) |ParamT| {
        \\                return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{@as(ParamT, null)});
        \\            } else {
        \\                return invokeStep(Owner, TargetFn, has_self, SelfT, pass_alloc, alloc_val, cand, TupT, tup, stage + 1, prefix ++ .{null});
        \\            }
        \\        }
        \\    }
        \\    if (comptime (cand.has_rest and fi == fixed_len)) {
        \\        const rest_sub = packRestStep(.{}, tup, tp_n + fixed_len);
        \\        return @call(.auto, TargetFn, prefix ++ .{rest_sub});
        \\    }
        \\    return @call(.auto, TargetFn, prefix);
        \\}
        \\
        \\fn isComptimeOnlyArgType(comptime T: type) bool {
        \\    return switch (@typeInfo(T)) {
        \\        .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined => true,
        \\        .optional => |opt| isComptimeOnlyArgType(opt.child),
        \\        .array => |ar| isComptimeOnlyArgType(ar.child),
        \\        .pointer => |pt| isComptimeOnlyArgType(pt.child),
        \\        .@"struct" => |st| blk: {
        \\            for (st.field_types, 0..) |ft, fi| {
        \\                if (!st.field_attrs[fi].@"comptime" and isComptimeOnlyArgType(ft)) break :blk true;
        \\            }
        \\            break :blk false;
        \\        },
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn wrapSingleArgTupleType(comptime ArgsT: type) type {
        \\    if (isTupleType(ArgsT)) return ArgsT;
        \\    if (ArgsT == type) return @TypeOf(.{u8});
        \\    if (!isComptimeOnlyArgType(ArgsT) or @typeInfo(ArgsT) == .enum_literal) {
        \\        return @Tuple(&[_]type{ArgsT});
        \\    }
        \\    return @TypeOf(.{dummyForType(ArgsT)});
        \\}
        \\
        \\pub fn OverloadReturn(comptime Owner: type, comptime specs: anytype, comptime ArgsT: type, comptime has_alloc: bool) type {
        \\    const TupT = wrapSingleArgTupleType(ArgsT);
        \\    const ci = selectCandidateIndex(Owner, false, specs, TupT);
        \\    return CandidateCallReturnType(Owner, false, void, specs[ci], TupT, has_alloc);
        \\}
        \\
        \\pub fn OverloadMethodReturn(comptime Owner: type, comptime SelfT: type, comptime specs: anytype, comptime ArgsT: type, comptime has_alloc: bool) type {
        \\    const TupT = wrapSingleArgTupleType(ArgsT);
        \\    const ci = selectCandidateIndex(Owner, true, specs, TupT);
        \\    return CandidateCallReturnType(Owner, true, SelfT, specs[ci], TupT, has_alloc);
        \\}
        \\
        \\pub inline fn dispatchOverload(comptime Owner: type, comptime specs: anytype, args: anytype, alloc_opt: anytype) OverloadReturn(Owner, specs, @TypeOf(args), @TypeOf(alloc_opt) != @TypeOf(null)) {
        \\    const has_alloc = comptime (@TypeOf(alloc_opt) != @TypeOf(null));
        \\    const is_tup = comptime isTupleType(@TypeOf(args));
        \\    const TupT = wrapSingleArgTupleType(@TypeOf(args));
        \\    const ci = comptime selectCandidateIndex(Owner, false, specs, TupT);
        \\    const cand = specs[ci];
        \\    const pass_alloc = comptime candidatePassAlloc(cand, TupT, has_alloc);
        \\    const TargetFn = @field(Owner, candidateTargetFnName(cand, TupT, pass_alloc));
        \\    const alloc_val: std.mem.Allocator = if (has_alloc) alloc_opt else undefined;
        \\    if (is_tup) {
        \\        return invokeStep(Owner, TargetFn, false, void, pass_alloc, alloc_val, cand, TupT, args, 0, .{});
        \\    }
        \\    return invokeStep(Owner, TargetFn, false, void, pass_alloc, alloc_val, cand, TupT, .{args}, 0, .{});
        \\}
        \\
        \\pub inline fn dispatchOverloadMethod(comptime Owner: type, self_val: anytype, comptime specs: anytype, args: anytype, alloc_opt: anytype) OverloadMethodReturn(Owner, @TypeOf(self_val), specs, @TypeOf(args), @TypeOf(alloc_opt) != @TypeOf(null)) {
        \\    const has_alloc = comptime (@TypeOf(alloc_opt) != @TypeOf(null));
        \\    const is_tup = comptime isTupleType(@TypeOf(args));
        \\    const TupT = wrapSingleArgTupleType(@TypeOf(args));
        \\    const ci = comptime selectCandidateIndex(Owner, true, specs, TupT);
        \\    const cand = specs[ci];
        \\    const pass_alloc = comptime candidatePassAlloc(cand, TupT, has_alloc);
        \\    const TargetFn = @field(Owner, candidateTargetFnName(cand, TupT, pass_alloc));
        \\    const alloc_val: std.mem.Allocator = if (has_alloc) alloc_opt else undefined;
        \\    if (is_tup) {
        \\        return invokeStep(Owner, TargetFn, true, @TypeOf(self_val), pass_alloc, alloc_val, cand, TupT, args, 0, .{self_val});
        \\    }
        \\    return invokeStep(Owner, TargetFn, true, @TypeOf(self_val), pass_alloc, alloc_val, cand, TupT, .{args}, 0, .{self_val});
        \\}
        \\
        \\pub const hidden_meta_field_name = "__zigar_js_meta";
        \\
        \\fn isHiddenMetaField(comptime fname: []const u8) bool {
        \\    return std.mem.eql(u8, fname, hidden_meta_field_name);
        \\}
        \\
        \\fn hasStructZigarJsMeta(comptime T: type) bool {
        \\    if (@typeInfo(T) != .@"struct") return false;
        \\    if (@hasDecl(T, "zigar_js")) return true;
        \\    if (@hasField(T, hidden_meta_field_name)) {
        \\        const Carrier = @FieldType(T, hidden_meta_field_name);
        \\        return @typeInfo(Carrier) == .@"struct" and @hasDecl(Carrier, "zigar_js");
        \\    }
        \\    return false;
        \\}
        \\
        \\fn StructZigarJsMetaType(comptime T: type) type {
        \\    if (@hasDecl(T, "zigar_js")) return @TypeOf(T.zigar_js);
        \\    return @TypeOf(@FieldType(T, hidden_meta_field_name).zigar_js);
        \\}
        \\
        \\fn getStructZigarJsMeta(comptime T: type) StructZigarJsMetaType(T) {
        \\    if (@hasDecl(T, "zigar_js")) return T.zigar_js;
        \\    return @FieldType(T, hidden_meta_field_name).zigar_js;
        \\}
        \\
        \\fn isModuleNullableType(comptime T: type) bool {
        \\    return @typeInfo(T) == .@"union" and @hasDecl(T, "is_zigar_nullable") and T.is_zigar_nullable;
        \\}
        \\
        \\fn isPlainValueStructForTransform(comptime T: type) bool {
        \\    if (@typeInfo(T) != .@"struct") return false;
        \\    if (@typeInfo(T).@"struct".is_tuple) return false;
        \\    if (isJsValueStruct(T)) return false;
        \\    if (isGeneratedHandleStruct(T)) return false;
        \\    if (@hasDecl(T, "zigar_js_tuple")) return false;
        \\    if (hasStructZigarJsMeta(T)) {
        \\        const meta = getStructZigarJsMeta(T);
        \\        const MetaT = @TypeOf(meta);
        \\        if (@hasField(MetaT, "is_template_literal") and meta.is_template_literal) return false;
        \\        if (@hasField(MetaT, "is_enum") and meta.is_enum) return false;
        \\        if (@hasField(MetaT, "is_open_literal") and meta.is_open_literal) return false;
        \\    }
        \\    return true;
        \\}
        \\
        \\fn topStructFieldWireName(comptime T: type, comptime field_name: []const u8) []const u8 {
        \\    if (hasStructZigarJsMeta(T)) {
        \\        const meta = getStructZigarJsMeta(T);
        \\        if (@hasField(@TypeOf(meta), "fields")) {
        \\            inline for (meta.fields) |fm| {
        \\                if (std.mem.eql(u8, fm.name, field_name)) {
        \\                    if (@hasField(@TypeOf(fm), "js_name")) return fm.js_name;
        \\                    return field_name;
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return field_name;
        \\}
        \\
        \\fn topStructFieldIsOptional(comptime T: type, comptime field_name: []const u8, comptime has_default: bool) bool {
        \\    if (hasStructZigarJsMeta(T)) {
        \\        const meta = getStructZigarJsMeta(T);
        \\        if (@hasField(@TypeOf(meta), "fields")) {
        \\            inline for (meta.fields) |fm| {
        \\                if (std.mem.eql(u8, fm.name, field_name)) {
        \\                    if (@hasField(@TypeOf(fm), "is_optional")) return fm.is_optional;
        \\                    return has_default;
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return has_default;
        \\}
        \\
        \\const TransformMetaMode = enum {
        \\    preserve,
        \\    make_partial,
        \\    make_required,
        \\};
        \\
        \\fn specTopSelfNullish(comptime spec: anytype) NullishKind {
        \\    const SpecT = @TypeOf(spec);
        \\    if (SpecT == NullishKind) return spec;
        \\    return switch (@typeInfo(SpecT)) {
        \\        .enum_literal => @field(NullishKind, @tagName(spec)),
        \\        .@"struct" => if (@hasField(SpecT, "self")) specTopSelfNullish(spec.self) else .none,
        \\        else => .none,
        \\    };
        \\}
        \\
        \\fn RebuildSpecWithSelfType(comptime SpecT: type) type {
        \\    if (@typeInfo(SpecT) != .@"struct" or !@hasField(SpecT, "self")) return NullishKind;
        \\    if (@hasField(SpecT, "child")) {
        \\        return if (@hasField(SpecT, "id"))
        \\            struct { id: @FieldType(SpecT, "id"), self: NullishKind, child: @FieldType(SpecT, "child") }
        \\        else
        \\            struct { self: NullishKind, child: @FieldType(SpecT, "child") };
        \\    }
        \\    if (@hasField(SpecT, "elem")) {
        \\        return struct { self: NullishKind, elem: @FieldType(SpecT, "elem") };
        \\    }
        \\    if (@hasField(SpecT, "fields")) {
        \\        return if (@hasField(SpecT, "id"))
        \\            struct { id: @FieldType(SpecT, "id"), self: NullishKind, fields: @FieldType(SpecT, "fields") }
        \\        else
        \\            struct { self: NullishKind, fields: @FieldType(SpecT, "fields") };
        \\    }
        \\    if (@hasField(SpecT, "variants")) {
        \\        return if (@hasField(SpecT, "id"))
        \\            struct { id: @FieldType(SpecT, "id"), self: NullishKind, variants: @FieldType(SpecT, "variants") }
        \\        else
        \\            struct { self: NullishKind, variants: @FieldType(SpecT, "variants") };
        \\    }
        \\    if (@hasField(SpecT, "tuple")) {
        \\        return if (@hasField(SpecT, "id"))
        \\            struct { id: @FieldType(SpecT, "id"), self: NullishKind, tuple: @FieldType(SpecT, "tuple") }
        \\        else
        \\            struct { self: NullishKind, tuple: @FieldType(SpecT, "tuple") };
        \\    }
        \\    return NullishKind;
        \\}
        \\
        \\fn rebuildSpecWithSelf(comptime spec: anytype, comptime new_self: NullishKind) RebuildSpecWithSelfType(@TypeOf(spec)) {
        \\    const SpecT = @TypeOf(spec);
        \\    if (@typeInfo(SpecT) != .@"struct" or !@hasField(SpecT, "self")) return new_self;
        \\    if (@hasField(SpecT, "child")) {
        \\        return if (@hasField(SpecT, "id"))
        \\            .{ .id = spec.id, .self = new_self, .child = spec.child }
        \\        else
        \\            .{ .self = new_self, .child = spec.child };
        \\    }
        \\    if (@hasField(SpecT, "elem")) {
        \\        return .{ .self = new_self, .elem = spec.elem };
        \\    }
        \\    if (@hasField(SpecT, "fields")) {
        \\        return if (@hasField(SpecT, "id"))
        \\            .{ .id = spec.id, .self = new_self, .fields = spec.fields }
        \\        else
        \\            .{ .self = new_self, .fields = spec.fields };
        \\    }
        \\    if (@hasField(SpecT, "variants")) {
        \\        return if (@hasField(SpecT, "id"))
        \\            .{ .id = spec.id, .self = new_self, .variants = spec.variants }
        \\        else
        \\            .{ .self = new_self, .variants = spec.variants };
        \\    }
        \\    if (@hasField(SpecT, "tuple")) {
        \\        return if (@hasField(SpecT, "id"))
        \\            .{ .id = spec.id, .self = new_self, .tuple = spec.tuple }
        \\        else
        \\            .{ .self = new_self, .tuple = spec.tuple };
        \\    }
        \\    return new_self;
        \\}
        \\
        \\fn UnwrapSpecChildType(comptime SpecT: type) type {
        \\    if (@typeInfo(SpecT) == .@"struct" and @hasField(SpecT, "child")) {
        \\        return @FieldType(SpecT, "child");
        \\    }
        \\    return NullishKind;
        \\}
        \\
        \\fn unwrapSpecChild(comptime spec: anytype) UnwrapSpecChildType(@TypeOf(spec)) {
        \\    const SpecT = @TypeOf(spec);
        \\    if (@typeInfo(SpecT) == .@"struct" and @hasField(SpecT, "child")) {
        \\        return spec.child;
        \\    }
        \\    return .none;
        \\}
        \\
        \\fn WrapSpecAsOptionalType(comptime spec: anytype) type {
        \\    const SpecT = @TypeOf(spec);
        \\    if (@typeInfo(SpecT) == .@"struct") {
        \\        return struct { self: NullishKind, child: SpecT };
        \\    }
        \\    const cur = specTopSelfNullish(spec);
        \\    if (cur == .none) return NullishKind;
        \\    return struct { self: NullishKind, child: NullishKind };
        \\}
        \\
        \\fn wrapSpecAsOptional(comptime spec: anytype, comptime outer_self: NullishKind) WrapSpecAsOptionalType(spec) {
        \\    const SpecT = @TypeOf(spec);
        \\    if (@typeInfo(SpecT) == .@"struct") {
        \\        return .{ .self = outer_self, .child = spec };
        \\    }
        \\    const cur = specTopSelfNullish(spec);
        \\    if (cur == .none) return outer_self;
        \\    return .{ .self = outer_self, .child = cur };
        \\}
        \\
        \\fn ComputedTransformedNullishType(comptime T: type, comptime fname: []const u8, comptime mode: TransformMetaMode) type {
        \\    const OrigFT = @FieldType(T, fname);
        \\    if (hasStructZigarJsMeta(T)) {
        \\        const meta = getStructZigarJsMeta(T);
        \\        if (@hasField(@TypeOf(meta), "fields")) {
        \\            inline for (meta.fields) |fm| {
        \\                if (std.mem.eql(u8, fm.name, fname)) {
        \\                    const FmT = @TypeOf(fm);
        \\                    const has_nullish = @hasField(FmT, "nullish");
        \\                    if (!has_nullish) return NullishKind;
        \\                    const fm_is_opt = @hasField(FmT, "is_optional") and fm.is_optional;
        \\                    const cur_self = specTopSelfNullish(fm.nullish);
        \\                    return switch (mode) {
        \\                        .preserve => @TypeOf(fm.nullish),
        \\                        .make_partial => if (@typeInfo(OrigFT) == .optional or isModuleNullableType(OrigFT))
        \\                            RebuildSpecWithSelfType(@TypeOf(fm.nullish))
        \\                        else
        \\                            WrapSpecAsOptionalType(fm.nullish),
        \\                        .make_required => if (!fm_is_opt)
        \\                            @TypeOf(fm.nullish)
        \\                        else if (isModuleNullableType(OrigFT) or cur_self == .null_only or cur_self == .null_or_undefined)
        \\                            RebuildSpecWithSelfType(@TypeOf(fm.nullish))
        \\                        else
        \\                            UnwrapSpecChildType(@TypeOf(fm.nullish)),
        \\                    };
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return NullishKind;
        \\}
        \\
        \\fn computeTransformedNullish(
        \\    comptime T: type,
        \\    comptime fname: []const u8,
        \\    comptime mode: TransformMetaMode,
        \\) ComputedTransformedNullishType(T, fname, mode) {
        \\    const OrigFT = @FieldType(T, fname);
        \\    if (hasStructZigarJsMeta(T)) {
        \\        const meta = getStructZigarJsMeta(T);
        \\        if (@hasField(@TypeOf(meta), "fields")) {
        \\            inline for (meta.fields) |fm| {
        \\                if (std.mem.eql(u8, fm.name, fname)) {
        \\                    const FmT = @TypeOf(fm);
        \\                    const has_nullish = @hasField(FmT, "nullish");
        \\                    if (!has_nullish) {
        \\                        return if (mode == .make_partial) NullishKind.undefined_only else NullishKind.none;
        \\                    }
        \\                    const fm_is_opt = @hasField(FmT, "is_optional") and fm.is_optional;
        \\                    const cur_self = specTopSelfNullish(fm.nullish);
        \\                    return switch (mode) {
        \\                        .preserve => fm.nullish,
        \\                        .make_partial => blk: {
        \\                            if (@typeInfo(OrigFT) == .optional or isModuleNullableType(OrigFT)) {
        \\                                const merged_self: NullishKind = if (cur_self == .null_only or cur_self == .null_or_undefined)
        \\                                    .null_or_undefined
        \\                                else
        \\                                    .undefined_only;
        \\                                break :blk rebuildSpecWithSelf(fm.nullish, merged_self);
        \\                            }
        \\                            break :blk wrapSpecAsOptional(fm.nullish, .undefined_only);
        \\                        },
        \\                        .make_required => blk: {
        \\                            if (!fm_is_opt) break :blk fm.nullish;
        \\                            if (isModuleNullableType(OrigFT) or cur_self == .null_only or cur_self == .null_or_undefined) {
        \\                                break :blk rebuildSpecWithSelf(fm.nullish, .null_only);
        \\                            }
        \\                            break :blk unwrapSpecChild(fm.nullish);
        \\                        },
        \\                    };
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return if (mode == .make_partial) NullishKind.undefined_only else NullishKind.none;
        \\}
        \\
        \\fn requiredFieldResolution(comptime T: type, comptime fname: []const u8, comptime OrigFT: type) struct {
        \\    ty: type,
        \\    preserve_default: bool,
        \\} {
        \\    if (hasStructZigarJsMeta(T)) {
        \\        const meta = getStructZigarJsMeta(T);
        \\        if (@hasField(@TypeOf(meta), "fields")) {
        \\            inline for (meta.fields) |fm| {
        \\                if (std.mem.eql(u8, fm.name, fname)) {
        \\                    const FmT = @TypeOf(fm);
        \\                    const fm_is_opt = @hasField(FmT, "is_optional") and fm.is_optional;
        \\                    if (!fm_is_opt) {
        \\                        return .{ .ty = OrigFT, .preserve_default = true };
        \\                    }
        \\                    if (isModuleNullableType(OrigFT)) {
        \\                        return .{ .ty = ?OrigFT.Value, .preserve_default = false };
        \\                    }
        \\                    const cur_self = if (@hasField(FmT, "nullish")) specTopSelfNullish(fm.nullish) else NullishKind.none;
        \\                    if (cur_self == .null_only or cur_self == .null_or_undefined) {
        \\                        return .{ .ty = OrigFT, .preserve_default = false };
        \\                    }
        \\                    const unwrapped = if (@typeInfo(OrigFT) == .optional) @typeInfo(OrigFT).optional.child else OrigFT;
        \\                    return .{ .ty = unwrapped, .preserve_default = false };
        \\                }
        \\            }
        \\        }
        \\    }
        \\    if (@typeInfo(OrigFT) == .optional) {
        \\        return .{ .ty = @typeInfo(OrigFT).optional.child, .preserve_default = false };
        \\    }
        \\    if (isModuleNullableType(OrigFT)) {
        \\        return .{ .ty = OrigFT.Value, .preserve_default = false };
        \\    }
        \\    return .{ .ty = OrigFT, .preserve_default = true };
        \\}
        \\
        \\fn TransformFieldEntryType(comptime T: type, comptime fname: []const u8, comptime mode: TransformMetaMode) type {
        \\    if (hasStructZigarJsMeta(T)) {
        \\        const meta = getStructZigarJsMeta(T);
        \\        if (@hasField(@TypeOf(meta), "fields")) {
        \\            inline for (meta.fields) |fm| {
        \\                if (std.mem.eql(u8, fm.name, fname)) {
        \\                    if (mode == .preserve) return @TypeOf(fm);
        \\                    const FmT = @TypeOf(fm);
        \\                    const NullishT = ComputedTransformedNullishType(T, fname, mode);
        \\                    return buildConstraintPreservingDescriptorType(FmT, NullishT);
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return struct {
        \\        name: []const u8,
        \\        js_name: []const u8,
        \\        is_optional: bool,
        \\        nullish: NullishKind,
        \\    };
        \\}
        \\
        \\fn buildConstraintPreservingDescriptorType(comptime FmT: type, comptime NullishT: type) type {
        \\    comptime var fnames: [10][]const u8 = undefined;
        \\    comptime var ftypes: [10]type = undefined;
        \\    comptime var fattrs: [10]std.builtin.Type.Struct.FieldAttributes = undefined;
        \\    comptime var n: usize = 0;
        \\
        \\    fnames[n] = "name";
        \\    ftypes[n] = []const u8;
        \\    fattrs[n] = .{};
        \\    n += 1;
        \\
        \\    fnames[n] = "js_name";
        \\    ftypes[n] = []const u8;
        \\    fattrs[n] = .{};
        \\    n += 1;
        \\
        \\    fnames[n] = "is_optional";
        \\    ftypes[n] = bool;
        \\    fattrs[n] = .{};
        \\    n += 1;
        \\
        \\    fnames[n] = "nullish";
        \\    ftypes[n] = NullishT;
        \\    fattrs[n] = .{};
        \\    n += 1;
        \\
        \\    const extras = [_][]const u8{
        \\        "expected_str",
        \\        "expected_num",
        \\        "expected_bool",
        \\        "expected_bigint_i64",
        \\        "expected_bigint_str",
        \\        "expected_enum_tag",
        \\    };
        \\    inline for (extras) |ex| {
        \\        if (@hasField(FmT, ex)) {
        \\            fnames[n] = ex;
        \\            ftypes[n] = @FieldType(FmT, ex);
        \\            fattrs[n] = .{};
        \\            n += 1;
        \\        }
        \\    }
        \\    const names_fin = fnames[0..n].*;
        \\    const types_fin = ftypes[0..n].*;
        \\    const attrs_fin = fattrs[0..n].*;
        \\    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
        \\}
        \\
        \\fn transformOneFieldDescriptor(
        \\    comptime T: type,
        \\    comptime fname: []const u8,
        \\    comptime mode: TransformMetaMode,
        \\) TransformFieldEntryType(T, fname, mode) {
        \\    const OutT = TransformFieldEntryType(T, fname, mode);
        \\    const wire = topStructFieldWireName(T, fname);
        \\    if (hasStructZigarJsMeta(T)) {
        \\        const meta = getStructZigarJsMeta(T);
        \\        if (@hasField(@TypeOf(meta), "fields")) {
        \\            inline for (meta.fields) |fm| {
        \\                if (std.mem.eql(u8, fm.name, fname)) {
        \\                    if (mode == .preserve) return fm;
        \\                    const FmT = @TypeOf(fm);
        \\                    var out: OutT = undefined;
        \\                    out.name = fname;
        \\                    out.js_name = wire;
        \\                    out.is_optional = (mode == .make_partial);
        \\                    out.nullish = computeTransformedNullish(T, fname, mode);
        \\                    const extras = [_][]const u8{
        \\                        "expected_str",
        \\                        "expected_num",
        \\                        "expected_bool",
        \\                        "expected_bigint_i64",
        \\                        "expected_bigint_str",
        \\                        "expected_enum_tag",
        \\                    };
        \\                    inline for (extras) |ex| {
        \\                        if (@hasField(FmT, ex)) {
        \\                            @field(out, ex) = @field(fm, ex);
        \\                        }
        \\                    }
        \\                    return out;
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return .{
        \\        .name = fname,
        \\        .js_name = wire,
        \\        .is_optional = (mode == .make_partial),
        \\        .nullish = if (mode == .make_partial) NullishKind.undefined_only else NullishKind.none,
        \\    };
        \\}
        \\
        \\fn buildStructMetaCarrier(
        \\    comptime T: type,
        \\    comptime kept_names: []const []const u8,
        \\    comptime mode: TransformMetaMode,
        \\) type {
        \\    comptime var entry_types: [kept_names.len]type = undefined;
        \\    inline for (kept_names, 0..) |fname, i| {
        \\        entry_types[i] = TransformFieldEntryType(T, fname, mode);
        \\    }
        \\    const FieldsTuple = @Tuple(&entry_types);
        \\    const fields_val = comptime blk: {
        \\        var tup: FieldsTuple = undefined;
        \\        for (kept_names, 0..) |fname, i| {
        \\            tup[i] = transformOneFieldDescriptor(T, fname, mode);
        \\        }
        \\        break :blk tup;
        \\    };
        \\    return struct {
        \\        pub const zigar_js = .{
        \\            .fields = fields_val,
        \\        };
        \\    };
        \\}
        \\
        \\fn defaultPtrForValue(comptime FieldT: type, comptime val: FieldT) *const anyopaque {
        \\    const Holder = struct {
        \\        const stored: FieldT = val;
        \\    };
        \\    return @ptrCast(&Holder.stored);
        \\}
        \\
        \\fn isComptimeKeyStringType(comptime KT: type) bool {
        \\    if (KT == []const u8) return true;
        \\    return switch (@typeInfo(KT)) {
        \\        .pointer => |pt| pt.size == .one and @typeInfo(pt.child) == .array and @typeInfo(pt.child).array.child == u8,
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn formatComptimeJsNumberKey(comptime n_any: anytype) []const u8 {
        \\    const NT = @TypeOf(n_any);
        \\    if (@typeInfo(NT) == .int or @typeInfo(NT) == .comptime_int) {
        \\        return std.fmt.comptimePrint("{d}", .{n_any});
        \\    }
        \\    const n: f64 = @floatCast(n_any);
        \\    if (n == 0.0) return "0";
        \\    if (std.math.isFinite(n) and @trunc(n) == n and @abs(n) <= 9007199254740991.0) {
        \\        return std.fmt.comptimePrint("{d}", .{@as(i64, @intFromFloat(n))});
        \\    }
        \\    return std.fmt.comptimePrint("{d}", .{n});
        \\}
        \\
        \\fn enumMemberWireKey(comptime m: anytype) []const u8 {
        \\    const MT = @TypeOf(m);
        \\    if (@hasField(MT, "str_value")) return m.str_value;
        \\    if (@hasField(MT, "num_value")) return formatComptimeJsNumberKey(m.num_value);
        \\    if (@hasField(MT, "int_value")) return formatComptimeJsNumberKey(m.int_value);
        \\    if (@hasField(MT, "float_value")) return formatComptimeJsNumberKey(m.float_value);
        \\    if (@hasField(MT, "bool_value")) return if (m.bool_value) "true" else "false";
        \\    if (@hasField(MT, "bigint_value")) return m.bigint_value;
        \\    if (@hasField(MT, "js_name")) return m.js_name;
        \\    return m.tag;
        \\}
        \\
        \\fn comptimeSnakeFieldName(comptime raw: []const u8) []const u8 {
        \\    if (raw.len == 0) return "_empty";
        \\    comptime var buf: [raw.len * 2 + 1]u8 = undefined;
        \\    comptime var out_len: usize = 0;
        \\    comptime var word_count: usize = 0;
        \\    comptime var i: usize = 0;
        \\    while (i < raw.len) {
        \\        while (i < raw.len and !std.ascii.isAlphanumeric(raw[i])) : (i += 1) {}
        \\        if (i >= raw.len) break;
        \\        const start = i;
        \\        if (std.ascii.isDigit(raw[i])) {
        \\            while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) {}
        \\            if (start == 0 and i < raw.len and std.ascii.isAlphabetic(raw[i])) {
        \\                while (i < raw.len and std.ascii.isAlphanumeric(raw[i]) and !std.ascii.isUpper(raw[i])) : (i += 1) {}
        \\            }
        \\        } else if (std.ascii.isUpper(raw[i])) {
        \\            i += 1;
        \\            if (i < raw.len and std.ascii.isUpper(raw[i])) {
        \\                while (i < raw.len and std.ascii.isUpper(raw[i])) : (i += 1) {}
        \\                if (i < raw.len and std.ascii.isLower(raw[i]) and (i - start) > 1) {
        \\                    i -= 1;
        \\                }
        \\            } else {
        \\                while (i < raw.len and (std.ascii.isLower(raw[i]) or std.ascii.isDigit(raw[i]))) : (i += 1) {}
        \\            }
        \\        } else {
        \\            while (i < raw.len and (std.ascii.isLower(raw[i]) or std.ascii.isDigit(raw[i]))) : (i += 1) {}
        \\        }
        \\        if (word_count > 0) {
        \\            buf[out_len] = '_';
        \\            out_len += 1;
        \\        }
        \\        for (raw[start..i]) |ch| {
        \\            buf[out_len] = std.ascii.toLower(ch);
        \\            out_len += 1;
        \\        }
        \\        word_count += 1;
        \\    }
        \\    if (word_count == 0) return "_";
        \\    const fin = buf[0..out_len].*;
        \\    return &fin;
        \\}
        \\
        \\fn isReservedRecordFieldName(comptime cand: []const u8, comptime used: []const []const u8) bool {
        \\    if (isHiddenMetaField(cand) or std.mem.eql(u8, cand, "zigar_js") or std.mem.eql(u8, cand, "zigar_js_tuple")) {
        \\        return true;
        \\    }
        \\    for (used) |u| {
        \\        if (std.mem.eql(u8, u, cand)) return true;
        \\    }
        \\    return false;
        \\}
        \\
        \\fn dedupeComptimeFieldName(comptime base: []const u8, comptime used: []const []const u8) []const u8 {
        \\    if (!isReservedRecordFieldName(base, used)) return base;
        \\    comptime var suffix: usize = 2;
        \\    while (true) : (suffix += 1) {
        \\        const cand = std.fmt.comptimePrint("{s}_{d}", .{ base, suffix });
        \\        if (!isReservedRecordFieldName(cand, used)) return cand;
        \\    }
        \\}
        \\
        \\fn canExtractSingleComptimeKey(comptime ItemT: type) bool {
        \\    if (isComptimeKeyStringType(ItemT)) return true;
        \\    return switch (@typeInfo(ItemT)) {
        \\        .enum_literal, .int, .comptime_int, .float, .comptime_float, .bool, .@"enum" => true,
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn extractSingleComptimeKey(comptime item: anytype) []const u8 {
        \\    const ItemT = @TypeOf(item);
        \\    if (isComptimeKeyStringType(ItemT)) return item;
        \\    return switch (@typeInfo(ItemT)) {
        \\        .enum_literal => @tagName(item),
        \\        .int, .comptime_int, .float, .comptime_float => formatComptimeJsNumberKey(item),
        \\        .bool => if (item) "true" else "false",
        \\        .@"enum" => blk: {
        \\            if (@hasDecl(ItemT, "zigar_js") and @hasField(@TypeOf(ItemT.zigar_js), "members")) {
        \\                for (ItemT.zigar_js.members) |m| {
        \\                    if (std.mem.eql(u8, m.tag, @tagName(item))) {
        \\                        break :blk enumMemberWireKey(m);
        \\                    }
        \\                }
        \\            }
        \\            break :blk @tagName(item);
        \\        },
        \\        else => @compileError("Unsupported key item for Pick/Omit/IndexAccess: " ++ @typeName(ItemT)),
        \\    };
        \\}
        \\
        \\fn isNumericPropertyKeyString(comptime s: []const u8) bool {
        \\    if (s.len == 0) return false;
        \\    const parsed = std.fmt.parseFloat(f64, s) catch return false;
        \\    return std.mem.eql(u8, formatComptimeJsNumberKey(parsed), s);
        \\}
        \\
        \\fn extractKeyListFromSpec(comptime keys_spec: anytype) []const []const u8 {
        \\    const SpecT = @TypeOf(keys_spec);
        \\    if (SpecT == type) {
        \\        if (keys_spec == void or keys_spec == noreturn) return &.{};
        \\        if (keys_spec == []const u8) return &.{};
        \\        switch (@typeInfo(keys_spec)) {
        \\            .@"enum" => |en| {
        \\                if (@hasDecl(keys_spec, "zigar_js") and @hasField(@TypeOf(keys_spec.zigar_js), "members")) {
        \\                    comptime var count: usize = 0;
        \\                    for (keys_spec.zigar_js.members) |m| {
        \\                        if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
        \\                        count += 1;
        \\                    }
        \\                    comptime var arr: [count][]const u8 = undefined;
        \\                    comptime var idx: usize = 0;
        \\                    for (keys_spec.zigar_js.members) |m| {
        \\                        if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
        \\                        arr[idx] = enumMemberWireKey(m);
        \\                        idx += 1;
        \\                    }
        \\                    const fin = arr;
        \\                    return &fin;
        \\                }
        \\                return en.field_names;
        \\            },
        \\            .@"union" => {
        \\                if (@hasDecl(keys_spec, "zigar_js") and @hasField(@TypeOf(keys_spec.zigar_js), "variants")) {
        \\                    comptime var count: usize = 0;
        \\                    for (keys_spec.zigar_js.variants) |v| {
        \\                        if (@hasField(@TypeOf(v), "is_unit_literal") and v.is_unit_literal) {
        \\                            count += 1;
        \\                        }
        \\                    }
        \\                    comptime var arr: [count][]const u8 = undefined;
        \\                    comptime var idx: usize = 0;
        \\                    for (keys_spec.zigar_js.variants) |v| {
        \\                        if (@hasField(@TypeOf(v), "is_unit_literal") and v.is_unit_literal) {
        \\                            arr[idx] = enumMemberWireKey(v);
        \\                            idx += 1;
        \\                        }
        \\                    }
        \\                    const fin = arr;
        \\                    return &fin;
        \\                }
        \\                return &.{};
        \\            },
        \\            else => return &.{},
        \\        }
        \\    }
        \\    if (canExtractSingleComptimeKey(SpecT)) {
        \\        const fin = [_][]const u8{extractSingleComptimeKey(keys_spec)};
        \\        return &fin;
        \\    }
        \\    switch (@typeInfo(SpecT)) {
        \\        .pointer => |pt| {
        \\            if (pt.size == .slice and canExtractSingleComptimeKey(pt.child)) {
        \\                comptime var arr: [keys_spec.len][]const u8 = undefined;
        \\                for (keys_spec, 0..) |item, i| {
        \\                    arr[i] = extractSingleComptimeKey(item);
        \\                }
        \\                const fin = arr;
        \\                return &fin;
        \\            }
        \\            if (pt.size == .one and @typeInfo(pt.child) == .@"struct" and @typeInfo(pt.child).@"struct".is_tuple) {
        \\                return extractKeyListFromSpec(keys_spec.*);
        \\            }
        \\            if (pt.size == .one and @typeInfo(pt.child) == .array) {
        \\                const ElemT = @typeInfo(pt.child).array.child;
        \\                if (canExtractSingleComptimeKey(ElemT)) {
        \\                    comptime var arr: [keys_spec.len][]const u8 = undefined;
        \\                    for (keys_spec, 0..) |item, i| {
        \\                        arr[i] = extractSingleComptimeKey(item);
        \\                    }
        \\                    const fin = arr;
        \\                    return &fin;
        \\                }
        \\            }
        \\        },
        \\        .@"struct" => |st| {
        \\            if (st.is_tuple) {
        \\                comptime var arr: [st.field_types.len][]const u8 = undefined;
        \\                inline for (0..st.field_types.len) |i| {
        \\                    arr[i] = extractSingleComptimeKey(keys_spec[i]);
        \\                }
        \\                const fin = arr;
        \\                return &fin;
        \\            }
        \\        },
        \\        else => {},
        \\    }
        \\    @compileError("Unsupported key specification for Pick/Omit/IndexAccess: " ++ @typeName(SpecT));
        \\}
        \\
        \\fn structHasExactWireKey(comptime T: type, comptime target_wire: []const u8) bool {
        \\    const st = @typeInfo(T).@"struct";
        \\    for (st.field_names) |other_fname| {
        \\        if (isHiddenMetaField(other_fname)) continue;
        \\        if (std.mem.eql(u8, topStructFieldWireName(T, other_fname), target_wire)) return true;
        \\    }
        \\    return false;
        \\}
        \\
        \\fn fieldMatchesAnyKey(comptime T: type, comptime fname: []const u8, comptime keys: []const []const u8) bool {
        \\    const wire = topStructFieldWireName(T, fname);
        \\    for (keys) |k| {
        \\        if (std.mem.eql(u8, wire, k)) return true;
        \\        if (!structHasExactWireKey(T, k) and std.mem.eql(u8, fname, k)) return true;
        \\    }
        \\    return false;
        \\}
        \\
        \\pub fn standalonePartial(comptime T: type) type {
        \\    @setEvalBranchQuota(200_000);
        \\    if (!isPlainValueStructForTransform(T)) return T;
        \\    const st = @typeInfo(T).@"struct";
        \\    const need_meta = hasStructZigarJsMeta(T);
        \\    comptime var real_count: usize = 0;
        \\    for (st.field_names) |fname| {
        \\        if (!isHiddenMetaField(fname)) real_count += 1;
        \\    }
        \\    const total_count = real_count + @intFromBool(need_meta);
        \\    comptime var kept_names: [real_count][]const u8 = undefined;
        \\    comptime var fnames: [total_count][]const u8 = undefined;
        \\    comptime var ftypes: [total_count]type = undefined;
        \\    comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;
        \\
        \\    comptime var out_i: usize = 0;
        \\    inline for (st.field_names, 0..) |fname, fi| {
        \\        if (comptime isHiddenMetaField(fname)) continue;
        \\        const OrigFT = st.field_types[fi];
        \\        const NewFT = if (@typeInfo(OrigFT) == .optional or isModuleNullableType(OrigFT)) OrigFT else ?OrigFT;
        \\        const def_ptr: *const anyopaque = if (isModuleNullableType(NewFT))
        \\            defaultPtrForValue(NewFT, .@"undefined")
        \\        else
        \\            defaultPtrForValue(NewFT, null);
        \\
        \\        kept_names[out_i] = fname;
        \\        fnames[out_i] = fname;
        \\        ftypes[out_i] = NewFT;
        \\        fattrs[out_i] = .{
        \\            .default_value_ptr = def_ptr,
        \\            .@"comptime" = false,
        \\            .@"align" = @alignOf(NewFT),
        \\        };
        \\        out_i += 1;
        \\    }
        \\
        \\    if (need_meta) {
        \\        const Carrier = buildStructMetaCarrier(T, &kept_names, .make_partial);
        \\        fnames[real_count] = hidden_meta_field_name;
        \\        ftypes[real_count] = Carrier;
        \\        fattrs[real_count] = .{
        \\            .default_value_ptr = defaultPtrForValue(Carrier, .{}),
        \\            .@"comptime" = false,
        \\            .@"align" = @alignOf(Carrier),
        \\        };
        \\    }
        \\
        \\    const names_fin = fnames;
        \\    const types_fin = ftypes;
        \\    const attrs_fin = fattrs;
        \\    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
        \\}
        \\
        \\pub fn standaloneRequired(comptime T: type) type {
        \\    @setEvalBranchQuota(200_000);
        \\    if (!isPlainValueStructForTransform(T)) return T;
        \\    const st = @typeInfo(T).@"struct";
        \\    const need_meta = hasStructZigarJsMeta(T);
        \\    comptime var real_count: usize = 0;
        \\    for (st.field_names) |fname| {
        \\        if (!isHiddenMetaField(fname)) real_count += 1;
        \\    }
        \\    const total_count = real_count + @intFromBool(need_meta);
        \\    comptime var kept_names: [real_count][]const u8 = undefined;
        \\    comptime var fnames: [total_count][]const u8 = undefined;
        \\    comptime var ftypes: [total_count]type = undefined;
        \\    comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;
        \\
        \\    comptime var out_i: usize = 0;
        \\    inline for (st.field_names, 0..) |fname, fi| {
        \\        if (comptime isHiddenMetaField(fname)) continue;
        \\        const OrigFT = st.field_types[fi];
        \\        const req_res = comptime requiredFieldResolution(T, fname, OrigFT);
        \\        const NewFT = req_res.ty;
        \\        const preserve_default = req_res.preserve_default;
        \\
        \\        kept_names[out_i] = fname;
        \\        fnames[out_i] = fname;
        \\        ftypes[out_i] = NewFT;
        \\        fattrs[out_i] = .{
        \\            .default_value_ptr = if (preserve_default) st.field_attrs[fi].default_value_ptr else null,
        \\            .@"comptime" = false,
        \\            .@"align" = @alignOf(NewFT),
        \\        };
        \\        out_i += 1;
        \\    }
        \\
        \\    if (need_meta) {
        \\        const Carrier = buildStructMetaCarrier(T, &kept_names, .make_required);
        \\        fnames[real_count] = hidden_meta_field_name;
        \\        ftypes[real_count] = Carrier;
        \\        fattrs[real_count] = .{
        \\            .default_value_ptr = defaultPtrForValue(Carrier, .{}),
        \\            .@"comptime" = false,
        \\            .@"align" = @alignOf(Carrier),
        \\        };
        \\    }
        \\
        \\    const names_fin = fnames;
        \\    const types_fin = ftypes;
        \\    const attrs_fin = fattrs;
        \\    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
        \\}
        \\
        \\pub fn standaloneReadonly(comptime T: type) type {
        \\    @setEvalBranchQuota(200_000);
        \\    return switch (@typeInfo(T)) {
        \\        .pointer => |pt| switch (pt.size) {
        \\            .slice => if (pt.attrs.@"const") T else []const pt.child,
        \\            .one => if (pt.attrs.@"const") T else *const pt.child,
        \\            else => T,
        \\        },
        \\        .@"struct" => |st| blk: {
        \\            if (!isPlainValueStructForTransform(T)) break :blk T;
        \\            const need_meta = hasStructZigarJsMeta(T);
        \\            comptime var real_count: usize = 0;
        \\            for (st.field_names) |fname| {
        \\                if (!isHiddenMetaField(fname)) real_count += 1;
        \\            }
        \\            const total_count = real_count + @intFromBool(need_meta);
        \\            comptime var kept_names: [real_count][]const u8 = undefined;
        \\            comptime var fnames: [total_count][]const u8 = undefined;
        \\            comptime var ftypes: [total_count]type = undefined;
        \\            comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;
        \\
        \\            comptime var out_i: usize = 0;
        \\            inline for (st.field_names, 0..) |fname, fi| {
        \\                if (comptime isHiddenMetaField(fname)) continue;
        \\                const OrigFT = st.field_types[fi];
        \\                kept_names[out_i] = fname;
        \\                fnames[out_i] = fname;
        \\                ftypes[out_i] = OrigFT;
        \\                fattrs[out_i] = st.field_attrs[fi];
        \\                out_i += 1;
        \\            }
        \\
        \\            if (need_meta) {
        \\                const Carrier = buildStructMetaCarrier(T, &kept_names, .preserve);
        \\                fnames[real_count] = hidden_meta_field_name;
        \\                ftypes[real_count] = Carrier;
        \\                fattrs[real_count] = .{
        \\                    .default_value_ptr = defaultPtrForValue(Carrier, .{}),
        \\                    .@"comptime" = false,
        \\                    .@"align" = @alignOf(Carrier),
        \\                };
        \\            }
        \\
        \\            const names_fin = fnames;
        \\            const types_fin = ftypes;
        \\            const attrs_fin = fattrs;
        \\            break :blk @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
        \\        },
        \\        else => T,
        \\    };
        \\}
        \\
        \\fn filterStructFields(comptime T: type, comptime keys_spec: anytype, comptime include_matched: bool) type {
        \\    @setEvalBranchQuota(200_000);
        \\    if (!isPlainValueStructForTransform(T)) return T;
        \\    const st = @typeInfo(T).@"struct";
        \\    const keys = comptime extractKeyListFromSpec(keys_spec);
        \\    const need_meta = hasStructZigarJsMeta(T);
        \\
        \\    comptime var real_count: usize = 0;
        \\    inline for (st.field_names) |fname| {
        \\        if (comptime isHiddenMetaField(fname)) continue;
        \\        const matched = comptime fieldMatchesAnyKey(T, fname, keys);
        \\        if (matched == include_matched) real_count += 1;
        \\    }
        \\
        \\    const total_count = real_count + @intFromBool(need_meta and real_count > 0);
        \\    comptime var kept_names: [real_count][]const u8 = undefined;
        \\    comptime var fnames: [total_count][]const u8 = undefined;
        \\    comptime var ftypes: [total_count]type = undefined;
        \\    comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;
        \\
        \\    comptime var out_i: usize = 0;
        \\    inline for (st.field_names, 0..) |fname, fi| {
        \\        if (comptime isHiddenMetaField(fname)) continue;
        \\        const matched = comptime fieldMatchesAnyKey(T, fname, keys);
        \\        if (matched != include_matched) continue;
        \\        kept_names[out_i] = fname;
        \\        fnames[out_i] = fname;
        \\        ftypes[out_i] = st.field_types[fi];
        \\        fattrs[out_i] = st.field_attrs[fi];
        \\        out_i += 1;
        \\    }
        \\
        \\    if (need_meta and real_count > 0) {
        \\        const Carrier = buildStructMetaCarrier(T, &kept_names, .preserve);
        \\        fnames[real_count] = hidden_meta_field_name;
        \\        ftypes[real_count] = Carrier;
        \\        fattrs[real_count] = .{
        \\            .default_value_ptr = defaultPtrForValue(Carrier, .{}),
        \\            .@"comptime" = false,
        \\            .@"align" = @alignOf(Carrier),
        \\        };
        \\    }
        \\
        \\    const names_fin = fnames;
        \\    const types_fin = ftypes;
        \\    const attrs_fin = fattrs;
        \\    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
        \\}
        \\
        \\pub fn standalonePick(comptime T: type, comptime keys_spec: anytype) type {
        \\    return filterStructFields(T, keys_spec, true);
        \\}
        \\
        \\pub fn standaloneOmit(comptime T: type, comptime keys_spec: anytype) type {
        \\    return filterStructFields(T, keys_spec, false);
        \\}
        \\
        \\pub fn standaloneEnumRecord(comptime K: type, comptime V: type) type {
        \\    @setEvalBranchQuota(200_000);
        \\    const en = @typeInfo(K).@"enum";
        \\    const ValIsOptional = (@typeInfo(V) == .optional or isModuleNullableType(V));
        \\
        \\    const MetaEntry = struct {
        \\        name: []const u8,
        \\        js_name: []const u8,
        \\        is_optional: bool,
        \\        nullish: NullishKind,
        \\    };
        \\
        \\    if (@hasDecl(K, "zigar_js") and @hasField(@TypeOf(K.zigar_js), "members")) {
        \\        comptime var real_count: usize = 0;
        \\        for (K.zigar_js.members) |m| {
        \\            if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
        \\            real_count += 1;
        \\        }
        \\        comptime var chosen_names: [real_count][]const u8 = undefined;
        \\        comptime var chosen_wires: [real_count][]const u8 = undefined;
        \\        comptime var any_renamed = false;
        \\        comptime var pass_i: usize = 0;
        \\        for (K.zigar_js.members) |m| {
        \\            if (@hasField(@TypeOf(m), "is_alias") and m.is_alias) continue;
        \\            const wire = enumMemberWireKey(m);
        \\            const fname = dedupeComptimeFieldName(comptimeSnakeFieldName(wire), chosen_names[0..pass_i]);
        \\            chosen_names[pass_i] = fname;
        \\            chosen_wires[pass_i] = wire;
        \\            if (!std.mem.eql(u8, wire, fname)) {
        \\                any_renamed = true;
        \\            }
        \\            pass_i += 1;
        \\        }
        \\        const need_meta = any_renamed or ValIsOptional;
        \\        const total_count = real_count + @intFromBool(need_meta);
        \\        comptime var fnames: [total_count][]const u8 = undefined;
        \\        comptime var ftypes: [total_count]type = undefined;
        \\        comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;
        \\
        \\        comptime var meta_entries: [real_count]MetaEntry = undefined;
        \\        for (0..real_count) |out_i| {
        \\            const fname = chosen_names[out_i];
        \\            const wire = chosen_wires[out_i];
        \\            fnames[out_i] = fname;
        \\            ftypes[out_i] = V;
        \\            fattrs[out_i] = .{
        \\                .default_value_ptr = null,
        \\                .@"comptime" = false,
        \\                .@"align" = @alignOf(V),
        \\            };
        \\            meta_entries[out_i] = .{
        \\                .name = fname,
        \\                .js_name = wire,
        \\                .is_optional = false,
        \\                .nullish = if (ValIsOptional) NullishKind.null_only else NullishKind.none,
        \\            };
        \\        }
        \\        if (need_meta) {
        \\            const entries_fin = meta_entries;
        \\            const Carrier = struct {
        \\                pub const zigar_js = .{
        \\                    .fields = entries_fin,
        \\                };
        \\            };
        \\            fnames[real_count] = hidden_meta_field_name;
        \\            ftypes[real_count] = Carrier;
        \\            fattrs[real_count] = .{
        \\                .default_value_ptr = defaultPtrForValue(Carrier, .{}),
        \\                .@"comptime" = false,
        \\                .@"align" = @alignOf(Carrier),
        \\            };
        \\        }
        \\        const names_fin = fnames;
        \\        const types_fin = ftypes;
        \\        const attrs_fin = fattrs;
        \\        return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
        \\    }
        \\
        \\    const real_count = en.field_names.len;
        \\    const need_meta = ValIsOptional;
        \\    const total_count = real_count + @intFromBool(need_meta);
        \\    comptime var fnames: [total_count][]const u8 = undefined;
        \\    comptime var ftypes: [total_count]type = undefined;
        \\    comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;
        \\    comptime var meta_entries: [real_count]MetaEntry = undefined;
        \\    for (en.field_names, 0..) |fname, i| {
        \\        fnames[i] = fname;
        \\        ftypes[i] = V;
        \\        fattrs[i] = .{
        \\            .default_value_ptr = null,
        \\            .@"comptime" = false,
        \\            .@"align" = @alignOf(V),
        \\        };
        \\        meta_entries[i] = .{
        \\            .name = fname,
        \\            .js_name = fname,
        \\            .is_optional = false,
        \\            .nullish = if (ValIsOptional) NullishKind.null_only else NullishKind.none,
        \\        };
        \\    }
        \\    if (need_meta) {
        \\        const entries_fin = meta_entries;
        \\        const Carrier = struct {
        \\            pub const zigar_js = .{
        \\                .fields = entries_fin,
        \\            };
        \\        };
        \\        fnames[real_count] = hidden_meta_field_name;
        \\        ftypes[real_count] = Carrier;
        \\        fattrs[real_count] = .{
        \\            .default_value_ptr = defaultPtrForValue(Carrier, .{}),
        \\            .@"comptime" = false,
        \\            .@"align" = @alignOf(Carrier),
        \\        };
        \\    }
        \\    const names_fin = fnames;
        \\    const types_fin = ftypes;
        \\    const attrs_fin = fattrs;
        \\    return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
        \\}
        \\
        \\pub fn standaloneMappedValues(comptime T: type, comptime V: type) type {
        \\    return standaloneMappedValuesSpec(T, V, .auto);
        \\}
        \\
        \\pub fn standaloneMappedValuesSpec(
        \\    comptime T: type,
        \\    comptime V: type,
        \\    comptime v_spec: anytype,
        \\) type {
        \\    @setEvalBranchQuota(200_000);
        \\    switch (@typeInfo(T)) {
        \\        .pointer => |pt| {
        \\            if (pt.size == .slice) {
        \\                if (pt.child == u8) return T;
        \\                return if (pt.attrs.@"const") []const V else []V;
        \\            }
        \\            return StubRecord(standaloneKeyOf(T), V);
        \\        },
        \\        .array => |ar| return [ar.len]V,
        \\        .int, .float, .bool, .void => return T,
        \\        .@"struct" => |st| {
        \\            if (st.is_tuple) return [st.field_types.len]V;
        \\            if (@hasDecl(T, "is_js_array") and T.is_js_array) return []const V;
        \\            if (@hasDecl(T, "is_js_bigint") and T.is_js_bigint) return T;
        \\            if (@hasDecl(T, "zigar_js_tuple")) {
        \\                const has_var = @hasField(@TypeOf(T.zigar_js_tuple), "variadic_index") and T.zigar_js_tuple.variadic_index != null;
        \\                const has_opt = blk: {
        \\                    for (st.field_attrs) |fa| {
        \\                        if (fa.default_value_ptr != null) break :blk true;
        \\                    }
        \\                    if (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "fields")) {
        \\                        inline for (T.zigar_js.fields) |fm| {
        \\                            if (@hasField(@TypeOf(fm), "is_optional") and fm.is_optional) break :blk true;
        \\                        }
        \\                    }
        \\                    break :blk false;
        \\                };
        \\                if (has_var or has_opt) return []const V;
        \\                return [st.field_types.len]V;
        \\            }
        \\            if (isPlainValueStructForTransform(T)) {
        \\                comptime var real_count: usize = 0;
        \\                for (st.field_names) |fname| {
        \\                    if (!isHiddenMetaField(fname)) real_count += 1;
        \\                }
        \\                if (real_count == 0) return struct {};
        \\
        \\                const req_spec = comptime blk: {
        \\                    const VSpecT = @TypeOf(v_spec);
        \\                    if (@typeInfo(VSpecT) == .enum_literal) {
        \\                        if (v_spec == .auto) {
        \\                            break :blk if (isModuleNullableType(V))
        \\                                NullishKind.null_or_undefined
        \\                            else if (@typeInfo(V) == .optional)
        \\                                NullishKind.null_only
        \\                            else
        \\                                NullishKind.none;
        \\                        }
        \\                        break :blk @as(NullishKind, v_spec);
        \\                    }
        \\                    break :blk v_spec;
        \\                };
        \\                const opt_spec = comptime blk: {
        \\                    if (@typeInfo(V) == .optional or isModuleNullableType(V)) {
        \\                        const cur_self = specTopSelfNullish(req_spec);
        \\                        const merged_self: NullishKind = if (isModuleNullableType(V) or cur_self == .null_only or cur_self == .null_or_undefined)
        \\                            .null_or_undefined
        \\                        else
        \\                            .undefined_only;
        \\                        break :blk rebuildSpecWithSelf(req_spec, merged_self);
        \\                    }
        \\                    break :blk wrapSpecAsOptional(req_spec, .undefined_only);
        \\                };
        \\
        \\                const ReqEntryT = struct {
        \\                    name: []const u8,
        \\                    js_name: []const u8,
        \\                    is_optional: bool,
        \\                    nullish: @TypeOf(req_spec),
        \\                };
        \\                const OptEntryT = struct {
        \\                    name: []const u8,
        \\                    js_name: []const u8,
        \\                    is_optional: bool,
        \\                    nullish: @TypeOf(opt_spec),
        \\                };
        \\
        \\                comptime var any_opt = false;
        \\                inline for (st.field_names, 0..) |fname, fi| {
        \\                    if (comptime isHiddenMetaField(fname)) continue;
        \\                    if (comptime topStructFieldIsOptional(T, fname, st.field_attrs[fi].default_value_ptr != null)) {
        \\                        any_opt = true;
        \\                    }
        \\                }
        \\
        \\                const req_needs_meta = (@TypeOf(req_spec) != NullishKind) or (req_spec != NullishKind.none);
        \\                const need_meta = hasStructZigarJsMeta(T) or any_opt or req_needs_meta;
        \\                const total_count = real_count + @intFromBool(need_meta);
        \\
        \\                comptime var fnames: [total_count][]const u8 = undefined;
        \\                comptime var ftypes: [total_count]type = undefined;
        \\                comptime var fattrs: [total_count]std.builtin.Type.Struct.FieldAttributes = undefined;
        \\                comptime var entry_types: [real_count]type = undefined;
        \\
        \\                comptime var out_i: usize = 0;
        \\                inline for (st.field_names, 0..) |fname, fi| {
        \\                    if (comptime isHiddenMetaField(fname)) continue;
        \\                    const src_is_opt = comptime topStructFieldIsOptional(T, fname, st.field_attrs[fi].default_value_ptr != null);
        \\                    if (src_is_opt) {
        \\                        const NewFT = if (@typeInfo(V) == .optional or isModuleNullableType(V)) V else ?V;
        \\                        const def_ptr: *const anyopaque = if (isModuleNullableType(NewFT))
        \\                            defaultPtrForValue(NewFT, .@"undefined")
        \\                        else
        \\                            defaultPtrForValue(NewFT, null);
        \\                        fnames[out_i] = fname;
        \\                        ftypes[out_i] = NewFT;
        \\                        fattrs[out_i] = .{
        \\                            .default_value_ptr = def_ptr,
        \\                            .@"comptime" = false,
        \\                            .@"align" = @alignOf(NewFT),
        \\                        };
        \\                        entry_types[out_i] = OptEntryT;
        \\                    } else {
        \\                        fnames[out_i] = fname;
        \\                        ftypes[out_i] = V;
        \\                        fattrs[out_i] = .{
        \\                            .default_value_ptr = null,
        \\                            .@"comptime" = false,
        \\                            .@"align" = @alignOf(V),
        \\                        };
        \\                        entry_types[out_i] = ReqEntryT;
        \\                    }
        \\                    out_i += 1;
        \\                }
        \\
        \\                if (need_meta) {
        \\                    const FieldsTuple = @Tuple(&entry_types);
        \\                    const fields_val = comptime blk: {
        \\                        var tup: FieldsTuple = undefined;
        \\                        var ti: usize = 0;
        \\                        for (st.field_names, 0..) |fname, fi| {
        \\                            if (isHiddenMetaField(fname)) continue;
        \\                            const wire = topStructFieldWireName(T, fname);
        \\                            const src_is_opt = topStructFieldIsOptional(T, fname, st.field_attrs[fi].default_value_ptr != null);
        \\                            if (src_is_opt) {
        \\                                tup[ti] = OptEntryT{
        \\                                    .name = fname,
        \\                                    .js_name = wire,
        \\                                    .is_optional = true,
        \\                                    .nullish = opt_spec,
        \\                                };
        \\                            } else {
        \\                                tup[ti] = ReqEntryT{
        \\                                    .name = fname,
        \\                                    .js_name = wire,
        \\                                    .is_optional = false,
        \\                                    .nullish = req_spec,
        \\                                };
        \\                            }
        \\                            ti += 1;
        \\                        }
        \\                        break :blk tup;
        \\                    };
        \\                    const Carrier = struct {
        \\                        pub const zigar_js = .{
        \\                            .fields = fields_val,
        \\                        };
        \\                    };
        \\                    fnames[real_count] = hidden_meta_field_name;
        \\                    ftypes[real_count] = Carrier;
        \\                    fattrs[real_count] = .{
        \\                        .default_value_ptr = defaultPtrForValue(Carrier, .{}),
        \\                        .@"comptime" = false,
        \\                        .@"align" = @alignOf(Carrier),
        \\                    };
        \\                }
        \\
        \\                const names_fin = fnames;
        \\                const types_fin = ftypes;
        \\                const attrs_fin = fattrs;
        \\                return @Struct(.auto, null, &names_fin, &types_fin, &attrs_fin);
        \\            }
        \\            return StubRecord(standaloneKeyOf(T), V);
        \\        },
        \\        else => return StubRecord(standaloneKeyOf(T), V),
        \\    }
        \\}
        \\
        \\pub fn standaloneNonNullable(comptime T: type) type {
        \\    if (@typeInfo(T) == .optional) return standaloneNonNullable(@typeInfo(T).optional.child);
        \\    if (isModuleNullableType(T)) return standaloneNonNullable(T.Value);
        \\    return T;
        \\}
        \\
        \\fn buildSynthesizedUnion(comptime member_types: []const type) type {
        \\    const count = member_types.len;
        \\    if (count == 0) return noreturn;
        \\    if (count == 1) return member_types[0];
        \\    const TagInt = std.math.IntFittingRange(0, count - 1);
        \\    comptime var fnames: [count][]const u8 = undefined;
        \\    comptime var ftypes: [count]type = undefined;
        \\    comptime var fattrs: [count]std.builtin.Type.Union.FieldAttributes = undefined;
        \\    comptime var tag_vals: [count]TagInt = undefined;
        \\    for (member_types, 0..) |mt, i| {
        \\        fnames[i] = std.fmt.comptimePrint("v{d}", .{i});
        \\        ftypes[i] = mt;
        \\        fattrs[i] = .{};
        \\        tag_vals[i] = i;
        \\    }
        \\    const names_fin = fnames;
        \\    const types_fin = ftypes;
        \\    const attrs_fin = fattrs;
        \\    const vals_fin = tag_vals;
        \\    const Tag = @Enum(TagInt, .exhaustive, &names_fin, &vals_fin);
        \\    return @Union(.auto, Tag, &names_fin, &types_fin, &attrs_fin);
        \\}
        \\
        \\pub fn standaloneAwaited(comptime T: type) type {
        \\    if (@typeInfo(T) == .@"struct") {
        \\        if (@hasDecl(T, "is_js_promise") and T.is_js_promise and @hasDecl(T, "Payload")) {
        \\            return standaloneAwaited(T.Payload);
        \\        }
        \\        if (@hasDecl(T, "Target") and @TypeOf(T.Target) == type and @typeInfo(T.Target) == .@"struct") {
        \\            if (@hasDecl(T.Target, "is_js_promise") and T.Target.is_js_promise and @hasDecl(T.Target, "Payload")) {
        \\                return standaloneAwaited(T.Target.Payload);
        \\            }
        \\        }
        \\    }
        \\    if (@typeInfo(T) == .@"union" and @typeInfo(T).@"union".tag_type != null and !isModuleNullableType(T)) {
        \\        const un = @typeInfo(T).@"union";
        \\        comptime var any_changed = false;
        \\        comptime var distinct: [un.field_types.len]type = undefined;
        \\        comptime var d_len: usize = 0;
        \\        for (un.field_types) |ft| {
        \\            const aw = standaloneAwaited(ft);
        \\            if (aw != ft) any_changed = true;
        \\            var seen = false;
        \\            for (distinct[0..d_len]) |prev| {
        \\                if (prev == aw) {
        \\                    seen = true;
        \\                    break;
        \\                }
        \\            }
        \\            if (!seen) {
        \\                distinct[d_len] = aw;
        \\                d_len += 1;
        \\            }
        \\        }
        \\        if (any_changed) {
        \\            if (d_len == 1) return distinct[0];
        \\            return buildSynthesizedUnion(distinct[0..d_len]);
        \\        }
        \\    }
        \\    return T;
        \\}
        \\
        \\pub fn standaloneKeyOf(comptime T: type) type {
        \\    @setEvalBranchQuota(200_000);
        \\    switch (@typeInfo(T)) {
        \\        .@"struct" => |st| {
        \\            if (isPlainValueStructForTransform(T)) {
        \\                comptime var max_count: usize = 0;
        \\                for (st.field_names) |fname| {
        \\                    if (!isHiddenMetaField(fname)) max_count += 1;
        \\                }
        \\                if (max_count == 0) return noreturn;
        \\                comptime var names_buf: [max_count][]const u8 = undefined;
        \\                comptime var count: usize = 0;
        \\                for (st.field_names) |fname| {
        \\                    if (isHiddenMetaField(fname)) continue;
        \\                    const w = topStructFieldWireName(T, fname);
        \\                    var dup = false;
        \\                    for (names_buf[0..count]) |prev| {
        \\                        if (std.mem.eql(u8, prev, w)) {
        \\                            dup = true;
        \\                            break;
        \\                        }
        \\                    }
        \\                    if (!dup) {
        \\                        names_buf[count] = w;
        \\                        count += 1;
        \\                    }
        \\                }
        \\                if (count == 0) return noreturn;
        \\                const TagInt = std.math.IntFittingRange(0, count - 1);
        \\                comptime var vals: [count]TagInt = undefined;
        \\                for (0..count) |i| vals[i] = i;
        \\                const names_fin = names_buf[0..count].*;
        \\                const vals_fin = vals;
        \\                return @Enum(TagInt, .exhaustive, &names_fin, &vals_fin);
        \\            }
        \\            if (isGeneratedHandleStruct(T) and @hasField(@TypeOf(T.zigar_js), "fields")) {
        \\                const fmeta = T.zigar_js.fields;
        \\                const mmeta = if (@hasField(@TypeOf(T.zigar_js), "methods")) T.zigar_js.methods else .{};
        \\                const max_len = fmeta.len + mmeta.len;
        \\                if (max_len == 0) return []const u8;
        \\                comptime var names_buf: [max_len][]const u8 = undefined;
        \\                comptime var count: usize = 0;
        \\                for (fmeta) |fm| {
        \\                    const w = if (@hasField(@TypeOf(fm), "js_name")) fm.js_name else fm.name;
        \\                    var dup = false;
        \\                    for (names_buf[0..count]) |prev| {
        \\                        if (std.mem.eql(u8, prev, w)) {
        \\                            dup = true;
        \\                            break;
        \\                        }
        \\                    }
        \\                    if (!dup) {
        \\                        names_buf[count] = w;
        \\                        count += 1;
        \\                    }
        \\                }
        \\                for (mmeta) |mm| {
        \\                    if (@hasField(@TypeOf(mm), "is_static") and mm.is_static) continue;
        \\                    const w = if (@hasField(@TypeOf(mm), "js_name")) mm.js_name else mm.name;
        \\                    var dup = false;
        \\                    for (names_buf[0..count]) |prev| {
        \\                        if (std.mem.eql(u8, prev, w)) {
        \\                            dup = true;
        \\                            break;
        \\                        }
        \\                    }
        \\                    if (!dup) {
        \\                        names_buf[count] = w;
        \\                        count += 1;
        \\                    }
        \\                }
        \\                if (count == 0) return []const u8;
        \\                const TagInt = std.math.IntFittingRange(0, count - 1);
        \\                comptime var vals: [count]TagInt = undefined;
        \\                for (0..count) |i| vals[i] = i;
        \\                const names_fin = names_buf[0..count].*;
        \\                const vals_fin = vals;
        \\                return @Enum(TagInt, .exhaustive, &names_fin, &vals_fin);
        \\            }
        \\            if (@hasDecl(T, "is_js_record") and T.is_js_record and @hasDecl(T, "Key")) {
        \\                return T.Key;
        \\            }
        \\            return []const u8;
        \\        },
        \\        .pointer => |pt| {
        \\            if (pt.size == .slice) return f64;
        \\            return []const u8;
        \\        },
        \\        else => return []const u8,
        \\    }
        \\}
        \\
        \\fn isNumericIndexKeySpec(comptime keys_spec: anytype) ?usize {
        \\    const SpecT = @TypeOf(keys_spec);
        \\    if (SpecT == comptime_int or @typeInfo(SpecT) == .int) {
        \\        if (keys_spec < 0) @compileError("Negative tuple/array index in IndexAccess");
        \\        return @intCast(keys_spec);
        \\    }
        \\    return null;
        \\}
        \\
        \\fn isBroadNumericIndexType(comptime keys_spec: anytype) bool {
        \\    if (@TypeOf(keys_spec) != type) return false;
        \\    return switch (@typeInfo(keys_spec)) {
        \\        .int, .float => true,
        \\        else => false,
        \\    };
        \\}
        \\
        \\pub fn standaloneIndexAccess(comptime T: type, comptime keys_spec: anytype) type {
        \\    @setEvalBranchQuota(200_000);
        \\    switch (@typeInfo(T)) {
        \\        .pointer => |pt| {
        \\            if (pt.size == .slice) {
        \\                if (isNumericIndexKeySpec(keys_spec) != null or isBroadNumericIndexType(keys_spec)) {
        \\                    return pt.child;
        \\                }
        \\            }
        \\        },
        \\        .array => |ar| {
        \\            if (isNumericIndexKeySpec(keys_spec) != null or isBroadNumericIndexType(keys_spec)) {
        \\                return ar.child;
        \\            }
        \\        },
        \\        .@"struct" => |st| {
        \\            if (@hasDecl(T, "is_js_record") and T.is_js_record and @hasDecl(T, "Value")) {
        \\                return T.Value;
        \\            }
        \\            if (@hasDecl(T, "is_js_array") and T.is_js_array and (@hasDecl(T, "Elem") or @hasDecl(T, "Element"))) {
        \\                if (isNumericIndexKeySpec(keys_spec) != null or isBroadNumericIndexType(keys_spec)) {
        \\                    return if (@hasDecl(T, "Elem")) T.Elem else T.Element;
        \\                }
        \\            }
        \\            if (st.is_tuple or @hasDecl(T, "zigar_js_tuple")) {
        \\                if (isNumericIndexKeySpec(keys_spec)) |idx| {
        \\                    if (idx < st.field_types.len) return st.field_types[idx];
        \\                    @compileError("Tuple index out of bounds in IndexAccess");
        \\                }
        \\                if (isBroadNumericIndexType(keys_spec)) {
        \\                    comptime var distinct: [st.field_types.len]type = undefined;
        \\                    comptime var d_len: usize = 0;
        \\                    for (st.field_types, 0..) |ft, fi| {
        \\                        const elem_t = if (@hasDecl(T, "zigar_js_tuple") and @hasField(@TypeOf(T.zigar_js_tuple), "variadic_index") and T.zigar_js_tuple.variadic_index != null and T.zigar_js_tuple.variadic_index.? == fi and @typeInfo(ft) == .pointer and @typeInfo(ft).pointer.size == .slice)
        \\                            @typeInfo(ft).pointer.child
        \\                        else
        \\                            ft;
        \\                        var seen = false;
        \\                        for (distinct[0..d_len]) |prev| {
        \\                            if (prev == elem_t) {
        \\                                seen = true;
        \\                                break;
        \\                            }
        \\                        }
        \\                        if (!seen) {
        \\                            distinct[d_len] = elem_t;
        \\                            d_len += 1;
        \\                        }
        \\                    }
        \\                    return buildSynthesizedUnion(distinct[0..d_len]);
        \\                }
        \\            }
        \\            if (isPlainValueStructForTransform(T)) {
        \\                if (@TypeOf(keys_spec) == type and keys_spec == []const u8) {
        \\                    return Any;
        \\                }
        \\                if (isBroadNumericIndexType(keys_spec)) {
        \\                    comptime var distinct_num: [st.field_types.len]type = undefined;
        \\                    comptime var dn_len: usize = 0;
        \\                    for (st.field_names, 0..) |fname, fi| {
        \\                        if (isHiddenMetaField(fname)) continue;
        \\                        if (!isNumericPropertyKeyString(topStructFieldWireName(T, fname))) continue;
        \\                        const ft = st.field_types[fi];
        \\                        var seen = false;
        \\                        for (distinct_num[0..dn_len]) |prev| {
        \\                            if (prev == ft) {
        \\                                seen = true;
        \\                                break;
        \\                            }
        \\                        }
        \\                        if (!seen) {
        \\                            distinct_num[dn_len] = ft;
        \\                            dn_len += 1;
        \\                        }
        \\                    }
        \\                    if (dn_len > 0) return buildSynthesizedUnion(distinct_num[0..dn_len]);
        \\                    return Any;
        \\                }
        \\                const keys = comptime extractKeyListFromSpec(keys_spec);
        \\                if (keys.len == 0) return noreturn;
        \\                comptime var distinct: [st.field_types.len]type = undefined;
        \\                comptime var d_len: usize = 0;
        \\                for (st.field_names, 0..) |fname, fi| {
        \\                    if (isHiddenMetaField(fname)) continue;
        \\                    if (!fieldMatchesAnyKey(T, fname, keys)) continue;
        \\                    const ft = st.field_types[fi];
        \\                    var seen = false;
        \\                    for (distinct[0..d_len]) |prev| {
        \\                        if (prev == ft) {
        \\                            seen = true;
        \\                            break;
        \\                        }
        \\                    }
        \\                    if (!seen) {
        \\                        distinct[d_len] = ft;
        \\                        d_len += 1;
        \\                    }
        \\                }
        \\                if (d_len > 0) return buildSynthesizedUnion(distinct[0..d_len]);
        \\                return Any;
        \\            }
        \\        },
        \\        else => {},
        \\    }
        \\    return Any;
        \\}
        \\
        \\pub fn standaloneInferJsType(comptime Arg: type) type {
        \\    if (Arg == comptime_int or Arg == comptime_float) return f64;
        \\    if (Arg == @TypeOf(null) or Arg == @TypeOf(undefined)) return Any;
        \\    return switch (@typeInfo(Arg)) {
        \\        .enum_literal => @compileError("zigar.js: pass a concrete enum value or string slice instead of an untyped enum literal"),
        \\        .pointer => |pt| blk: {
        \\            if (pt.size == .one and @typeInfo(pt.child) == .array) {
        \\                const elem = @typeInfo(pt.child).array.child;
        \\                if (elem == comptime_int or elem == comptime_float) break :blk []const f64;
        \\                break :blk []const elem;
        \\            }
        \\            break :blk Arg;
        \\        },
        \\        else => Arg,
        \\    };
        \\}
        \\
        \\pub fn standaloneInferConstJsType(comptime Arg: type) type {
        \\    if (Arg == comptime_int or Arg == comptime_float) return f64;
        \\    if (Arg == @TypeOf(null) or Arg == @TypeOf(undefined)) return Any;
        \\    return switch (@typeInfo(Arg)) {
        \\        .enum_literal => @compileError("zigar.js: pass a concrete enum value or string slice instead of an untyped enum literal"),
        \\        .pointer => |pt| blk: {
        \\            if (pt.size == .one and @typeInfo(pt.child) == .array) {
        \\                const ar = @typeInfo(pt.child).array;
        \\                if (ar.child == u8 and ar.sentinel() != null) break :blk []const u8;
        \\                const elem = if (ar.child == comptime_int or ar.child == comptime_float) f64 else ar.child;
        \\                break :blk [ar.len]elem;
        \\            }
        \\            break :blk Arg;
        \\        },
        \\        .array => |ar| blk: {
        \\            const elem = if (ar.child == comptime_int or ar.child == comptime_float) f64 else ar.child;
        \\            break :blk [ar.len]elem;
        \\        },
        \\        else => Arg,
        \\    };
        \\}
        \\
        \\pub fn standaloneIsConstArrayPtr(comptime Arg: type) bool {
        \\    return switch (@typeInfo(Arg)) {
        \\        .pointer => |pt| blk: {
        \\            if (pt.size == .one and @typeInfo(pt.child) == .array) {
        \\                const ar = @typeInfo(pt.child).array;
        \\                if (ar.child == u8 and ar.sentinel() != null) break :blk false;
        \\                break :blk true;
        \\            }
        \\            break :blk false;
        \\        },
        \\        else => false,
        \\    };
        \\}
        \\
        \\pub fn standaloneInferSliceElem(comptime S: type) type {
        \\    return switch (@typeInfo(S)) {
        \\        .pointer => |pt| blk: {
        \\            if (pt.size == .slice) {
        \\                if (pt.child == comptime_int or pt.child == comptime_float) break :blk f64;
        \\                break :blk pt.child;
        \\            }
        \\            if (pt.size == .one and @typeInfo(pt.child) == .array) {
        \\                const elem = @typeInfo(pt.child).array.child;
        \\                if (elem == comptime_int or elem == comptime_float) break :blk f64;
        \\                break :blk elem;
        \\            }
        \\            @compileError("zigar.js: expected slice or array pointer argument for generic element inference, got " ++ @typeName(S));
        \\        },
        \\        .array => |ar| if (ar.child == comptime_int or ar.child == comptime_float) f64 else ar.child,
        \\        else => @compileError("zigar.js: expected slice or array argument for generic element inference, got " ++ @typeName(S)),
        \\    };
        \\}
        \\
        \\pub fn standaloneInferOptionalChild(comptime Opt: type) type {
        \\    if (Opt == @TypeOf(null) or Opt == @TypeOf(undefined)) return Any;
        \\    return switch (@typeInfo(Opt)) {
        \\        .optional => |op| standaloneInferJsType(op.child),
        \\        else => standaloneInferJsType(Opt),
        \\    };
        \\}
        \\
        \\fn isRefToTarget(comptime T: type, comptime TargetMarker: type) bool {
        \\    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Target") and @TypeOf(T.Target) == type and T.Target == TargetMarker;
        \\}
        \\
        \\fn isUnconstrainedJsAnyOrUnknown(comptime T: type) bool {
        \\    if (T == Any or T == Unknown) return true;
        \\    if (isRefToTarget(T, Any) or isRefToTarget(T, Unknown)) return true;
        \\    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_any_or_unknown") and T.is_js_any_or_unknown) return true;
        \\    return false;
        \\}
        \\
        \\fn isJsObjectConstraintMarker(comptime T: type) bool {
        \\    if (T == Object or isRefToTarget(T, Object)) return true;
        \\    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_object") and T.is_js_object;
        \\}
        \\
        \\fn isJsFunctionConstraintMarker(comptime T: type) bool {
        \\    if (T == Function or isRefToTarget(T, Function)) return true;
        \\    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_function") and T.is_js_function;
        \\}
        \\
        \\fn isJsSymbolConstraintMarker(comptime T: type) bool {
        \\    if (T == Symbol or isRefToTarget(T, Symbol)) return true;
        \\    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_symbol") and T.is_js_symbol;
        \\}
        \\
        \\fn isStringLikeConstraintCandidate(comptime T: type) bool {
        \\    if (T == []const u8 or T == []u8 or T == [:0]const u8 or T == [:0]u8) return true;
        \\    return switch (@typeInfo(T)) {
        \\        .pointer => |pt| (pt.size == .slice and pt.child == u8) or
        \\            (pt.size == .one and @typeInfo(pt.child) == .array and @typeInfo(pt.child).array.child == u8),
        \\        .@"enum" => @hasDecl(T, "toSlice"),
        \\        .@"struct" => isTemplateLiteralStruct(T) or (@hasDecl(T, "is_js_string") and T.is_js_string),
        \\        .@"union" => @hasDecl(T, "zigar_js") and
        \\            @hasField(@TypeOf(T.zigar_js), "is_open_literal") and
        \\            T.zigar_js.is_open_literal and
        \\            @hasDecl(T, "fromSlice"),
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn isNumberLikeConstraintCandidate(comptime T: type) bool {
        \\    return switch (@typeInfo(T)) {
        \\        .float, .comptime_float, .int, .comptime_int => true,
        \\        .@"enum" => !@hasDecl(T, "toSlice"),
        \\        .@"union" => @hasDecl(T, "zigar_js") and
        \\            @hasField(@TypeOf(T.zigar_js), "is_open_literal") and
        \\            T.zigar_js.is_open_literal and
        \\            !@hasDecl(T, "fromSlice"),
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn isFunctionLikeConstraintCandidate(comptime T: type) bool {
        \\    return switch (@typeInfo(T)) {
        \\        .@"fn" => true,
        \\        .pointer => |pt| pt.size == .one and @typeInfo(pt.child) == .@"fn",
        \\        .@"struct" => (@hasDecl(T, "is_zig_callback") and T.is_zig_callback) or
        \\            isJsFunctionConstraintMarker(T) or
        \\            (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_callable_handle") and T.zigar_js.is_callable_handle),
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn structDerivesFrom(comptime T: type, comptime Base: type, comptime depth: usize) bool {
        \\    if (T == Base) return true;
        \\    if (depth > 8) return false;
        \\    if (@typeInfo(T) != .@"struct") return false;
        \\    if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "bases"))) {
        \\        const bases = T.zigar_js.bases;
        \\        inline for (@typeInfo(@TypeOf(bases)).@"struct".field_names) |bf_name| {
        \\            const B = @field(bases, bf_name);
        \\            if (comptime (@TypeOf(B) == type)) {
        \\                if (B == Base or structDerivesFrom(B, Base, depth + 1)) return true;
        \\            }
        \\        }
        \\    }
        \\    return false;
        \\}
        \\
        \\fn structProvidesMember(comptime T: type, comptime wire_or_zig: []const u8) bool {
        \\    if (@typeInfo(T) != .@"struct") return false;
        \\    if (@hasField(T, wire_or_zig) or @hasDecl(T, wire_or_zig)) return true;
        \\    if (comptime @hasDecl(T, "zigar_js")) {
        \\        const meta = T.zigar_js;
        \\        if (comptime @hasField(@TypeOf(meta), "fields")) {
        \\            inline for (@typeInfo(@TypeOf(meta.fields)).@"struct".field_names) |mf_name| {
        \\                const entry = @field(meta.fields, mf_name);
        \\                if (comptime @hasField(@TypeOf(entry), "js_name")) {
        \\                    if (std.mem.eql(u8, entry.js_name, wire_or_zig)) return true;
        \\                }
        \\                if (comptime @hasField(@TypeOf(entry), "name")) {
        \\                    if (std.mem.eql(u8, entry.name, wire_or_zig)) return true;
        \\                }
        \\            }
        \\        }
        \\        if (comptime @hasField(@TypeOf(meta), "methods")) {
        \\            inline for (@typeInfo(@TypeOf(meta.methods)).@"struct".field_names) |mf_name| {
        \\                const entry = @field(meta.methods, mf_name);
        \\                if (comptime @hasField(@TypeOf(entry), "js_name")) {
        \\                    if (std.mem.eql(u8, entry.js_name, wire_or_zig)) return true;
        \\                }
        \\                if (comptime @hasField(@TypeOf(entry), "name")) {
        \\                    if (std.mem.eql(u8, entry.name, wire_or_zig)) return true;
        \\                }
        \\            }
        \\        }
        \\        if (comptime @hasField(@TypeOf(meta), "bases")) {
        \\            inline for (@typeInfo(@TypeOf(meta.bases)).@"struct".field_names) |bf_name| {
        \\                const B = @field(meta.bases, bf_name);
        \\                if (comptime (@TypeOf(B) == type)) {
        \\                    if (structProvidesMember(B, wire_or_zig)) return true;
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return false;
        \\}
        \\
        \\fn lookupStructFieldType(comptime T: type, comptime zig_name: []const u8, comptime wire_name: []const u8) ?type {
        \\    if (@typeInfo(T) != .@"struct") return null;
        \\    if (@hasField(T, zig_name)) return @FieldType(T, zig_name);
        \\    if (!std.mem.eql(u8, wire_name, zig_name) and @hasField(T, wire_name)) return @FieldType(T, wire_name);
        \\    if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "fields"))) {
        \\        inline for (@typeInfo(@TypeOf(T.zigar_js.fields)).@"struct".field_names) |mf_name| {
        \\            const entry = @field(T.zigar_js.fields, mf_name);
        \\            if (comptime (@hasField(@TypeOf(entry), "js_name") and @hasField(@TypeOf(entry), "name"))) {
        \\                if (comptime (std.mem.eql(u8, entry.js_name, wire_name) and @hasField(T, entry.name))) {
        \\                    return @FieldType(T, entry.name);
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
        \\fn enumMemberWireName(comptime EnumT: type, comptime field_name: []const u8) []const u8 {
        \\    if (comptime (@hasDecl(EnumT, "zigar_js") and @hasField(@TypeOf(EnumT.zigar_js), "members"))) {
        \\        const members = EnumT.zigar_js.members;
        \\        inline for (@typeInfo(@TypeOf(members)).@"struct".field_names) |mf_name| {
        \\            const entry = @field(members, mf_name);
        \\            if (comptime @hasField(@TypeOf(entry), "tag")) {
        \\                if (std.mem.eql(u8, entry.tag, field_name)) {
        \\                    if (comptime @hasField(@TypeOf(entry), "str_value")) return entry.str_value;
        \\                    if (comptime @hasField(@TypeOf(entry), "js_name")) return entry.js_name;
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return field_name;
        \\}
        \\
        \\fn standaloneUnitLiteralSatisfiesConstraint(comptime vd: anytype, comptime Constraint: type, comptime depth: usize) bool {
        \\    if (depth > 8) return true;
        \\    const VD = @TypeOf(vd);
        \\    if (@typeInfo(Constraint) == .optional) {
        \\        return standaloneUnitLiteralSatisfiesConstraint(vd, @typeInfo(Constraint).optional.child, depth + 1);
        \\    }
        \\    if (@typeInfo(Constraint) == .@"union") {
        \\        if (comptime (@hasDecl(Constraint, "is_zigar_nullable") and Constraint.is_zigar_nullable)) {
        \\            return standaloneUnitLiteralSatisfiesConstraint(vd, Constraint.Value, depth + 1);
        \\        }
        \\        if (comptime (@hasDecl(Constraint, "zigar_js") and
        \\            @hasField(@TypeOf(Constraint.zigar_js), "is_open_literal") and
        \\            Constraint.zigar_js.is_open_literal))
        \\        {
        \\            if (comptime @hasDecl(Constraint, "fromSlice")) return @hasField(VD, "str_value");
        \\            return @hasField(VD, "int_value") or @hasField(VD, "float_value");
        \\        }
        \\        const c_types = @typeInfo(Constraint).@"union".field_types;
        \\        if (comptime (@hasDecl(Constraint, "zigar_js") and @hasField(@TypeOf(Constraint.zigar_js), "variants"))) {
        \\            const cvs = Constraint.zigar_js.variants;
        \\            inline for (c_types, 0..) |cf_ty, ci| {
        \\                if (ci < cvs.len and @hasField(@TypeOf(cvs[ci]), "is_unit_literal") and cvs[ci].is_unit_literal) {
        \\                    const cvd = cvs[ci];
        \\                    const CVD = @TypeOf(cvd);
        \\                    if (@hasField(VD, "str_value") and @hasField(CVD, "str_value") and std.mem.eql(u8, vd.str_value, cvd.str_value)) return true;
        \\                    if (@hasField(VD, "bool_value") and @hasField(CVD, "bool_value") and vd.bool_value == cvd.bool_value) return true;
        \\                    if (@hasField(VD, "num_value") and @hasField(CVD, "num_value") and vd.num_value == cvd.num_value) return true;
        \\                    if (@hasField(VD, "int_value") and @hasField(CVD, "int_value") and vd.int_value == cvd.int_value) return true;
        \\                    if (@hasField(VD, "float_value") and @hasField(CVD, "float_value") and vd.float_value == cvd.float_value) return true;
        \\                    if (@hasField(VD, "bigint_value") and @hasField(CVD, "bigint_value") and std.mem.eql(u8, vd.bigint_value, cvd.bigint_value)) return true;
        \\                } else if (cf_ty != void and standaloneUnitLiteralSatisfiesConstraint(vd, cf_ty, depth + 1)) {
        \\                    return true;
        \\                }
        \\            }
        \\            return false;
        \\        }
        \\        inline for (c_types) |cf_ty| {
        \\            if (cf_ty != void and standaloneUnitLiteralSatisfiesConstraint(vd, cf_ty, depth + 1)) return true;
        \\        }
        \\        return false;
        \\    }
        \\    if (@hasField(VD, "str_value")) {
        \\        if (@typeInfo(Constraint) == .@"enum") {
        \\            inline for (@typeInfo(Constraint).@"enum".field_names) |cf_name| {
        \\                if (std.mem.eql(u8, vd.str_value, comptime enumMemberWireName(Constraint, cf_name))) return true;
        \\            }
        \\            return false;
        \\        }
        \\        return standaloneSatisfiesTypeConstraint([]const u8, Constraint, depth + 1);
        \\    }
        \\    if (@hasField(VD, "bool_value")) return standaloneSatisfiesTypeConstraint(bool, Constraint, depth + 1);
        \\    if (@hasField(VD, "num_value") or @hasField(VD, "int_value") or @hasField(VD, "float_value")) return standaloneSatisfiesTypeConstraint(f64, Constraint, depth + 1);
        \\    if (@hasField(VD, "bigint_value")) return standaloneSatisfiesTypeConstraint(i64, Constraint, depth + 1);
        \\    return false;
        \\}
        \\
        \\pub fn standaloneSatisfiesTypeConstraint(comptime T: type, comptime Constraint: type, comptime depth: usize) bool {
        \\    @setEvalBranchQuota(200_000);
        \\    if (T == Constraint or T == noreturn) return true;
        \\    if (depth > 8) return true;
        \\    if (comptime isUnconstrainedJsAnyOrUnknown(T)) return true;
        \\    if (comptime isUnconstrainedJsAnyOrUnknown(Constraint)) return true;
        \\
        \\    if (comptime isJsObjectConstraintMarker(Constraint)) {
        \\        return switch (@typeInfo(T)) {
        \\            .bool, .int, .comptime_int, .float, .comptime_float, .void => false,
        \\            else => true,
        \\        };
        \\    }
        \\
        \\    if (comptime isJsSymbolConstraintMarker(Constraint)) {
        \\        return isJsSymbolConstraintMarker(T);
        \\    }
        \\
        \\    if (comptime (isJsFunctionConstraintMarker(Constraint) or
        \\        (@typeInfo(Constraint) == .@"struct" and @hasDecl(Constraint, "is_zig_callback") and Constraint.is_zig_callback) or
        \\        (@typeInfo(Constraint) == .@"struct" and @hasDecl(Constraint, "zigar_js") and @hasField(@TypeOf(Constraint.zigar_js), "is_callable_handle") and Constraint.zigar_js.is_callable_handle) or
        \\        @typeInfo(Constraint) == .@"fn" or
        \\        (@typeInfo(Constraint) == .pointer and @typeInfo(Constraint).pointer.size == .one and @typeInfo(@typeInfo(Constraint).pointer.child) == .@"fn")))
        \\    {
        \\        return isFunctionLikeConstraintCandidate(T);
        \\    }
        \\
        \\    if (comptime (Constraint == []const u8 or isTemplateLiteralStruct(Constraint) or
        \\        (@typeInfo(Constraint) == .@"struct" and @hasDecl(Constraint, "is_js_string") and Constraint.is_js_string)))
        \\    {
        \\        return isStringLikeConstraintCandidate(T);
        \\    }
        \\
        \\    if (Constraint == bool) return T == bool;
        \\
        \\    if (comptime (Constraint == i64 or Constraint == u64 or
        \\        (@typeInfo(Constraint) == .@"struct" and @hasDecl(Constraint, "is_js_bigint") and Constraint.is_js_bigint)))
        \\    {
        \\        return switch (@typeInfo(T)) {
        \\            .int, .comptime_int => true,
        \\            .@"struct" => @hasDecl(T, "is_js_bigint") and T.is_js_bigint,
        \\            else => false,
        \\        };
        \\    }
        \\
        \\    if (comptime (@typeInfo(Constraint) == .float or @typeInfo(Constraint) == .int)) {
        \\        return isNumberLikeConstraintCandidate(T);
        \\    }
        \\
        \\    if (comptime (@typeInfo(T) == .@"union")) {
        \\        if (comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "is_open_literal") and T.zigar_js.is_open_literal)) {
        \\            // Handled below if Constraint is open literal or union.
        \\        } else if (comptime (@hasDecl(T, "is_zigar_nullable") and T.is_zigar_nullable)) {
        \\            return standaloneSatisfiesTypeConstraint(@TypeOf(null), Constraint, depth + 1) and
        \\                standaloneSatisfiesTypeConstraint(T.Value, Constraint, depth + 1);
        \\        } else {
        \\            const u_types = @typeInfo(T).@"union".field_types;
        \\            if (comptime (u_types.len > 0)) {
        \\                const has_t_vars = comptime (@hasDecl(T, "zigar_js") and @hasField(@TypeOf(T.zigar_js), "variants"));
        \\                inline for (u_types, 0..) |uf_ty, ui| {
        \\                    if (uf_ty != void) {
        \\                        if (!standaloneSatisfiesTypeConstraint(uf_ty, Constraint, depth + 1)) return false;
        \\                    } else if (has_t_vars and ui < T.zigar_js.variants.len and
        \\                        @hasField(@TypeOf(T.zigar_js.variants[ui]), "is_unit_literal") and
        \\                        T.zigar_js.variants[ui].is_unit_literal)
        \\                    {
        \\                        if (!standaloneUnitLiteralSatisfiesConstraint(T.zigar_js.variants[ui], Constraint, depth + 1)) return false;
        \\                    } else {
        \\                        if (!standaloneSatisfiesTypeConstraint(void, Constraint, depth + 1)) return false;
        \\                    }
        \\                }
        \\                return true;
        \\            }
        \\        }
        \\    }
        \\
        \\    return switch (@typeInfo(Constraint)) {
        \\        .optional => |op| blk: {
        \\            if (T == @TypeOf(null) or T == @TypeOf(undefined)) break :blk true;
        \\            if (@typeInfo(T) == .optional) {
        \\                break :blk standaloneSatisfiesTypeConstraint(@typeInfo(T).optional.child, op.child, depth + 1);
        \\            }
        \\            break :blk standaloneSatisfiesTypeConstraint(T, op.child, depth + 1);
        \\        },
        \\        .pointer => |cpt| blk: {
        \\            if (cpt.size == .slice) {
        \\                if (cpt.child == u8) {
        \\                    if (isStringLikeConstraintCandidate(T)) break :blk true;
        \\                    if (@typeInfo(T) == .@"struct" and isGeneratedHandleStruct(T)) break :blk true;
        \\                }
        \\                break :blk switch (@typeInfo(T)) {
        \\                    .pointer => |tpt| if (tpt.size == .slice)
        \\                        standaloneSatisfiesTypeConstraint(tpt.child, cpt.child, depth + 1)
        \\                    else if (tpt.size == .one and @typeInfo(tpt.child) == .array)
        \\                        standaloneSatisfiesTypeConstraint(@typeInfo(tpt.child).array.child, cpt.child, depth + 1)
        \\                    else
        \\                        false,
        \\                    .array => |tar| standaloneSatisfiesTypeConstraint(tar.child, cpt.child, depth + 1),
        \\                    else => false,
        \\                };
        \\            }
        \\            break :blk false;
        \\        },
        \\        .@"enum" => |cen| blk: {
        \\            if (@typeInfo(T) != .@"enum") break :blk false;
        \\            const ten = @typeInfo(T).@"enum";
        \\            inline for (ten.field_names) |tf_name| {
        \\                const tw = comptime enumMemberWireName(T, tf_name);
        \\                var found = false;
        \\                inline for (cen.field_names) |cf_name| {
        \\                    const cw = comptime enumMemberWireName(Constraint, cf_name);
        \\                    if (std.mem.eql(u8, tw, cw)) {
        \\                        found = true;
        \\                        break;
        \\                    }
        \\                }
        \\                if (!found) break :blk false;
        \\            }
        \\            break :blk true;
        \\        },
        \\        .@"union" => |cun| blk: {
        \\            if (comptime (@hasDecl(Constraint, "is_zigar_nullable") and Constraint.is_zigar_nullable)) {
        \\                if (T == @TypeOf(null) or T == @TypeOf(undefined) or T == void) break :blk true;
        \\                if (@typeInfo(T) == .optional) {
        \\                    break :blk standaloneSatisfiesTypeConstraint(@typeInfo(T).optional.child, Constraint.Value, depth + 1);
        \\                }
        \\                break :blk standaloneSatisfiesTypeConstraint(T, Constraint.Value, depth + 1);
        \\            }
        \\            if (comptime (@hasDecl(Constraint, "zigar_js") and
        \\                @hasField(@TypeOf(Constraint.zigar_js), "is_open_literal") and
        \\                Constraint.zigar_js.is_open_literal))
        \\            {
        \\                if (comptime @hasDecl(Constraint, "fromSlice")) break :blk isStringLikeConstraintCandidate(T);
        \\                break :blk isNumberLikeConstraintCandidate(T);
        \\            }
        \\            const has_c_vars = comptime (@hasDecl(Constraint, "zigar_js") and @hasField(@TypeOf(Constraint.zigar_js), "variants"));
        \\            inline for (cun.field_types, 0..) |cf_ty, ci| {
        \\                if (cf_ty != void) {
        \\                    if (standaloneSatisfiesTypeConstraint(T, cf_ty, depth + 1)) break :blk true;
        \\                } else if (T == void) {
        \\                    const is_ul = has_c_vars and ci < Constraint.zigar_js.variants.len and
        \\                        @hasField(@TypeOf(Constraint.zigar_js.variants[ci]), "is_unit_literal") and
        \\                        Constraint.zigar_js.variants[ci].is_unit_literal;
        \\                    if (!is_ul) break :blk true;
        \\                }
        \\            }
        \\            if (@typeInfo(T) == .@"enum") {
        \\                const ten = @typeInfo(T).@"enum";
        \\                if (ten.field_names.len > 0) {
        \\                    var all_ok = true;
        \\                    inline for (ten.field_names) |tf_name| {
        \\                        const tw = comptime enumMemberWireName(T, tf_name);
        \\                        if (!standaloneUnitLiteralSatisfiesConstraint(.{ .str_value = tw }, Constraint, depth + 1)) {
        \\                            all_ok = false;
        \\                            break;
        \\                        }
        \\                    }
        \\                    if (all_ok) break :blk true;
        \\                }
        \\            }
        \\            break :blk false;
        \\        },
        \\        .@"struct" => |cst| blk: {
        \\            if (comptime ((@hasDecl(Constraint, "is_js_map") and Constraint.is_js_map) or
        \\                (@hasDecl(Constraint, "is_js_record") and Constraint.is_js_record)))
        \\            {
        \\                break :blk @typeInfo(T) == .@"struct";
        \\            }
        \\            if (comptime (@hasDecl(Constraint, "is_js_set") and Constraint.is_js_set)) {
        \\                if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_set") and T.is_js_set)) {
        \\                    const TElem = if (@hasDecl(T, "Elem")) T.Elem else T.Element;
        \\                    const CElem = if (@hasDecl(Constraint, "Elem")) Constraint.Elem else Constraint.Element;
        \\                    break :blk standaloneSatisfiesTypeConstraint(TElem, CElem, depth + 1);
        \\                }
        \\                break :blk false;
        \\            }
        \\            if (comptime (@hasDecl(Constraint, "is_js_promise") and Constraint.is_js_promise)) {
        \\                if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "is_js_promise") and T.is_js_promise)) {
        \\                    if (comptime (@hasDecl(T, "Payload") and @hasDecl(Constraint, "Payload"))) {
        \\                        break :blk standaloneSatisfiesTypeConstraint(T.Payload, Constraint.Payload, depth + 1);
        \\                    }
        \\                    break :blk true;
        \\                }
        \\                break :blk structProvidesMember(T, "then");
        \\            }
        \\            if (comptime @hasDecl(Constraint, "zigar_js_tuple")) {
        \\                if (@typeInfo(T) != .@"struct" and @typeInfo(T) != .array) break :blk false;
        \\                break :blk true;
        \\            }
        \\            if (comptime isGeneratedHandleStruct(Constraint)) {
        \\                if (structDerivesFrom(T, Constraint, 0)) break :blk true;
        \\                const is_nom_class = comptime (@hasField(@TypeOf(Constraint.zigar_js), "is_class") and Constraint.zigar_js.is_class);
        \\                if (is_nom_class) {
        \\                    const has_priv = comptime ((@hasField(@TypeOf(Constraint.zigar_js), "has_private_constructor") and Constraint.zigar_js.has_private_constructor) or
        \\                        (@hasField(@TypeOf(Constraint.zigar_js), "has_non_public_members") and Constraint.zigar_js.has_non_public_members));
        \\                    if (has_priv or !isGeneratedHandleStruct(T)) break :blk false;
        \\                    if (comptime @hasField(@TypeOf(Constraint.zigar_js), "fields")) {
        \\                        inline for (@typeInfo(@TypeOf(Constraint.zigar_js.fields)).@"struct".field_names) |mf_name| {
        \\                            const entry = @field(Constraint.zigar_js.fields, mf_name);
        \\                            const opt = comptime (@hasField(@TypeOf(entry), "is_optional") and entry.is_optional);
        \\                            if (!opt and !structProvidesMember(T, entry.js_name)) break :blk false;
        \\                        }
        \\                    }
        \\                    if (comptime @hasField(@TypeOf(Constraint.zigar_js), "methods")) {
        \\                        inline for (@typeInfo(@TypeOf(Constraint.zigar_js.methods)).@"struct".field_names) |mf_name| {
        \\                            const entry = @field(Constraint.zigar_js.methods, mf_name);
        \\                            const is_stat = comptime (@hasField(@TypeOf(entry), "is_static") and entry.is_static);
        \\                            if (!is_stat and !structProvidesMember(T, entry.js_name)) break :blk false;
        \\                        }
        \\                    }
        \\                    break :blk true;
        \\                }
        \\                if (@typeInfo(T) != .@"struct") break :blk false;
        \\                if (isJsObjectConstraintMarker(T)) break :blk true;
        \\                if (comptime @hasField(@TypeOf(Constraint.zigar_js), "required_methods")) {
        \\                    inline for (Constraint.zigar_js.required_methods) |rm| {
        \\                        if (!structProvidesMember(T, rm)) break :blk false;
        \\                    }
        \\                }
        \\                if (comptime @hasField(@TypeOf(Constraint.zigar_js), "required_props")) {
        \\                    inline for (Constraint.zigar_js.required_props) |rp| {
        \\                        if (!structProvidesMember(T, rp)) break :blk false;
        \\                    }
        \\                }
        \\                break :blk true;
        \\            }
        \\            if (@typeInfo(T) != .@"struct") break :blk false;
        \\            if (isJsObjectConstraintMarker(T)) break :blk true;
        \\            inline for (cst.field_names, 0..) |cf_name, cf_idx| {
        \\                if (comptime isHiddenMetaField(cf_name)) continue;
        \\                const cf_ty = cst.field_types[cf_idx];
        \\                const cf_attr = cst.field_attrs[cf_idx];
        \\                const is_opt = comptime (cf_attr.default_value_ptr != null or @typeInfo(cf_ty) == .optional or isModuleNullableType(cf_ty));
        \\                if (!is_opt) {
        \\                    const wire = comptime topStructFieldWireName(Constraint, cf_name);
        \\                    if (comptime lookupStructFieldType(T, cf_name, wire)) |tf_ty| {
        \\                        if (!standaloneSatisfiesTypeConstraint(tf_ty, cf_ty, depth + 1)) break :blk false;
        \\                    } else if (comptime (isGeneratedHandleStruct(T) and structProvidesMember(T, wire))) {
        \\                        // Handle struct exposes this property via getter/accessor.
        \\                    } else {
        \\                        break :blk false;
        \\                    }
        \\                }
        \\            }
        \\            break :blk true;
        \\        },
        \\        else => true,
        \\    };
        \\}
        \\
        \\pub fn standaloneCheckTypeConstraint(comptime T: type, comptime Constraint: type) void {
        \\    if (!comptime standaloneSatisfiesTypeConstraint(T, Constraint, 0)) {
        \\        @compileError("zigar.js: type '" ++ @typeName(T) ++ "' does not satisfy TypeScript constraint '" ++ @typeName(Constraint) ++ "'");
        \\    }
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
