//! WebAssembly Component Model library for Zig's Wasm linker (`wasm32-wasip2`).
//!
//! Vendored from `cataggar/wabt` (`src/component/` and `src/tools/component_new.zig`),
//! licensed under the Apache License, Version 2.0 (see `NOTICE`).
//!
//! Provides an in-process, purely in-memory (`[]const u8` -> `[]u8`) pipeline for:
//! - Encoding WIT worlds (including bundled `wasi-canon/` 0.2.x packages) into
//!   `component-type:<world>` custom section payloads (`encodeWorldFromSource`)
//!   and splicing them onto core `.wasm` modules (`embed`, `embedWorldFromSource`).
//! - Wrapping core `.wasm` modules importing `wasi:*` directly (or via preview1)
//!   into WASI 0.2 components (`buildComponent`).
//! - Splicing preview1->preview2 adapter modules with core `.wasm` modules
//!   (`splice`, `spliceMany`, `wasi_preview1_command_wasm`, `wasi_preview1_reactor_wasm`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Feature = @import("Feature.zig");
pub const Opcode = @import("Opcode.zig");
pub const leb128 = @import("leb128.zig");
pub const core_types = @import("core_types.zig");
pub const Module = @import("Module.zig").Module;
pub const binary = struct {
    pub const instr = @import("binary/instr.zig");
    pub const reader = @import("binary/reader.zig");
    pub const writer = @import("binary/writer.zig");
};

pub const types = @import("types.zig");
pub const writer = @import("writer.zig");
pub const loader = @import("loader.zig");
pub const compose = @import("compose.zig");
pub const extern_name = @import("extern_name.zig");
pub const rewrite_extern_names = @import("rewrite_extern_names.zig");
pub const resource_intrinsics = @import("resource_intrinsics.zig");
pub const type_walk = @import("type_walk.zig");
pub const build_component = @import("build_component.zig");
pub const Optimizer = @import("Optimizer.zig");
pub const optimizeCoreModule = Optimizer.optimize;

pub const wit = struct {
    pub const ast = @import("wit/ast.zig");
    pub const lexer = @import("wit/lexer.zig");
    pub const parser = @import("wit/parser.zig");
    pub const embed = @import("wit/embed.zig");
    pub const lift_types = @import("wit/lift_types.zig");
    pub const metadata_decode = @import("wit/metadata_decode.zig");
    pub const metadata_encode = @import("wit/metadata_encode.zig");
    pub const resolver = @import("wit/resolver.zig");
    pub const wasi_canon = @import("wit/wasi_canon.zig");
};

pub const adapter = struct {
    pub const abi = @import("adapter/abi.zig");
    pub const adapter = @import("adapter/adapter.zig");
    pub const core_imports = @import("adapter/core_imports.zig");
    pub const decode = @import("adapter/decode.zig");
    pub const fixup = @import("adapter/fixup.zig");
    pub const gc = @import("adapter/gc.zig");
    pub const shim = @import("adapter/shim.zig");
    pub const stack_init = @import("adapter/stack_init.zig");
    pub const types_import = @import("adapter/types_import.zig");
    pub const world_gc = @import("adapter/world_gc.zig");

    pub const splice = @This().adapter.splice;
    pub const spliceMany = @This().adapter.spliceMany;
    pub const AdapterSpec = @This().adapter.AdapterSpec;
    pub const SplicedComponent = @This().adapter.SplicedComponent;
    pub const SplicerError = @This().adapter.SplicerError;
    pub const wasi_preview1_command_wasm = build_component.builtin_adapter.wasi_preview1_command_wasm;
    pub const wasi_preview1_reactor_wasm = build_component.builtin_adapter.wasi_preview1_reactor_wasm;
};

// ── Top-level post-link API ────────────────────────────────────────────────

pub const encodeWorldFromSource = wit.metadata_encode.encodeWorldFromSource;
pub const encodeWorld = wit.metadata_encode.encodeWorld;
pub const encodeWorldFromResolver = wit.metadata_encode.encodeWorldFromResolver;
pub const encodeWorldFromResolverWithDiag = wit.metadata_encode.encodeWorldFromResolverWithDiag;
pub const embedCustomSection = wit.embed.embedCustomSection;

pub const buildComponent = build_component.buildComponent;
pub const coreImportsModule = build_component.coreImportsModule;
pub const probeStartExport = build_component.probeStartExport;
pub const pickBuiltinAdapter = build_component.pickBuiltinAdapter;
pub const StartExportProbe = build_component.StartExportProbe;
pub const builtin_adapter = build_component.builtin_adapter;

pub const splice = adapter.adapter.splice;
pub const spliceMany = adapter.adapter.spliceMany;
pub const AdapterSpec = adapter.adapter.AdapterSpec;
pub const SplicedComponent = adapter.adapter.SplicedComponent;
pub const SplicerError = adapter.adapter.SplicerError;

pub const wasi_preview1_command_wasm: []const u8 = build_component.builtin_adapter.wasi_preview1_command_wasm;
pub const wasi_preview1_reactor_wasm: []const u8 = build_component.builtin_adapter.wasi_preview1_reactor_wasm;

pub const wasi_canon = wit.wasi_canon;

/// Canonical bundled WIT sources for standard WASI 0.2 and 0.3 worlds.
pub const bundled_wit = struct {
    pub const cli_command_0_2_6: []const u8 = @embedFile("wit/wasi-canon/0.2.6/cli/command.wit");
    pub const cli_command_0_2_12: []const u8 = @embedFile("wit/wasi-canon/0.2.12/cli/command.wit");
    pub const cli_command_0_3_0: []const u8 = @embedFile("wit/wasi-canon/0.3.0/cli/command.wit");
    pub const cli_imports_0_2_6: []const u8 = @embedFile("wit/wasi-canon/0.2.6/cli/imports.wit");
    pub const cli_imports_0_2_12: []const u8 = @embedFile("wit/wasi-canon/0.2.12/cli/imports.wit");
    pub const cli_imports_0_3_0: []const u8 = @embedFile("wit/wasi-canon/0.3.0/cli/imports.wit");
    pub const http_proxy_0_2_6: []const u8 = @embedFile("wit/wasi-canon/0.2.6/http/proxy.wit");
    pub const http_proxy_0_2_12: []const u8 = @embedFile("wit/wasi-canon/0.2.12/http/proxy.wit");
    pub const http_worlds_0_3_0: []const u8 = @embedFile("wit/wasi-canon/0.3.0/http/worlds.wit");
    pub const cli_command: []const u8 = cli_command_0_2_6;
    pub const cli_imports: []const u8 = cli_imports_0_2_6;
    pub const http_proxy: []const u8 = http_proxy_0_2_6;
};

