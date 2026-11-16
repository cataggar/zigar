const std = @import("std");
const cli = @import("cli.zig");
const naming = @import("naming.zig");

/// Lowering configuration for `lowerGraph`.
pub const LowerOptions = struct {
    /// Optional VFS base directory stripped from file-module paths when deriving relative module names.
    base_dir: ?[]const u8 = null,
    /// Optional explicit primary VFS entry paths (`-t / --types`). When non-empty and `modules` is
    /// empty, only primary modules are re-exported by `root.zig`, and unreferenced non-primary
    /// modules are pruned via reachability closure.
    primary_vfs_paths: []const []const u8 = &.{},
    /// Optional `-m / --module` filters. Empty means emit primary modules and their dependencies.
    modules: []const []const u8 = &.{},
    /// Optional `-s / --substitute <from=to>` rules.
    substitutions: []const cli.Substitution = &.{},
};

pub const JsDocParamIr = struct {
    name: []const u8,
    description: []const u8,
};

pub const JsDocIr = struct {
    summary: []const u8,
    params: []const JsDocParamIr,
    returns: ?[]const u8,
    deprecated: ?[]const u8,
    throws: []const []const u8,
    examples: []const []const u8,
};

pub const TypeParamIr = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_name: []const u8,
    constraint: ?*const TypeIr,
    default_type: ?*const TypeIr,
};

pub const ParamIr = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_name: []const u8,
    ty: *const TypeIr,
    is_optional: bool,
    is_rest: bool,
};

pub const SignatureIr = struct {
    self_param_ident: ?[]const u8 = null,
    type_params: []const TypeParamIr,
    params: []const ParamIr,
    return_type: *const TypeIr,
    has_type_predicate: bool,
    type_predicate_asserts: bool,
    jsdoc: ?JsDocIr,
};

pub const FieldIr = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_name: []const u8,
    ty: *const TypeIr,
    is_optional: bool,
    is_readonly: bool,
    jsdoc: ?JsDocIr,
};

pub const MethodIr = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_name: []const u8,
    is_static: bool,
    signature: SignatureIr,
    jsdoc: ?JsDocIr,
};

pub const EnumValueIr = union(enum) {
    auto,
    num: f64,
    str: []const u8,
};

pub const EnumMemberIr = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_name: []const u8,
    value: EnumValueIr,
    jsdoc: ?JsDocIr,
};

pub const LiteralValueIr = union(enum) {
    str: []const u8,
    num: f64,
    bigint_val: []const u8,
    boolean: bool,
};

pub const PrimSliceElem = enum {
    i8,
    u16,
    i16,
    u32,
    i32,
    u64,
    i64,
    f32,
    f64,
};

pub const TupleElemIr = struct {
    zig_ident: []const u8,
    wire_label: ?[]const u8,
    ty: *const TypeIr,
    is_optional: bool,
};

pub const UnionVariantIr = struct {
    zig_ident: []const u8,
    wire_tag: []const u8,
    payload: *const TypeIr,
};

pub const FnPtrIr = struct {
    params: []const *const TypeIr,
    return_type: *const TypeIr,
};

pub const DeclRefIr = struct {
    module_index: u32,
    decl_zig_path: []const []const u8,
    target_decl_id: u32,
    type_args: []const *const TypeIr,
    /// Set to true if embedding by value would create a Zig struct/union size dependency cycle.
    indirect: bool = false,
};

pub const TypeIr = union(enum) {
    void_type,
    noreturn_type,
    bool_type,
    f64_type,
    i64_type,
    string_type,
    bytes_type,
    typed_slice: PrimSliceElem,
    js_value,
    js_object,
    js_symbol,
    self_type: []const u8,
    type_param_ref: []const u8,
    optional: *const TypeIr,
    pointer_const: *const TypeIr,
    slice: *const TypeIr,
    promise: *const TypeIr,
    js_map: struct {
        key: *const TypeIr,
        value: *const TypeIr,
    },
    tuple: []const TupleElemIr,
    fn_ptr: FnPtrIr,
    anon_struct: []const FieldIr,
    tagged_union: []const UnionVariantIr,
    decl_ref: DeclRefIr,
};

pub const StaticPropIr = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_name: []const u8,
    ty: *const TypeIr,
    literal: ?LiteralValueIr,
    jsdoc: ?JsDocIr,
};

pub const ConstructorIr = struct {
    zig_ident: []const u8,
    signature: SignatureIr,
    jsdoc: ?JsDocIr,
};

pub const StructDeclIr = struct {
    is_class: bool,
    is_abstract: bool,
    self_ident: []const u8,
    type_params: []const TypeParamIr,
    fields: []const FieldIr,
    static_props: []const StaticPropIr,
    constructors: []const ConstructorIr,
    methods: []const MethodIr,
    nested_decls: []const DeclIr,
};

pub const DeclKindIr = union(enum) {
    function_decl: SignatureIr,
    const_literal: struct {
        ty: *const TypeIr,
        value: LiteralValueIr,
    },
    global_var: *const TypeIr,
    struct_decl: StructDeclIr,
    enum_decl: struct {
        is_const: bool,
        members: []const EnumMemberIr,
    },
    string_enum_decl: []const EnumMemberIr,
    union_decl: struct {
        type_params: []const TypeParamIr,
        variants: []const UnionVariantIr,
    },
    type_alias: struct {
        type_params: []const TypeParamIr,
        target: *const TypeIr,
    },
    namespace_decl: []const DeclIr,
    re_export_decl: struct {
        target_module_index: u32,
        target_zig_path: []const []const u8,
    },
    namespace_re_export: struct {
        target_module_index: u32,
    },
};

pub const DeclIr = struct {
    source_decl_id: ?u32,
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_name: []const u8,
    is_exported: bool,
    is_default_export: bool,
    jsdoc: ?JsDocIr,
    kind: DeclKindIr,
};

pub const ModuleImportIr = struct {
    target_module_index: u32,
    local_alias: []const u8,
    rel_import_path: []const u8,
};

pub const ModuleIr = struct {
    index: u32,
    specifier: []const u8,
    wire_specifier: []const u8,
    rel_zig_path: []const u8,
    root_export_ident: []const u8,
    root_export_logical_name: []const u8,
    is_primary: bool,
    needs_root_runtime: bool,
    imports: []const ModuleImportIr,
    decls: []const DeclIr,
};

pub const PackageIr = struct {
    arena: std.heap.ArenaAllocator,
    modules: []const ModuleIr,

    pub fn deinit(self: *PackageIr) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const LowerError = error{
    OutOfMemory,
    NoMatchingModules,
};

/// Applies `-s / --substitute <from=to>` rules sequentially to a module/namespace specifier.
pub fn applySubstitutions(
    allocator: std.mem.Allocator,
    raw_specifier: []const u8,
    substitutions: []const cli.Substitution,
) ![]u8 {
    var current = try allocator.dupe(u8, raw_specifier);
    errdefer allocator.free(current);

    for (substitutions) |rule| {
        if (std.mem.eql(u8, current, rule.from)) {
            const next = try allocator.dupe(u8, rule.to);
            allocator.free(current);
            current = next;
            continue;
        }
        if (std.mem.startsWith(u8, current, rule.from) and current.len > rule.from.len) {
            const boundary = current[rule.from.len];
            const from_ends_sep = rule.from[rule.from.len - 1] == ':' or
                rule.from[rule.from.len - 1] == '/' or
                rule.from[rule.from.len - 1] == '.';
            if (from_ends_sep or boundary == '/' or boundary == '.' or boundary == ':') {
                const next = try std.fmt.allocPrint(allocator, "{s}{s}", .{
                    rule.to,
                    current[rule.from.len..],
                });
                allocator.free(current);
                current = next;
            }
        }
    }

    return current;
}

fn stripNodePrefix(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "node:")) return s["node:".len..];
    return s;
}

/// Checks whether a candidate module matches a single `-m / --module` filter pattern.
pub fn moduleMatchesPattern(
    wire_spec: []const u8,
    substituted_spec: []const u8,
    pattern: []const u8,
) bool {
    const pat = std.mem.trim(u8, pattern, " \t\r\n");
    if (pat.len == 0) return false;

    const candidates = [_][]const u8{ wire_spec, substituted_spec };
    const pat_no_node = stripNodePrefix(naming.stripModuleExtension(pat));

    for (candidates) |cand_raw| {
        const cand = naming.stripModuleExtension(cand_raw);
        if (std.mem.eql(u8, cand_raw, pat) or std.mem.eql(u8, cand, pat)) return true;
        const cand_no_node = stripNodePrefix(cand);
        if (std.mem.eql(u8, cand_no_node, pat_no_node)) return true;

        // Also match normalized '.' <-> '/' namespace vs path spelling (e.g. monaco.editor <-> monaco/editor).
        if (cand_no_node.len == pat_no_node.len) {
            var eq_norm = true;
            for (cand_no_node, pat_no_node) |ca, cb| {
                const na: u8 = if (ca == '.') '/' else ca;
                const nb: u8 = if (cb == '.') '/' else cb;
                if (na != nb) {
                    eq_norm = false;
                    break;
                }
            }
            if (eq_norm) return true;
        }
    }
    return false;
}

/// Lowers any `DeclarationGraph` value generated from `zigar:typescript@7.1.0` (`types.DeclarationGraph`
/// across native/wasm32/wasm64 bindgen instantiations) into a normalized, cycle-safe `PackageIr`.
pub fn lowerGraph(
    backing_allocator: std.mem.Allocator,
    graph: anytype,
    options: LowerOptions,
) LowerError!PackageIr {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var ctx = LowerCtx(@TypeOf(graph)){
        .alloc = alloc,
        .scratch = backing_allocator,
        .graph = graph,
        .options = options,
    };
    defer ctx.deinitScratch();

    const modules = try ctx.build();
    return .{
        .arena = arena,
        .modules = modules,
    };
}

