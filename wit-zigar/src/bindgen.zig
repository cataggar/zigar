//! WIT-to-Zig binding generator (`wit-zigar`).
//!
//! Consumes resolved WIT ASTs (`resolver.zig`, `wasi_canon.zig`) together with
//! `metadata_encode.zig`, `metadata_decode.zig`, `lift_types.zig`, and
//! `adapter/abi.zig` to emit idiomatic Zig 0.17 declarations (`extern struct`,
//! tagged `union(enum)`, `Result`, `packed struct` flags, `enum`, slices,
//! resource handles `Own`/`Borrow`, P3 `Stream`/`Future`/`ErrorContext`, and
//! core Wasm `extern` / `@export` bindings) matching Canonical ABI rules.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ast = @import("component/wit/ast.zig");
pub const lexer = @import("component/wit/lexer.zig");
pub const parser = @import("component/wit/parser.zig");
pub const resolver_mod = @import("component/wit/resolver.zig");
pub const lift_types = @import("component/wit/lift_types.zig");
pub const metadata_encode = @import("component/wit/metadata_encode.zig");
pub const metadata_decode = @import("component/wit/metadata_decode.zig");
pub const wasi_canon = @import("component/wit/wasi_canon.zig");
pub const abi = @import("component/adapter/abi.zig");
pub const ctypes = @import("component/types.zig");
pub const wtypes = @import("component/core_types.zig");

pub const Arch = enum {
    wasm32,
    wasm64,
};

pub const BindgenOptions = struct {
    resolver: ?resolver_mod.Resolver = null,
    world_name: ?[]const u8 = null,
    arch: Arch = .wasm32,
    emit_runtime_helpers: bool = true,
};

pub const BindgenError = parser.ParseError ||
    resolver_mod.ResolveError ||
    metadata_encode.EncodeError ||
    metadata_decode.DecodeError ||
    lift_types.Error ||
    abi.Error ||
    error{
        MissingResolver,
        UnknownWasiPackage,
    };

// ── Identifier Naming Helpers ──────────────────────────────────────────────

/// Convert a WIT `kebab-case` identifier (e.g. `get-arguments`, `monotonic-clock`,
/// `%type`) into a Zig `snake_case` identifier (`get_arguments`, `monotonic_clock`,
/// `@"type"`), escaping Zig reserved keywords, primitives, or leading-digit names.
pub fn toSnakeCase(alloc: Allocator, wit_name: []const u8) Allocator.Error![]u8 {
    const raw = try toRawSnakeCase(alloc, wit_name);
    if (needsZigEscape(raw)) {
        defer alloc.free(raw);
        return std.fmt.allocPrint(alloc, "@\"{s}\"", .{raw});
    }
    return raw;
}

/// Convert a WIT `kebab-case` identifier into an unescaped `snake_case` string
/// (useful before appending a suffix like `_Fn` or `_meta`).
pub fn toRawSnakeCase(alloc: Allocator, wit_name: []const u8) Allocator.Error![]u8 {
    const clean = stripPercent(wit_name);
    var out = try alloc.alloc(u8, clean.len);
    for (clean, 0..) |c, i| {
        out[i] = if (c == '-') '_' else std.ascii.toLower(c);
    }
    return out;
}

/// Convert a WIT `kebab-case` type name (e.g. `descriptor-type`, `error-code`,
/// `input-stream`, `datetime`, `DNS-error-payload`) into an idiomatic Zig
/// `PascalCase` identifier (`DescriptorType`, `ErrorCode`, `InputStream`,
/// `Datetime`, `DnsErrorPayload`).
pub fn toPascalCase(alloc: Allocator, wit_name: []const u8) Allocator.Error![]u8 {
    const clean = stripPercent(wit_name);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    var it = std.mem.tokenizeAny(u8, clean, "-_");
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        try buf.append(alloc, std.ascii.toUpper(seg[0]));
        const has_lower = blk: {
            for (seg[1..]) |ch| {
                if (std.ascii.isLower(ch)) break :blk true;
            }
            break :blk false;
        };
        const has_upper = blk: {
            for (seg[1..]) |ch| {
                if (std.ascii.isUpper(ch)) break :blk true;
            }
            break :blk false;
        };
        for (seg[1..]) |ch| {
            // Preserve camelCase boundaries if input was already mixed-case,
            // otherwise lowercase the remainder of the segment (e.g. DNS -> Dns).
            if (has_lower and has_upper) {
                try buf.append(alloc, ch);
            } else {
                try buf.append(alloc, std.ascii.toLower(ch));
            }
        }
    }

    const raw = try buf.toOwnedSlice(alloc);
    if (needsZigEscape(raw)) {
        defer alloc.free(raw);
        return std.fmt.allocPrint(alloc, "@\"{s}\"", .{raw});
    }
    return raw;
}

fn stripPercent(s: []const u8) []const u8 {
    if (s.len > 0 and s[0] == '%') return s[1..];
    return s;
}

fn escapeZigId(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    if (needsZigEscape(raw)) {
        return std.fmt.allocPrint(alloc, "@\"{s}\"", .{raw});
    }
    return alloc.dupe(u8, raw);
}

fn needsZigEscape(id: []const u8) bool {
    if (id.len == 0) return true;
    if (std.mem.eql(u8, id, "_")) return true;
    if (!isAsciiAlphaOrUnderscore(id[0])) return true;
    for (id[1..]) |c| {
        if (!isAsciiAlphaOrUnderscore(c) and !std.ascii.isDigit(c)) return true;
    }
    if (std.zig.Token.keywords.has(id)) return true;
    if (std.zig.isPrimitive(id)) return true;
    return false;
}

fn isAsciiAlphaOrUnderscore(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

// ── Public Entry Points ────────────────────────────────────────────────────

/// Generate Zig bindings using `opts.resolver`.
pub fn generate(allocator: Allocator, opts: BindgenOptions) BindgenError![]u8 {
    const res = opts.resolver orelse return error.MissingResolver;
    return generateFromResolver(allocator, res, opts);
}

/// Parse `wit_source`, attach embedded `wasi-canon` packages (`0.3.0`, `0.2.x`),
/// and generate idiomatic Zig bindings.
pub fn generateFromWitSource(
    allocator: Allocator,
    wit_source: []const u8,
    opts: BindgenOptions,
) BindgenError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const doc = try parser.parse(ar, wit_source, null);
    const res = try resolver_mod.finishWithEmbedded(ar, doc, &.{});
    return generateFromResolver(allocator, res, opts);
}

/// Look up an embedded WASI world (e.g. `wasi:cli/command@0.3.0`,
/// `wasi:cli/imports@0.3.0`, `wasi:filesystem/imports@0.3.0`,
/// `wasi:http/service@0.3.0`) and generate Zig bindings for it.
pub fn generateWasiWorld(
    allocator: Allocator,
    pkg_ns: []const u8,
    pkg_name: []const u8,
    world_name: []const u8,
    version: ?[]const u8,
    opts: BindgenOptions,
) BindgenError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const embedded = try resolver_mod.embeddedWasiDocs(ar);
    var matched_doc: ?ast.Document = null;
    for (embedded) |edoc| {
        const epkg = edoc.package orelse continue;
        if (!std.mem.eql(u8, epkg.namespace, pkg_ns)) continue;
        if (!std.mem.eql(u8, epkg.name, pkg_name)) continue;
        if (version) |want_ver| {
            const have_ver = epkg.version orelse continue;
            if (!std.mem.eql(u8, have_ver, want_ver)) continue;
        }
        for (edoc.items) |it| {
            if (it == .world and std.mem.eql(u8, it.world.name, world_name)) {
                matched_doc = edoc;
                break;
            }
        }
        if (matched_doc != null) break;
    }

    const main_doc = matched_doc orelse return error.UnknownWorld;
    const res = resolver_mod.Resolver.init(main_doc, embedded);
    var sub_opts = opts;
    sub_opts.world_name = world_name;
    return generateFromResolver(allocator, res, sub_opts);
}

/// Convenience helper accepting a single `<ns>:<pkg>/<world>[@<ver>]` string
/// such as `"wasi:cli/command@0.3.0"`.
pub fn generateWasiWorldBySpec(
    allocator: Allocator,
    spec: []const u8,
    opts: BindgenOptions,
) BindgenError![]u8 {
    const parsed = parseWorldSpec(spec) orelse return error.UnknownWorld;
    return generateWasiWorld(
        allocator,
        parsed.namespace,
        parsed.pkg_name,
        parsed.world_name,
        parsed.version,
        opts,
    );
}

pub const WorldSpec = struct {
    namespace: []const u8,
    pkg_name: []const u8,
    world_name: []const u8,
    version: ?[]const u8,
};

pub fn parseWorldSpec(spec: []const u8) ?WorldSpec {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return null;
    const pkg_part = spec[0..slash];
    const colon = std.mem.indexOfScalar(u8, pkg_part, ':') orelse return null;
    const ns = pkg_part[0..colon];
    const pkg_name = pkg_part[colon + 1 ..];
    const rest = spec[slash + 1 ..];
    if (ns.len == 0 or pkg_name.len == 0 or rest.len == 0) return null;
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        const wname = rest[0..at];
        const ver = rest[at + 1 ..];
        if (wname.len == 0 or ver.len == 0) return null;
        return .{
            .namespace = ns,
            .pkg_name = pkg_name,
            .world_name = wname,
            .version = ver,
        };
    }
    return .{
        .namespace = ns,
        .pkg_name = pkg_name,
        .world_name = rest,
        .version = null,
    };
}

/// Transcribe all functions of an exported `metadata_decode.WorldExtern` using
/// `lift_types.transcribeFuncSig`, returning the hoisted component-level
/// `ctypes.TypeDef`s in emission order.
pub fn transcribeExportedInterfaceFuncs(
    allocator: Allocator,
    ext: metadata_decode.WorldExtern,
) lift_types.Error![]ctypes.TypeDef {
    var added = std.ArrayList(ctypes.TypeDef).empty;
    errdefer added.deinit(allocator);
    var cache = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer cache.deinit(allocator);

    const Ctx = struct {
        added_list: *std.ArrayList(ctypes.TypeDef),
        slot_cache: *std.AutoHashMapUnmanaged(u32, u32),
        alloc: Allocator,

        pub fn addType(self: @This(), td: ctypes.TypeDef) lift_types.Error!u32 {
            const idx: u32 = @intCast(self.added_list.items.len);
            try self.added_list.append(self.alloc, td);
            return idx;
        }

        pub fn lookupType(self: @This(), slot: u32) ?u32 {
            return self.slot_cache.get(slot);
        }

        pub fn cacheType(self: @This(), slot: u32, idx: u32) lift_types.Error!void {
            try self.slot_cache.put(self.alloc, slot, idx);
        }

        pub fn rewriteLeaf(_: @This(), v: ctypes.ValType) lift_types.Error!ctypes.ValType {
            return v;
        }
    };

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const ctx = Ctx{
        .added_list = &added,
        .slot_cache = &cache,
        .alloc = allocator,
    };
    for (ext.funcs) |f| {
        _ = try lift_types.transcribeFuncSig(scratch.allocator(), ctx, ext.type_slots, f.sig);
    }
    return added.toOwnedSlice(allocator);
}

// ── Core Generator Implementation ──────────────────────────────────────────

const synth_world_imports_name = "wit-zigar-world-imports";
const synth_world_exports_name = "wit-zigar-world-exports";
const synth_all_world_name = "wit-zigar-all-world";