pub const WasiVersion = enum { p2, p3 };

pub const LinkComponentOptions = struct {
    exec_model: std.builtin.WasiExecModel = .command,
    wasi_version: WasiVersion = .p2,
    wit_source: ?[]const u8 = null,
    wit_world: ?[]const u8 = null,
    custom_adapter_bytes: ?[]const u8 = null,
};

/// Encode `world_name` from `wit_source` (resolving against bundled `wasi-canon/`
/// packages when needed) and append the `component-type:<world>` custom section
/// onto `core_wasm`. Caller owns the returned slice.
pub fn embedWorldFromSource(
    allocator: Allocator,
    core_wasm: []const u8,
    wit_source: []const u8,
    world_name: []const u8,
) ![]u8 {
    const payload = try encodeWorldFromSource(allocator, wit_source, world_name);
    defer allocator.free(payload);
    const short_name = shortWorldName(world_name);
    const section_name = try std.fmt.allocPrint(allocator, "component-type:{s}", .{short_name});
    defer allocator.free(section_name);
    return embedCustomSection(allocator, core_wasm, section_name, payload);
}

fn shortWorldName(world_name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, world_name, '/')) |slash|
        if (std.mem.indexOfScalar(u8, world_name[slash + 1 ..], '@')) |at|
            world_name[slash + 1 ..][0..at]
        else
            world_name[slash + 1 ..]
    else
        world_name;
}

fn selectWorldNameFromSource(
    arena: Allocator,
    wit_source: []const u8,
    requested_world: ?[]const u8,
    exec_model: std.builtin.WasiExecModel,
) ![]const u8 {
    if (requested_world) |w| return w;
    const doc = wit.parser.parse(arena, wit_source, null) catch return switch (exec_model) {
        .command => "command",
        .reactor => "imports",
    };
    var first_world: ?[]const u8 = null;
    const preferred = switch (exec_model) {
        .command => "command",
        .reactor => "reactor",
    };
    for (doc.items) |item| {
        switch (item) {
            .world => |w| {
                if (first_world == null) first_world = w.name;
                if (std.mem.eql(u8, w.name, preferred)) return w.name;
            },
            else => {},
        }
    }
    return first_world orelse switch (exec_model) {
        .command => "command",
        .reactor => "imports",
    };
}

fn appendUniqueString(arena: Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(arena, value);
}

