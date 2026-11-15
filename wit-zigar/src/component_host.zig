//! WebAssembly Component Model host instance unpacker, resource handle table,
//! and cross-memory Canonical ABI host invoker (`ComponentHost`).
//!
//! Enables Zig programs — both native Zig (`ts-zigar` CLI, `zig build test`,
//! `node-zigar`) and WASM-compiled Zig running under Node.js 26 / V8
//! (`zigar-compiler`) — to instantiate and invoke WebAssembly Components
//! (including `componentize-go` WASI P1 reactor components such as
//! `typescript-compiler.component.wasm`) across separate linear memories.

const std = @import("std");
const builtin = @import("builtin");

const loader = @import("component/loader.zig");
const ctypes = @import("component/types.zig");
const leb128 = @import("component/leb128.zig");
pub const canon = @import("canon.zig");

pub const has_process_support = builtin.os.tag != .freestanding and
    builtin.os.tag != .wasi and
    builtin.cpu.arch != .wasm32 and
    builtin.cpu.arch != .wasm64;

// ── Errors & Core Flat Values ───────────────────────────────────────────────

pub const HostError = canon.Error || error{
    InvalidComponent,
    ExportNotFound,
    CoreExportNotFound,
    PostReturnNotFound,
    InvalidResourceHandle,
    DoubleDropResource,
    ResourceTypeMismatch,
    BackendCallFailed,
    BackendIoError,
    EndOfStream,
    HandshakeFailed,
    UnsupportedAsyncHostCall,
};

pub fn HostCallResult(comptime FnType: type) type {
    const RetT = canon.ReturnType(FnType);
    return switch (@typeInfo(RetT)) {
        .error_union => |eu| (HostError || eu.error_set)!eu.payload,
        .error_set => (HostError || RetT)!void,
        else => HostError!RetT,
    };
}

pub const CoreValTag = enum(u8) {
    void = 0,
    i32 = 1,
    i64 = 2,
    f32 = 3,
    f64 = 4,

    pub fn fromFlatValType(ft: ?canon.FlatValType) CoreValTag {
        const v = ft orelse return .void;
        return switch (v) {
            .i32 => .i32,
            .i64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
        };
    }
};

pub const CoreVal = union(CoreValTag) {
    void: void,
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,

    pub fn fromZigFlat(comptime ft: canon.FlatValType, v: canon.ToZigType(ft)) CoreVal {
        return switch (ft) {
            .i32 => .{ .i32 = v },
            .i64 => .{ .i64 = v },
            .f32 => .{ .f32 = v },
            .f64 => .{ .f64 = v },
        };
    }

    pub fn toZigFlat(self: CoreVal, comptime ft: canon.FlatValType) HostError!canon.ToZigType(ft) {
        return switch (ft) {
            .i32 => switch (self) {
                .i32 => |v| v,
                .i64 => |v| @bitCast(@as(u32, @truncate(@as(u64, @bitCast(v))))),
                else => error.BackendCallFailed,
            },
            .i64 => switch (self) {
                .i64 => |v| v,
                .i32 => |v| @intCast(@as(u32, @bitCast(v))),
                else => error.BackendCallFailed,
            },
            .f32 => switch (self) {
                .f32 => |v| v,
                .i32 => |v| @bitCast(v),
                else => error.BackendCallFailed,
            },
            .f64 => switch (self) {
                .f64 => |v| v,
                .i64 => |v| @bitCast(v),
                else => error.BackendCallFailed,
            },
        };
    }

    pub fn toRawBits(self: CoreVal) u64 {
        return switch (self) {
            .void => 0,
            .i32 => |v| @as(u32, @bitCast(v)),
            .i64 => |v| @bitCast(v),
            .f32 => |v| @as(u32, @bitCast(v)),
            .f64 => |v| @bitCast(v),
        };
    }

    pub fn fromTagAndBits(tag: CoreValTag, bits: u64) CoreVal {
        return switch (tag) {
            .void => .{ .void = {} },
            .i32 => .{ .i32 = @bitCast(@as(u32, @truncate(bits))) },
            .i64 => .{ .i64 = @bitCast(bits) },
            .f32 => .{ .f32 = @bitCast(@as(u32, @truncate(bits))) },
            .f64 => .{ .f64 = @bitCast(bits) },
        };
    }
};

// ── Component Unpacker & Instantiation Plan ─────────────────────────────────

pub const ResourceIntrinsicKind = enum {
    resource_new,
    resource_rep,
    resource_drop,
};

pub const CoreExportRef = struct {
    core_instance_idx: u32,
    export_name: []const u8,
};

pub const SyntheticCoreExport = union(enum) {
    core_ref: struct {
        name: []const u8,
        sort: ctypes.CoreSort,
        target_core_instance_idx: ?u32 = null,
        target_export_name: []const u8 = "",
    },
    resource_intrinsic: struct {
        name: []const u8,
        kind: ResourceIntrinsicKind,
        resource_type_idx: u32,
    },
    lowered_import: struct {
        name: []const u8,
        comp_func_idx: u32,
    },
};

pub const CoreInstancePlan = union(enum) {
    instantiate: struct {
        module_idx: u32,
        args: []const ctypes.CoreInstantiateArg,
    },
    synthetic_exports: []const SyntheticCoreExport,
};

pub const ResourcePlan = struct {
    type_idx: u32,
    interface_name: []const u8,
    resource_name: []const u8,
    dtor_core_instance_idx: ?u32,
    dtor_export_name: ?[]const u8,
};

pub const CanonicalExport = struct {
    /// Full canonical symbol (`<iface>#<func>` for interface exports, `<func>` for world-level exports).
    canonical_name: []const u8,
    /// Exported WIT interface name (empty `""` for top-level world functions).
    interface_name: []const u8,
    /// WIT function or resource method name (e.g. `compiler-version`, `[constructor]vfs`, `[method]vfs.write-file`).
    func_name: []const u8,
    core_instance_idx: u32,
    core_module_idx: ?u32,
    core_export_name: []const u8,
    memory_export: ?CoreExportRef,
    realloc_export: ?CoreExportRef,
    post_return_export: ?CoreExportRef,
    string_encoding: ctypes.StringEncoding = .utf8,
    is_async: bool = false,
};

pub const PlanOptions = struct {
    /// If true, copies embedded core `.wasm` module slices into the plan's arena
    /// so the input `wasm_bytes` buffer can be freed immediately.
    copy_module_bytes: bool = false,
    /// Enforce strict Component Model binary section validation.
    strict: bool = true,
};

