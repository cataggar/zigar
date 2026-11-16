const std = @import("std");
const ir = @import("ir.zig");
const naming = @import("naming.zig");

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
    used_self_mod_alias: bool = false,

    fn deinit(self: *ModuleEmitCtx) void {
        self.out.deinit(self.allocator);
        self.nested_decl_scopes.deinit(self.allocator);
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
            .js_value => try self.out.appendSlice(self.allocator, "__zigar_js.JsValue"),
            .js_object => try self.out.appendSlice(self.allocator, "__zigar_js.JsObject"),
            .js_symbol => try self.out.appendSlice(self.allocator, "__zigar_js.JsSymbol"),
            .self_type => |sid| try self.emitIdentSegment(sid),
            .type_param_ref => |tp_ident| try self.out.appendSlice(self.allocator, tp_ident),
            .optional => |inner| {
                try self.out.append(self.allocator, '?');
                try self.emitType(inner);
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
                try self.out.appendSlice(self.allocator, "__zigar_js.JsMap(");
                try self.emitType(m.key);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitType(m.value);
                try self.out.append(self.allocator, ')');
            },
            .tuple => |elems| {
                try self.out.appendSlice(self.allocator, "struct { ");
                for (elems, 0..) |el, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.out.print(self.allocator, "{s}: ", .{el.zig_ident});
                    try self.emitType(el.ty);
                    if (el.ty.* == .optional) {
                        try self.out.appendSlice(self.allocator, " = null");
                    }
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
                const clean_bi = std.mem.trimEnd(u8, std.mem.trim(u8, raw_bi, " \t"), "n");
                if (std.fmt.parseInt(i64, clean_bi, 10)) |parsed_i64| {
                    try self.out.print(self.allocator, "{s}const {s}: i64 = {d};\n", .{ pub_kw, zig_ident, parsed_i64 });
                } else |_| if (std.fmt.parseInt(i128, clean_bi, 10)) |parsed_i128| {
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

    fn emitStructBody(
        self: *ModuleEmitCtx,
        wire_name: []const u8,
        st: ir.StructDeclIr,
    ) error{OutOfMemory}!void {
        const frame_count = 2 + st.static_props.len + st.constructors.len + st.methods.len + st.nested_decls.len;
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
                try self.out.print(self.allocator, "pub const {s}: __zigar_js.Global(", .{sp.zig_ident});
                try self.emitType(sp.ty);
                try self.out.appendSlice(self.allocator, ") = .{ .js_name = ");
                try self.emitStringLit(sp.wire_name);
                try self.out.appendSlice(self.allocator, " };\n");
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
        try self.out.print(self.allocator, ",\n.is_class = {s},\n.fields = .{{\n", .{
            if (st.is_class) "true" else "false",
        });
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
        is_const: bool,
        members: []const ir.EnumMemberIr,
    ) !void {
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
                .auto => {},
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
        if (d.jsdoc) |jd| {
            try appendJsDocComments(&self.out, self.allocator, jd);
        }
        const pub_kw = if (d.is_exported) "pub " else "";

        switch (d.kind) {
            .function_decl => |sig| {
                try self.emitFunction(pub_kw, d.zig_ident, null, sig);
            },
            .const_literal => |cl| {
                try self.emitLiteralConst(pub_kw, d.zig_ident, cl.ty, cl.value);
            },
            .global_var => |gty| {
                try self.out.print(self.allocator, "{s}const {s}: __zigar_js.Global(", .{ pub_kw, d.zig_ident });
                try self.emitType(gty);
                try self.out.appendSlice(self.allocator, ") = .{ .js_name = ");
                try self.emitStringLit(d.wire_name);
                try self.out.appendSlice(self.allocator, " };\n");
            },
            .struct_decl => |st| {
                if (st.type_params.len == 0) {
                    try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                    try self.emitStructBody(d.wire_name, st);
                    try self.out.appendSlice(self.allocator, ";\n");
                } else {
                    try self.out.print(self.allocator, "{s}fn {s}(", .{ pub_kw, d.zig_ident });
                    for (st.type_params, 0..) |tp, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.print(self.allocator, "comptime {s}: type", .{tp.zig_ident});
                    }
                    try self.out.appendSlice(self.allocator, ") type {\nreturn ");
                    try self.emitStructBody(d.wire_name, st);
                    try self.out.appendSlice(self.allocator, ";\n}\n");
                }
            },
            .enum_decl => |en| {
                try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                try self.emitEnumBody(d.wire_name, en.is_const, en.members);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .string_enum_decl => |members| {
                try self.out.print(self.allocator, "{s}const {s} = ", .{ pub_kw, d.zig_ident });
                try self.emitEnumBody(d.wire_name, false, members);
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
                const frame = try self.allocator.alloc([]const u8, children.len + 1);
                defer self.allocator.free(frame);
                for (children, 0..) |cd, idx| {
                    frame[idx] = cd.zig_ident;
                }
                frame[children.len] = "zigar_js";
                try self.nested_decl_scopes.append(self.allocator, frame);
                defer _ = self.nested_decl_scopes.pop();

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

fn signatureUsesTypeParam(sig: ir.SignatureIr, tp_ident: []const u8) bool {
    for (sig.params) |p| {
        if (typeUsesTypeParam(p.ty, tp_ident)) return true;
    }
    return typeUsesTypeParam(sig.return_type, tp_ident);
}

fn typeUsesTypeParam(ty: *const ir.TypeIr, tp_ident: []const u8) bool {
    return switch (ty.*) {
        .type_param_ref => |ref_id| std.mem.eql(u8, ref_id, tp_ident),
        .optional, .pointer_const, .slice, .promise => |inner| typeUsesTypeParam(inner, tp_ident),
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
    var barrel_exports: std.ArrayList(ir.DeclIr) = .empty;
    defer barrel_exports.deinit(allocator);
    if (barrel_mod) |bm| {
        for (bm.decls) |d| {
            if (!d.is_exported or !d.is_js_exported) continue;
            if (root_scope.isTaken(d.logical_name)) continue;
            try root_scope.reserve(d.logical_name);
            try barrel_exports.append(allocator, d);
        }
    }

    // Allocate non-shadowing parameter names inside `zigar_js` helpers so top-level exports
    // named `T`, `K`, `V`, `self`, `Promise`, `JsMap`, `Global`, etc. never collide or shadow!
    var zigar_js_scope = naming.ScopeNamer.initContainer(allocator, &root_scope);
    defer zigar_js_scope.deinit();
    try zigar_js_scope.reserve("JsValue");
    try zigar_js_scope.reserve("JsObject");
    try zigar_js_scope.reserve("JsSymbol");
    try zigar_js_scope.reserve("Promise");
    try zigar_js_scope.reserve("JsMap");
    try zigar_js_scope.reserve("Global");

    var promise_p = naming.ScopeNamer.initParam(allocator, &zigar_js_scope);
    defer promise_p.deinit();
    const tp_promise = try promise_p.bind("T", .pascal);
    defer tp_promise.deinit(allocator);

    var map_p = naming.ScopeNamer.initParam(allocator, &zigar_js_scope);
    defer map_p.deinit();
    const tp_k = try map_p.bind("K", .pascal);
    defer tp_k.deinit(allocator);
    const tp_v = try map_p.bind("V", .pascal);
    defer tp_v.deinit(allocator);

    var global_p = naming.ScopeNamer.initParam(allocator, &zigar_js_scope);
    defer global_p.deinit();
    const tp_global = try global_p.bind("T", .pascal);
    defer tp_global.deinit(allocator);

    var global_struct_scope = naming.ScopeNamer.initContainer(allocator, &global_p);
    defer global_struct_scope.deinit();
    try global_struct_scope.reserve("ValueType");
    try global_struct_scope.reserve("get");

    var global_get_p = naming.ScopeNamer.initParam(allocator, &global_struct_scope);
    defer global_get_p.deinit();
    const p_self = try global_get_p.bind("self", .preserve);
    defer p_self.deinit(allocator);

    try out.print(
        allocator,
        \\// Generated by ts-zigar (TypeScript 7.1). Do not edit manually.
        \\
        \\pub const zigar_js = struct {{
        \\    pub const JsValue = struct {{
        \\        handle: u32 = 0,
        \\    }};
        \\    pub const JsObject = struct {{
        \\        handle: u32 = 0,
        \\    }};
        \\    pub const JsSymbol = struct {{
        \\        id: u32 = 0,
        \\    }};
        \\    pub fn Promise(comptime {s}: type) type {{
        \\        return struct {{
        \\            pub const Payload = {s};
        \\            handle: u32 = 0,
        \\        }};
        \\    }}
        \\    pub fn JsMap(comptime {s}: type, comptime {s}: type) type {{
        \\        return struct {{
        \\            pub const Key = {s};
        \\            pub const Value = {s};
        \\            handle: u32 = 0,
        \\        }};
        \\    }}
        \\    pub fn Global(comptime {s}: type) type {{
        \\        return struct {{
        \\            pub const ValueType = {s};
        \\            js_name: []const u8,
        \\            pub fn get({s}: @This()) {s} {{
        \\                _ = {s};
        \\                @panic("ts-zigar host stub");
        \\            }}
        \\        }};
        \\    }}
        \\}};
        \\
        \\
    ,
        .{
            tp_promise.zig_ident,
            tp_promise.zig_ident,
            tp_k.zig_ident,
            tp_v.zig_ident,
            tp_k.zig_ident,
            tp_v.zig_ident,
            tp_global.zig_ident,
            tp_global.zig_ident,
            p_self.zig_ident,
            tp_global.zig_ident,
            p_self.zig_ident,
        },
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
            for (barrel_exports.items) |d| {
                try out.print(allocator, "pub const {s} = {s}.{s};\n", .{
                    d.zig_ident,
                    bm.root_export_ident,
                    d.zig_ident,
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