pub fn generateFromResolver(
    allocator: Allocator,
    input_res: resolver_mod.Resolver,
    opts: BindgenOptions,
) BindgenError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // Ensure embedded WASI docs are attached as fallback dependencies.
    const base_res = if (input_res.deps.len == 0)
        try resolver_mod.finishWithEmbedded(ar, input_res.main, &.{})
    else
        input_res;

    const prepared = try prepareWorldAndResolver(ar, base_res, opts.world_name);
    const effective_res = prepared.res;
    const target_world_name = prepared.world_name;

    const ct_bytes = try metadata_encode.encodeWorldFromResolver(ar, effective_res, target_world_name);
    const decoded = try metadata_decode.decode(ar, ct_bytes);

    // Map each interface extern to a unique Zig namespace identifier.
    const iface_bindings = try assignInterfaceIdentities(ar, effective_res, decoded, prepared);

    var qname_to_zig_ns = std.StringHashMapUnmanaged([]const u8).empty;
    for (iface_bindings) |ib| {
        if (!ib.is_synth_world) {
            try qname_to_zig_ns.put(ar, ib.ext.qualified_name, ib.zig_ident);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = BufWriter{ .list = &out, .alloc = allocator };

    try w.writeAll("// Generated by wit-zigar. DO NOT EDIT.\n");
    try w.writeAll("const std = @import(\"std\");\n\n");

    if (opts.emit_runtime_helpers) {
        try emitPreambleHelpers(w);
    }

    try w.print("pub const world_name = \"{s}\";\n", .{decoded.qualified_name});
    try w.print("pub const is_wasm64 = {};\n\n", .{opts.arch == .wasm64});

    // Emit any world-level types, imports, and exports (from synthetic world interfaces
    // or top-level `decoded.func_externs`).
    try emitWorldLevelBindings(
        ar,
        w,
        effective_res,
        prepared,
        decoded,
        iface_bindings,
        qname_to_zig_ns,
        opts,
    );

    // Emit each interface namespace.
    for (iface_bindings) |ib| {
        if (ib.is_synth_world) continue;
        try emitInterfaceNamespace(
            ar,
            w,
            effective_res,
            decoded,
            ib,
            qname_to_zig_ns,
            opts,
        );
    }

    return out.toOwnedSlice(allocator);
}

const BufWriter = struct {
    list: *std.ArrayList(u8),
    alloc: Allocator,

    pub fn writeAll(self: BufWriter, bytes: []const u8) Allocator.Error!void {
        try self.list.appendSlice(self.alloc, bytes);
    }

    pub fn writeByte(self: BufWriter, b: u8) Allocator.Error!void {
        try self.list.append(self.alloc, b);
    }

    pub fn print(self: BufWriter, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.list.appendSlice(self.alloc, s);
    }
};

fn emitPreambleHelpers(w: BufWriter) !void {
    try w.writeAll(
        \\pub const Char = u21;
        \\
        \\pub fn Result(comptime Ok: type, comptime Err: type) type {
        \\    return union(enum(u8)) {
        \\        ok: Ok,
        \\        err: Err,
        \\        pub const wit_is_result = true;
        \\        pub const OkType = Ok;
        \\        pub const ErrType = Err;
        \\    };
        \\}
        \\
        \\pub fn Own(comptime R: type) type {
        \\    return extern struct {
        \\        handle: i32,
        \\        pub const Resource = R;
        \\        pub const wit_handle_kind = .own;
        \\    };
        \\}
        \\
        \\pub fn Borrow(comptime R: type) type {
        \\    return extern struct {
        \\        handle: i32,
        \\        pub const Resource = R;
        \\        pub const wit_handle_kind = .borrow;
        \\    };
        \\}
        \\
        \\pub fn Stream(comptime T: type) type {
        \\    return extern struct {
        \\        handle: i32,
        \\        pub const Payload = T;
        \\        pub const wit_handle_kind = .stream;
        \\    };
        \\}
        \\
        \\pub fn Future(comptime T: type) type {
        \\    return extern struct {
        \\        handle: i32,
        \\        pub const Payload = T;
        \\        pub const wit_handle_kind = .future;
        \\    };
        \\}
        \\
        \\pub const ErrorContext = extern struct {
        \\    handle: i32,
        \\    pub const wit_handle_kind = .error_context;
        \\};
        \\
        \\pub const WitString = struct {
        \\    bytes: []const u8 = "",
        \\    pub const wit_is_string = true;
        \\};
        \\
        \\pub fn CanonSlice(comptime PtrInt: type) type {
        \\    return extern struct {
        \\        ptr: PtrInt = 0,
        \\        len: PtrInt = 0,
        \\    };
        \\}
        \\
        \\
    );
}

const PreparedWorld = struct {
    res: resolver_mod.Resolver,
    world_name: []const u8,
    world: ast.World,
    pkg: ast.PackageId,
    world_type_items: []const ast.InterfaceItem,
    world_import_funcs: []const ast.InterfaceItem,
    world_export_funcs: []const ast.InterfaceItem,
};

fn prepareWorldAndResolver(
    ar: Allocator,
    res: resolver_mod.Resolver,
    maybe_world_name: ?[]const u8,
) BindgenError!PreparedWorld {
    var main_doc = res.main;
    if (main_doc.package == null) {
        main_doc.package = .{ .namespace = "local", .name = "root", .version = null };
    }

    var target_world: ?ast.World = null;
    var target_pkg: ast.PackageId = main_doc.package.?;

    if (maybe_world_name) |wname| {
        if (findWorldInDoc(main_doc, wname)) |w| {
            target_world = w;
        } else if (parseWorldSpec(wname)) |spec| {
            const ref = ast.InterfaceRef{
                .package = .{
                    .namespace = spec.namespace,
                    .name = spec.pkg_name,
                    .version = spec.version,
                },
                .name = spec.world_name,
            };
            if (res.findWorld(ref)) |hit| {
                target_world = hit.world;
                target_pkg = hit.pkg;
                for (res.deps) |d| {
                    if (d.package) |dp| {
                        if (samePkgRelaxed(dp, hit.pkg) and findWorldInDoc(d, hit.world.name) != null) {
                            main_doc = d;
                            break;
                        }
                    }
                }
            } else return error.UnknownWorld;
        } else {
            if (res.findWorld(.{ .package = null, .name = wname })) |hit| {
                target_world = hit.world;
                target_pkg = hit.pkg;
            } else {
                for (res.deps) |d| {
                    if (findWorldInDoc(d, wname)) |w| {
                        target_world = w;
                        target_pkg = d.package orelse target_pkg;
                        main_doc = d;
                        break;
                    }
                }
                if (target_world == null) return error.UnknownWorld;
            }
        }
    } else {
        var world_count: usize = 0;
        var single_world: ?ast.World = null;
        for (main_doc.items) |it| {
            if (it == .world) {
                world_count += 1;
                single_world = it.world;
            }
        }
        if (world_count == 1) {
            target_world = single_world;
        } else {
            // Synthesize a world importing all interfaces and including all worlds in `main_doc`.
            var synth_items = std.ArrayList(ast.WorldItem).empty;
            for (main_doc.items) |it| {
                switch (it) {
                    .interface => |iface| {
                        try synth_items.append(ar, .{ .import = .{ .interface_ref = .{
                            .docs = iface.docs,
                            .ref = .{ .package = null, .name = iface.name },
                        } } });
                    },
                    .world => |w| {
                        try synth_items.append(ar, .{ .include = .{
                            .docs = w.docs,
                            .target = .{ .package = null, .name = w.name },
                        } });
                    },
                    .use => {},
                }
            }
            const synth_w = ast.World{
                .docs = "",
                .name = synth_all_world_name,
                .items = try synth_items.toOwnedSlice(ar),
            };
            var new_doc_items = std.ArrayList(ast.TopLevelItem).empty;
            try new_doc_items.appendSlice(ar, main_doc.items);
            try new_doc_items.append(ar, .{ .world = synth_w });
            main_doc.items = try new_doc_items.toOwnedSlice(ar);
            target_world = synth_w;
        }
    }

    const world = target_world.?;

    // Check if the world has world-level `.type` or `.use` items (or `named_func` items
    // that need them). If so, hoist them into synthetic interfaces on `main_doc` so
    // `metadata_encode` can lower all compound/named types uniformly.
    var world_type_items = std.ArrayList(ast.InterfaceItem).empty;
    var world_import_funcs = std.ArrayList(ast.InterfaceItem).empty;
    var world_export_funcs = std.ArrayList(ast.InterfaceItem).empty;

    for (world.items) |wi| {
        switch (wi) {
            .use => |u| try world_type_items.append(ar, .{ .use = u }),
            .type => |td| try world_type_items.append(ar, .{ .type = td }),
            else => {},
        }
    }

    if (world_type_items.items.len > 0) {
        var rewritten_world_items = std.ArrayList(ast.WorldItem).empty;
        for (world.items) |wi| {
            switch (wi) {
                .use, .type => {},
                .import => |we| switch (we) {
                    .named_func => |nf| {
                        try world_import_funcs.append(ar, .{ .func = .{
                            .docs = nf.docs,
                            .name = nf.name,
                            .func = nf.func,
                        } });
                    },
                    else => try rewritten_world_items.append(ar, wi),
                },
                .@"export" => |we| switch (we) {
                    .named_func => |nf| {
                        try world_export_funcs.append(ar, .{ .func = .{
                            .docs = nf.docs,
                            .name = nf.name,
                            .func = nf.func,
                        } });
                    },
                    else => try rewritten_world_items.append(ar, wi),
                },
                else => try rewritten_world_items.append(ar, wi),
            }
        }

        var new_top_items = std.ArrayList(ast.TopLevelItem).empty;
        for (main_doc.items) |it| {
            if (it == .world and std.mem.eql(u8, it.world.name, world.name)) continue;
            try new_top_items.append(ar, it);
        }

        var import_iface_items = std.ArrayList(ast.InterfaceItem).empty;
        try import_iface_items.appendSlice(ar, world_type_items.items);
        try import_iface_items.appendSlice(ar, world_import_funcs.items);
        try new_top_items.append(ar, .{ .interface = .{
            .name = synth_world_imports_name,
            .items = try import_iface_items.toOwnedSlice(ar),
        } });
        try rewritten_world_items.append(ar, .{ .import = .{ .interface_ref = .{
            .ref = .{ .package = null, .name = synth_world_imports_name },
        } } });

        if (world_export_funcs.items.len > 0) {
            var export_iface_items = std.ArrayList(ast.InterfaceItem).empty;
            try export_iface_items.appendSlice(ar, world_type_items.items);
            try export_iface_items.appendSlice(ar, world_export_funcs.items);
            try new_top_items.append(ar, .{ .interface = .{
                .name = synth_world_exports_name,
                .items = try export_iface_items.toOwnedSlice(ar),
            } });
            try rewritten_world_items.append(ar, .{ .@"export" = .{ .interface_ref = .{
                .ref = .{ .package = null, .name = synth_world_exports_name },
            } } });
        }

        const rewritten_world = ast.World{
            .docs = world.docs,
            .name = world.name,
            .items = try rewritten_world_items.toOwnedSlice(ar),
        };
        try new_top_items.append(ar, .{ .world = rewritten_world });
        main_doc.items = try new_top_items.toOwnedSlice(ar);

        return .{
            .res = resolver_mod.Resolver.init(main_doc, res.deps),
            .world_name = rewritten_world.name,
            .world = rewritten_world,
            .pkg = target_pkg,
            .world_type_items = try world_type_items.toOwnedSlice(ar),
            .world_import_funcs = try world_import_funcs.toOwnedSlice(ar),
            .world_export_funcs = try world_export_funcs.toOwnedSlice(ar),
        };
    } else {
        for (world.items) |wi| {
            switch (wi) {
                .import => |we| if (we == .named_func) {
                    const nf = we.named_func;
                    try world_import_funcs.append(ar, .{ .func = .{
                        .docs = nf.docs,
                        .name = nf.name,
                        .func = nf.func,
                    } });
                },
                .@"export" => |we| if (we == .named_func) {
                    const nf = we.named_func;
                    try world_export_funcs.append(ar, .{ .func = .{
                        .docs = nf.docs,
                        .name = nf.name,
                        .func = nf.func,
                    } });
                },
                else => {},
            }
        }
    }

    return .{
        .res = resolver_mod.Resolver.init(main_doc, res.deps),
        .world_name = world.name,
        .world = world,
        .pkg = target_pkg,
        .world_type_items = &.{},
        .world_import_funcs = try world_import_funcs.toOwnedSlice(ar),
        .world_export_funcs = try world_export_funcs.toOwnedSlice(ar),
    };
}

fn findWorldInDoc(doc: ast.Document, name: []const u8) ?ast.World {
    for (doc.items) |it| {
        if (it == .world and std.mem.eql(u8, it.world.name, name)) return it.world;
    }
    return null;
}

fn samePkgRelaxed(a: ast.PackageId, b: ast.PackageId) bool {
    if (!std.mem.eql(u8, a.namespace, b.namespace)) return false;
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    const av = a.version orelse return true;
    const bv = b.version orelse return true;
    return std.mem.eql(u8, av, bv);
}

const InterfaceBinding = struct {
    ext: metadata_decode.WorldExtern,
    pkg: ast.PackageId,
    bare_name: []const u8,
    items: []const ast.InterfaceItem,
    zig_ident: []const u8,
    alias_ident: ?[]const u8,
    is_synth_world: bool,
};

fn assignInterfaceIdentities(
    ar: Allocator,
    res: resolver_mod.Resolver,
    decoded: metadata_decode.DecodedWorld,
    prepared: PreparedWorld,
) BindgenError![]InterfaceBinding {
    var list = std.ArrayList(InterfaceBinding).empty;
    var seen_qnames = std.StringHashMapUnmanaged(void).empty;

    // First pass: resolve AST items and bare names for each decoded extern.
    var bare_counts = std.StringHashMapUnmanaged(usize).empty;
    for (decoded.externs) |ext| {
        const resolved = try resolveExternAst(ar, res, prepared, ext.qualified_name);
        const is_synth = std.mem.eql(u8, resolved.bare_name, synth_world_imports_name) or
            std.mem.eql(u8, resolved.bare_name, synth_world_exports_name);

        try list.append(ar, .{
            .ext = ext,
            .pkg = resolved.pkg,
            .bare_name = resolved.bare_name,
            .items = resolved.items,
            .zig_ident = "",
            .alias_ident = null,
            .is_synth_world = is_synth,
        });
        try seen_qnames.put(ar, ext.qualified_name, {});
        if (!is_synth) {
            const raw_bare = try toRawSnakeCase(ar, resolved.bare_name);
            const gop = try bare_counts.getOrPut(ar, raw_bare);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    // Transitively include any interfaces referenced via `use` whose types
    // were inlined by `metadata_encode` without an explicit world instance extern.
    var scan_idx: usize = 0;
    while (scan_idx < list.items.len) : (scan_idx += 1) {
        const cur = list.items[scan_idx];
        for (cur.items) |item| {
            if (item != .use) continue;
            const u = item.use;
            const src_lookup = res.findInterfaceWithPkgCtx(u.from, cur.pkg) orelse continue;
            const src_qname = try formatQualifiedName(
                ar,
                src_lookup.pkg.namespace,
                src_lookup.pkg.name,
                src_lookup.iface.name,
                src_lookup.pkg.version,
            );
            if (seen_qnames.contains(src_qname)) continue;
            try seen_qnames.put(ar, src_qname, {});

            const raw_bare = try toRawSnakeCase(ar, src_lookup.iface.name);
            const gop = try bare_counts.getOrPut(ar, raw_bare);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;

            try list.append(ar, .{
                .ext = .{
                    .qualified_name = src_qname,
                    .is_export = false,
                    .inst_decls = &.{},
                    .type_slots = &.{},
                    .funcs = &.{},
                },
                .pkg = src_lookup.pkg,
                .bare_name = src_lookup.iface.name,
                .items = src_lookup.iface.items,
                .zig_ident = "",
                .alias_ident = null,
                .is_synth_world = false,
            });
        }
    }

    // Second pass: assign collision-free Zig namespace identifiers.
    var used_idents = std.StringHashMapUnmanaged(void).empty;
    for (list.items) |*ib| {
        if (ib.is_synth_world) continue;
        const raw_bare = try toRawSnakeCase(ar, ib.bare_name);
        const count = bare_counts.get(raw_bare) orelse 1;
        const pkg_raw = try toRawSnakeCase(ar, ib.pkg.name);
        const qualified_raw = if (pkg_raw.len > 0 and !std.mem.eql(u8, pkg_raw, "root"))
            try std.fmt.allocPrint(ar, "{s}_{s}", .{ pkg_raw, raw_bare })
        else
            raw_bare;

        if (count == 1 and !used_idents.contains(raw_bare)) {
            ib.zig_ident = try escapeZigId(ar, raw_bare);
            try used_idents.put(ar, raw_bare, {});
            if (!std.mem.eql(u8, qualified_raw, raw_bare) and !used_idents.contains(qualified_raw)) {
                ib.alias_ident = try escapeZigId(ar, qualified_raw);
                try used_idents.put(ar, qualified_raw, {});
            }
        } else {
            // Multiple interfaces share `raw_bare` (e.g. `types` across `clocks`,
            // `filesystem`, `sockets`, `cli`, `http`, or an interface both imported
            // and exported). Give the main package's interface `raw_bare` if unused.
            const in_main_pkg = samePkgRelaxed(ib.pkg, prepared.pkg);
            if (in_main_pkg and !used_idents.contains(raw_bare)) {
                ib.zig_ident = try escapeZigId(ar, raw_bare);
                try used_idents.put(ar, raw_bare, {});
                if (!std.mem.eql(u8, qualified_raw, raw_bare) and !used_idents.contains(qualified_raw)) {
                    ib.alias_ident = try escapeZigId(ar, qualified_raw);
                    try used_idents.put(ar, qualified_raw, {});
                }
            } else if (!used_idents.contains(qualified_raw)) {
                ib.zig_ident = try escapeZigId(ar, qualified_raw);
                try used_idents.put(ar, qualified_raw, {});
                if (!used_idents.contains(raw_bare)) {
                    ib.alias_ident = try escapeZigId(ar, raw_bare);
                    try used_idents.put(ar, raw_bare, {});
                }
            } else {
                const dir_prefix = if (ib.ext.is_export) "export" else "import";
                const fallback_raw = try std.fmt.allocPrint(ar, "{s}_{s}", .{ dir_prefix, qualified_raw });
                ib.zig_ident = try escapeZigId(ar, fallback_raw);
                try used_idents.put(ar, fallback_raw, {});
            }
        }
    }

    return list.toOwnedSlice(ar);
}

const ResolvedExternAst = struct {
    pkg: ast.PackageId,
    bare_name: []const u8,
    items: []const ast.InterfaceItem,
};

fn resolveExternAst(
    ar: Allocator,
    res: resolver_mod.Resolver,
    prepared: PreparedWorld,
    qualified_name: []const u8,
) BindgenError!ResolvedExternAst {
    if (parseWorldSpec(qualified_name)) |spec| {
        const ref = ast.InterfaceRef{
            .package = .{
                .namespace = spec.namespace,
                .name = spec.pkg_name,
                .version = spec.version,
            },
            .name = spec.world_name,
        };
        if (res.findInterfaceWithPkg(ref)) |hit| {
            return .{
                .pkg = hit.pkg,
                .bare_name = hit.iface.name,
                .items = hit.iface.items,
            };
        }
    }

    // Check inline `named_interface` in the world.
    for (prepared.world.items) |wi| {
        switch (wi) {
            .import, .@"export" => |we| switch (we) {
                .named_interface => |ni| {
                    if (std.mem.eql(u8, ni.name, qualified_name)) {
                        return .{
                            .pkg = prepared.pkg,
                            .bare_name = ni.name,
                            .items = ni.items,
                        };
                    }
                },
                else => {},
            },
            else => {},
        }
    }

    if (res.findInterfaceWithPkgCtx(.{ .package = null, .name = qualified_name }, prepared.pkg)) |hit| {
        return .{
            .pkg = hit.pkg,
            .bare_name = hit.iface.name,
            .items = hit.iface.items,
        };
    }

    _ = ar;
    return error.UnknownInterface;
}

// ── World-Level Types & Functions Emission ─────────────────────────────────

fn emitWorldLevelBindings(
    ar: Allocator,
    w: anytype,
    res: resolver_mod.Resolver,
    prepared: PreparedWorld,
    decoded: metadata_decode.DecodedWorld,
    iface_bindings: []const InterfaceBinding,
    qname_to_zig_ns: std.StringHashMapUnmanaged([]const u8),
    opts: BindgenOptions,
) BindgenError!void {
    // Find any synthetic world import/export interface bindings.
    var synth_import_ib: ?InterfaceBinding = null;
    var synth_export_ib: ?InterfaceBinding = null;
    for (iface_bindings) |ib| {
        if (!ib.is_synth_world) continue;
        if (std.mem.eql(u8, ib.bare_name, synth_world_imports_name)) {
            synth_import_ib = ib;
        } else if (std.mem.eql(u8, ib.bare_name, synth_world_exports_name)) {
            synth_export_ib = ib;
        }
    }

    if (synth_import_ib) |ib| {
        const sorted_items = try sortInterfaceItems(ar, ib.items);
        for (sorted_items) |item| {
            switch (item) {
                .use => |u| try emitUseItem(ar, w, res, ib.pkg, u, qname_to_zig_ns, ""),
                .type => |td| try emitTypeDef(
                    ar,
                    w,
                    res,
                    ib.items,
                    ib.pkg,
                    "$root",
                    td,
                    ib.ext,
                    decoded.world_decls,
                    opts,
                    "",
                ),
                .func => {},
            }
        }
    }

    // Track world-level imported vs exported function names to disambiguate collisions.
    var world_import_names = std.StringHashMapUnmanaged(void).empty;
    var world_export_names = std.StringHashMapUnmanaged(void).empty;
    if (synth_import_ib) |ib| {
        for (ib.items) |it| {
            if (it == .func) try world_import_names.put(ar, it.func.name, {});
        }
    }
    if (synth_export_ib) |ib| {
        for (ib.items) |it| {
            if (it == .func) try world_export_names.put(ar, it.func.name, {});
        }
    }
    for (decoded.func_externs) |fe| {
        if (fe.is_export) {
            try world_export_names.put(ar, fe.name, {});
        } else {
            try world_import_names.put(ar, fe.name, {});
        }
    }

    // Collect world-level imported functions (either from `synth_import_ib` or `decoded.func_externs`)
    // and world-level exported async functions (whose `[task-return]` is imported from `[export]$root`).
    const has_world_imports = (synth_import_ib != null and synth_import_ib.?.ext.funcs.len > 0) or blk: {
        for (decoded.func_externs) |fe| {
            if (!fe.is_export) break :blk true;
        }
        break :blk false;
    };
    const has_world_async_exports = blk: {
        if (synth_export_ib) |ib| {
            for (ib.ext.funcs) |fref| {
                if (fref.sig.is_async) break :blk true;
            }
        }
        for (decoded.func_externs) |fe| {
            if (fe.is_export and fe.sig.is_async) break :blk true;
        }
        break :blk false;
    };
    const has_world_resources = if (synth_import_ib) |ib| hasResources(ib.items) else false;

    if (has_world_imports or has_world_async_exports or has_world_resources) {
        try w.writeAll("pub const raw = struct {\n");
        if (synth_import_ib) |ib| {
            for (ib.items) |it| {
                if (it == .type and it.type.kind == .resource) {
                    try w.print(
                        "    pub extern \"$root\" fn @\"[resource-drop]{s}\"(handle: i32) void;\n",
                        .{it.type.name},
                    );
                }
            }
            for (ib.ext.funcs) |fref| {
                const ftr = abi.FuncTypeRef{
                    .func = fref.sig,
                    .resolver = .{
                        .inst_decls = ib.ext.inst_decls,
                        .world_decls = decoded.world_decls,
                    },
                };
                const core_sig = try abi.lowerCoreSigForArch(ar, ftr, opts.arch == .wasm64);
                try emitRawExternDecl(w, "$root", fref.name, core_sig, "    ");
            }
        }
        if (synth_export_ib) |ib| {
            for (ib.ext.funcs) |fref| {
                if (!fref.sig.is_async) continue;
                const ftr = abi.FuncTypeRef{
                    .func = fref.sig,
                    .resolver = .{
                        .inst_decls = ib.ext.inst_decls,
                        .world_decls = decoded.world_decls,
                    },
                };
                const tr_sig = try abi.taskReturnCoreSigForArch(ar, ftr, opts.arch == .wasm64);
                const tr_name = try std.fmt.allocPrint(ar, "[task-return]{s}", .{fref.name});
                try emitRawExternDecl(w, "[export]$root", tr_name, tr_sig, "    ");
            }
        }
        for (decoded.func_externs) |fe| {
            const ftr = abi.FuncTypeRef{
                .func = fe.sig,
                .resolver = .{
                    .inst_decls = decoded.world_decls,
                    .world_decls = decoded.world_decls,
                },
            };
            if (!fe.is_export) {
                const core_sig = try abi.lowerCoreSigForArch(ar, ftr, opts.arch == .wasm64);
                try emitRawExternDecl(w, "$root", fe.name, core_sig, "    ");
            } else if (fe.sig.is_async) {
                const tr_sig = try abi.taskReturnCoreSigForArch(ar, ftr, opts.arch == .wasm64);
                const tr_name = try std.fmt.allocPrint(ar, "[task-return]{s}", .{fe.name});
                try emitRawExternDecl(w, "[export]$root", tr_name, tr_sig, "    ");
            }
        }
        try w.writeAll("};\n\n");
    }

    if (synth_import_ib) |ib| {
        for (ib.items) |it| {
            if (it != .func) continue;
            if (findFuncRef(ib.ext.funcs, it.func.name)) |fref| {
                const collides = world_export_names.contains(it.func.name);
                const prefix: []const u8 = if (collides) "import_" else "";
                try emitFuncSigAndMeta(
                    ar,
                    w,
                    res,
                    ib.items,
                    ib.pkg,
                    "$root",
                    false,
                    prefix,
                    it.func.name,
                    it.func.func,
                    fref.sig,
                    ib.ext.inst_decls,
                    decoded.world_decls,
                    opts,
                    "",
                );
            }
        }
    }

    if (synth_export_ib) |ib| {
        for (ib.items) |it| {
            if (it != .func) continue;
            if (findFuncRef(ib.ext.funcs, it.func.name)) |fref| {
                const collides = world_import_names.contains(it.func.name);
                const prefix: []const u8 = if (collides) "export_" else "";
                try emitFuncSigAndMeta(
                    ar,
                    w,
                    res,
                    ib.items,
                    ib.pkg,
                    "$root",
                    true,
                    prefix,
                    it.func.name,
                    it.func.func,
                    fref.sig,
                    ib.ext.inst_decls,
                    decoded.world_decls,
                    opts,
                    "",
                );
            }
        }
        try emitExportBindingsHelper(
            ar,
            w,
            "",
            ib.items,
            ib.ext.funcs,
            ib.ext.inst_decls,
            decoded.world_decls,
            world_import_names,
            opts,
            "",
        );
        try w.writeAll("pub const exportWorldBindings = exportBindings;\n\n");
    }

    // Also emit any plain `decoded.func_externs` (when no world-level types existed).
    var plain_export_items = std.ArrayList(ast.InterfaceItem).empty;
    var plain_export_frefs = std.ArrayList(metadata_decode.FuncRef).empty;
    for (decoded.func_externs) |fe| {
        // Find the AST Func in the target world (and its included worlds).
        const ast_fn = findWorldNamedFunc(res, prepared.world, prepared.pkg, fe.name, fe.is_export, 0);
        if (ast_fn) |af| {
            const collides = if (fe.is_export)
                world_import_names.contains(fe.name)
            else
                world_export_names.contains(fe.name);
            const prefix: []const u8 = if (collides)
                (if (fe.is_export) "export_" else "import_")
            else
                "";
            try emitFuncSigAndMeta(
                ar,
                w,
                res,
                &.{},
                prepared.pkg,
                "$root",
                fe.is_export,
                prefix,
                fe.name,
                af,
                fe.sig,
                decoded.world_decls,
                decoded.world_decls,
                opts,
                "",
            );
            if (fe.is_export) {
                try plain_export_items.append(ar, .{ .func = .{ .name = fe.name, .func = af } });
                try plain_export_frefs.append(ar, .{ .name = fe.name, .sig = fe.sig });
            }
        }
    }
    if (plain_export_items.items.len > 0) {
        try emitExportBindingsHelper(
            ar,
            w,
            "",
            plain_export_items.items,
            plain_export_frefs.items,
            decoded.world_decls,
            decoded.world_decls,
            world_import_names,
            opts,
            "",
        );
        try w.writeAll("pub const exportWorldBindings = exportBindings;\n\n");
    }
}

fn findWorldNamedFunc(
    res: resolver_mod.Resolver,
    world: ast.World,
    pkg: ast.PackageId,
    name: []const u8,
    is_export: bool,
    depth: u32,
) ?ast.Func {
    if (depth > 16) return null;
    for (world.items) |wi| {
        switch (wi) {
            .import => |im| if (!is_export and im == .named_func and std.mem.eql(u8, im.named_func.name, name)) {
                return im.named_func.func;
            },
            .@"export" => |ex| if (is_export and ex == .named_func and std.mem.eql(u8, ex.named_func.name, name)) {
                return ex.named_func.func;
            },
            .include => |inc| {
                var target_name = name;
                for (inc.with) |rn| {
                    if (rn.rename) |renamed| {
                        if (std.mem.eql(u8, renamed, name)) {
                            target_name = rn.name;
                            break;
                        }
                    }
                }
                if (res.findWorldCtx(inc.target, pkg)) |inc_lookup| {
                    if (findWorldNamedFunc(res, inc_lookup.world, inc_lookup.pkg, target_name, is_export, depth + 1)) |found| {
                        return found;
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

// ── Interface Namespace Emission ───────────────────────────────────────────

fn emitInterfaceNamespace(
    ar: Allocator,
    w: anytype,
    res: resolver_mod.Resolver,
    decoded: metadata_decode.DecodedWorld,
    ib: InterfaceBinding,
    qname_to_zig_ns: std.StringHashMapUnmanaged([]const u8),
    opts: BindgenOptions,
) BindgenError!void {
    try w.print("pub const {s} = struct {{\n", .{ib.zig_ident});
    try w.print("    pub const interface_name = \"{s}\";\n", .{ib.ext.qualified_name});
    try w.print("    pub const is_export = {};\n\n", .{ib.ext.is_export});

    const sorted_items = try sortInterfaceItems(ar, ib.items);

    // 1. Emit `use` aliases and `TypeDef` declarations.
    for (sorted_items) |item| {
        switch (item) {
            .use => |u| try emitUseItem(ar, w, res, ib.pkg, u, qname_to_zig_ns, "    "),
            .type => |td| try emitTypeDef(
                ar,
                w,
                res,
                ib.items,
                ib.pkg,
                ib.ext.qualified_name,
                td,
                ib.ext,
                decoded.world_decls,
                opts,
                "    ",
            ),
            .func => {},
        }
    }

    // 2. Emit `pub const raw = struct { ... };` with core Wasm extern declarations.
    // For exported interfaces, omit raw `pub extern` declarations on exported functions
    // (only `[resource-drop]` imports belong in `raw` on exports).
    try w.writeAll("    pub const raw = struct {\n");
    for (sorted_items) |item| {
        if (item == .type and item.type.kind == .resource) {
            const drop_mod = if (ib.ext.is_export)
                try std.fmt.allocPrint(ar, "[export]{s}", .{ib.ext.qualified_name})
            else
                ib.ext.qualified_name;
            try w.print(
                "        pub extern \"{s}\" fn @\"[resource-drop]{s}\"(handle: i32) void;\n",
                .{ drop_mod, item.type.name },
            );
        }
    }
    if (!ib.ext.is_export) {
        for (ib.ext.funcs) |fref| {
            const ftr = abi.FuncTypeRef{
                .func = fref.sig,
                .resolver = .{
                    .inst_decls = ib.ext.inst_decls,
                    .world_decls = decoded.world_decls,
                },
            };
            const core_sig = try abi.lowerCoreSigForArch(ar, ftr, opts.arch == .wasm64);
            try emitRawExternDecl(w, ib.ext.qualified_name, fref.name, core_sig, "        ");
        }
    } else {
        const exp_mod = try std.fmt.allocPrint(ar, "[export]{s}", .{ib.ext.qualified_name});
        for (ib.ext.funcs) |fref| {
            if (!fref.sig.is_async) continue;
            const ftr = abi.FuncTypeRef{
                .func = fref.sig,
                .resolver = .{
                    .inst_decls = ib.ext.inst_decls,
                    .world_decls = decoded.world_decls,
                },
            };
            const tr_sig = try abi.taskReturnCoreSigForArch(ar, ftr, opts.arch == .wasm64);
            const tr_name = try std.fmt.allocPrint(ar, "[task-return]{s}", .{fref.name});
            try emitRawExternDecl(w, exp_mod, tr_name, tr_sig, "        ");
        }
    }
    try w.writeAll("    };\n\n");

    // 3. Emit high-level function signatures and metadata.
    for (sorted_items) |item| {
        if (item != .func) continue;
        if (findFuncRef(ib.ext.funcs, item.func.name)) |fref| {
            try emitFuncSigAndMeta(
                ar,
                w,
                res,
                ib.items,
                ib.pkg,
                ib.ext.qualified_name,
                ib.ext.is_export,
                "",
                item.func.name,
                item.func.func,
                fref.sig,
                ib.ext.inst_decls,
                decoded.world_decls,
                opts,
                "    ",
            );
        }
    }

    // 4. For exported interfaces, verify `lift_types.transcribeFuncSig` and emit `exportBindings`.
    if (ib.ext.is_export) {
        const hoisted = try transcribeExportedInterfaceFuncs(ar, ib.ext);
        try w.print("    pub const transcribed_types_count: u32 = {d};\n\n", .{hoisted.len});
        const empty_collisions = std.StringHashMapUnmanaged(void).empty;
        try emitExportBindingsHelper(
            ar,
            w,
            ib.ext.qualified_name,
            ib.items,
            ib.ext.funcs,
            ib.ext.inst_decls,
            decoded.world_decls,
            empty_collisions,
            opts,
            "    ",
        );
    }

    try w.writeAll("};\n");
    if (ib.alias_ident) |alias_id| {
        try w.print("pub const {s} = {s};\n", .{ alias_id, ib.zig_ident });
    }
    try w.writeByte('\n');
}

fn emitUseItem(
    ar: Allocator,
    w: anytype,
    res: resolver_mod.Resolver,
    current_pkg: ast.PackageId,
    u: ast.Use,
    qname_to_zig_ns: std.StringHashMapUnmanaged([]const u8),
    indent: []const u8,
) BindgenError!void {
    const src_lookup = res.findInterfaceWithPkgCtx(u.from, current_pkg) orelse
        return error.UnknownInterface;
    const src_qname = try formatQualifiedName(
        ar,
        src_lookup.pkg.namespace,
        src_lookup.pkg.name,
        u.from.name,
        src_lookup.pkg.version,
    );
    const target_ns = qname_to_zig_ns.get(src_qname) orelse
        try toSnakeCase(ar, u.from.name);

    for (u.names) |un| {
        const orig_pascal = try toPascalCase(ar, un.name);
        const alias_pascal = if (un.rename) |ren|
            try toPascalCase(ar, ren)
        else
            orig_pascal;
        try w.print("{s}pub const {s} = {s}.{s};\n", .{ indent, alias_pascal, target_ns, orig_pascal });
    }
}

fn emitTypeDef(
    ar: Allocator,
    w: anytype,
    res: resolver_mod.Resolver,
    iface_items: []const ast.InterfaceItem,
    pkg: ast.PackageId,
    canonical_module: []const u8,
    td: ast.TypeDef,
    ext: ?metadata_decode.WorldExtern,
    world_decls: []const ctypes.Decl,
    opts: BindgenOptions,
    indent: []const u8,
) BindgenError!void {
    const pascal_name = try toPascalCase(ar, td.name);
    switch (td.kind) {
        .alias => |target_ty| {
            const ty_str = try formatWitType(ar, target_ty);
            try w.print("{s}pub const {s} = {s};\n\n", .{ indent, pascal_name, ty_str });
        },
        .record => |fields| {
            const all_extern = recordIsExternCompatible(res, iface_items, pkg, fields, 0);
            if (all_extern) {
                try w.print("{s}pub const {s} = extern struct {{\n", .{ indent, pascal_name });
                for (fields) |f| {
                    const f_snake = try toSnakeCase(ar, f.name);
                    const f_ty = try formatWitType(ar, f.type);
                    try w.print("{s}    {s}: {s},\n", .{ indent, f_snake, f_ty });
                }
                try w.print("{s}}};\n\n", .{indent});
            } else {
                try w.print("{s}pub const {s} = struct {{\n", .{ indent, pascal_name });
                for (fields) |f| {
                    const f_snake = try toSnakeCase(ar, f.name);
                    const f_ty = try formatWitType(ar, f.type);
                    try w.print("{s}    {s}: {s},\n", .{ indent, f_snake, f_ty });
                }
                try w.print("\n{s}    pub const Canon = extern struct {{\n", .{indent});
                for (fields) |f| {
                    const f_snake = try toSnakeCase(ar, f.name);
                    const wire_ty = try formatCanonWireFieldType(ar, res, iface_items, pkg, f.type, opts);
                    try w.print("{s}        {s}: {s},\n", .{ indent, f_snake, wire_ty });
                }
                try w.print("{s}    }};\n", .{indent});
                try w.print("{s}}};\n\n", .{indent});
            }
        },
        .@"enum" => |cases| {
            const backing = discBackingInt(cases.len);
            try w.print("{s}pub const {s} = enum({s}) {{\n", .{ indent, pascal_name, backing });
            for (cases, 0..) |c, idx| {
                const c_snake = try toSnakeCase(ar, c);
                try w.print("{s}    {s} = {d},\n", .{ indent, c_snake, idx });
            }
            try w.print("{s}}};\n\n", .{indent});
        },
        .flags => |flags| {
            const f_count = flags.len;
            if (f_count == 0) {
                try w.print("{s}pub const {s} = packed struct(u8) {{\n", .{ indent, pascal_name });
                try w.print("{s}    _padding: u8 = 0,\n", .{indent});
                try w.print("{s}    pub const wit_flags_count: u32 = 0;\n", .{indent});
                try w.print("{s}}};\n\n", .{indent});
            } else if (f_count <= 32) {
                const backing_bits: usize = if (f_count <= 8)
                    8
                else if (f_count <= 16)
                    16
                else
                    32;
                try w.print("{s}pub const {s} = packed struct(u{d}) {{\n", .{ indent, pascal_name, backing_bits });
                for (flags) |fl| {
                    const fl_snake = try toSnakeCase(ar, fl);
                    try w.print("{s}    {s}: bool = false,\n", .{ indent, fl_snake });
                }
                const pad_bits = backing_bits - f_count;
                if (pad_bits > 0) {
                    try w.print("{s}    _padding: u{d} = 0,\n", .{ indent, pad_bits });
                }
                try w.print("{s}    pub const wit_flags_count: u32 = {d};\n", .{ indent, f_count });
                try w.print("{s}}};\n\n", .{indent});
            } else {
                const num_words = (f_count + 31) / 32;
                const backing_bits = num_words * 32;
                try w.print("{s}pub const {s} = extern struct {{\n", .{ indent, pascal_name });
                try w.print("{s}    words: [{d}]u32 = @splat(0),\n", .{ indent, num_words });
                try w.print("{s}    pub const wit_flags_count: u32 = {d};\n", .{ indent, f_count });
                try w.print("{s}    pub const Packed = packed struct(u{d}) {{\n", .{ indent, backing_bits });
                for (flags) |fl| {
                    const fl_snake = try toSnakeCase(ar, fl);
                    try w.print("{s}        {s}: bool = false,\n", .{ indent, fl_snake });
                }
                const pad_bits = backing_bits - f_count;
                if (pad_bits > 0) {
                    try w.print("{s}        _padding: u{d} = 0,\n", .{ indent, pad_bits });
                }
                try w.print("{s}        pub const wit_flags_count: u32 = {d};\n", .{ indent, f_count });
                try w.print("{s}    }};\n", .{indent});
                try w.print("{s}    pub fn get(self: @This(), bit: u32) bool {{\n", .{indent});
                try w.print("{s}        return (self.words[bit / 32] & (@as(u32, 1) << @intCast(bit % 32))) != 0;\n", .{indent});
                try w.print("{s}    }}\n", .{indent});
                try w.print("{s}    pub fn set(self: *@This(), bit: u32, val: bool) void {{\n", .{indent});
                try w.print("{s}        const mask = @as(u32, 1) << @intCast(bit % 32);\n", .{indent});
                try w.print("{s}        if (val) self.words[bit / 32] |= mask else self.words[bit / 32] &= ~mask;\n", .{indent});
                try w.print("{s}    }}\n", .{indent});
                try w.print("{s}    pub fn toPacked(self: @This()) Packed {{\n", .{indent});
                try w.print("{s}        var raw_bits: u{d} = 0;\n", .{ indent, backing_bits });
                try w.print("{s}        inline for (0..{d}) |w_idx| {{\n", .{ indent, num_words });
                try w.print("{s}            raw_bits |= @as(u{d}, self.words[w_idx]) << @intCast(w_idx * 32);\n", .{ indent, backing_bits });
                try w.print("{s}        }}\n", .{indent});
                try w.print("{s}        return @bitCast(raw_bits);\n", .{indent});
                try w.print("{s}    }}\n", .{indent});
                try w.print("{s}    pub fn fromPacked(p: Packed) @This() {{\n", .{indent});
                try w.print("{s}        const raw_bits: u{d} = @bitCast(p);\n", .{ indent, backing_bits });
                try w.print("{s}        var out: @This() = .{{}};\n", .{indent});
                try w.print("{s}        inline for (0..{d}) |w_idx| {{\n", .{ indent, num_words });
                try w.print("{s}            out.words[w_idx] = @truncate(raw_bits >> @intCast(w_idx * 32));\n", .{indent});
                try w.print("{s}        }}\n", .{indent});
                try w.print("{s}        return out;\n", .{indent});
                try w.print("{s}    }}\n", .{indent});
                try w.print("{s}}};\n\n", .{indent});
            }
        },
        .variant => |cases| {
            const backing = discBackingInt(cases.len);
            try w.print("{s}pub const {s} = union(enum({s})) {{\n", .{ indent, pascal_name, backing });
            for (cases) |c| {
                const c_snake = try toSnakeCase(ar, c.name);
                if (c.type) |payload_ty| {
                    const p_str = try formatWitType(ar, payload_ty);
                    try w.print("{s}    {s}: {s},\n", .{ indent, c_snake, p_str });
                } else {
                    try w.print("{s}    {s}: void,\n", .{ indent, c_snake });
                }
            }
            try w.print("{s}}};\n\n", .{indent});
        },
        .resource => |methods| {
            try w.print("{s}pub const {s} = struct {{\n", .{ indent, pascal_name });
            try w.print("{s}    pub const OwnHandle = Own(@This());\n", .{indent});
            try w.print("{s}    pub const BorrowHandle = Borrow(@This());\n", .{indent});
            try w.print("{s}    pub const Resource = @This();\n", .{indent});
            try w.print("{s}    pub const wit_handle_kind = .own;\n", .{indent});
            try w.print("{s}    pub const resource_name = \"{s}\";\n", .{ indent, td.name });
            try w.print("{s}    handle: i32 = 0,\n\n", .{indent});
            try w.print(
                "{s}    pub fn drop(self: Own(@This())) void {{\n{s}        raw.@\"[resource-drop]{s}\"(self.handle);\n{s}    }}\n",
                .{ indent, indent, td.name, indent },
            );

            for (methods) |m| {
                const ext_name = try formatResourceMemberName(ar, m.kind, td.name, m.name);
                const m_raw = switch (m.kind) {
                    .constructor => try ar.dupe(u8, "constructor"),
                    .method, .static => try toRawSnakeCase(ar, m.name),
                };

                try w.print("\n{s}    pub const {s}_Fn = fn (", .{ indent, m_raw });
                var first_param = true;
                if (m.kind == .method) {
                    try w.writeAll("Borrow(@This())");
                    first_param = false;
                }
                for (m.func.params) |p| {
                    if (!first_param) try w.writeAll(", ");
                    first_param = false;
                    const p_ty = try formatWitType(ar, p.type);
                    try w.writeAll(p_ty);
                }
                const ret_str = switch (m.kind) {
                    .constructor => try ar.dupe(u8, "Own(@This())"),
                    .method, .static => if (m.func.result) |r|
                        try formatWitType(ar, r)
                    else
                        try ar.dupe(u8, "void"),
                };
                try w.print(") {s};\n", .{ret_str});

                if (ext) |we| {
                    if (findFuncRef(we.funcs, ext_name)) |fref| {
                        const ftr = abi.FuncTypeRef{
                            .func = fref.sig,
                            .resolver = .{
                                .inst_decls = we.inst_decls,
                                .world_decls = world_decls,
                            },
                        };
                        const cls = abi.classifyFunc(ftr);
                        try w.print(
                            \\{s}    pub const {s}_meta = .{{
                            \\{s}        .wit_name = "{s}",
                            \\{s}        .interface_name = "{s}",
                            \\{s}        .kind = .{s},
                            \\{s}        .is_async = {},
                            \\{s}        .params_flat = @as(u32, {d}),
                            \\{s}        .results_flat = @as(u32, {d}),
                            \\{s}        .has_result = {},
                            \\{s}        .is_direct = {},
                            \\{s}        .needs_memory = {},
                            \\{s}        .needs_realloc = {},
                            \\{s}        .string_encoding_utf8 = {},
                            \\{s}    }};
                            \\
                        , .{
                            indent,
                            m_raw,
                            indent,
                            ext_name,
                            indent,
                            canonical_module,
                            indent,
                            @tagName(m.kind),
                            indent,
                            m.func.is_async,
                            indent,
                            cls.params_flat,
                            indent,
                            cls.results_flat,
                            indent,
                            cls.has_result,
                            indent,
                            cls.class == .direct,
                            indent,
                            cls.opts.memory,
                            indent,
                            cls.opts.realloc,
                            indent,
                            cls.opts.string_encoding,
                            indent,
                        });
                    }
                }
            }
            try w.print("{s}}};\n\n", .{indent});
        },
    }
}

fn emitRawExternDecl(
    w: anytype,
    module_name: []const u8,
    func_name: []const u8,
    core_sig: abi.LoweredCoreSig,
    indent: []const u8,
) !void {
    try w.print("{s}pub extern \"{s}\" fn @\"{s}\"(", .{ indent, module_name, func_name });
    for (core_sig.params, 0..) |pt, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.print("p{d}: {s}", .{ idx, coreValTypeToZig(pt) });
    }
    const ret_ty = if (core_sig.results.len == 0)
        "void"
    else
        coreValTypeToZig(core_sig.results[0]);
    try w.print(") {s};\n", .{ret_ty});
}

fn emitFuncSigAndMeta(
    ar: Allocator,
    w: anytype,
    res: resolver_mod.Resolver,
    iface_items: []const ast.InterfaceItem,
    pkg: ast.PackageId,
    canonical_module: []const u8,
    is_export: bool,
    decl_prefix: []const u8,
    wit_func_name: []const u8,
    ast_func: ast.Func,
    decoded_sig: ctypes.FuncType,
    inst_decls: []const ctypes.Decl,
    world_decls: []const ctypes.Decl,
    opts: BindgenOptions,
    indent: []const u8,
) BindgenError!void {
    _ = res;
    _ = iface_items;
    _ = pkg;
    const raw_snake = try toRawSnakeCase(ar, wit_func_name);
    const fn_raw = if (decl_prefix.len > 0)
        try std.fmt.allocPrint(ar, "{s}{s}", .{ decl_prefix, raw_snake })
    else
        raw_snake;
    const ftr = abi.FuncTypeRef{
        .func = decoded_sig,
        .resolver = .{
            .inst_decls = inst_decls,
            .world_decls = world_decls,
        },
    };
    const cls = abi.classifyFunc(ftr);
    const lift_opts = abi.classifyFuncLift(ftr);
    const core_sig = if (is_export)
        try abi.liftCoreSigForArch(ar, ftr, opts.arch == .wasm64)
    else
        try abi.lowerCoreSigForArch(ar, ftr, opts.arch == .wasm64);

    // High-level Zig function type `<fn_raw>_Fn`.
    try w.print("{s}pub const {s}_Fn = fn (", .{ indent, fn_raw });
    for (ast_func.params, 0..) |p, idx| {
        if (idx > 0) try w.writeAll(", ");
        const p_ty = try formatWitType(ar, p.type);
        try w.writeAll(p_ty);
    }
    const ret_str = if (ast_func.result) |r|
        try formatWitType(ar, r)
    else
        try ar.dupe(u8, "void");
    try w.print(") {s};\n", .{ret_str});

    // Core Wasm function type `<fn_raw>_CoreFn` (`liftCoreSigForArch` for exports, `lowerCoreSigForArch` for imports).
    try w.print("{s}pub const {s}_CoreFn = fn (", .{ indent, fn_raw });
    for (core_sig.params, 0..) |pt, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.writeAll(coreValTypeToZig(pt));
    }
    const core_ret = if (core_sig.results.len == 0)
        "void"
    else
        coreValTypeToZig(core_sig.results[0]);
    try w.print(") callconv(.c) {s};\n", .{core_ret});

    const export_sym = if (std.mem.eql(u8, canonical_module, "$root"))
        wit_func_name
    else
        try std.fmt.allocPrint(ar, "{s}#{s}", .{ canonical_module, wit_func_name });

    try w.print(
        \\{s}pub const {s}_meta = .{{
        \\{s}    .wit_name = "{s}",
        \\{s}    .interface_name = "{s}",
        \\{s}    .export_name = "{s}",
        \\{s}    .is_export = {},
        \\{s}    .is_async = {},
        \\{s}    .params_flat = @as(u32, {d}),
        \\{s}    .results_flat = @as(u32, {d}),
        \\{s}    .has_result = {},
        \\{s}    .is_direct = {},
        \\
    , .{
        indent,
        fn_raw,
        indent,
        wit_func_name,
        indent,
        canonical_module,
        indent,
        export_sym,
        indent,
        is_export,
        indent,
        ast_func.is_async,
        indent,
        cls.params_flat,
        indent,
        cls.results_flat,
        indent,
        cls.has_result,
        indent,
        cls.class == .direct,
    });
    try w.print(
        \\{s}    .needs_memory = {},
        \\{s}    .needs_realloc = {},
        \\{s}    .string_encoding_utf8 = {},
        \\{s}    .lift_needs_memory = {},
        \\{s}    .lift_needs_realloc = {},
        \\{s}    .lift_needs_post_return = {},
        \\{s}}};
        \\
        \\
    , .{
        indent,
        cls.opts.memory,
        indent,
        cls.opts.realloc,
        indent,
        cls.opts.string_encoding,
        indent,
        lift_opts.memory,
        indent,
        lift_opts.realloc,
        indent,
        lift_opts.needs_post_return,
        indent,
    });
}

fn emitExportBindingsHelper(
    ar: Allocator,
    w: anytype,
    canonical_module: []const u8,
    items: []const ast.InterfaceItem,
    ext_funcs: []const metadata_decode.FuncRef,
    inst_decls: []const ctypes.Decl,
    world_decls: []const ctypes.Decl,
    import_collisions: std.StringHashMapUnmanaged(void),
    opts: BindgenOptions,
    indent: []const u8,
) BindgenError!void {
    try w.print("{s}pub fn exportBindings(comptime Impl: type) void {{\n", .{indent});
    var any_fn = false;
    for (items) |it| {
        if (it != .func) continue;
        const fref = findFuncRef(ext_funcs, it.func.name) orelse continue;
        any_fn = true;
        const raw_snake = try toRawSnakeCase(ar, it.func.name);
        const collides = import_collisions.contains(it.func.name);
        const decl_base = if (collides)
            try std.fmt.allocPrint(ar, "export_{s}", .{raw_snake})
        else
            raw_snake;
        const export_sym = if (canonical_module.len == 0 or std.mem.eql(u8, canonical_module, "$root"))
            it.func.name
        else
            try std.fmt.allocPrint(ar, "{s}#{s}", .{ canonical_module, it.func.name });

        const ftr = abi.FuncTypeRef{
            .func = fref.sig,
            .resolver = .{
                .inst_decls = inst_decls,
                .world_decls = world_decls,
            },
        };
        const core_sig = try abi.liftCoreSigForArch(ar, ftr, opts.arch == .wasm64);
        const core_ret = if (core_sig.results.len == 0)
            "void"
        else
            coreValTypeToZig(core_sig.results[0]);

        try w.print("{s}    if (@hasDecl(Impl, \"{s}\")) {{\n", .{ indent, raw_snake });
        try w.print("{s}        const _impl_fn = @field(Impl, \"{s}\");\n", .{ indent, raw_snake });
        try w.print("{s}        const _ImplT = @TypeOf(_impl_fn);\n", .{indent});
        try w.print("{s}        if (_ImplT == {s}_CoreFn) {{\n", .{ indent, decl_base });
        try w.print("{s}            @export(&_impl_fn, .{{ .name = \"{s}\" }});\n", .{ indent, export_sym });
        try w.print("{s}        }} else {{\n", .{indent});
        try w.print("{s}            const _Wrapper = struct {{\n", .{indent});
        try w.print("{s}                pub fn call(", .{indent});
        for (core_sig.params, 0..) |pt, idx| {
            if (idx > 0) try w.writeAll(", ");
            try w.print("p{d}: {s}", .{ idx, coreValTypeToZig(pt) });
        }
        try w.print(") callconv(.c) {s} {{\n", .{core_ret});
        try w.print("{s}                    if (comptime @hasDecl(Impl, \"canon\") and _ImplT == {s}_Fn) {{\n", .{ indent, decl_base });
        try w.print(
            "{s}                        const _thunk = Impl.canon.createLiftThunk({s}_Fn, .{{ .arch = if (is_wasm64) .wasm64 else .wasm32, .is_async = {s}_meta.is_async, .direction = .lift, .string_encoding_utf8 = {s}_meta.string_encoding_utf8 }}, &_impl_fn);\n",
            .{ indent, decl_base, decl_base, decl_base },
        );
        try w.print("{s}                        return _thunk(", .{indent});
        for (0..core_sig.params.len) |idx| {
            if (idx > 0) try w.writeAll(", ");
            try w.print("p{d}", .{idx});
        }
        try w.writeAll(");\n");
        try w.print("{s}                    }} else {{\n", .{indent});
        try w.print("{s}                        return @call(.auto, _impl_fn, .{{", .{indent});
        for (0..core_sig.params.len) |idx| {
            if (idx > 0) try w.writeAll(", ");
            try w.print("p{d}", .{idx});
        }
        try w.writeAll("});\n");
        try w.print("{s}                    }}\n", .{indent});
        try w.print("{s}                }}\n", .{indent});
        try w.print("{s}            }};\n", .{indent});
        try w.print("{s}            @export(&_Wrapper.call, .{{ .name = \"{s}\" }});\n", .{ indent, export_sym });
        try w.print("{s}        }}\n", .{indent});
        try w.print("{s}    }}\n", .{indent});
    }
    if (!any_fn) {
        try w.print("{s}    _ = Impl;\n", .{indent});
    }
    try w.print("{s}}}\n", .{indent});
}

// ── Type Formatting & C-ABI Layout Helpers ─────────────────────────────────

/// Format an `ast.Type` into its idiomatic Zig type expression.
pub fn formatWitType(ar: Allocator, t: ast.Type) Allocator.Error![]const u8 {
    return switch (t) {
        .bool => "bool",
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .s8 => "i8",
        .s16 => "i16",
        .s32 => "i32",
        .s64 => "i64",
        .f32 => "f32",
        .f64 => "f64",
        .char => "Char",
        .string => "[]const u8",
        .list => |elem| blk: {
            const elem_str = try formatWitType(ar, elem.*);
            break :blk try std.fmt.allocPrint(ar, "[]const {s}", .{elem_str});
        },
        .option => |inner| blk: {
            const inner_str = try formatWitType(ar, inner.*);
            break :blk try std.fmt.allocPrint(ar, "?{s}", .{inner_str});
        },
        .result => |r| blk: {
            const ok_str = if (r.ok) |ok_ty| try formatWitType(ar, ok_ty.*) else "void";
            const err_str = if (r.err) |err_ty| try formatWitType(ar, err_ty.*) else "void";
            break :blk try std.fmt.allocPrint(ar, "Result({s}, {s})", .{ ok_str, err_str });
        },
        .tuple => |elems| blk: {
            var all_extern = true;
            for (elems) |el| {
                if (!isSyntacticallyExternCompatible(el)) {
                    all_extern = false;
                    break;
                }
            }
            var buf: std.ArrayList(u8) = .empty;
            const bw = BufWriter{ .list = &buf, .alloc = ar };
            if (all_extern) {
                try bw.writeAll("extern struct { ");
            } else {
                try bw.writeAll("struct { ");
            }
            for (elems, 0..) |el, idx| {
                if (idx > 0) try bw.writeAll(", ");
                const el_str = try formatWitType(ar, el);
                try bw.print("@\"{d}\": {s}", .{ idx, el_str });
            }
            if (elems.len > 0) try bw.writeByte(' ');
            try bw.writeByte('}');
            break :blk try buf.toOwnedSlice(ar);
        },
        .future => |payload| blk: {
            const p_str = if (payload) |p| try formatWitType(ar, p.*) else "void";
            break :blk try std.fmt.allocPrint(ar, "Future({s})", .{p_str});
        },
        .stream => |payload| blk: {
            const p_str = if (payload) |p| try formatWitType(ar, p.*) else "void";
            break :blk try std.fmt.allocPrint(ar, "Stream({s})", .{p_str});
        },
        .error_context => "ErrorContext",
        .own => |res_name| blk: {
            const p_name = try toPascalCase(ar, res_name);
            break :blk try std.fmt.allocPrint(ar, "Own({s})", .{p_name});
        },
        .borrow => |res_name| blk: {
            const p_name = try toPascalCase(ar, res_name);
            break :blk try std.fmt.allocPrint(ar, "Borrow({s})", .{p_name});
        },
        .name => |n| try toPascalCase(ar, n),
    };
}

fn isSyntacticallyExternCompatible(t: ast.Type) bool {
    return switch (t) {
        .bool, .u8, .u16, .u32, .u64, .s8, .s16, .s32, .s64, .f32, .f64 => true,
        .own, .borrow, .future, .stream, .error_context => true,
        .tuple => |elems| blk: {
            for (elems) |el| {
                if (!isSyntacticallyExternCompatible(el)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Check whether a WIT `ast.Type` is transitively C-ABI `extern struct`
/// compatible in Zig.
pub fn isExternCompatible(
    res: resolver_mod.Resolver,
    iface_items: []const ast.InterfaceItem,
    pkg: ast.PackageId,
    t: ast.Type,
    depth: u32,
) bool {
    if (depth > 32) return false;
    return switch (t) {
        .bool, .u8, .u16, .u32, .u64, .s8, .s16, .s32, .s64, .f32, .f64 => true,
        .own, .borrow, .future, .stream, .error_context => true,
        .char, .string, .list, .option, .result => false,
        .tuple => isSyntacticallyExternCompatible(t),
        .name => |type_name| blk: {
            const resolved = resolveNamedTypeDef(res, iface_items, pkg, type_name, depth + 1) orelse
                break :blk false;
            break :blk switch (resolved.kind) {
                .alias => |inner| isExternCompatible(res, resolved.items, resolved.pkg, inner, depth + 1),
                .record => |fields| recordIsExternCompatible(res, resolved.items, resolved.pkg, fields, depth + 1),
                .@"enum", .flags => true,
                .variant, .resource => false,
            };
        },
    };
}

fn recordIsExternCompatible(
    res: resolver_mod.Resolver,
    iface_items: []const ast.InterfaceItem,
    pkg: ast.PackageId,
    fields: []const ast.Field,
    depth: u32,
) bool {
    for (fields) |f| {
        if (!isExternCompatible(res, iface_items, pkg, f.type, depth + 1)) return false;
    }
    return true;
}

const ResolvedNamedType = struct {
    kind: ast.TypeDefKind,
    items: []const ast.InterfaceItem,
    pkg: ast.PackageId,
};

fn resolveNamedTypeDef(
    res: resolver_mod.Resolver,
    iface_items: []const ast.InterfaceItem,
    pkg: ast.PackageId,
    name: []const u8,
    depth: u32,
) ?ResolvedNamedType {
    if (depth > 32) return null;
    for (iface_items) |it| {
        switch (it) {
            .type => |td| {
                if (std.mem.eql(u8, td.name, name)) {
                    return .{ .kind = td.kind, .items = iface_items, .pkg = pkg };
                }
            },
            .use => |u| {
                for (u.names) |un| {
                    const visible = un.rename orelse un.name;
                    if (std.mem.eql(u8, visible, name)) {
                        const hit = res.findInterfaceWithPkgCtx(u.from, pkg) orelse return null;
                        return resolveNamedTypeDef(res, hit.iface.items, hit.pkg, un.name, depth + 1);
                    }
                }
            },
            .func => {},
        }
    }
    return null;
}

fn formatCanonWireFieldType(
    ar: Allocator,
    res: resolver_mod.Resolver,
    iface_items: []const ast.InterfaceItem,
    pkg: ast.PackageId,
    t: ast.Type,
    opts: BindgenOptions,
) Allocator.Error![]const u8 {
    const ptr_int = if (opts.arch == .wasm64) "u64" else "u32";
    switch (t) {
        .string, .list => return std.fmt.allocPrint(ar, "CanonSlice({s})", .{ptr_int}),
        .char => return "u32",
        .name => |type_name| {
            if (resolveNamedTypeDef(res, iface_items, pkg, type_name, 0)) |resolved| {
                switch (resolved.kind) {
                    .alias => |inner| return formatCanonWireFieldType(ar, res, resolved.items, resolved.pkg, inner, opts),
                    .record => |fields| {
                        const p_name = try toPascalCase(ar, type_name);
                        if (recordIsExternCompatible(res, resolved.items, resolved.pkg, fields, 0)) {
                            return p_name;
                        }
                        return std.fmt.allocPrint(ar, "{s}.Canon", .{p_name});
                    },
                    .resource => {
                        const p_name = try toPascalCase(ar, type_name);
                        return std.fmt.allocPrint(ar, "Own({s})", .{p_name});
                    },
                    .@"enum", .flags => return toPascalCase(ar, type_name),
                    .variant => {},
                }
            }
        },
        else => {
            if (isExternCompatible(res, iface_items, pkg, t, 0)) {
                return formatWitType(ar, t);
            }
        },
    }

    const layout = canonSizeAlign(res, iface_items, pkg, t, opts.arch == .wasm64, 0);
    const word_ty = switch (layout.alignment) {
        1 => "u8",
        2 => "u16",
        4 => "u32",
        else => "u64",
    };
    const count = if (layout.alignment > 0) layout.size / layout.alignment else layout.size;
    return std.fmt.allocPrint(ar, "[{d}]{s}", .{ count, word_ty });
}

const SizeAlign = struct {
    size: u32,
    alignment: u32,
};

fn alignUp(offset: u32, alignment: u32) u32 {
    if (alignment <= 1) return offset;
    return (offset + alignment - 1) & ~(alignment - 1);
}

fn canonSizeAlign(
    res: resolver_mod.Resolver,
    iface_items: []const ast.InterfaceItem,
    pkg: ast.PackageId,
    t: ast.Type,
    is_wasm64: bool,
    depth: u32,
) SizeAlign {
    if (depth > 32) return .{ .size = 4, .alignment = 4 };
    const ptr_size: u32 = if (is_wasm64) 8 else 4;
    return switch (t) {
        .bool, .u8, .s8 => .{ .size = 1, .alignment = 1 },
        .u16, .s16 => .{ .size = 2, .alignment = 2 },
        .u32, .s32, .f32, .char, .own, .borrow, .future, .stream, .error_context => .{ .size = 4, .alignment = 4 },
        .u64, .s64, .f64 => .{ .size = 8, .alignment = 8 },
        .string, .list => .{ .size = ptr_size * 2, .alignment = ptr_size },
        .option => |inner| blk: {
            const p = canonSizeAlign(res, iface_items, pkg, inner.*, is_wasm64, depth + 1);
            const al = @max(@as(u32, 1), p.alignment);
            const sz = alignUp(alignUp(1, p.alignment) + p.size, al);
            break :blk .{ .size = sz, .alignment = al };
        },
        .result => |r| blk: {
            const ok_sa = if (r.ok) |ok_ty| canonSizeAlign(res, iface_items, pkg, ok_ty.*, is_wasm64, depth + 1) else SizeAlign{ .size = 0, .alignment = 1 };
            const err_sa = if (r.err) |err_ty| canonSizeAlign(res, iface_items, pkg, err_ty.*, is_wasm64, depth + 1) else SizeAlign{ .size = 0, .alignment = 1 };
            const max_p_size = @max(ok_sa.size, err_sa.size);
            const max_p_align = @max(ok_sa.alignment, err_sa.alignment);
            const al = @max(@as(u32, 1), max_p_align);
            const sz = alignUp(alignUp(1, max_p_align) + max_p_size, al);
            break :blk .{ .size = sz, .alignment = al };
        },
        .tuple => |elems| blk: {
            var sz: u32 = 0;
            var al: u32 = 1;
            for (elems) |el| {
                const el_sa = canonSizeAlign(res, iface_items, pkg, el, is_wasm64, depth + 1);
                sz = alignUp(sz, el_sa.alignment) + el_sa.size;
                al = @max(al, el_sa.alignment);
            }
            break :blk .{ .size = alignUp(sz, al), .alignment = al };
        },
        .name => |n| blk: {
            const resolved = resolveNamedTypeDef(res, iface_items, pkg, n, depth + 1) orelse
                break :blk .{ .size = 4, .alignment = 4 };
            break :blk switch (resolved.kind) {
                .alias => |inner| canonSizeAlign(res, resolved.items, resolved.pkg, inner, is_wasm64, depth + 1),
                .record => |fields| rec_blk: {
                    var sz: u32 = 0;
                    var al: u32 = 1;
                    for (fields) |f| {
                        const f_sa = canonSizeAlign(res, resolved.items, resolved.pkg, f.type, is_wasm64, depth + 1);
                        sz = alignUp(sz, f_sa.alignment) + f_sa.size;
                        al = @max(al, f_sa.alignment);
                    }
                    break :rec_blk .{ .size = alignUp(sz, al), .alignment = al };
                },
                .@"enum" => |cases| enumSizeAlign(cases.len),
                .flags => |flags| flagsSizeAlign(flags.len),
                .variant => |cases| var_blk: {
                    const disc_sa = enumSizeAlign(cases.len);
                    var max_p_size: u32 = 0;
                    var max_p_align: u32 = 1;
                    for (cases) |c| {
                        if (c.type) |ct| {
                            const c_sa = canonSizeAlign(res, resolved.items, resolved.pkg, ct, is_wasm64, depth + 1);
                            max_p_size = @max(max_p_size, c_sa.size);
                            max_p_align = @max(max_p_align, c_sa.alignment);
                        }
                    }
                    const al = @max(disc_sa.alignment, max_p_align);
                    const sz = alignUp(alignUp(disc_sa.size, max_p_align) + max_p_size, al);
                    break :var_blk .{ .size = sz, .alignment = al };
                },
                .resource => .{ .size = 4, .alignment = 4 },
            };
        },
    };
}

fn enumSizeAlign(num_cases: usize) SizeAlign {
    if (num_cases <= 256) return .{ .size = 1, .alignment = 1 };
    if (num_cases <= 65536) return .{ .size = 2, .alignment = 2 };
    return .{ .size = 4, .alignment = 4 };
}

fn flagsSizeAlign(num_flags: usize) SizeAlign {
    if (num_flags <= 8) return .{ .size = 1, .alignment = 1 };
    if (num_flags <= 16) return .{ .size = 2, .alignment = 2 };
    if (num_flags <= 32) return .{ .size = 4, .alignment = 4 };
    const words: u32 = @intCast((num_flags + 31) / 32);
    return .{ .size = words * 4, .alignment = 4 };
}

fn discBackingInt(num_cases: usize) []const u8 {
    if (num_cases <= 256) return "u8";
    if (num_cases <= 65536) return "u16";
    return "u32";
}

fn coreValTypeToZig(vt: wtypes.ValType) []const u8 {
    return switch (vt) {
        .i32 => "i32",
        .i64 => "i64",
        .f32 => "f32",
        .f64 => "f64",
        else => "i32",
    };
}

fn hasResources(items: []const ast.InterfaceItem) bool {
    for (items) |it| {
        if (it == .type and it.type.kind == .resource) return true;
    }
    return false;
}

fn findFuncRef(funcs: []const metadata_decode.FuncRef, name: []const u8) ?metadata_decode.FuncRef {
    for (funcs) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

fn formatQualifiedName(
    ar: Allocator,
    ns: []const u8,
    pkg: []const u8,
    item: []const u8,
    version: ?[]const u8,
) Allocator.Error![]const u8 {
    if (version) |v| {
        return std.fmt.allocPrint(ar, "{s}:{s}/{s}@{s}", .{ ns, pkg, item, v });
    }
    return std.fmt.allocPrint(ar, "{s}:{s}/{s}", .{ ns, pkg, item });
}

fn formatResourceMemberName(
    ar: Allocator,
    kind: ast.ResourceMethodKind,
    resource: []const u8,
    member: []const u8,
) Allocator.Error![]const u8 {
    return switch (kind) {
        .constructor => std.fmt.allocPrint(ar, "[constructor]{s}", .{resource}),
        .method => std.fmt.allocPrint(ar, "[method]{s}.{s}", .{ resource, member }),
        .static => std.fmt.allocPrint(ar, "[static]{s}.{s}", .{ resource, member }),
    };
}

fn sortInterfaceItems(ar: Allocator, items: []const ast.InterfaceItem) Allocator.Error![]const ast.InterfaceItem {
    var uses = std.ArrayList(ast.InterfaceItem).empty;
    var types = std.ArrayList(ast.InterfaceItem).empty;
    var funcs = std.ArrayList(ast.InterfaceItem).empty;
    for (items) |it| {
        switch (it) {
            .use => try uses.append(ar, it),
            .type => try types.append(ar, it),
            .func => try funcs.append(ar, it),
        }
    }

    var bound = std.StringHashMapUnmanaged(void).empty;
    for (uses.items) |u_it| for (u_it.use.names) |un| {
        const visible = un.rename orelse un.name;
        try bound.put(ar, visible, {});
    };

    var sorted_types = std.ArrayList(ast.InterfaceItem).empty;
    while (types.items.len > 0) {
        var made_progress = false;
        var i: usize = 0;
        while (i < types.items.len) {
            const t_item = types.items[i];
            const td = t_item.type;
            if (typeKindAllDepsBound(td.kind, bound, td.name)) {
                try sorted_types.append(ar, t_item);
                try bound.put(ar, td.name, {});
                _ = types.orderedRemove(i);
                made_progress = true;
            } else {
                i += 1;
            }
        }
        if (!made_progress) {
            try sorted_types.appendSlice(ar, types.items);
            break;
        }
    }

    var out = std.ArrayList(ast.InterfaceItem).empty;
    try out.appendSlice(ar, uses.items);
    try out.appendSlice(ar, sorted_types.items);
    try out.appendSlice(ar, funcs.items);
    return out.toOwnedSlice(ar);
}

fn typeKindAllDepsBound(
    kind: ast.TypeDefKind,
    bound: std.StringHashMapUnmanaged(void),
    self_name: []const u8,
) bool {
    return switch (kind) {
        .alias => |t| typeAllDepsBound(t, bound, self_name),
        .record => |fields| blk: {
            for (fields) |f| if (!typeAllDepsBound(f.type, bound, self_name)) break :blk false;
            break :blk true;
        },
        .variant => |cases| blk: {
            for (cases) |c| if (c.type) |t| if (!typeAllDepsBound(t, bound, self_name)) break :blk false;
            break :blk true;
        },
        .@"enum", .flags => true,
        .resource => |methods| blk: {
            for (methods) |m| {
                for (m.func.params) |p| if (!typeAllDepsBound(p.type, bound, self_name)) break :blk false;
                if (m.func.result) |r| if (!typeAllDepsBound(r, bound, self_name)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn typeAllDepsBound(t: ast.Type, bound: std.StringHashMapUnmanaged(void), self_name: []const u8) bool {
    return switch (t) {
        .bool, .u8, .u16, .u32, .u64, .s8, .s16, .s32, .s64, .f32, .f64, .char, .string, .error_context => true,
        .list, .option => |inner| typeAllDepsBound(inner.*, bound, self_name),
        .result => |r| blk: {
            if (r.ok) |t2| if (!typeAllDepsBound(t2.*, bound, self_name)) break :blk false;
            if (r.err) |t2| if (!typeAllDepsBound(t2.*, bound, self_name)) break :blk false;
            break :blk true;
        },
        .tuple => |ts| blk: {
            for (ts) |t2| if (!typeAllDepsBound(t2, bound, self_name)) break :blk false;
            break :blk true;
        },
        .future, .stream => |inner| if (inner) |p| typeAllDepsBound(p.*, bound, self_name) else true,
        .name, .borrow, .own => |n| (self_name.len > 0 and std.mem.eql(u8, n, self_name)) or bound.contains(n),
    };
}

// ── Unit Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn assertValidZigAst(allocator: Allocator, source: []const u8) !void {
    const z_source = try allocator.allocSentinel(u8, source.len, 0);
    defer allocator.free(z_source);
    @memcpy(z_source[0..source.len], source);
    var tree = try std.zig.Ast.parse(allocator, z_source, .{ .mode = .zig });
    defer tree.deinit(allocator);
    if (tree.errors.len > 0) {
        for (tree.errors) |err| {
            const loc = tree.tokenLocation(0, err.token);
            std.debug.print("AST error at line {d}, col {d}: {s}\n", .{ loc.line + 1, loc.column + 1, @tagName(err.tag) });
        }
        std.debug.print("Generated source:\n{s}\n", .{source});
    }
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "identifier naming conventions: toSnakeCase and toPascalCase" {
    const alloc = testing.allocator;

    {
        const s = try toSnakeCase(alloc, "get-arguments");
        defer alloc.free(s);
        try testing.expectEqualStrings("get_arguments", s);
    }
    {
        const s = try toSnakeCase(alloc, "monotonic-clock");
        defer alloc.free(s);
        try testing.expectEqualStrings("monotonic_clock", s);
    }
    {
        const s = try toSnakeCase(alloc, "%type");
        defer alloc.free(s);
        try testing.expectEqualStrings("@\"type\"", s);
    }
    {
        const s = try toSnakeCase(alloc, "error");
        defer alloc.free(s);
        try testing.expectEqualStrings("@\"error\"", s);
    }
    {
        const s = try toSnakeCase(alloc, "u32");
        defer alloc.free(s);
        try testing.expectEqualStrings("@\"u32\"", s);
    }
    {
        const p = try toPascalCase(alloc, "descriptor-type");
        defer alloc.free(p);
        try testing.expectEqualStrings("DescriptorType", p);
    }
    {
        const p = try toPascalCase(alloc, "error-code");
        defer alloc.free(p);
        try testing.expectEqualStrings("ErrorCode", p);
    }
    {
        const p = try toPascalCase(alloc, "input-stream");
        defer alloc.free(p);
        try testing.expectEqualStrings("InputStream", p);
    }
    {
        const p = try toPascalCase(alloc, "datetime");
        defer alloc.free(p);
        try testing.expectEqualStrings("Datetime", p);
    }
    {
        const p = try toPascalCase(alloc, "DNS-error-payload");
        defer alloc.free(p);
        try testing.expectEqualStrings("DnsErrorPayload", p);
    }
}

test "wasi-canon/0.3.0 worlds generate valid Zig ASTs" {
    const alloc = testing.allocator;
    const worlds = [_]struct {
        ns: []const u8,
        pkg: []const u8,
        world: []const u8,
        ver: []const u8,
    }{
        .{ .ns = "wasi", .pkg = "cli", .world = "command", .ver = "0.3.0" },
        .{ .ns = "wasi", .pkg = "cli", .world = "imports", .ver = "0.3.0" },
        .{ .ns = "wasi", .pkg = "clocks", .world = "imports", .ver = "0.3.0" },
        .{ .ns = "wasi", .pkg = "filesystem", .world = "imports", .ver = "0.3.0" },
        .{ .ns = "wasi", .pkg = "random", .world = "imports", .ver = "0.3.0" },
        .{ .ns = "wasi", .pkg = "http", .world = "service", .ver = "0.3.0" },
        .{ .ns = "wasi", .pkg = "sockets", .world = "imports", .ver = "0.3.0" },
    };

    for (worlds) |w| {
        const zig_src = try generateWasiWorld(alloc, w.ns, w.pkg, w.world, w.ver, .{});
        defer alloc.free(zig_src);
        try assertValidZigAst(alloc, zig_src);
    }

    // Verify specific declarations in `wasi:cli/command@0.3.0` and `wasi:http/service@0.3.0`.
    const cli_src = try generateWasiWorldBySpec(alloc, "wasi:cli/command@0.3.0", .{});
    defer alloc.free(cli_src);
    try testing.expect(std.mem.indexOf(u8, cli_src, "pub const environment = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, cli_src, "pub const get_arguments_Fn = fn () []const []const u8;") != null);
    try testing.expect(std.mem.indexOf(u8, cli_src, "pub const run = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, cli_src, "pub extern \"[export]wasi:cli/run@0.3.0\" fn @\"[task-return]run\"(p0: i32) void;") != null);
    try testing.expect(std.mem.indexOf(u8, cli_src, "pub fn exportBindings(comptime Impl: type) void") != null);

    const http_src = try generateWasiWorldBySpec(alloc, "wasi:http/service@0.3.0", .{});
    defer alloc.free(http_src);
    try testing.expect(std.mem.indexOf(u8, http_src, "pub const Fields = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, http_src, "pub const Request = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, http_src, "pub const Response = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, http_src, "pub const DnsErrorPayload = struct {") != null);
}

test "custom WIT world: extern record, slice-bearing record, variant, enum, flags, resources, P3 async, and >16 flat params spill" {
    const alloc = testing.allocator;
    const wit_src =
        \\package my:custom@0.1.0;
        \\
        \\interface shared {
        \\    enum color { red, green, blue }
        \\    flags perms { read, write, exec }
        \\    record point { x: f32, y: f32 }
        \\}
        \\
        \\interface api {
        \\    use shared.{color, perms, point};
        \\
        \\    record user-profile {
        \\        id: u64,
        \\        name: string,
        \\        tags: list<string>,
        \\        fav-color: color,
        \\        home: point,
        \\    }
        \\
        \\    variant event {
        \\        empty,
        \\        clicked(point),
        \\        renamed(string),
        \\        code(char),
        \\    }
        \\
        \\    resource session {
        \\        constructor(name: string);
        \\        get-id: func() -> u64;
        \\        connect: static async func(endpoint: string) -> result<session, error-context>;
        \\    }
        \\
        \\    transform: func(
        \\        p: point,
        \\        u: user-profile,
        \\        ev: event,
        \\        fl: perms,
        \\        opt: option<u32>,
        \\        tup: tuple<u32, u64>,
        \\        st: stream<u8>,
        \\        fut: future<result<u32, error-context>>,
        \\        own-sess: own<session>,
        \\        bor-sess: borrow<session>,
        \\    ) -> result<tuple<point, string>, error-context>;
        \\
        \\    spill-params: func(
        \\        a1: u32, a2: u32, a3: u32, a4: u32,
        \\        a5: u32, a6: u32, a7: u32, a8: u32,
        \\        a9: u32, a10: u32, a11: u32, a12: u32,
        \\        a13: u32, a14: u32, a15: u32, a16: u32,
        \\        a17: u32,
        \\    ) -> u32;
        \\}
        \\
        \\interface guest-export {
        \\    use shared.{point};
        \\    record stats { count: u32, origin: point }
        \\    compute: async func(input: stats) -> result<stats, string>;
        \\}
        \\
        \\world full-world {
        \\    import shared;
        \\    import api;
        \\    export guest-export;
        \\}
    ;

    // Test wasm32 generation
    const zig32 = try generateFromWitSource(alloc, wit_src, .{
        .world_name = "full-world",
        .arch = .wasm32,
    });
    defer alloc.free(zig32);
    try assertValidZigAst(alloc, zig32);

    // Verify extern struct vs slice-bearing struct + Canon wire struct
    try testing.expect(std.mem.indexOf(u8, zig32, "pub const Point = extern struct {") != null);
    try testing.expect(std.mem.indexOf(u8, zig32, "pub const UserProfile = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, zig32, "name: CanonSlice(u32),") != null);
    try testing.expect(std.mem.indexOf(u8, zig32, "pub const Perms = packed struct(u8) {") != null);
    try testing.expect(std.mem.indexOf(u8, zig32, "_padding: u5 = 0,") != null);
    try testing.expect(std.mem.indexOf(u8, zig32, "pub const Event = union(enum(u8)) {") != null);
    try testing.expect(std.mem.indexOf(u8, zig32, "pub const Session = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, zig32, "pub extern \"my:custom/api@0.1.0\" fn @\"[resource-drop]session\"(handle: i32) void;") != null);
    try testing.expect(std.mem.indexOf(u8, zig32, "pub extern \"my:custom/api@0.1.0\" fn @\"[constructor]session\"(p0: i32, p1: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, zig32, "pub extern \"my:custom/api@0.1.0\" fn @\"[method]session.get-id\"(p0: i32) i64;") != null);

    // >16 flat params spill to a single pointer in core signature: `fn @"spill-params"(p0: i32) i32;`
    try testing.expect(std.mem.indexOf(u8, zig32, "pub extern \"my:custom/api@0.1.0\" fn @\"spill-params\"(p0: i32) i32;") != null);

    // Verify lift_types.zig hoisting on guest-export (`stats` record + `result<stats, string>` = 2 defined types)
    try testing.expect(std.mem.indexOf(u8, zig32, "pub const transcribed_types_count: u32 = 2;") != null);

    // Test wasm64 generation
    const zig64 = try generateFromWitSource(alloc, wit_src, .{
        .world_name = "full-world",
        .arch = .wasm64,
    });
    defer alloc.free(zig64);
    try assertValidZigAst(alloc, zig64);
    try testing.expect(std.mem.indexOf(u8, zig64, "name: CanonSlice(u64),") != null);
    try testing.expect(std.mem.indexOf(u8, zig64, "pub extern \"my:custom/api@0.1.0\" fn @\"spill-params\"(p0: i64) i32;") != null);
}

test "flags edge cases (0 flags, 8 flags, >64 flags) and world-level functions" {
    const alloc = testing.allocator;
    const wit_src =
        \\package my:edge@0.1.0;
        \\
        \\interface flag-cases {
        \\    flags empty-flags {}
        \\    flags byte-flags { b0, b1, b2, b3, b4, b5, b6, b7 }
        \\    flags big-flags {
        \\        flag0, flag1, flag2, flag3, flag4, flag5, flag6, flag7,
        \\        flag8, flag9, flag10, flag11, flag12, flag13, flag14, flag15,
        \\        flag16, flag17, flag18, flag19, flag20, flag21, flag22, flag23,
        \\        flag24, flag25, flag26, flag27, flag28, flag29, flag30, flag31,
        \\        %f32, flag33, flag34, flag35, flag36, flag37, flag38, flag39,
        \\        flag40, flag41, flag42, flag43, flag44, flag45, flag46, flag47,
        \\        flag48, flag49, flag50, flag51, flag52, flag53, flag54, flag55,
        \\        flag56, flag57, flag58, flag59, flag60, flag61, flag62, flag63,
        \\        %f64,
        \\    }
        \\    check-flags: func(a: empty-flags, b: byte-flags, c: big-flags) -> big-flags;
        \\}
        \\
        \\world edge-world {
        \\    import flag-cases;
        \\    import host-log: func(msg: string);
        \\    export guest-add: func(x: s32, y: s32) -> s32;
        \\}
    ;

    const zig_src = try generateFromWitSource(alloc, wit_src, .{});
    defer alloc.free(zig_src);
    try assertValidZigAst(alloc, zig_src);

    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const EmptyFlags = packed struct(u8) {") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const wit_flags_count: u32 = 0;") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const ByteFlags = packed struct(u8) {") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const wit_flags_count: u32 = 8;") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "words: [3]u32 = @splat(0),") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const wit_flags_count: u32 = 65;") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub extern \"$root\" fn @\"host-log\"(p0: i32, p1: i32) void;") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const guest_add_Fn = fn (i32, i32) i32;") != null);
}

test "export liftCoreSig, no raw extern on exports, world import/export collision, 33..64 flags, and world scoping" {
    const alloc = testing.allocator;
    const wit_src =
        \\package my:review@0.1.0;
        \\
        \\interface exp {
        \\    flags flags40 {
        \\        f0, f1, f2, f3, f4, f5, f6, f7,
        \\        f8, f9, f10, f11, f12, f13, f14, f15,
        \\        f16, f17, f18, f19, f20, f21, f22, f23,
        \\        f24, f25, f26, f27, f28, f29, f30, f31,
        \\        %f32, f33, f34, f35, f36, f37, f38, f39,
        \\    }
        \\    get-pair: func(a: u32) -> tuple<u32, u32>;
        \\    async-five: async func(a: u32, b: u32, c: u32, d: u32, e: u32) -> tuple<u32, u32>;
        \\}
        \\
        \\world other-world {
        \\    export ping: func(x: string) -> string;
        \\}
        \\
        \\world target-world {
        \\    export exp;
        \\    import ping: func(a: u32) -> u32;
        \\    export ping: func(a: u32, b: u32) -> tuple<u32, u32>;
        \\}
    ;

    const zig_src = try generateFromWitSource(alloc, wit_src, .{ .world_name = "target-world" });
    defer alloc.free(zig_src);
    try assertValidZigAst(alloc, zig_src);

    // N8: 33..64 flags emitted as extern struct with words: [2]u32, Packed, toPacked, fromPacked
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const Flags40 = extern struct {") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "words: [2]u32 = @splat(0),") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub fn toPacked(self: @This()) Packed") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub fn fromPacked(p: Packed) @This()") != null);

    // B1 & N9: Exported interface uses liftCoreSig (sync >1 flat result returns i32, async 5 params -> void)
    // and omits raw `pub extern` declarations on exported functions.
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const get_pair_CoreFn = fn (i32) callconv(.c) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const async_five_CoreFn = fn (i32, i32, i32, i32, i32) callconv(.c) void;") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub extern \"my:review/exp@0.1.0\" fn @\"get-pair\"") == null);

    // B1 & N7: World-level import/export collision disambiguated as import_ping_* and export_ping_*,
    // and `export ping` uses `target-world`'s AST signature (not `other-world`'s string signature!).
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const import_ping_Fn = fn (u32) u32;") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const export_ping_Fn = fn (u32, u32) extern struct { @\"0\": u32, @\"1\": u32 };") != null);
    try testing.expect(std.mem.indexOf(u8, zig_src, "pub const export_ping_CoreFn = fn (i32, i32) callconv(.c) i32;") != null);
}