/// Deterministic instantiation & canonical export plan extracted from a `.component.wasm` binary.
pub const ComponentPlan = struct {
    arena: std.heap.ArenaAllocator,
    core_modules: []const []const u8,
    core_instances: []const CoreInstancePlan,
    primary_core_module_idx: ?u32,
    primary_core_instance_idx: ?u32,
    wasi_imports_needed: bool,
    resources: []const ResourcePlan,
    exports: []const CanonicalExport,
    export_by_canonical: std.StringHashMapUnmanaged(usize),

    pub fn deinit(self: *ComponentPlan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn fromBytes(
        backing_allocator: std.mem.Allocator,
        wasm_bytes: []const u8,
    ) (loader.LoadError || HostError)!ComponentPlan {
        return fromBytesWithOptions(backing_allocator, wasm_bytes, .{});
    }

    pub fn fromBytesWithOptions(
        backing_allocator: std.mem.Allocator,
        wasm_bytes: []const u8,
        opts: PlanOptions,
    ) (loader.LoadError || HostError)!ComponentPlan {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const ar = arena.allocator();

        const comp = if (opts.strict)
            try loader.loadStrictVerbatim(wasm_bytes, ar)
        else
            try loader.loadVerbatim(wasm_bytes, ar);

        var plan = try buildFromComponent(ar, &comp, opts);
        plan.arena = arena;
        return plan;
    }

    pub fn findExport(self: *const ComponentPlan, canonical_or_export_name: []const u8) ?CanonicalExport {
        if (self.export_by_canonical.get(canonical_or_export_name)) |idx| {
            return self.exports[idx];
        }
        for (self.exports) |exp| {
            if (std.mem.eql(u8, exp.core_export_name, canonical_or_export_name)) {
                return exp;
            }
        }
        return null;
    }

    pub fn findInterfaceExport(
        self: *const ComponentPlan,
        interface_name: []const u8,
        func_name: []const u8,
    ) ?CanonicalExport {
        for (self.exports) |exp| {
            if (std.mem.eql(u8, exp.interface_name, interface_name) and
                std.mem.eql(u8, exp.func_name, func_name))
            {
                return exp;
            }
        }
        // Fallback: match unversioned interface prefix (`pkg:ns/iface` against `pkg:ns/iface@ver`)
        for (self.exports) |exp| {
            if (interfaceMatchesPrefix(exp.interface_name, interface_name) and
                std.mem.eql(u8, exp.func_name, func_name))
            {
                return exp;
            }
        }
        return null;
    }

    pub fn findResource(
        self: *const ComponentPlan,
        interface_name: []const u8,
        resource_name: []const u8,
    ) ?ResourcePlan {
        for (self.resources) |res| {
            if (std.mem.eql(u8, res.resource_name, resource_name)) {
                if (interface_name.len == 0 or
                    std.mem.eql(u8, res.interface_name, interface_name) or
                    interfaceMatchesPrefix(res.interface_name, interface_name))
                {
                    return res;
                }
            }
        }
        return null;
    }
};

fn interfaceMatchesPrefix(have: []const u8, want: []const u8) bool {
    if (std.mem.eql(u8, have, want)) return true;
    const have_base = if (std.mem.indexOfScalar(u8, have, '@')) |at| have[0..at] else have;
    const want_base = if (std.mem.indexOfScalar(u8, want, '@')) |at| want[0..at] else want;
    return have_base.len > 0 and std.mem.eql(u8, have_base, want_base);
}

const CoreFuncEntry = union(enum) {
    core_export: CoreExportRef,
    resource_intrinsic: struct {
        kind: ResourceIntrinsicKind,
        type_idx: u32,
    },
    lowered_import: u32,
    other_canon,
};

const CompFuncEntry = union(enum) {
    lifted: struct {
        core_func_idx: u32,
        type_idx: u32,
        opts: []const ctypes.CanonOpt,
    },
    imported: []const u8,
    unknown,
};

const CompTypeEntry = union(enum) {
    resource: struct {
        dtor_core_func: ?u32,
    },
    other,
};

const CompInstanceValue = struct {
    funcs: std.StringHashMapUnmanaged(u32) = .empty,
    types: std.StringHashMapUnmanaged(u32) = .empty,
    instances: std.StringHashMapUnmanaged(u32) = .empty,
};

const CoreModuleSummary = struct {
    has_memory_export: bool = false,
    has_realloc_or_init: bool = false,
    imports_wasi_p1: bool = false,
};

fn inspectCoreModuleSummary(wasm_bytes: []const u8) CoreModuleSummary {
    var out: CoreModuleSummary = .{};
    if (wasm_bytes.len < 8 or !std.mem.eql(u8, wasm_bytes[0..8], "\x00asm\x01\x00\x00\x00")) {
        return out;
    }
    var pos: usize = 8;
    while (pos < wasm_bytes.len) {
        const sec_id = wasm_bytes[pos];
        pos += 1;
        const sz = leb128.readU32Leb128(wasm_bytes[pos..]) catch return out;
        pos += sz.bytes_read;
        const sec_end = pos + sz.value;
        if (sec_end > wasm_bytes.len) return out;

        if (sec_id == 2) {
            // Core Import section
            var p = pos;
            const cnt = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch {
                pos = sec_end;
                continue;
            };
            p += cnt.bytes_read;
            var i: u32 = 0;
            while (i < cnt.value and p < sec_end) : (i += 1) {
                const mod_len = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                p += mod_len.bytes_read;
                if (p + mod_len.value > sec_end) break;
                const mod_name = wasm_bytes[p .. p + mod_len.value];
                p += mod_len.value;
                if (std.mem.eql(u8, mod_name, "wasi_snapshot_preview1")) {
                    out.imports_wasi_p1 = true;
                }
                const nm_len = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                p += nm_len.bytes_read;
                if (p + nm_len.value >= sec_end) break;
                p += nm_len.value;
                const desc_kind = wasm_bytes[p];
                p += 1;
                switch (desc_kind) {
                    0x00 => { // func typeidx
                        const ti = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                        p += ti.bytes_read;
                    },
                    0x01 => { // table: elemtype + limits
                        if (p >= sec_end) break;
                        p += 1;
                        const fl = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                        p += fl.bytes_read;
                        const mn = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                        p += mn.bytes_read;
                        if ((fl.value & 0x01) != 0) {
                            const mx = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                            p += mx.bytes_read;
                        }
                    },
                    0x02 => { // mem: limits
                        const fl = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                        p += fl.bytes_read;
                        const mn = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                        p += mn.bytes_read;
                        if ((fl.value & 0x01) != 0) {
                            const mx = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                            p += mx.bytes_read;
                        }
                    },
                    0x03 => { // global: valtype + mut
                        if (p + 2 > sec_end) break;
                        p += 2;
                    },
                    else => break,
                }
            }
        } else if (sec_id == 7) {
            // Core Export section
            var p = pos;
            const cnt = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch {
                pos = sec_end;
                continue;
            };
            p += cnt.bytes_read;
            var i: u32 = 0;
            while (i < cnt.value and p < sec_end) : (i += 1) {
                const nm_len = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                p += nm_len.bytes_read;
                if (p + nm_len.value >= sec_end) break;
                const name = wasm_bytes[p .. p + nm_len.value];
                p += nm_len.value;
                const kind = wasm_bytes[p];
                p += 1;
                const idx = leb128.readU32Leb128(wasm_bytes[p..sec_end]) catch break;
                p += idx.bytes_read;
                if (kind == 0x02 and std.mem.eql(u8, name, "memory")) {
                    out.has_memory_export = true;
                } else if (kind == 0x00 and (std.mem.eql(u8, name, "cabi_realloc") or std.mem.eql(u8, name, "_initialize"))) {
                    out.has_realloc_or_init = true;
                }
            }
        }
        pos = sec_end;
    }
    return out;
}

fn buildFromComponent(
    ar: std.mem.Allocator,
    comp: *const ctypes.Component,
    opts: PlanOptions,
) HostError!ComponentPlan {
    var core_modules: std.ArrayList([]const u8) = .empty;
    var core_instances: std.ArrayList(CoreInstancePlan) = .empty;
    var core_func_space: std.ArrayList(CoreFuncEntry) = .empty;
    var core_mem_space: std.ArrayList(CoreExportRef) = .empty;
    var core_table_space: std.ArrayList(CoreExportRef) = .empty;
    var core_global_space: std.ArrayList(CoreExportRef) = .empty;

    var comp_func_space: std.ArrayList(CompFuncEntry) = .empty;
    var comp_type_space: std.ArrayList(CompTypeEntry) = .empty;
    var comp_instance_space: std.ArrayList(CompInstanceValue) = .empty;
    var comp_component_space: std.ArrayList(?*const ctypes.Component) = .empty;

    var resources: std.ArrayList(ResourcePlan) = .empty;
    var exports: std.ArrayList(CanonicalExport) = .empty;
    var export_by_canonical: std.StringHashMapUnmanaged(usize) = .empty;

    var primary_core_module_idx: ?u32 = null;
    var primary_core_instance_idx: ?u32 = null;
    var wasi_imports_needed = false;

    const fallback_order = [_]ctypes.SectionEntry{
        .{ .kind = .core_module, .start = 0, .count = @intCast(comp.core_modules.len) },
        .{ .kind = .type, .start = 0, .count = @intCast(comp.types.len) },
        .{ .kind = .import, .start = 0, .count = @intCast(comp.imports.len) },
        .{ .kind = .core_instance, .start = 0, .count = @intCast(comp.core_instances.len) },
        .{ .kind = .component, .start = 0, .count = @intCast(comp.components.len) },
        .{ .kind = .alias, .start = 0, .count = @intCast(comp.aliases.len) },
        .{ .kind = .canon, .start = 0, .count = @intCast(comp.canons.len) },
        .{ .kind = .instance, .start = 0, .count = @intCast(comp.instances.len) },
        .{ .kind = .@"export", .start = 0, .count = @intCast(comp.exports.len) },
    };
    const sections = comp.section_order orelse &fallback_order;

    for (sections) |sec| {
        switch (sec.kind) {
            .core_module => {
                for (comp.core_modules[sec.start .. sec.start + sec.count]) |cm| {
                    const mod_idx: u32 = @intCast(core_modules.items.len);
                    const summary = inspectCoreModuleSummary(cm.data);
                    if (summary.imports_wasi_p1) wasi_imports_needed = true;
                    if (primary_core_module_idx == null and summary.has_memory_export and summary.has_realloc_or_init) {
                        primary_core_module_idx = mod_idx;
                    }
                    const mod_bytes = if (opts.copy_module_bytes)
                        try ar.dupe(u8, cm.data)
                    else
                        cm.data;
                    try core_modules.append(ar, mod_bytes);
                }
            },
            .core_instance => {
                for (comp.core_instances[sec.start .. sec.start + sec.count]) |ci| {
                    const ci_idx: u32 = @intCast(core_instances.items.len);
                    switch (ci) {
                        .instantiate => |inst| {
                            if (primary_core_module_idx != null and inst.module_idx == primary_core_module_idx.? and primary_core_instance_idx == null) {
                                primary_core_instance_idx = ci_idx;
                            }
                            const dup_args = try ar.alloc(ctypes.CoreInstantiateArg, inst.args.len);
                            for (inst.args, 0..) |a, idx| {
                                dup_args[idx] = .{
                                    .name = try ar.dupe(u8, a.name),
                                    .instance_idx = a.instance_idx,
                                };
                            }
                            try core_instances.append(ar, .{
                                .instantiate = .{
                                    .module_idx = inst.module_idx,
                                    .args = dup_args,
                                },
                            });
                        },
                        .exports => |exps| {
                            const synth = try ar.alloc(SyntheticCoreExport, exps.len);
                            for (exps, 0..) |e, idx| {
                                const nm = try ar.dupe(u8, e.name);
                                if (e.sort_idx.sort == .func and e.sort_idx.idx < core_func_space.items.len) {
                                    switch (core_func_space.items[e.sort_idx.idx]) {
                                        .core_export => |ce| {
                                            synth[idx] = .{
                                                .core_ref = .{
                                                    .name = nm,
                                                    .sort = .func,
                                                    .target_core_instance_idx = ce.core_instance_idx,
                                                    .target_export_name = ce.export_name,
                                                },
                                            };
                                        },
                                        .resource_intrinsic => |ri| {
                                            synth[idx] = .{
                                                .resource_intrinsic = .{
                                                    .name = nm,
                                                    .kind = ri.kind,
                                                    .resource_type_idx = ri.type_idx,
                                                },
                                            };
                                        },
                                        .lowered_import => |cf_idx| {
                                            synth[idx] = .{
                                                .lowered_import = .{
                                                    .name = nm,
                                                    .comp_func_idx = cf_idx,
                                                },
                                            };
                                        },
                                        .other_canon => {
                                            synth[idx] = .{
                                                .core_ref = .{ .name = nm, .sort = .func },
                                            };
                                        },
                                    }
                                } else if (e.sort_idx.sort == .table and e.sort_idx.idx < core_table_space.items.len) {
                                    const te = core_table_space.items[e.sort_idx.idx];
                                    synth[idx] = .{
                                        .core_ref = .{
                                            .name = nm,
                                            .sort = .table,
                                            .target_core_instance_idx = te.core_instance_idx,
                                            .target_export_name = te.export_name,
                                        },
                                    };
                                } else if (e.sort_idx.sort == .memory and e.sort_idx.idx < core_mem_space.items.len) {
                                    const me = core_mem_space.items[e.sort_idx.idx];
                                    synth[idx] = .{
                                        .core_ref = .{
                                            .name = nm,
                                            .sort = .memory,
                                            .target_core_instance_idx = me.core_instance_idx,
                                            .target_export_name = me.export_name,
                                        },
                                    };
                                } else {
                                    synth[idx] = .{
                                        .core_ref = .{ .name = nm, .sort = e.sort_idx.sort },
                                    };
                                }
                            }
                            try core_instances.append(ar, .{ .synthetic_exports = synth });
                        },
                    }
                }
            },
            .alias => {
                for (comp.aliases[sec.start .. sec.start + sec.count]) |al| {
                    switch (al) {
                        .instance_export => |ie| {
                            const exp_nm = try ar.dupe(u8, ie.name);
                            switch (ie.sort) {
                                .core => |cs| switch (cs) {
                                    .func => try core_func_space.append(ar, .{
                                        .core_export = .{
                                            .core_instance_idx = ie.instance_idx,
                                            .export_name = exp_nm,
                                        },
                                    }),
                                    .memory => try core_mem_space.append(ar, .{
                                        .core_instance_idx = ie.instance_idx,
                                        .export_name = exp_nm,
                                    }),
                                    .table => try core_table_space.append(ar, .{
                                        .core_instance_idx = ie.instance_idx,
                                        .export_name = exp_nm,
                                    }),
                                    .global => try core_global_space.append(ar, .{
                                        .core_instance_idx = ie.instance_idx,
                                        .export_name = exp_nm,
                                    }),
                                    else => {},
                                },
                                .func => {
                                    if (ie.instance_idx < comp_instance_space.items.len) {
                                        if (comp_instance_space.items[ie.instance_idx].funcs.get(exp_nm)) |fidx| {
                                            try comp_func_space.append(ar, comp_func_space.items[fidx]);
                                        } else {
                                            try comp_func_space.append(ar, .unknown);
                                        }
                                    } else {
                                        try comp_func_space.append(ar, .unknown);
                                    }
                                },
                                .type => {
                                    if (ie.instance_idx < comp_instance_space.items.len) {
                                        if (comp_instance_space.items[ie.instance_idx].types.get(exp_nm)) |tidx| {
                                            try comp_type_space.append(ar, comp_type_space.items[tidx]);
                                        } else {
                                            try comp_type_space.append(ar, .other);
                                        }
                                    } else {
                                        try comp_type_space.append(ar, .other);
                                    }
                                },
                                .instance => {
                                    if (ie.instance_idx < comp_instance_space.items.len) {
                                        if (comp_instance_space.items[ie.instance_idx].instances.get(exp_nm)) |sub_idx| {
                                            try comp_instance_space.append(ar, comp_instance_space.items[sub_idx]);
                                        } else {
                                            try comp_instance_space.append(ar, .{});
                                        }
                                    } else {
                                        try comp_instance_space.append(ar, .{});
                                    }
                                },
                                else => {},
                            }
                        },
                        .outer => |ou| switch (ou.sort) {
                            .core => |cs| switch (cs) {
                                .func => try core_func_space.append(ar, .other_canon),
                                .memory => try core_mem_space.append(ar, .{ .core_instance_idx = 0, .export_name = "" }),
                                .table => try core_table_space.append(ar, .{ .core_instance_idx = 0, .export_name = "" }),
                                .global => try core_global_space.append(ar, .{ .core_instance_idx = 0, .export_name = "" }),
                                else => {},
                            },
                            .func => try comp_func_space.append(ar, .unknown),
                            .type => try comp_type_space.append(ar, .other),
                            .instance => try comp_instance_space.append(ar, .{}),
                            .component => try comp_component_space.append(ar, null),
                            else => {},
                        },
                    }
                }
            },
            .component => {
                for (comp.components[sec.start .. sec.start + sec.count]) |sub_comp| {
                    try comp_component_space.append(ar, sub_comp);
                }
            },
            .type => {
                for (comp.types[sec.start .. sec.start + sec.count]) |td| {
                    switch (td) {
                        .resource => |rt| try comp_type_space.append(ar, .{
                            .resource = .{ .dtor_core_func = rt.destructor },
                        }),
                        else => try comp_type_space.append(ar, .other),
                    }
                }
            },
            .import => {
                for (comp.imports[sec.start .. sec.start + sec.count]) |imp| {
                    switch (imp.desc) {
                        .module => try core_modules.append(ar, &.{}),
                        .func => try comp_func_space.append(ar, .{ .imported = try ar.dupe(u8, imp.name) }),
                        .type => try comp_type_space.append(ar, .other),
                        .instance => try comp_instance_space.append(ar, .{}),
                        .component => try comp_component_space.append(ar, null),
                        else => {},
                    }
                }
            },
            .canon => {
                for (comp.canons[sec.start .. sec.start + sec.count]) |cn| {
                    switch (cn) {
                        .lift => |lf| {
                            try comp_func_space.append(ar, .{
                                .lifted = .{
                                    .core_func_idx = lf.core_func_idx,
                                    .type_idx = lf.type_idx,
                                    .opts = lf.opts,
                                },
                            });
                        },
                        .lower => |lw| {
                            try core_func_space.append(ar, .{ .lowered_import = lw.func_idx });
                        },
                        .resource_new => |t_idx| {
                            try core_func_space.append(ar, .{
                                .resource_intrinsic = .{ .kind = .resource_new, .type_idx = t_idx },
                            });
                        },
                        .resource_rep => |t_idx| {
                            try core_func_space.append(ar, .{
                                .resource_intrinsic = .{ .kind = .resource_rep, .type_idx = t_idx },
                            });
                        },
                        .resource_drop => |t_idx| {
                            try core_func_space.append(ar, .{
                                .resource_intrinsic = .{ .kind = .resource_drop, .type_idx = t_idx },
                            });
                        },
                        else => {
                            try core_func_space.append(ar, .other_canon);
                        },
                    }
                }
            },
            .instance => {
                for (comp.instances[sec.start .. sec.start + sec.count]) |inst_expr| {
                    var inst_val: CompInstanceValue = .{};
                    switch (inst_expr) {
                        .exports => |inline_exps| {
                            for (inline_exps) |ie| {
                                const nm = try ar.dupe(u8, ie.name);
                                switch (ie.sort_idx.sort) {
                                    .func => try inst_val.funcs.put(ar, nm, ie.sort_idx.idx),
                                    .type => try inst_val.types.put(ar, nm, ie.sort_idx.idx),
                                    .instance => try inst_val.instances.put(ar, nm, ie.sort_idx.idx),
                                    else => {},
                                }
                            }
                        },
                        .instantiate => |inst| {
                            if (inst.component_idx < comp_component_space.items.len) {
                                if (comp_component_space.items[inst.component_idx]) |sub_comp| {
                                    try evaluateShimComponentInstantiation(
                                        ar,
                                        sub_comp,
                                        inst.args,
                                        comp_instance_space.items,
                                        comp_func_space.items.len,
                                        comp_type_space.items.len,
                                        &inst_val,
                                    );
                                }
                            }
                        },
                    }
                    try comp_instance_space.append(ar, inst_val);
                }
            },
            .@"export" => {
                for (comp.exports[sec.start .. sec.start + sec.count]) |exp| {
                    const si = exp.sort_idx orelse continue;
                    const exp_name = try ar.dupe(u8, exp.name);

                    // Top-level component exports also append the exported entity to its sort index space!
                    switch (si.sort) {
                        .func => {
                            if (si.idx < comp_func_space.items.len) {
                                const entry = comp_func_space.items[si.idx];
                                try comp_func_space.append(ar, entry);
                                try appendLiftedExport(
                                    ar,
                                    "",
                                    exp_name,
                                    entry,
                                    core_func_space.items,
                                    core_mem_space.items,
                                    core_instances.items,
                                    &exports,
                                    &export_by_canonical,
                                );
                            } else {
                                try comp_func_space.append(ar, .unknown);
                            }
                        },
                        .type => {
                            if (si.idx < comp_type_space.items.len) {
                                const t_entry = comp_type_space.items[si.idx];
                                try comp_type_space.append(ar, t_entry);
                                try appendResourceIfAny(
                                    ar,
                                    "",
                                    exp_name,
                                    si.idx,
                                    t_entry,
                                    core_func_space.items,
                                    &resources,
                                );
                            } else {
                                try comp_type_space.append(ar, .other);
                            }
                        },
                        .instance => {
                            if (si.idx < comp_instance_space.items.len) {
                                const inst_val = comp_instance_space.items[si.idx];
                                try comp_instance_space.append(ar, inst_val);

                                // Collect exported resources on this WIT interface
                                var type_it = inst_val.types.iterator();
                                while (type_it.next()) |kv| {
                                    const t_idx = kv.value_ptr.*;
                                    if (t_idx < comp_type_space.items.len) {
                                        try appendResourceIfAny(
                                            ar,
                                            exp_name,
                                            kv.key_ptr.*,
                                            t_idx,
                                            comp_type_space.items[t_idx],
                                            core_func_space.items,
                                            &resources,
                                        );
                                    }
                                }

                                // Collect canonical lifted functions on this WIT interface
                                var fn_it = inst_val.funcs.iterator();
                                while (fn_it.next()) |kv| {
                                    const f_idx = kv.value_ptr.*;
                                    if (f_idx < comp_func_space.items.len) {
                                        try appendLiftedExport(
                                            ar,
                                            exp_name,
                                            kv.key_ptr.*,
                                            comp_func_space.items[f_idx],
                                            core_func_space.items,
                                            core_mem_space.items,
                                            core_instances.items,
                                            &exports,
                                            &export_by_canonical,
                                        );
                                    }
                                }
                            } else {
                                try comp_instance_space.append(ar, .{});
                            }
                        },
                        .core => |cs| switch (cs) {
                            .module => {
                                if (si.idx < core_modules.items.len) {
                                    try core_modules.append(ar, core_modules.items[si.idx]);
                                }
                            },
                            .func => {
                                if (si.idx < core_func_space.items.len) {
                                    try core_func_space.append(ar, core_func_space.items[si.idx]);
                                }
                            },
                            .memory => {
                                if (si.idx < core_mem_space.items.len) {
                                    try core_mem_space.append(ar, core_mem_space.items[si.idx]);
                                }
                            },
                            .table => {
                                if (si.idx < core_table_space.items.len) {
                                    try core_table_space.append(ar, core_table_space.items[si.idx]);
                                }
                            },
                            .global => {
                                if (si.idx < core_global_space.items.len) {
                                    try core_global_space.append(ar, core_global_space.items[si.idx]);
                                }
                            },
                            else => {},
                        },
                        .component => {
                            if (si.idx < comp_component_space.items.len) {
                                try comp_component_space.append(ar, comp_component_space.items[si.idx]);
                            } else {
                                try comp_component_space.append(ar, null);
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    if (primary_core_module_idx == null and core_modules.items.len > 0) {
        primary_core_module_idx = 0;
    }

    // Resolve `wasm-tools component new` indirect shim trampoline slots (`shim` + `actual`
    // fixup core instances) back to the underlying core module export names.
    for (resources.items) |*res| {
        if (res.dtor_core_instance_idx != null and res.dtor_export_name != null) {
            if (resolveShimCoreExport(
                .{ .core_instance_idx = res.dtor_core_instance_idx.?, .export_name = res.dtor_export_name.? },
                core_instances.items,
            )) |resolved| {
                res.dtor_core_instance_idx = resolved.core_instance_idx;
                res.dtor_export_name = resolved.export_name;
            }
        }
    }
    for (exports.items) |*exp| {
        if (resolveShimCoreExport(
            .{ .core_instance_idx = exp.core_instance_idx, .export_name = exp.core_export_name },
            core_instances.items,
        )) |resolved| {
            exp.core_instance_idx = resolved.core_instance_idx;
            exp.core_export_name = resolved.export_name;
            if (resolved.core_instance_idx < core_instances.items.len and
                core_instances.items[resolved.core_instance_idx] == .instantiate)
            {
                exp.core_module_idx = core_instances.items[resolved.core_instance_idx].instantiate.module_idx;
            }
        }
    }

    return .{
        .arena = undefined,
        .core_modules = try core_modules.toOwnedSlice(ar),
        .core_instances = try core_instances.toOwnedSlice(ar),
        .primary_core_module_idx = primary_core_module_idx,
        .primary_core_instance_idx = primary_core_instance_idx,
        .wasi_imports_needed = wasi_imports_needed,
        .resources = try resources.toOwnedSlice(ar),
        .exports = try exports.toOwnedSlice(ar),
        .export_by_canonical = export_by_canonical,
    };
}

fn resolveShimCoreExport(
    ref: CoreExportRef,
    core_instances: []const CoreInstancePlan,
) ?CoreExportRef {
    for (core_instances) |ci| {
        if (ci != .instantiate) continue;
        var shim_inst: ?u32 = null;
        var actual_inst: ?u32 = null;
        for (ci.instantiate.args) |arg| {
            if (std.mem.eql(u8, arg.name, "shim")) shim_inst = arg.instance_idx;
            if (std.mem.eql(u8, arg.name, "actual")) actual_inst = arg.instance_idx;
        }
        if (shim_inst != null and shim_inst.? == ref.core_instance_idx and actual_inst != null) {
            const act_idx = actual_inst.?;
            if (act_idx < core_instances.len and core_instances[act_idx] == .synthetic_exports) {
                for (core_instances[act_idx].synthetic_exports) |se| {
                    if (se == .core_ref and
                        std.mem.eql(u8, se.core_ref.name, ref.export_name) and
                        se.core_ref.target_core_instance_idx != null and
                        se.core_ref.target_export_name.len > 0)
                    {
                        return .{
                            .core_instance_idx = se.core_ref.target_core_instance_idx.?,
                            .export_name = se.core_ref.target_export_name,
                        };
                    }
                }
            }
        }
    }
    return null;
}

fn evaluateShimComponentInstantiation(
    ar: std.mem.Allocator,
    sub_comp: *const ctypes.Component,
    args: []const ctypes.InstantiateArg,
    outer_instances: []const CompInstanceValue,
    outer_func_len: usize,
    outer_type_len: usize,
    out_inst: *CompInstanceValue,
) !void {
    var arg_map: std.StringHashMapUnmanaged(ctypes.SortIdx) = .empty;
    for (args) |a| {
        try arg_map.put(ar, a.name, a.sort_idx);
    }

    var sub_funcs: std.ArrayList(?u32) = .empty;
    var sub_types: std.ArrayList(?u32) = .empty;
    var sub_instances: std.ArrayList(?u32) = .empty;

    const fallback_order = [_]ctypes.SectionEntry{
        .{ .kind = .type, .start = 0, .count = @intCast(sub_comp.types.len) },
        .{ .kind = .import, .start = 0, .count = @intCast(sub_comp.imports.len) },
        .{ .kind = .alias, .start = 0, .count = @intCast(sub_comp.aliases.len) },
        .{ .kind = .instance, .start = 0, .count = @intCast(sub_comp.instances.len) },
        .{ .kind = .@"export", .start = 0, .count = @intCast(sub_comp.exports.len) },
    };
    const sections = sub_comp.section_order orelse &fallback_order;

    for (sections) |sec| {
        switch (sec.kind) {
            .import => {
                for (sub_comp.imports[sec.start .. sec.start + sec.count]) |imp| {
                    const matched = arg_map.get(imp.name);
                    switch (imp.desc) {
                        .func => try sub_funcs.append(ar, if (matched) |m| (if (m.sort == .func) m.idx else null) else null),
                        .type => try sub_types.append(ar, if (matched) |m| (if (m.sort == .type) m.idx else null) else null),
                        .instance => try sub_instances.append(ar, if (matched) |m| (if (m.sort == .instance) m.idx else null) else null),
                        else => {},
                    }
                }
            },
            .type => {
                var i: u32 = 0;
                while (i < sec.count) : (i += 1) {
                    try sub_types.append(ar, null);
                }
            },
            .alias => {
                for (sub_comp.aliases[sec.start .. sec.start + sec.count]) |al| {
                    switch (al) {
                        .instance_export => |ie| {
                            const outer_inst_idx = if (ie.instance_idx < sub_instances.items.len)
                                sub_instances.items[ie.instance_idx]
                            else
                                null;
                            const outer_inst: ?CompInstanceValue = if (outer_inst_idx) |oi|
                                (if (oi < outer_instances.len) outer_instances[oi] else null)
                            else
                                null;
                            switch (ie.sort) {
                                .func => try sub_funcs.append(ar, if (outer_inst) |inst| inst.funcs.get(ie.name) else null),
                                .type => try sub_types.append(ar, if (outer_inst) |inst| inst.types.get(ie.name) else null),
                                .instance => try sub_instances.append(ar, if (outer_inst) |inst| inst.instances.get(ie.name) else null),
                                else => {},
                            }
                        },
                        .outer => |ou| {
                            const is_parent = (ou.outer_count == 1);
                            switch (ou.sort) {
                                .func => try sub_funcs.append(ar, if (is_parent and ou.idx < outer_func_len) ou.idx else null),
                                .type => try sub_types.append(ar, if (is_parent and ou.idx < outer_type_len) ou.idx else null),
                                .instance => try sub_instances.append(ar, if (is_parent and ou.idx < outer_instances.len) ou.idx else null),
                                else => {},
                            }
                        },
                    }
                }
            },
            .instance => {
                var i: u32 = 0;
                while (i < sec.count) : (i += 1) {
                    try sub_instances.append(ar, null);
                }
            },
            .@"export" => {
                for (sub_comp.exports[sec.start .. sec.start + sec.count]) |sub_exp| {
                    const si = sub_exp.sort_idx orelse continue;
                    const exp_nm = try ar.dupe(u8, sub_exp.name);
                    switch (si.sort) {
                        .func => {
                            const mapped = if (si.idx < sub_funcs.items.len) sub_funcs.items[si.idx] else null;
                            try sub_funcs.append(ar, mapped);
                            if (mapped) |outer_fidx| {
                                try out_inst.funcs.put(ar, exp_nm, outer_fidx);
                            }
                        },
                        .type => {
                            const mapped = if (si.idx < sub_types.items.len) sub_types.items[si.idx] else null;
                            try sub_types.append(ar, mapped);
                            if (mapped) |outer_tidx| {
                                try out_inst.types.put(ar, exp_nm, outer_tidx);
                            }
                        },
                        .instance => {
                            const mapped = if (si.idx < sub_instances.items.len) sub_instances.items[si.idx] else null;
                            try sub_instances.append(ar, mapped);
                            if (mapped) |outer_iidx| {
                                try out_inst.instances.put(ar, exp_nm, outer_iidx);
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
}

fn appendResourceIfAny(
    ar: std.mem.Allocator,
    interface_name: []const u8,
    resource_name: []const u8,
    type_idx: u32,
    t_entry: CompTypeEntry,
    core_func_space: []const CoreFuncEntry,
    resources: *std.ArrayList(ResourcePlan),
) !void {
    switch (t_entry) {
        .resource => |rt| {
            // Avoid duplicate registration when another interface `use`s and re-exports the same resource
            for (resources.items) |existing| {
                if (existing.type_idx == type_idx and std.mem.eql(u8, existing.resource_name, resource_name)) {
                    return;
                }
            }
            var dtor_inst: ?u32 = null;
            var dtor_name: ?[]const u8 = null;
            if (rt.dtor_core_func) |df_idx| {
                if (df_idx < core_func_space.len) {
                    if (core_func_space[df_idx] == .core_export) {
                        dtor_inst = core_func_space[df_idx].core_export.core_instance_idx;
                        dtor_name = core_func_space[df_idx].core_export.export_name;
                    }
                }
            }
            try resources.append(ar, .{
                .type_idx = type_idx,
                .interface_name = interface_name,
                .resource_name = resource_name,
                .dtor_core_instance_idx = dtor_inst,
                .dtor_export_name = dtor_name,
            });
        },
        .other => {},
    }
}

fn appendLiftedExport(
    ar: std.mem.Allocator,
    interface_name: []const u8,
    func_name: []const u8,
    entry: CompFuncEntry,
    core_func_space: []const CoreFuncEntry,
    core_mem_space: []const CoreExportRef,
    core_instances: []const CoreInstancePlan,
    exports: *std.ArrayList(CanonicalExport),
    export_by_canonical: *std.StringHashMapUnmanaged(usize),
) !void {
    const lf = switch (entry) {
        .lifted => |l| l,
        else => return,
    };
    if (lf.core_func_idx >= core_func_space.len) return;
    const target_ce = switch (core_func_space[lf.core_func_idx]) {
        .core_export => |ce| ce,
        else => return,
    };

    var core_mod_idx: ?u32 = null;
    if (target_ce.core_instance_idx < core_instances.len) {
        if (core_instances[target_ce.core_instance_idx] == .instantiate) {
            core_mod_idx = core_instances[target_ce.core_instance_idx].instantiate.module_idx;
        }
    }

    var mem_ref: ?CoreExportRef = null;
    var realloc_ref: ?CoreExportRef = null;
    var post_ref: ?CoreExportRef = null;
    var str_enc: ctypes.StringEncoding = .utf8;
    var is_async = false;

    for (lf.opts) |opt| {
        switch (opt) {
            .memory => |m_idx| {
                if (m_idx < core_mem_space.len) mem_ref = core_mem_space[m_idx];
            },
            .realloc => |r_idx| {
                if (r_idx < core_func_space.len and core_func_space[r_idx] == .core_export) {
                    realloc_ref = core_func_space[r_idx].core_export;
                }
            },
            .post_return => |p_idx| {
                if (p_idx < core_func_space.len and core_func_space[p_idx] == .core_export) {
                    post_ref = core_func_space[p_idx].core_export;
                }
            },
            .string_encoding => |enc| str_enc = enc,
            .async_ => is_async = true,
            else => {},
        }
    }

    const canonical_name = if (interface_name.len == 0)
        func_name
    else
        try std.fmt.allocPrint(ar, "{s}#{s}", .{ interface_name, func_name });

    const out_idx = exports.items.len;
    try exports.append(ar, .{
        .canonical_name = canonical_name,
        .interface_name = interface_name,
        .func_name = func_name,
        .core_instance_idx = target_ce.core_instance_idx,
        .core_module_idx = core_mod_idx,
        .core_export_name = target_ce.export_name,
        .memory_export = mem_ref,
        .realloc_export = realloc_ref,
        .post_return_export = post_ref,
        .string_encoding = str_enc,
        .is_async = is_async,
    });
    try export_by_canonical.put(ar, canonical_name, out_idx);
}

// ── Host Resource Handle Table ──────────────────────────────────────────────

pub const ResourceDtorFn = *const fn (ctx: ?*anyopaque, rep: i32) HostError!void;

pub const HostResourceTable = struct {
    allocator: std.mem.Allocator,
    next_handle: i32 = 1,
    entries: std.AutoHashMapUnmanaged(i32, Entry) = .empty,
    dtors: std.StringHashMapUnmanaged(DtorBinding) = .empty,

    pub const Entry = struct {
        iface: []u8,
        resource_name: []u8,
        rep: i32,
    };

    pub const DtorBinding = struct {
        ctx: ?*anyopaque = null,
        func: ResourceDtorFn,
    };

    pub fn init(allocator: std.mem.Allocator) HostResourceTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HostResourceTable) void {
        var entry_it = self.entries.valueIterator();
        while (entry_it.next()) |e| {
            self.allocator.free(e.iface);
            self.allocator.free(e.resource_name);
        }
        self.entries.deinit(self.allocator);

        var dtor_it = self.dtors.keyIterator();
        while (dtor_it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.dtors.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn bindDtor(
        self: *HostResourceTable,
        iface: []const u8,
        resource_name: []const u8,
        ctx: ?*anyopaque,
        func: ResourceDtorFn,
    ) !void {
        if (iface.len > 0) {
            const qual = try std.fmt.allocPrint(self.allocator, "{s}#{s}", .{ iface, resource_name });
            if (self.dtors.fetchRemove(qual)) |old| {
                self.allocator.free(old.key);
            }
            try self.dtors.put(self.allocator, qual, .{ .ctx = ctx, .func = func });
        }
        if (!self.dtors.contains(resource_name)) {
            const bare = try self.allocator.dupe(u8, resource_name);
            errdefer self.allocator.free(bare);
            try self.dtors.put(self.allocator, bare, .{ .ctx = ctx, .func = func });
        }
    }

    pub fn insert(
        self: *HostResourceTable,
        iface: []const u8,
        resource_name: []const u8,
        rep_val: i32,
    ) HostError!i32 {
        const handle = self.next_handle;
        self.next_handle += 1;

        const dup_iface = try self.allocator.dupe(u8, iface);
        errdefer self.allocator.free(dup_iface);
        const dup_res = try self.allocator.dupe(u8, resource_name);
        errdefer self.allocator.free(dup_res);

        try self.entries.put(self.allocator, handle, .{
            .iface = dup_iface,
            .resource_name = dup_res,
            .rep = rep_val,
        });
        return handle;
    }

    pub fn rep(
        self: *const HostResourceTable,
        _iface: []const u8,
        resource_name: []const u8,
        handle: i32,
    ) HostError!i32 {
        _ = _iface;
        const entry = self.entries.get(handle) orelse return error.InvalidResourceHandle;
        if (resource_name.len > 0 and !std.mem.eql(u8, entry.resource_name, resource_name)) {
            return error.ResourceTypeMismatch;
        }
        return entry.rep;
    }

    pub fn drop(
        self: *HostResourceTable,
        _iface: []const u8,
        resource_name: []const u8,
        handle: i32,
    ) HostError!void {
        _ = _iface;
        const existing = self.entries.get(handle) orelse return error.DoubleDropResource;
        if (resource_name.len > 0 and !std.mem.eql(u8, existing.resource_name, resource_name)) {
            return error.ResourceTypeMismatch;
        }
        const kv = self.entries.fetchRemove(handle).?;
        const entry = kv.value;
        defer {
            self.allocator.free(entry.iface);
            self.allocator.free(entry.resource_name);
        }

        // Look up `<iface>#<resource_name>` or bare `<resource_name>`
        var stack_buf: [256]u8 = undefined;
        const dtor_binding: ?DtorBinding = blk: {
            if (entry.iface.len > 0) {
                if (entry.iface.len + 1 + entry.resource_name.len <= stack_buf.len) {
                    const key = std.fmt.bufPrint(&stack_buf, "{s}#{s}", .{ entry.iface, entry.resource_name }) catch unreachable;
                    if (self.dtors.get(key)) |b| break :blk b;
                } else {
                    const key = try std.fmt.allocPrint(self.allocator, "{s}#{s}", .{ entry.iface, entry.resource_name });
                    defer self.allocator.free(key);
                    if (self.dtors.get(key)) |b| break :blk b;
                }
            }
            break :blk self.dtors.get(entry.resource_name);
        };
        if (dtor_binding) |b| {
            try b.func(b.ctx, entry.rep);
        }
    }

    pub fn liveCount(self: *const HostResourceTable) u32 {
        return @intCast(self.entries.count());
    }
};

// ── Abstract Guest Memory & Execution Backend ───────────────────────────────

pub const GuestMemoryBackend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        alloc: *const fn (ctx: *anyopaque, realloc_export: []const u8, alignment: u32, byte_len: u32) HostError!u64,
        write: *const fn (ctx: *anyopaque, guest_addr: u64, bytes: []const u8) HostError!void,
        alloc_and_write: ?*const fn (ctx: *anyopaque, realloc_export: []const u8, alignment: u32, bytes: []const u8) HostError!u64 = null,
        read: *const fn (ctx: *anyopaque, guest_addr: u64, out: []u8) HostError!void,
        memory_size: *const fn (ctx: *anyopaque) HostError!u64,
        call_core: *const fn (
            ctx: *anyopaque,
            export_name: []const u8,
            params: []const CoreVal,
            expected_result: ?canon.FlatValType,
        ) HostError!CoreVal,
        call_post_return: *const fn (
            ctx: *anyopaque,
            post_export_name: []const u8,
            raw_result: CoreVal,
        ) HostError!void,
        resource_new: *const fn (ctx: *anyopaque, iface: []const u8, resource_name: []const u8, rep: i32) HostError!i32,
        resource_rep: *const fn (ctx: *anyopaque, iface: []const u8, resource_name: []const u8, handle: i32) HostError!i32,
        resource_drop: *const fn (ctx: *anyopaque, iface: []const u8, resource_name: []const u8, handle: i32) HostError!void,
        live_resource_count: *const fn (ctx: *anyopaque) u32,
    };

    pub inline fn alloc(self: GuestMemoryBackend, realloc_export: []const u8, alignment: u32, byte_len: u32) HostError!u64 {
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.AlignmentError;
        if (byte_len == 0) return alignment;
        const addr = try self.vtable.alloc(self.ctx, realloc_export, alignment, byte_len);
        if ((addr & (alignment - 1)) != 0) return error.UnalignedPointer;
        return addr;
    }

    pub inline fn write(self: GuestMemoryBackend, guest_addr: u64, bytes: []const u8) HostError!void {
        if (bytes.len == 0) return;
        return self.vtable.write(self.ctx, guest_addr, bytes);
    }

    pub inline fn allocAndWrite(
        self: GuestMemoryBackend,
        realloc_export: []const u8,
        alignment: u32,
        bytes: []const u8,
    ) HostError!u64 {
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.AlignmentError;
        if (bytes.len == 0) return alignment;
        if (bytes.len > std.math.maxInt(u32)) return error.OutOfBounds;
        if (self.vtable.alloc_and_write) |aw| {
            const addr = try aw(self.ctx, realloc_export, alignment, bytes);
            if ((addr & (alignment - 1)) != 0) return error.UnalignedPointer;
            return addr;
        }
        const addr = try self.alloc(realloc_export, alignment, @intCast(bytes.len));
        try self.write(addr, bytes);
        return addr;
    }

    pub inline fn read(self: GuestMemoryBackend, guest_addr: u64, out: []u8) HostError!void {
        if (out.len == 0) return;
        return self.vtable.read(self.ctx, guest_addr, out);
    }

    pub inline fn memorySize(self: GuestMemoryBackend) HostError!u64 {
        return self.vtable.memory_size(self.ctx);
    }

    pub inline fn callCore(
        self: GuestMemoryBackend,
        export_name: []const u8,
        params: []const CoreVal,
        expected_result: ?canon.FlatValType,
    ) HostError!CoreVal {
        return self.vtable.call_core(self.ctx, export_name, params, expected_result);
    }

    pub inline fn callPostReturn(
        self: GuestMemoryBackend,
        post_export_name: []const u8,
        raw_result: CoreVal,
    ) HostError!void {
        return self.vtable.call_post_return(self.ctx, post_export_name, raw_result);
    }

    pub inline fn resourceNew(self: GuestMemoryBackend, iface: []const u8, resource_name: []const u8, rep: i32) HostError!i32 {
        return self.vtable.resource_new(self.ctx, iface, resource_name, rep);
    }

    pub inline fn resourceRep(self: GuestMemoryBackend, iface: []const u8, resource_name: []const u8, handle: i32) HostError!i32 {
        return self.vtable.resource_rep(self.ctx, iface, resource_name, handle);
    }

    pub inline fn resourceDrop(self: GuestMemoryBackend, iface: []const u8, resource_name: []const u8, handle: i32) HostError!void {
        return self.vtable.resource_drop(self.ctx, iface, resource_name, handle);
    }

    pub inline fn liveResourceCount(self: GuestMemoryBackend) u32 {
        return self.vtable.live_resource_count(self.ctx);
    }
};

// ── Deep Deallocator for Lifted Host Values ─────────────────────────────────

pub fn typeNeedsHostFree(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pt| pt.size == .slice,
        .array => |ar| ar.len > 0 and typeNeedsHostFree(ar.child),
        .optional => |op| typeNeedsHostFree(op.child),
        .@"struct" => |st| blk: {
            if (canon.isHandleType(T) or st.layout == .@"packed") break :blk false;
            if (canon.isStringWrapper(T)) break :blk true;
            for (st.field_types, st.field_attrs) |FT, fattr| {
                if (!fattr.@"comptime" and typeNeedsHostFree(FT)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |un| blk: {
            for (un.field_types) |CT| {
                if (typeNeedsHostFree(CT)) break :blk true;
            }
            break :blk false;
        },
        .error_union => |eu| typeNeedsHostFree(eu.payload),
        else => false,
    };
}

/// Recursively free all slices and strings allocated in `allocator` by `ComponentHost`
/// when lifting a value of type `T`. Safe to call on values containing empty slices (`&.{}').
/// Note: WIT resource handles (`Own(R)`) represent guest-side resources and must be
/// released via `host.dropResource(...)` or `resource_client.drop()`.
pub fn freeValue(comptime T: type, allocator: std.mem.Allocator, val: T) void {
    if (comptime !typeNeedsHostFree(T)) return;

    switch (@typeInfo(T)) {
        .pointer => |pt| switch (pt.size) {
            .slice => {
                if (comptime typeNeedsHostFree(pt.child)) {
                    for (val) |elem| {
                        freeValue(pt.child, allocator, elem);
                    }
                }
                if (comptime pt.sentinel_ptr != null) {
                    const sent = @as(*const pt.child, @ptrCast(@alignCast(pt.sentinel_ptr.?))).*;
                    const s: [:sent]const pt.child = val;
                    allocator.free(s);
                } else if (val.len > 0) {
                    allocator.free(val);
                }
            },
            else => {},
        },
        .array => |ar| {
            for (val) |elem| {
                freeValue(ar.child, allocator, elem);
            }
        },
        .optional => |op| {
            if (val) |inner| {
                freeValue(op.child, allocator, inner);
            }
        },
        .@"struct" => |st| {
            if (comptime canon.isStringWrapper(T)) {
                freeValue(@TypeOf(val.bytes), allocator, val.bytes);
                return;
            }
            inline for (st.field_names, st.field_types, st.field_attrs) |fname, FT, fattr| {
                if (!fattr.@"comptime" and comptime typeNeedsHostFree(FT)) {
                    freeValue(FT, allocator, @field(val, fname));
                }
            }
        },
        .@"union" => {
            switch (val) {
                inline else => |payload| freeValue(@TypeOf(payload), allocator, payload),
            }
        },
        .error_union => |eu| {
            if (val) |ok_val| {
                freeValue(eu.payload, allocator, ok_val);
            } else |_| {}
        },
        else => {},
    }
}

// ── Cross-Memory Canonical ABI Host Invoker (`ComponentHost`) ───────────────

fn isHostBlittable(comptime T: type, comptime arch: canon.Arch) bool {
    if (builtin.cpu.arch.endian() != .little) return false;
    return switch (@typeInfo(T)) {
        .int => (comptime canon.layoutOf(T, arch)).is_blittable,
        .float => false, // Canonical ABI requires NaN canonicalization
        .array => |ar| ar.len == 0 or (isHostBlittable(ar.child, arch) and (comptime canon.layoutOf(T, arch)).is_blittable),
        .@"struct" => |st| blk: {
            if (canon.isHandleType(T) or canon.isStringWrapper(T) or st.layout != .@"extern") break :blk false;
            if (!(comptime canon.layoutOf(T, arch)).is_blittable) break :blk false;
            for (st.field_types, st.field_attrs) |FT, fattr| {
                if (!fattr.@"comptime" and !isHostBlittable(FT, arch)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn canonicalizeF32(v: f32) f32 {
    return if (std.math.isNan(v)) @bitCast(@as(u32, 0x7fc0_0000)) else v;
}

fn canonicalizeF64(v: f64) f64 {
    return if (std.math.isNan(v)) @bitCast(@as(u64, 0x7ff8_0000_0000_0000)) else v;
}

fn hostPackedFlagsMask(comptime T: type) @Int(.unsigned, @bitSizeOf(@typeInfo(T).@"struct".backing_integer.?)) {
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

fn raiseErrorByIndex(comptime ErrSet: type, raw: u32) HostError!ErrSet {
    const names = @typeInfo(ErrSet).error_set.error_names.?;
    inline for (names, 0..) |ename, idx| {
        if (raw == idx) return @field(ErrSet, ename);
    }
    return error.InvalidDiscriminant;
}

fn errorToIndex(comptime ErrSet: type, err_val: ErrSet) u32 {
    const names = @typeInfo(ErrSet).error_set.error_names.?;
    inline for (names, 0..) |ename, idx| {
        if (err_val == @field(ErrSet, ename)) return @intCast(idx);
    }
    unreachable;
}

pub const CallSpec = struct {
    interface_name: []const u8 = "",
    is_async: bool = false,
    string_encoding_utf8: bool = true,
};

pub const ComponentHost = ComponentHostForArch(.wasm32);
pub const ComponentHost64 = ComponentHostForArch(.wasm64);

pub fn ComponentHostForArch(comptime arch: canon.Arch) type {
    return struct {
        backend: GuestMemoryBackend,
        plan: ?*const ComponentPlan = null,
        default_realloc_export: []const u8 = "cabi_realloc",
        validate_utf8: bool = true,

        const Self = @This();
        const AddrT = canon.AddrInt(arch);
        const FlatAddrT = canon.FlatAddrType(arch);

        pub const free = freeValue;

        pub fn init(backend: GuestMemoryBackend) Self {
            return .{ .backend = backend };
        }

        pub fn initWithPlan(backend: GuestMemoryBackend, plan: *const ComponentPlan) Self {
            return .{
                .backend = backend,
                .plan = plan,
            };
        }

        pub fn dropResource(self: *const Self, iface: []const u8, resource_name: []const u8, handle: i32) HostError!void {
            return self.backend.resourceDrop(iface, resource_name, handle);
        }

        pub fn liveResourceCount(self: *const Self) u32 {
            return self.backend.liveResourceCount();
        }

        /// Invoke a `zigar wit`-generated function or resource method using its
        /// emitted `*_Fn` signature and `*_meta` Canonical ABI descriptor.
        pub fn callMeta(
            self: *const Self,
            comptime FnType: type,
            comptime meta: anytype,
            allocator: std.mem.Allocator,
            args: std.meta.ArgsTuple(FnType),
        ) HostCallResult(FnType) {
            const iface: []const u8 = if (@hasField(@TypeOf(meta), "interface_name"))
                meta.interface_name
            else
                "";
            const is_async: bool = if (@hasField(@TypeOf(meta), "is_async"))
                meta.is_async
            else
                false;
            const str_utf8: bool = if (@hasField(@TypeOf(meta), "string_encoding_utf8"))
                meta.string_encoding_utf8
            else
                true;
            return self.call(
                FnType,
                .{
                    .interface_name = iface,
                    .is_async = is_async,
                    .string_encoding_utf8 = str_utf8,
                },
                allocator,
                meta.export_name,
                args,
            );
        }

        /// Invoke an exported WIT function across the host -> guest boundary.
        ///
        /// 1. Lowers `args` into guest linear memory via `cabi_realloc` without caching
        ///    stale slices across reallocations (safe under `memory.grow` mid-lower),
        /// 2. Preserves unsigned 32-bit (`u32`) guest pointers across `>= 2 GiB` (`0x8000_0000+`),
        /// 3. Invokes the core Wasm export,
        /// 4. Lifts the Canonical ABI result into `allocator` while guaranteeing
        ///    `cabi_post_*` cleanup via `defer` on both `ok` and `err` arms (and on lift errors).
        pub fn call(
            self: *const Self,
            comptime FnType: type,
            comptime spec: CallSpec,
            allocator: std.mem.Allocator,
            export_name: []const u8,
            args: std.meta.ArgsTuple(FnType),
        ) HostCallResult(FnType) {
            if (comptime spec.is_async) {
                return error.UnsupportedAsyncHostCall;
            }

            const call_opts: canon.CallOptions = .{
                .arch = arch,
                .is_async = false,
                .direction = .lift,
                .string_encoding_utf8 = spec.string_encoding_utf8,
            };
            const cls = comptime canon.classifyZigFn(FnType, call_opts);
            const ArgsT = std.meta.ArgsTuple(FnType);
            const RetT = canon.ReturnType(FnType);
            const ret_layout = comptime canon.layoutOf(RetT, arch);

            // Resolve export names via `ComponentPlan` when attached, else standard `wit-bindgen` naming
            const plan_exp = if (self.plan) |p|
                (p.findExport(export_name) orelse blk: {
                    if (spec.interface_name.len > 0) {
                        if (std.mem.indexOfScalar(u8, export_name, '#')) |hash_idx| {
                            break :blk p.findInterfaceExport(export_name[0..hash_idx], export_name[hash_idx + 1 ..]);
                        }
                        break :blk p.findInterfaceExport(spec.interface_name, export_name);
                    }
                    break :blk null;
                })
            else
                null;

            if (self.plan != null and plan_exp == null) {
                return error.ExportNotFound;
            }

            const core_export_name = if (plan_exp) |pe| pe.core_export_name else export_name;
            const realloc_export_name = if (plan_exp) |pe|
                (if (pe.realloc_export) |re| re.export_name else self.default_realloc_export)
            else
                self.default_realloc_export;

            const strict_u8_utf8 = self.validate_utf8 and
                (spec.string_encoding_utf8 and (if (plan_exp) |pe| pe.string_encoding == .utf8 else true));

            const op_ctx = LowerLiftCtx{
                .backend = self.backend,
                .allocator = allocator,
                .realloc_export = realloc_export_name,
                .iface = spec.interface_name,
                .validate_utf8 = self.validate_utf8,
                .strict_u8_utf8 = strict_u8_utf8,
            };

            // 1. Lower arguments to core Wasm flat parameters (or indirect spill record)
            var core_params: [cls.core_param_types.len]CoreVal = undefined;
            if (comptime cls.params_spill) {
                const args_addr = try op_ctx.allocAddr(cls.params_record_align, cls.params_record_size);
                try storeToGuest(ArgsT, op_ctx, args_addr, args);
                const flat_addr: FlatAddrT = @bitCast(args_addr);
                core_params[0] = CoreVal.fromZigFlat(arch.flatAddrValType(), flat_addr);
            } else {
                const flat_args = try lowerToFlatGuest(ArgsT, op_ctx, args);
                inline for (cls.core_param_types, 0..) |ft, idx| {
                    core_params[idx] = CoreVal.fromZigFlat(ft, flat_args[idx]);
                }
            }

            // 2. Call guest core Wasm export
            const raw_ret = try self.backend.callCore(
                core_export_name,
                &core_params,
                cls.core_result_type,
            );

            // 3. Schedule `cabi_post_*` cleanup unconditionally after lifting!
            var post_err: ?HostError = null;
            {
                var stack_post_buf: [256]u8 = undefined;
                var heap_post_name: ?[]u8 = null;
                defer if (heap_post_name) |h| allocator.free(h);

                const maybe_post_name: ?[]const u8 = blk: {
                    if (plan_exp) |pe| {
                        break :blk if (pe.post_return_export) |pr| pr.export_name else null;
                    }
                    if (comptime cls.needs_post_return) {
                        const needed = "cabi_post_".len + core_export_name.len;
                        if (needed <= stack_post_buf.len) {
                            break :blk std.fmt.bufPrint(&stack_post_buf, "cabi_post_{s}", .{core_export_name}) catch unreachable;
                        }
                        const s = try allocator.alloc(u8, needed);
                        heap_post_name = s;
                        @memcpy(s[0.."cabi_post_".len], "cabi_post_");
                        @memcpy(s["cabi_post_".len..], core_export_name);
                        break :blk s;
                    }
                    break :blk null;
                };

                defer if (maybe_post_name) |post_name| {
                    self.backend.callPostReturn(post_name, raw_ret) catch |err| {
                        if (post_err == null) post_err = err;
                    };
                };

                // 4. Lift return value from guest flat register or indirect return pointer
                if (comptime RetT == void or ret_layout.flat_count == 0) {
                    if (post_err) |pe| return pe;
                    return;
                }

                if (comptime cls.results_indirect) {
                    const ret_flat = try raw_ret.toZigFlat(arch.flatAddrValType());
                    const ret_addr: AddrT = @bitCast(ret_flat);
                    if ((ret_addr & (ret_layout.alignment - 1)) != 0) {
                        return error.UnalignedPointer;
                    }
                    const lifted = try loadFromGuest(RetT, op_ctx, ret_addr);
                    errdefer switch (@typeInfo(RetT)) {
                        .error_union => |eu| freeValue(eu.payload, allocator, lifted),
                        .error_set => {},
                        else => freeValue(RetT, allocator, lifted),
                    };
                    if (post_err) |pe| return pe;
                    return lifted;
                } else {
                    var flat_ret: canon.FlatTuple(RetT, arch) = undefined;
                    flat_ret[0] = try raw_ret.toZigFlat(ret_layout.flat_types[0]);
                    const lifted = try liftFromFlatGuest(RetT, op_ctx, flat_ret);
                    errdefer switch (@typeInfo(RetT)) {
                        .error_union => |eu| freeValue(eu.payload, allocator, lifted),
                        .error_set => {},
                        else => freeValue(RetT, allocator, lifted),
                    };
                    if (post_err) |pe| return pe;
                    return lifted;
                }
            }
        }

        const LowerLiftCtx = struct {
            backend: GuestMemoryBackend,
            allocator: std.mem.Allocator,
            realloc_export: []const u8,
            iface: []const u8,
            validate_utf8: bool,
            strict_u8_utf8: bool,

            fn allocAddr(self: LowerLiftCtx, alignment: u32, byte_len: u32) HostError!AddrT {
                const raw = try self.backend.alloc(self.realloc_export, alignment, byte_len);
                if (raw > std.math.maxInt(AddrT)) return error.OutOfBounds;
                const end = std.math.add(u64, raw, byte_len) catch return error.OutOfBounds;
                if (arch == .wasm32 and end > (@as(u64, std.math.maxInt(u32)) + 1)) {
                    return error.OutOfBounds;
                }
                return @intCast(raw);
            }

            fn allocAndWriteAddr(self: LowerLiftCtx, alignment: u32, bytes: []const u8) HostError!AddrT {
                const raw = try self.backend.allocAndWrite(self.realloc_export, alignment, bytes);
                if (raw > std.math.maxInt(AddrT)) return error.OutOfBounds;
                const end = std.math.add(u64, raw, bytes.len) catch return error.OutOfBounds;
                if (arch == .wasm32 and end > (@as(u64, std.math.maxInt(u32)) + 1)) {
                    return error.OutOfBounds;
                }
                return @intCast(raw);
            }

            fn checkReadBounds(self: LowerLiftCtx, addr: AddrT, byte_len: u64) HostError!void {
                const start: u64 = addr;
                const end = std.math.add(u64, start, byte_len) catch return error.OutOfBounds;
                const mem_size = try self.backend.memorySize();
                if (end > mem_size) return error.OutOfBounds;
            }
        };

        fn lowerHandleValue(comptime T: type, ctx: LowerLiftCtx, val: T) HostError!i32 {
            const kind_name = @tagName(T.wit_handle_kind);
            const res_name: []const u8 = if (@hasDecl(T, "Resource") and @hasDecl(T.Resource, "resource_name"))
                T.Resource.resource_name
            else
                "";
            if (comptime std.mem.eql(u8, kind_name, "borrow")) {
                return ctx.backend.resourceRep(ctx.iface, res_name, val.handle);
            }
            return val.handle;
        }

        fn lowerSliceData(comptime E: type, ctx: LowerLiftCtx, val: []const E) HostError!AddrT {
            const elem_layout = comptime canon.layoutOf(E, arch);
            if (comptime E == u8) {
                if (ctx.strict_u8_utf8 and !std.unicode.utf8ValidateSlice(val)) {
                    return error.InvalidUtf8;
                }
            }
            if (val.len == 0) {
                return @intCast(elem_layout.alignment);
            }
            const byte_len_u64 = std.math.mul(u64, val.len, elem_layout.size) catch return error.OutOfBounds;
            if (byte_len_u64 > 0x7fff_ffff) return error.OutOfBounds;
            const byte_len: u32 = @intCast(byte_len_u64);

            if (comptime elem_layout.size == 0) {
                return @intCast(elem_layout.alignment);
            }

            if (comptime isHostBlittable(E, arch)) {
                return ctx.allocAndWriteAddr(elem_layout.alignment, std.mem.sliceAsBytes(val));
            }

            // Important: for nested slices/strings inside `E`, lowering `elem` may call
            // `cabi_realloc` and grow guest memory! Allocate the outer array first, then
            // store each element by unsigned `AddrT` offset via `backend.write` (never
            // holding a host slice into guest memory across element lowers!).
            const base_addr = try ctx.allocAddr(elem_layout.alignment, byte_len);
            for (val, 0..) |elem, i| {
                const elem_off: AddrT = @intCast(@as(u64, base_addr) + @as(u64, i) * elem_layout.size);
                try storeToGuest(E, ctx, elem_off, elem);
            }
            return base_addr;
        }

        fn storeToGuest(comptime T: type, ctx: LowerLiftCtx, addr: AddrT, val: T) HostError!void {
            const layout = comptime canon.layoutOf(T, arch);
            if (T == void or layout.size == 0) return;

            if (comptime isHostBlittable(T, arch)) {
                return ctx.backend.write(addr, std.mem.asBytes(&val));
            }

            if (comptime canon.isCharType(T)) {
                const cp: u21 = if (@typeInfo(T) == .@"enum") @intFromEnum(val) else val;
                _ = try canon.validateChar(cp);
                var buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &buf, cp, .little);
                return ctx.backend.write(addr, &buf);
            }

            switch (@typeInfo(T)) {
                .bool => {
                    const b: [1]u8 = .{if (val) 1 else 0};
                    return ctx.backend.write(addr, &b);
                },
                .int => |int| switch (int.bits) {
                    8 => {
                        const b: [1]u8 = .{@bitCast(val)};
                        return ctx.backend.write(addr, &b);
                    },
                    16 => {
                        var b: [2]u8 = undefined;
                        std.mem.writeInt(T, &b, val, .little);
                        return ctx.backend.write(addr, &b);
                    },
                    32 => {
                        var b: [4]u8 = undefined;
                        std.mem.writeInt(T, &b, val, .little);
                        return ctx.backend.write(addr, &b);
                    },
                    64 => {
                        var b: [8]u8 = undefined;
                        std.mem.writeInt(T, &b, val, .little);
                        return ctx.backend.write(addr, &b);
                    },
                    else => unreachable,
                },
                .float => |fl| switch (fl.bits) {
                    32 => {
                        var b: [4]u8 = undefined;
                        std.mem.writeInt(u32, &b, @bitCast(canonicalizeF32(val)), .little);
                        return ctx.backend.write(addr, &b);
                    },
                    64 => {
                        var b: [8]u8 = undefined;
                        std.mem.writeInt(u64, &b, @bitCast(canonicalizeF64(val)), .little);
                        return ctx.backend.write(addr, &b);
                    },
                    else => unreachable,
                },
                .@"enum" => {
                    const idx = canon.enumToIndex(T, val);
                    switch (layout.size) {
                        1 => {
                            const b: [1]u8 = .{@intCast(idx)};
                            return ctx.backend.write(addr, &b);
                        },
                        2 => {
                            var b: [2]u8 = undefined;
                            std.mem.writeInt(u16, &b, @intCast(idx), .little);
                            return ctx.backend.write(addr, &b);
                        },
                        4 => {
                            var b: [4]u8 = undefined;
                            std.mem.writeInt(u32, &b, idx, .little);
                            return ctx.backend.write(addr, &b);
                        },
                        else => unreachable,
                    }
                },
                .pointer => |pt| switch (pt.size) {
                    .slice => {
                        if (val.len > std.math.maxInt(AddrT)) return error.OutOfBounds;
                        const data_addr = try lowerSliceData(pt.child, ctx, val);
                        var pair: [2 * @sizeOf(AddrT)]u8 = undefined;
                        std.mem.writeInt(AddrT, pair[0..@sizeOf(AddrT)], data_addr, .little);
                        std.mem.writeInt(AddrT, pair[@sizeOf(AddrT) .. 2 * @sizeOf(AddrT)], @intCast(val.len), .little);
                        return ctx.backend.write(addr, &pair);
                    },
                    else => unreachable,
                },
                .array => |ar| {
                    const el = comptime canon.layoutOf(ar.child, arch);
                    for (val, 0..) |elem, i| {
                        try storeToGuest(ar.child, ctx, addr + @as(AddrT, @intCast(i * el.size)), elem);
                    }
                },
                .@"struct" => |st| {
                    if (comptime canon.isHandleType(T)) {
                        const raw_h = try lowerHandleValue(T, ctx, val);
                        var b: [4]u8 = undefined;
                        std.mem.writeInt(i32, &b, raw_h, .little);
                        return ctx.backend.write(addr, &b);
                    }
                    if (comptime canon.isStringWrapper(T)) {
                        if (ctx.validate_utf8 and !std.unicode.utf8ValidateSlice(val.bytes)) {
                            return error.InvalidUtf8;
                        }
                        return storeToGuest([]const u8, ctx, addr, val.bytes);
                    }
                    if (comptime st.layout == .@"packed") {
                        const BackingInt = st.backing_integer.?;
                        const UnsignedInt = @Int(.unsigned, @bitSizeOf(BackingInt));
                        const raw: UnsignedInt = (@as(UnsignedInt, @bitCast(val))) & (comptime hostPackedFlagsMask(T));
                        var buf: [layout.size]u8 = @splat(0);
                        switch (layout.size) {
                            1 => buf[0] = @intCast(raw),
                            2 => std.mem.writeInt(u16, buf[0..2], @intCast(raw), .little),
                            4 => std.mem.writeInt(u32, buf[0..4], @intCast(raw), .little),
                            else => {
                                inline for (0..layout.flat_count) |w| {
                                    const shift = w * 32;
                                    const word: u32 = if (comptime shift < @bitSizeOf(UnsignedInt))
                                        @truncate(raw >> shift)
                                    else
                                        0;
                                    std.mem.writeInt(u32, buf[w * 4 ..][0..4], word, .little);
                                }
                            },
                        }
                        return ctx.backend.write(addr, &buf);
                    }

                    // Record / tuple: zero-fill struct padding first, then write each field
                    var zero_buf: [layout.size]u8 = @splat(0);
                    try ctx.backend.write(addr, &zero_buf);
                    inline for (st.field_names, st.field_types, st.field_attrs, 0..) |fname, FT, fattr, f_idx| {
                        if (!fattr.@"comptime") {
                            const f_off = comptime canon.fieldOffset(T, arch, f_idx);
                            try storeToGuest(FT, ctx, addr + f_off, @field(val, fname));
                        }
                    }
                },
                .optional => |op| {
                    var zero_buf: [layout.size]u8 = @splat(0);
                    if (val) |inner| {
                        zero_buf[0] = 1;
                        try ctx.backend.write(addr, &zero_buf);
                        const pay_off = comptime canon.optionPayloadOffset(T, arch);
                        try storeToGuest(op.child, ctx, addr + pay_off, inner);
                    } else {
                        try ctx.backend.write(addr, &zero_buf);
                    }
                },
                .@"union" => |un| {
                    var zero_buf: [layout.size]u8 = @splat(0);
                    const disc_size = comptime canon.variantDiscSize(un.field_names.len);
                    const pay_off = comptime canon.variantPayloadOffset(T, arch);
                    const active_tag = std.meta.activeTag(val);
                    inline for (un.field_names, un.field_types, 0..) |fname, CaseT, case_idx| {
                        if (active_tag == @field(un.tag_type.?, fname)) {
                            switch (disc_size) {
                                1 => zero_buf[0] = @intCast(case_idx),
                                2 => std.mem.writeInt(u16, zero_buf[0..2], @intCast(case_idx), .little),
                                4 => std.mem.writeInt(u32, zero_buf[0..4], @intCast(case_idx), .little),
                                else => unreachable,
                            }
                            try ctx.backend.write(addr, &zero_buf);
                            try storeToGuest(CaseT, ctx, addr + pay_off, @field(val, fname));
                            return;
                        }
                    }
                    unreachable;
                },
                .error_set => {
                    const idx = errorToIndex(T, val);
                    switch (layout.size) {
                        1 => {
                            const b: [1]u8 = .{@intCast(idx)};
                            return ctx.backend.write(addr, &b);
                        },
                        2 => {
                            var b: [2]u8 = undefined;
                            std.mem.writeInt(u16, &b, @intCast(idx), .little);
                            return ctx.backend.write(addr, &b);
                        },
                        4 => {
                            var b: [4]u8 = undefined;
                            std.mem.writeInt(u32, &b, idx, .little);
                            return ctx.backend.write(addr, &b);
                        },
                        else => unreachable,
                    }
                },
                .error_union => |eu| {
                    var zero_buf: [layout.size]u8 = @splat(0);
                    const pay_off = comptime canon.variantPayloadOffset(T, arch);
                    if (val) |ok_val| {
                        zero_buf[0] = 0;
                        try ctx.backend.write(addr, &zero_buf);
                        try storeToGuest(eu.payload, ctx, addr + pay_off, ok_val);
                    } else |err_val| {
                        zero_buf[0] = 1;
                        try ctx.backend.write(addr, &zero_buf);
                        try storeToGuest(eu.error_set, ctx, addr + pay_off, err_val);
                    }
                },
                else => unreachable,
            }
        }

        fn lowerToFlatGuest(comptime T: type, ctx: LowerLiftCtx, val: T) HostError!canon.FlatTuple(T, arch) {
            const layout = comptime canon.layoutOf(T, arch);
            if (T == void) return .{};

            if (comptime canon.isCharType(T)) {
                const cp: u21 = if (@typeInfo(T) == .@"enum") @intFromEnum(val) else val;
                _ = try canon.validateChar(cp);
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
                .float => |fl| switch (fl.bits) {
                    32 => .{canonicalizeF32(val)},
                    64 => .{canonicalizeF64(val)},
                    else => unreachable,
                },
                .@"enum" => .{@as(i32, @intCast(canon.enumToIndex(T, val)))},
                .pointer => |pt| switch (pt.size) {
                    .slice => blk: {
                        if (val.len > std.math.maxInt(AddrT)) return error.OutOfBounds;
                        const data_addr = try lowerSliceData(pt.child, ctx, val);
                        const p_flat: FlatAddrT = @bitCast(data_addr);
                        const l_flat: FlatAddrT = @bitCast(@as(AddrT, @intCast(val.len)));
                        break :blk .{ p_flat, l_flat };
                    },
                    else => unreachable,
                },
                .array => |ar| blk: {
                    var out: canon.FlatTuple(T, arch) = undefined;
                    const el = comptime canon.layoutOf(ar.child, arch);
                    inline for (0..ar.len) |i| {
                        const sub = try lowerToFlatGuest(ar.child, ctx, val[i]);
                        inline for (0..el.flat_count) |j| {
                            out[i * el.flat_count + j] = sub[j];
                        }
                    }
                    break :blk out;
                },
                .@"struct" => |st| blk: {
                    if (comptime canon.isHandleType(T)) {
                        const raw_h = try lowerHandleValue(T, ctx, val);
                        break :blk .{raw_h};
                    }
                    if (comptime canon.isStringWrapper(T)) {
                        if (ctx.validate_utf8 and !std.unicode.utf8ValidateSlice(val.bytes)) {
                            return error.InvalidUtf8;
                        }
                        break :blk try lowerToFlatGuest([]const u8, ctx, val.bytes);
                    }
                    if (comptime st.layout == .@"packed") {
                        const BackingInt = st.backing_integer.?;
                        const UnsignedInt = @Int(.unsigned, @bitSizeOf(BackingInt));
                        const raw: UnsignedInt = (@as(UnsignedInt, @bitCast(val))) & (comptime hostPackedFlagsMask(T));
                        var out: canon.FlatTuple(T, arch) = undefined;
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

                    var out: canon.FlatTuple(T, arch) = undefined;
                    comptime var cursor: usize = 0;
                    inline for (st.field_names, st.field_types, st.field_attrs) |fname, FT, fattr| {
                        if (!fattr.@"comptime") {
                            const fl = comptime canon.layoutOf(FT, arch);
                            const sub = try lowerToFlatGuest(FT, ctx, @field(val, fname));
                            inline for (0..fl.flat_count) |j| {
                                out[cursor + j] = sub[j];
                            }
                            cursor += fl.flat_count;
                        }
                    }
                    break :blk out;
                },
                .optional => |op| blk: {
                    var out: canon.FlatTuple(T, arch) = undefined;
                    const pl = comptime canon.layoutOf(op.child, arch);
                    if (val) |inner| {
                        out[0] = 1;
                        const sub = try lowerToFlatGuest(op.child, ctx, inner);
                        inline for (0..pl.flat_count) |j| {
                            out[1 + j] = sub[j];
                        }
                    } else {
                        out[0] = 0;
                        inline for (0..pl.flat_count) |j| {
                            out[1 + j] = canon.zeroFlatVal(pl.flat_types[j]);
                        }
                    }
                    break :blk out;
                },
                .@"union" => |un| blk: {
                    var out: canon.FlatTuple(T, arch) = undefined;
                    const active_tag = std.meta.activeTag(val);
                    inline for (un.field_names, un.field_types, 0..) |fname, CaseT, case_idx| {
                        if (active_tag == @field(un.tag_type.?, fname)) {
                            out[0] = @intCast(case_idx);
                            const cl = comptime canon.layoutOf(CaseT, arch);
                            const sub = try lowerToFlatGuest(CaseT, ctx, @field(val, fname));
                            inline for (0..cl.flat_count) |j| {
                                out[1 + j] = canon.coerceToJoinedSlot(cl.flat_types[j], layout.flat_types[1 + j], sub[j]);
                            }
                            inline for (cl.flat_count .. layout.flat_count - 1) |j| {
                                out[1 + j] = canon.zeroFlatVal(layout.flat_types[1 + j]);
                            }
                            break :blk out;
                        }
                    }
                    unreachable;
                },
                .error_set => .{@as(i32, @intCast(errorToIndex(T, val)))},
                .error_union => |eu| blk: {
                    var out: canon.FlatTuple(T, arch) = undefined;
                    if (val) |ok_val| {
                        out[0] = 0;
                        const cl = comptime canon.layoutOf(eu.payload, arch);
                        const sub = try lowerToFlatGuest(eu.payload, ctx, ok_val);
                        inline for (0..cl.flat_count) |j| {
                            out[1 + j] = canon.coerceToJoinedSlot(cl.flat_types[j], layout.flat_types[1 + j], sub[j]);
                        }
                        inline for (cl.flat_count .. layout.flat_count - 1) |j| {
                            out[1 + j] = canon.zeroFlatVal(layout.flat_types[1 + j]);
                        }
                    } else |err_val| {
                        out[0] = 1;
                        const err_i32: i32 = @intCast(errorToIndex(eu.error_set, err_val));
                        out[1] = canon.coerceToJoinedSlot(.i32, layout.flat_types[1], err_i32);
                        inline for (1 .. layout.flat_count - 1) |j| {
                            out[1 + j] = canon.zeroFlatVal(layout.flat_types[1 + j]);
                        }
                    }
                    break :blk out;
                },
                else => unreachable,
            };
        }

        fn liftSliceFromGuest(
            comptime SliceT: type,
            ctx: LowerLiftCtx,
            data_addr: AddrT,
            len_addr: AddrT,
        ) HostError!SliceT {
            const pt = @typeInfo(SliceT).pointer;
            const E = pt.child;
            const elem_layout = comptime canon.layoutOf(E, arch);

            if ((data_addr & (elem_layout.alignment - 1)) != 0) {
                return error.UnalignedPointer;
            }

            const len: usize = std.math.cast(usize, len_addr) orelse return error.OutOfBounds;
            const byte_len = std.math.mul(u64, @as(u64, len_addr), elem_layout.size) catch return error.OutOfBounds;
            try ctx.checkReadBounds(data_addr, byte_len);

            if (comptime E == u8 and pt.sentinel_ptr != null) {
                const sent = @as(*const u8, @ptrCast(@alignCast(pt.sentinel_ptr.?))).*;
                const buf = try ctx.allocator.allocSentinel(u8, len, sent);
                errdefer ctx.allocator.free(buf);
                if (len > 0) {
                    try ctx.backend.read(data_addr, buf[0..len]);
                    if (ctx.strict_u8_utf8 and !std.unicode.utf8ValidateSlice(buf[0..len])) {
                        return error.InvalidUtf8;
                    }
                }
                return buf;
            }

            if (len == 0) {
                return &.{};
            }

            const out = try ctx.allocator.alloc(E, len);
            errdefer ctx.allocator.free(out);

            if (comptime elem_layout.size == 0) {
                @memset(out, undefined);
                return out;
            }

            if (comptime isHostBlittable(E, arch)) {
                const out_bytes = std.mem.sliceAsBytes(out);
                try ctx.backend.read(data_addr, out_bytes);
                if (comptime E == u8) {
                    if (ctx.strict_u8_utf8 and !std.unicode.utf8ValidateSlice(out)) {
                        return error.InvalidUtf8;
                    }
                }
                return out;
            }

            var initialized: usize = 0;
            errdefer if (comptime typeNeedsHostFree(E)) {
                for (out[0..initialized]) |elem| {
                    freeValue(E, ctx.allocator, elem);
                }
            };

            for (0..len) |i| {
                const elem_addr: AddrT = @intCast(@as(u64, data_addr) + @as(u64, i) * elem_layout.size);
                out[i] = try loadFromGuest(E, ctx, elem_addr);
                initialized += 1;
            }
            return out;
        }

        fn loadFromGuest(comptime T: type, ctx: LowerLiftCtx, addr: AddrT) (switch (@typeInfo(T)) {
            .error_union => |eu| (HostError || eu.error_set)!eu.payload,
            .error_set => (HostError || T)!void,
            else => HostError!T,
        }) {
            const layout = comptime canon.layoutOf(T, arch);
            try ctx.checkReadBounds(addr, layout.size);

            if (T == void) return;

            if (comptime isHostBlittable(T, arch)) {
                var out: T = undefined;
                if (layout.size > 0) {
                    try ctx.backend.read(addr, std.mem.asBytes(&out));
                }
                return out;
            }

            if (comptime canon.isCharType(T)) {
                var b: [4]u8 = undefined;
                try ctx.backend.read(addr, &b);
                const raw = std.mem.readInt(u32, &b, .little);
                const cp = try canon.validateChar(raw);
                return if (@typeInfo(T) == .@"enum") @enumFromInt(cp) else cp;
            }

            switch (@typeInfo(T)) {
                .bool => {
                    var b: [1]u8 = undefined;
                    try ctx.backend.read(addr, &b);
                    return b[0] != 0;
                },
                .int => |int| switch (int.bits) {
                    8 => {
                        var b: [1]u8 = undefined;
                        try ctx.backend.read(addr, &b);
                        return @bitCast(b[0]);
                    },
                    16 => {
                        var b: [2]u8 = undefined;
                        try ctx.backend.read(addr, &b);
                        return std.mem.readInt(T, &b, .little);
                    },
                    32 => {
                        var b: [4]u8 = undefined;
                        try ctx.backend.read(addr, &b);
                        return std.mem.readInt(T, &b, .little);
                    },
                    64 => {
                        var b: [8]u8 = undefined;
                        try ctx.backend.read(addr, &b);
                        return std.mem.readInt(T, &b, .little);
                    },
                    else => unreachable,
                },
                .float => |fl| switch (fl.bits) {
                    32 => {
                        var b: [4]u8 = undefined;
                        try ctx.backend.read(addr, &b);
                        const v: f32 = @bitCast(std.mem.readInt(u32, &b, .little));
                        return canonicalizeF32(v);
                    },
                    64 => {
                        var b: [8]u8 = undefined;
                        try ctx.backend.read(addr, &b);
                        const v: f64 = @bitCast(std.mem.readInt(u64, &b, .little));
                        return canonicalizeF64(v);
                    },
                    else => unreachable,
                },
                .@"enum" => {
                    const raw: u32 = switch (layout.size) {
                        1 => blk: {
                            var b: [1]u8 = undefined;
                            try ctx.backend.read(addr, &b);
                            break :blk b[0];
                        },
                        2 => blk: {
                            var b: [2]u8 = undefined;
                            try ctx.backend.read(addr, &b);
                            break :blk std.mem.readInt(u16, &b, .little);
                        },
                        4 => blk: {
                            var b: [4]u8 = undefined;
                            try ctx.backend.read(addr, &b);
                            break :blk std.mem.readInt(u32, &b, .little);
                        },
                        else => unreachable,
                    };
                    return try canon.intToEnum(T, raw);
                },
                .pointer => |pt| switch (pt.size) {
                    .slice => {
                        var pair: [2 * @sizeOf(AddrT)]u8 = undefined;
                        try ctx.backend.read(addr, &pair);
                        const data_addr = std.mem.readInt(AddrT, pair[0..@sizeOf(AddrT)], .little);
                        const len_addr = std.mem.readInt(AddrT, pair[@sizeOf(AddrT) .. 2 * @sizeOf(AddrT)], .little);
                        return try liftSliceFromGuest(T, ctx, data_addr, len_addr);
                    },
                    else => unreachable,
                },
                .array => |ar| {
                    var out: T = undefined;
                    const el = comptime canon.layoutOf(ar.child, arch);
                    var initialized: usize = 0;
                    errdefer if (comptime typeNeedsHostFree(ar.child)) {
                        for (out[0..initialized]) |elem| {
                            freeValue(ar.child, ctx.allocator, elem);
                        }
                    };
                    for (0..ar.len) |i| {
                        out[i] = try loadFromGuest(ar.child, ctx, addr + @as(AddrT, @intCast(i * el.size)));
                        initialized += 1;
                    }
                    return out;
                },
                .@"struct" => |st| {
                    if (comptime canon.isHandleType(T)) {
                        var b: [4]u8 = undefined;
                        try ctx.backend.read(addr, &b);
                        return .{ .handle = std.mem.readInt(i32, &b, .little) };
                    }
                    if (comptime canon.isStringWrapper(T)) {
                        var sub_ctx = ctx;
                        sub_ctx.strict_u8_utf8 = ctx.validate_utf8;
                        const bytes = try loadFromGuest([]const u8, sub_ctx, addr);
                        return .{ .bytes = bytes };
                    }
                    if (comptime st.layout == .@"packed") {
                        const BackingInt = st.backing_integer.?;
                        const UnsignedInt = @Int(.unsigned, @bitSizeOf(BackingInt));
                        if (layout.size == 0) return @bitCast(@as(UnsignedInt, 0));
                        var buf: [layout.size]u8 = undefined;
                        try ctx.backend.read(addr, &buf);
                        var raw: UnsignedInt = switch (layout.size) {
                            1 => @intCast(buf[0]),
                            2 => @intCast(std.mem.readInt(u16, buf[0..2], .little)),
                            4 => @intCast(std.mem.readInt(u32, buf[0..4], .little)),
                            else => blk: {
                                var acc: UnsignedInt = 0;
                                inline for (0..layout.flat_count) |w| {
                                    const shift = w * 32;
                                    if (comptime shift < @bitSizeOf(UnsignedInt)) {
                                        const word = std.mem.readInt(u32, buf[w * 4 ..][0..4], .little);
                                        acc |= (@as(UnsignedInt, word) << shift);
                                    }
                                }
                                break :blk acc;
                            },
                        };
                        raw &= comptime hostPackedFlagsMask(T);
                        return @bitCast(@as(BackingInt, @bitCast(raw)));
                    }

                    var out: T = undefined;
                    comptime var built_fields: usize = 0;
                    inline for (st.field_names, st.field_types, st.field_attrs, 0..) |fname, FT, fattr, f_idx| {
                        if (!fattr.@"comptime") {
                            const f_off = comptime canon.fieldOffset(T, arch, f_idx);
                            @field(out, fname) = loadFromGuest(FT, ctx, addr + f_off) catch |err| {
                                inline for (0..built_fields) |prev_idx| {
                                    if (!st.field_attrs[prev_idx].@"comptime" and comptime typeNeedsHostFree(st.field_types[prev_idx])) {
                                        freeValue(st.field_types[prev_idx], ctx.allocator, @field(out, st.field_names[prev_idx]));
                                    }
                                }
                                return err;
                            };
                        }
                        built_fields += 1;
                    }
                    return out;
                },
                .optional => |op| {
                    var b: [1]u8 = undefined;
                    try ctx.backend.read(addr, &b);
                    return switch (b[0]) {
                        0 => null,
                        1 => try loadFromGuest(op.child, ctx, addr + (comptime canon.optionPayloadOffset(T, arch))),
                        else => error.InvalidDiscriminant,
                    };
                },
                .@"union" => |un| {
                    const disc_size = comptime canon.variantDiscSize(un.field_names.len);
                    const pay_off = comptime canon.variantPayloadOffset(T, arch);
                    const disc: u32 = switch (disc_size) {
                        1 => blk: {
                            var b: [1]u8 = undefined;
                            try ctx.backend.read(addr, &b);
                            break :blk b[0];
                        },
                        2 => blk: {
                            var b: [2]u8 = undefined;
                            try ctx.backend.read(addr, &b);
                            break :blk std.mem.readInt(u16, &b, .little);
                        },
                        4 => blk: {
                            var b: [4]u8 = undefined;
                            try ctx.backend.read(addr, &b);
                            break :blk std.mem.readInt(u32, &b, .little);
                        },
                        else => unreachable,
                    };
                    inline for (un.field_names, un.field_types, 0..) |fname, CaseT, case_idx| {
                        if (disc == case_idx) {
                            const payload = try loadFromGuest(CaseT, ctx, addr + pay_off);
                            return @unionInit(T, fname, payload);
                        }
                    }
                    return error.InvalidDiscriminant;
                },
                .error_set => {
                    const raw: u32 = switch (layout.size) {
                        1 => blk: {
                            var b: [1]u8 = undefined;
                            try ctx.backend.read(addr, &b);
                            break :blk b[0];
                        },
                        2 => blk: {
                            var b: [2]u8 = undefined;
                            try ctx.backend.read(addr, &b);
                            break :blk std.mem.readInt(u16, &b, .little);
                        },
                        4 => blk: {
                            var b: [4]u8 = undefined;
                            try ctx.backend.read(addr, &b);
                            break :blk std.mem.readInt(u32, &b, .little);
                        },
                        else => unreachable,
                    };
                    return try raiseErrorByIndex(T, raw);
                },
                .error_union => |eu| {
                    var b: [1]u8 = undefined;
                    try ctx.backend.read(addr, &b);
                    const pay_off = comptime canon.variantPayloadOffset(T, arch);
                    switch (b[0]) {
                        0 => return try loadFromGuest(eu.payload, ctx, addr + pay_off),
                        1 => {
                            try loadFromGuest(eu.error_set, ctx, addr + pay_off);
                            unreachable;
                        },
                        else => return error.InvalidDiscriminant,
                    }
                },
                else => unreachable,
            }
        }

        fn liftFromFlatGuest(
            comptime T: type,
            ctx: LowerLiftCtx,
            flat: canon.FlatTuple(T, arch),
        ) (switch (@typeInfo(T)) {
            .error_union => |eu| (HostError || eu.error_set)!eu.payload,
            .error_set => (HostError || T)!void,
            else => HostError!T,
        }) {
            const layout = comptime canon.layoutOf(T, arch);
            if (T == void) return;

            if (comptime canon.isCharType(T)) {
                const raw: u32 = @bitCast(flat[0]);
                const cp = try canon.validateChar(raw);
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
                .float => |fl| return switch (fl.bits) {
                    32 => canonicalizeF32(flat[0]),
                    64 => canonicalizeF64(flat[0]),
                    else => unreachable,
                },
                .@"enum" => {
                    const raw: u32 = @bitCast(flat[0]);
                    return try canon.intToEnum(T, raw);
                },
                .pointer => |pt| switch (pt.size) {
                    .slice => {
                        const data_addr: AddrT = @bitCast(flat[0]);
                        const len_addr: AddrT = @bitCast(flat[1]);
                        return try liftSliceFromGuest(T, ctx, data_addr, len_addr);
                    },
                    else => unreachable,
                },
                .array => |ar| {
                    var out: T = undefined;
                    const el = comptime canon.layoutOf(ar.child, arch);
                    inline for (0..ar.len) |i| {
                        var sub: canon.FlatTuple(ar.child, arch) = undefined;
                        inline for (0..el.flat_count) |j| {
                            sub[j] = flat[i * el.flat_count + j];
                        }
                        out[i] = try liftFromFlatGuest(ar.child, ctx, sub);
                    }
                    return out;
                },
                .@"struct" => |st| {
                    if (comptime canon.isHandleType(T)) {
                        return .{ .handle = flat[0] };
                    }
                    if (comptime canon.isStringWrapper(T)) {
                        var sub_ctx = ctx;
                        sub_ctx.strict_u8_utf8 = ctx.validate_utf8;
                        const s = try liftFromFlatGuest([]const u8, sub_ctx, flat);
                        return .{ .bytes = s };
                    }
                    if (comptime st.layout == .@"packed") {
                        const BackingInt = st.backing_integer.?;
                        const UnsignedInt = @Int(.unsigned, @bitSizeOf(BackingInt));
                        var raw: UnsignedInt = 0;
                        inline for (0..layout.flat_count) |w| {
                            const shift = w * 32;
                            if (comptime shift < @bitSizeOf(UnsignedInt)) {
                                const word: u32 = @bitCast(flat[w]);
                                raw |= (@as(UnsignedInt, word) << shift);
                            }
                        }
                        raw &= comptime hostPackedFlagsMask(T);
                        return @bitCast(@as(BackingInt, @bitCast(raw)));
                    }

                    var out: T = undefined;
                    comptime var cursor: usize = 0;
                    inline for (st.field_names, st.field_types, st.field_attrs) |fname, FT, fattr| {
                        if (!fattr.@"comptime") {
                            const fl = comptime canon.layoutOf(FT, arch);
                            var sub: canon.FlatTuple(FT, arch) = undefined;
                            inline for (0..fl.flat_count) |j| {
                                sub[j] = flat[cursor + j];
                            }
                            @field(out, fname) = try liftFromFlatGuest(FT, ctx, sub);
                            cursor += fl.flat_count;
                        }
                    }
                    return out;
                },
                .optional => |op| {
                    const disc: u32 = @bitCast(flat[0]);
                    switch (disc) {
                        0 => return null,
                        1 => {
                            const pl = comptime canon.layoutOf(op.child, arch);
                            var sub: canon.FlatTuple(op.child, arch) = undefined;
                            inline for (0..pl.flat_count) |j| {
                                sub[j] = flat[1 + j];
                            }
                            return try liftFromFlatGuest(op.child, ctx, sub);
                        },
                        else => return error.InvalidDiscriminant,
                    }
                },
                .@"union" => |un| {
                    const disc: u32 = @bitCast(flat[0]);
                    inline for (un.field_names, un.field_types, 0..) |fname, CaseT, case_idx| {
                        if (disc == case_idx) {
                            const cl = comptime canon.layoutOf(CaseT, arch);
                            var sub: canon.FlatTuple(CaseT, arch) = undefined;
                            inline for (0..cl.flat_count) |j| {
                                sub[j] = canon.uncoerceFromJoinedSlot(cl.flat_types[j], layout.flat_types[1 + j], flat[1 + j]);
                            }
                            return @unionInit(T, fname, try liftFromFlatGuest(CaseT, ctx, sub));
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
                            const cl = comptime canon.layoutOf(eu.payload, arch);
                            var sub: canon.FlatTuple(eu.payload, arch) = undefined;
                            inline for (0..cl.flat_count) |j| {
                                sub[j] = canon.uncoerceFromJoinedSlot(cl.flat_types[j], layout.flat_types[1 + j], flat[1 + j]);
                            }
                            return try liftFromFlatGuest(eu.payload, ctx, sub);
                        },
                        1 => {
                            const err_i32 = canon.uncoerceFromJoinedSlot(.i32, layout.flat_types[1], flat[1]);
                            const raw: u32 = @bitCast(err_i32);
                            return try raiseErrorByIndex(eu.error_set, raw);
                        },
                        else => return error.InvalidDiscriminant,
                    }
                },
                else => unreachable,
            }
        }
    };
}

// ── Backend 1: Pure-Zig Mock Guest WASM Memory Backend ──────────────────────

pub const MockGuestBackend = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    /// Optional high guest base address (e.g. `0x8000_0000` for testing `>= 2 GiB` unsigned
    /// Wasm32 pointers without allocating 2 GiB of physical host RAM).
    virtual_base_offset: u64 = 0,
    bump_cursor: u64 = 64,
    /// When true, EVERY `cabi_realloc` allocates a brand-new host buffer, copies
    /// live bytes, poisons the old buffer with `0xdd`, and frees it — deterministically
    /// reproducing WebAssembly `memory.grow` buffer detachment on every allocation!
    grow_on_every_alloc: bool = false,
    alloc_count: usize = 0,
    grow_count: usize = 0,
    post_return_count: usize = 0,
    last_post_return_val: CoreVal = .{ .void = {} },
    resources: HostResourceTable,

    user_ctx: ?*anyopaque = null,
    on_call_core: ?*const fn (
        self: *MockGuestBackend,
        export_name: []const u8,
        params: []const CoreVal,
        expected_result: ?canon.FlatValType,
    ) HostError!CoreVal = null,
    on_post_return: ?*const fn (
        self: *MockGuestBackend,
        post_export_name: []const u8,
        raw_result: CoreVal,
    ) HostError!void = null,

    pub const InitOptions = struct {
        initial_bytes: usize = 4096,
        virtual_base_offset: u64 = 0,
        initial_bump_offset: u64 = 64,
        grow_on_every_alloc: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) !MockGuestBackend {
        const buf = try allocator.alloc(u8, opts.initial_bytes);
        @memset(buf, 0);
        return .{
            .allocator = allocator,
            .buffer = buf,
            .virtual_base_offset = opts.virtual_base_offset,
            .bump_cursor = opts.virtual_base_offset + opts.initial_bump_offset,
            .grow_on_every_alloc = opts.grow_on_every_alloc,
            .resources = HostResourceTable.init(allocator),
        };
    }

    pub fn deinit(self: *MockGuestBackend) void {
        self.resources.deinit();
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    pub fn backend(self: *MockGuestBackend) GuestMemoryBackend {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    pub fn guestSlice(self: *MockGuestBackend, guest_addr: u64, len: usize) HostError![]u8 {
        if (guest_addr < self.virtual_base_offset) return error.OutOfBounds;
        const rel = guest_addr - self.virtual_base_offset;
        const end = std.math.add(u64, rel, len) catch return error.OutOfBounds;
        if (end > self.buffer.len) return error.OutOfBounds;
        return self.buffer[@intCast(rel)..@intCast(end)];
    }

    pub fn forceRelocateAndGrow(self: *MockGuestBackend, min_rel_end: usize) HostError!void {
        var new_cap = @max(self.buffer.len + 256, min_rel_end);
        new_cap = std.mem.alignForward(usize, new_cap, 256);
        const new_buf = try self.allocator.alloc(u8, new_cap);
        @memset(new_buf, 0);
        @memcpy(new_buf[0..self.buffer.len], self.buffer);
        @memset(self.buffer, 0xdd);
        self.allocator.free(self.buffer);
        self.buffer = new_buf;
        self.grow_count += 1;
    }

    pub fn guestAlloc(self: *MockGuestBackend, alignment: u32, byte_len: u32) HostError!u64 {
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.AlignmentError;
        self.alloc_count += 1;
        if (byte_len == 0) return self.virtual_base_offset + alignment;

        const mask: u64 = alignment - 1;
        const aligned = (self.bump_cursor + mask) & ~mask;
        const next_cursor = std.math.add(u64, aligned, byte_len) catch return error.OutOfBounds;
        const rel_end = std.math.cast(usize, next_cursor - self.virtual_base_offset) orelse return error.OutOfBounds;

        if (self.grow_on_every_alloc or rel_end > self.buffer.len) {
            try self.forceRelocateAndGrow(rel_end);
        }
        self.bump_cursor = next_cursor;
        return aligned;
    }

    const vtable = GuestMemoryBackend.VTable{
        .alloc = vtableAlloc,
        .write = vtableWrite,
        .read = vtableRead,
        .memory_size = vtableMemSize,
        .call_core = vtableCallCore,
        .call_post_return = vtablePostReturn,
        .resource_new = vtableResourceNew,
        .resource_rep = vtableResourceRep,
        .resource_drop = vtableResourceDrop,
        .live_resource_count = vtableLiveResources,
    };

    fn vtableAlloc(ctx: *anyopaque, _realloc: []const u8, alignment: u32, byte_len: u32) HostError!u64 {
        _ = _realloc;
        const self: *MockGuestBackend = @ptrCast(@alignCast(ctx));
        return self.guestAlloc(alignment, byte_len);
    }

    fn vtableWrite(ctx: *anyopaque, guest_addr: u64, bytes: []const u8) HostError!void {
        const self: *MockGuestBackend = @ptrCast(@alignCast(ctx));
        const dst = try self.guestSlice(guest_addr, bytes.len);
        @memcpy(dst, bytes);
    }

    fn vtableRead(ctx: *anyopaque, guest_addr: u64, out: []u8) HostError!void {
        const self: *MockGuestBackend = @ptrCast(@alignCast(ctx));
        const src = try self.guestSlice(guest_addr, out.len);
        @memcpy(out, src);
    }

    fn vtableMemSize(ctx: *anyopaque) HostError!u64 {
        const self: *MockGuestBackend = @ptrCast(@alignCast(ctx));
        return self.virtual_base_offset + self.buffer.len;
    }

    fn vtableCallCore(
        ctx: *anyopaque,
        export_name: []const u8,
        params: []const CoreVal,
        expected_result: ?canon.FlatValType,
    ) HostError!CoreVal {
        const self: *MockGuestBackend = @ptrCast(@alignCast(ctx));
        const handler = self.on_call_core orelse return error.CoreExportNotFound;
        return handler(self, export_name, params, expected_result);
    }

    fn vtablePostReturn(ctx: *anyopaque, post_export_name: []const u8, raw_result: CoreVal) HostError!void {
        const self: *MockGuestBackend = @ptrCast(@alignCast(ctx));
        self.post_return_count += 1;
        self.last_post_return_val = raw_result;
        if (self.on_post_return) |cb| {
            try cb(self, post_export_name, raw_result);
        }
    }

    fn vtableResourceNew(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, rep: i32) HostError!i32 {
        const self: *MockGuestBackend = @ptrCast(@alignCast(ctx));
        return self.resources.insert(iface, resource_name, rep);
    }

    fn vtableResourceRep(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, handle: i32) HostError!i32 {
        const self: *MockGuestBackend = @ptrCast(@alignCast(ctx));
        return self.resources.rep(iface, resource_name, handle);
    }

    fn vtableResourceDrop(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, handle: i32) HostError!void {
        const self: *MockGuestBackend = @ptrCast(@alignCast(ctx));
        return self.resources.drop(iface, resource_name, handle);
    }

    fn vtableLiveResources(ctx: *anyopaque) u32 {
        const self: *MockGuestBackend = @ptrCast(@alignCast(ctx));
        return self.resources.liveCount();
    }
};

// ── Backend 2: WASM Extern Bridge (`zigar:component-host` imports) ──────────

pub const WasmExternBackend = struct {
    instance_id: u32 = 1,

    const raw = struct {
        extern "zigar:component-host" fn alloc(
            inst_id: u32,
            realloc_ptr: [*]const u8,
            realloc_len: usize,
            align_bytes: u32,
            byte_len: u32,
            out_addr: *u32,
        ) u32;
        extern "zigar:component-host" fn write(
            inst_id: u32,
            guest_addr: u32,
            src_ptr: [*]const u8,
            byte_len: usize,
        ) u32;
        extern "zigar:component-host" fn read(
            inst_id: u32,
            guest_addr: u32,
            dst_ptr: [*]u8,
            byte_len: usize,
        ) u32;
        extern "zigar:component-host" fn memory_size(inst_id: u32) u64;
        extern "zigar:component-host" fn call_core(
            inst_id: u32,
            exp_ptr: [*]const u8,
            exp_len: usize,
            params_ptr: [*]const ExternCoreVal,
            params_count: usize,
            expected_ret_tag: u32,
            result_ptr: *ExternCoreVal,
        ) u32;
        extern "zigar:component-host" fn call_post_return(
            inst_id: u32,
            exp_ptr: [*]const u8,
            exp_len: usize,
            val_tag: u32,
            val_bits: u64,
        ) u32;
        extern "zigar:component-host" fn resource_new(
            inst_id: u32,
            iface_ptr: [*]const u8,
            iface_len: usize,
            res_ptr: [*]const u8,
            res_len: usize,
            rep: i32,
        ) i32;
        extern "zigar:component-host" fn resource_rep(
            inst_id: u32,
            iface_ptr: [*]const u8,
            iface_len: usize,
            res_ptr: [*]const u8,
            res_len: usize,
            handle: i32,
            out_rep: *i32,
        ) u32;
        extern "zigar:component-host" fn resource_drop(
            inst_id: u32,
            iface_ptr: [*]const u8,
            iface_len: usize,
            res_ptr: [*]const u8,
            res_len: usize,
            handle: i32,
        ) u32;
        extern "zigar:component-host" fn live_resource_count(inst_id: u32) u32;
    };

    pub const ExternCoreVal = extern struct {
        tag: u32,
        _pad: u32 = 0,
        bits: u64,
    };

    pub fn init(instance_id: u32) WasmExternBackend {
        return .{ .instance_id = instance_id };
    }

    pub fn backend(self: *WasmExternBackend) GuestMemoryBackend {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    const vtable = GuestMemoryBackend.VTable{
        .alloc = vtableAlloc,
        .write = vtableWrite,
        .read = vtableRead,
        .memory_size = vtableMemSize,
        .call_core = vtableCallCore,
        .call_post_return = vtablePostReturn,
        .resource_new = vtableResourceNew,
        .resource_rep = vtableResourceRep,
        .resource_drop = vtableResourceDrop,
        .live_resource_count = vtableLiveResources,
    };

    fn vtableAlloc(ctx: *anyopaque, realloc_export: []const u8, alignment: u32, byte_len: u32) HostError!u64 {
        const self: *WasmExternBackend = @ptrCast(@alignCast(ctx));
        var out_addr: u32 = 0;
        const rc = raw.alloc(self.instance_id, realloc_export.ptr, realloc_export.len, alignment, byte_len, &out_addr);
        if (rc != 0) return error.ReallocFailed;
        return out_addr;
    }

    fn vtableWrite(ctx: *anyopaque, guest_addr: u64, bytes: []const u8) HostError!void {
        const self: *WasmExternBackend = @ptrCast(@alignCast(ctx));
        const addr32 = std.math.cast(u32, guest_addr) orelse return error.OutOfBounds;
        if (raw.write(self.instance_id, addr32, bytes.ptr, bytes.len) != 0) {
            return error.OutOfBounds;
        }
    }

    fn vtableRead(ctx: *anyopaque, guest_addr: u64, out: []u8) HostError!void {
        const self: *WasmExternBackend = @ptrCast(@alignCast(ctx));
        const addr32 = std.math.cast(u32, guest_addr) orelse return error.OutOfBounds;
        if (raw.read(self.instance_id, addr32, out.ptr, out.len) != 0) {
            return error.OutOfBounds;
        }
    }

    fn vtableMemSize(ctx: *anyopaque) HostError!u64 {
        const self: *WasmExternBackend = @ptrCast(@alignCast(ctx));
        return raw.memory_size(self.instance_id);
    }

    fn vtableCallCore(
        ctx: *anyopaque,
        export_name: []const u8,
        params: []const CoreVal,
        expected_result: ?canon.FlatValType,
    ) HostError!CoreVal {
        const self: *WasmExternBackend = @ptrCast(@alignCast(ctx));
        var stack_params: [32]ExternCoreVal = undefined;
        if (params.len > stack_params.len) return error.BackendCallFailed;
        for (params, 0..) |p, idx| {
            stack_params[idx] = .{
                .tag = @intFromEnum(std.meta.activeTag(p)),
                .bits = p.toRawBits(),
            };
        }
        var out_res: ExternCoreVal = .{ .tag = 0, .bits = 0 };
        const rc = raw.call_core(
            self.instance_id,
            export_name.ptr,
            export_name.len,
            &stack_params,
            params.len,
            @intFromEnum(CoreValTag.fromFlatValType(expected_result)),
            &out_res,
        );
        if (rc != 0) return error.BackendCallFailed;
        const tag: CoreValTag = std.enums.fromInt(CoreValTag, out_res.tag) orelse return error.BackendCallFailed;
        return CoreVal.fromTagAndBits(tag, out_res.bits);
    }

    fn vtablePostReturn(ctx: *anyopaque, post_export_name: []const u8, raw_result: CoreVal) HostError!void {
        const self: *WasmExternBackend = @ptrCast(@alignCast(ctx));
        const rc = raw.call_post_return(
            self.instance_id,
            post_export_name.ptr,
            post_export_name.len,
            @intFromEnum(std.meta.activeTag(raw_result)),
            raw_result.toRawBits(),
        );
        if (rc != 0) return error.PostReturnNotFound;
    }

    fn vtableResourceNew(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, rep: i32) HostError!i32 {
        const self: *WasmExternBackend = @ptrCast(@alignCast(ctx));
        const h = raw.resource_new(self.instance_id, iface.ptr, iface.len, resource_name.ptr, resource_name.len, rep);
        if (h < 0) return error.InvalidResourceHandle;
        return h;
    }

    fn vtableResourceRep(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, handle: i32) HostError!i32 {
        const self: *WasmExternBackend = @ptrCast(@alignCast(ctx));
        var rep: i32 = 0;
        const rc = raw.resource_rep(self.instance_id, iface.ptr, iface.len, resource_name.ptr, resource_name.len, handle, &rep);
        if (rc != 0) return error.InvalidResourceHandle;
        return rep;
    }

    fn vtableResourceDrop(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, handle: i32) HostError!void {
        const self: *WasmExternBackend = @ptrCast(@alignCast(ctx));
        const rc = raw.resource_drop(self.instance_id, iface.ptr, iface.len, resource_name.ptr, resource_name.len, handle);
        if (rc != 0) return error.DoubleDropResource;
    }

    fn vtableLiveResources(ctx: *anyopaque) u32 {
        const self: *WasmExternBackend = @ptrCast(@alignCast(ctx));
        return raw.live_resource_count(self.instance_id);
    }
};

// ── Backend 3: Zigar JS Function Callback Struct (`createZigarCallbacks`) ───

pub const ZigarCoreCallResult = extern struct {
    status: u32 = 0,
    tag: u32 = 0,
    bits: u64 = 0,
};

pub const ZigarReadChunk = extern struct {
    status: u32 = 0,
    len: u32 = 0,
    data: [4096]u8 = @splat(0),
};

pub const ZigarCallbacks = struct {
    alloc: *const fn (realloc_name: []const u8, align_bytes: u32, byte_len: u32) i64,
    write: *const fn (guest_addr: u32, bytes: []const u8) bool,
    read_chunk: *const fn (guest_addr: u32, byte_len: u32) ZigarReadChunk,
    memory_size: *const fn () u64,
    call_core: *const fn (
        export_name: []const u8,
        encoded_params: []const u8,
        expected_ret_tag: u32,
    ) ZigarCoreCallResult,
    call_post_return: *const fn (export_name: []const u8, val_tag: u32, val_bits: u64) bool,
    resource_new: *const fn (iface: []const u8, resource_name: []const u8, rep: i32) i32,
    resource_rep: *const fn (iface: []const u8, resource_name: []const u8, handle: i32) i64,
    resource_drop: *const fn (iface: []const u8, resource_name: []const u8, handle: i32) bool,
    live_resource_count: *const fn () u32,
};

pub const ZigarCallbacksBackend = struct {
    callbacks: ZigarCallbacks,

    pub fn init(callbacks: ZigarCallbacks) ZigarCallbacksBackend {
        return .{
            .callbacks = callbacks,
        };
    }

    pub fn backend(self: *ZigarCallbacksBackend) GuestMemoryBackend {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    const vtable = GuestMemoryBackend.VTable{
        .alloc = vtableAlloc,
        .write = vtableWrite,
        .read = vtableRead,
        .memory_size = vtableMemSize,
        .call_core = vtableCallCore,
        .call_post_return = vtablePostReturn,
        .resource_new = vtableResourceNew,
        .resource_rep = vtableResourceRep,
        .resource_drop = vtableResourceDrop,
        .live_resource_count = vtableLiveResources,
    };

    fn vtableAlloc(ctx: *anyopaque, realloc_export: []const u8, alignment: u32, byte_len: u32) HostError!u64 {
        const self: *ZigarCallbacksBackend = @ptrCast(@alignCast(ctx));
        const res = self.callbacks.alloc(realloc_export, alignment, byte_len);
        if (res < 0) return error.ReallocFailed;
        return @intCast(res);
    }

    fn vtableWrite(ctx: *anyopaque, guest_addr: u64, bytes: []const u8) HostError!void {
        const self: *ZigarCallbacksBackend = @ptrCast(@alignCast(ctx));
        const addr32 = std.math.cast(u32, guest_addr) orelse return error.OutOfBounds;
        if (!self.callbacks.write(addr32, bytes)) return error.OutOfBounds;
    }

    fn vtableRead(ctx: *anyopaque, guest_addr: u64, out: []u8) HostError!void {
        if (out.len == 0) return;
        const self: *ZigarCallbacksBackend = @ptrCast(@alignCast(ctx));
        var done: usize = 0;
        while (done < out.len) {
            const cur_addr = std.math.add(u64, guest_addr, done) catch return error.OutOfBounds;
            const addr32 = std.math.cast(u32, cur_addr) orelse return error.OutOfBounds;
            const chunk_len: u32 = @intCast(@min(out.len - done, 4096));
            const chunk = self.callbacks.read_chunk(addr32, chunk_len);
            if (chunk.status != 1 or chunk.len != chunk_len) return error.OutOfBounds;
            @memcpy(out[done .. done + chunk_len], chunk.data[0..chunk_len]);
            done += chunk_len;
        }
    }

    fn vtableMemSize(ctx: *anyopaque) HostError!u64 {
        const self: *ZigarCallbacksBackend = @ptrCast(@alignCast(ctx));
        return self.callbacks.memory_size();
    }

    fn vtableCallCore(
        ctx: *anyopaque,
        export_name: []const u8,
        params: []const CoreVal,
        expected_result: ?canon.FlatValType,
    ) HostError!CoreVal {
        const self: *ZigarCallbacksBackend = @ptrCast(@alignCast(ctx));
        var encoded: [32 * 16]u8 = @splat(0);
        if (params.len > 32) return error.BackendCallFailed;
        for (params, 0..) |p, idx| {
            std.mem.writeInt(u32, encoded[idx * 16 ..][0..4], @intFromEnum(std.meta.activeTag(p)), .little);
            std.mem.writeInt(u64, encoded[idx * 16 + 8 ..][0..8], p.toRawBits(), .little);
        }
        const raw_out = self.callbacks.call_core(
            export_name,
            encoded[0 .. params.len * 16],
            @intFromEnum(CoreValTag.fromFlatValType(expected_result)),
        );
        if (raw_out.status != 1) return error.BackendCallFailed;
        const tag: CoreValTag = std.enums.fromInt(CoreValTag, raw_out.tag) orelse return error.BackendCallFailed;
        return CoreVal.fromTagAndBits(tag, raw_out.bits);
    }

    fn vtablePostReturn(ctx: *anyopaque, post_export_name: []const u8, raw_result: CoreVal) HostError!void {
        const self: *ZigarCallbacksBackend = @ptrCast(@alignCast(ctx));
        if (!self.callbacks.call_post_return(
            post_export_name,
            @intFromEnum(std.meta.activeTag(raw_result)),
            raw_result.toRawBits(),
        )) return error.PostReturnNotFound;
    }

    fn vtableResourceNew(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, rep: i32) HostError!i32 {
        const self: *ZigarCallbacksBackend = @ptrCast(@alignCast(ctx));
        const h = self.callbacks.resource_new(iface, resource_name, rep);
        if (h < 0) return error.InvalidResourceHandle;
        return h;
    }

    fn vtableResourceRep(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, handle: i32) HostError!i32 {
        const self: *ZigarCallbacksBackend = @ptrCast(@alignCast(ctx));
        const r = self.callbacks.resource_rep(iface, resource_name, handle);
        if (r < 0) return error.InvalidResourceHandle;
        return @bitCast(@as(u32, @truncate(@as(u64, @intCast(r)))));
    }

    fn vtableResourceDrop(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, handle: i32) HostError!void {
        const self: *ZigarCallbacksBackend = @ptrCast(@alignCast(ctx));
        if (!self.callbacks.resource_drop(iface, resource_name, handle)) {
            return error.DoubleDropResource;
        }
    }

    fn vtableLiveResources(ctx: *anyopaque) u32 {
        const self: *ZigarCallbacksBackend = @ptrCast(@alignCast(ctx));
        return self.callbacks.live_resource_count();
    }
};

// ── Backend 4: Native Zig <-> Node 26 V8 WebAssembly Stdio RPC Backend ──────

pub const NodeProcessBackend = if (has_process_support) struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    cached_mem_size: u64,
    cached_live_resources: u32 = 0,
    page_cache: std.AutoHashMapUnmanaged(u32, *[PAGE_SIZE]u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    const PAGE_SHIFT = 18;
    const PAGE_SIZE: usize = 1 << PAGE_SHIFT; // 256 KiB demand-paged read cache
    const embedded_node_rpc_worker_mjs = @embedFile("node_rpc_worker.mjs");

    const OP_ALLOC: u8 = 0x01;
    const OP_WRITE: u8 = 0x02;
    const OP_ALLOC_WRITE: u8 = 0x03;
    const OP_READ: u8 = 0x04;
    const OP_MEM_SIZE: u8 = 0x05;
    const OP_CALL_CORE: u8 = 0x06;
    const OP_POST_RETURN: u8 = 0x07;
    const OP_RESOURCE_NEW: u8 = 0x08;
    const OP_RESOURCE_REP: u8 = 0x09;
    const OP_RESOURCE_DROP: u8 = 0x0a;
    const OP_LIVE_RESOURCES: u8 = 0x0b;
    const OP_SHUTDOWN: u8 = 0xff;

    pub const SpawnOptions = struct {
        wasm_path: []const u8,
        node_binary: []const u8 = "node",
        /// Optional path to `zigar-compiler/src/component-host.js`. When null,
        /// passes the embedded ESM worker directly via `node --input-type=module -e`
        /// with zero temporary files on disk.
        runner_script_path: ?[]const u8 = null,
    };

    pub const spawn = init;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: SpawnOptions) !NodeProcessBackend {
        const child = if (opts.runner_script_path) |script_path|
            try std.process.spawn(io, .{
                .argv = &.{ opts.node_binary, "--no-warnings", script_path, "--rpc-stdio", opts.wasm_path },
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            })
        else
            try std.process.spawn(io, .{
                .argv = &.{
                    opts.node_binary,
                    "--no-warnings",
                    "--input-type=module",
                    "-e",
                    embedded_node_rpc_worker_mjs,
                    "--",
                    "--rpc-stdio",
                    opts.wasm_path,
                },
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            });
        var self = NodeProcessBackend{
            .allocator = allocator,
            .io = io,
            .child = child,
            .cached_mem_size = 0,
        };
        errdefer self.killAndClean();

        var handshake: [16]u8 = undefined;
        try self.readExact(&handshake);
        if (!std.mem.eql(u8, handshake[0..4], "ZCH1")) {
            return error.HandshakeFailed;
        }
        const status = std.mem.readInt(u32, handshake[4..8], .little);
        const size_or_len = std.mem.readInt(u64, handshake[8..16], .little);
        if (status != 0) {
            if (size_or_len > 0 and size_or_len <= 65536) {
                const err_buf = try allocator.alloc(u8, @intCast(size_or_len));
                defer allocator.free(err_buf);
                self.readExact(err_buf) catch {};
            }
            return error.HandshakeFailed;
        }
        self.cached_mem_size = size_or_len;
        return self;
    }

    pub fn deinit(self: *NodeProcessBackend) void {
        self.clearPageCache();
        self.page_cache.deinit(self.allocator);
        self.scratch.deinit(self.allocator);

        if (self.child.stdin != null) {
            var shutdown_hdr: [8]u8 = @splat(0);
            shutdown_hdr[0] = OP_SHUTDOWN;
            if (self.child.stdin.?.writeStreamingAll(self.io, &shutdown_hdr)) |_| {
                var resp_hdr: [8]u8 = undefined;
                self.readExact(&resp_hdr) catch {};
            } else |_| {}
            self.child.stdin.?.close(self.io);
            self.child.stdin = null;
        }
        _ = self.child.wait(self.io) catch {
            self.child.kill(self.io);
        };
        self.* = undefined;
    }

    fn killAndClean(self: *NodeProcessBackend) void {
        self.clearPageCache();
        self.page_cache.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.child.kill(self.io);
    }

    pub fn backend(self: *NodeProcessBackend) GuestMemoryBackend {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    fn clearPageCache(self: *NodeProcessBackend) void {
        var it = self.page_cache.valueIterator();
        while (it.next()) |page_ptr| {
            self.allocator.destroy(page_ptr.*);
        }
        self.page_cache.clearRetainingCapacity();
    }

    fn writeAll(self: *NodeProcessBackend, bytes: []const u8) HostError!void {
        const stdin = self.child.stdin orelse return error.BackendIoError;
        stdin.writeStreamingAll(self.io, bytes) catch return error.BackendIoError;
    }

    fn readExact(self: *NodeProcessBackend, buf: []u8) HostError!void {
        const stdout = self.child.stdout orelse return error.BackendIoError;
        var filled: usize = 0;
        while (filled < buf.len) {
            const n = stdout.readStreaming(self.io, &.{buf[filled..]}) catch return error.BackendIoError;
            if (n == 0) return error.EndOfStream;
            filled += n;
        }
    }

    const RespHeader = struct {
        status: u8,
        val_tag: u8,
        flags: u16,
        payload_len: u32,
    };

    fn sendHeaderAndPayload(self: *NodeProcessBackend, opcode: u8, req_flags: u8, payload: []const u8) HostError!RespHeader {
        var hdr: [8]u8 = @splat(0);
        hdr[0] = opcode;
        hdr[1] = req_flags;
        std.mem.writeInt(u32, hdr[4..8], @intCast(payload.len), .little);
        try self.writeAll(&hdr);
        if (payload.len > 0) {
            try self.writeAll(payload);
        }
        var resp: [8]u8 = undefined;
        try self.readExact(&resp);
        const rh = RespHeader{
            .status = resp[0],
            .val_tag = resp[1],
            .flags = std.mem.readInt(u16, resp[2..4], .little),
            .payload_len = std.mem.readInt(u32, resp[4..8], .little),
        };
        if (rh.status != 0) {
            if (rh.payload_len > 0) {
                try self.scratch.resize(self.allocator, rh.payload_len);
                self.readExact(self.scratch.items) catch {};
            }
            return error.BackendCallFailed;
        }
        return rh;
    }

    fn rawReadFromRpc(self: *NodeProcessBackend, addr32: u32, out: []u8) HostError!void {
        var req: [8]u8 = undefined;
        std.mem.writeInt(u32, req[0..4], addr32, .little);
        std.mem.writeInt(u32, req[4..8], @intCast(out.len), .little);
        const rh = try self.sendHeaderAndPayload(OP_READ, 0, &req);
        if (rh.payload_len != 8 + out.len) return error.BackendIoError;
        var mem_sz_buf: [8]u8 = undefined;
        try self.readExact(&mem_sz_buf);
        self.cached_mem_size = std.mem.readInt(u64, &mem_sz_buf, .little);
        if (out.len > 0) {
            try self.readExact(out);
        }
    }

    const vtable = GuestMemoryBackend.VTable{
        .alloc = vtableAlloc,
        .write = vtableWrite,
        .alloc_and_write = vtableAllocAndWrite,
        .read = vtableRead,
        .memory_size = vtableMemSize,
        .call_core = vtableCallCore,
        .call_post_return = vtablePostReturn,
        .resource_new = vtableResourceNew,
        .resource_rep = vtableResourceRep,
        .resource_drop = vtableResourceDrop,
        .live_resource_count = vtableLiveResources,
    };

    fn vtableAlloc(ctx: *anyopaque, realloc_export: []const u8, alignment: u32, byte_len: u32) HostError!u64 {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        self.clearPageCache();
        const total = 8 + realloc_export.len;
        try self.scratch.resize(self.allocator, total);
        std.mem.writeInt(u32, self.scratch.items[0..4], alignment, .little);
        std.mem.writeInt(u32, self.scratch.items[4..8], byte_len, .little);
        @memcpy(self.scratch.items[8..total], realloc_export);

        const rh = self.sendHeaderAndPayload(OP_ALLOC, 0, self.scratch.items[0..total]) catch return error.ReallocFailed;
        if (rh.payload_len != 12) return error.BackendIoError;
        var resp_buf: [12]u8 = undefined;
        try self.readExact(&resp_buf);
        const addr = std.mem.readInt(u32, resp_buf[0..4], .little);
        self.cached_mem_size = std.mem.readInt(u64, resp_buf[4..12], .little);
        return addr;
    }

    fn vtableWrite(ctx: *anyopaque, guest_addr: u64, bytes: []const u8) HostError!void {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        const addr32 = std.math.cast(u32, guest_addr) orelse return error.OutOfBounds;
        self.clearPageCache();

        var hdr: [12]u8 = @splat(0);
        hdr[0] = OP_WRITE;
        std.mem.writeInt(u32, hdr[4..8], @intCast(4 + bytes.len), .little);
        std.mem.writeInt(u32, hdr[8..12], addr32, .little);
        try self.writeAll(&hdr);
        if (bytes.len > 0) {
            try self.writeAll(bytes);
        }
        var resp: [8]u8 = undefined;
        try self.readExact(&resp);
        if (resp[0] != 0) {
            const plen = std.mem.readInt(u32, resp[4..8], .little);
            if (plen > 0) {
                try self.scratch.resize(self.allocator, plen);
                self.readExact(self.scratch.items) catch {};
            }
            return error.OutOfBounds;
        }
    }

    fn vtableAllocAndWrite(ctx: *anyopaque, realloc_export: []const u8, alignment: u32, bytes: []const u8) HostError!u64 {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        self.clearPageCache();

        var hdr: [16]u8 = @splat(0);
        hdr[0] = OP_ALLOC_WRITE;
        const payload_len: u32 = @intCast(8 + realloc_export.len + bytes.len);
        std.mem.writeInt(u32, hdr[4..8], payload_len, .little);
        std.mem.writeInt(u32, hdr[8..12], alignment, .little);
        std.mem.writeInt(u16, hdr[12..14], @intCast(realloc_export.len), .little);
        try self.writeAll(&hdr);
        if (realloc_export.len > 0) try self.writeAll(realloc_export);
        if (bytes.len > 0) try self.writeAll(bytes);

        var resp_hdr: [8]u8 = undefined;
        try self.readExact(&resp_hdr);
        const plen = std.mem.readInt(u32, resp_hdr[4..8], .little);
        if (resp_hdr[0] != 0) {
            if (plen > 0) {
                try self.scratch.resize(self.allocator, plen);
                self.readExact(self.scratch.items) catch {};
            }
            return error.ReallocFailed;
        }
        if (plen != 12) return error.BackendIoError;
        var body: [12]u8 = undefined;
        try self.readExact(&body);
        const addr = std.mem.readInt(u32, body[0..4], .little);
        self.cached_mem_size = std.mem.readInt(u64, body[4..12], .little);
        return addr;
    }

    fn vtableRead(ctx: *anyopaque, guest_addr: u64, out: []u8) HostError!void {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        const addr32 = std.math.cast(u32, guest_addr) orelse return error.OutOfBounds;
        const end = std.math.add(u64, guest_addr, out.len) catch return error.OutOfBounds;
        if (end > self.cached_mem_size) return error.OutOfBounds;

        // Large contiguous slices (>= 256 KiB, e.g. multi-megabyte emitted source) stream directly
        if (out.len >= PAGE_SIZE) {
            return self.rawReadFromRpc(addr32, out);
        }

        // Small / medium reads (records, interned string tables, AST nodes) pull through 256 KiB pages
        var remaining = out;
        var cur_addr: u64 = guest_addr;
        while (remaining.len > 0) {
            const page_idx: u32 = @intCast(cur_addr >> PAGE_SHIFT);
            const page_off: usize = @intCast(cur_addr & (PAGE_SIZE - 1));
            const page_base: u64 = @as(u64, page_idx) << PAGE_SHIFT;
            const valid_in_page: usize = @intCast(@min(@as(u64, PAGE_SIZE), self.cached_mem_size - page_base));

            const page_ptr = blk: {
                if (self.page_cache.get(page_idx)) |existing| {
                    break :blk existing;
                }
                const new_page = try self.allocator.create([PAGE_SIZE]u8);
                errdefer self.allocator.destroy(new_page);
                try self.rawReadFromRpc(@intCast(page_base), new_page[0..valid_in_page]);
                try self.page_cache.put(self.allocator, page_idx, new_page);
                break :blk new_page;
            };

            const chunk = @min(remaining.len, valid_in_page - page_off);
            @memcpy(remaining[0..chunk], page_ptr[page_off .. page_off + chunk]);
            remaining = remaining[chunk..];
            cur_addr += chunk;
        }
    }

    fn vtableMemSize(ctx: *anyopaque) HostError!u64 {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        return self.cached_mem_size;
    }

    fn vtableCallCore(
        ctx: *anyopaque,
        export_name: []const u8,
        params: []const CoreVal,
        expected_result: ?canon.FlatValType,
    ) HostError!CoreVal {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        self.clearPageCache();

        const total = 4 + export_name.len + params.len * 12;
        try self.scratch.resize(self.allocator, total);
        @memset(self.scratch.items[0..total], 0);
        std.mem.writeInt(u16, self.scratch.items[0..2], @intCast(export_name.len), .little);
        std.mem.writeInt(u16, self.scratch.items[2..4], @intCast(params.len), .little);
        @memcpy(self.scratch.items[4 .. 4 + export_name.len], export_name);
        const params_base = 4 + export_name.len;
        for (params, 0..) |p, idx| {
            const off = params_base + idx * 12;
            self.scratch.items[off] = @intFromEnum(std.meta.activeTag(p));
            std.mem.writeInt(u64, self.scratch.items[off + 4 ..][0..8], p.toRawBits(), .little);
        }

        const expected_tag: u8 = @intFromEnum(CoreValTag.fromFlatValType(expected_result));
        const rh = try self.sendHeaderAndPayload(OP_CALL_CORE, expected_tag, self.scratch.items[0..total]);
        if (rh.payload_len != 20) return error.BackendIoError;
        var body: [20]u8 = undefined;
        try self.readExact(&body);
        const ret_bits = std.mem.readInt(u64, body[0..8], .little);
        self.cached_mem_size = std.mem.readInt(u64, body[8..16], .little);
        self.cached_live_resources = std.mem.readInt(u32, body[16..20], .little);
        const tag: CoreValTag = std.enums.fromInt(CoreValTag, rh.val_tag) orelse return error.BackendCallFailed;
        return CoreVal.fromTagAndBits(tag, ret_bits);
    }

    fn vtablePostReturn(ctx: *anyopaque, post_export_name: []const u8, raw_result: CoreVal) HostError!void {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        self.clearPageCache();

        const total = 12 + post_export_name.len;
        try self.scratch.resize(self.allocator, total);
        @memset(self.scratch.items[0..12], 0);
        self.scratch.items[0] = @intFromEnum(std.meta.activeTag(raw_result));
        std.mem.writeInt(u64, self.scratch.items[4..12], raw_result.toRawBits(), .little);
        @memcpy(self.scratch.items[12..total], post_export_name);

        const rh = self.sendHeaderAndPayload(OP_POST_RETURN, 0, self.scratch.items[0..total]) catch return error.PostReturnNotFound;
        if (rh.payload_len != 12) return error.BackendIoError;
        var body: [12]u8 = undefined;
        try self.readExact(&body);
        self.cached_mem_size = std.mem.readInt(u64, body[0..8], .little);
        self.cached_live_resources = std.mem.readInt(u32, body[8..12], .little);
    }

    fn vtableResourceNew(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, rep: i32) HostError!i32 {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        const total = 8 + iface.len + resource_name.len;
        try self.scratch.resize(self.allocator, total);
        std.mem.writeInt(i32, self.scratch.items[0..4], rep, .little);
        std.mem.writeInt(u16, self.scratch.items[4..6], @intCast(iface.len), .little);
        std.mem.writeInt(u16, self.scratch.items[6..8], @intCast(resource_name.len), .little);
        @memcpy(self.scratch.items[8 .. 8 + iface.len], iface);
        @memcpy(self.scratch.items[8 + iface.len .. total], resource_name);

        const rh = try self.sendHeaderAndPayload(OP_RESOURCE_NEW, 0, self.scratch.items[0..total]);
        if (rh.payload_len != 8) return error.BackendIoError;
        var body: [8]u8 = undefined;
        try self.readExact(&body);
        const handle = std.mem.readInt(i32, body[0..4], .little);
        self.cached_live_resources = std.mem.readInt(u32, body[4..8], .little);
        return handle;
    }

    fn vtableResourceRep(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, handle: i32) HostError!i32 {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        const total = 8 + iface.len + resource_name.len;
        try self.scratch.resize(self.allocator, total);
        std.mem.writeInt(i32, self.scratch.items[0..4], handle, .little);
        std.mem.writeInt(u16, self.scratch.items[4..6], @intCast(iface.len), .little);
        std.mem.writeInt(u16, self.scratch.items[6..8], @intCast(resource_name.len), .little);
        @memcpy(self.scratch.items[8 .. 8 + iface.len], iface);
        @memcpy(self.scratch.items[8 + iface.len .. total], resource_name);

        const rh = self.sendHeaderAndPayload(OP_RESOURCE_REP, 0, self.scratch.items[0..total]) catch return error.InvalidResourceHandle;
        if (rh.payload_len != 4) return error.BackendIoError;
        var body: [4]u8 = undefined;
        try self.readExact(&body);
        return std.mem.readInt(i32, body[0..4], .little);
    }

    fn vtableResourceDrop(ctx: *anyopaque, iface: []const u8, resource_name: []const u8, handle: i32) HostError!void {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        self.clearPageCache();
        const total = 8 + iface.len + resource_name.len;
        try self.scratch.resize(self.allocator, total);
        std.mem.writeInt(i32, self.scratch.items[0..4], handle, .little);
        std.mem.writeInt(u16, self.scratch.items[4..6], @intCast(iface.len), .little);
        std.mem.writeInt(u16, self.scratch.items[6..8], @intCast(resource_name.len), .little);
        @memcpy(self.scratch.items[8 .. 8 + iface.len], iface);
        @memcpy(self.scratch.items[8 + iface.len .. total], resource_name);

        const rh = self.sendHeaderAndPayload(OP_RESOURCE_DROP, 0, self.scratch.items[0..total]) catch return error.DoubleDropResource;
        if (rh.payload_len != 4) return error.BackendIoError;
        var body: [4]u8 = undefined;
        try self.readExact(&body);
        self.cached_live_resources = std.mem.readInt(u32, body[0..4], .little);
    }

    fn vtableLiveResources(ctx: *anyopaque) u32 {
        const self: *NodeProcessBackend = @ptrCast(@alignCast(ctx));
        return self.cached_live_resources;
    }
} else struct {};

// ── Unit Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "MockGuestBackend mid-lower memory.grow relocates guest buffer safely across multiple strings and lists" {
    const alloc = testing.allocator;

    const FileInput = struct {
        path: []const u8,
        content: []const u8,
        tags: []const u32,
    };
    const BatchFn = fn ([]const FileInput, []const u8) canon.Result([]const u8, []const u8);

    const Handler = struct {
        fn onCall(
            mock: *MockGuestBackend,
            export_name: []const u8,
            params: []const CoreVal,
            _expected: ?canon.FlatValType,
        ) HostError!CoreVal {
            _ = _expected;
            if (!std.mem.eql(u8, export_name, "test:pkg/api#process-batch")) {
                return error.CoreExportNotFound;
            }
            const list_addr: u32 = @bitCast(params[0].i32);
            const list_len: u32 = @bitCast(params[1].i32);
            const suffix_addr: u32 = @bitCast(params[2].i32);
            const suffix_len: u32 = @bitCast(params[3].i32);

            // Concatenate all lowered paths, contents, tag counts, and suffix inside guest memory
            var summary: std.ArrayList(u8) = .empty;
            defer summary.deinit(mock.allocator);

            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const elem_base = @as(u64, list_addr) + @as(u64, i) * 24;
                const elem_bytes = try mock.guestSlice(elem_base, 24);
                const p_addr = std.mem.readInt(u32, elem_bytes[0..4], .little);
                const p_len = std.mem.readInt(u32, elem_bytes[4..8], .little);
                const c_addr = std.mem.readInt(u32, elem_bytes[8..12], .little);
                const c_len = std.mem.readInt(u32, elem_bytes[12..16], .little);
                const t_addr = std.mem.readInt(u32, elem_bytes[16..20], .little);
                const t_len = std.mem.readInt(u32, elem_bytes[20..24], .little);

                const path_s = try mock.guestSlice(p_addr, p_len);
                const content_s = try mock.guestSlice(c_addr, c_len);
                const tags_bytes = try mock.guestSlice(t_addr, t_len * 4);
                const first_tag = if (t_len > 0) std.mem.readInt(u32, tags_bytes[0..4], .little) else 0;

                try summary.print(mock.allocator, "{s}={s}({d});", .{ path_s, content_s, first_tag });
            }
            const suffix_s = try mock.guestSlice(suffix_addr, suffix_len);
            try summary.appendSlice(mock.allocator, suffix_s);

            const out_str_addr: u32 = @intCast(try mock.guestAlloc(1, @intCast(summary.items.len)));
            @memcpy(try mock.guestSlice(out_str_addr, summary.items.len), summary.items);

            // Result<string, string> layout in Wasm32: size=12, align=4 (disc at 0, ptr at 4, len at 8)
            const ret_addr: u32 = @intCast(try mock.guestAlloc(4, 12));
            const ret_slot = try mock.guestSlice(ret_addr, 12);
            @memset(ret_slot, 0);
            ret_slot[0] = 0; // .ok
            std.mem.writeInt(u32, ret_slot[4..8], out_str_addr, .little);
            std.mem.writeInt(u32, ret_slot[8..12], @intCast(summary.items.len), .little);
            return .{ .i32 = @bitCast(ret_addr) };
        }

        fn onPost(mock: *MockGuestBackend, post_name: []const u8, raw_ret: CoreVal) HostError!void {
            if (!std.mem.eql(u8, post_name, "cabi_post_test:pkg/api#process-batch")) {
                return error.PostReturnNotFound;
            }
            // Poison guest return slot during `cabi_post_*` to prove lifted host slices are deep-copied!
            const ret_addr: u32 = @bitCast(raw_ret.i32);
            const ret_slot = try mock.guestSlice(ret_addr, 12);
            const str_addr = std.mem.readInt(u32, ret_slot[4..8], .little);
            const str_len = std.mem.readInt(u32, ret_slot[8..12], .little);
            @memset(try mock.guestSlice(str_addr, str_len), 0xaa);
            @memset(ret_slot, 0xbb);
        }
    };

    var mock = try MockGuestBackend.init(alloc, .{
        .initial_bytes = 128,
        .grow_on_every_alloc = true,
    });
    defer mock.deinit();
    mock.on_call_core = Handler.onCall;
    mock.on_post_return = Handler.onPost;

    const host = ComponentHost.init(mock.backend());
    const inputs = [_]FileInput{
        .{ .path = "/a.ts", .content = "export const a = 1;", .tags = &.{ 10, 20 } },
        .{ .path = "/b.ts", .content = "export const b = 2;", .tags = &.{30} },
        .{ .path = "/c.ts", .content = "export const c = 3;", .tags = &.{ 40, 50, 60 } },
    };

    const res = try host.call(
        BatchFn,
        .{ .interface_name = "test:pkg/api", .string_encoding_utf8 = true },
        alloc,
        "test:pkg/api#process-batch",
        .{ &inputs, "DONE" },
    );
    defer ComponentHost.free(@TypeOf(res), alloc, res);

    // Every single string, tag slice, and outer array allocation triggered a buffer relocation!
    try testing.expect(mock.grow_count >= 10);
    try testing.expectEqual(@as(usize, 1), mock.post_return_count);
    try testing.expect(res == .ok);
    try testing.expectEqualStrings(
        "/a.ts=export const a = 1;(10);/b.ts=export const b = 2;(30);/c.ts=export const c = 3;(40);DONE",
        res.ok,
    );
}

test "ComponentHost preserves unsigned 32-bit guest offsets >= 2 GiB (0x8000_0000+) and runs cabi_post_* on err arms and lift errors" {
    const alloc = testing.allocator;
    const HighFn = fn ([]const u8) canon.Result([]const u8, []const u8);

    const State = struct {
        mode: enum { ok, wit_err, bad_utf8 } = .ok,
    };
    var state = State{};

    const Handler = struct {
        fn onCall(
            mock: *MockGuestBackend,
            _name: []const u8,
            params: []const CoreVal,
            _expected: ?canon.FlatValType,
        ) HostError!CoreVal {
            _ = _name;
            _ = _expected;
            const st: *State = @ptrCast(@alignCast(mock.user_ctx.?));

            // Input pointer must be >= 0x8000_0000 (negative when viewed as signed i32!)
            if (params[0].i32 >= 0) return error.BackendCallFailed;
            const in_addr: u32 = @bitCast(params[0].i32);
            const in_len: u32 = @bitCast(params[1].i32);
            if (in_addr < 0x8000_0000) return error.BackendCallFailed;
            const input_copy = try mock.allocator.dupe(u8, try mock.guestSlice(in_addr, in_len));
            defer mock.allocator.free(input_copy);

            const ret_addr: u32 = @intCast(try mock.guestAlloc(4, 12));
            switch (st.mode) {
                .ok => {
                    const msg = try std.fmt.allocPrint(mock.allocator, "high:{s}", .{input_copy});
                    defer mock.allocator.free(msg);
                    const str_addr: u32 = @intCast(try mock.guestAlloc(1, @intCast(msg.len)));
                    @memcpy(try mock.guestSlice(str_addr, msg.len), msg);
                    const slot = try mock.guestSlice(ret_addr, 12);
                    slot[0] = 0; // .ok
                    std.mem.writeInt(u32, slot[4..8], str_addr, .little);
                    std.mem.writeInt(u32, slot[8..12], @intCast(msg.len), .little);
                },
                .wit_err => {
                    const err_msg = "diagnostic-over-2gib";
                    const str_addr: u32 = @intCast(try mock.guestAlloc(1, err_msg.len));
                    @memcpy(try mock.guestSlice(str_addr, err_msg.len), err_msg);
                    const slot = try mock.guestSlice(ret_addr, 12);
                    slot[0] = 1; // .err
                    std.mem.writeInt(u32, slot[4..8], str_addr, .little);
                    std.mem.writeInt(u32, slot[8..12], err_msg.len, .little);
                },
                .bad_utf8 => {
                    const invalid = [_]u8{ 0xff, 0xfe, 0xfd };
                    const str_addr: u32 = @intCast(try mock.guestAlloc(1, invalid.len));
                    @memcpy(try mock.guestSlice(str_addr, invalid.len), &invalid);
                    const slot = try mock.guestSlice(ret_addr, 12);
                    slot[0] = 0; // .ok with invalid UTF-8
                    std.mem.writeInt(u32, slot[4..8], str_addr, .little);
                    std.mem.writeInt(u32, slot[8..12], invalid.len, .little);
                },
            }
            return .{ .i32 = @bitCast(ret_addr) };
        }
    };

    var mock = try MockGuestBackend.init(alloc, .{
        .initial_bytes = 8192,
        .virtual_base_offset = 0x8000_1000,
        .grow_on_every_alloc = true,
    });
    defer mock.deinit();
    mock.user_ctx = &state;
    mock.on_call_core = Handler.onCall;

    const host = ComponentHost.init(mock.backend());

    // 1. `.ok` arm above 2 GiB
    state.mode = .ok;
    const ok_res = try host.call(HighFn, .{}, alloc, "high-fn", .{"payload"});
    defer ComponentHost.free(@TypeOf(ok_res), alloc, ok_res);
    try testing.expect(ok_res == .ok);
    try testing.expectEqualStrings("high:payload", ok_res.ok);
    try testing.expectEqual(@as(usize, 1), mock.post_return_count);

    // 2. `.err` arm above 2 GiB MUST still invoke `cabi_post_*`
    state.mode = .wit_err;
    const err_res = try host.call(HighFn, .{}, alloc, "high-fn", .{"payload"});
    defer ComponentHost.free(@TypeOf(err_res), alloc, err_res);
    try testing.expect(err_res == .err);
    try testing.expectEqualStrings("diagnostic-over-2gib", err_res.err);
    try testing.expectEqual(@as(usize, 2), mock.post_return_count);

    // 3. Lifting failure (`error.InvalidUtf8`) MUST ALSO invoke `cabi_post_*` without leaking!
    state.mode = .bad_utf8;
    try testing.expectError(error.InvalidUtf8, host.call(HighFn, .{}, alloc, "high-fn", .{"payload"}));
    try testing.expectEqual(@as(usize, 3), mock.post_return_count);
}

test "ComponentHost resource handle table lowers Borrow<T> to guest rep, supports cross-interface borrows, and drops cleanly" {
    const alloc = testing.allocator;

    const DummyVfs = struct {
        pub const resource_name = "vfs";
        pub fn drop(_: canon.Own(@This())) void {}
    };
    const DummyOther = struct {
        pub const resource_name = "other";
        pub fn drop(_: canon.Own(@This())) void {}
    };

    const CtorFn = fn () canon.Own(DummyVfs);
    const BorrowFn = fn (canon.Borrow(DummyVfs), u32) u32;

    const DtorTracker = struct {
        dropped_reps: [4]i32 = @splat(0),
        count: usize = 0,

        fn onDtor(ctx: ?*anyopaque, rep: i32) HostError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.dropped_reps[self.count] = rep;
            self.count += 1;
        }
    };
    var tracker = DtorTracker{};

    const Handler = struct {
        fn onCall(
            mock: *MockGuestBackend,
            export_name: []const u8,
            params: []const CoreVal,
            _expected: ?canon.FlatValType,
        ) HostError!CoreVal {
            _ = _expected;
            if (std.mem.eql(u8, export_name, "pkg:a/compiler#[constructor]vfs")) {
                // Guest allocates internal rep = 777 and registers host handle via `[resource-new]vfs`
                const h = try mock.resources.insert("pkg:a/compiler", "vfs", 777);
                return .{ .i32 = h };
            }
            if (std.mem.eql(u8, export_name, "pkg:a/extractor#inspect-vfs")) {
                // Guest `FromBorrowHandle(rep)` receives `rep == 777` directly, NOT `handle == 1`!
                const rep = params[0].i32;
                const addend: u32 = @bitCast(params[1].i32);
                return .{ .i32 = @bitCast(@as(u32, @intCast(rep)) + addend) };
            }
            return error.CoreExportNotFound;
        }
    };

    var mock = try MockGuestBackend.init(alloc, .{});
    defer mock.deinit();
    mock.on_call_core = Handler.onCall;
    try mock.resources.bindDtor("pkg:a/compiler", "vfs", &tracker, DtorTracker.onDtor);

    const host = ComponentHost.init(mock.backend());
    const owned_vfs = try host.call(
        CtorFn,
        .{ .interface_name = "pkg:a/compiler" },
        alloc,
        "pkg:a/compiler#[constructor]vfs",
        .{},
    );
    try testing.expectEqual(@as(i32, 1), owned_vfs.handle);
    try testing.expectEqual(@as(u32, 1), host.liveResourceCount());

    // Cross-interface borrow (`pkg:a/extractor` borrowing `pkg:a/compiler`'s `vfs`)
    const computed = try host.call(
        BorrowFn,
        .{ .interface_name = "pkg:a/extractor" },
        alloc,
        "pkg:a/extractor#inspect-vfs",
        .{ canon.Borrow(DummyVfs){ .handle = owned_vfs.handle }, 23 },
    );
    try testing.expectEqual(@as(u32, 800), computed);
    try testing.expectEqual(@as(u32, 1), host.liveResourceCount());

    // Wrong resource type must reject borrow & drop
    const wrong_borrow = canon.Borrow(DummyOther){ .handle = owned_vfs.handle };
    try testing.expectError(
        error.ResourceTypeMismatch,
        host.call(
            fn (canon.Borrow(DummyOther), u32) u32,
            .{ .interface_name = "pkg:a/extractor" },
            alloc,
            "pkg:a/extractor#inspect-vfs",
            .{ wrong_borrow, 1 },
        ),
    );
    try testing.expectError(error.ResourceTypeMismatch, host.dropResource("pkg:a/compiler", "other", owned_vfs.handle));

    // Valid drop invokes destructor with `rep == 777` and decrements live count to 0
    try host.dropResource("pkg:a/compiler", "vfs", owned_vfs.handle);
    try testing.expectEqual(@as(u32, 0), host.liveResourceCount());
    try testing.expectEqual(@as(usize, 1), tracker.count);
    try testing.expectEqual(@as(i32, 777), tracker.dropped_reps[0]);

    // Double-drop is rejected cleanly
    try testing.expectError(error.DoubleDropResource, host.dropResource("pkg:a/compiler", "vfs", owned_vfs.handle));
}

test "ComponentPlan unpacks typescript-compiler.component.wasm when available" {
    if (!has_process_support) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const rel_paths = [_][]const u8{
        "../ts-zigar/component/dist/typescript-compiler.component.wasm",
        "ts-zigar/component/dist/typescript-compiler.component.wasm",
    };
    var wasm_bytes: ?[]u8 = null;
    for (rel_paths) |p| {
        if (cwd.readFileAlloc(io, p, testing.allocator, .limited(128 * 1024 * 1024))) |bytes| {
            wasm_bytes = bytes;
            break;
        } else |_| {}
    }
    const bytes = wasm_bytes orelse return; // Optional when running standalone without built component
    defer testing.allocator.free(bytes);

    var plan = try ComponentPlan.fromBytes(testing.allocator, bytes);
    defer plan.deinit();

    try testing.expect(plan.core_modules.len >= 1);
    try testing.expectEqual(@as(?u32, 0), plan.primary_core_module_idx);
    try testing.expect(plan.wasi_imports_needed);

    // Verify all 3 WIT resources (`vfs`, `program`, `checker`) and their `[dtor]` bindings
    const vfs_res = plan.findResource("zigar:typescript/compiler@7.1.0", "vfs") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zigar:typescript/compiler@7.1.0#[dtor]vfs", vfs_res.dtor_export_name.?);
    const prog_res = plan.findResource("zigar:typescript/compiler@7.1.0", "program") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zigar:typescript/compiler@7.1.0#[dtor]program", prog_res.dtor_export_name.?);
    const chk_res = plan.findResource("zigar:typescript/compiler@7.1.0", "checker") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zigar:typescript/compiler@7.1.0#[dtor]checker", chk_res.dtor_export_name.?);

    // Verify canonical exports across both `compiler` and `extractor` interfaces
    const ver_exp = plan.findExport("zigar:typescript/compiler@7.1.0#compiler-version") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("memory", ver_exp.memory_export.?.export_name);
    try testing.expectEqualStrings("cabi_post_zigar:typescript/compiler@7.1.0#compiler-version", ver_exp.post_return_export.?.export_name);

    const vfs_ctor = plan.findInterfaceExport("zigar:typescript/compiler", "[constructor]vfs") orelse return error.TestUnexpectedResult;
    try testing.expect(vfs_ctor.post_return_export == null);

    const create_prog = plan.findInterfaceExport("zigar:typescript/compiler@7.1.0", "create-program") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("cabi_realloc", create_prog.realloc_export.?.export_name);
    try testing.expectEqualStrings("cabi_post_zigar:typescript/compiler@7.1.0#create-program", create_prog.post_return_export.?.export_name);

    const extract_exp = plan.findExport("zigar:typescript/extractor@7.1.0#extract-module-graph") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("memory", extract_exp.memory_export.?.export_name);
    try testing.expectEqualStrings("cabi_realloc", extract_exp.realloc_export.?.export_name);
    try testing.expectEqualStrings("cabi_post_zigar:typescript/extractor@7.1.0#extract-module-graph", extract_exp.post_return_export.?.export_name);
}