fn LowerCtx(comptime GraphType: type) type {
    return struct {
        const Self = @This();

        const ForeignExportEntry = struct {
            decl_id: u32,
            wire_name_override: ?[]const u8 = null,
            is_default_export: bool = false,
        };

        const CandidateModule = struct {
            wire_specifier: []const u8,
            substituted_specifier: []const u8,
            rel_zig_path: []const u8,
            source_mod_ids: std.ArrayList(u32) = .empty,
            decl_ids: std.ArrayList(u32) = .empty,
            exported_decl_ids: std.ArrayList(u32) = .empty,
            foreign_exports: std.ArrayList(ForeignExportEntry) = .empty,
            star_re_export_source_mods: std.ArrayList(u32) = .empty,
            star_re_export_specs: std.ArrayList([]const u8) = .empty,
            is_primary: bool = false,
            included: bool = false,
        };

        const DeclLocation = struct {
            module_index: u32,
            zig_path: []const []const u8,
            type_param_defaults: []const ?u32,
        };

        const ActiveTypeParam = struct {
            ts_name: []const u8,
            zig_ident: []const u8,
        };

        const StarExportItem = struct {
            decl_id: u32,
            wire_name_override: ?[]const u8 = null,
        };

        const PlannedReExport = struct {
            source_decl_id: u32,
            zig_ident: []const u8,
            logical_name: []const u8,
            wire_name: []const u8,
            is_default_export: bool,
            target_module_index: u32,
            target_zig_path: []const []const u8,
        };

        const LoweredTypeParams = struct {
            ir: []TypeParamIr,
            active: []ActiveTypeParam,
        };

        alloc: std.mem.Allocator,
        scratch: std.mem.Allocator,
        graph: GraphType,
        options: LowerOptions,

        candidates: std.ArrayList(CandidateModule) = .empty,
        source_mod_to_cand: std.AutoHashMapUnmanaged(u32, u32) = .empty,
        decl_locations: std.AutoHashMapUnmanaged(u32, DeclLocation) = .empty,
        merged_ns_consumed: std.AutoHashMapUnmanaged(u32, void) = .empty,
        ns_child_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
        decl_to_cand: std.AutoHashMapUnmanaged(u32, u32) = .empty,
        cand_to_final_map: ?[]?u32 = null,

        fn deinitScratch(self: *Self) void {
            for (self.candidates.items) |*c| {
                c.source_mod_ids.deinit(self.scratch);
                c.decl_ids.deinit(self.scratch);
                c.exported_decl_ids.deinit(self.scratch);
                c.foreign_exports.deinit(self.scratch);
                c.star_re_export_source_mods.deinit(self.scratch);
                c.star_re_export_specs.deinit(self.scratch);
            }
            self.candidates.deinit(self.scratch);
            self.source_mod_to_cand.deinit(self.scratch);
            self.decl_locations.deinit(self.scratch);
            self.merged_ns_consumed.deinit(self.scratch);
            self.ns_child_ids.deinit(self.scratch);
            self.decl_to_cand.deinit(self.scratch);
        }

        fn str(self: *const Self, id: u32) []const u8 {
            if (id < self.graph.strings.len) return self.graph.strings[id];
            return "";
        }

        fn isPrimaryVfsPath(self: *const Self, fp: []const u8) bool {
            if (fp.len == 0) return false;
            for (self.options.primary_vfs_paths) |p| {
                if (std.mem.eql(u8, p, fp)) return true;
            }
            return false;
        }

        fn normalizeExternalNodeModulesSubpath(self: *Self, nm_rel: []const u8) ![]const u8 {
            const pkg_rel = if (std.mem.startsWith(u8, nm_rel, "@types/"))
                nm_rel["@types/".len..]
            else
                nm_rel;
            const stripped = naming.stripModuleExtension(pkg_rel);
            const final_rel = if (std.mem.endsWith(u8, stripped, "/index") and stripped.len > "/index".len)
                stripped[0 .. stripped.len - "/index".len]
            else if (stripped.len == 0)
                "index"
            else
                stripped;
            return try self.alloc.dupe(u8, final_rel);
        }

        fn deriveFileLogicalSpecifier(self: *Self, mod: anytype) ![]const u8 {
            const raw_spec = self.str(mod.specifier);
            const file_path = self.str(mod.file_path);

            // Non-path package/ambient specifier takes precedence.
            if (raw_spec.len > 0 and !std.mem.startsWith(u8, raw_spec, "/") and !std.mem.startsWith(u8, raw_spec, ".")) {
                return try self.alloc.dupe(u8, naming.stripModuleExtension(raw_spec));
            }

            const chosen = if (file_path.len > 0) file_path else raw_spec;
            var rel = chosen;
            if (self.options.base_dir) |base| {
                const trimmed_base = std.mem.trimEnd(u8, base, "/");
                if (trimmed_base.len > 0 and std.mem.startsWith(u8, chosen, trimmed_base)) {
                    const after = chosen[trimmed_base.len..];
                    if (after.len == 0) {
                        rel = "index";
                    } else if (after[0] == '/') {
                        const sub = after[1..];
                        if (std.mem.startsWith(u8, sub, "node_modules/")) {
                            return self.normalizeExternalNodeModulesSubpath(sub["node_modules/".len..]);
                        }
                        if (std.mem.lastIndexOf(u8, sub, "/node_modules/")) |nm_idx| {
                            return self.normalizeExternalNodeModulesSubpath(sub[nm_idx + "/node_modules/".len ..]);
                        }
                        rel = sub;
                    }
                } else if (std.mem.lastIndexOf(u8, chosen, "/node_modules/")) |nm_idx| {
                    return self.normalizeExternalNodeModulesSubpath(chosen[nm_idx + "/node_modules/".len ..]);
                } else if (std.mem.lastIndexOfScalar(u8, chosen, '/')) |slash| {
                    rel = chosen[slash + 1 ..];
                }
            } else if (std.mem.lastIndexOf(u8, chosen, "/node_modules/")) |nm_idx| {
                return self.normalizeExternalNodeModulesSubpath(chosen[nm_idx + "/node_modules/".len ..]);
            } else if (std.mem.startsWith(u8, chosen, "/")) {
                rel = chosen[1..];
            }

            const stripped = naming.stripModuleExtension(rel);
            if (stripped.len == 0) return try self.alloc.dupe(u8, "index");
            return try self.alloc.dupe(u8, stripped);
        }

        fn getOrCreateCandidate(
            self: *Self,
            wire_spec: []const u8,
            source_mod_id: ?u32,
        ) !u32 {
            const sub_spec = try applySubstitutions(self.alloc, wire_spec, self.options.substitutions);
            // Normalize '.' in dotted namespace specifiers (e.g. monaco.editor -> monaco/editor) before path sanitization.
            const slash_spec = try self.alloc.dupe(u8, sub_spec);
            for (slash_spec) |*ch| {
                if (ch.* == '.') ch.* = '/';
            }
            const rel_zig_path = try naming.sanitizeModuleRelPath(self.alloc, slash_spec);

            for (self.candidates.items, 0..) |*existing, idx| {
                if (std.mem.eql(u8, existing.rel_zig_path, rel_zig_path)) {
                    if (source_mod_id) |smid| {
                        try appendUniqueU32(&existing.source_mod_ids, self.scratch, smid);
                        try self.source_mod_to_cand.put(self.scratch, smid, @intCast(idx));
                    }
                    return @intCast(idx);
                }
            }

            const new_idx: u32 = @intCast(self.candidates.items.len);
            var cand = CandidateModule{
                .wire_specifier = try self.alloc.dupe(u8, wire_spec),
                .substituted_specifier = sub_spec,
                .rel_zig_path = rel_zig_path,
            };
            if (source_mod_id) |smid| {
                try cand.source_mod_ids.append(self.scratch, smid);
                try self.source_mod_to_cand.put(self.scratch, smid, new_idx);
            }
            try self.candidates.append(self.scratch, cand);
            return new_idx;
        }

        fn appendDeclRecursiveToCand(self: *Self, decl_id: u32, cand_idx: u32) error{OutOfMemory}!void {
            if (decl_id >= self.graph.decls.len) return;
            if (!self.decl_to_cand.contains(decl_id)) {
                try self.decl_to_cand.put(self.scratch, decl_id, cand_idx);
            }
            const d = self.graph.decls[decl_id];
            switch (d.kind) {
                .namespace_decl => |children| {
                    for (children) |cid| {
                        try self.appendDeclRecursiveToCand(cid, cand_idx);
                    }
                },
                else => {},
            }
        }

        fn findDottedNamespaceDecls(self: *const Self, dotted: []const u8) ?[]const u32 {
            if (std.mem.indexOfScalar(u8, dotted, '.') == null) return null;
            var seg_it = std.mem.splitScalar(u8, dotted, '.');
            const first_seg = seg_it.next() orelse return null;

            for (self.graph.modules) |mod| {
                const top_lists = [_][]const u32{ mod.exports, mod.global_augmentations };
                for (top_lists) |list| {
                    for (list) |did| {
                        if (did >= self.graph.decls.len) continue;
                        const d = self.graph.decls[did];
                        if (!std.mem.eql(u8, self.str(d.name), first_seg)) continue;
                        if (d.kind != .namespace_decl) continue;

                        var cur_children = d.kind.namespace_decl;
                        var rem_it = seg_it;
                        var matched_all = true;
                        while (rem_it.next()) |seg| {
                            var found_next: ?[]const u32 = null;
                            for (cur_children) |cid| {
                                if (cid >= self.graph.decls.len) continue;
                                const cd = self.graph.decls[cid];
                                if (cd.kind == .namespace_decl and std.mem.eql(u8, self.str(cd.name), seg)) {
                                    found_next = cd.kind.namespace_decl;
                                    break;
                                }
                            }
                            if (found_next) |nxt| {
                                cur_children = nxt;
                            } else {
                                matched_all = false;
                                break;
                            }
                        }
                        if (matched_all) return cur_children;
                    }
                }
            }
            return null;
        }

        fn isBundledLibModule(self: *const Self, mod: anytype) bool {
            const fp = self.str(mod.file_path);
            if (std.mem.startsWith(u8, fp, "/lib.") and std.mem.endsWith(u8, fp, ".d.ts")) return true;
            if (std.mem.indexOf(u8, fp, "/typescript/lib/lib.") != null) return true;
            return false;
        }

        fn findGraphModuleIndexById(self: *const Self, mod_id: u32) ?usize {
            if (mod_id < self.graph.modules.len and self.graph.modules[mod_id].id == mod_id) {
                return mod_id;
            }
            for (self.graph.modules, 0..) |m, midx| {
                if (m.id == mod_id) return midx;
            }
            return null;
        }

        fn appendUniqueForeignExport(
            list: *std.ArrayList(ForeignExportEntry),
            allocator: std.mem.Allocator,
            entry: ForeignExportEntry,
        ) !void {
            for (list.items) |existing| {
                if (existing.decl_id == entry.decl_id and existing.is_default_export == entry.is_default_export) {
                    const same_override = if (existing.wire_name_override) |a|
                        (if (entry.wire_name_override) |b| std.mem.eql(u8, a, b) else false)
                    else
                        entry.wire_name_override == null;
                    if (same_override) return;
                }
            }
            try list.append(allocator, entry);
        }

        fn registerCanonicalDeclInCandidate(self: *Self, owner_cand: u32, did: u32) !void {
            if (did >= self.graph.decls.len) return;
            if (!self.ns_child_ids.contains(did)) {
                try appendUniqueU32(&self.candidates.items[owner_cand].decl_ids, self.scratch, did);
            }
            try self.appendDeclRecursiveToCand(did, owner_cand);
            const d = self.graph.decls[did];
            for (d.merged_with) |mid| {
                if (mid < self.graph.decls.len and self.graph.decls[mid].module == d.module) {
                    if (!self.ns_child_ids.contains(mid)) {
                        try appendUniqueU32(&self.candidates.items[owner_cand].decl_ids, self.scratch, mid);
                    }
                    try self.appendDeclRecursiveToCand(mid, owner_cand);
                }
            }
        }

        fn resolveOrCreateOwnerCandForFileMod(self: *Self, owner_mod: anytype) !u32 {
            if (self.source_mod_to_cand.get(owner_mod.id)) |existing| return existing;
            // If `owner_mod` is an ambient-only `.d.ts` file (no ES exports / `export =` / globals),
            // keep unexported helper declarations inside its ambient module candidate rather than
            // synthesizing a bogus file-named `.zig` stub!
            if (owner_mod.ambient_modules.len > 0 and
                owner_mod.exports.len == 0 and
                owner_mod.star_re_exports.len == 0 and
                owner_mod.default_export == null and
                owner_mod.export_equals == null and
                owner_mod.global_augmentations.len == 0)
            {
                if (try self.findAmbientCandidateIdx(self.str(owner_mod.ambient_modules[0].module_name))) |amb_c| {
                    return amb_c;
                }
            }
            const ws = try self.deriveFileLogicalSpecifier(owner_mod);
            return try self.getOrCreateCandidate(ws, owner_mod.id);
        }

        fn registerCandidateDeclOrForeignExport(
            self: *Self,
            c_idx: u32,
            current_mod_id: ?u32,
            did: u32,
            wire_override: ?[]const u8,
            is_default_export: bool,
        ) !void {
            if (did >= self.graph.decls.len) return;
            const d = self.graph.decls[did];

            if (d.kind == .re_export_decl) {
                const eff_name = if (d.export_name) |esid| self.str(esid) else self.str(d.name);
                if (d.kind.re_export_decl.is_namespace and std.mem.eql(u8, eff_name, "*")) {
                    if (!self.decl_to_cand.contains(did)) {
                        try self.decl_to_cand.put(self.scratch, did, c_idx);
                    }
                    if (d.kind.re_export_decl.target_module) |tmid| {
                        try appendUniqueU32(
                            &self.candidates.items[c_idx].star_re_export_source_mods,
                            self.scratch,
                            tmid,
                        );
                    }
                    const mspec = self.str(d.kind.re_export_decl.module_specifier);
                    if (mspec.len > 0) {
                        var seen_spec = false;
                        for (self.candidates.items[c_idx].star_re_export_specs.items) |s| {
                            if (std.mem.eql(u8, s, mspec)) {
                                seen_spec = true;
                                break;
                            }
                        }
                        if (!seen_spec) {
                            try self.candidates.items[c_idx].star_re_export_specs.append(self.scratch, mspec);
                        }
                    }
                    return;
                }
                try appendUniqueU32(&self.candidates.items[c_idx].decl_ids, self.scratch, did);
                if (!is_default_export and !d.modifiers.default_export) {
                    try appendUniqueU32(&self.candidates.items[c_idx].exported_decl_ids, self.scratch, did);
                }
                try self.appendDeclRecursiveToCand(did, c_idx);
                return;
            }
            if (d.kind == .import_equals_decl) {
                try appendUniqueU32(&self.candidates.items[c_idx].decl_ids, self.scratch, did);
                if (d.modifiers.export_decl and !is_default_export and !d.modifiers.default_export) {
                    try appendUniqueU32(&self.candidates.items[c_idx].exported_decl_ids, self.scratch, did);
                }
                try self.appendDeclRecursiveToCand(did, c_idx);
                return;
            }

            var owner_cand: u32 = c_idx;
            if (current_mod_id != null and d.module != current_mod_id.?) {
                if (self.decl_to_cand.get(did)) |existing_cand| {
                    owner_cand = existing_cand;
                } else if (self.findGraphModuleIndexById(d.module)) |om_idx| {
                    const owner_mod = self.graph.modules[om_idx];
                    if (!self.isBundledLibModule(owner_mod)) {
                        owner_cand = try self.resolveOrCreateOwnerCandForFileMod(owner_mod);
                        try self.registerCanonicalDeclInCandidate(owner_cand, did);
                        if (!d.modifiers.default_export and !self.ns_child_ids.contains(did)) {
                            try appendUniqueU32(&self.candidates.items[owner_cand].exported_decl_ids, self.scratch, did);
                        }
                    } else {
                        owner_cand = c_idx;
                    }
                }
            } else if (self.decl_to_cand.get(did)) |existing_cand| {
                owner_cand = existing_cand;
            }

            if (owner_cand == c_idx) {
                try self.registerCanonicalDeclInCandidate(c_idx, did);
                if (!is_default_export and !d.modifiers.default_export and !self.ns_child_ids.contains(did)) {
                    try appendUniqueU32(&self.candidates.items[c_idx].exported_decl_ids, self.scratch, did);
                }
            } else {
                try appendUniqueForeignExport(&self.candidates.items[c_idx].foreign_exports, self.scratch, .{
                    .decl_id = did,
                    .wire_name_override = wire_override,
                    .is_default_export = is_default_export,
                });
            }
        }

        fn discoverCandidates(self: *Self) !void {
            // Precompute all declarations owned as children of a `namespace_decl` so nested
            // namespace members are never hoisted to top-level `cand.decl_ids`.
            for (self.graph.decls) |d| {
                if (d.kind == .namespace_decl) {
                    for (d.kind.namespace_decl) |cid| {
                        try self.ns_child_ids.put(self.scratch, cid, {});
                    }
                }
            }

            // 1a. Ambient modules (`declare module "node:http" { ... }`): register canonical own
            // declarations first so cross-file ambient re-exports find their owning ambient module.
            for (self.graph.modules) |mod| {
                if (self.isBundledLibModule(mod)) continue;
                for (mod.ambient_modules) |amb| {
                    const amb_name = self.str(amb.module_name);
                    const c_idx = try self.getOrCreateCandidate(amb_name, null);
                    for (amb.decls) |did| {
                        if (did >= self.graph.decls.len) continue;
                        const d = self.graph.decls[did];
                        if (d.kind == .re_export_decl or d.kind == .import_equals_decl) continue;
                        if (d.module == mod.id and !self.decl_to_cand.contains(did)) {
                            try self.registerCandidateDeclOrForeignExport(c_idx, mod.id, did, null, false);
                        }
                    }
                }
            }

            // 1b. Ambient modules: register re-exports and cross-ambient foreign exports.
            for (self.graph.modules) |mod| {
                if (self.isBundledLibModule(mod)) continue;
                for (mod.ambient_modules) |amb| {
                    const amb_name = self.str(amb.module_name);
                    const c_idx = try self.getOrCreateCandidate(amb_name, null);
                    for (amb.decls) |did| {
                        try self.registerCandidateDeclOrForeignExport(c_idx, mod.id, did, null, false);
                    }
                }
            }

            // 2. File-level module exports / star re-exports / export = / global augmentations.
            // Reference-only (`/// <reference path="..." />`) and ambient-only (`declare module "..."`)
            // files do NOT create empty file-level candidates here.
            for (self.graph.modules) |mod| {
                if (self.isBundledLibModule(mod)) continue;

                const has_file_content = mod.exports.len > 0 or
                    mod.star_re_exports.len > 0 or
                    mod.default_export != null or
                    mod.export_equals != null or
                    mod.global_augmentations.len > 0 or
                    self.source_mod_to_cand.contains(mod.id);

                if (has_file_content) {
                    const c_idx = self.source_mod_to_cand.get(mod.id) orelse blk: {
                        const wire_spec = try self.deriveFileLogicalSpecifier(mod);
                        break :blk try self.getOrCreateCandidate(wire_spec, mod.id);
                    };

                    for (mod.exports) |did| {
                        try self.registerCandidateDeclOrForeignExport(c_idx, mod.id, did, null, false);
                    }
                    if (mod.default_export) |def_id| {
                        try self.registerCandidateDeclOrForeignExport(c_idx, mod.id, def_id, "default", true);
                    }
                    if (mod.export_equals) |eq_id| {
                        try self.registerCandidateDeclOrForeignExport(c_idx, mod.id, eq_id, null, false);
                    }
                    for (mod.global_augmentations) |did| {
                        try self.registerCandidateDeclOrForeignExport(c_idx, mod.id, did, null, false);
                    }
                    for (mod.star_re_exports) |target_smid| {
                        try appendUniqueU32(
                            &self.candidates.items[c_idx].star_re_export_source_mods,
                            self.scratch,
                            target_smid,
                        );
                    }
                }
            }

            // 2b. Register declarations from transitively type-imported modules (`import type { X } from "./peer"`)
            // where the extractor recorded `d.module` without populating `mod.exports`.
            for (self.graph.decls) |d| {
                if (self.decl_to_cand.contains(d.id)) continue;
                if (self.ns_child_ids.contains(d.id)) continue;

                var found_mod_idx: ?usize = null;
                if (d.module < self.graph.modules.len and self.graph.modules[d.module].id == d.module) {
                    found_mod_idx = d.module;
                } else {
                    for (self.graph.modules, 0..) |m, midx| {
                        if (m.id == d.module) {
                            found_mod_idx = midx;
                            break;
                        }
                    }
                }
                const mod_idx = found_mod_idx orelse continue;
                const owner_mod = self.graph.modules[mod_idx];
                if (self.isBundledLibModule(owner_mod)) continue;

                const c_idx = try self.resolveOrCreateOwnerCandForFileMod(owner_mod);
                try appendUniqueU32(&self.candidates.items[c_idx].decl_ids, self.scratch, d.id);
                try self.appendDeclRecursiveToCand(d.id, c_idx);
            }

            // 3. Support dotted namespace `-m` filters such as `-m monaco.editor`.
            for (self.options.modules) |mod_pat| {
                var already_matched = false;
                for (self.candidates.items) |cand| {
                    if (moduleMatchesPattern(cand.wire_specifier, cand.substituted_specifier, mod_pat)) {
                        already_matched = true;
                        break;
                    }
                }
                if (!already_matched) {
                    if (self.findDottedNamespaceDecls(mod_pat)) |ns_decls| {
                        const c_idx = try self.getOrCreateCandidate(mod_pat, null);
                        for (ns_decls) |did| {
                            try appendUniqueU32(&self.candidates.items[c_idx].decl_ids, self.scratch, did);
                            // Point these decls to the synthesized dotted namespace module.
                            try self.decl_to_cand.put(self.scratch, did, c_idx);
                        }
                    }
                }
            }
        }

        fn collectReferencedCandsFromType(
            self: *Self,
            ty_id: u32,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            queue: *std.ArrayList(u32),
        ) error{OutOfMemory}!void {
            if (ty_id >= self.graph.types.len) return;
            if (visited_types.contains(ty_id)) return;
            try visited_types.put(self.scratch, ty_id, {});

            const tn = self.graph.types[ty_id];
            switch (tn.kind) {
                .reference => |ref| {
                    if (ref.target_decl) |td| {
                        if (self.decl_to_cand.get(td)) |dep_cand| {
                            if (!self.candidates.items[dep_cand].included) {
                                self.candidates.items[dep_cand].included = true;
                                try queue.append(self.scratch, dep_cand);
                            }
                        }
                    } else if (tn.resolved_type) |rt| {
                        try self.collectReferencedCandsFromType(rt, visited_types, queue);
                    }
                    for (ref.type_args) |arg_ty| {
                        try self.collectReferencedCandsFromType(arg_ty, visited_types, queue);
                    }
                },
                .array, .readonly_array, .keyof_type => |inner| {
                    try self.collectReferencedCandsFromType(inner, visited_types, queue);
                },
                .tuple, .readonly_tuple => |elems| {
                    for (elems) |el| try self.collectReferencedCandsFromType(el.ty, visited_types, queue);
                },
                .union_type, .intersection => |arms| {
                    for (arms) |arm| try self.collectReferencedCandsFromType(arm, visited_types, queue);
                },
                .object_literal => |obj| {
                    for (obj.properties) |pid| {
                        if (pid < self.graph.properties.len) {
                            try self.collectReferencedCandsFromType(self.graph.properties[pid].ty, visited_types, queue);
                        }
                    }
                    for (obj.call_signatures) |sid| try self.collectReferencedCandsFromSig(sid, visited_types, queue);
                    for (obj.construct_signatures) |sid| try self.collectReferencedCandsFromSig(sid, visited_types, queue);
                },
                .function_type, .constructor_type => |sid| {
                    try self.collectReferencedCandsFromSig(sid, visited_types, queue);
                },
                else => {
                    if (tn.resolved_type) |rt| {
                        try self.collectReferencedCandsFromType(rt, visited_types, queue);
                    }
                },
            }
        }

        fn collectReferencedCandsFromTypeParams(
            self: *Self,
            tp_ids: []const u32,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            queue: *std.ArrayList(u32),
        ) error{OutOfMemory}!void {
            for (tp_ids) |tp_id| {
                if (tp_id >= self.graph.type_params.len) continue;
                const tp = self.graph.type_params[tp_id];
                if (tp.constraint) |ct| try self.collectReferencedCandsFromType(ct, visited_types, queue);
                if (tp.default_type) |dt| try self.collectReferencedCandsFromType(dt, visited_types, queue);
            }
        }

        fn collectReferencedCandsFromSig(
            self: *Self,
            sig_id: u32,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            queue: *std.ArrayList(u32),
        ) error{OutOfMemory}!void {
            if (sig_id >= self.graph.signatures.len) return;
            const sig = self.graph.signatures[sig_id];
            try self.collectReferencedCandsFromTypeParams(sig.type_params, visited_types, queue);
            for (sig.params) |p| try self.collectReferencedCandsFromType(p.ty, visited_types, queue);
            try self.collectReferencedCandsFromType(sig.return_type, visited_types, queue);
        }

        fn collectReferencedCandsFromDecl(
            self: *Self,
            decl_id: u32,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            queue: *std.ArrayList(u32),
        ) error{OutOfMemory}!void {
            if (decl_id >= self.graph.decls.len) return;
            const d = self.graph.decls[decl_id];
            switch (d.kind) {
                .function_decl => |sigs| {
                    for (sigs) |sid| try self.collectReferencedCandsFromSig(sid, visited_types, queue);
                },
                .variable_decl => |ty| try self.collectReferencedCandsFromType(ty, visited_types, queue),
                .type_alias_decl => |ty| {
                    try self.collectReferencedCandsFromTypeParams(d.type_params, visited_types, queue);
                    try self.collectReferencedCandsFromType(ty, visited_types, queue);
                },
                .interface_decl => |iface| {
                    try self.collectReferencedCandsFromTypeParams(d.type_params, visited_types, queue);
                    for (iface.properties) |pid| {
                        if (pid < self.graph.properties.len) {
                            try self.collectReferencedCandsFromType(self.graph.properties[pid].ty, visited_types, queue);
                        }
                    }
                    for (iface.methods) |m| {
                        for (m.signatures) |sid| try self.collectReferencedCandsFromSig(sid, visited_types, queue);
                    }
                    for (iface.call_signatures) |sid| try self.collectReferencedCandsFromSig(sid, visited_types, queue);
                    for (iface.construct_signatures) |sid| try self.collectReferencedCandsFromSig(sid, visited_types, queue);
                },
                .class_decl => |cls| {
                    try self.collectReferencedCandsFromTypeParams(d.type_params, visited_types, queue);
                    for (cls.constructors) |sid| try self.collectReferencedCandsFromSig(sid, visited_types, queue);
                    for (cls.properties) |pid| {
                        if (pid < self.graph.properties.len) {
                            try self.collectReferencedCandsFromType(self.graph.properties[pid].ty, visited_types, queue);
                        }
                    }
                    for (cls.methods) |m| {
                        for (m.signatures) |sid| try self.collectReferencedCandsFromSig(sid, visited_types, queue);
                    }
                },
                .namespace_decl => |children| {
                    for (children) |cid| try self.collectReferencedCandsFromDecl(cid, visited_types, queue);
                },
                .re_export_decl => |re| {
                    if (re.target_module) |tmid| {
                        if (self.source_mod_to_cand.get(tmid)) |dep_cand| {
                            if (!self.candidates.items[dep_cand].included) {
                                self.candidates.items[dep_cand].included = true;
                                try queue.append(self.scratch, dep_cand);
                            }
                        }
                    }
                    if (re.target_decl) |tdid| {
                        if (self.decl_to_cand.get(tdid)) |dep_cand| {
                            if (!self.candidates.items[dep_cand].included) {
                                self.candidates.items[dep_cand].included = true;
                                try queue.append(self.scratch, dep_cand);
                            }
                        }
                    } else if (re.target_module == null) {
                        const mspec = self.str(re.module_specifier);
                        if (try self.resolveSpecToCandidateIdx(mspec)) |dep_cand| {
                            if (!self.candidates.items[dep_cand].included) {
                                self.candidates.items[dep_cand].included = true;
                                try queue.append(self.scratch, dep_cand);
                            }
                        }
                    }
                },
                .import_equals_decl => |ie| {
                    if (ie.target_decl) |tdid| {
                        if (self.decl_to_cand.get(tdid)) |dep_cand| {
                            if (!self.candidates.items[dep_cand].included) {
                                self.candidates.items[dep_cand].included = true;
                                try queue.append(self.scratch, dep_cand);
                            }
                        }
                    } else if (ie.module_specifier) |msid| {
                        const mspec = self.str(msid);
                        if (try self.resolveSpecToCandidateIdx(mspec)) |dep_cand| {
                            if (!self.candidates.items[dep_cand].included) {
                                self.candidates.items[dep_cand].included = true;
                                try queue.append(self.scratch, dep_cand);
                            }
                        }
                    }
                },
                .enum_decl => {},
            }
        }

        fn resolveRelativeVfsPath(allocator: std.mem.Allocator, from_file_path: []const u8, rel_path: []const u8) ![]u8 {
            const dir_part = if (std.mem.lastIndexOfScalar(u8, from_file_path, '/')) |slash|
                (if (slash == 0) "/" else from_file_path[0..slash])
            else
                "/";
            const joined = if (rel_path.len > 0 and rel_path[0] == '/')
                try allocator.dupe(u8, rel_path)
            else if (std.mem.eql(u8, dir_part, "/"))
                try std.fmt.allocPrint(allocator, "/{s}", .{rel_path})
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_part, rel_path });
            defer allocator.free(joined);

            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);

            var start: usize = 0;
            var i: usize = 0;
            while (i <= joined.len) : (i += 1) {
                const is_sep = (i == joined.len) or (joined[i] == '/') or (joined[i] == '\\');
                if (!is_sep) continue;
                const seg = joined[start..i];
                start = i + 1;
                if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
                if (std.mem.eql(u8, seg, "..")) {
                    if (parts.items.len > 0) _ = parts.pop();
                    continue;
                }
                try parts.append(allocator, seg);
            }

            if (parts.items.len == 0) return try allocator.dupe(u8, "/");
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            for (parts.items) |seg| {
                try out.append(allocator, '/');
                try out.appendSlice(allocator, seg);
            }
            return try out.toOwnedSlice(allocator);
        }

        fn runReachabilityClosure(self: *Self, queue: *std.ArrayList(u32)) error{OutOfMemory}!void {
            var visited_types: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited_types.deinit(self.scratch);

            var q_head: usize = 0;
            while (q_head < queue.items.len) : (q_head += 1) {
                const c_idx = queue.items[q_head];
                const star_targets = try self.scratch.dupe(u32, self.candidates.items[c_idx].star_re_export_source_mods.items);
                defer self.scratch.free(star_targets);
                for (star_targets) |smid| {
                    if (self.source_mod_to_cand.get(smid)) |dep_cand| {
                        if (!self.candidates.items[dep_cand].included) {
                            self.candidates.items[dep_cand].included = true;
                            try queue.append(self.scratch, dep_cand);
                        }
                    }
                }

                const star_specs = try self.scratch.dupe([]const u8, self.candidates.items[c_idx].star_re_export_specs.items);
                defer self.scratch.free(star_specs);
                for (star_specs) |mspec| {
                    if (try self.resolveSpecToCandidateIdx(mspec)) |dep_cand| {
                        if (!self.candidates.items[dep_cand].included) {
                            self.candidates.items[dep_cand].included = true;
                            try queue.append(self.scratch, dep_cand);
                        }
                    }
                }

                const foreign_snapshot = try self.scratch.dupe(ForeignExportEntry, self.candidates.items[c_idx].foreign_exports.items);
                defer self.scratch.free(foreign_snapshot);
                for (foreign_snapshot) |fe| {
                    if (self.decl_to_cand.get(fe.decl_id)) |dep_cand| {
                        if (!self.candidates.items[dep_cand].included) {
                            self.candidates.items[dep_cand].included = true;
                            try queue.append(self.scratch, dep_cand);
                        }
                    }
                }

                const decl_snapshot = try self.scratch.dupe(u32, self.candidates.items[c_idx].decl_ids.items);
                defer self.scratch.free(decl_snapshot);
                for (decl_snapshot) |did| {
                    try self.collectReferencedCandsFromDecl(did, &visited_types, queue);
                }
            }
        }

        fn findAmbientCandidateIdx(self: *Self, amb_name: []const u8) !?u32 {
            const sub_spec = try applySubstitutions(self.scratch, amb_name, self.options.substitutions);
            defer self.scratch.free(sub_spec);
            const slash_spec = try self.scratch.dupe(u8, sub_spec);
            defer self.scratch.free(slash_spec);
            for (slash_spec) |*ch| {
                if (ch.* == '.') ch.* = '/';
            }
            const rel_zig_path = try naming.sanitizeModuleRelPath(self.scratch, slash_spec);
            defer self.scratch.free(rel_zig_path);

            for (self.candidates.items, 0..) |cand, idx| {
                if (std.mem.eql(u8, cand.rel_zig_path, rel_zig_path)) {
                    return @intCast(idx);
                }
            }
            return null;
        }

        fn resolveSpecToCandidateIdx(self: *Self, mspec: []const u8) error{OutOfMemory}!?u32 {
            const trimmed = std.mem.trim(u8, mspec, " \t\r\n");
            if (trimmed.len == 0) return null;

            for (self.candidates.items, 0..) |cand, idx| {
                if (std.mem.eql(u8, cand.wire_specifier, trimmed) or
                    std.mem.eql(u8, cand.substituted_specifier, trimmed))
                {
                    return @intCast(idx);
                }
            }

            if (try self.findAmbientCandidateIdx(trimmed)) |amb_idx| {
                return amb_idx;
            }

            for (self.candidates.items, 0..) |cand, idx| {
                if (moduleMatchesPattern(cand.wire_specifier, cand.substituted_specifier, trimmed)) {
                    return @intCast(idx);
                }
            }

            return null;
        }

        fn createEmptyFallbackCandidate(self: *Self) !u32 {
            for (self.graph.modules) |mod| {
                if (self.isBundledLibModule(mod)) continue;
                if (self.isPrimaryVfsPath(self.str(mod.file_path))) {
                    const wire_spec = try self.deriveFileLogicalSpecifier(mod);
                    return try self.getOrCreateCandidate(wire_spec, mod.id);
                }
            }
            for (self.graph.modules) |mod| {
                if (self.isBundledLibModule(mod)) continue;
                const wire_spec = try self.deriveFileLogicalSpecifier(mod);
                return try self.getOrCreateCandidate(wire_spec, mod.id);
            }
            return try self.getOrCreateCandidate("index", null);
        }

        fn filterAndCloseDependencies(self: *Self) LowerError![]u32 {
            if (self.options.modules.len > 0) {
                var queue: std.ArrayList(u32) = .empty;
                defer queue.deinit(self.scratch);

                for (self.candidates.items, 0..) |*cand, idx| {
                    for (self.options.modules) |pat| {
                        if (moduleMatchesPattern(cand.wire_specifier, cand.substituted_specifier, pat)) {
                            cand.is_primary = true;
                            cand.included = true;
                            try queue.append(self.scratch, @intCast(idx));
                            break;
                        }
                    }
                }

                if (queue.items.len == 0) {
                    return error.NoMatchingModules;
                }

                try self.runReachabilityClosure(&queue);
            } else if (self.options.primary_vfs_paths.len > 0) {
                var queue: std.ArrayList(u32) = .empty;
                defer queue.deinit(self.scratch);

                var primary_mod_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer primary_mod_ids.deinit(self.scratch);

                var ref_path_mod_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer ref_path_mod_ids.deinit(self.scratch);

                var mod_bfs: std.ArrayList(u32) = .empty;
                defer mod_bfs.deinit(self.scratch);

                for (self.graph.modules) |mod| {
                    if (self.isBundledLibModule(mod)) continue;
                    if (self.isPrimaryVfsPath(self.str(mod.file_path))) {
                        try primary_mod_ids.put(self.scratch, mod.id, {});
                        try ref_path_mod_ids.put(self.scratch, mod.id, {});
                        try mod_bfs.append(self.scratch, mod.id);
                    }
                }

                // Compute transitive `/// <reference path="..." />` closure (explicitly NOT
                // `triple_slash_types` to external `node_modules`!) starting from `primary_vfs_paths`.
                var mb_head: usize = 0;
                while (mb_head < mod_bfs.items.len) : (mb_head += 1) {
                    const mid = mod_bfs.items[mb_head];
                    const midx = self.findGraphModuleIndexById(mid) orelse continue;
                    const cur_mod = self.graph.modules[midx];
                    const cur_fp = self.str(cur_mod.file_path);
                    for (cur_mod.triple_slash_paths) |ref_sid| {
                        const ref_rel = self.str(ref_sid);
                        if (ref_rel.len == 0) continue;
                        const resolved_fp = try resolveRelativeVfsPath(self.scratch, cur_fp, ref_rel);
                        defer self.scratch.free(resolved_fp);
                        const resolved_dts = try std.fmt.allocPrint(self.scratch, "{s}.d.ts", .{resolved_fp});
                        defer self.scratch.free(resolved_dts);
                        const resolved_ts = try std.fmt.allocPrint(self.scratch, "{s}.ts", .{resolved_fp});
                        defer self.scratch.free(resolved_ts);
                        const resolved_idx_dts = try std.fmt.allocPrint(self.scratch, "{s}/index.d.ts", .{resolved_fp});
                        defer self.scratch.free(resolved_idx_dts);
                        const resolved_idx_ts = try std.fmt.allocPrint(self.scratch, "{s}/index.ts", .{resolved_fp});
                        defer self.scratch.free(resolved_idx_ts);

                        for (self.graph.modules) |other| {
                            if (self.isBundledLibModule(other)) continue;
                            const ofp = self.str(other.file_path);
                            if (std.mem.eql(u8, ofp, resolved_fp) or
                                std.mem.eql(u8, ofp, resolved_dts) or
                                std.mem.eql(u8, ofp, resolved_ts) or
                                std.mem.eql(u8, ofp, resolved_idx_dts) or
                                std.mem.eql(u8, ofp, resolved_idx_ts))
                            {
                                if (!ref_path_mod_ids.contains(other.id)) {
                                    try ref_path_mod_ids.put(self.scratch, other.id, {});
                                    try mod_bfs.append(self.scratch, other.id);
                                }
                            }
                        }
                    }
                }

                // 1. Mark non-empty file-level candidates directly owned by `primary_vfs_paths` as primary.
                for (self.candidates.items, 0..) |*cand, idx| {
                    for (cand.source_mod_ids.items) |smid| {
                        if (primary_mod_ids.contains(smid)) {
                            cand.is_primary = true;
                            if (!cand.included) {
                                cand.included = true;
                                try queue.append(self.scratch, @intCast(idx));
                            }
                            break;
                        }
                    }
                }

                // 2. Mark every ambient module (`declare module "..."`) and `declare global` / script
                // globals module in the `primary_vfs_paths + triple_slash_paths` closure as primary!
                for (mod_bfs.items) |mid| {
                    const midx = self.findGraphModuleIndexById(mid) orelse continue;
                    const m = self.graph.modules[midx];
                    if (m.global_augmentations.len > 0) {
                        if (self.source_mod_to_cand.get(mid)) |c_idx| {
                            self.candidates.items[c_idx].is_primary = true;
                            if (!self.candidates.items[c_idx].included) {
                                self.candidates.items[c_idx].included = true;
                                try queue.append(self.scratch, c_idx);
                            }
                        }
                    } else if (!primary_mod_ids.contains(mid)) {
                        if (self.source_mod_to_cand.get(mid)) |c_idx| {
                            if (!self.candidates.items[c_idx].included) {
                                self.candidates.items[c_idx].included = true;
                                try queue.append(self.scratch, c_idx);
                            }
                        }
                    }
                    for (m.ambient_modules) |amb| {
                        if (try self.findAmbientCandidateIdx(self.str(amb.module_name))) |amb_cand_idx| {
                            var ac = &self.candidates.items[amb_cand_idx];
                            ac.is_primary = true;
                            if (!ac.included) {
                                ac.included = true;
                                try queue.append(self.scratch, amb_cand_idx);
                            }
                        }
                    }
                }

                if (queue.items.len == 0) {
                    // Only emit an empty fallback module when the entire package would otherwise
                    // emit zero modules!
                    const fb_idx = try self.createEmptyFallbackCandidate();
                    self.candidates.items[fb_idx].is_primary = true;
                    self.candidates.items[fb_idx].included = true;
                } else {
                    var has_any_primary = false;
                    for (queue.items) |q_idx| {
                        if (self.candidates.items[q_idx].is_primary) {
                            has_any_primary = true;
                            break;
                        }
                    }
                    if (!has_any_primary) {
                        for (queue.items) |q_idx| {
                            self.candidates.items[q_idx].is_primary = true;
                        }
                    }
                    try self.runReachabilityClosure(&queue);
                }
            } else {
                if (self.candidates.items.len == 0) {
                    _ = try self.createEmptyFallbackCandidate();
                }
                for (self.candidates.items) |*cand| {
                    cand.is_primary = true;
                    cand.included = true;
                }
            }

            var selected: std.ArrayList(u32) = .empty;
            errdefer selected.deinit(self.alloc);
            for (self.candidates.items, 0..) |cand, idx| {
                if (cand.included) {
                    try selected.append(self.alloc, @intCast(idx));
                }
            }
            return try selected.toOwnedSlice(self.alloc);
        }

        fn declNameStyle(self: *const Self, d: anytype) naming.NameStyle {
            return switch (d.kind) {
                .function_decl => .camel,
                .interface_decl, .class_decl, .enum_decl, .type_alias_decl, .namespace_decl => .pascal,
                .variable_decl => blk: {
                    const raw = self.str(d.name);
                    if (isAllUpperOrUnderscore(raw)) break :blk .preserve;
                    break :blk .snake;
                },
                .import_equals_decl, .re_export_decl => .preserve,
            };
        }

        fn prebindScopeDecls(
            self: *Self,
            final_mod_idx: u32,
            decl_ids: []const u32,
            scope: *naming.ScopeNamer,
            prefix_path: []const []const u8,
            prebound_names: *std.AutoHashMapUnmanaged(u32, naming.BoundName),
            prebound_overloads: *std.AutoHashMapUnmanaged(u32, []naming.BoundName),
        ) error{OutOfMemory}!void {
            // Detect interface/class + namespace declaration merging in the same scope so merged
            // namespace children fold cleanly inside the struct rather than colliding!
            for (decl_ids) |did| {
                if (did >= self.graph.decls.len) continue;
                const d = self.graph.decls[did];
                if (d.kind == .interface_decl or d.kind == .class_decl) {
                    for (d.merged_with) |mid| {
                        if (mid >= self.graph.decls.len) continue;
                        if (self.graph.decls[mid].kind == .namespace_decl) {
                            for (decl_ids) |other| {
                                if (other == mid) {
                                    try self.merged_ns_consumed.put(self.scratch, mid, {});
                                }
                            }
                        }
                    }
                }
            }

            for (decl_ids) |did| {
                if (did >= self.graph.decls.len) continue;
                if (self.merged_ns_consumed.contains(did)) continue;

                const d = self.graph.decls[did];
                if (d.kind == .import_equals_decl and !d.modifiers.export_decl) continue;
                const wire = if (d.export_name) |esid| self.str(esid) else self.str(d.name);
                if (d.kind == .re_export_decl and d.kind.re_export_decl.is_namespace and std.mem.eql(u8, wire, "*")) continue;
                const bound = try scope.bind(wire, self.declNameStyle(d));

                // Duplicate into arena so `PackageIr` owns all strings.
                const owned_bound = naming.BoundName{
                    .zig_ident = try self.alloc.dupe(u8, bound.zig_ident),
                    .logical_name = try self.alloc.dupe(u8, bound.logical_name),
                    .wire_name = try self.alloc.dupe(u8, bound.wire_name),
                };
                bound.deinit(self.scratch);
                try prebound_names.put(self.scratch, did, owned_bound);

                if (d.kind == .function_decl and d.kind.function_decl.len > 1) {
                    const extra_count = d.kind.function_decl.len - 1;
                    var extras = try self.alloc.alloc(naming.BoundName, extra_count);
                    for (0..extra_count) |ei| {
                        const ov = try scope.bind(owned_bound.wire_name, .camel);
                        extras[ei] = .{
                            .zig_ident = try self.alloc.dupe(u8, ov.zig_ident),
                            .logical_name = try self.alloc.dupe(u8, ov.logical_name),
                            .wire_name = owned_bound.wire_name,
                        };
                        ov.deinit(self.scratch);
                    }
                    try prebound_overloads.put(self.scratch, did, extras);
                }

                var full_path = try self.alloc.alloc([]const u8, prefix_path.len + 1);
                @memcpy(full_path[0..prefix_path.len], prefix_path);
                full_path[prefix_path.len] = owned_bound.zig_ident;

                var defaults = try self.alloc.alloc(?u32, d.type_params.len);
                for (d.type_params, 0..) |tp_id, tp_i| {
                    defaults[tp_i] = if (tp_id < self.graph.type_params.len)
                        self.graph.type_params[tp_id].default_type
                    else
                        null;
                }

                try self.decl_locations.put(self.scratch, did, .{
                    .module_index = final_mod_idx,
                    .zig_path = full_path,
                    .type_param_defaults = defaults,
                });

                switch (d.kind) {
                    .namespace_decl => |children| {
                        var nested_scope = naming.ScopeNamer.initContainer(self.scratch, scope);
                        defer nested_scope.deinit();
                        try nested_scope.reserve("zigar_js");
                        try self.prebindScopeDecls(final_mod_idx, children, &nested_scope, full_path, prebound_names, prebound_overloads);
                    },
                    .interface_decl, .class_decl => {
                        var preview_tp_scope = naming.ScopeNamer.initParam(self.scratch, scope);
                        defer preview_tp_scope.deinit();
                        for (d.type_params) |tp_id| {
                            const raw_tp = if (tp_id < self.graph.type_params.len)
                                self.str(self.graph.type_params[tp_id].name)
                            else
                                "T";
                            const tb = try preview_tp_scope.bindWithFallbackSuffix(raw_tp, .pascal, "T");
                            tb.deinit(self.scratch);
                        }
                        var nested_scope = naming.ScopeNamer.initContainer(self.scratch, &preview_tp_scope);
                        defer nested_scope.deinit();
                        try nested_scope.reserve("zigar_js");
                        for (d.merged_with) |mid| {
                            if (self.merged_ns_consumed.contains(mid)) {
                                const mchildren = self.graph.decls[mid].kind.namespace_decl;
                                try self.prebindScopeDecls(final_mod_idx, mchildren, &nested_scope, full_path, prebound_names, prebound_overloads);
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        fn lowerJsDoc(self: *Self, opt_jsdoc: anytype) !?JsDocIr {
            const jd = opt_jsdoc orelse return null;
            const summary = if (jd.summary) |s_id| self.str(s_id) else "";

            var params: std.ArrayList(JsDocParamIr) = .empty;
            var returns_txt: ?[]const u8 = null;
            var throws: std.ArrayList([]const u8) = .empty;
            var examples: std.ArrayList([]const u8) = .empty;

            for (jd.tags) |tag| {
                const tag_name = self.str(tag.name);
                const raw_text = if (tag.text) |tid| std.mem.trim(u8, self.str(tid), " \t\r\n") else "";
                if (std.mem.eql(u8, tag_name, "param") or std.mem.eql(u8, tag_name, "arg") or std.mem.eql(u8, tag_name, "argument")) {
                    var p_name: []const u8 = "";
                    var p_desc: []const u8 = raw_text;
                    if (raw_text.len > 0) {
                        var sp: usize = 0;
                        while (sp < raw_text.len and raw_text[sp] != ' ' and raw_text[sp] != '\t' and raw_text[sp] != '\r' and raw_text[sp] != '\n') : (sp += 1) {}
                        p_name = raw_text[0..sp];
                        p_desc = std.mem.trimStart(u8, raw_text[sp..], " \t-:");
                    }
                    try params.append(self.alloc, .{
                        .name = try self.alloc.dupe(u8, p_name),
                        .description = try self.alloc.dupe(u8, p_desc),
                    });
                } else if (std.mem.eql(u8, tag_name, "returns") or std.mem.eql(u8, tag_name, "return")) {
                    if (raw_text.len > 0 and returns_txt == null) {
                        returns_txt = try self.alloc.dupe(u8, raw_text);
                    }
                } else if (std.mem.eql(u8, tag_name, "throws") or std.mem.eql(u8, tag_name, "exception")) {
                    if (raw_text.len > 0) {
                        try throws.append(self.alloc, try self.alloc.dupe(u8, raw_text));
                    }
                } else if (std.mem.eql(u8, tag_name, "example")) {
                    if (raw_text.len > 0) {
                        try examples.append(self.alloc, try self.alloc.dupe(u8, raw_text));
                    }
                }
            }

            const has_any = summary.len > 0 or
                params.items.len > 0 or
                returns_txt != null or
                jd.is_deprecated or
                throws.items.len > 0 or
                examples.items.len > 0;
            if (!has_any) return null;

            const deprecated: ?[]const u8 = if (jd.is_deprecated)
                (if (jd.deprecation_message) |dm_id|
                    try self.alloc.dupe(u8, self.str(dm_id))
                else
                    "")
            else
                null;

            return .{
                .summary = try self.alloc.dupe(u8, summary),
                .params = try params.toOwnedSlice(self.alloc),
                .returns = returns_txt,
                .deprecated = deprecated,
                .throws = try throws.toOwnedSlice(self.alloc),
                .examples = try examples.toOwnedSlice(self.alloc),
            };
        }

        fn makeType(self: *Self, val: TypeIr) !*TypeIr {
            const ptr = try self.alloc.create(TypeIr);
            ptr.* = val;
            return ptr;
        }

        fn lowerTypeParams(
            self: *Self,
            raw_tp_ids: []const u32,
            tp_scope: *naming.ScopeNamer,
            outer_active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}!LoweredTypeParams {
            var ir_list = try self.alloc.alloc(TypeParamIr, raw_tp_ids.len);
            var combined_active = try self.alloc.alloc(ActiveTypeParam, outer_active_tps.len + raw_tp_ids.len);
            @memcpy(combined_active[0..outer_active_tps.len], outer_active_tps);

            // Bind all type parameter names first so mutual constraints (`<T extends U, U>`) resolve cleanly.
            for (raw_tp_ids, 0..) |tp_id, idx| {
                const raw_name = if (tp_id < self.graph.type_params.len)
                    self.str(self.graph.type_params[tp_id].name)
                else
                    "T";
                const bound = try tp_scope.bindWithFallbackSuffix(raw_name, .pascal, "T");
                const zig_ident = try self.alloc.dupe(u8, bound.zig_ident);
                const logical = try self.alloc.dupe(u8, bound.logical_name);
                const wire = try self.alloc.dupe(u8, bound.wire_name);
                bound.deinit(self.scratch);

                ir_list[idx] = .{
                    .zig_ident = zig_ident,
                    .logical_name = logical,
                    .wire_name = wire,
                    .constraint = null,
                    .default_type = null,
                };
                combined_active[outer_active_tps.len + idx] = .{
                    .ts_name = wire,
                    .zig_ident = zig_ident,
                };
            }

            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(self.scratch);

            for (raw_tp_ids, 0..) |tp_id, idx| {
                if (tp_id >= self.graph.type_params.len) continue;
                const tp = self.graph.type_params[tp_id];
                if (tp.constraint) |ct| {
                    visited.clearRetainingCapacity();
                    ir_list[idx].constraint = try self.lowerType(
                        ct,
                        false,
                        combined_active,
                        self_ident_opt,
                        &visited,
                        imports_used,
                        needs_runtime,
                    );
                }
                if (tp.default_type) |dt| {
                    visited.clearRetainingCapacity();
                    ir_list[idx].default_type = try self.lowerType(
                        dt,
                        false,
                        combined_active,
                        self_ident_opt,
                        &visited,
                        imports_used,
                        needs_runtime,
                    );
                }
            }

            return .{ .ir = ir_list, .active = combined_active };
        }

        fn lowerType(
            self: *Self,
            ty_id: u32,
            is_return_pos: bool,
            active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            visited: *std.AutoHashMapUnmanaged(u32, void),
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}!*TypeIr {
            if (ty_id >= self.graph.types.len) {
                needs_runtime.* = true;
                return self.makeType(.js_value);
            }
            if (visited.contains(ty_id)) {
                needs_runtime.* = true;
                return self.makeType(.js_value);
            }
            try visited.put(self.scratch, ty_id, {});
            defer _ = visited.remove(ty_id);

            const tn = self.graph.types[ty_id];
            switch (tn.kind) {
                .void_type, .undefined_type => return self.makeType(.void_type),
                .never_type => {
                    if (is_return_pos) return self.makeType(.noreturn_type);
                    return self.makeType(.void_type);
                },
                .null_type => {
                    needs_runtime.* = true;
                    const inner = try self.makeType(.js_value);
                    return self.makeType(.{ .optional = inner });
                },
                .boolean_type => return self.makeType(.bool_type),
                .number_type => return self.makeType(.f64_type),
                .bigint_type => return self.makeType(.i64_type),
                .string_type, .template_literal, .intrinsic => return self.makeType(.string_type),
                .symbol_type, .unique_symbol => {
                    needs_runtime.* = true;
                    return self.makeType(.js_symbol);
                },
                .any_type, .unknown_type => {
                    needs_runtime.* = true;
                    return self.makeType(.js_value);
                },
                .object_type => {
                    needs_runtime.* = true;
                    return self.makeType(.js_object);
                },
                .this_type => {
                    if (self_ident_opt) |sid| {
                        const self_t = try self.makeType(.{ .self_type = sid });
                        return self.makeType(.{ .pointer_const = self_t });
                    }
                    needs_runtime.* = true;
                    return self.makeType(.js_value);
                },
                .literal => |lit| return switch (lit) {
                    .str => self.makeType(.string_type),
                    .num => self.makeType(.f64_type),
                    .bigint_literal => self.makeType(.i64_type),
                    .boolean => self.makeType(.bool_type),
                },
                .type_param, .infer_type => |tp_id| {
                    const tp_name = if (tp_id < self.graph.type_params.len)
                        self.str(self.graph.type_params[tp_id].name)
                    else
                        "";
                    var i: usize = active_tps.len;
                    while (i > 0) {
                        i -= 1;
                        if (std.mem.eql(u8, active_tps[i].ts_name, tp_name)) {
                            return self.makeType(.{ .type_param_ref = active_tps[i].zig_ident });
                        }
                    }
                    needs_runtime.* = true;
                    return self.makeType(.js_value);
                },
                .array, .readonly_array => |elem_id| {
                    const elem = try self.lowerType(elem_id, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                    return self.makeType(.{ .slice = elem });
                },
                .tuple, .readonly_tuple => |elems| {
                    var tup_scope = naming.ScopeNamer.initContainer(self.scratch, null);
                    defer tup_scope.deinit();
                    try tup_scope.reserve("zigar_js");

                    var out_elems = try self.alloc.alloc(TupleElemIr, elems.len);
                    for (elems, 0..) |el, idx| {
                        const raw_lbl = if (el.label) |lsid| self.str(lsid) else null;
                        const fallback_lbl = if (raw_lbl) |l| l else try std.fmt.allocPrint(self.alloc, "{d}", .{idx});
                        const bound = try tup_scope.bind(fallback_lbl, if (raw_lbl != null) .snake else .preserve);
                        const zig_ident = try self.alloc.dupe(u8, bound.zig_ident);
                        bound.deinit(self.scratch);

                        var elem_ty = try self.lowerType(el.ty, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                        if (el.variadic) {
                            elem_ty = try self.makeType(.{ .slice = elem_ty });
                        } else if (el.optional) {
                            elem_ty = try self.wrapOptional(elem_ty);
                        }
                        out_elems[idx] = .{
                            .zig_ident = zig_ident,
                            .wire_label = if (raw_lbl) |l| try self.alloc.dupe(u8, l) else null,
                            .ty = elem_ty,
                            .is_optional = el.optional,
                        };
                    }
                    return self.makeType(.{ .tuple = out_elems });
                },
                .union_type => |arms| {
                    var non_null: std.ArrayList(u32) = .empty;
                    defer non_null.deinit(self.scratch);
                    var has_nullish = false;

                    for (arms) |arm_id| {
                        if (arm_id >= self.graph.types.len) continue;
                        switch (self.graph.types[arm_id].kind) {
                            .null_type, .undefined_type, .void_type => has_nullish = true,
                            .never_type => {},
                            else => try non_null.append(self.scratch, arm_id),
                        }
                    }

                    if (non_null.items.len == 0) {
                        if (has_nullish) {
                            needs_runtime.* = true;
                            const jv = try self.makeType(.js_value);
                            return self.makeType(.{ .optional = jv });
                        }
                        return self.makeType(.void_type);
                    }

                    var base_ty: *TypeIr = undefined;
                    if (non_null.items.len == 1) {
                        base_ty = try self.lowerType(non_null.items[0], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                    } else if (self.allArmsSameScalarKind(non_null.items)) |scalar_ty| {
                        base_ty = try self.makeType(scalar_ty);
                    } else {
                        // Lower general multi-arm union in inline type position to `zigar_js.JsValue`
                        // (top-level `type Foo = A | B` emits a dedicated `union(enum)` via `lowerUnionDecl`).
                        needs_runtime.* = true;
                        base_ty = try self.makeType(.js_value);
                    }

                    if (has_nullish) return self.wrapOptional(base_ty);
                    return base_ty;
                },
                .reference => |ref| {
                    const ref_name = self.str(ref.target_name);

                    // Check active generic type parameter first in case TS emitted a reference node.
                    for (active_tps) |tp| {
                        if (std.mem.eql(u8, tp.ts_name, ref_name)) {
                            return self.makeType(.{ .type_param_ref = tp.zig_ident });
                        }
                    }

                    if (ref.target_decl) |td| {
                        if (self.decl_locations.get(td)) |loc| {
                            try imports_used.put(self.scratch, loc.module_index, {});

                            const expected_len = loc.type_param_defaults.len;
                            const final_len = if (expected_len > 0) expected_len else ref.type_args.len;
                            var lowered_args = try self.alloc.alloc(*const TypeIr, final_len);

                            for (0..final_len) |ai| {
                                if (ai < ref.type_args.len) {
                                    lowered_args[ai] = try self.lowerType(ref.type_args[ai], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                                } else if (ai < loc.type_param_defaults.len and loc.type_param_defaults[ai] != null) {
                                    lowered_args[ai] = try self.lowerType(loc.type_param_defaults[ai].?, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                                } else {
                                    needs_runtime.* = true;
                                    lowered_args[ai] = try self.makeType(.js_value);
                                }
                            }

                            return self.makeType(.{
                                .decl_ref = .{
                                    .module_index = loc.module_index,
                                    .decl_zig_path = loc.zig_path,
                                    .target_decl_id = td,
                                    .type_args = lowered_args,
                                },
                            });
                        }
                    }

                    // Built-in JS / TypeScript standard library types.
                    if (std.mem.eql(u8, ref_name, "Array") or std.mem.eql(u8, ref_name, "ReadonlyArray") or
                        std.mem.eql(u8, ref_name, "Iterable") or std.mem.eql(u8, ref_name, "IterableIterator") or
                        std.mem.eql(u8, ref_name, "Set") or std.mem.eql(u8, ref_name, "ReadonlySet"))
                    {
                        const elem = if (ref.type_args.len > 0)
                            try self.lowerType(ref.type_args[0], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime)
                        else blk: {
                            needs_runtime.* = true;
                            break :blk try self.makeType(.js_value);
                        };
                        return self.makeType(.{ .slice = elem });
                    }
                    if (std.mem.eql(u8, ref_name, "Promise") or std.mem.eql(u8, ref_name, "PromiseLike")) {
                        needs_runtime.* = true;
                        const inner = if (ref.type_args.len > 0)
                            try self.lowerType(ref.type_args[0], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime)
                        else
                            try self.makeType(.void_type);
                        return self.makeType(.{ .promise = inner });
                    }
                    if (std.mem.eql(u8, ref_name, "Uint8Array") or std.mem.eql(u8, ref_name, "Uint8ClampedArray") or
                        std.mem.eql(u8, ref_name, "Buffer") or std.mem.eql(u8, ref_name, "ArrayBuffer") or
                        std.mem.eql(u8, ref_name, "SharedArrayBuffer") or std.mem.eql(u8, ref_name, "ArrayBufferLike"))
                    {
                        return self.makeType(.bytes_type);
                    }
                    if (builtinTypedArrayElem(ref_name)) |prim_el| {
                        return self.makeType(.{ .typed_slice = prim_el });
                    }
                    if (std.mem.eql(u8, ref_name, "Map") or std.mem.eql(u8, ref_name, "ReadonlyMap")) {
                        needs_runtime.* = true;
                        const k = if (ref.type_args.len > 0)
                            try self.lowerType(ref.type_args[0], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime)
                        else
                            try self.makeType(.js_value);
                        const v = if (ref.type_args.len > 1)
                            try self.lowerType(ref.type_args[1], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime)
                        else
                            try self.makeType(.js_value);
                        return self.makeType(.{ .js_map = .{ .key = k, .value = v } });
                    }

                    // Utility types (`Partial<T>`, `Pick<T, K>`, `Omit<T, K>`, `Readonly<T>`, `Record<K, V>`, etc.):
                    // use the TypeScript 7.1 Checker's `resolved_type` if available!
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) {
                            return self.lowerType(rt, is_return_pos, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                        }
                    }

                    if (std.mem.eql(u8, ref_name, "Record") and ref.type_args.len == 2) {
                        needs_runtime.* = true;
                        const k = try self.lowerType(ref.type_args[0], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                        const v = try self.lowerType(ref.type_args[1], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                        return self.makeType(.{ .js_map = .{ .key = k, .value = v } });
                    }

                    needs_runtime.* = true;
                    return self.makeType(.js_object);
                },
                .function_type, .constructor_type => |sig_id| {
                    if (sig_id < self.graph.signatures.len) {
                        const sig = self.graph.signatures[sig_id];
                        // Generic function types cannot be bare Zig function pointers; represent as JsValue.
                        if (sig.type_params.len == 0) {
                            var p_types = try self.alloc.alloc(*const TypeIr, sig.params.len);
                            for (sig.params, 0..) |p, idx| {
                                var pt = try self.lowerType(p.ty, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                                if (p.rest) {
                                    if (pt.* != .slice) pt = try self.makeType(.{ .slice = pt });
                                } else if (p.optional) {
                                    pt = try self.wrapOptional(pt);
                                }
                                p_types[idx] = pt;
                            }
                            const ret = if (sig.type_predicate) |pred|
                                (if (pred.asserts) try self.makeType(.void_type) else try self.makeType(.bool_type))
                            else
                                try self.lowerType(sig.return_type, true, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                            return self.makeType(.{ .fn_ptr = .{ .params = p_types, .return_type = ret } });
                        }
                    }
                    needs_runtime.* = true;
                    return self.makeType(.js_value);
                },
                .object_literal => |obj| {
                    if (obj.properties.len == 0 and obj.call_signatures.len == 1) {
                        const sid = obj.call_signatures[0];
                        if (sid < self.graph.signatures.len and self.graph.signatures[sid].type_params.len == 0) {
                            const sig = self.graph.signatures[sid];
                            var p_types = try self.alloc.alloc(*const TypeIr, sig.params.len);
                            for (sig.params, 0..) |p, idx| {
                                var pt = try self.lowerType(p.ty, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                                if (p.optional and !p.rest) pt = try self.wrapOptional(pt);
                                p_types[idx] = pt;
                            }
                            const ret = try self.lowerType(sig.return_type, true, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                            return self.makeType(.{ .fn_ptr = .{ .params = p_types, .return_type = ret } });
                        }
                    }
                    if (obj.properties.len > 0) {
                        var anon_scope = naming.ScopeNamer.initContainer(self.scratch, null);
                        defer anon_scope.deinit();
                        try anon_scope.reserve("zigar_js");
                        const fields = try self.lowerFields(obj.properties, false, &anon_scope, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                        return self.makeType(.{ .anon_struct = fields });
                    }
                    needs_runtime.* = true;
                    return self.makeType(.js_object);
                },
                else => {
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) {
                            return self.lowerType(rt, is_return_pos, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                        }
                    }
                    needs_runtime.* = true;
                    return self.makeType(.js_value);
                },
            }
        }

        fn wrapOptional(self: *Self, inner: *TypeIr) !*TypeIr {
            switch (inner.*) {
                .optional, .void_type, .noreturn_type => return inner,
                else => return self.makeType(.{ .optional = inner }),
            }
        }

        fn allArmsSameScalarKind(self: *const Self, arm_ids: []const u32) ?TypeIr {
            var expected: ?TypeIr = null;
            for (arm_ids) |aid| {
                const k = self.graph.types[aid].kind;
                const mapped: TypeIr = switch (k) {
                    .string_type, .template_literal => .string_type,
                    .number_type => .f64_type,
                    .boolean_type => .bool_type,
                    .bigint_type => .i64_type,
                    .literal => |lit| switch (lit) {
                        .str => .string_type,
                        .num => .f64_type,
                        .bigint_literal => .i64_type,
                        .boolean => .bool_type,
                    },
                    else => return null,
                };
                if (expected) |exp| {
                    if (@as(std.meta.Tag(TypeIr), exp) != @as(std.meta.Tag(TypeIr), mapped)) return null;
                } else {
                    expected = mapped;
                }
            }
            return expected;
        }

        fn lowerFields(
            self: *Self,
            prop_ids: []const u32,
            only_instance: bool,
            field_scope: *naming.ScopeNamer,
            active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            visited: *std.AutoHashMapUnmanaged(u32, void),
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}![]FieldIr {
            var list: std.ArrayList(FieldIr) = .empty;
            errdefer list.deinit(self.alloc);

            for (prop_ids) |pid| {
                if (pid >= self.graph.properties.len) continue;
                const p = self.graph.properties[pid];
                if (only_instance and p.modifiers.static_mod) continue;
                const wire = self.str(p.name);
                const bound = try field_scope.bind(wire, .snake);
                const zig_ident = try self.alloc.dupe(u8, bound.zig_ident);
                const logical = try self.alloc.dupe(u8, bound.logical_name);
                const wire_copy = try self.alloc.dupe(u8, bound.wire_name);
                bound.deinit(self.scratch);

                var f_ty = try self.lowerType(p.ty, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                if (p.modifiers.optional_mod) {
                    f_ty = try self.wrapOptional(f_ty);
                }

                try list.append(self.alloc, .{
                    .zig_ident = zig_ident,
                    .logical_name = logical,
                    .wire_name = wire_copy,
                    .ty = f_ty,
                    .is_optional = p.modifiers.optional_mod,
                    .is_readonly = p.modifiers.readonly_mod,
                    .jsdoc = try self.lowerJsDoc(p.jsdoc),
                });
            }

            return try list.toOwnedSlice(self.alloc);
        }

        fn lowerSignature(
            self: *Self,
            sig_id: u32,
            enclosing_scope: *const naming.ScopeNamer,
            has_self_receiver: bool,
            outer_active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}!SignatureIr {
            if (sig_id >= self.graph.signatures.len) {
                var fallback_self_ident: ?[]const u8 = null;
                if (has_self_receiver) {
                    var fn_scope_fb = naming.ScopeNamer.initParam(self.scratch, enclosing_scope);
                    defer fn_scope_fb.deinit();
                    const sb = try fn_scope_fb.bindWithFallbackSuffix("self", .snake, "arg");
                    fallback_self_ident = try self.alloc.dupe(u8, sb.zig_ident);
                    sb.deinit(self.scratch);
                }
                return .{
                    .self_param_ident = fallback_self_ident,
                    .type_params = &.{},
                    .params = &.{},
                    .return_type = try self.makeType(.void_type),
                    .has_type_predicate = false,
                    .type_predicate_asserts = false,
                    .jsdoc = null,
                };
            }

            const sig = self.graph.signatures[sig_id];
            var fn_scope = naming.ScopeNamer.initParam(self.scratch, enclosing_scope);
            defer fn_scope.deinit();

            var self_param_ident: ?[]const u8 = null;
            if (has_self_receiver) {
                const sb = try fn_scope.bindWithFallbackSuffix("self", .snake, "arg");
                self_param_ident = try self.alloc.dupe(u8, sb.zig_ident);
                sb.deinit(self.scratch);
            }

            const tp_res = try self.lowerTypeParams(
                sig.type_params,
                &fn_scope,
                outer_active_tps,
                self_ident_opt,
                imports_used,
                needs_runtime,
            );

            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(self.scratch);

            var params = try self.alloc.alloc(ParamIr, sig.params.len);
            for (sig.params, 0..) |p, idx| {
                const raw_pname = self.str(p.name);
                const fallback = if (raw_pname.len == 0 or std.mem.eql(u8, raw_pname, "_")) "arg" else raw_pname;
                const bound = try fn_scope.bindWithFallbackSuffix(fallback, .snake, "arg");
                const zig_ident = try self.alloc.dupe(u8, bound.zig_ident);
                const logical = try self.alloc.dupe(u8, bound.logical_name);
                bound.deinit(self.scratch);

                visited.clearRetainingCapacity();
                var pt = try self.lowerType(p.ty, false, tp_res.active, self_ident_opt, &visited, imports_used, needs_runtime);
                if (p.rest) {
                    if (pt.* != .slice) pt = try self.makeType(.{ .slice = pt });
                } else if (p.optional) {
                    pt = try self.wrapOptional(pt);
                }

                params[idx] = .{
                    .zig_ident = zig_ident,
                    .logical_name = logical,
                    .wire_name = try self.alloc.dupe(u8, raw_pname),
                    .ty = pt,
                    .is_optional = p.optional,
                    .is_rest = p.rest,
                };
            }

            visited.clearRetainingCapacity();
            const has_pred = sig.type_predicate != null;
            const pred_asserts = if (sig.type_predicate) |pred| pred.asserts else false;
            const ret_ty = if (has_pred)
                (if (pred_asserts) try self.makeType(.void_type) else try self.makeType(.bool_type))
            else
                try self.lowerType(sig.return_type, true, tp_res.active, self_ident_opt, &visited, imports_used, needs_runtime);

            return .{
                .self_param_ident = self_param_ident,
                .type_params = tp_res.ir,
                .params = params,
                .return_type = ret_ty,
                .has_type_predicate = has_pred,
                .type_predicate_asserts = pred_asserts,
                .jsdoc = try self.lowerJsDoc(sig.jsdoc),
            };
        }

        fn tryLowerStringEnum(self: *Self, ty_id: u32) !?[]EnumMemberIr {
            if (ty_id >= self.graph.types.len) return null;
            const tn = self.graph.types[ty_id];
            if (tn.kind != .union_type) return null;
            const arms = tn.kind.union_type;
            if (arms.len < 2) return null;

            for (arms) |aid| {
                if (aid >= self.graph.types.len) return null;
                const ak = self.graph.types[aid].kind;
                if (ak != .literal or ak.literal != .str) return null;
            }

            var tag_scope = naming.ScopeNamer.init(self.scratch, null);
            defer tag_scope.deinit();
            try tag_scope.reserve("zigar_js");

            var members = try self.alloc.alloc(EnumMemberIr, arms.len);
            for (arms, 0..) |aid, idx| {
                const raw_s = self.str(self.graph.types[aid].kind.literal.str);
                const bound = try tag_scope.bind(raw_s, .snake);
                members[idx] = .{
                    .zig_ident = try self.alloc.dupe(u8, bound.zig_ident),
                    .logical_name = try self.alloc.dupe(u8, bound.logical_name),
                    .wire_name = try self.alloc.dupe(u8, bound.wire_name),
                    .value = .{ .str = try self.alloc.dupe(u8, raw_s) },
                    .jsdoc = null,
                };
                bound.deinit(self.scratch);
            }
            return members;
        }

        fn tryLowerUnionDeclVariants(
            self: *Self,
            ty_id: u32,
            active_tps: []const ActiveTypeParam,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) !?[]UnionVariantIr {
            if (ty_id >= self.graph.types.len) return null;
            const tn = self.graph.types[ty_id];
            if (tn.kind != .union_type) return null;
            const arms = tn.kind.union_type;

            // Keep nullable single-type unions (`T | null`) as clean `?T` type aliases!
            var non_null: std.ArrayList(u32) = .empty;
            defer non_null.deinit(self.scratch);
            var has_nullish = false;
            for (arms) |aid| {
                if (aid >= self.graph.types.len) continue;
                switch (self.graph.types[aid].kind) {
                    .null_type, .undefined_type, .void_type => has_nullish = true,
                    .never_type => {},
                    else => try non_null.append(self.scratch, aid),
                }
            }
            if (has_nullish or non_null.items.len < 2) return null;

            var var_scope = naming.ScopeNamer.init(self.scratch, null);
            defer var_scope.deinit();
            try var_scope.reserve("zigar_js");

            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(self.scratch);

            var variants = try self.alloc.alloc(UnionVariantIr, non_null.items.len);
            for (non_null.items, 0..) |aid, idx| {
                visited.clearRetainingCapacity();
                const payload = try self.lowerType(aid, false, active_tps, null, &visited, imports_used, needs_runtime);
                const hint = self.deriveVariantTagHint(aid, idx);
                const bound = try var_scope.bind(hint, .snake);
                variants[idx] = .{
                    .zig_ident = try self.alloc.dupe(u8, bound.zig_ident),
                    .wire_tag = try self.alloc.dupe(u8, bound.wire_name),
                    .payload = payload,
                };
                bound.deinit(self.scratch);
            }
            return variants;
        }

        fn deriveVariantTagHint(self: *Self, arm_ty_id: u32, idx: usize) []const u8 {
            const ak = self.graph.types[arm_ty_id].kind;
            switch (ak) {
                .string_type => return "str",
                .number_type => return "num",
                .boolean_type => return "boolean",
                .bigint_type => return "bigint",
                .reference => |ref| return self.str(ref.target_name),
                .object_literal => |obj| {
                    for (obj.properties) |pid| {
                        if (pid >= self.graph.properties.len) continue;
                        const p = self.graph.properties[pid];
                        const pname = self.str(p.name);
                        if (p.ty < self.graph.types.len and self.graph.types[p.ty].kind == .literal) {
                            const lit = self.graph.types[p.ty].kind.literal;
                            switch (lit) {
                                .str => |sid| return self.str(sid),
                                .boolean => |b| {
                                    return std.fmt.allocPrint(self.alloc, "{s}_{s}", .{ pname, if (b) "true" else "false" }) catch "variant";
                                },
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
            return std.fmt.allocPrint(self.alloc, "variant_{d}", .{idx}) catch "variant";
        }

        fn lowerDeclIntoList(
            self: *Self,
            final_mod_idx: u32,
            decl_id: u32,
            scope: *naming.ScopeNamer,
            prebound_names: *const std.AutoHashMapUnmanaged(u32, naming.BoundName),
            prebound_overloads: *const std.AutoHashMapUnmanaged(u32, []naming.BoundName),
            outer_active_tps: []const ActiveTypeParam,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
            out_list: *std.ArrayList(DeclIr),
        ) error{OutOfMemory}!void {
            if (decl_id >= self.graph.decls.len) return;
            if (self.merged_ns_consumed.contains(decl_id)) return;

            const d = self.graph.decls[decl_id];
            const bound = prebound_names.get(decl_id) orelse return;
            const top_jsdoc = try self.lowerJsDoc(d.jsdoc);
            const is_exported = !d.modifiers.private_mod and !d.modifiers.protected_mod;
            const is_default_export = d.modifiers.default_export;

            switch (d.kind) {
                .function_decl => |sigs| {
                    if (sigs.len == 0) {
                        const empty_sig = SignatureIr{
                            .self_param_ident = null,
                            .type_params = &.{},
                            .params = &.{},
                            .return_type = try self.makeType(.void_type),
                            .has_type_predicate = false,
                            .type_predicate_asserts = false,
                            .jsdoc = top_jsdoc,
                        };
                        try out_list.append(self.alloc, .{
                            .source_decl_id = decl_id,
                            .zig_ident = bound.zig_ident,
                            .logical_name = bound.logical_name,
                            .wire_name = bound.wire_name,
                            .is_exported = is_exported,
                            .is_default_export = is_default_export,
                            .jsdoc = top_jsdoc,
                            .kind = .{ .function_decl = empty_sig },
                        });
                        return;
                    }

                    const ov_slice = prebound_overloads.get(decl_id) orelse &[_]naming.BoundName{};
                    for (sigs, 0..) |sid, s_idx| {
                        const sig_ir = try self.lowerSignature(
                            sid,
                            scope,
                            false,
                            outer_active_tps,
                            null,
                            imports_used,
                            needs_runtime,
                        );
                        var ident = bound.zig_ident;
                        var logical = bound.logical_name;
                        if (s_idx > 0) {
                            if (s_idx - 1 < ov_slice.len) {
                                ident = ov_slice[s_idx - 1].zig_ident;
                                logical = ov_slice[s_idx - 1].logical_name;
                            } else {
                                const ov = try scope.bind(bound.wire_name, .camel);
                                ident = try self.alloc.dupe(u8, ov.zig_ident);
                                logical = try self.alloc.dupe(u8, ov.logical_name);
                                ov.deinit(self.scratch);
                            }
                        }
                        try out_list.append(self.alloc, .{
                            .source_decl_id = decl_id,
                            .zig_ident = ident,
                            .logical_name = logical,
                            .wire_name = bound.wire_name,
                            .is_exported = is_exported,
                            .is_default_export = is_default_export and s_idx == 0,
                            .jsdoc = sig_ir.jsdoc orelse top_jsdoc,
                            .kind = .{ .function_decl = sig_ir },
                        });
                    }
                },
                .variable_decl => |ty_id| {
                    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
                    defer visited.deinit(self.scratch);
                    const lowered_ty = try self.lowerType(ty_id, false, outer_active_tps, null, &visited, imports_used, needs_runtime);

                    if (ty_id < self.graph.types.len and self.graph.types[ty_id].kind == .literal) {
                        const lit = self.graph.types[ty_id].kind.literal;
                        const lit_ir: LiteralValueIr = switch (lit) {
                            .str => |sid| .{ .str = try self.alloc.dupe(u8, self.str(sid)) },
                            .num => |n| .{ .num = n },
                            .bigint_literal => |sid| .{ .bigint_val = try self.alloc.dupe(u8, self.str(sid)) },
                            .boolean => |b| .{ .boolean = b },
                        };
                        try out_list.append(self.alloc, .{
                            .source_decl_id = decl_id,
                            .zig_ident = bound.zig_ident,
                            .logical_name = bound.logical_name,
                            .wire_name = bound.wire_name,
                            .is_exported = is_exported,
                            .is_default_export = is_default_export,
                            .jsdoc = top_jsdoc,
                            .kind = .{ .const_literal = .{ .ty = lowered_ty, .value = lit_ir } },
                        });
                    } else {
                        needs_runtime.* = true;
                        try out_list.append(self.alloc, .{
                            .source_decl_id = decl_id,
                            .zig_ident = bound.zig_ident,
                            .logical_name = bound.logical_name,
                            .wire_name = bound.wire_name,
                            .is_exported = is_exported,
                            .is_default_export = is_default_export,
                            .jsdoc = top_jsdoc,
                            .kind = .{ .global_var = lowered_ty },
                        });
                    }
                },
                .interface_decl => |iface| {
                    const struct_ir = try self.lowerStructDecl(
                        final_mod_idx,
                        decl_id,
                        false,
                        false,
                        d.type_params,
                        &.{},
                        iface.properties,
                        iface.methods,
                        iface.call_signatures,
                        iface.construct_signatures,
                        d.merged_with,
                        scope,
                        prebound_names,
                        prebound_overloads,
                        outer_active_tps,
                        imports_used,
                        needs_runtime,
                    );
                    try out_list.append(self.alloc, .{
                        .source_decl_id = decl_id,
                        .zig_ident = bound.zig_ident,
                        .logical_name = bound.logical_name,
                        .wire_name = bound.wire_name,
                        .is_exported = is_exported,
                        .is_default_export = is_default_export,
                        .jsdoc = top_jsdoc,
                        .kind = .{ .struct_decl = struct_ir },
                    });
                },
                .class_decl => |cls| {
                    const struct_ir = try self.lowerStructDecl(
                        final_mod_idx,
                        decl_id,
                        true,
                        d.modifiers.abstract_mod,
                        d.type_params,
                        cls.constructors,
                        cls.properties,
                        cls.methods,
                        &.{},
                        &.{},
                        d.merged_with,
                        scope,
                        prebound_names,
                        prebound_overloads,
                        outer_active_tps,
                        imports_used,
                        needs_runtime,
                    );
                    try out_list.append(self.alloc, .{
                        .source_decl_id = decl_id,
                        .zig_ident = bound.zig_ident,
                        .logical_name = bound.logical_name,
                        .wire_name = bound.wire_name,
                        .is_exported = is_exported,
                        .is_default_export = is_default_export,
                        .jsdoc = top_jsdoc,
                        .kind = .{ .struct_decl = struct_ir },
                    });
                },
                .enum_decl => |en| {
                    var member_scope = naming.ScopeNamer.initContainer(self.scratch, null);
                    defer member_scope.deinit();
                    try member_scope.reserve("zigar_js");

                    var members = try self.alloc.alloc(EnumMemberIr, en.members.len);
                    for (en.members, 0..) |m, idx| {
                        const m_wire = self.str(m.name);
                        const mb = try member_scope.bind(m_wire, .snake);
                        const val_ir: EnumValueIr = if (m.value) |mv| switch (mv) {
                            .num => |n| .{ .num = n },
                            .str => |sid| .{ .str = try self.alloc.dupe(u8, self.str(sid)) },
                            .bigint_literal, .boolean => .auto,
                        } else .auto;
                        members[idx] = .{
                            .zig_ident = try self.alloc.dupe(u8, mb.zig_ident),
                            .logical_name = try self.alloc.dupe(u8, mb.logical_name),
                            .wire_name = try self.alloc.dupe(u8, mb.wire_name),
                            .value = val_ir,
                            .jsdoc = try self.lowerJsDoc(m.jsdoc),
                        };
                        mb.deinit(self.scratch);
                    }
                    try out_list.append(self.alloc, .{
                        .source_decl_id = decl_id,
                        .zig_ident = bound.zig_ident,
                        .logical_name = bound.logical_name,
                        .wire_name = bound.wire_name,
                        .is_exported = is_exported,
                        .is_default_export = is_default_export,
                        .jsdoc = top_jsdoc,
                        .kind = .{ .enum_decl = .{ .is_const = en.is_const, .members = members } },
                    });
                },
                .type_alias_decl => |ty_id| {
                    var tp_scope = naming.ScopeNamer.initParam(self.scratch, scope);
                    defer tp_scope.deinit();
                    const tp_res = try self.lowerTypeParams(
                        d.type_params,
                        &tp_scope,
                        outer_active_tps,
                        null,
                        imports_used,
                        needs_runtime,
                    );

                    // 1. Non-generic string-literal union -> first-class Zig `enum`!
                    if (d.type_params.len == 0) {
                        if (try self.tryLowerStringEnum(ty_id)) |str_members| {
                            try out_list.append(self.alloc, .{
                                .source_decl_id = decl_id,
                                .zig_ident = bound.zig_ident,
                                .logical_name = bound.logical_name,
                                .wire_name = bound.wire_name,
                                .is_exported = is_exported,
                                .is_default_export = is_default_export,
                                .jsdoc = top_jsdoc,
                                .kind = .{ .string_enum_decl = str_members },
                            });
                            return;
                        }
                    }

                    // 2. Multi-arm discriminated/heterogeneous union -> Zig `union(enum)`!
                    if (try self.tryLowerUnionDeclVariants(ty_id, tp_res.active, imports_used, needs_runtime)) |variants| {
                        try out_list.append(self.alloc, .{
                            .source_decl_id = decl_id,
                            .zig_ident = bound.zig_ident,
                            .logical_name = bound.logical_name,
                            .wire_name = bound.wire_name,
                            .is_exported = is_exported,
                            .is_default_export = is_default_export,
                            .jsdoc = top_jsdoc,
                            .kind = .{ .union_decl = .{ .type_params = tp_res.ir, .variants = variants } },
                        });
                        return;
                    }

                    // 3. Inline object literal type alias (`type Opts = { ... }`) -> `struct`!
                    const resolved_obj_id: ?u32 = if (ty_id < self.graph.types.len and self.graph.types[ty_id].kind == .object_literal)
                        ty_id
                    else if (ty_id < self.graph.types.len and self.graph.types[ty_id].resolved_type != null and
                        self.graph.types[ty_id].kind != .reference and
                        self.graph.types[ty_id].resolved_type.? < self.graph.types.len and
                        self.graph.types[self.graph.types[ty_id].resolved_type.?].kind == .object_literal)
                        self.graph.types[ty_id].resolved_type.?
                    else
                        null;

                    if (resolved_obj_id) |oid| {
                        const obj = self.graph.types[oid].kind.object_literal;
                        if (obj.properties.len > 0 or obj.call_signatures.len > 0 or obj.construct_signatures.len > 0) {
                            const EmptyMethodStub = struct {
                                name: u32,
                                signatures: []const u32,
                                modifiers: packed struct { static_mod: bool = false },
                                jsdoc: @TypeOf(d.jsdoc),
                            };
                            const empty_methods: []const EmptyMethodStub = &.{};
                            const struct_ir = try self.lowerStructDecl(
                                final_mod_idx,
                                decl_id,
                                false,
                                false,
                                d.type_params,
                                &.{},
                                obj.properties,
                                empty_methods,
                                obj.call_signatures,
                                obj.construct_signatures,
                                &.{},
                                scope,
                                prebound_names,
                                prebound_overloads,
                                outer_active_tps,
                                imports_used,
                                needs_runtime,
                            );
                            try out_list.append(self.alloc, .{
                                .source_decl_id = decl_id,
                                .zig_ident = bound.zig_ident,
                                .logical_name = bound.logical_name,
                                .wire_name = bound.wire_name,
                                .is_exported = is_exported,
                                .is_default_export = is_default_export,
                                .jsdoc = top_jsdoc,
                                .kind = .{ .struct_decl = struct_ir },
                            });
                            return;
                        }
                    }

                    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
                    defer visited.deinit(self.scratch);
                    const target = try self.lowerType(ty_id, false, tp_res.active, null, &visited, imports_used, needs_runtime);
                    try out_list.append(self.alloc, .{
                        .source_decl_id = decl_id,
                        .zig_ident = bound.zig_ident,
                        .logical_name = bound.logical_name,
                        .wire_name = bound.wire_name,
                        .is_exported = is_exported,
                        .is_default_export = is_default_export,
                        .jsdoc = top_jsdoc,
                        .kind = .{ .type_alias = .{ .type_params = tp_res.ir, .target = target } },
                    });
                },
                .namespace_decl => |children| {
                    var ns_scope = naming.ScopeNamer.initContainer(self.scratch, scope);
                    defer ns_scope.deinit();
                    try ns_scope.reserve("zigar_js");
                    for (children) |cid| {
                        if (prebound_names.get(cid)) |cb| try ns_scope.reserve(cb.logical_name);
                        if (prebound_overloads.get(cid)) |ovs| {
                            for (ovs) |ov| try ns_scope.reserve(ov.logical_name);
                        }
                    }

                    var child_irs: std.ArrayList(DeclIr) = .empty;
                    for (children) |cid| {
                        try self.lowerDeclIntoList(
                            final_mod_idx,
                            cid,
                            &ns_scope,
                            prebound_names,
                            prebound_overloads,
                            outer_active_tps,
                            imports_used,
                            needs_runtime,
                            &child_irs,
                        );
                    }
                    try out_list.append(self.alloc, .{
                        .source_decl_id = decl_id,
                        .zig_ident = bound.zig_ident,
                        .logical_name = bound.logical_name,
                        .wire_name = bound.wire_name,
                        .is_exported = is_exported,
                        .is_default_export = is_default_export,
                        .jsdoc = top_jsdoc,
                        .kind = .{ .namespace_decl = try child_irs.toOwnedSlice(self.alloc) },
                    });
                },
                .re_export_decl => |re| {
                    const eff_name = if (d.export_name) |esid| self.str(esid) else self.str(d.name);
                    if (re.is_namespace and std.mem.eql(u8, eff_name, "*")) return;
                    if (re.is_namespace) {
                        if (try self.resolveNamespaceReExportTargetMod(re)) |t_mod_idx| {
                            if (t_mod_idx != final_mod_idx) {
                                try imports_used.put(self.scratch, t_mod_idx, {});
                                try out_list.append(self.alloc, .{
                                    .source_decl_id = decl_id,
                                    .zig_ident = bound.zig_ident,
                                    .logical_name = bound.logical_name,
                                    .wire_name = bound.wire_name,
                                    .is_exported = true,
                                    .is_default_export = is_default_export,
                                    .jsdoc = top_jsdoc,
                                    .kind = .{ .namespace_re_export = .{ .target_module_index = t_mod_idx } },
                                });
                            }
                        }
                        return;
                    }
                    if (try self.resolveNamedReExportTargetLoc(d, re, 0)) |loc| {
                        const is_self_noop = loc.module_index == final_mod_idx and
                            loc.zig_path.len == 1 and
                            std.mem.eql(u8, loc.zig_path[0], bound.zig_ident);
                        if (!is_self_noop and loc.zig_path.len > 0) {
                            if (loc.module_index != final_mod_idx) {
                                try imports_used.put(self.scratch, loc.module_index, {});
                            }
                            try out_list.append(self.alloc, .{
                                .source_decl_id = decl_id,
                                .zig_ident = bound.zig_ident,
                                .logical_name = bound.logical_name,
                                .wire_name = bound.wire_name,
                                .is_exported = true,
                                .is_default_export = is_default_export,
                                .jsdoc = top_jsdoc,
                                .kind = .{
                                    .re_export_decl = .{
                                        .target_module_index = loc.module_index,
                                        .target_zig_path = loc.zig_path,
                                    },
                                },
                            });
                        }
                    }
                },
                .import_equals_decl => |ie| {
                    if (!d.modifiers.export_decl) return;
                    if (ie.target_decl) |tdid| {
                        if (try self.resolveEffectiveReExportTarget(tdid, 0)) |loc| {
                            const is_self_noop = loc.module_index == final_mod_idx and
                                loc.zig_path.len == 1 and
                                std.mem.eql(u8, loc.zig_path[0], bound.zig_ident);
                            if (!is_self_noop and loc.zig_path.len > 0) {
                                if (loc.module_index != final_mod_idx) {
                                    try imports_used.put(self.scratch, loc.module_index, {});
                                }
                                try out_list.append(self.alloc, .{
                                    .source_decl_id = decl_id,
                                    .zig_ident = bound.zig_ident,
                                    .logical_name = bound.logical_name,
                                    .wire_name = bound.wire_name,
                                    .is_exported = true,
                                    .is_default_export = is_default_export,
                                    .jsdoc = top_jsdoc,
                                    .kind = .{
                                        .re_export_decl = .{
                                            .target_module_index = loc.module_index,
                                            .target_zig_path = loc.zig_path,
                                        },
                                    },
                                });
                            }
                        }
                    } else if (ie.module_specifier) |msid| {
                        if (try self.resolveSpecToCandidateIdx(self.str(msid))) |c_idx| {
                            if (self.candToFinalIndex(c_idx)) |t_mod_idx| {
                                if (t_mod_idx != final_mod_idx) {
                                    try imports_used.put(self.scratch, t_mod_idx, {});
                                    try out_list.append(self.alloc, .{
                                        .source_decl_id = decl_id,
                                        .zig_ident = bound.zig_ident,
                                        .logical_name = bound.logical_name,
                                        .wire_name = bound.wire_name,
                                        .is_exported = true,
                                        .is_default_export = is_default_export,
                                        .jsdoc = top_jsdoc,
                                        .kind = .{ .namespace_re_export = .{ .target_module_index = t_mod_idx } },
                                    });
                                }
                            }
                        }
                    }
                },
            }
        }

        fn chooseStructSelfIdent(
            self: *Self,
            raw_tps: []const u32,
            merged_ids: []const u32,
            parent_scope: *const naming.ScopeNamer,
            prebound_names: *const std.AutoHashMapUnmanaged(u32, naming.BoundName),
            prebound_overloads: *const std.AutoHashMapUnmanaged(u32, []naming.BoundName),
        ) error{OutOfMemory}![]const u8 {
            // Preview type-parameter bindings against `parent_scope` so `preview_tp.used` reflects
            // this struct's comptime type parameters while `preview_tp.isTakenInAnyAncestor` checks
            // EVERY enclosing scope (`parent_scope` — which already contains this struct's own outer
            // declaration name AND all sibling declarations — plus all outer namespaces/structs/modules!).
            var preview_tp = naming.ScopeNamer.initParam(self.scratch, parent_scope);
            defer preview_tp.deinit();
            for (raw_tps) |tp_id| {
                const raw_tp = if (tp_id < self.graph.type_params.len) self.str(self.graph.type_params[tp_id].name) else "T";
                const b = try preview_tp.bindWithFallbackSuffix(raw_tp, .pascal, "T");
                b.deinit(self.scratch);
            }

            var merged_used: std.StringHashMapUnmanaged(void) = .empty;
            defer merged_used.deinit(self.scratch);
            for (merged_ids) |mid| {
                if (self.merged_ns_consumed.contains(mid)) {
                    for (self.graph.decls[mid].kind.namespace_decl) |cid| {
                        if (prebound_names.get(cid)) |cb| try merged_used.put(self.scratch, cb.logical_name, {});
                        if (prebound_overloads.get(cid)) |ovs| {
                            for (ovs) |ov| try merged_used.put(self.scratch, ov.logical_name, {});
                        }
                    }
                }
            }

            var suffix_n: usize = 1;
            while (true) : (suffix_n += 1) {
                const cand = if (suffix_n == 1)
                    try self.scratch.dupe(u8, "Self")
                else
                    try std.fmt.allocPrint(self.scratch, "Self_{d}", .{suffix_n});
                defer self.scratch.free(cand);

                if (!preview_tp.used.contains(cand) and
                    !preview_tp.isTakenInAnyAncestor(cand) and
                    !merged_used.contains(cand))
                {
                    return try self.alloc.dupe(u8, cand);
                }
            }
        }

        fn lowerStructDecl(
            self: *Self,
            final_mod_idx: u32,
            _: u32,
            is_class: bool,
            is_abstract: bool,
            raw_tps: []const u32,
            raw_ctors: []const u32,
            raw_prop_ids: []const u32,
            raw_methods: anytype,
            call_sigs: []const u32,
            construct_sigs: []const u32,
            merged_ids: []const u32,
            parent_scope: *const naming.ScopeNamer,
            prebound_names: *const std.AutoHashMapUnmanaged(u32, naming.BoundName),
            prebound_overloads: *const std.AutoHashMapUnmanaged(u32, []naming.BoundName),
            outer_active_tps: []const ActiveTypeParam,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}!StructDeclIr {
            const self_ident = try self.chooseStructSelfIdent(
                raw_tps,
                merged_ids,
                parent_scope,
                prebound_names,
                prebound_overloads,
            );

            var tp_scope = naming.ScopeNamer.initParam(self.scratch, parent_scope);
            defer tp_scope.deinit();

            const tp_res = try self.lowerTypeParams(
                raw_tps,
                &tp_scope,
                outer_active_tps,
                self_ident,
                imports_used,
                needs_runtime,
            );

            var struct_scope = naming.ScopeNamer.initContainer(self.scratch, &tp_scope);
            defer struct_scope.deinit();
            try struct_scope.reserve("zigar_js");
            try struct_scope.reserve(self_ident);

            // Reserve merged namespace child decl names (and overloads) in `struct_scope` first.
            for (merged_ids) |mid| {
                if (self.merged_ns_consumed.contains(mid)) {
                    for (self.graph.decls[mid].kind.namespace_decl) |cid| {
                        if (prebound_names.get(cid)) |cb| try struct_scope.reserve(cb.logical_name);
                        if (prebound_overloads.get(cid)) |ovs| {
                            for (ovs) |ov| try struct_scope.reserve(ov.logical_name);
                        }
                    }
                }
            }

            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(self.scratch);

            // Instance fields share `struct_scope` so fields, static props, constructors, methods,
            // `Self`, and `zigar_js` can NEVER collide inside the same Zig struct!
            const fields = try self.lowerFields(
                raw_prop_ids,
                true,
                &struct_scope,
                tp_res.active,
                self_ident,
                &visited,
                imports_used,
                needs_runtime,
            );

            // Static properties.
            var static_props: std.ArrayList(StaticPropIr) = .empty;
            for (raw_prop_ids) |pid| {
                if (pid >= self.graph.properties.len) continue;
                const p = self.graph.properties[pid];
                if (!p.modifiers.static_mod) continue;
                const wire = self.str(p.name);
                const style: naming.NameStyle = if (isAllUpperOrUnderscore(wire)) .preserve else .snake;
                const sb = try struct_scope.bind(wire, style);
                visited.clearRetainingCapacity();
                const sty = try self.lowerType(p.ty, false, tp_res.active, self_ident, &visited, imports_used, needs_runtime);

                var lit_opt: ?LiteralValueIr = null;
                if (p.ty < self.graph.types.len and self.graph.types[p.ty].kind == .literal) {
                    lit_opt = switch (self.graph.types[p.ty].kind.literal) {
                        .str => |sid| .{ .str = try self.alloc.dupe(u8, self.str(sid)) },
                        .num => |n| .{ .num = n },
                        .bigint_literal => |sid| .{ .bigint_val = try self.alloc.dupe(u8, self.str(sid)) },
                        .boolean => |b| .{ .boolean = b },
                    };
                } else {
                    needs_runtime.* = true;
                }

                try static_props.append(self.alloc, .{
                    .zig_ident = try self.alloc.dupe(u8, sb.zig_ident),
                    .logical_name = try self.alloc.dupe(u8, sb.logical_name),
                    .wire_name = try self.alloc.dupe(u8, sb.wire_name),
                    .ty = sty,
                    .literal = lit_opt,
                    .jsdoc = try self.lowerJsDoc(p.jsdoc),
                });
                sb.deinit(self.scratch);
            }

            // Constructors (`init`, `init_2`, ...).
            const all_ctor_sigs = if (raw_ctors.len > 0) raw_ctors else construct_sigs;
            var ctors = try self.alloc.alloc(ConstructorIr, all_ctor_sigs.len);
            var ctor_idents = try self.scratch.alloc([]const u8, all_ctor_sigs.len);
            defer self.scratch.free(ctor_idents);
            for (all_ctor_sigs, 0..) |_, idx| {
                const cb = try struct_scope.bind("init", .camel);
                ctor_idents[idx] = try self.alloc.dupe(u8, cb.zig_ident);
                cb.deinit(self.scratch);
            }

            // Pre-bind all method names in `struct_scope` BEFORE lowering method parameter scopes so
            // NO method parameter can shadow ANY sibling method name on the struct!
            const BoundMethodSlot = struct {
                zig_ident: []const u8,
                logical_name: []const u8,
                wire_name: []const u8,
                is_static: bool,
                sig_id: u32,
                prop_jsdoc: ?JsDocIr,
            };
            var method_slots: std.ArrayList(BoundMethodSlot) = .empty;
            defer method_slots.deinit(self.scratch);

            for (raw_methods) |m| {
                const m_wire = self.str(m.name);
                const m_jsdoc = try self.lowerJsDoc(m.jsdoc);
                for (m.signatures) |sid| {
                    const mb = try struct_scope.bind(m_wire, .camel);
                    try method_slots.append(self.scratch, .{
                        .zig_ident = try self.alloc.dupe(u8, mb.zig_ident),
                        .logical_name = try self.alloc.dupe(u8, mb.logical_name),
                        .wire_name = try self.alloc.dupe(u8, mb.wire_name),
                        .is_static = m.modifiers.static_mod,
                        .sig_id = sid,
                        .prop_jsdoc = m_jsdoc,
                    });
                    mb.deinit(self.scratch);
                }
            }
            for (call_sigs) |sid| {
                const mb = try struct_scope.bind("call", .camel);
                try method_slots.append(self.scratch, .{
                    .zig_ident = try self.alloc.dupe(u8, mb.zig_ident),
                    .logical_name = try self.alloc.dupe(u8, mb.logical_name),
                    .wire_name = try self.alloc.dupe(u8, "call"),
                    .is_static = false,
                    .sig_id = sid,
                    .prop_jsdoc = null,
                });
                mb.deinit(self.scratch);
            }

            // Now `struct_scope` knows EVERY declaration inside this struct — lower constructors & methods!
            for (all_ctor_sigs, 0..) |sid, idx| {
                var c_sig = try self.lowerSignature(sid, &struct_scope, false, tp_res.active, self_ident, imports_used, needs_runtime);
                c_sig.return_type = try self.makeType(.{ .self_type = self_ident });
                ctors[idx] = .{
                    .zig_ident = ctor_idents[idx],
                    .signature = c_sig,
                    .jsdoc = c_sig.jsdoc,
                };
            }

            var methods = try self.alloc.alloc(MethodIr, method_slots.items.len);
            for (method_slots.items, 0..) |slot, idx| {
                const m_sig = try self.lowerSignature(
                    slot.sig_id,
                    &struct_scope,
                    !slot.is_static,
                    tp_res.active,
                    self_ident,
                    imports_used,
                    needs_runtime,
                );
                methods[idx] = .{
                    .zig_ident = slot.zig_ident,
                    .logical_name = slot.logical_name,
                    .wire_name = slot.wire_name,
                    .is_static = slot.is_static,
                    .signature = m_sig,
                    .jsdoc = m_sig.jsdoc orelse slot.prop_jsdoc,
                };
            }

            var nested_decls: std.ArrayList(DeclIr) = .empty;
            for (merged_ids) |mid| {
                if (self.merged_ns_consumed.contains(mid)) {
                    for (self.graph.decls[mid].kind.namespace_decl) |cid| {
                        try self.lowerDeclIntoList(
                            final_mod_idx,
                            cid,
                            &struct_scope,
                            prebound_names,
                            prebound_overloads,
                            tp_res.active,
                            imports_used,
                            needs_runtime,
                            &nested_decls,
                        );
                    }
                }
            }

            return .{
                .is_class = is_class,
                .is_abstract = is_abstract,
                .self_ident = self_ident,
                .type_params = tp_res.ir,
                .fields = fields,
                .static_props = try static_props.toOwnedSlice(self.alloc),
                .constructors = ctors,
                .methods = methods,
                .nested_decls = try nested_decls.toOwnedSlice(self.alloc),
            };
        }

        fn resolveFinalModFromSourceMod(self: *const Self, source_mod_id: u32) ?u32 {
            const cand_idx = self.source_mod_to_cand.get(source_mod_id) orelse return null;
            return self.candToFinalIndex(cand_idx);
        }

        fn candToFinalIndex(self: *const Self, cand_idx: u32) ?u32 {
            if (self.cand_to_final_map) |m| {
                if (cand_idx < m.len) return m[cand_idx];
            }
            return null;
        }

        fn resolveNamespaceReExportTargetMod(self: *Self, re: anytype) error{OutOfMemory}!?u32 {
            if (re.target_module) |tmid| {
                return self.resolveFinalModFromSourceMod(tmid);
            }
            const mspec = self.str(re.module_specifier);
            if (try self.resolveSpecToCandidateIdx(mspec)) |amb_cand| {
                return self.candToFinalIndex(amb_cand);
            }
            return null;
        }

        fn resolveNamedReExportTargetLoc(
            self: *Self,
            d: anytype,
            re: anytype,
            depth: usize,
        ) error{OutOfMemory}!?DeclLocation {
            if (depth > 64) return null;
            if (re.target_decl) |tdid| {
                return try self.resolveEffectiveReExportTarget(tdid, depth + 1);
            }
            const target_cand_opt: ?u32 = if (re.target_module) |tmid|
                self.source_mod_to_cand.get(tmid)
            else
                try self.resolveSpecToCandidateIdx(self.str(re.module_specifier));

            const target_cand_idx = target_cand_opt orelse return null;
            const orig_name = self.str(d.name);
            if (orig_name.len == 0) return null;

            const tcand = &self.candidates.items[target_cand_idx];
            for (tcand.exported_decl_ids.items) |edid| {
                if (edid >= self.graph.decls.len) continue;
                const ed = self.graph.decls[edid];
                const ew = if (ed.export_name) |esid| self.str(esid) else self.str(ed.name);
                if (std.mem.eql(u8, ew, orig_name)) {
                    return try self.resolveEffectiveReExportTarget(edid, depth + 1);
                }
            }
            for (tcand.foreign_exports.items) |fe| {
                if (fe.is_default_export or fe.decl_id >= self.graph.decls.len) continue;
                const fd = self.graph.decls[fe.decl_id];
                const fw = fe.wire_name_override orelse (if (fd.export_name) |esid| self.str(esid) else self.str(fd.name));
                if (std.mem.eql(u8, fw, orig_name)) {
                    return try self.resolveEffectiveReExportTarget(fe.decl_id, depth + 1);
                }
            }
            return null;
        }

        fn resolveEffectiveReExportTarget(self: *Self, did: u32, depth: usize) error{OutOfMemory}!?DeclLocation {
            if (depth > 64 or did >= self.graph.decls.len) return null;
            const d = self.graph.decls[did];
            switch (d.kind) {
                .re_export_decl => |re| {
                    const eff_name = if (d.export_name) |esid| self.str(esid) else self.str(d.name);
                    if (re.is_namespace and std.mem.eql(u8, eff_name, "*")) return null;
                    if (re.is_namespace) {
                        const owner_loc = self.decl_locations.get(did) orelse return null;
                        if (try self.resolveNamespaceReExportTargetMod(re)) |t_mod_idx| {
                            if (t_mod_idx != owner_loc.module_index) return owner_loc;
                        }
                        return null;
                    }
                    return try self.resolveNamedReExportTargetLoc(d, re, depth + 1);
                },
                .import_equals_decl => |ie| {
                    if (!d.modifiers.export_decl) return null;
                    if (ie.target_decl) |tdid| {
                        return try self.resolveEffectiveReExportTarget(tdid, depth + 1);
                    }
                    if (ie.module_specifier) |msid| {
                        const owner_loc = self.decl_locations.get(did) orelse return null;
                        if (try self.resolveSpecToCandidateIdx(self.str(msid))) |c_idx| {
                            if (self.candToFinalIndex(c_idx)) |t_mod_idx| {
                                if (t_mod_idx != owner_loc.module_index) return owner_loc;
                            }
                        }
                    }
                    return null;
                },
                else => return self.decl_locations.get(did),
            }
        }

        fn collectStarReExportsFromSourceMod(
            self: *Self,
            source_mod_id: u32,
            self_final_mod_idx: u32,
            visited_source_mods: *std.AutoHashMapUnmanaged(u32, void),
            visited_cands: *std.AutoHashMapUnmanaged(u32, void),
            out: *std.ArrayList(StarExportItem),
        ) error{OutOfMemory}!void {
            if (visited_source_mods.contains(source_mod_id)) return;
            try visited_source_mods.put(self.scratch, source_mod_id, {});

            if (self.findGraphModuleIndexById(source_mod_id)) |sm_idx| {
                const sm = self.graph.modules[sm_idx];
                if (self.resolveFinalModFromSourceMod(source_mod_id)) |t_final| {
                    if (t_final != self_final_mod_idx) {
                        for (sm.exports) |did| {
                            try out.append(self.scratch, .{ .decl_id = did });
                        }
                    }
                }
                for (sm.star_re_exports) |next_sm| {
                    try self.collectStarReExportsFromSourceMod(
                        next_sm,
                        self_final_mod_idx,
                        visited_source_mods,
                        visited_cands,
                        out,
                    );
                }
            }

            if (self.source_mod_to_cand.get(source_mod_id)) |sc_idx| {
                try self.collectStarReExportsFromCand(
                    sc_idx,
                    self_final_mod_idx,
                    visited_source_mods,
                    visited_cands,
                    out,
                );
            }
        }

        fn collectStarReExportsFromCand(
            self: *Self,
            cand_idx: u32,
            self_final_mod_idx: u32,
            visited_source_mods: *std.AutoHashMapUnmanaged(u32, void),
            visited_cands: *std.AutoHashMapUnmanaged(u32, void),
            out: *std.ArrayList(StarExportItem),
        ) error{OutOfMemory}!void {
            if (cand_idx >= self.candidates.items.len) return;
            if (visited_cands.contains(cand_idx)) return;
            try visited_cands.put(self.scratch, cand_idx, {});

            const cand = &self.candidates.items[cand_idx];
            if (self.candToFinalIndex(cand_idx)) |t_final| {
                if (t_final != self_final_mod_idx) {
                    for (cand.exported_decl_ids.items) |did| {
                        try out.append(self.scratch, .{ .decl_id = did });
                    }
                    for (cand.foreign_exports.items) |fe| {
                        if (!fe.is_default_export) {
                            try out.append(self.scratch, .{
                                .decl_id = fe.decl_id,
                                .wire_name_override = fe.wire_name_override,
                            });
                        }
                    }
                }
            }

            for (cand.star_re_export_source_mods.items) |smid| {
                try self.collectStarReExportsFromSourceMod(
                    smid,
                    self_final_mod_idx,
                    visited_source_mods,
                    visited_cands,
                    out,
                );
            }
            for (cand.star_re_export_specs.items) |mspec| {
                if (try self.resolveSpecToCandidateIdx(mspec)) |dep_cand| {
                    try self.collectStarReExportsFromCand(
                        dep_cand,
                        self_final_mod_idx,
                        visited_source_mods,
                        visited_cands,
                        out,
                    );
                }
            }
        }

        /// Breaks any by-value struct/union/tuple/alias cycles across the entire `PackageIr` by setting
        /// `decl_ref.indirect = true` (`*const Target` / `?*const Target`) on back-edges!
        fn breakValueTypeCycles(self: *Self, modules: []ModuleIr) !void {
            var decl_ptr_map: std.StringHashMapUnmanaged(*DeclIr) = .empty;
            defer {
                var it = decl_ptr_map.keyIterator();
                while (it.next()) |k| self.scratch.free(k.*);
                decl_ptr_map.deinit(self.scratch);
            }

            for (modules) |*m| {
                try indexDeclPointersByPath(self.scratch, m.index, &.{}, @constCast(m.decls), &decl_ptr_map);
            }

            // Visit state keyed by `"mod_idx:seg0.seg1"`: 1 = visiting (active stack), 2 = finished.
            var state: std.StringHashMapUnmanaged(u8) = .empty;
            defer {
                var it = state.keyIterator();
                while (it.next()) |k| self.scratch.free(k.*);
                state.deinit(self.scratch);
            }

            for (modules) |*m| {
                for (@constCast(m.decls)) |*d| {
                    try dfsValueCycleDeclByPath(self.scratch, self.alloc, m.index, &.{}, d, &decl_ptr_map, &state);
                }
            }
        }

        fn build(self: *Self) LowerError![]ModuleIr {
            try self.discoverCandidates();
            const selected_cands = try self.filterAndCloseDependencies();

            var map_slice = try self.alloc.alloc(?u32, self.candidates.items.len);
            @memset(map_slice, null);
            for (selected_cands, 0..) |cand_idx, final_i| {
                map_slice[cand_idx] = @intCast(final_i);
            }
            self.cand_to_final_map = map_slice;

            // Pass 1: Pre-bind canonical module-level scopes & declaration locations across all
            // selected modules first so cross-module and cyclic references resolve deterministically!
            var mod_scopes = try self.scratch.alloc(naming.ScopeNamer, selected_cands.len);
            for (mod_scopes) |*ms| ms.* = naming.ScopeNamer.initContainer(self.scratch, null);
            defer {
                for (mod_scopes) |*ms| ms.deinit();
                self.scratch.free(mod_scopes);
            }

            var prebound_names: std.AutoHashMapUnmanaged(u32, naming.BoundName) = .empty;
            defer prebound_names.deinit(self.scratch);

            var prebound_overloads: std.AutoHashMapUnmanaged(u32, []naming.BoundName) = .empty;
            defer prebound_overloads.deinit(self.scratch);

            for (selected_cands, 0..) |cand_idx, final_i| {
                var ms = &mod_scopes[final_i];
                try ms.reserve("__root");
                try ms.reserve("__zigar_mod");
                try ms.reserve("__zigar_js");
                try ms.reserve("zigar_js");
                for (0..selected_cands.len) |dep_i| {
                    const mod_alias = try std.fmt.allocPrint(self.scratch, "__mod_{d}", .{dep_i});
                    defer self.scratch.free(mod_alias);
                    try ms.reserve(mod_alias);
                }

                try self.prebindScopeDecls(
                    @intCast(final_i),
                    self.candidates.items[cand_idx].decl_ids.items,
                    ms,
                    &.{},
                    &prebound_names,
                    &prebound_overloads,
                );
            }

            // Pass 2: Pre-bind foreign exports (`export *` expanded into `mod.exports`, cross-module
            // `default_export` / `export_equals`) and `star_re_export_source_mods` into `mod_scopes`
            // BEFORE lowering any module's functions so no parameter can shadow a re-exported symbol!
            var planned_re_exports = try self.scratch.alloc(std.ArrayList(PlannedReExport), selected_cands.len);
            for (planned_re_exports) |*pl| pl.* = .empty;
            defer {
                for (planned_re_exports) |*pl| pl.deinit(self.scratch);
                self.scratch.free(planned_re_exports);
            }

            for (selected_cands, 0..) |cand_idx, final_i| {
                const cand = &self.candidates.items[cand_idx];
                const final_mod_idx: u32 = @intCast(final_i);
                var ms = &mod_scopes[final_i];

                var seen_non_default_decls: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer seen_non_default_decls.deinit(self.scratch);

                var seen_export_wires: std.StringHashMapUnmanaged(void) = .empty;
                defer seen_export_wires.deinit(self.scratch);
                for (cand.exported_decl_ids.items) |edid| {
                    if (edid >= self.graph.decls.len) continue;
                    const ed = self.graph.decls[edid];
                    if (ed.modifiers.default_export) continue;
                    const ew = if (ed.export_name) |esid| self.str(esid) else self.str(ed.name);
                    if (ew.len > 0) try seen_export_wires.put(self.scratch, ew, {});
                }

                for (cand.foreign_exports.items) |fe| {
                    if (self.merged_ns_consumed.contains(fe.decl_id)) continue;
                    if (fe.decl_id >= self.graph.decls.len) continue;
                    const sd = self.graph.decls[fe.decl_id];
                    const loc = (try self.resolveEffectiveReExportTarget(fe.decl_id, 0)) orelse continue;
                    if (loc.zig_path.len == 0 or loc.module_index == final_mod_idx) continue;

                    const export_wire = fe.wire_name_override orelse
                        (if (sd.export_name) |esid| self.str(esid) else self.str(sd.name));
                    const style: naming.NameStyle = if (fe.wire_name_override != null) .preserve else self.declNameStyle(sd);

                    if (!fe.is_default_export) {
                        if (seen_non_default_decls.contains(fe.decl_id) or seen_export_wires.contains(export_wire)) continue;
                        const desired_styled = switch (style) {
                            .preserve => try self.scratch.dupe(u8, export_wire),
                            .camel => try naming.toCamelCase(self.scratch, export_wire),
                            .pascal => try naming.toPascalCase(self.scratch, export_wire),
                            .snake => try naming.toSnakeCase(self.scratch, export_wire),
                        };
                        defer self.scratch.free(desired_styled);
                        const base_check = if (desired_styled.len == 0) "_empty" else desired_styled;
                        if (ms.isTaken(base_check)) continue;
                        try seen_non_default_decls.put(self.scratch, fe.decl_id, {});
                        if (export_wire.len > 0) try seen_export_wires.put(self.scratch, export_wire, {});
                    }

                    const sb = try ms.bind(export_wire, style);
                    try planned_re_exports[final_i].append(self.scratch, .{
                        .source_decl_id = fe.decl_id,
                        .zig_ident = try self.alloc.dupe(u8, sb.zig_ident),
                        .logical_name = try self.alloc.dupe(u8, sb.logical_name),
                        .wire_name = try self.alloc.dupe(u8, sb.wire_name),
                        .is_default_export = fe.is_default_export,
                        .target_module_index = loc.module_index,
                        .target_zig_path = loc.zig_path,
                    });
                    sb.deinit(self.scratch);
                }

                var visited_star_smods: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer visited_star_smods.deinit(self.scratch);
                for (cand.source_mod_ids.items) |self_smid| {
                    try visited_star_smods.put(self.scratch, self_smid, {});
                }

                var visited_star_cands: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer visited_star_cands.deinit(self.scratch);
                try visited_star_cands.put(self.scratch, cand_idx, {});

                var star_items: std.ArrayList(StarExportItem) = .empty;
                defer star_items.deinit(self.scratch);
                for (cand.star_re_export_source_mods.items) |smid| {
                    try self.collectStarReExportsFromSourceMod(
                        smid,
                        final_mod_idx,
                        &visited_star_smods,
                        &visited_star_cands,
                        &star_items,
                    );
                }
                for (cand.star_re_export_specs.items) |mspec| {
                    if (try self.resolveSpecToCandidateIdx(mspec)) |dep_cand| {
                        try self.collectStarReExportsFromCand(
                            dep_cand,
                            final_mod_idx,
                            &visited_star_smods,
                            &visited_star_cands,
                            &star_items,
                        );
                    }
                }

                for (star_items.items) |item| {
                    if (self.merged_ns_consumed.contains(item.decl_id)) continue;
                    if (item.decl_id >= self.graph.decls.len) continue;
                    const sd = self.graph.decls[item.decl_id];
                    if (sd.modifiers.default_export) continue;
                    const loc = (try self.resolveEffectiveReExportTarget(item.decl_id, 0)) orelse continue;
                    if (loc.zig_path.len == 0 or loc.module_index == final_mod_idx) continue;

                    const export_wire = item.wire_name_override orelse
                        (if (sd.export_name) |esid| self.str(esid) else self.str(sd.name));
                    if (seen_export_wires.contains(export_wire)) continue;
                    if (item.wire_name_override == null and seen_non_default_decls.contains(item.decl_id)) continue;

                    const style: naming.NameStyle = if (item.wire_name_override != null) .preserve else self.declNameStyle(sd);
                    const desired_styled = switch (style) {
                        .preserve => try self.scratch.dupe(u8, export_wire),
                        .camel => try naming.toCamelCase(self.scratch, export_wire),
                        .pascal => try naming.toPascalCase(self.scratch, export_wire),
                        .snake => try naming.toSnakeCase(self.scratch, export_wire),
                    };
                    defer self.scratch.free(desired_styled);
                    const base_check = if (desired_styled.len == 0) "_empty" else desired_styled;

                    // `export *` in TypeScript does NOT override a direct export of the same name.
                    if (ms.isTaken(base_check)) continue;
                    if (item.wire_name_override == null) {
                        try seen_non_default_decls.put(self.scratch, item.decl_id, {});
                    }
                    if (export_wire.len > 0) {
                        try seen_export_wires.put(self.scratch, export_wire, {});
                    }

                    const sb = try ms.bind(export_wire, style);
                    try planned_re_exports[final_i].append(self.scratch, .{
                        .source_decl_id = item.decl_id,
                        .zig_ident = try self.alloc.dupe(u8, sb.zig_ident),
                        .logical_name = try self.alloc.dupe(u8, sb.logical_name),
                        .wire_name = try self.alloc.dupe(u8, sb.wire_name),
                        .is_default_export = false,
                        .target_module_index = loc.module_index,
                        .target_zig_path = loc.zig_path,
                    });
                    sb.deinit(self.scratch);
                }
            }

            // Assign unique `root.zig` export identifiers for all emitted modules, binding
            // `is_primary` modules first so non-primary transitive modules never shadow them!
            var root_scope = naming.ScopeNamer.initContainer(self.scratch, null);
            defer root_scope.deinit();
            try root_scope.reserve("zigar_js");

            var root_export_idents = try self.scratch.alloc([]const u8, selected_cands.len);
            defer self.scratch.free(root_export_idents);
            var root_export_logicals = try self.scratch.alloc([]const u8, selected_cands.len);
            defer self.scratch.free(root_export_logicals);

            for ([_]bool{ true, false }) |primary_pass| {
                for (selected_cands, 0..) |cand_idx, final_i| {
                    const cand = &self.candidates.items[cand_idx];
                    if (cand.is_primary != primary_pass) continue;
                    const rb = try root_scope.bind(cand.substituted_specifier, .snake);
                    root_export_idents[final_i] = try self.alloc.dupe(u8, rb.zig_ident);
                    root_export_logicals[final_i] = try self.alloc.dupe(u8, rb.logical_name);
                    rb.deinit(self.scratch);
                }
            }

            var modules = try self.alloc.alloc(ModuleIr, selected_cands.len);

            // Pass 3: Lower declarations and append planned cross-module re-export aliases!
            for (selected_cands, 0..) |cand_idx, final_i| {
                const cand = &self.candidates.items[cand_idx];
                const final_mod_idx: u32 = @intCast(final_i);
                const ms = &mod_scopes[final_i];

                const root_export_ident = root_export_idents[final_i];
                const root_export_logical = root_export_logicals[final_i];

                var imports_used: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer imports_used.deinit(self.scratch);
                var needs_runtime = false;

                var decl_irs: std.ArrayList(DeclIr) = .empty;
                for (cand.decl_ids.items) |did| {
                    try self.lowerDeclIntoList(
                        final_mod_idx,
                        did,
                        ms,
                        &prebound_names,
                        &prebound_overloads,
                        &.{},
                        &imports_used,
                        &needs_runtime,
                        &decl_irs,
                    );
                }

                for (planned_re_exports[final_i].items) |pre| {
                    try imports_used.put(self.scratch, pre.target_module_index, {});
                    try decl_irs.append(self.alloc, .{
                        .source_decl_id = pre.source_decl_id,
                        .zig_ident = pre.zig_ident,
                        .logical_name = pre.logical_name,
                        .wire_name = pre.wire_name,
                        .is_exported = true,
                        .is_default_export = pre.is_default_export,
                        .jsdoc = null,
                        .kind = .{
                            .re_export_decl = .{
                                .target_module_index = pre.target_module_index,
                                .target_zig_path = pre.target_zig_path,
                            },
                        },
                    });
                }

                // Deterministic sorted module imports (excluding self-imports).
                var dep_indices: std.ArrayList(u32) = .empty;
                defer dep_indices.deinit(self.scratch);
                var imp_it = imports_used.keyIterator();
                while (imp_it.next()) |dep_ptr| {
                    if (dep_ptr.* != final_mod_idx) {
                        try dep_indices.append(self.scratch, dep_ptr.*);
                    }
                }
                std.mem.sort(u32, dep_indices.items, {}, std.sort.asc(u32));

                var mod_imports = try self.alloc.alloc(ModuleImportIr, dep_indices.items.len);
                for (dep_indices.items, 0..) |dep_idx, i_pos| {
                    const target_cand = &self.candidates.items[selected_cands[dep_idx]];
                    const alias_raw = try std.fmt.allocPrint(self.alloc, "__mod_{d}", .{dep_idx});
                    const rel_imp = try naming.relativeImportPath(
                        self.alloc,
                        cand.rel_zig_path,
                        target_cand.rel_zig_path,
                    );
                    mod_imports[i_pos] = .{
                        .target_module_index = dep_idx,
                        .local_alias = alias_raw,
                        .rel_import_path = rel_imp,
                    };
                }

                modules[final_i] = .{
                    .index = final_mod_idx,
                    .specifier = cand.substituted_specifier,
                    .wire_specifier = cand.wire_specifier,
                    .rel_zig_path = cand.rel_zig_path,
                    .root_export_ident = root_export_ident,
                    .root_export_logical_name = root_export_logical,
                    .is_primary = cand.is_primary,
                    .needs_root_runtime = needs_runtime,
                    .imports = mod_imports,
                    .decls = try decl_irs.toOwnedSlice(self.alloc),
                };
            }

            try self.breakValueTypeCycles(modules);
            return modules;
        }
    };
}

fn appendUniqueU32(list: *std.ArrayList(u32), allocator: std.mem.Allocator, val: u32) !void {
    for (list.items) |existing| {
        if (existing == val) return;
    }
    try list.append(allocator, val);
}

fn isAllUpperOrUnderscore(s: []const u8) bool {
    if (s.len == 0) return false;
    var has_upper = false;
    for (s) |ch| {
        if (std.ascii.isUpper(ch)) {
            has_upper = true;
        } else if (!std.ascii.isDigit(ch) and ch != '_') {
            return false;
        }
    }
    return has_upper;
}

fn builtinTypedArrayElem(name: []const u8) ?PrimSliceElem {
    const map = std.StaticStringMap(PrimSliceElem).initComptime(.{
        .{ "Int8Array", .i8 },
        .{ "Uint16Array", .u16 },
        .{ "Int16Array", .i16 },
        .{ "Uint32Array", .u32 },
        .{ "Int32Array", .i32 },
        .{ "BigUint64Array", .u64 },
        .{ "BigInt64Array", .i64 },
        .{ "Float32Array", .f32 },
        .{ "Float64Array", .f64 },
    });
    return map.get(name);
}

fn formatDeclCycleKey(
    allocator: std.mem.Allocator,
    mod_idx: u32,
    prefix: []const []const u8,
    leaf: ?[]const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "{d}:", .{mod_idx});
    for (prefix, 0..) |seg, i| {
        if (i > 0) try out.append(allocator, '.');
        try out.appendSlice(allocator, seg);
    }
    if (leaf) |lf| {
        if (prefix.len > 0) try out.append(allocator, '.');
        try out.appendSlice(allocator, lf);
    }
    return try out.toOwnedSlice(allocator);
}

fn indexDeclPointersByPath(
    allocator: std.mem.Allocator,
    mod_idx: u32,
    prefix: []const []const u8,
    decls: []DeclIr,
    map: *std.StringHashMapUnmanaged(*DeclIr),
) error{OutOfMemory}!void {
    for (decls) |*d| {
        const key = try formatDeclCycleKey(allocator, mod_idx, prefix, d.zig_ident);
        const gop = try map.getOrPut(allocator, key);
        if (gop.found_existing) {
            allocator.free(key);
        } else {
            gop.value_ptr.* = d;
        }

        switch (d.kind) {
            .namespace_decl => |children| {
                const sub_prefix = try allocator.alloc([]const u8, prefix.len + 1);
                defer allocator.free(sub_prefix);
                @memcpy(sub_prefix[0..prefix.len], prefix);
                sub_prefix[prefix.len] = d.zig_ident;
                try indexDeclPointersByPath(allocator, mod_idx, sub_prefix, @constCast(children), map);
            },
            .struct_decl => |*st| {
                if (st.nested_decls.len > 0) {
                    const sub_prefix = try allocator.alloc([]const u8, prefix.len + 1);
                    defer allocator.free(sub_prefix);
                    @memcpy(sub_prefix[0..prefix.len], prefix);
                    sub_prefix[prefix.len] = d.zig_ident;
                    try indexDeclPointersByPath(allocator, mod_idx, sub_prefix, @constCast(st.nested_decls), map);
                }
            },
            else => {},
        }
    }
}

fn dfsValueCycleDeclByPath(
    state_alloc: std.mem.Allocator,
    ir_alloc: std.mem.Allocator,
    mod_idx: u32,
    prefix: []const []const u8,
    d: *DeclIr,
    decl_map: *const std.StringHashMapUnmanaged(*DeclIr),
    state: *std.StringHashMapUnmanaged(u8),
) error{OutOfMemory}!void {
    const self_key = try formatDeclCycleKey(state_alloc, mod_idx, prefix, d.zig_ident);
    if (state.get(self_key)) |st| {
        state_alloc.free(self_key);
        if (st == 2 or st == 1) return;
    }
    try state.put(state_alloc, self_key, 1);

    switch (d.kind) {
        .struct_decl => |*st| {
            for (st.fields) |f| {
                try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(f.ty), decl_map, state);
            }
            if (st.nested_decls.len > 0) {
                const sub_prefix = try state_alloc.alloc([]const u8, prefix.len + 1);
                defer state_alloc.free(sub_prefix);
                @memcpy(sub_prefix[0..prefix.len], prefix);
                sub_prefix[prefix.len] = d.zig_ident;
                for (@constCast(st.nested_decls)) |*nd| {
                    try dfsValueCycleDeclByPath(state_alloc, ir_alloc, mod_idx, sub_prefix, nd, decl_map, state);
                }
            }
        },
        .union_decl => |*un| {
            for (un.variants) |v| {
                try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(v.payload), decl_map, state);
            }
        },
        .type_alias => |*ta| {
            try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(ta.target), decl_map, state);
        },
        .re_export_decl => |re| {
            const target_key = try formatDeclCycleKey(state_alloc, re.target_module_index, re.target_zig_path, null);
            defer state_alloc.free(target_key);
            if (decl_map.get(target_key)) |target_decl| {
                const parent_prefix = if (re.target_zig_path.len > 1)
                    re.target_zig_path[0 .. re.target_zig_path.len - 1]
                else
                    &[_][]const u8{};
                try dfsValueCycleDeclByPath(state_alloc, ir_alloc, re.target_module_index, parent_prefix, target_decl, decl_map, state);
            }
        },
        .namespace_decl => |children| {
            const sub_prefix = try state_alloc.alloc([]const u8, prefix.len + 1);
            defer state_alloc.free(sub_prefix);
            @memcpy(sub_prefix[0..prefix.len], prefix);
            sub_prefix[prefix.len] = d.zig_ident;
            for (@constCast(children)) |*cd| {
                try dfsValueCycleDeclByPath(state_alloc, ir_alloc, mod_idx, sub_prefix, cd, decl_map, state);
            }
        },
        else => {},
    }

    if (state.getPtr(self_key)) |st_ptr| {
        st_ptr.* = 2;
    }
}

fn dfsValueCycleTypeByPath(
    state_alloc: std.mem.Allocator,
    ir_alloc: std.mem.Allocator,
    ty: *TypeIr,
    decl_map: *const std.StringHashMapUnmanaged(*DeclIr),
    state: *std.StringHashMapUnmanaged(u8),
) error{OutOfMemory}!void {
    switch (ty.*) {
        // Indirection boundaries (pointer/slice/fn/runtime handle) cannot cause a value-size dependency loop!
        .slice, .pointer_const, .fn_ptr, .promise, .js_map => return,
        .self_type => |sid| {
            const inner = try ir_alloc.create(TypeIr);
            inner.* = .{ .self_type = sid };
            ty.* = .{ .pointer_const = inner };
        },
        .optional => |inner| {
            try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(inner), decl_map, state);
        },
        .tuple => |elems| {
            for (elems) |el| {
                try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(el.ty), decl_map, state);
            }
        },
        .anon_struct => |fields| {
            for (fields) |f| {
                try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(f.ty), decl_map, state);
            }
        },
        .tagged_union => |vars| {
            for (vars) |v| {
                try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(v.payload), decl_map, state);
            }
        },
        .decl_ref => {
            if (ty.decl_ref.indirect) return;
            const target_key = try formatDeclCycleKey(state_alloc, ty.decl_ref.module_index, ty.decl_ref.decl_zig_path, null);
            defer state_alloc.free(target_key);
            if (state.get(target_key)) |st| {
                if (st == 1) {
                    // Cycle back-edge detected! Mutate `ty.decl_ref` directly in place (`*const Target`).
                    ty.decl_ref.indirect = true;
                    return;
                }
                if (st == 2) return;
            }
            if (decl_map.get(target_key)) |target_decl| {
                const parent_prefix = if (ty.decl_ref.decl_zig_path.len > 1)
                    ty.decl_ref.decl_zig_path[0 .. ty.decl_ref.decl_zig_path.len - 1]
                else
                    &[_][]const u8{};
                try dfsValueCycleDeclByPath(
                    state_alloc,
                    ir_alloc,
                    ty.decl_ref.module_index,
                    parent_prefix,
                    target_decl,
                    decl_map,
                    state,
                );
            }
        },
        else => {},
    }
}

test "applySubstitutions and moduleMatchesPattern handle prefixes and node: normalization" {
    const alloc = std.testing.allocator;

    const rules = [_]cli.Substitution{
        .{ .from = "node:fs", .to = "fs" },
        .{ .from = "foo/internal", .to = "foo" },
    };

    {
        const s = try applySubstitutions(alloc, "node:fs/promises", &rules);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("fs/promises", s);
    }
    {
        const s = try applySubstitutions(alloc, "foo/internal/bar", &rules);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("foo/bar", s);
    }
    {
        const s = try applySubstitutions(alloc, "foo/internal_other", &rules);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("foo/internal_other", s);
    }

    try std.testing.expect(moduleMatchesPattern("node:http", "node:http", "http"));
    try std.testing.expect(moduleMatchesPattern("http", "http", "node:http"));
    try std.testing.expect(moduleMatchesPattern("dns/promises", "dns/promises", "dns/promises"));
    try std.testing.expect(moduleMatchesPattern("monaco.editor", "monaco/editor", "monaco.editor"));
    try std.testing.expect(!moduleMatchesPattern("http2", "http2", "http"));
}