fn extractResourceName(field_name: []const u8) ?[]const u8 {
    if (field_name.len == 0 or field_name[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, field_name, ']') orelse return null;
    const tag = field_name[1..close];
    const rest = field_name[close + 1 ..];
    if (std.mem.eql(u8, tag, "method") or std.mem.eql(u8, tag, "static")) {
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
        return rest[0..dot];
    }
    if (std.mem.eql(u8, tag, "constructor") or
        std.mem.eql(u8, tag, "resource-drop") or
        std.mem.eql(u8, tag, "resource-new") or
        std.mem.eql(u8, tag, "resource-rep"))
    {
        return if (rest.len > 0) rest else null;
    }
    return null;
}

fn parseAsyncChannelFuncRef(module_name: []const u8) ?struct { iface: []const u8, func_name: []const u8 } {
    const spec = if (std.mem.startsWith(u8, module_name, "[stream]"))
        module_name["[stream]".len..]
    else if (std.mem.startsWith(u8, module_name, "[future]"))
        module_name["[future]".len..]
    else
        return null;
    const h1 = std.mem.indexOfScalar(u8, spec, '#') orelse return null;
    const tail = spec[h1 + 1 ..];
    const h2 = std.mem.lastIndexOfScalar(u8, tail, '#') orelse return null;
    if (h1 == 0 or h2 == 0) return null;
    return .{
        .iface = spec[0..h1],
        .func_name = tail[0..h2],
    };
}

fn collectLiveMethodsForCore(
    arena: Allocator,
    core_iface: *const adapter.core_imports.CoreInterface,
) !struct {
    namespaces: []const []const u8,
    methods_by_namespace: []const adapter.world_gc.LiveMethodSet,
} {
    var ns_list: std.ArrayList([]const u8) = .empty;
    var sets: std.ArrayList(adapter.world_gc.LiveMethodSet) = .empty;

    for (core_iface.imports) |imp| {
        if (std.mem.eql(u8, imp.module_name, "env") or
            std.mem.eql(u8, imp.module_name, "__main_module__") or
            std.mem.eql(u8, imp.module_name, "wasi_snapshot_preview1"))
        {
            continue;
        }
        if (std.mem.startsWith(u8, imp.module_name, "[")) {
            if (parseAsyncChannelFuncRef(imp.module_name)) |ref| {
                try appendUniqueString(arena, &ns_list, ref.iface);
            }
            continue;
        }
        try appendUniqueString(arena, &ns_list, imp.module_name);
    }

    for (ns_list.items) |ns| {
        var methods: std.ArrayList([]const u8) = .empty;
        var type_exports: std.ArrayList([]const u8) = .empty;

        for (core_iface.imports) |imp| {
            if (std.mem.startsWith(u8, imp.module_name, "[")) {
                if (parseAsyncChannelFuncRef(imp.module_name)) |ref| {
                    if (std.mem.eql(u8, ref.iface, ns)) {
                        try appendUniqueString(arena, &methods, ref.func_name);
                        if (extractResourceName(ref.func_name)) |rname| {
                            try appendUniqueString(arena, &type_exports, rname);
                        }
                    }
                }
                continue;
            }
            if (!std.mem.eql(u8, imp.module_name, ns)) continue;
            const canonical_field = if (std.mem.startsWith(u8, imp.field_name, "[async-lower]"))
                imp.field_name["[async-lower]".len..]
            else
                imp.field_name;
            try appendUniqueString(arena, &methods, canonical_field);
            if (extractResourceName(canonical_field)) |rname| {
                try appendUniqueString(arena, &type_exports, rname);
            }
        }

        try sets.append(arena, .{
            .namespace = ns,
            .methods = try methods.toOwnedSlice(arena),
            .type_exports = try type_exports.toOwnedSlice(arena),
        });
    }

    if (sets.items.len == 0) {
        // Provide a dummy entry so `world_gc.gcWorld` runs `pruneInstanceBodies`
        // rather than falling back to legacy no-method-filter mode.
        try sets.append(arena, .{
            .namespace = "",
            .methods = &.{},
            .type_exports = &.{},
        });
    }

    return .{
        .namespaces = try ns_list.toOwnedSlice(arena),
        .methods_by_namespace = try sets.toOwnedSlice(arena),
    };
}

fn parseQualifiedInterfaceRef(qualified: []const u8) ?wit.ast.InterfaceRef {
    const slash = std.mem.indexOfScalar(u8, qualified, '/') orelse return null;
    const pkg_part = qualified[0..slash];
    const colon = std.mem.indexOfScalar(u8, pkg_part, ':') orelse return null;
    const ns = pkg_part[0..colon];
    const pkg_name = pkg_part[colon + 1 ..];
    const rest = qualified[slash + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        return .{
            .package = .{ .namespace = ns, .name = pkg_name, .version = rest[at + 1 ..] },
            .name = rest[0..at],
        };
    }
    return .{
        .package = .{ .namespace = ns, .name = pkg_name, .version = null },
        .name = rest,
    };
}

fn encodeWorldForCore(
    arena: Allocator,
    wit_source: []const u8,
    world_name: []const u8,
    core_iface: *const adapter.core_imports.CoreInterface,
) ![]u8 {
    var wasi_imports: std.ArrayList([]const u8) = .empty;
    for (core_iface.imports) |imp| {
        if (std.mem.startsWith(u8, imp.module_name, "wasi:")) {
            try appendUniqueString(arena, &wasi_imports, imp.module_name);
        } else if (parseAsyncChannelFuncRef(imp.module_name)) |ref| {
            if (std.mem.startsWith(u8, ref.iface, "wasi:")) {
                var is_exported_iface = false;
                for (core_iface.exports) |exp| {
                    if (exp.kind == .func and std.mem.startsWith(u8, exp.name, ref.iface) and
                        exp.name.len > ref.iface.len and exp.name[ref.iface.len] == '#')
                    {
                        is_exported_iface = true;
                        break;
                    }
                }
                if (!is_exported_iface) {
                    try appendUniqueString(arena, &wasi_imports, ref.iface);
                }
            }
        }
    }
    if (wasi_imports.items.len == 0) {
        return encodeWorldFromSource(arena, wit_source, world_name);
    }

    const doc = wit.parser.parse(arena, wit_source, null) catch {
        return encodeWorldFromSource(arena, wit_source, world_name);
    };
    const short_target = shortWorldName(world_name);
    var found_world_idx: ?usize = null;
    for (doc.items, 0..) |item, i| {
        if (item == .world and
            (std.mem.eql(u8, item.world.name, world_name) or
                std.mem.eql(u8, item.world.name, short_target)))
        {
            found_world_idx = i;
            break;
        }
    }
    const world_idx = found_world_idx orelse {
        return encodeWorldFromSource(arena, wit_source, world_name);
    };

    const orig_world = doc.items[world_idx].world;
    var new_world_items: std.ArrayList(wit.ast.WorldItem) = .empty;

    var added_any = false;
    for (wasi_imports.items) |mod_name| {
        const qref = parseQualifiedInterfaceRef(mod_name) orelse continue;
        try new_world_items.append(arena, .{
            .import = .{ .interface_ref = .{ .ref = qref } },
        });
        added_any = true;
    }
    if (!added_any) {
        return encodeWorldFromSource(arena, wit_source, world_name);
    }

    try new_world_items.appendSlice(arena, orig_world.items);

    const mutable_items = try arena.dupe(wit.ast.TopLevelItem, doc.items);
    mutable_items[world_idx] = .{
        .world = .{
            .docs = orig_world.docs,
            .name = orig_world.name,
            .items = try new_world_items.toOwnedSlice(arena),
        },
    };
    const augmented_doc: wit.ast.Document = .{
        .package = doc.package,
        .items = mutable_items,
    };
    const resolver = wit.resolver.finishWithEmbedded(arena, augmented_doc, &.{}) catch {
        return encodeWorldFromSource(arena, wit_source, world_name);
    };
    return encodeWorldFromResolver(arena, resolver, world_name) catch {
        return encodeWorldFromSource(arena, wit_source, world_name);
    };
}

fn pruneEncodedWorldForCore(
    arena: Allocator,
    raw_payload: []const u8,
    core_iface: *const adapter.core_imports.CoreInterface,
) []const u8 {
    const pristine_world = adapter.decode.parse(arena, raw_payload) catch return raw_payload;

    var live_export_names: std.ArrayList([]const u8) = .empty;
    for (pristine_world.exports) |exp_entry| {
        live_export_names.append(arena, exp_entry.name) catch return raw_payload;
    }

    const live = collectLiveMethodsForCore(arena, core_iface) catch return raw_payload;
    const gc_res = adapter.world_gc.gcWorld(
        arena,
        pristine_world,
        live.namespaces,
        live.methods_by_namespace,
        live_export_names.items,
    ) catch return raw_payload;
    return gc_res.payload_bytes;
}

/// High-level post-link entry point for Zig's Wasm linker (`wasm32-wasip2`).
/// Takes a linked core WebAssembly module (`\x00asm\x01\x00\x00\x00`) and wraps
/// it into a WebAssembly Component (`\x00asm\x0d\x00\x01\x00`) using either:
/// - The preview1->preview2 adapter splice pipeline (`splice`) when the module
///   imports `wasi_snapshot_preview1`, a custom adapter is supplied, or a
///   command module only exports preview1 `_start`; or
/// - The zero-adapter native WASI 0.2 component builder (`buildComponent`) with
///   automatic WIT world embedding and unused-import pruning (`world_gc`).
/// Caller owns the returned slice (allocated with `gpa`).
pub fn linkComponent(
    gpa: Allocator,
    core_wasm: []const u8,
    opts: LinkComponentOptions,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();

    var core_owned = try adapter.core_imports.extract(gpa, core_wasm);
    defer core_owned.deinit();
    const core_iface = &core_owned.interface;

    var imports_preview1 = false;
    var imports_other = false;
    var imports_p3 = false;
    for (core_iface.imports) |imp| {
        if (std.mem.eql(u8, imp.module_name, "wasi_snapshot_preview1")) {
            imports_preview1 = true;
        } else if (!std.mem.eql(u8, imp.module_name, "env") and
            !std.mem.eql(u8, imp.module_name, "__main_module__"))
        {
            imports_other = true;
            if (std.mem.indexOf(u8, imp.module_name, "@0.3.") != null) {
                imports_p3 = true;
            }
        }
    }

    var exports_wasi_run = false;
    var exports_wasi_run_p3 = false;
    var exports_start = false;
    for (core_iface.exports) |exp| {
        if (exp.kind != .func) continue;
        if (std.mem.startsWith(u8, exp.name, "wasi:cli/run@")) {
            exports_wasi_run = true;
            if (std.mem.startsWith(u8, exp.name, "wasi:cli/run@0.3.")) {
                exports_wasi_run_p3 = true;
            }
        } else if (std.mem.eql(u8, exp.name, "_start")) {
            exports_start = true;
        }
    }

    const is_p3 = (opts.wasi_version == .p3) or exports_wasi_run_p3 or imports_p3;

    const existing_meta = try wit.metadata_decode.extractFromCoreWasm(core_wasm);
    const has_embedded_world = (existing_meta != null);

    const use_adapter_splice = (opts.custom_adapter_bytes != null) or
        imports_preview1 or
        (!is_p3 and
            opts.exec_model == .command and
            opts.wit_source == null and
            opts.wit_world == null and
            !has_embedded_world and
            !exports_wasi_run and
            exports_start);

    var working_core: []const u8 = core_wasm;
    const needs_embedded_world = !has_embedded_world and
        !(use_adapter_splice and opts.wit_source == null and opts.wit_world == null and !imports_other);

    if (needs_embedded_world) {
        const wit_src: []const u8, const world_name: []const u8 = if (opts.wit_source) |src| .{
            src,
            try selectWorldNameFromSource(ar, src, opts.wit_world, opts.exec_model),
        } else if (opts.wit_world) |w| blk: {
            const world_is_p3 = is_p3 or std.mem.indexOf(u8, w, "0.3.") != null;
            if (std.mem.indexOf(u8, w, "proxy") != null or
                std.mem.indexOf(u8, w, "http") != null or
                std.mem.indexOf(u8, w, "service") != null or
                std.mem.indexOf(u8, w, "middleware") != null)
            {
                if (world_is_p3 or std.mem.indexOf(u8, w, "service") != null or std.mem.indexOf(u8, w, "middleware") != null) {
                    const effective_w = if (std.mem.eql(u8, w, "proxy") or std.mem.eql(u8, w, "http")) "service" else w;
                    break :blk .{ bundled_wit.http_worlds_0_3_0, effective_w };
                }
                break :blk .{ bundled_wit.http_proxy, w };
            } else if (std.mem.eql(u8, w, "imports") or std.mem.startsWith(u8, w, "wasi:cli/imports")) {
                break :blk .{ if (world_is_p3) bundled_wit.cli_imports_0_3_0 else bundled_wit.cli_imports, w };
            } else {
                break :blk .{ if (world_is_p3) bundled_wit.cli_command_0_3_0 else bundled_wit.cli_command, w };
            }
        } else switch (opts.exec_model) {
            .command => .{ if (is_p3) bundled_wit.cli_command_0_3_0 else bundled_wit.cli_command, "command" },
            .reactor => .{ if (is_p3) bundled_wit.cli_imports_0_3_0 else bundled_wit.cli_imports, "imports" },
        };

        const raw_payload = try encodeWorldForCore(ar, wit_src, world_name, core_iface);
        const final_payload = pruneEncodedWorldForCore(ar, raw_payload, core_iface);
        const section_name = try std.fmt.allocPrint(ar, "component-type:{s}", .{shortWorldName(world_name)});
        working_core = try embedCustomSection(ar, core_wasm, section_name, final_payload);
    }

    if (use_adapter_splice) {
        const adapter_bytes = opts.custom_adapter_bytes orelse switch (opts.exec_model) {
            .command => wasi_preview1_command_wasm,
            .reactor => wasi_preview1_reactor_wasm,
        };
        return splice(gpa, working_core, adapter_bytes, "wasi_snapshot_preview1");
    }

    return buildComponent(gpa, working_core);
}

test {
    _ = Feature;
    _ = Opcode;
    _ = leb128;
    _ = core_types;
    _ = Module;
    _ = binary.instr;
    _ = binary.reader;
    _ = binary.writer;
    _ = types;
    _ = writer;
    _ = loader;
    _ = compose;
    _ = extern_name;
    _ = rewrite_extern_names;
    _ = resource_intrinsics;
    _ = type_walk;
    _ = build_component;
    _ = Optimizer;
    _ = wit.ast;
    _ = wit.lexer;
    _ = wit.parser;
    _ = wit.embed;
    _ = wit.lift_types;
    _ = wit.metadata_decode;
    _ = wit.metadata_encode;
    _ = wit.resolver;
    _ = wit.wasi_canon;
    _ = adapter.abi;
    _ = adapter.adapter;
    _ = adapter.core_imports;
    _ = adapter.decode;
    _ = adapter.fixup;
    _ = adapter.gc;
    _ = adapter.shim;
    _ = adapter.stack_init;
    _ = adapter.types_import;
    _ = adapter.world_gc;
}

test "encodeWorldFromSource: bundled wasi:cli/command and wasi:http/proxy worlds (cataggar/wabt#234)" {
    const testing = std.testing;

    // 1. Encode bundled `wasi:cli/command` (both short and qualified world names).
    const cli_payload = try encodeWorldFromSource(
        testing.allocator,
        bundled_wit.cli_command,
        "command",
    );
    defer testing.allocator.free(cli_payload);
    try testing.expect(cli_payload.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", cli_payload[0..8]);

    var cli_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer cli_arena.deinit();
    const cli_meta = try wit.metadata_decode.decode(cli_arena.allocator(), cli_payload);
    try testing.expect(cli_meta.externs.len >= 2);

    const cli_qual_payload = try encodeWorldFromSource(
        testing.allocator,
        bundled_wit.cli_command,
        "wasi:cli/command",
    );
    defer testing.allocator.free(cli_qual_payload);
    try testing.expectEqualSlices(u8, cli_payload, cli_qual_payload);

    // 2. Encode bundled `wasi:http/proxy` and a custom world importing
    // `wasi:http/outgoing-handler` (cataggar/wabt#234 regression check).
    const http_payload = try encodeWorldFromSource(
        testing.allocator,
        bundled_wit.http_proxy,
        "proxy",
    );
    defer testing.allocator.free(http_payload);
    try testing.expect(http_payload.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", http_payload[0..8]);

    var http_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer http_arena.deinit();
    const http_meta = try wit.metadata_decode.decode(http_arena.allocator(), http_payload);
    try testing.expect(http_meta.externs.len >= 2);

    const http_client_wit =
        \\package test:http-client@0.1.0;
        \\
        \\world client {
        \\  import wasi:http/types@0.2.6;
        \\  import wasi:http/outgoing-handler@0.2.6;
        \\}
    ;
    const client_payload = try encodeWorldFromSource(
        testing.allocator,
        http_client_wit,
        "client",
    );
    defer testing.allocator.free(client_payload);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", client_payload[0..8]);
}

test "buildComponent: round-trip core wasm with embedded WIT metadata into component binary" {
    const testing = std.testing;

    const wit_src =
        \\package docs:adder@0.1.0;
        \\
        \\interface add {
        \\  add: func(x: u32, y: u32) -> u32;
        \\}
        \\
        \\world adder {
        \\  export add;
        \\}
    ;

    // Minimal core module exporting `docs:adder/add@0.1.0#add` ((i32, i32) -> i32).
    const core_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 28,   0x01,
        24,   'd',  'o',  'c',  's',  ':',  'a',  'd',
        'd',  'e',  'r',  '/',  'a',  'd',  'd',  '@',
        '0',  '.',  '1',  '.',  '0',  '#',  'a',  'd',
        'd',  0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00,
        0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
    };

    const embedded_core = try embedWorldFromSource(
        testing.allocator,
        &core_bytes,
        wit_src,
        "adder",
    );
    defer testing.allocator.free(embedded_core);

    const comp_bytes = try buildComponent(testing.allocator, embedded_core);
    defer testing.allocator.free(comp_bytes);

    try testing.expect(comp_bytes.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", comp_bytes[0..8]);

    var loaded_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer loaded_arena.deinit();
    const loaded = try loader.load(comp_bytes, loaded_arena.allocator());
    try testing.expect(loaded.core_modules.len >= 1);
}

test "adapter.splice: wrap preview1 core module into a component" {
    const testing = std.testing;

    // Minimal preview1 command core module importing
    // `wasi_snapshot_preview1.proc_exit` (i32) -> () and exporting
    // `memory` + `_start` () -> ().
    const main_bytes = [_]u8{
        // preamble
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: 2 types: 0 = (i32) -> (), 1 = () -> ()
        0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60,
        0x00, 0x00,
        // import section: 1 import: wasi_snapshot_preview1.proc_exit (func type 0)
        0x02, 36,   0x01, 22,   'w',  'a',
        's',  'i',  '_',  's',  'n',  'a',  'p',  's',
        'h',  'o',  't',  '_',  'p',  'r',  'e',  'v',
        'i',  'e',  'w',  '1',  9,    'p',  'r',  'o',
        'c',  '_',  'e',  'x',  'i',  't',  0x00, 0x00,
        // function section: 1 defined func (type 1)
        0x03, 0x02, 0x01, 0x01,
        // memory section: 1 memory (min 1 page)
        0x05, 0x03, 0x01, 0x00,
        0x01,
        // export section: 2 exports: "memory" (mem 0), "_start" (func 1)
        0x07, 19,   0x02, 6,    'm',  'e',  'm',
        'o',  'r',  'y',  0x02, 0x00, 6,    '_',  's',
        't',  'a',  'r',  't',  0x00, 0x01,
        // code section: 1 body: i32.const 0; call 0; end
        0x0a, 0x08,
        0x01, 0x06, 0x00, 0x41, 0x00, 0x10, 0x00, 0x0b,
    };

    const spliced = try splice(
        testing.allocator,
        &main_bytes,
        wasi_preview1_command_wasm,
        "wasi_snapshot_preview1",
    );
    defer testing.allocator.free(spliced);
    try testing.expect(spliced.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", spliced[0..8]);
}

test "linkComponent: pure P2 command, custom WIT reactor, and preview1 fallback" {
    const testing = std.testing;

    // 1. Pure P2 command core module exporting `wasi:cli/run@0.2.6#run` (() -> i32) with zero imports.
    const pure_p2_core = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: () -> i32
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        // function section: 1 func (type 0)
        0x03,
        0x02, 0x01, 0x00,
        // memory section: 1 memory (min 1 page)
        0x05, 0x03, 0x01, 0x00, 0x01,
        // export section: "memory" (mem 0) + "wasi:cli/run@0.2.6#run" (func 0)
        0x07, 35,   0x02, 6,    'm',  'e',  'm',  'o',
        'r',  'y',  0x02, 0x00, 22,   'w',  'a',  's',
        'i',  ':',  'c',  'l',  'i',  '/',  'r',  'u',
        'n',  '@',  '0',  '.',  '2',  '.',  '6',  '#',
        'r',  'u',  'n',  0x00, 0x00,
        // code section: i32.const 0; end
        0x0a, 0x06, 0x01,
        0x04, 0x00, 0x41, 0x00, 0x0b,
    };

    const p2_comp = try linkComponent(testing.allocator, &pure_p2_core, .{
        .exec_model = .command,
    });
    defer testing.allocator.free(p2_comp);
    try testing.expect(p2_comp.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", p2_comp[0..8]);
    var p2_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer p2_arena.deinit();
    const p2_loaded = try loader.load(p2_comp, p2_arena.allocator());
    try testing.expectEqual(@as(usize, 0), p2_loaded.imports.len);
    try testing.expectEqual(@as(usize, 1), p2_loaded.exports.len);

    // 2. Custom WIT reactor (`docs:adder/adder@0.1.0`) without explicit world name.
    const wit_src =
        \\package docs:adder@0.1.0;
        \\
        \\interface add {
        \\  add: func(x: u32, y: u32) -> u32;
        \\}
        \\
        \\world adder {
        \\  export add;
        \\}
    ;
    const adder_core = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 28,   0x01,
        24,   'd',  'o',  'c',  's',  ':',  'a',  'd',
        'd',  'e',  'r',  '/',  'a',  'd',  'd',  '@',
        '0',  '.',  '1',  '.',  '0',  '#',  'a',  'd',
        'd',  0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00,
        0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
    };
    const adder_comp = try linkComponent(testing.allocator, &adder_core, .{
        .exec_model = .reactor,
        .wit_source = wit_src,
    });
    defer testing.allocator.free(adder_comp);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", adder_comp[0..8]);

    // 3. Custom WIT world with top-level `export add: func(a: s32, b: s32) -> s32;`
    //    where the core module also imports `wasi:io/poll@0.2.6#[resource-drop]pollable`
    //    (e.g. from Zig's Debug panic handler). Exercises `encodeWorldForCore`
    //    auto-importing `wasi:*` interfaces into custom worlds.
    const top_func_wit =
        \\package example:math@0.1.0;
        \\
        \\world adder {
        \\  export add: func(a: s32, b: s32) -> s32;
        \\}
    ;
    const top_func_core = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: 2 types: 0 = (i32) -> (), 1 = (i32, i32) -> i32
        0x01, 0x0b, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60,
        0x02, 0x7f, 0x7f, 0x01, 0x7f,
        // import section: 1 import: "wasi:io/poll@0.2.6" "[resource-drop]pollable" (func type 0)
        0x02, 46,   0x01,
        18,   'w',  'a',  's',  'i',  ':',  'i',  'o',
        '/',  'p',  'o',  'l',  'l',  '@',  '0',  '.',
        '2',  '.',  '6',  23,   '[',  'r',  'e',  's',
        'o',  'u',  'r',  'c',  'e',  '-',  'd',  'r',
        'o',  'p',  ']',  'p',  'o',  'l',  'l',  'a',
        'b',  'l',  'e',  0x00, 0x00,
        // function section: 1 defined func (type 1)
        0x03, 0x02, 0x01,
        0x01,
        // memory section: 1 memory (min 1 page)
        0x05, 0x03, 0x01, 0x00, 0x01,
        // export section: "memory" (mem 0) + "add" (func 1)
        0x07, 16,
        0x02, 6,    'm',  'e',  'm',  'o',  'r',  'y',
        0x02, 0x00, 3,    'a',  'd',  'd',  0x00, 0x01,
        // code section: local.get 0; local.get 1; i32.add; end
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20,
        0x01, 0x6a, 0x0b,
    };
    const top_func_comp = try linkComponent(testing.allocator, &top_func_core, .{
        .exec_model = .reactor,
        .wit_source = top_func_wit,
        .wit_world = "adder",
    });
    defer testing.allocator.free(top_func_comp);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", top_func_comp[0..8]);

    // 4. Preview1 command fallback via `linkComponent`.
    const p1_core = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60,
        0x00, 0x00, 0x02, 36,   0x01, 22,   'w',  'a',
        's',  'i',  '_',  's',  'n',  'a',  'p',  's',
        'h',  'o',  't',  '_',  'p',  'r',  'e',  'v',
        'i',  'e',  'w',  '1',  9,    'p',  'r',  'o',
        'c',  '_',  'e',  'x',  'i',  't',  0x00, 0x00,
        0x03, 0x02, 0x01, 0x01, 0x05, 0x03, 0x01, 0x00,
        0x01, 0x07, 19,   0x02, 6,    'm',  'e',  'm',
        'o',  'r',  'y',  0x02, 0x00, 6,    '_',  's',
        't',  'a',  'r',  't',  0x00, 0x01, 0x0a, 0x08,
        0x01, 0x06, 0x00, 0x41, 0x00, 0x10, 0x00, 0x0b,
    };
    const p1_comp = try linkComponent(testing.allocator, &p1_core, .{
        .exec_model = .command,
    });
    defer testing.allocator.free(p1_comp);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", p1_comp[0..8]);
}

test "WASI 0.3.0: encodeWorldFromSource and linkComponent P3 command" {
    const testing = std.testing;

    // 1. Encode bundled `wasi:cli/command@0.3.0` (both short and qualified world names).
    const cli_p3_payload = try encodeWorldFromSource(
        testing.allocator,
        bundled_wit.cli_command_0_3_0,
        "command",
    );
    defer testing.allocator.free(cli_p3_payload);
    try testing.expect(cli_p3_payload.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", cli_p3_payload[0..8]);

    var cli_p3_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer cli_p3_arena.deinit();
    const cli_p3_meta = try wit.metadata_decode.decode(cli_p3_arena.allocator(), cli_p3_payload);
    try testing.expect(cli_p3_meta.externs.len >= 2);

    const cli_p3_qual_payload = try encodeWorldFromSource(
        testing.allocator,
        bundled_wit.cli_command_0_3_0,
        "wasi:cli/command",
    );
    defer testing.allocator.free(cli_p3_qual_payload);
    try testing.expectEqualSlices(u8, cli_p3_payload, cli_p3_qual_payload);

    // 2. Minimal P3 command core module importing
    // `"[export]wasi:cli/run@0.3.0" "[task-return]run"` ((i32) -> ()) and
    // exporting `"memory"` (mem 0) + `"wasi:cli/run@0.3.0#run"` (() -> ()).
    const pure_p3_core = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: 2 types: 0 = (i32) -> (), 1 = () -> ()
        0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60,
        0x00, 0x00,
        // import section: 1 import: "[export]wasi:cli/run@0.3.0" "[task-return]run" (func type 0)
        0x02, 47,   0x01, 26,   '[',  'e',
        'x',  'p',  'o',  'r',  't',  ']',  'w',  'a',
        's',  'i',  ':',  'c',  'l',  'i',  '/',  'r',
        'u',  'n',  '@',  '0',  '.',  '3',  '.',  '0',
        16,   '[',  't',  'a',  's',  'k',  '-',  'r',
        'e',  't',  'u',  'r',  'n',  ']',  'r',  'u',
        'n',  0x00, 0x00,
        // function section: 1 defined func (type 1)
        0x03, 0x02, 0x01, 0x01,
        // memory section: 1 memory (min 1 page)
        0x05,
        0x03, 0x01, 0x00, 0x01,
        // export section: "memory" (mem 0) + "wasi:cli/run@0.3.0#run" (func 1)
        0x07, 35,   0x02, 6,
        'm',  'e',  'm',  'o',  'r',  'y',  0x02, 0x00,
        22,   'w',  'a',  's',  'i',  ':',  'c',  'l',
        'i',  '/',  'r',  'u',  'n',  '@',  '0',  '.',
        '3',  '.',  '0',  '#',  'r',  'u',  'n',  0x00,
        0x01,
        // code section: i32.const 0; call 0; end
        0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x00,
        0x10, 0x00, 0x0b,
    };

    const p3_comp = try linkComponent(testing.allocator, &pure_p3_core, .{
        .wasi_version = .p3,
        .exec_model = .command,
    });
    defer testing.allocator.free(p3_comp);
    try testing.expect(p3_comp.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", p3_comp[0..8]);

    var p3_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer p3_arena.deinit();
    const p3_loaded = try loader.load(p3_comp, p3_arena.allocator());
    try testing.expectEqual(@as(usize, 0), p3_loaded.imports.len);
    try testing.expectEqual(@as(usize, 1), p3_loaded.exports.len);
}

test "WASI 0.3.0: custom WIT async world with record/variant/result, multi-task-return, and MAX_FLAT_ASYNC_PARAMS spill" {
    const testing = std.testing;

    const custom_wit =
        \\package example:custom-p3@0.1.0;
        \\
        \\interface host-ops {
        \\  record point {
        \\    x: s32,
        \\    y: s32,
        \\  }
        \\  variant op {
        \\    translate(point),
        \\    scale(s32),
        \\    negate,
        \\  }
        \\  async-combine6: async func(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32) -> u32;
        \\}
        \\
        \\interface calc {
        \\  use host-ops.{point, op};
        \\  sync-add: func(a: u32, b: u32) -> u32;
        \\  async-add: async func(a: u32, b: u32) -> u32;
        \\  async-eval: async func(p: point, action: op) -> result<point, s32>;
        \\  async-sum17: async func(
        \\    p1: u32, p2: u32, p3: u32, p4: u32,
        \\    p5: u32, p6: u32, p7: u32, p8: u32,
        \\    p9: u32, p10: u32, p11: u32, p12: u32,
        \\    p13: u32, p14: u32, p15: u32, p16: u32,
        \\    p17: u32
        \\  ) -> u32;
        \\}
        \\
        \\world custom-p3 {
        \\  export calc;
        \\  import host-ops;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // Build a synthetic core module that imports:
    //   - "example:custom-p3/host-ops@0.1.0" "[async-lower]async-combine6": (i32) -> i32
    //   - "[export]example:custom-p3/calc@0.1.0" "[task-return]async-add": (i32) -> ()
    //   - "[export]example:custom-p3/calc@0.1.0" "[task-return]async-eval": (i32, i32, i32) -> ()
    //   - "[export]example:custom-p3/calc@0.1.0" "[task-return]async-sum17": (i32) -> ()
    // and exports:
    //   - "memory", "cabi_realloc"
    //   - "example:custom-p3/calc@0.1.0#sync-add": (i32, i32) -> i32
    //   - "example:custom-p3/calc@0.1.0#async-add": (i32, i32) -> i32
    //   - "example:custom-p3/calc@0.1.0#async-eval": (i32, i32, i32, i32, i32) -> i32
    //   - "example:custom-p3/calc@0.1.0#async-sum17": (i32) -> i32
    const H = struct {
        fn appendU32(a: Allocator, buf: *std.ArrayList(u8), v: u32) !void {
            var val = v;
            while (true) {
                var byte: u8 = @intCast(val & 0x7f);
                val >>= 7;
                if (val != 0) byte |= 0x80;
                try buf.append(a, byte);
                if (val == 0) break;
            }
        }
        fn appendStr(a: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
            try appendU32(a, buf, @intCast(s.len));
            try buf.appendSlice(a, s);
        }
        fn appendSec(a: Allocator, out: *std.ArrayList(u8), id: u8, body: []const u8) !void {
            try out.append(a, id);
            try appendU32(a, out, @intCast(body.len));
            try out.appendSlice(a, body);
        }
    };

    var core = std.ArrayList(u8).empty;
    try core.appendSlice(ar, "\x00asm\x01\x00\x00\x00");

    // Section 1: Type section (6 func types)
    {
        var sec = std.ArrayList(u8).empty;
        try sec.appendSlice(ar, &.{
            6,
            0x60, 1, 0x7f, 1, 0x7f, // 0: (i32) -> i32
            0x60, 1, 0x7f, 0, // 1: (i32) -> ()
            0x60, 3, 0x7f, 0x7f, 0x7f, 0, // 2: (i32, i32, i32) -> ()
            0x60, 4, 0x7f, 0x7f, 0x7f, 0x7f, 1, 0x7f, // 3: (i32x4) -> i32
            0x60, 2, 0x7f, 0x7f, 1, 0x7f, // 4: (i32, i32) -> i32
            0x60, 5, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 1, 0x7f, // 5: (i32x5) -> i32
        });
        try H.appendSec(ar, &core, 1, sec.items);
    }

    // Section 2: Import section (4 func imports)
    {
        var sec = std.ArrayList(u8).empty;
        try H.appendU32(ar, &sec, 4);
        const imps = [_]struct { m: []const u8, f: []const u8, ty: u8 }{
            .{ .m = "example:custom-p3/host-ops@0.1.0", .f = "[async-lower]async-combine6", .ty = 4 },
            .{ .m = "[export]example:custom-p3/calc@0.1.0", .f = "[task-return]async-add", .ty = 1 },
            .{ .m = "[export]example:custom-p3/calc@0.1.0", .f = "[task-return]async-eval", .ty = 2 },
            .{ .m = "[export]example:custom-p3/calc@0.1.0", .f = "[task-return]async-sum17", .ty = 1 },
        };
        for (imps) |im| {
            try H.appendStr(ar, &sec, im.m);
            try H.appendStr(ar, &sec, im.f);
            try sec.appendSlice(ar, &.{ 0x00, im.ty });
        }
        try H.appendSec(ar, &core, 2, sec.items);
    }

    // Section 3: Function section (5 defined funcs: indices 4..8)
    try H.appendSec(ar, &core, 3, &.{ 5, 3, 4, 4, 5, 0 });

    // Section 5: Memory section (1 memory, min 1 page)
    try H.appendSec(ar, &core, 5, &.{ 1, 0x00, 1 });

    // Section 7: Export section
    {
        var sec = std.ArrayList(u8).empty;
        try H.appendU32(ar, &sec, 6);
        try H.appendStr(ar, &sec, "memory");
        try sec.appendSlice(ar, &.{ 0x02, 0 });
        const exps = [_]struct { n: []const u8, idx: u8 }{
            .{ .n = "cabi_realloc", .idx = 4 },
            .{ .n = "example:custom-p3/calc@0.1.0#sync-add", .idx = 5 },
            .{ .n = "example:custom-p3/calc@0.1.0#async-add", .idx = 6 },
            .{ .n = "example:custom-p3/calc@0.1.0#async-eval", .idx = 7 },
            .{ .n = "example:custom-p3/calc@0.1.0#async-sum17", .idx = 8 },
        };
        for (exps) |ex| {
            try H.appendStr(ar, &sec, ex.n);
            try sec.appendSlice(ar, &.{ 0x00, ex.idx });
        }
        try H.appendSec(ar, &core, 7, sec.items);
    }

    // Section 10: Code section (5 bodies returning 0)
    {
        var sec = std.ArrayList(u8).empty;
        try H.appendU32(ar, &sec, 5);
        for (0..5) |_| {
            try sec.appendSlice(ar, &.{ 4, 0, 0x41, 0x00, 0x0b });
        }
        try H.appendSec(ar, &core, 10, sec.items);
    }

    const comp_bytes = try linkComponent(testing.allocator, core.items, .{
        .wasi_version = .p3,
        .exec_model = .reactor,
        .wit_source = custom_wit,
        .wit_world = "custom-p3",
    });
    defer testing.allocator.free(comp_bytes);

    try testing.expect(comp_bytes.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", comp_bytes[0..8]);

    const loaded = try loader.load(comp_bytes, ar);
    try testing.expectEqual(@as(usize, 1), loaded.imports.len);
    try testing.expectEqualStrings("example:custom-p3/host-ops@0.1.0", loaded.imports[0].name);
    try testing.expectEqual(@as(usize, 1), loaded.exports.len);
    try testing.expectEqualStrings("example:custom-p3/calc@0.1.0", loaded.exports[0].name);
}

test "optimizeCoreModule + linkComponent: prunes dead stubs and folds constants in WASI P2 component" {
    const testing = std.testing;

    // Core P2 command module with 6 dead `(func unreachable)` stubs (indices 0..5)
    // and exported `wasi:cli/run@0.2.6#run` at index 6 containing foldable constants:
    // `(i32.sub (i32.add (i32.const 10) (i32.const 20)) (i32.const 30))` -> `i32.const 0`.
    const unopt_core = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: 2 types: 0 = () -> (), 1 = () -> i32
        0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x00,
        0x01, 0x7f,
        // function section: 7 funcs (types 0x6, 1)
        0x03, 0x08, 0x07, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01,
        // memory section: 1 memory (min 1 page)
        0x05, 0x03, 0x01, 0x00,
        0x01,
        // export section: "memory" (mem 0) + "wasi:cli/run@0.2.6#run" (func 6)
        0x07, 35,   0x02, 6,    'm',  'e',  'm',
        'o',  'r',  'y',  0x02, 0x00, 22,   'w',  'a',
        's',  'i',  ':',  'c',  'l',  'i',  '/',  'r',
        'u',  'n',  '@',  '0',  '.',  '2',  '.',  '6',
        '#',  'r',  'u',  'n',  0x00, 0x06,
        // code section: 6 dead unreachable bodies + 1 foldable body
        0x0a, 36,
        0x07,
        0x03, 0x00, 0x00, 0x0b, // func 0: unreachable; end
        0x03, 0x00, 0x00, 0x0b, // func 1: unreachable; end
        0x03, 0x00, 0x00, 0x0b, // func 2: unreachable; end
        0x03, 0x00, 0x00, 0x0b, // func 3: unreachable; end
        0x03, 0x00, 0x00, 0x0b, // func 4: unreachable; end
        0x03, 0x00, 0x00, 0x0b, // func 5: unreachable; end
        0x0a, 0x00, 0x41, 10,
        0x41, 20,   0x6a, 0x41,
        30, 0x6b, 0x0b, // func 6: (10 + 20) - 30
    };

    const unopt_comp = try linkComponent(testing.allocator, &unopt_core, .{
        .exec_model = .command,
    });
    defer testing.allocator.free(unopt_comp);

    const opt_core = try optimizeCoreModule(testing.allocator, &unopt_core, .{
        .custom_sections = .preserve,
    });
    defer testing.allocator.free(opt_core);
    try testing.expect(opt_core.len < unopt_core.len);

    var opt_mod = try binary.reader.readModule(testing.allocator, opt_core);
    defer opt_mod.deinit();
    try testing.expectEqual(@as(usize, 1), opt_mod.funcs.items.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x00, 0x0b }, opt_mod.funcs.items[0].code_bytes);

    const opt_comp = try linkComponent(testing.allocator, opt_core, .{
        .exec_model = .command,
    });
    defer testing.allocator.free(opt_comp);

    try testing.expect(opt_comp.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm\x0d\x00\x01\x00", opt_comp[0..8]);
    try testing.expect(opt_comp.len < unopt_comp.len);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(opt_comp, arena.allocator());
    try testing.expectEqual(@as(usize, 0), loaded.imports.len);
    try testing.expectEqual(@as(usize, 1), loaded.exports.len);
}
