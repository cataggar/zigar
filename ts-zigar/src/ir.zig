const std = @import("std");
const cli = @import("cli.zig");
const naming = @import("naming.zig");
const lower_types = @import("lower_types.zig");
const lower_unions = @import("lower_unions.zig");
const classify_decls = @import("classify_decls.zig");
const lower_objects = @import("lower_objects.zig");

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
    nullish_kind: lower_types.NullishKind = .none,
};

pub const SignatureIr = struct {
    self_param_ident: ?[]const u8 = null,
    alloc_param_ident: ?[]const u8 = null,
    type_params: []const TypeParamIr,
    params: []const ParamIr,
    return_type: *const TypeIr,
    has_type_predicate: bool,
    type_predicate_asserts: bool,
    jsdoc: ?JsDocIr,
};

pub const FieldLiteralConstraintIr = union(enum) {
    str: []const u8,
    num: f64,
    bigint_val: []const u8,
    boolean: bool,
    enum_member: struct {
        enum_decl_id: u32,
        tag_zig_ident: []const u8,
        tag_logical_name: []const u8,
    },
};

pub const FieldIr = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_name: []const u8,
    ty: *const TypeIr,
    is_optional: bool,
    is_readonly: bool,
    nullish_kind: lower_types.NullishKind = .none,
    literal_constraint: ?FieldLiteralConstraintIr = null,
    jsdoc: ?JsDocIr,
};

pub const MethodIr = struct {
    zig_ident: []const u8,
    alloc_companion_ident: ?[]const u8 = null,
    logical_name: []const u8,
    wire_name: []const u8,
    is_static: bool,
    call_kind: lower_objects.MethodCallKind = .method,
    signature: SignatureIr,
    jsdoc: ?JsDocIr,
};

pub const EnumValueIr = union(enum) {
    unknown,
    num: f64,
    str: []const u8,
    boolean: bool,
    bigint_val: []const u8,
};

pub const EnumMemberIr = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_name: []const u8,
    value: EnumValueIr,
    int_backing_val: ?i64 = null,
    alias_of_zig_ident: ?[]const u8 = null,
    alias_of_logical_name: ?[]const u8 = null,
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
    is_variadic: bool = false,
    nullish_kind: lower_types.NullishKind = .none,
};

pub const OptionalTypeIr = struct {
    child: *const TypeIr,
    nullish_kind: lower_types.NullishKind = .null_or_undefined,
    is_pure_nullish: bool = false,
};

pub const VariantDiscriminantValueIr = union(enum) {
    str: []const u8,
    num: f64,
    boolean: bool,
    bigint_val: []const u8,
};

pub const UnionVariantIr = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_tag: []const u8,
    payload: *const TypeIr,
    unit_literal: ?EnumValueIr = null,
    disc_values: []const VariantDiscriminantValueIr = &.{},
};

pub const TaggedUnionIr = struct {
    discriminant_prop: ?[]const u8 = null,
    variants: []const UnionVariantIr,
};

pub const InlineEnumIr = struct {
    backing: lower_unions.EnumBackingKind,
    members: []const EnumMemberIr,
};

pub const OpenLiteralUnionIr = struct {
    base_kind: lower_unions.OpenPrimitiveKind,
    known_members: []const EnumMemberIr,
    custom_tag_ident: []const u8,
    custom_logical_name: []const u8,
    custom_payload: *const TypeIr,
};

pub const TemplateSpanIr = struct {
    placeholder: lower_unions.TemplatePlaceholderKind,
    choices: []const []const u8 = &.{},
    literal_tail: []const u8,
};

pub const TemplatePatternIr = struct {
    head: []const u8,
    spans: []const TemplateSpanIr,
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
    js_any,
    js_unknown,
    js_object,
    js_function,
    js_symbol,
    js_bigint,
    js_string,
    binary_view: lower_types.BinaryViewKind,
    self_type: []const u8,
    type_param_ref: []const u8,
    optional: OptionalTypeIr,
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
    inline_enum: InlineEnumIr,
    open_literal_union: OpenLiteralUnionIr,
    template_pattern: TemplatePatternIr,
    tagged_union: TaggedUnionIr,
    decl_ref: DeclRefIr,
};

pub const StaticPropIr = struct {
    zig_ident: []const u8,
    logical_name: []const u8,
    wire_name: []const u8,
    access_kind: lower_objects.StaticPropAccessKind = .read_write,
    ty: *const TypeIr,
    setter_ty: ?*const TypeIr = null,
    literal: ?LiteralValueIr,
    jsdoc: ?JsDocIr,
};

pub const InstancePropIr = struct {
    wire_name: []const u8,
    is_optional: bool,
    getter_ident: ?[]const u8 = null,
    getter_alloc_ident: ?[]const u8 = null,
    getter_alloc_param_ident: []const u8 = "allocator",
    getter_ty: ?*const TypeIr = null,
    setter_ident: ?[]const u8 = null,
    setter_param_ident: []const u8 = "value",
    setter_ty: ?*const TypeIr = null,
    setter_is_optional: bool = false,
    jsdoc: ?JsDocIr = null,
};

pub const ConstructorIr = struct {
    zig_ident: []const u8,
    signature: SignatureIr,
    jsdoc: ?JsDocIr,
};

pub const StructDeclIr = struct {
    repr: classify_decls.ObjectDeclKind = .value_struct,
    is_class: bool,
    is_abstract: bool,
    is_callable_handle: bool = false,
    has_private_constructor: bool = false,
    has_non_public_members: bool = false,
    self_ident: []const u8,
    ref_field_ident: []const u8 = "ref",
    self_param_ident: []const u8 = "__zigar_self",
    raw_param_ident: []const u8 = "__zigar_raw",
    alloc_param_ident: []const u8 = "__zigar_alloc",
    to_js_ref_ident: ?[]const u8 = null,
    from_js_ref_ident: ?[]const u8 = null,
    from_js_ref_alloc_ident: ?[]const u8 = null,
    deinit_ident: ?[]const u8 = null,
    required_methods: []const []const u8 = &.{},
    required_props: []const []const u8 = &.{},
    type_params: []const TypeParamIr,
    fields: []const FieldIr,
    instance_props: []const InstancePropIr = &.{},
    static_props: []const StaticPropIr,
    constructors: []const ConstructorIr,
    methods: []const MethodIr,
    nested_decls: []const DeclIr,
};

pub const UnionDeclIr = struct {
    type_params: []const TypeParamIr,
    discriminant_prop: ?[]const u8 = null,
    variants: []const UnionVariantIr,
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
        has_unknown_values: bool = false,
        backing: lower_unions.EnumBackingKind = .none,
        members: []const EnumMemberIr,
    },
    literal_enum_decl: InlineEnumIr,
    open_literal_decl: OpenLiteralUnionIr,
    template_pattern_decl: TemplatePatternIr,
    union_decl: UnionDeclIr,
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
    is_js_exported: bool = true,
    is_default_export: bool,
    is_global_scope: bool = false,
    alloc_companion_ident: ?[]const u8 = null,
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
    export_equals_ident: ?[]const u8 = null,
    export_equals_wire_name: ?[]const u8 = null,
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

    var scratch_arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer scratch_arena.deinit();

    var ctx = LowerCtx(@TypeOf(graph)){
        .alloc = alloc,
        .scratch = scratch_arena.allocator(),
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
            same_mod_export_equals_children: std.ArrayList(u32) = .empty,
            star_re_export_source_mods: std.ArrayList(u32) = .empty,
            star_re_export_specs: std.ArrayList([]const u8) = .empty,
            default_export_decl_id: ?u32 = null,
            export_equals_decl_id: ?u32 = null,
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
            zig_ident: []const u8 = "",
            subst_ty: ?*TypeIr = null,
        };

        const DeclNodeType = std.meta.Elem(@FieldType(GraphType, "decls"));
        const DeclKindType = @FieldType(DeclNodeType, "kind");
        const IfaceDataType = @FieldType(DeclKindType, "interface_decl");
        const MethodNodeType = std.meta.Elem(@FieldType(IfaceDataType, "methods"));

        const HeritageBinding = struct {
            ts_name: []const u8,
            arg_ty_id: ?u32,
            arg_in_self_env: bool = false,
        };

        const HeritageEnv = struct {
            bindings: []const HeritageBinding,
            parent: ?*const HeritageEnv = null,
        };

        const SourcedProp = struct {
            pid: u32,
            env: ?*const HeritageEnv = null,
        };

        const SourcedMethod = struct {
            method: MethodNodeType,
            env: ?*const HeritageEnv = null,
        };

        const SourcedSig = struct {
            sid: u32,
            env: ?*const HeritageEnv = null,
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
        merged_iface_consumed: std.AutoHashMapUnmanaged(u32, void) = .empty,
        merged_ctor_var_consumed: std.AutoHashMapUnmanaged(u32, void) = .empty,
        decl_classifications: std.AutoHashMapUnmanaged(u32, classify_decls.DeclClassification) = .empty,
        merged_generic_ns_peer: std.AutoHashMapUnmanaged(u32, u32) = .empty,
        merged_generic_ns_set: std.AutoHashMapUnmanaged(u32, void) = .empty,
        pure_export_equals_ns: std.AutoHashMapUnmanaged(u32, void) = .empty,
        ns_child_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
        child_to_parent_ns: std.AutoHashMapUnmanaged(u32, u32) = .empty,
        js_exported_decls: std.AutoHashMapUnmanaged(u32, void) = .empty,
        global_aug_decls: std.AutoHashMapUnmanaged(u32, void) = .empty,
        decl_to_cand: std.AutoHashMapUnmanaged(u32, u32) = .empty,
        cand_to_final_map: ?[]?u32 = null,
        type_ref_counts: []u32 = &.{},
        type_closed_cache: []u8 = &.{},
        cur_mod_idx: u32 = 0,
        cur_mod_hoisted_locs: std.AutoHashMapUnmanaged(u32, DeclLocation) = .empty,
        cur_mod_closed_types: std.AutoHashMapUnmanaged(u32, *TypeIr) = .empty,
        cur_mod_decls_out: ?*std.ArrayList(DeclIr) = null,
        cur_mod_root_scope: ?*naming.ScopeNamer = null,
        cur_mod_anon_counter: u32 = 0,
        inline_anon_depth: u32 = 0,
        in_handle_struct: bool = false,

        fn deinitScratch(self: *Self) void {
            for (self.candidates.items) |*c| {
                c.source_mod_ids.deinit(self.scratch);
                c.decl_ids.deinit(self.scratch);
                c.exported_decl_ids.deinit(self.scratch);
                c.foreign_exports.deinit(self.scratch);
                c.same_mod_export_equals_children.deinit(self.scratch);
                c.star_re_export_source_mods.deinit(self.scratch);
                c.star_re_export_specs.deinit(self.scratch);
            }
            self.candidates.deinit(self.scratch);
            self.source_mod_to_cand.deinit(self.scratch);
            self.decl_locations.deinit(self.scratch);
            self.merged_ns_consumed.deinit(self.scratch);
            self.merged_iface_consumed.deinit(self.scratch);
            self.merged_ctor_var_consumed.deinit(self.scratch);
            self.decl_classifications.deinit(self.scratch);
            self.merged_generic_ns_peer.deinit(self.scratch);
            self.merged_generic_ns_set.deinit(self.scratch);
            self.pure_export_equals_ns.deinit(self.scratch);
            self.ns_child_ids.deinit(self.scratch);
            self.child_to_parent_ns.deinit(self.scratch);
            self.js_exported_decls.deinit(self.scratch);
            self.global_aug_decls.deinit(self.scratch);
            self.decl_to_cand.deinit(self.scratch);
            self.cur_mod_hoisted_locs.deinit(self.scratch);
            self.cur_mod_closed_types.deinit(self.scratch);
        }

        fn str(self: *const Self, id: u32) []const u8 {
            if (id < self.graph.strings.len) return self.graph.strings[id];
            return "";
        }

        fn classifyDecl(self: *Self, decl_id: u32) error{OutOfMemory}!classify_decls.DeclClassification {
            if (self.decl_classifications.get(decl_id)) |cached| return cached;
            var cls = classify_decls.Classifier(GraphType).init(self.scratch, &self.graph);
            defer cls.state.deinit(self.scratch);
            cls.memo = self.decl_classifications;
            defer self.decl_classifications = cls.memo;
            return try cls.classifyDecl(decl_id);
        }

        fn classifyObjectLiteral(self: *const Self, obj: anytype) classify_decls.DeclClassification {
            var cls = classify_decls.Classifier(GraphType).init(self.scratch, &self.graph);
            return cls.classifyObjectLiteralData(obj);
        }

        fn classifyObjectType(self: *Self, ty_id: u32) error{OutOfMemory}!classify_decls.DeclClassification {
            var cls = classify_decls.Classifier(GraphType).init(self.scratch, &self.graph);
            defer cls.state.deinit(self.scratch);
            cls.memo = self.decl_classifications;
            defer self.decl_classifications = cls.memo;
            return try cls.classifyObjectType(ty_id, 0);
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
            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(self.scratch);
            try self.appendDeclRecursiveToCandInner(decl_id, cand_idx, &visited);
        }

        fn appendDeclRecursiveToCandInner(
            self: *Self,
            decl_id: u32,
            cand_idx: u32,
            visited: *std.AutoHashMapUnmanaged(u32, void),
        ) error{OutOfMemory}!void {
            if (decl_id >= self.graph.decls.len) return;
            if (visited.contains(decl_id)) return;
            try visited.put(self.scratch, decl_id, {});
            if (!self.decl_to_cand.contains(decl_id)) {
                try self.decl_to_cand.put(self.scratch, decl_id, cand_idx);
            }
            const d = self.graph.decls[decl_id];
            switch (d.kind) {
                .namespace_decl => |children| {
                    for (children) |cid| {
                        try self.appendDeclRecursiveToCandInner(cid, cand_idx, visited);
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

        fn markGlobalScopeDeclRecursive(self: *Self, did: u32) error{OutOfMemory}!void {
            if (did >= self.graph.decls.len) return;
            if (self.global_aug_decls.contains(did)) return;
            try self.global_aug_decls.put(self.scratch, did, {});
            const d = self.graph.decls[did];
            if (d.kind == .namespace_decl) {
                for (d.kind.namespace_decl) |cid| {
                    try self.markGlobalScopeDeclRecursive(cid);
                }
            }
            for (d.merged_with) |mid| {
                if (mid < self.graph.decls.len and self.graph.decls[mid].kind == .namespace_decl) {
                    try self.markGlobalScopeDeclRecursive(mid);
                }
            }
        }

        fn isBuiltinMappedReference(
            self: *const Self,
            ref_name: []const u8,
            type_args_len: usize,
            target_decl: ?u32,
        ) bool {
            const is_bvk = lower_types.BinaryViewKind.fromTypeName(ref_name) != null;
            const is_boxed = (type_args_len == 0 and lower_types.BoxedIntrinsicKind.fromTypeName(ref_name) != null);
            if (!is_bvk and !is_boxed) return false;

            const td = target_decl orelse return true;
            if (td >= self.graph.decls.len) return true;
            if (self.global_aug_decls.contains(td)) return true;

            if (self.decl_to_cand.get(td)) |c_idx| {
                if (c_idx < self.candidates.items.len and self.candidates.items[c_idx].source_mod_ids.items.len == 0) {
                    const cand_spec = self.candidates.items[c_idx].wire_specifier;
                    if (lower_types.isBuiltinBufferOrGlobalsModule(cand_spec, "")) {
                        return true;
                    }
                }
            }

            var cur_ns_opt = self.child_to_parent_ns.get(td);
            var ns_depth: usize = 0;
            while (cur_ns_opt) |ns_id| : (ns_depth += 1) {
                if (ns_depth >= 32 or ns_id >= self.graph.decls.len) break;
                const ns_name = self.str(self.graph.decls[ns_id].name);
                if (lower_types.isBuiltinBufferOrGlobalsModule(ns_name, "")) {
                    return true;
                }
                cur_ns_opt = self.child_to_parent_ns.get(ns_id);
            }

            const owner_mid = self.findGraphModuleIndexById(self.graph.decls[td].module) orelse return true;
            const owner_mod = self.graph.modules[owner_mid];
            if (self.isBundledLibModule(owner_mod)) return true;
            if (lower_types.isBuiltinBufferOrGlobalsModule(self.str(owner_mod.specifier), self.str(owner_mod.file_path))) {
                return true;
            }
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

        fn markJsExportedDecl(self: *Self, did: u32) !void {
            if (did >= self.graph.decls.len) return;
            const d = self.graph.decls[did];
            if (d.kind == .import_equals_decl and !d.modifiers.export_decl) return;
            try self.js_exported_decls.put(self.scratch, did, {});
            for (d.merged_with) |mid| {
                if (mid < self.graph.decls.len and self.graph.decls[mid].module == d.module) {
                    try self.js_exported_decls.put(self.scratch, mid, {});
                }
            }
        }

        fn isAmbientOnlyFileMod(owner_mod: anytype) bool {
            return owner_mod.ambient_modules.len > 0 and
                owner_mod.exports.len == 0 and
                owner_mod.star_re_exports.len == 0 and
                owner_mod.default_export == null and
                owner_mod.export_equals == null and
                owner_mod.global_augmentations.len == 0;
        }

        fn resolveOrCreateOwnerCandForFileMod(self: *Self, owner_mod: anytype) !u32 {
            if (self.source_mod_to_cand.get(owner_mod.id)) |existing| return existing;
            // If `owner_mod` is a single-block ambient-only `.d.ts` file, route same-file unowned
            // helpers to that sole ambient module. When `ambient_modules.len > 1`, Step 2a has
            // already routed helpers reachable from each ambient block; any truly unreferenced
            // orphan must NOT pollute `ambient_modules[0]` or create a primary file stub.
            if (isAmbientOnlyFileMod(owner_mod)) {
                if (owner_mod.ambient_modules.len == 1) {
                    if (try self.findAmbientCandidateIdx(self.str(owner_mod.ambient_modules[0].module_name))) |amb_c| {
                        return amb_c;
                    }
                }
                const ws = try self.deriveFileLogicalSpecifier(owner_mod);
                return try self.getOrCreateCandidate(ws, null);
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
                if (self.ns_child_ids.contains(did)) {
                    if (!self.decl_to_cand.contains(did)) {
                        try self.decl_to_cand.put(self.scratch, did, c_idx);
                    }
                    try self.appendDeclRecursiveToCand(did, c_idx);
                    return;
                }
                if (self.decl_to_cand.get(did)) |existing_cand| {
                    if (existing_cand != c_idx) {
                        try appendUniqueForeignExport(&self.candidates.items[c_idx].foreign_exports, self.scratch, .{
                            .decl_id = did,
                            .wire_name_override = wire_override,
                            .is_default_export = is_default_export,
                        });
                        return;
                    }
                } else {
                    try self.decl_to_cand.put(self.scratch, did, c_idx);
                }
                try appendUniqueU32(&self.candidates.items[c_idx].decl_ids, self.scratch, did);
                try self.markJsExportedDecl(did);
                if (!is_default_export and !d.modifiers.default_export) {
                    try appendUniqueU32(&self.candidates.items[c_idx].exported_decl_ids, self.scratch, did);
                }
                try self.appendDeclRecursiveToCand(did, c_idx);
                return;
            }
            if (d.kind == .import_equals_decl) {
                if (self.ns_child_ids.contains(did)) {
                    if (!self.decl_to_cand.contains(did)) {
                        try self.decl_to_cand.put(self.scratch, did, c_idx);
                    }
                    try self.appendDeclRecursiveToCand(did, c_idx);
                    return;
                }
                if (self.decl_to_cand.get(did)) |existing_cand| {
                    if (existing_cand != c_idx) {
                        if (d.modifiers.export_decl or is_default_export) {
                            try appendUniqueForeignExport(&self.candidates.items[c_idx].foreign_exports, self.scratch, .{
                                .decl_id = did,
                                .wire_name_override = wire_override,
                                .is_default_export = is_default_export,
                            });
                        }
                        return;
                    }
                } else {
                    try self.decl_to_cand.put(self.scratch, did, c_idx);
                }
                try appendUniqueU32(&self.candidates.items[c_idx].decl_ids, self.scratch, did);
                if (d.modifiers.export_decl) {
                    try self.markJsExportedDecl(did);
                }
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
                        if (d.modifiers.export_decl or d.modifiers.default_export) {
                            try self.markJsExportedDecl(did);
                        }
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
                if (!self.pure_export_equals_ns.contains(did)) {
                    try self.markJsExportedDecl(did);
                }
                if (!is_default_export and
                    !d.modifiers.default_export and
                    !self.ns_child_ids.contains(did) and
                    !self.pure_export_equals_ns.contains(did))
                {
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

        fn wouldCreateNamespaceParentCycle(self: *const Self, child_id: u32, parent_id: u32) bool {
            if (child_id == parent_id) return true;
            var cur = parent_id;
            var hops: usize = 0;
            while (hops <= self.graph.decls.len) : (hops += 1) {
                const next = self.child_to_parent_ns.get(cur) orelse return false;
                if (next == child_id or next == cur) return true;
                cur = next;
            }
            return true;
        }

        fn registerExportEqualsForCandidate(
            self: *Self,
            c_idx: u32,
            current_mod_id: ?u32,
            raw_eq_id: u32,
        ) !void {
            if (raw_eq_id >= self.graph.decls.len) return;

            var target_id = raw_eq_id;
            var hops: usize = 0;
            while (hops < 32 and target_id < self.graph.decls.len) : (hops += 1) {
                const td = self.graph.decls[target_id];
                switch (td.kind) {
                    .import_equals_decl => |ie| {
                        if (ie.target_decl) |next_id| {
                            if (next_id == target_id) break;
                            target_id = next_id;
                            continue;
                        }
                        if (ie.module_specifier) |msid| {
                            const mspec = self.str(msid);
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
                        }
                        try self.registerCandidateDeclOrForeignExport(c_idx, current_mod_id, raw_eq_id, null, false);
                        return;
                    },
                    .re_export_decl => |re| {
                        if (re.target_decl) |next_id| {
                            if (next_id == target_id) break;
                            target_id = next_id;
                            continue;
                        }
                        break;
                    },
                    else => break,
                }
            }

            if (target_id >= self.graph.decls.len) return;
            const eq_decl = self.graph.decls[target_id];

            var peer_ids: std.ArrayList(u32) = .empty;
            defer peer_ids.deinit(self.scratch);
            try appendUniqueU32(&peer_ids, self.scratch, target_id);
            for (eq_decl.merged_with) |mid| {
                if (mid < self.graph.decls.len and self.graph.decls[mid].module == eq_decl.module) {
                    try appendUniqueU32(&peer_ids, self.scratch, mid);
                }
            }

            // Choose primary declaration (prefer class/function/variable/interface/enum/type_alias over namespace)
            var primary_id = target_id;
            var has_non_ns_peer = false;
            for (peer_ids.items) |pid| {
                const pd = self.graph.decls[pid];
                if (pd.kind != .namespace_decl) {
                    if (!has_non_ns_peer or pd.kind == .class_decl or pd.kind == .function_decl) {
                        primary_id = pid;
                    }
                    has_non_ns_peer = true;
                }
            }

            self.candidates.items[c_idx].export_equals_decl_id = primary_id;

            if (!has_non_ns_peer and eq_decl.kind == .namespace_decl) {
                try self.pure_export_equals_ns.put(self.scratch, target_id, {});
            }

            // Register primary + merged peers into candidate (same-module or foreign)
            for (peer_ids.items) |pid| {
                try self.registerCandidateDeclOrForeignExport(c_idx, current_mod_id, pid, null, false);
            }

            // Expose exported members of any `export =` namespace peer at module top-level
            // (e.g. `join`, `resolve`, `posix` from `export = path`, or `once`, `on`, `Abortable`
            // from `export = EventEmitter`).
            const primary_owner = self.decl_to_cand.get(primary_id);
            for (peer_ids.items) |pid| {
                const pd = self.graph.decls[pid];
                if (pd.kind != .namespace_decl) continue;
                for (pd.kind.namespace_decl) |cid| {
                    if (cid >= self.graph.decls.len) continue;
                    if (cid == pid or cid == primary_id) continue;
                    var is_peer = false;
                    for (peer_ids.items) |check_pid| {
                        if (cid == check_pid) {
                            is_peer = true;
                            break;
                        }
                    }
                    if (is_peer) continue;
                    const cd = self.graph.decls[cid];
                    if (!cd.modifiers.export_decl and !cd.modifiers.default_export) continue;
                    // Skip self-re-export aliases (`export { EventEmitter }`) whose wire name matches `eq_decl`.
                    const child_wire = if (cd.export_name) |esid| self.str(esid) else self.str(cd.name);
                    if (has_non_ns_peer and std.mem.eql(u8, child_wire, self.str(eq_decl.name))) continue;

                    if (primary_owner != null and primary_owner.? == c_idx) {
                        try appendUniqueU32(&self.candidates.items[c_idx].same_mod_export_equals_children, self.scratch, cid);
                        try appendUniqueU32(&self.candidates.items[c_idx].exported_decl_ids, self.scratch, cid);
                    } else {
                        try appendUniqueForeignExport(&self.candidates.items[c_idx].foreign_exports, self.scratch, .{
                            .decl_id = cid,
                            .wire_name_override = null,
                            .is_default_export = false,
                        });
                    }
                }
            }
        }

        fn discoverCandidates(self: *Self) !void {
            // Record all global augmentation / script-global declarations across all modules
            // (both user ambient globals and `@types/node` / lib global augmentations).
            for (self.graph.modules) |mod| {
                for (mod.global_augmentations) |did| {
                    try self.markGlobalScopeDeclRecursive(did);
                }
            }

            // Precompute all declarations owned as children of a `namespace_decl` so nested
            // namespace members are never hoisted to top-level `cand.decl_ids`.
            // Guard against cyclic or self-merged namespace children (`H1`/`H2`).
            for (self.graph.decls) |d| {
                if (d.kind == .namespace_decl) {
                    for (d.kind.namespace_decl) |cid| {
                        if (cid >= self.graph.decls.len) continue;
                        if (cid == d.id) continue;
                        var is_merged_peer = false;
                        for (d.merged_with) |mid| {
                            if (cid == mid) {
                                is_merged_peer = true;
                                break;
                            }
                        }
                        if (is_merged_peer) continue;
                        if (self.wouldCreateNamespaceParentCycle(cid, d.id)) continue;
                        try self.ns_child_ids.put(self.scratch, cid, {});
                        if (!self.child_to_parent_ns.contains(cid)) {
                            try self.child_to_parent_ns.put(self.scratch, cid, d.id);
                        }
                    }
                }
            }

            // Pre-mark pure `export = <namespace>` targets before Step 1a/2 so Step 1a doesn't
            // falsely mark the namespace wrapper itself as a named `.js_name` export.
            for (self.graph.modules) |mod| {
                if (self.isBundledLibModule(mod)) continue;
                for (mod.ambient_modules) |amb| {
                    if (amb.export_equals) |eq_id| {
                        if (eq_id < self.graph.decls.len) {
                            const ed = self.graph.decls[eq_id];
                            if (ed.kind == .namespace_decl) {
                                var has_non_ns = false;
                                for (ed.merged_with) |mid| {
                                    if (mid < self.graph.decls.len and self.graph.decls[mid].kind != .namespace_decl) {
                                        has_non_ns = true;
                                        break;
                                    }
                                }
                                if (!has_non_ns) try self.pure_export_equals_ns.put(self.scratch, eq_id, {});
                            }
                        }
                    }
                }
                if (mod.export_equals) |eq_id| {
                    if (eq_id < self.graph.decls.len) {
                        const ed = self.graph.decls[eq_id];
                        if (ed.kind == .namespace_decl) {
                            var has_non_ns = false;
                            for (ed.merged_with) |mid| {
                                if (mid < self.graph.decls.len and self.graph.decls[mid].kind != .namespace_decl) {
                                    has_non_ns = true;
                                    break;
                                }
                            }
                            if (!has_non_ns) try self.pure_export_equals_ns.put(self.scratch, eq_id, {});
                        }
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
                    if (amb.default_export) |def_id| {
                        if (def_id < self.graph.decls.len) {
                            const dd = self.graph.decls[def_id];
                            if (dd.kind != .re_export_decl and dd.kind != .import_equals_decl and dd.module == mod.id and !self.decl_to_cand.contains(def_id)) {
                                self.candidates.items[c_idx].default_export_decl_id = def_id;
                                try self.registerCandidateDeclOrForeignExport(c_idx, mod.id, def_id, "default", true);
                            }
                        }
                    }
                    if (amb.export_equals) |eq_id| {
                        if (eq_id < self.graph.decls.len) {
                            const ed = self.graph.decls[eq_id];
                            if (ed.kind != .re_export_decl and ed.kind != .import_equals_decl and ed.module == mod.id) {
                                try self.registerExportEqualsForCandidate(c_idx, mod.id, eq_id);
                            }
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
                    if (amb.default_export) |def_id| {
                        self.candidates.items[c_idx].default_export_decl_id = def_id;
                        try self.registerCandidateDeclOrForeignExport(c_idx, mod.id, def_id, "default", true);
                    }
                    if (amb.export_equals) |eq_id| {
                        try self.registerExportEqualsForCandidate(c_idx, mod.id, eq_id);
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
                        self.candidates.items[c_idx].default_export_decl_id = def_id;
                        try self.registerCandidateDeclOrForeignExport(c_idx, mod.id, def_id, "default", true);
                    }
                    if (mod.export_equals) |eq_id| {
                        try self.registerExportEqualsForCandidate(c_idx, mod.id, eq_id);
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

            // 2a. Route unowned same-file helper declarations (`interface Hid` in
            // `declare module "p2" { interface Hid ...; export function g(h: Hid): void; export {}; }`)
            // by reachability from each ambient module block's declarations BEFORE Step 2b!
            for (self.graph.modules) |mod| {
                if (self.isBundledLibModule(mod)) continue;
                for (mod.ambient_modules) |amb| {
                    const amb_cand = (try self.findAmbientCandidateIdx(self.str(amb.module_name))) orelse continue;
                    var seeds: std.ArrayList(u32) = .empty;
                    defer seeds.deinit(self.scratch);
                    for (amb.decls) |did| try appendUniqueU32(&seeds, self.scratch, did);
                    if (amb.default_export) |def_id| try appendUniqueU32(&seeds, self.scratch, def_id);
                    if (amb.export_equals) |eq_id| try appendUniqueU32(&seeds, self.scratch, eq_id);
                    try self.claimSameFileAmbientHelpers(amb_cand, mod.id, seeds.items);
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
                if (d.modifiers.export_decl and
                    owner_mod.exports.len == 0 and
                    owner_mod.ambient_modules.len == 0 and
                    owner_mod.default_export == null and
                    owner_mod.export_equals == null and
                    owner_mod.global_augmentations.len == 0)
                {
                    try self.markJsExportedDecl(d.id);
                }
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
                            try self.markJsExportedDecl(did);
                            // Point these decls to the synthesized dotted namespace module.
                            try self.decl_to_cand.put(self.scratch, did, c_idx);
                        }
                    }
                }
            }
        }

        fn claimSameFileAmbientHelpers(
            self: *Self,
            amb_cand: u32,
            mod_id: u32,
            seed_decls: []const u32,
        ) error{OutOfMemory}!void {
            var worklist: std.ArrayList(u32) = .empty;
            defer worklist.deinit(self.scratch);

            var visited_decls: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited_decls.deinit(self.scratch);

            var visited_types: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited_types.deinit(self.scratch);

            for (seed_decls) |did| {
                if (did >= self.graph.decls.len) continue;
                if (self.decl_to_cand.get(did) == amb_cand) {
                    try worklist.append(self.scratch, did);
                    for (self.graph.decls[did].merged_with) |mid| {
                        if (mid < self.graph.decls.len and self.decl_to_cand.get(mid) == amb_cand) {
                            try worklist.append(self.scratch, mid);
                        }
                    }
                }
            }

            const HelperClaimVisitor = struct {
                amb_cand: u32,
                mod_id: u32,
                worklist: *std.ArrayList(u32),

                fn onDeclRef(v: *@This(), ctx: *Self, target_did: u32) error{OutOfMemory}!void {
                    var root_did = target_did;
                    var hops: usize = 0;
                    while (hops < ctx.graph.decls.len) : (hops += 1) {
                        const p_ns = ctx.child_to_parent_ns.get(root_did) orelse break;
                        if (p_ns == root_did) break;
                        root_did = p_ns;
                    }
                    if (root_did >= ctx.graph.decls.len) return;
                    if (ctx.decl_to_cand.contains(root_did)) return;
                    const rd = ctx.graph.decls[root_did];
                    if (rd.module != v.mod_id) return;

                    try ctx.registerCanonicalDeclInCandidate(v.amb_cand, root_did);
                    try v.worklist.append(ctx.scratch, root_did);
                    for (rd.merged_with) |mid| {
                        if (mid < ctx.graph.decls.len and ctx.graph.decls[mid].module == v.mod_id) {
                            try v.worklist.append(ctx.scratch, mid);
                        }
                    }
                }

                fn onModuleIdRef(_: *@This(), _: *Self, _: u32) error{OutOfMemory}!void {}
                fn onModuleSpecRef(_: *@This(), _: *Self, _: []const u8) error{OutOfMemory}!void {}
            };

            var visitor = HelperClaimVisitor{
                .amb_cand = amb_cand,
                .mod_id = mod_id,
                .worklist = &worklist,
            };

            var cursor: usize = 0;
            while (cursor < worklist.items.len) : (cursor += 1) {
                const cur_did = worklist.items[cursor];
                if (visited_decls.contains(cur_did)) continue;
                try visited_decls.put(self.scratch, cur_did, {});
                try self.walkDeclRefs(cur_did, &visited_types, &visitor);
            }
        }

        fn walkTypeRefs(
            self: *Self,
            ty_id: u32,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            visitor: anytype,
        ) error{OutOfMemory}!void {
            if (ty_id >= self.graph.types.len) return;
            if (visited_types.contains(ty_id)) return;
            try visited_types.put(self.scratch, ty_id, {});

            const tn = self.graph.types[ty_id];
            switch (tn.kind) {
                .reference => |ref| {
                    if (!self.isBuiltinMappedReference(self.str(ref.target_name), ref.type_args.len, ref.target_decl)) {
                        if (ref.target_decl) |td| {
                            try visitor.onDeclRef(self, td);
                        } else if (tn.resolved_type) |rt| {
                            if (rt != ty_id) try self.walkTypeRefs(rt, visited_types, visitor);
                        }
                    }
                    for (ref.type_args) |arg_ty| {
                        try self.walkTypeRefs(arg_ty, visited_types, visitor);
                    }
                },
                .typeof_query => |tq| {
                    if (tq.target_decl) |td| {
                        try visitor.onDeclRef(self, td);
                    }
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) try self.walkTypeRefs(rt, visited_types, visitor);
                    }
                    for (tq.type_args) |arg_ty| {
                        try self.walkTypeRefs(arg_ty, visited_types, visitor);
                    }
                },
                .import_type => |it| {
                    try visitor.onModuleSpecRef(self, self.str(it.module_specifier));
                    for (it.type_args) |arg_ty| {
                        try self.walkTypeRefs(arg_ty, visited_types, visitor);
                    }
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) try self.walkTypeRefs(rt, visited_types, visitor);
                    }
                },
                .template_literal => |tl| {
                    for (tl.spans) |sp| try self.walkTypeRefs(sp.ty, visited_types, visitor);
                },
                .array, .readonly_array, .keyof_type => |inner| {
                    try self.walkTypeRefs(inner, visited_types, visitor);
                },
                .tuple, .readonly_tuple => |elems| {
                    for (elems) |el| try self.walkTypeRefs(el.ty, visited_types, visitor);
                },
                .union_type, .intersection => |arms| {
                    for (arms) |arm| try self.walkTypeRefs(arm, visited_types, visitor);
                },
                .object_literal => |obj| {
                    try self.walkPropsRefs(obj.properties, visited_types, visitor);
                    for (obj.call_signatures) |sid| try self.walkSigRefs(sid, visited_types, visitor);
                    for (obj.construct_signatures) |sid| try self.walkSigRefs(sid, visited_types, visitor);
                    for (obj.index_signatures) |isig| {
                        try self.walkTypeRefs(isig.key_type, visited_types, visitor);
                        try self.walkTypeRefs(isig.value_type, visited_types, visitor);
                    }
                },
                .function_type, .constructor_type => |sid| {
                    try self.walkSigRefs(sid, visited_types, visitor);
                },
                .indexed_access => |ia| {
                    try self.walkTypeRefs(ia.object_ty, visited_types, visitor);
                    try self.walkTypeRefs(ia.index_ty, visited_types, visitor);
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) try self.walkTypeRefs(rt, visited_types, visitor);
                    }
                },
                .conditional => |cond| {
                    try self.walkTypeRefs(cond.check_type, visited_types, visitor);
                    try self.walkTypeRefs(cond.extends_type, visited_types, visitor);
                    try self.walkTypeRefs(cond.true_type, visited_types, visitor);
                    try self.walkTypeRefs(cond.false_type, visited_types, visitor);
                    try self.walkTypeParamsRefs(cond.infer_params, visited_types, visitor);
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) try self.walkTypeRefs(rt, visited_types, visitor);
                    }
                },
                .mapped => |mp| {
                    try self.walkTypeParamsRefs(&.{mp.type_param}, visited_types, visitor);
                    if (mp.name_type) |nt| try self.walkTypeRefs(nt, visited_types, visitor);
                    try self.walkTypeRefs(mp.value_type, visited_types, visitor);
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) try self.walkTypeRefs(rt, visited_types, visitor);
                    }
                },
                .type_predicate => |tp| {
                    if (tp.target_type) |tt| try self.walkTypeRefs(tt, visited_types, visitor);
                },
                else => {
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) try self.walkTypeRefs(rt, visited_types, visitor);
                    }
                },
            }
        }

        fn walkTypeParamsRefs(
            self: *Self,
            tp_ids: []const u32,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            visitor: anytype,
        ) error{OutOfMemory}!void {
            for (tp_ids) |tp_id| {
                if (tp_id >= self.graph.type_params.len) continue;
                const tp = self.graph.type_params[tp_id];
                if (tp.constraint) |ct| try self.walkTypeRefs(ct, visited_types, visitor);
                if (tp.default_type) |dt| try self.walkTypeRefs(dt, visited_types, visitor);
            }
        }

        fn walkPropsRefs(
            self: *Self,
            prop_ids: []const u32,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            visitor: anytype,
        ) error{OutOfMemory}!void {
            for (prop_ids) |pid| {
                if (pid >= self.graph.properties.len) continue;
                const prop = self.graph.properties[pid];
                if (prop.modifiers.private_mod or prop.modifiers.protected_mod) continue;
                if (prop.computed_symbol) |cs| {
                    if (cs == .unique) try visitor.onDeclRef(self, cs.unique);
                }
                try self.walkTypeRefs(prop.ty, visited_types, visitor);
                if (prop.setter_ty) |sty| try self.walkTypeRefs(sty, visited_types, visitor);
            }
        }

        fn walkHeritageRefs(
            self: *Self,
            hc: anytype,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            visitor: anytype,
        ) error{OutOfMemory}!void {
            if (hc.target_decl) |td| try visitor.onDeclRef(self, td);
            try self.walkTypeRefs(hc.target_type, visited_types, visitor);
            for (hc.type_args) |arg_ty| try self.walkTypeRefs(arg_ty, visited_types, visitor);
        }

        fn walkSigRefs(
            self: *Self,
            sig_id: u32,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            visitor: anytype,
        ) error{OutOfMemory}!void {
            if (sig_id >= self.graph.signatures.len) return;
            const sig = self.graph.signatures[sig_id];
            try self.walkTypeParamsRefs(sig.type_params, visited_types, visitor);
            if (sig.this_param) |tp| try self.walkTypeRefs(tp, visited_types, visitor);
            for (sig.params) |p| try self.walkTypeRefs(p.ty, visited_types, visitor);
            try self.walkTypeRefs(sig.return_type, visited_types, visitor);
            if (sig.type_predicate) |tpred| {
                if (tpred.target_type) |tt| try self.walkTypeRefs(tt, visited_types, visitor);
            }
        }

        fn walkDeclRefs(
            self: *Self,
            decl_id: u32,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            visitor: anytype,
        ) error{OutOfMemory}!void {
            var visited_decls: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited_decls.deinit(self.scratch);
            try self.walkDeclRefsInner(decl_id, &visited_decls, visited_types, visitor);
        }

        fn walkDeclRefsInner(
            self: *Self,
            decl_id: u32,
            visited_decls: *std.AutoHashMapUnmanaged(u32, void),
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            visitor: anytype,
        ) error{OutOfMemory}!void {
            if (decl_id >= self.graph.decls.len) return;
            if (visited_decls.contains(decl_id)) return;
            try visited_decls.put(self.scratch, decl_id, {});

            const d = self.graph.decls[decl_id];
            try self.walkTypeParamsRefs(d.type_params, visited_types, visitor);
            for (d.merged_with) |mid| {
                if (mid < self.graph.decls.len and self.graph.decls[mid].module == d.module) {
                    try visitor.onDeclRef(self, mid);
                }
            }
            switch (d.kind) {
                .function_decl => |sigs| {
                    for (sigs) |sid| try self.walkSigRefs(sid, visited_types, visitor);
                },
                .variable_decl => |ty| try self.walkTypeRefs(ty, visited_types, visitor),
                .type_alias_decl => |ty| try self.walkTypeRefs(ty, visited_types, visitor),
                .interface_decl => |iface| {
                    for (iface.extends_clauses) |hc| try self.walkHeritageRefs(hc, visited_types, visitor);
                    try self.walkPropsRefs(iface.properties, visited_types, visitor);
                    for (iface.methods) |m| {
                        if (m.modifiers.private_mod or m.modifiers.protected_mod) continue;
                        if (m.computed_symbol) |cs| {
                            if (cs == .unique) try visitor.onDeclRef(self, cs.unique);
                        }
                        for (m.signatures) |sid| try self.walkSigRefs(sid, visited_types, visitor);
                    }
                    for (iface.call_signatures) |sid| try self.walkSigRefs(sid, visited_types, visitor);
                    for (iface.construct_signatures) |sid| try self.walkSigRefs(sid, visited_types, visitor);
                    for (iface.index_signatures) |isig| {
                        try self.walkTypeRefs(isig.key_type, visited_types, visitor);
                        try self.walkTypeRefs(isig.value_type, visited_types, visitor);
                    }
                    for (d.merged_with) |mid| {
                        if (mid == decl_id or mid >= self.graph.decls.len) continue;
                        const md = self.graph.decls[mid];
                        if (md.module == d.module and md.kind == .variable_decl) {
                            try self.walkTypeRefs(md.kind.variable_decl, visited_types, visitor);
                        }
                    }
                },
                .class_decl => |cls| {
                    if (cls.extends_clause) |hc| try self.walkHeritageRefs(hc, visited_types, visitor);
                    for (cls.implements_clauses) |hc| try self.walkHeritageRefs(hc, visited_types, visitor);
                    for (cls.constructors) |sid| {
                        if (sid < self.graph.signatures.len) {
                            const csig = self.graph.signatures[sid];
                            if (csig.modifiers.private_mod or csig.modifiers.protected_mod) continue;
                        }
                        try self.walkSigRefs(sid, visited_types, visitor);
                    }
                    try self.walkPropsRefs(cls.properties, visited_types, visitor);
                    for (cls.methods) |m| {
                        if (m.modifiers.private_mod or m.modifiers.protected_mod) continue;
                        if (m.computed_symbol) |cs| {
                            if (cs == .unique) try visitor.onDeclRef(self, cs.unique);
                        }
                        for (m.signatures) |sid| try self.walkSigRefs(sid, visited_types, visitor);
                    }
                    for (cls.index_signatures) |isig| {
                        try self.walkTypeRefs(isig.key_type, visited_types, visitor);
                        try self.walkTypeRefs(isig.value_type, visited_types, visitor);
                    }
                },
                .namespace_decl => |children| {
                    for (children) |cid| try self.walkDeclRefsInner(cid, visited_decls, visited_types, visitor);
                },
                .re_export_decl => |re| {
                    if (re.target_module) |tmid| try visitor.onModuleIdRef(self, tmid);
                    if (re.target_decl) |tdid| {
                        try visitor.onDeclRef(self, tdid);
                    } else if (re.target_module == null) {
                        try visitor.onModuleSpecRef(self, self.str(re.module_specifier));
                    }
                },
                .import_equals_decl => |ie| {
                    if (ie.target_decl) |tdid| {
                        try visitor.onDeclRef(self, tdid);
                    } else if (ie.module_specifier) |msid| {
                        try visitor.onModuleSpecRef(self, self.str(msid));
                    }
                },
                .enum_decl => {},
            }
        }

        fn collectReferencedCandsFromDecl(
            self: *Self,
            decl_id: u32,
            visited_types: *std.AutoHashMapUnmanaged(u32, void),
            queue: *std.ArrayList(u32),
        ) error{OutOfMemory}!void {
            const CandReachVisitor = struct {
                queue: *std.ArrayList(u32),

                fn markCand(v: *@This(), ctx: *Self, dep_cand: u32) error{OutOfMemory}!void {
                    if (!ctx.candidates.items[dep_cand].included) {
                        ctx.candidates.items[dep_cand].included = true;
                        try v.queue.append(ctx.scratch, dep_cand);
                    }
                }

                fn onDeclRef(v: *@This(), ctx: *Self, td: u32) error{OutOfMemory}!void {
                    if (ctx.decl_to_cand.get(td)) |dep_cand| {
                        try v.markCand(ctx, dep_cand);
                    }
                }

                fn onModuleIdRef(v: *@This(), ctx: *Self, tmid: u32) error{OutOfMemory}!void {
                    if (ctx.source_mod_to_cand.get(tmid)) |dep_cand| {
                        try v.markCand(ctx, dep_cand);
                    }
                }

                fn onModuleSpecRef(v: *@This(), ctx: *Self, mspec: []const u8) error{OutOfMemory}!void {
                    if (try ctx.resolveSpecToCandidateIdx(mspec)) |dep_cand| {
                        try v.markCand(ctx, dep_cand);
                    }
                }
            };

            var visitor = CandReachVisitor{ .queue = queue };
            try self.walkDeclRefs(decl_id, visited_types, &visitor);
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
            var visited_ns: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited_ns.deinit(self.scratch);
            try self.prebindScopeDeclsInner(
                final_mod_idx,
                decl_ids,
                scope,
                prefix_path,
                prebound_names,
                prebound_overloads,
                &visited_ns,
            );
        }

        fn prebindScopeDeclsInner(
            self: *Self,
            final_mod_idx: u32,
            decl_ids: []const u32,
            scope: *naming.ScopeNamer,
            prefix_path: []const []const u8,
            prebound_names: *std.AutoHashMapUnmanaged(u32, naming.BoundName),
            prebound_overloads: *std.AutoHashMapUnmanaged(u32, []naming.BoundName),
            visited_ns: *std.AutoHashMapUnmanaged(u32, void),
        ) error{OutOfMemory}!void {
            // 1. Detect class + interface declaration merging in the same scope so merged interface
            // members fold cleanly into the class struct rather than colliding as `Foo_2`!
            for (decl_ids) |did| {
                if (did >= self.graph.decls.len) continue;
                const d = self.graph.decls[did];
                if (d.kind == .class_decl) {
                    for (d.merged_with) |mid| {
                        if (mid >= self.graph.decls.len or mid == did) continue;
                        if (self.graph.decls[mid].kind == .interface_decl) {
                            for (decl_ids) |other| {
                                if (other == mid) {
                                    try self.merged_iface_consumed.put(self.scratch, mid, {});
                                }
                            }
                        }
                    }
                } else if (d.kind == .interface_decl and !self.merged_iface_consumed.contains(did)) {
                    for (d.merged_with) |mid| {
                        if (mid >= self.graph.decls.len or mid <= did) continue;
                        if (self.graph.decls[mid].kind == .interface_decl) {
                            for (decl_ids) |other| {
                                if (other == mid) {
                                    try self.merged_iface_consumed.put(self.scratch, mid, {});
                                }
                            }
                        }
                    }
                }
            }

            // 2. Detect interface/class + namespace declaration merging in the same scope:
            //    - When `d.type_params.len == 0` (`const Foo = struct { ... }`), consume the merged
            //      `namespace_decl` directly into `Foo`'s nested declarations!
            //    - When `d.type_params.len > 0` (`fn Foo(comptime T: type) type`), Zig 0.17 does NOT
            //      allow `Foo.Bar` field access on a generic type constructor function! Keep the
            //      merged `namespace_decl` as a concrete module/scope sibling (`Foo_2`, marked in
            //      `merged_generic_ns_set`) AND also alias its children inside `Foo(T)`!
            for (decl_ids) |did| {
                if (did >= self.graph.decls.len) continue;
                if (self.merged_iface_consumed.contains(did)) continue;
                const d = self.graph.decls[did];
                if (d.kind == .interface_decl or d.kind == .class_decl) {
                    if (d.kind == .interface_decl and d.type_params.len == 0) {
                        const icls = try self.classifyDecl(did);
                        if (icls.companion_var_decl_id) |var_did| {
                            for (decl_ids) |other| {
                                if (other == var_did) {
                                    try self.merged_ctor_var_consumed.put(self.scratch, var_did, {});
                                }
                            }
                        }
                    }
                    for (d.merged_with) |mid| {
                        if (mid >= self.graph.decls.len or mid == did) continue;
                        if (self.graph.decls[mid].kind == .namespace_decl) {
                            for (decl_ids) |other| {
                                if (other == mid) {
                                    if (d.type_params.len == 0) {
                                        try self.merged_ns_consumed.put(self.scratch, mid, {});
                                    } else {
                                        try self.merged_generic_ns_peer.put(self.scratch, did, mid);
                                        try self.merged_generic_ns_set.put(self.scratch, mid, {});
                                    }
                                }
                            }
                        }
                    }
                }
            }

            for (decl_ids) |did| {
                if (did >= self.graph.decls.len) continue;
                if (self.merged_ns_consumed.contains(did)) continue;
                if (self.merged_iface_consumed.contains(did)) continue;
                if (self.merged_ctor_var_consumed.contains(did)) continue;
                if (prebound_names.get(did)) |existing| {
                    try scope.reserve(existing.logical_name);
                    if (prebound_overloads.get(did)) |ovs| {
                        for (ovs) |ov| try scope.reserve(ov.logical_name);
                    }
                    continue;
                }

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

                const loc = DeclLocation{
                    .module_index = final_mod_idx,
                    .zig_path = full_path,
                    .type_param_defaults = defaults,
                };
                try self.decl_locations.put(self.scratch, did, loc);

                // Point consumed merged interfaces and companion constructor vars at the owning decl location too!
                if (d.kind == .class_decl) {
                    for (d.merged_with) |mid| {
                        if (self.merged_iface_consumed.contains(mid)) {
                            try self.decl_locations.put(self.scratch, mid, loc);
                        }
                    }
                } else if (d.kind == .interface_decl) {
                    for (d.merged_with) |mid| {
                        if (self.merged_ctor_var_consumed.contains(mid) or self.merged_iface_consumed.contains(mid)) {
                            try self.decl_locations.put(self.scratch, mid, loc);
                        }
                    }
                }

                switch (d.kind) {
                    .namespace_decl => |children| {
                        if (!visited_ns.contains(did)) {
                            try visited_ns.put(self.scratch, did, {});
                            var nested_scope = naming.ScopeNamer.initContainer(self.scratch, scope);
                            defer nested_scope.deinit();
                            try nested_scope.reserve("zigar_js");
                            try self.prebindScopeDeclsInner(
                                final_mod_idx,
                                children,
                                &nested_scope,
                                full_path,
                                prebound_names,
                                prebound_overloads,
                                visited_ns,
                            );
                        }
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
                            if (self.merged_ns_consumed.contains(mid) and !visited_ns.contains(mid)) {
                                try visited_ns.put(self.scratch, mid, {});
                                const mchildren = self.graph.decls[mid].kind.namespace_decl;
                                try self.prebindScopeDeclsInner(
                                    final_mod_idx,
                                    mchildren,
                                    &nested_scope,
                                    full_path,
                                    prebound_names,
                                    prebound_overloads,
                                    visited_ns,
                                );
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

        fn isBundledLibDecl(self: *const Self, did: u32) bool {
            if (did >= self.graph.decls.len) return false;
            const mid = self.findGraphModuleIndexById(self.graph.decls[did].module) orelse return false;
            return self.isBundledLibModule(self.graph.modules[mid]);
        }

        fn lookupDeclLocation(self: *const Self, td: u32) ?struct { id: u32, loc: DeclLocation } {
            if (self.decl_locations.get(td)) |loc| {
                return .{ .id = td, .loc = loc };
            }
            if (td < self.graph.decls.len) {
                const d = self.graph.decls[td];
                for (d.merged_with) |mid| {
                    if (self.decl_locations.get(mid)) |mloc| {
                        return .{ .id = mid, .loc = mloc };
                    }
                }
            }
            return null;
        }

        fn computeTypeRefCounts(self: *Self) error{OutOfMemory}!void {
            const n = self.graph.types.len;
            const counts = try self.scratch.alloc(u32, n);
            @memset(counts, 0);
            const closed_cache = try self.scratch.alloc(u8, n);
            @memset(closed_cache, 0);

            const bump = struct {
                fn call(c: []u32, tid: u32) void {
                    if (tid < c.len) c[tid] +|= 1;
                }
            }.call;

            for (self.graph.types, 0..) |tn, idx| {
                const self_id: u32 = @intCast(idx);
                if (tn.resolved_type) |rt| {
                    if (rt != self_id) bump(counts, rt);
                }
                switch (tn.kind) {
                    .array, .readonly_array, .keyof_type => |inner| bump(counts, inner),
                    .tuple, .readonly_tuple => |elems| {
                        for (elems) |el| bump(counts, el.ty);
                    },
                    .union_type, .intersection => |arms| {
                        for (arms) |aid| bump(counts, aid);
                    },
                    .reference => |ref| {
                        for (ref.type_args) |ta| bump(counts, ta);
                    },
                    .typeof_query => |tq| {
                        for (tq.type_args) |ta| bump(counts, ta);
                    },
                    .import_type => |it| {
                        for (it.type_args) |ta| bump(counts, ta);
                    },
                    .template_literal => |tl| {
                        for (tl.spans) |sp| bump(counts, sp.ty);
                    },
                    .indexed_access => |ia| {
                        bump(counts, ia.object_ty);
                        bump(counts, ia.index_ty);
                    },
                    .conditional => |cond| {
                        bump(counts, cond.check_type);
                        bump(counts, cond.extends_type);
                        bump(counts, cond.true_type);
                        bump(counts, cond.false_type);
                    },
                    .mapped => |mp| {
                        if (mp.name_type) |nt| bump(counts, nt);
                        bump(counts, mp.value_type);
                    },
                    .type_predicate => |tp| {
                        if (tp.target_type) |tt| bump(counts, tt);
                    },
                    else => {},
                }
            }
            for (self.graph.properties) |p| {
                if (p.modifiers.private_mod or p.modifiers.protected_mod) continue;
                bump(counts, p.ty);
                if (p.setter_ty) |sty| bump(counts, sty);
            }
            for (self.graph.signatures) |sig| {
                if (sig.modifiers.private_mod or sig.modifiers.protected_mod) continue;
                if (sig.this_param) |tp| bump(counts, tp);
                for (sig.params) |p| bump(counts, p.ty);
                bump(counts, sig.return_type);
                if (sig.type_predicate) |pred| {
                    if (pred.target_type) |tt| bump(counts, tt);
                }
            }
            for (self.graph.type_params) |tp| {
                if (tp.constraint) |ct| bump(counts, ct);
                if (tp.default_type) |dt| bump(counts, dt);
            }
            for (self.graph.decls) |d| {
                switch (d.kind) {
                    .variable_decl, .type_alias_decl => |ty| bump(counts, ty),
                    else => {},
                }
            }

            self.type_ref_counts = counts;
            self.type_closed_cache = closed_cache;
        }

        fn isClosedTypeSubgraph(self: *Self, ty_id: u32) error{OutOfMemory}!bool {
            if (ty_id >= self.graph.types.len) return true;
            if (ty_id < self.type_closed_cache.len) {
                const cached = self.type_closed_cache[ty_id];
                if (cached == 2) return true;
                if (cached == 3) return false;
            }
            var bound_tps: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer bound_tps.deinit(self.scratch);
            var visiting: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visiting.deinit(self.scratch);
            return self.isClosedTypeInner(ty_id, &bound_tps, &visiting);
        }

        fn isClosedTypeInner(
            self: *Self,
            ty_id: u32,
            bound_tps: *std.AutoHashMapUnmanaged(u32, void),
            visiting: *std.AutoHashMapUnmanaged(u32, void),
        ) error{OutOfMemory}!bool {
            if (ty_id >= self.graph.types.len) return true;
            const can_cache = (bound_tps.count() == 0) and (ty_id < self.type_closed_cache.len);
            if (can_cache) {
                const cached = self.type_closed_cache[ty_id];
                if (cached == 2) return true;
                if (cached == 3) return false;
            }
            if (visiting.contains(ty_id)) return true;
            try visiting.put(self.scratch, ty_id, {});
            defer _ = visiting.remove(ty_id);

            const tn = self.graph.types[ty_id];
            const res: bool = switch (tn.kind) {
                .this_type, .infer_type => false,
                .type_param => |tp_id| bound_tps.contains(tp_id),
                .array, .readonly_array, .keyof_type => |inner| try self.isClosedTypeInner(inner, bound_tps, visiting),
                .tuple, .readonly_tuple => |elems| blk: {
                    for (elems) |el| {
                        if (!try self.isClosedTypeInner(el.ty, bound_tps, visiting)) break :blk false;
                    }
                    break :blk true;
                },
                .union_type, .intersection => |arms| blk: {
                    for (arms) |aid| {
                        if (!try self.isClosedTypeInner(aid, bound_tps, visiting)) break :blk false;
                    }
                    break :blk true;
                },
                .reference => |ref| blk: {
                    for (ref.type_args) |ta| {
                        if (!try self.isClosedTypeInner(ta, bound_tps, visiting)) break :blk false;
                    }
                    if (ref.target_decl == null and ref.type_args.len == 0 and tn.resolved_type == null) {
                        break :blk false;
                    }
                    if (self.lookupDeclLocation(ref.target_decl orelse std.math.maxInt(u32)) == null) {
                        if (ref.target_decl == null or (ref.target_decl.? < self.graph.decls.len and self.graph.decls[ref.target_decl.?].kind == .type_alias_decl)) {
                            if (tn.resolved_type) |rt| {
                                if (rt != ty_id and !try self.isClosedTypeInner(rt, bound_tps, visiting)) break :blk false;
                            }
                        }
                    }
                    break :blk true;
                },
                .function_type, .constructor_type => |sid| try self.isClosedSigInner(sid, bound_tps, visiting),
                .object_literal => |obj| blk: {
                    for (obj.properties) |pid| {
                        if (pid >= self.graph.properties.len) continue;
                        const p = self.graph.properties[pid];
                        if (p.modifiers.private_mod or p.modifiers.protected_mod) continue;
                        if (!try self.isClosedTypeInner(p.ty, bound_tps, visiting)) break :blk false;
                        if (p.setter_ty) |sty| {
                            if (!try self.isClosedTypeInner(sty, bound_tps, visiting)) break :blk false;
                        }
                    }
                    for (obj.call_signatures) |sid| {
                        if (!try self.isClosedSigInner(sid, bound_tps, visiting)) break :blk false;
                    }
                    for (obj.construct_signatures) |sid| {
                        if (!try self.isClosedSigInner(sid, bound_tps, visiting)) break :blk false;
                    }
                    break :blk true;
                },
                .typeof_query => |tq| blk: {
                    for (tq.type_args) |ta| {
                        if (!try self.isClosedTypeInner(ta, bound_tps, visiting)) break :blk false;
                    }
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id and !try self.isClosedTypeInner(rt, bound_tps, visiting)) break :blk false;
                    }
                    break :blk true;
                },
                .indexed_access => |ia| blk: {
                    if (!try self.isClosedTypeInner(ia.object_ty, bound_tps, visiting)) break :blk false;
                    if (!try self.isClosedTypeInner(ia.index_ty, bound_tps, visiting)) break :blk false;
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id and !try self.isClosedTypeInner(rt, bound_tps, visiting)) break :blk false;
                    }
                    break :blk true;
                },
                .conditional => |cond| blk: {
                    var added: std.ArrayList(u32) = .empty;
                    defer {
                        for (added.items) | id_rm | _ = bound_tps.remove(id_rm);
                        added.deinit(self.scratch);
                    }
                    for (cond.infer_params) |tp_id| {
                        if (!bound_tps.contains(tp_id)) {
                            try bound_tps.put(self.scratch, tp_id, {});
                            try added.append(self.scratch, tp_id);
                        }
                    }
                    if (!try self.isClosedTypeInner(cond.check_type, bound_tps, visiting)) break :blk false;
                    if (!try self.isClosedTypeInner(cond.extends_type, bound_tps, visiting)) break :blk false;
                    if (!try self.isClosedTypeInner(cond.true_type, bound_tps, visiting)) break :blk false;
                    if (!try self.isClosedTypeInner(cond.false_type, bound_tps, visiting)) break :blk false;
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id and !try self.isClosedTypeInner(rt, bound_tps, visiting)) break :blk false;
                    }
                    break :blk true;
                },
                .mapped => |mp| blk: {
                    const was_new = !bound_tps.contains(mp.type_param);
                    if (was_new) try bound_tps.put(self.scratch, mp.type_param, {});
                    defer if (was_new) {
                        _ = bound_tps.remove(mp.type_param);
                    };
                    if (mp.name_type) |nt| {
                        if (!try self.isClosedTypeInner(nt, bound_tps, visiting)) break :blk false;
                    }
                    if (!try self.isClosedTypeInner(mp.value_type, bound_tps, visiting)) break :blk false;
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id and !try self.isClosedTypeInner(rt, bound_tps, visiting)) break :blk false;
                    }
                    break :blk true;
                },
                else => blk: {
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id and !try self.isClosedTypeInner(rt, bound_tps, visiting)) break :blk false;
                    }
                    break :blk true;
                },
            };

            if (can_cache and visiting.count() == 1) {
                self.type_closed_cache[ty_id] = if (res) 2 else 3;
            }
            return res;
        }

        fn isClosedSigInner(
            self: *Self,
            sid: u32,
            bound_tps: *std.AutoHashMapUnmanaged(u32, void),
            visiting: *std.AutoHashMapUnmanaged(u32, void),
        ) error{OutOfMemory}!bool {
            if (sid >= self.graph.signatures.len) return true;
            const sig = self.graph.signatures[sid];
            var added: std.ArrayList(u32) = .empty;
            defer {
                for (added.items) |id_rm| _ = bound_tps.remove(id_rm);
                added.deinit(self.scratch);
            }
            for (sig.type_params) |tp_id| {
                if (!bound_tps.contains(tp_id)) {
                    try bound_tps.put(self.scratch, tp_id, {});
                    try added.append(self.scratch, tp_id);
                }
            }
            for (sig.type_params) |tp_id| {
                if (tp_id >= self.graph.type_params.len) continue;
                const tp = self.graph.type_params[tp_id];
                if (tp.constraint) |ct| {
                    if (!try self.isClosedTypeInner(ct, bound_tps, visiting)) return false;
                }
                if (tp.default_type) |dt| {
                    if (!try self.isClosedTypeInner(dt, bound_tps, visiting)) return false;
                }
            }
            for (sig.params) |p| {
                if (!try self.isClosedTypeInner(p.ty, bound_tps, visiting)) return false;
            }
            if (!try self.isClosedTypeInner(sig.return_type, bound_tps, visiting)) return false;
            return true;
        }

        fn isSafeToShareTypeIrPtr(ty: *const TypeIr) bool {
            return switch (ty.*) {
                .void_type,
                .noreturn_type,
                .bool_type,
                .f64_type,
                .i64_type,
                .string_type,
                .bytes_type,
                .typed_slice,
                .js_value,
                .js_any,
                .js_unknown,
                .js_object,
                .js_function,
                .js_symbol,
                .js_bigint,
                .js_string,
                .binary_view,
                .slice,
                .pointer_const,
                .fn_ptr,
                .promise,
                .js_map,
                => true,
                .optional => |opt| isSafeToShareTypeIrPtr(opt.child),
                else => false,
            };
        }

        fn allocFreshAnonHelperName(
            self: *Self,
            prefix: []const u8,
            active_tps: []const ActiveTypeParam,
        ) error{OutOfMemory}!struct { zig_ident: []const u8, logical: []const u8, path: []const []const u8 } {
            const rs = self.cur_mod_root_scope.?;
            while (true) {
                self.cur_mod_anon_counter += 1;
                const raw = try std.fmt.allocPrint(self.scratch, "{s}_{d}", .{ prefix, self.cur_mod_anon_counter });
                defer self.scratch.free(raw);
                if (rs.isTaken(raw)) continue;
                var collides_tp = false;
                for (active_tps) |tp| {
                    if (std.mem.eql(u8, tp.zig_ident, raw) or std.mem.eql(u8, tp.ts_name, raw)) {
                        collides_tp = true;
                        break;
                    }
                }
                if (collides_tp) continue;
                const b = try rs.bind(raw, .preserve);
                const zig_ident = try self.alloc.dupe(u8, b.zig_ident);
                const logical = try self.alloc.dupe(u8, b.logical_name);
                b.deinit(self.scratch);
                var path = try self.alloc.alloc([]const u8, 1);
                path[0] = zig_ident;
                return .{ .zig_ident = zig_ident, .logical = logical, .path = path };
            }
        }

        fn makeHoistedDeclRef(self: *Self, loc: DeclLocation) error{OutOfMemory}!*TypeIr {
            return self.makeType(.{
                .decl_ref = .{
                    .module_index = loc.module_index,
                    .decl_zig_path = loc.zig_path,
                    .target_decl_id = std.math.maxInt(u32),
                    .type_args = &.{},
                },
            });
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
                return self.makeType(.js_any);
            }
            if (self.cur_mod_hoisted_locs.get(ty_id)) |hloc| {
                return self.makeHoistedDeclRef(hloc);
            }
            if (!is_return_pos) {
                if (self.cur_mod_closed_types.get(ty_id)) |cached_ty| {
                    return cached_ty;
                }
            }
            if (visited.contains(ty_id)) {
                needs_runtime.* = true;
                return self.makeType(.js_any);
            }
            try visited.put(self.scratch, ty_id, {});
            defer _ = visited.remove(ty_id);

            const tn = self.graph.types[ty_id];
            const ref_cnt: u32 = if (ty_id < self.type_ref_counts.len) self.type_ref_counts[ty_id] else 1;
            const can_hoist_in_mod = (self.cur_mod_decls_out != null and self.cur_mod_root_scope != null);
            const no_free_vars = (active_tps.len == 0 and self_ident_opt == null);

            switch (tn.kind) {
                .void_type, .undefined_type => return self.makeType(.void_type),
                .never_type => {
                    if (is_return_pos) return self.makeType(.noreturn_type);
                    return self.makeType(.void_type);
                },
                .null_type => {
                    needs_runtime.* = true;
                    const inner = try self.makeType(.js_any);
                    return self.makeType(.{ .optional = .{ .child = inner, .nullish_kind = .null_only, .is_pure_nullish = true } });
                },
                .boolean_type => return self.makeType(.bool_type),
                .number_type => return self.makeType(.f64_type),
                .bigint_type => return self.makeType(.i64_type),
                .string_type => return self.makeType(.string_type),
                .intrinsic => {
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) {
                            return self.lowerType(rt, is_return_pos, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                        }
                    }
                    return self.makeType(.string_type);
                },
                .template_literal => |tl| {
                    return self.lowerTemplateLiteralInline(
                        ty_id,
                        tl,
                        tn.resolved_type,
                        ref_cnt,
                        can_hoist_in_mod,
                        no_free_vars,
                        active_tps,
                        self_ident_opt,
                        visited,
                        imports_used,
                        needs_runtime,
                    );
                },
                .symbol_type, .unique_symbol => {
                    needs_runtime.* = true;
                    return self.makeType(.js_symbol);
                },
                .any_type => {
                    needs_runtime.* = true;
                    return self.makeType(.js_any);
                },
                .unknown_type => {
                    needs_runtime.* = true;
                    return self.makeType(.js_unknown);
                },
                .object_type => {
                    needs_runtime.* = true;
                    return self.makeType(.js_object);
                },
                .this_type => {
                    if (self_ident_opt) |sid| {
                        const self_t = try self.makeType(.{ .self_type = sid });
                        if (self.in_handle_struct) return self_t;
                        return self.makeType(.{ .pointer_const = self_t });
                    }
                    needs_runtime.* = true;
                    return self.makeType(.js_any);
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
                            if (active_tps[i].subst_ty) |sub| return sub;
                            return self.makeType(.{ .type_param_ref = active_tps[i].zig_ident });
                        }
                    }
                    needs_runtime.* = true;
                    return self.makeType(.js_any);
                },
                .array, .readonly_array => |elem_id| {
                    const elem = try self.lowerType(elem_id, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                    const res = try self.makeType(.{ .slice = elem });
                    if (ref_cnt > 1 and can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id))) {
                        try self.cur_mod_closed_types.put(self.scratch, ty_id, res);
                    }
                    return res;
                },
                .tuple, .readonly_tuple => |elems| {
                    var tup_scope = naming.ScopeNamer.initContainer(self.scratch, null);
                    defer tup_scope.deinit();
                    try tup_scope.reserve("zigar_js");
                    try tup_scope.reserve("zigar_js_tuple");

                    var out_elems = try self.alloc.alloc(TupleElemIr, elems.len);
                    for (elems, 0..) |el, idx| {
                        const raw_lbl = if (el.label) |lsid| self.str(lsid) else null;
                        const fallback_lbl = if (raw_lbl) |l| l else try std.fmt.allocPrint(self.alloc, "{d}", .{idx});
                        const bound = try tup_scope.bind(fallback_lbl, if (raw_lbl != null) .snake else .preserve);
                        const zig_ident = try self.alloc.dupe(u8, bound.zig_ident);
                        bound.deinit(self.scratch);

                        var elem_ty = try self.lowerType(el.ty, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                        if (el.variadic) {
                            if (!self.isAlreadySliceTypeIr(elem_ty, 0)) {
                                elem_ty = try self.makeType(.{ .slice = elem_ty });
                            }
                        } else if (el.optional) {
                            elem_ty = try self.wrapOptionalWithNullish(elem_ty, .undefined_only);
                        }
                        out_elems[idx] = .{
                            .zig_ident = zig_ident,
                            .wire_label = if (raw_lbl) |l| try self.alloc.dupe(u8, l) else null,
                            .ty = elem_ty,
                            .is_optional = el.optional and !el.variadic,
                            .is_variadic = el.variadic,
                            .nullish_kind = if (!el.variadic and elem_ty.* == .optional) elem_ty.optional.nullish_kind else .none,
                        };
                    }
                    const tup_ir = try self.makeType(.{ .tuple = out_elems });
                    if (ref_cnt > 1 and elems.len > 0 and can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id))) {
                        const h = try self.allocFreshAnonHelperName("__zigar_AnonTuple", active_tps);
                        const hloc = DeclLocation{
                            .module_index = self.cur_mod_idx,
                            .zig_path = h.path,
                            .type_param_defaults = &.{},
                        };
                        try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);
                        try self.cur_mod_decls_out.?.append(self.alloc, .{
                            .source_decl_id = null,
                            .zig_ident = h.zig_ident,
                            .logical_name = h.logical,
                            .wire_name = h.logical,
                            .is_exported = false,
                            .is_js_exported = false,
                            .is_default_export = false,
                            .jsdoc = null,
                            .kind = .{ .type_alias = .{ .type_params = &.{}, .target = tup_ir } },
                        });
                        return self.makeHoistedDeclRef(hloc);
                    }
                    return tup_ir;
                },
                .union_type => |arms| {
                    return self.lowerUnionTypeInline(
                        ty_id,
                        arms,
                        ref_cnt,
                        can_hoist_in_mod,
                        no_free_vars,
                        active_tps,
                        self_ident_opt,
                        visited,
                        imports_used,
                        needs_runtime,
                    );
                },
                .reference => |ref| {
                    const ref_name = self.str(ref.target_name);

                    // Check active generic type parameter first in case TS emitted a reference node.
                    {
                        var i: usize = active_tps.len;
                        while (i > 0) {
                            i -= 1;
                            if (std.mem.eql(u8, active_tps[i].ts_name, ref_name)) {
                                if (active_tps[i].subst_ty) |sub| return sub;
                                return self.makeType(.{ .type_param_ref = active_tps[i].zig_ident });
                            }
                        }
                    }

                    // Built-in JS/Node binary buffer & view types and boxed global wrappers (`BigInt`, `String`, `Symbol`, `Object`).
                    if (self.isBuiltinMappedReference(ref_name, ref.type_args.len, ref.target_decl)) {
                        needs_runtime.* = true;
                        if (lower_types.BinaryViewKind.fromTypeName(ref_name)) |bvk| {
                            const res = try self.makeType(.{ .binary_view = bvk });
                            if (ref_cnt > 1 and can_hoist_in_mod and no_free_vars) {
                                try self.cur_mod_closed_types.put(self.scratch, ty_id, res);
                            }
                            return res;
                        }
                        if (lower_types.BoxedIntrinsicKind.fromTypeName(ref_name)) |bik| {
                            const tag: TypeIr = switch (bik) {
                                .bigint => .js_bigint,
                                .string => .js_string,
                                .symbol => .js_symbol,
                                .object => .js_object,
                            };
                            const res = try self.makeType(tag);
                            if (ref_cnt > 1 and can_hoist_in_mod and no_free_vars) {
                                try self.cur_mod_closed_types.put(self.scratch, ty_id, res);
                            }
                            return res;
                        }
                    }

                    if (ref.target_decl) |td| {
                        if (self.lookupDeclLocation(td)) |found| {
                            const loc = found.loc;
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
                                    .target_decl_id = found.id,
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
                        const res = try self.makeType(.{ .slice = elem });
                        if (ref_cnt > 1 and can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id))) {
                            try self.cur_mod_closed_types.put(self.scratch, ty_id, res);
                        }
                        return res;
                    }
                    if (std.mem.eql(u8, ref_name, "Promise") or std.mem.eql(u8, ref_name, "PromiseLike")) {
                        needs_runtime.* = true;
                        const inner = if (ref.type_args.len > 0)
                            try self.lowerType(ref.type_args[0], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime)
                        else
                            try self.makeType(.void_type);
                        const res = try self.makeType(.{ .promise = inner });
                        if (ref_cnt > 1 and can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id))) {
                            try self.cur_mod_closed_types.put(self.scratch, ty_id, res);
                        }
                        return res;
                    }
                    if (std.mem.eql(u8, lower_types.stripGlobalQualifier(ref_name), "ArrayBufferLike") and tn.resolved_type == null) {
                        needs_runtime.* = true;
                        return self.makeType(.{ .binary_view = .array_buffer });
                    }
                    if (std.mem.eql(u8, ref_name, "Map") or std.mem.eql(u8, ref_name, "ReadonlyMap")) {
                        needs_runtime.* = true;
                        const k = if (ref.type_args.len > 0)
                            try self.lowerType(ref.type_args[0], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime)
                        else
                            try self.makeType(.js_any);
                        const v = if (ref.type_args.len > 1)
                            try self.lowerType(ref.type_args[1], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime)
                        else
                            try self.makeType(.js_any);
                        const res = try self.makeType(.{ .js_map = .{ .key = k, .value = v } });
                        if (ref_cnt > 1 and can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id))) {
                            try self.cur_mod_closed_types.put(self.scratch, ty_id, res);
                        }
                        return res;
                    }

                    // Utility types (`Partial<T>`, `Pick<T, K>`, `Omit<T, K>`, `Readonly<T>`, `Record<K, V>`, etc.):
                    // ONLY follow `resolved_type` when `ref.target_decl == null` OR `target_decl` is a `type_alias_decl`!
                    // Never inline `resolved_type` for unselected/external `class_decl`/`interface_decl`s (`H3`)!
                    const allow_resolved = if (ref.target_decl) |td|
                        (td < self.graph.decls.len and self.graph.decls[td].kind == .type_alias_decl)
                    else
                        true;
                    if (allow_resolved) {
                        if (tn.resolved_type) |rt| {
                            if (rt != ty_id) {
                                return self.lowerType(rt, is_return_pos, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                            }
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
                            const fp_ir = try self.makeType(.{ .fn_ptr = .{ .params = p_types, .return_type = ret } });
                            if (ref_cnt > 1 and can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id))) {
                                const h = try self.allocFreshAnonHelperName("__zigar_AnonFn", active_tps);
                                const hloc = DeclLocation{
                                    .module_index = self.cur_mod_idx,
                                    .zig_path = h.path,
                                    .type_param_defaults = &.{},
                                };
                                try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);
                                try self.cur_mod_decls_out.?.append(self.alloc, .{
                                    .source_decl_id = null,
                                    .zig_ident = h.zig_ident,
                                    .logical_name = h.logical,
                                    .wire_name = h.logical,
                                    .is_exported = false,
                                    .is_js_exported = false,
                                    .is_default_export = false,
                                    .jsdoc = null,
                                    .kind = .{ .type_alias = .{ .type_params = &.{}, .target = fp_ir } },
                                });
                                return self.makeHoistedDeclRef(hloc);
                            }
                            return fp_ir;
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
                            const fp_ir = try self.makeType(.{ .fn_ptr = .{ .params = p_types, .return_type = ret } });
                            if (ref_cnt > 1 and can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id))) {
                                const h = try self.allocFreshAnonHelperName("__zigar_AnonFn", active_tps);
                                const hloc = DeclLocation{
                                    .module_index = self.cur_mod_idx,
                                    .zig_path = h.path,
                                    .type_param_defaults = &.{},
                                };
                                try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);
                                try self.cur_mod_decls_out.?.append(self.alloc, .{
                                    .source_decl_id = null,
                                    .zig_ident = h.zig_ident,
                                    .logical_name = h.logical,
                                    .wire_name = h.logical,
                                    .is_exported = false,
                                    .is_js_exported = false,
                                    .is_default_export = false,
                                    .jsdoc = null,
                                    .kind = .{ .type_alias = .{ .type_params = &.{}, .target = fp_ir } },
                                });
                                return self.makeHoistedDeclRef(hloc);
                            }
                            return fp_ir;
                        }
                    }
                    const obj_cls = self.classifyObjectLiteral(obj);
                    if (obj_cls.kind == .handle_wrapper) {
                        const is_closed = no_free_vars or try self.isClosedTypeSubgraph(ty_id);
                        if (can_hoist_in_mod and is_closed and self.cur_mod_root_scope != null) {
                            const h = try self.allocFreshAnonHelperName("__zigar_AnonHandle", active_tps);
                            const hloc = DeclLocation{
                                .module_index = self.cur_mod_idx,
                                .zig_path = h.path,
                                .type_param_defaults = &.{},
                            };
                            try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);

                            var empty_names: std.AutoHashMapUnmanaged(u32, naming.BoundName) = .empty;
                            var empty_ovs: std.AutoHashMapUnmanaged(u32, []naming.BoundName) = .empty;
                            var empty_active: std.AutoHashMapUnmanaged(u32, void) = .empty;
                            defer empty_active.deinit(self.scratch);

                            const saved_depth = self.inline_anon_depth;
                            self.inline_anon_depth = 0;
                            defer self.inline_anon_depth = saved_depth;

                            const split = try self.splitObjectLiteralPropsAndMethods(obj.properties);
                            const sourced_calls = try self.wrapUnsourcedSigs(obj.call_signatures);
                            const sourced_ctors = try self.wrapUnsourcedSigs(obj.construct_signatures);

                            const struct_ir = try self.lowerStructDecl(
                                self.cur_mod_idx,
                                std.math.maxInt(u32),
                                obj_cls,
                                false,
                                false,
                                &.{},
                                &.{},
                                split.props,
                                &.{},
                                split.methods,
                                sourced_calls,
                                sourced_ctors,
                                &.{},
                                self.cur_mod_root_scope.?,
                                &empty_names,
                                &empty_ovs,
                                &.{},
                                imports_used,
                                needs_runtime,
                                &empty_active,
                            );
                            try self.cur_mod_decls_out.?.append(self.alloc, .{
                                .source_decl_id = null,
                                .zig_ident = h.zig_ident,
                                .logical_name = h.logical,
                                .wire_name = h.logical,
                                .is_exported = false,
                                .is_js_exported = false,
                                .is_default_export = false,
                                .jsdoc = null,
                                .kind = .{ .struct_decl = struct_ir },
                            });
                            return self.makeHoistedDeclRef(hloc);
                        }
                        needs_runtime.* = true;
                        return self.makeType(if (obj_cls.is_callable_handle) .js_function else .js_object);
                    }
                    if (obj.properties.len > 0) {
                        const is_closed = no_free_vars or try self.isClosedTypeSubgraph(ty_id);
                        // Hoist closed shared/multi-member/nested `object_literal`s (`H3`) once per module
                        // so DAGs like `typeof EventEmitter` or `http2` never re-inline exponentially!
                        if (can_hoist_in_mod and is_closed and (ref_cnt > 1 or obj.properties.len > 2 or self.inline_anon_depth >= 1)) {
                            const h = try self.allocFreshAnonHelperName("__zigar_AnonObj", active_tps);
                            const hloc = DeclLocation{
                                .module_index = self.cur_mod_idx,
                                .zig_path = h.path,
                                .type_param_defaults = &.{},
                            };
                            // Register in `cur_mod_hoisted_locs` BEFORE lowering fields so mutual/self
                            // cycles resolve immediately to `hloc` without re-entering!
                            try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);

                            var anon_scope = naming.ScopeNamer.initContainer(self.scratch, null);
                            defer anon_scope.deinit();
                            try anon_scope.reserve("zigar_js");

                            var fresh_visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
                            defer fresh_visited.deinit(self.scratch);
                            const saved_depth = self.inline_anon_depth;
                            self.inline_anon_depth = 0;
                            defer self.inline_anon_depth = saved_depth;

                            const fields = try self.lowerFields(
                                obj.properties,
                                false,
                                &anon_scope,
                                &.{},
                                null,
                                &fresh_visited,
                                imports_used,
                                needs_runtime,
                            );
                            const target_ty = if (fields.len > 0)
                                try self.makeType(.{ .anon_struct = fields })
                            else blk: {
                                needs_runtime.* = true;
                                break :blk try self.makeType(.js_object);
                            };
                            try self.cur_mod_decls_out.?.append(self.alloc, .{
                                .source_decl_id = null,
                                .zig_ident = h.zig_ident,
                                .logical_name = h.logical,
                                .wire_name = h.logical,
                                .is_exported = false,
                                .is_js_exported = false,
                                .is_default_export = false,
                                .jsdoc = null,
                                .kind = .{ .type_alias = .{ .type_params = &.{}, .target = target_ty } },
                            });
                            return self.makeHoistedDeclRef(hloc);
                        }

                        // Enforce inline nesting & member budget for un-hoistable open generic object literals (`H3`).
                        if (self.inline_anon_depth >= 3 or obj.properties.len > 48) {
                            needs_runtime.* = true;
                            return self.makeType(.js_object);
                        }

                        var anon_scope = naming.ScopeNamer.initContainer(self.scratch, null);
                        defer anon_scope.deinit();
                        try anon_scope.reserve("zigar_js");
                        self.inline_anon_depth += 1;
                        defer self.inline_anon_depth -= 1;
                        const fields = try self.lowerFields(obj.properties, false, &anon_scope, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                        if (fields.len == 0) {
                            needs_runtime.* = true;
                            return self.makeType(.js_object);
                        }
                        return self.makeType(.{ .anon_struct = fields });
                    }
                    needs_runtime.* = true;
                    return self.makeType(.js_object);
                },
                .intersection => |parts| {
                    return self.lowerIntersectionInline(
                        ty_id,
                        parts,
                        ref_cnt,
                        can_hoist_in_mod,
                        no_free_vars,
                        active_tps,
                        self_ident_opt,
                        visited,
                        imports_used,
                        needs_runtime,
                    );
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

        const GraphSliceEnv = struct {
            tp_ids: []const u32,
            ir_args: []const *const TypeIr = &.{},
            graph_args: []const u32 = &.{},
            arg_env: ?*const GraphSliceEnv = null,
        };

        fn isGraphTypeSliceEnv(
            self: *const Self,
            ty_id: u32,
            env: ?*const GraphSliceEnv,
            depth: usize,
        ) bool {
            if (depth >= 24 or ty_id >= self.graph.types.len) return false;
            const tn = self.graph.types[ty_id];
            return switch (tn.kind) {
                .array, .readonly_array => true,
                .type_param => |tp_id| blk: {
                    if (env) |e| {
                        for (e.tp_ids, 0..) |cand_id, idx| {
                            if (cand_id == tp_id) {
                                if (e.ir_args.len > 0) {
                                    if (idx < e.ir_args.len) {
                                        break :blk self.isAlreadySliceTypeIr(e.ir_args[idx], depth + 1);
                                    }
                                } else if (idx < e.graph_args.len) {
                                    break :blk self.isGraphTypeSliceEnv(e.graph_args[idx], e.arg_env, depth + 1);
                                }
                                if (tp_id < self.graph.type_params.len) {
                                    if (self.graph.type_params[tp_id].default_type) |def_id| {
                                        break :blk self.isGraphTypeSliceEnv(def_id, e, depth + 1);
                                    }
                                }
                                break :blk false;
                            }
                        }
                    }
                    break :blk false;
                },
                .reference => |ref| blk: {
                    const ref_name = self.str(ref.target_name);
                    if (env) |e| {
                        for (e.tp_ids, 0..) |cand_id, idx| {
                            if (cand_id < self.graph.type_params.len and
                                std.mem.eql(u8, self.str(self.graph.type_params[cand_id].name), ref_name))
                            {
                                if (e.ir_args.len > 0) {
                                    if (idx < e.ir_args.len) {
                                        break :blk self.isAlreadySliceTypeIr(e.ir_args[idx], depth + 1);
                                    }
                                } else if (idx < e.graph_args.len) {
                                    break :blk self.isGraphTypeSliceEnv(e.graph_args[idx], e.arg_env, depth + 1);
                                }
                                if (self.graph.type_params[cand_id].default_type) |def_id| {
                                    break :blk self.isGraphTypeSliceEnv(def_id, e, depth + 1);
                                }
                                break :blk false;
                            }
                        }
                    }
                    if (ref.target_decl) |td_id| {
                        if (td_id < self.graph.decls.len and self.graph.decls[td_id].kind == .type_alias_decl) {
                            const alias_decl = self.graph.decls[td_id];
                            const next_env = GraphSliceEnv{
                                .tp_ids = alias_decl.type_params,
                                .graph_args = ref.type_args,
                                .arg_env = env,
                            };
                            break :blk self.isGraphTypeSliceEnv(
                                alias_decl.kind.type_alias_decl,
                                if (alias_decl.type_params.len > 0) &next_env else null,
                                depth + 1,
                            );
                        }
                    }
                    if ((ref.target_decl == null or self.isBundledLibDecl(ref.target_decl.?)) and
                        (std.mem.eql(u8, ref_name, "Array") or std.mem.eql(u8, ref_name, "ReadonlyArray")))
                    {
                        break :blk true;
                    }
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) break :blk self.isGraphTypeSliceEnv(rt, env, depth + 1);
                    }
                    break :blk false;
                },
                else => false,
            };
        }

        fn isAlreadySliceTypeIr(self: *const Self, ty: *const TypeIr, depth: usize) bool {
            if (depth >= 24) return false;
            return switch (ty.*) {
                .slice, .typed_slice => true,
                .decl_ref => |dr| blk: {
                    if (dr.indirect or dr.target_decl_id >= self.graph.decls.len) break :blk false;
                    const td = self.graph.decls[dr.target_decl_id];
                    if (td.kind == .type_alias_decl) {
                        const env = GraphSliceEnv{
                            .tp_ids = td.type_params,
                            .ir_args = dr.type_args,
                        };
                        break :blk self.isGraphTypeSliceEnv(
                            td.kind.type_alias_decl,
                            if (td.type_params.len > 0) &env else null,
                            depth + 1,
                        );
                    }
                    break :blk false;
                },
                else => false,
            };
        }

        fn wrapOptionalWithNullish(self: *Self, inner: *TypeIr, kind: lower_types.NullishKind) !*TypeIr {
            const eff_kind: lower_types.NullishKind = if (kind == .none) .null_or_undefined else kind;
            switch (inner.*) {
                .void_type, .noreturn_type => return inner,
                .optional => |opt| {
                    const merged = opt.nullish_kind.merge(eff_kind);
                    if (merged == opt.nullish_kind) return inner;
                    return self.makeType(.{
                        .optional = .{
                            .child = opt.child,
                            .nullish_kind = merged,
                            .is_pure_nullish = opt.is_pure_nullish,
                        },
                    });
                },
                else => return self.makeType(.{ .optional = .{ .child = inner, .nullish_kind = eff_kind } }),
            }
        }

        fn wrapOptional(self: *Self, inner: *TypeIr) !*TypeIr {
            return self.wrapOptionalWithNullish(inner, .undefined_only);
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
                if (p.modifiers.private_mod or p.modifiers.protected_mod) continue;
                if (only_instance and p.modifiers.static_mod) continue;
                const wire = self.str(p.name);
                const bound = try field_scope.bind(wire, .snake);
                const zig_ident = try self.alloc.dupe(u8, bound.zig_ident);
                const logical = try self.alloc.dupe(u8, bound.logical_name);
                const wire_copy = try self.alloc.dupe(u8, bound.wire_name);
                bound.deinit(self.scratch);

                var f_ty = try self.lowerType(p.ty, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                var lit_constraint: ?FieldLiteralConstraintIr = null;
                if (p.modifiers.optional_mod) {
                    f_ty = try self.wrapOptional(f_ty);
                } else {
                    lit_constraint = try self.extractCompatibleFieldLiteralConstraint(p.ty, f_ty);
                }

                try list.append(self.alloc, .{
                    .zig_ident = zig_ident,
                    .logical_name = logical,
                    .wire_name = wire_copy,
                    .ty = f_ty,
                    .is_optional = p.modifiers.optional_mod,
                    .is_readonly = p.modifiers.readonly_mod,
                    .nullish_kind = if (f_ty.* == .optional) f_ty.optional.nullish_kind else .none,
                    .literal_constraint = lit_constraint,
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
                    try fn_scope_fb.reserve("zigar_js");
                    try fn_scope_fb.reserve("zigar_js_tuple");
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
            try fn_scope.reserve("zigar_js");
            try fn_scope.reserve("zigar_js_tuple");

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
                    if (!self.isAlreadySliceTypeIr(pt, 0)) pt = try self.makeType(.{ .slice = pt });
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
                    .nullish_kind = if (!p.rest and pt.* == .optional) pt.optional.nullish_kind else .none,
                };
            }

            const alloc_bound = try fn_scope.bindWithFallbackSuffix("allocator", .snake, "arg");
            const alloc_param_ident = try self.alloc.dupe(u8, alloc_bound.zig_ident);
            alloc_bound.deinit(self.scratch);

            visited.clearRetainingCapacity();
            const has_pred = sig.type_predicate != null;
            const pred_asserts = if (sig.type_predicate) |pred| pred.asserts else false;
            const ret_ty = if (has_pred)
                (if (pred_asserts) try self.makeType(.void_type) else try self.makeType(.bool_type))
            else
                try self.lowerType(sig.return_type, true, tp_res.active, self_ident_opt, &visited, imports_used, needs_runtime);

            return .{
                .self_param_ident = self_param_ident,
                .alloc_param_ident = alloc_param_ident,
                .type_params = tp_res.ir,
                .params = params,
                .return_type = ret_ty,
                .has_type_predicate = has_pred,
                .type_predicate_asserts = pred_asserts,
                .jsdoc = try self.lowerJsDoc(sig.jsdoc),
            };
        }

        fn typeMayAllocateOnDecode(self: *Self, ty: *const TypeIr) error{OutOfMemory}!bool {
            return switch (ty.*) {
                .string_type, .bytes_type, .typed_slice, .slice, .pointer_const, .type_param_ref, .template_pattern => true,
                .inline_enum => false,
                .open_literal_union => |olu| olu.base_kind == .str,
                .optional => |opt| try self.typeMayAllocateOnDecode(opt.child),
                .tuple => |elems| blk: {
                    for (elems) |el| {
                        if (try self.typeMayAllocateOnDecode(el.ty)) break :blk true;
                    }
                    break :blk false;
                },
                .anon_struct => |fields| blk: {
                    for (fields) |f| {
                        if (try self.typeMayAllocateOnDecode(f.ty)) break :blk true;
                    }
                    break :blk false;
                },
                .tagged_union => |tu| blk: {
                    for (tu.variants) |v| {
                        if (try self.typeMayAllocateOnDecode(v.payload)) break :blk true;
                    }
                    break :blk false;
                },
                .decl_ref => |dr| blk: {
                    if (dr.indirect) break :blk true;
                    if (dr.target_decl_id == std.math.maxInt(u32)) {
                        if (dr.decl_zig_path.len == 1 and
                            (std.mem.startsWith(u8, dr.decl_zig_path[0], "__zigar_AnonHandle") or
                                std.mem.startsWith(u8, dr.decl_zig_path[0], "__zigar_AnonFn")))
                        {
                            break :blk false;
                        }
                    } else if (dr.target_decl_id < self.graph.decls.len) {
                        const td_kind = self.graph.decls[dr.target_decl_id].kind;
                        if (td_kind == .enum_decl) break :blk false;
                        if ((try self.classifyDecl(dr.target_decl_id)).kind == .handle_wrapper) {
                            break :blk false;
                        }
                    }
                    break :blk true;
                },
                else => false,
            };
        }

        const EnumMemberLookup = struct {
            enum_decl_id: u32,
            member_idx: usize,
            tag_zig_ident: []const u8,
            tag_logical_name: []const u8,
            value: EnumValueIr,
        };

        fn resolveEnumMemberReference(self: *Self, ty_id: u32) error{OutOfMemory}!?EnumMemberLookup {
            if (ty_id >= self.graph.types.len) return null;
            const tn = self.graph.types[ty_id];
            if (tn.kind != .reference) return null;
            const ref = tn.kind.reference;
            const td = ref.target_decl orelse return null;
            if (td >= self.graph.decls.len) return null;
            const decl = self.graph.decls[td];
            if (decl.kind != .enum_decl) return null;
            const en = decl.kind.enum_decl;
            if (en.members.len == 0) return null;

            const ref_name = self.str(ref.target_name);
            const dot_idx = std.mem.lastIndexOfScalar(u8, ref_name, '.') orelse return null;
            const member_suffix = ref_name[dot_idx + 1 ..];
            if (member_suffix.len == 0) return null;

            // Verify every member in the parent enum has a known value; otherwise runtime representation is a struct wrapper.
            for (en.members) |m| {
                const mv = m.value orelse return null;
                switch (mv) {
                    .num => |n| if (!std.math.isFinite(n)) return null,
                    .str, .boolean, .bigint_literal => {},
                }
            }

            var target_member_idx: ?usize = null;
            for (en.members, 0..) |m, idx| {
                if (std.mem.eql(u8, self.str(m.name), member_suffix)) {
                    target_member_idx = idx;
                    break;
                }
            }
            const found_idx = target_member_idx orelse return null;

            // Replay exact member ScopeNamer binding order so aliased/deduplicated tag names match 1-for-1!
            var member_scope = naming.ScopeNamer.initContainer(self.scratch, null);
            defer member_scope.deinit();
            try member_scope.reserve("zigar_js");
            try member_scope.reserve("__zigar_value");

            var chosen_zig_ident: []const u8 = "";
            var chosen_logical_name: []const u8 = "";
            for (en.members, 0..) |m, idx| {
                const mb = try member_scope.bind(self.str(m.name), .snake);
                if (idx == found_idx) {
                    chosen_zig_ident = try self.alloc.dupe(u8, mb.zig_ident);
                    chosen_logical_name = try self.alloc.dupe(u8, mb.logical_name);
                }
                mb.deinit(self.scratch);
            }

            const mv = en.members[found_idx].value.?;
            const val_ir: EnumValueIr = switch (mv) {
                .num => |n| .{ .num = n },
                .str => |sid| .{ .str = self.str(sid) },
                .boolean => |b| .{ .boolean = b },
                .bigint_literal => |sid| .{ .bigint_val = self.str(sid) },
            };

            return .{
                .enum_decl_id = td,
                .member_idx = found_idx,
                .tag_zig_ident = chosen_zig_ident,
                .tag_logical_name = chosen_logical_name,
                .value = val_ir,
            };
        }

        fn extractClosedLiteralFromType(
            self: *Self,
            ty_id: u32,
            depth: usize,
        ) error{OutOfMemory}!?lower_unions.ClosedLiteralValue {
            if (ty_id >= self.graph.types.len or depth > 8) return null;
            const tn = self.graph.types[ty_id];
            switch (tn.kind) {
                .literal => |lit| return switch (lit) {
                    .str => |sid| .{ .str = self.str(sid) },
                    .num => |n| if (std.math.isFinite(n)) .{ .num = n } else null,
                    .boolean => |b| .{ .boolean = b },
                    .bigint_literal => |sid| .{ .bigint_val = try lower_types.normalizeBigIntLiteral(self.alloc, self.str(sid)) },
                },
                .template_literal => |tl| {
                    if (tl.spans.len == 0) return .{ .str = self.str(tl.head) };
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) return self.extractClosedLiteralFromType(rt, depth + 1);
                    }
                    return null;
                },
                .intrinsic => {
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) return self.extractClosedLiteralFromType(rt, depth + 1);
                    }
                    return null;
                },
                .reference => |ref| {
                    if (try self.resolveEnumMemberReference(ty_id)) |em| {
                        return switch (em.value) {
                            .str => |s| .{ .str = s },
                            .num => |n| .{ .num = n },
                            .boolean => |b| .{ .boolean = b },
                            .bigint_val => |bi| .{ .bigint_val = try lower_types.normalizeBigIntLiteral(self.alloc, bi) },
                            .unknown => null,
                        };
                    }
                    if (ref.target_decl) |td| {
                        if (td < self.graph.decls.len) {
                            const d = self.graph.decls[td];
                            if (d.kind == .type_alias_decl and d.type_params.len == 0) {
                                return self.extractClosedLiteralFromType(d.kind.type_alias_decl, depth + 1);
                            }
                        }
                    } else if (tn.resolved_type) |rt| {
                        if (rt != ty_id) return self.extractClosedLiteralFromType(rt, depth + 1);
                    }
                    return null;
                },
                else => return null,
            }
        }

        fn resolveUnderlyingBuiltinKind(self: *const Self, ty: *const TypeIr, depth: usize) std.meta.Tag(TypeIr) {
            if (depth > 8) return @as(std.meta.Tag(TypeIr), ty.*);
            if (ty.* == .decl_ref) {
                const dr = ty.decl_ref;
                if (!dr.indirect and dr.type_args.len == 0 and dr.target_decl_id < self.graph.decls.len) {
                    const d = self.graph.decls[dr.target_decl_id];
                    if (d.kind == .type_alias_decl) {
                        const target_ty_id = d.kind.type_alias_decl;
                        if (target_ty_id < self.graph.types.len) {
                            switch (self.graph.types[target_ty_id].kind) {
                                .literal => |lit| return switch (lit) {
                                    .str => .string_type,
                                    .num => .f64_type,
                                    .boolean => .bool_type,
                                    .bigint_literal => .i64_type,
                                },
                                .string_type => return .string_type,
                                .number_type => return .f64_type,
                                .boolean_type => return .bool_type,
                                .bigint_type => return .i64_type,
                                else => {},
                            }
                        }
                    }
                }
            }
            return @as(std.meta.Tag(TypeIr), ty.*);
        }

        fn extractCompatibleFieldLiteralConstraint(
            self: *Self,
            raw_ty_id: u32,
            lowered_ty: *const TypeIr,
        ) error{OutOfMemory}!?FieldLiteralConstraintIr {
            if (try self.resolveEnumMemberReference(raw_ty_id)) |em| {
                if (lowered_ty.* == .decl_ref and !lowered_ty.decl_ref.indirect and lowered_ty.decl_ref.target_decl_id == em.enum_decl_id) {
                    return .{
                        .enum_member = .{
                            .enum_decl_id = em.enum_decl_id,
                            .tag_zig_ident = em.tag_zig_ident,
                            .tag_logical_name = em.tag_logical_name,
                        },
                    };
                }
                return null;
            }

            // Do not attach a literal default when `raw_ty_id` is a reference to a multi-member or nominal enum/alias
            // unless `lowered_ty` actually lowered to the corresponding scalar type!
            const underlying_tag = self.resolveUnderlyingBuiltinKind(lowered_ty, 0);
            const clv = (try self.extractClosedLiteralFromType(raw_ty_id, 0)) orelse return null;
            switch (clv) {
                .str => |s| {
                    if (underlying_tag != .string_type) return null;
                    return .{ .str = try self.alloc.dupe(u8, s) };
                },
                .num => |n| {
                    if (underlying_tag != .f64_type) return null;
                    return .{ .num = n };
                },
                .boolean => |b| {
                    if (underlying_tag != .bool_type) return null;
                    return .{ .boolean = b };
                },
                .bigint_val => |bi| {
                    if (underlying_tag != .i64_type) return null;
                    _ = std.fmt.parseInt(i64, bi, 0) catch return null;
                    return .{ .bigint_val = bi };
                },
            }
        }

        fn isEmptyObjectMarkerType(self: *const Self, ty_id: u32, depth: usize) bool {
            if (ty_id >= self.graph.types.len or depth > 4) return false;
            const tn = self.graph.types[ty_id];
            switch (tn.kind) {
                .object_literal => |obj| {
                    return obj.properties.len == 0 and
                        obj.call_signatures.len == 0 and
                        obj.construct_signatures.len == 0 and
                        obj.index_signatures.len == 0;
                },
                .reference => |ref| {
                    const rname = self.str(ref.target_name);
                    if (std.mem.eql(u8, rname, "Record") and ref.type_args.len == 2) {
                        const k_id = ref.type_args[0];
                        if (k_id < self.graph.types.len and self.graph.types[k_id].kind == .never_type) return true;
                    }
                    if (ref.target_decl == null) {
                        if (tn.resolved_type) |rt| {
                            if (rt != ty_id) return self.isEmptyObjectMarkerType(rt, depth + 1);
                        }
                    }
                    return false;
                },
                else => return false,
            }
        }

        fn detectOpenPrimitiveIntersection(self: *const Self, parts: []const u32) ?lower_unions.OpenPrimitiveKind {
            if (parts.len < 2) return null;
            var prim_opt: ?lower_unions.OpenPrimitiveKind = null;
            var saw_empty_obj = false;
            for (parts) |pid| {
                if (pid >= self.graph.types.len) return null;
                switch (self.graph.types[pid].kind) {
                    .string_type => {
                        if (prim_opt != null and prim_opt.? != .str) return null;
                        prim_opt = .str;
                    },
                    .number_type => {
                        if (prim_opt != null and prim_opt.? != .num) return null;
                        prim_opt = .num;
                    },
                    .bigint_type => {
                        if (prim_opt != null and prim_opt.? != .bigint) return null;
                        prim_opt = .bigint;
                    },
                    else => {
                        if (self.isEmptyObjectMarkerType(pid, 0)) {
                            saw_empty_obj = true;
                        } else {
                            return null;
                        }
                    },
                }
            }
            if (saw_empty_obj) return prim_opt;
            return null;
        }

        fn classifyOpenSlotType(self: *const Self, ty_id: u32, depth: usize) ?lower_unions.TemplatePlaceholderKind {
            if (ty_id >= self.graph.types.len or depth > 6) return null;
            const tn = self.graph.types[ty_id];
            return switch (tn.kind) {
                .string_type, .any_type => .any_string,
                .number_type => .number,
                .bigint_type => .bigint,
                .boolean_type => .boolean,
                .intersection => |parts| blk: {
                    if (self.detectOpenPrimitiveIntersection(parts)) |opk| {
                        break :blk switch (opk) {
                            .str => .any_string,
                            .num => .number,
                            .bigint => .bigint,
                        };
                    }
                    break :blk null;
                },
                .reference => |ref| blk: {
                    if (ref.target_decl) |td| {
                        if (td < self.graph.decls.len and ref.type_args.len == 0) {
                            const d = self.graph.decls[td];
                            if (d.kind == .type_alias_decl and d.type_params.len == 0) {
                                break :blk self.classifyOpenSlotType(d.kind.type_alias_decl, depth + 1);
                            }
                        }
                    }
                    break :blk null;
                },
                else => null,
            };
        }

        fn tryExpandFiniteStringSet(
            self: *Self,
            ty_id: u32,
            out: *std.ArrayList([]const u8),
            depth: usize,
        ) error{OutOfMemory}!bool {
            if (ty_id >= self.graph.types.len or depth > 8) return false;
            const tn = self.graph.types[ty_id];
            switch (tn.kind) {
                .never_type => return true,
                .null_type => {
                    try out.append(self.alloc, "null");
                    return out.items.len <= lower_unions.max_template_expansion;
                },
                .undefined_type => {
                    try out.append(self.alloc, "undefined");
                    return out.items.len <= lower_unions.max_template_expansion;
                },
                .boolean_type => {
                    try out.append(self.alloc, "false");
                    try out.append(self.alloc, "true");
                    return out.items.len <= lower_unions.max_template_expansion;
                },
                .literal => |lit| {
                    switch (lit) {
                        .str => |sid| try out.append(self.alloc, self.str(sid)),
                        .boolean => |b| try out.append(self.alloc, if (b) "true" else "false"),
                        .num => |n| {
                            if (!std.math.isFinite(n)) return false;
                            if (lower_unions.exactIntI64(n)) |iv| {
                                try out.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}", .{iv}));
                            } else {
                                try out.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}", .{n}));
                            }
                        },
                        .bigint_literal => |sid| {
                            const clean = try lower_types.normalizeBigIntLiteral(self.alloc, self.str(sid));
                            if (std.fmt.parseInt(i128, clean, 0)) |iv| {
                                try out.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}", .{iv}));
                            } else |_| {
                                try out.append(self.alloc, clean);
                            }
                        },
                    }
                    return out.items.len <= lower_unions.max_template_expansion;
                },
                .union_type => |arms| {
                    for (arms) |aid| {
                        if (!try self.tryExpandFiniteStringSet(aid, out, depth + 1)) return false;
                        if (out.items.len > lower_unions.max_template_expansion) return false;
                    }
                    return true;
                },
                .template_literal => |tl| {
                    if (tl.spans.len == 0) {
                        try out.append(self.alloc, self.str(tl.head));
                        return out.items.len <= lower_unions.max_template_expansion;
                    }
                    var span_alts = try self.scratch.alloc([]const []const u8, tl.spans.len);
                    defer self.scratch.free(span_alts);
                    var seps = try self.scratch.alloc([]const u8, tl.spans.len);
                    defer self.scratch.free(seps);

                    for (tl.spans, 0..) |sp, idx| {
                        var sub: std.ArrayList([]const u8) = .empty;
                        if (!try self.tryExpandFiniteStringSet(sp.ty, &sub, depth + 1)) {
                            sub.deinit(self.alloc);
                            return false;
                        }
                        span_alts[idx] = try sub.toOwnedSlice(self.alloc);
                        seps[idx] = self.str(sp.literal);
                    }
                    const expanded = (try lower_unions.expandTemplateCrossProduct(
                        self.alloc,
                        self.str(tl.head),
                        span_alts,
                        seps,
                    )) orelse return false;
                    defer self.alloc.free(expanded);
                    for (expanded) |s| {
                        try out.append(self.alloc, s);
                        if (out.items.len > lower_unions.max_template_expansion) return false;
                    }
                    return true;
                },
                .intrinsic => {
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) return self.tryExpandFiniteStringSet(rt, out, depth + 1);
                    }
                    return false;
                },
                .reference => |ref| {
                    if (try self.resolveEnumMemberReference(ty_id)) |em| {
                        switch (em.value) {
                            .str => |s| try out.append(self.alloc, s),
                            .num => |n| {
                                if (!std.math.isFinite(n)) return false;
                                if (lower_unions.exactIntI64(n)) |iv| {
                                    try out.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}", .{iv}));
                                } else {
                                    try out.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}", .{n}));
                                }
                            },
                            .boolean => |b| try out.append(self.alloc, if (b) "true" else "false"),
                            .bigint_val => |bi| try out.append(self.alloc, bi),
                            .unknown => return false,
                        }
                        return out.items.len <= lower_unions.max_template_expansion;
                    }
                    if (ref.target_decl) |td| {
                        if (td < self.graph.decls.len and ref.type_args.len == 0) {
                            const d = self.graph.decls[td];
                            switch (d.kind) {
                                .type_alias_decl => |alias_ty| {
                                    if (d.type_params.len == 0) {
                                        return self.tryExpandFiniteStringSet(alias_ty, out, depth + 1);
                                    }
                                },
                                .enum_decl => |en| {
                                    if (en.members.len == 0 or en.members.len > lower_unions.max_template_expansion) return false;
                                    const saved_len = out.items.len;
                                    for (en.members) |m| {
                                        const mv = m.value orelse {
                                            out.shrinkRetainingCapacity(saved_len);
                                            return false;
                                        };
                                        switch (mv) {
                                            .str => |sid| try out.append(self.alloc, self.str(sid)),
                                            .num => |n| {
                                                if (!std.math.isFinite(n)) {
                                                    out.shrinkRetainingCapacity(saved_len);
                                                    return false;
                                                }
                                                if (lower_unions.exactIntI64(n)) |iv| {
                                                    try out.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}", .{iv}));
                                                } else {
                                                    try out.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}", .{n}));
                                                }
                                            },
                                            else => {
                                                out.shrinkRetainingCapacity(saved_len);
                                                return false;
                                            },
                                        }
                                        if (out.items.len > lower_unions.max_template_expansion) return false;
                                    }
                                    return true;
                                },
                                else => {},
                            }
                        }
                    } else if (tn.resolved_type) |rt| {
                        if (rt != ty_id) return self.tryExpandFiniteStringSet(rt, out, depth + 1);
                    }
                    return false;
                },
                else => return false,
            }
        }

        fn buildStringEnumFromUniqueStrings(self: *Self, strs: []const []const u8) error{OutOfMemory}!InlineEnumIr {
            var unique: std.ArrayList([]const u8) = .empty;
            defer unique.deinit(self.scratch);
            for (strs) |s| {
                var dup = false;
                for (unique.items) |u| {
                    if (std.mem.eql(u8, u, s)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) try unique.append(self.scratch, s);
            }

            var tag_scope = naming.ScopeNamer.init(self.scratch, null);
            defer tag_scope.deinit();
            try tag_scope.reserve("zigar_js");

            var members = try self.alloc.alloc(EnumMemberIr, unique.items.len);
            for (unique.items, 0..) |raw_s, idx| {
                const hint = try lower_unions.formatLiteralTagHint(self.scratch, .{ .str = raw_s });
                defer self.scratch.free(hint);
                const bound = try tag_scope.bind(hint, .snake);
                const dup_s = try self.alloc.dupe(u8, raw_s);
                members[idx] = .{
                    .zig_ident = try self.alloc.dupe(u8, bound.zig_ident),
                    .logical_name = try self.alloc.dupe(u8, bound.logical_name),
                    .wire_name = dup_s,
                    .value = .{ .str = dup_s },
                    .jsdoc = null,
                };
                bound.deinit(self.scratch);
            }
            return .{ .backing = .none, .members = members };
        }

        const PendingTemplateSpan = struct {
            placeholder: lower_unions.TemplatePlaceholderKind,
            choices: []const []const u8,
            tail: std.ArrayList(u8),
        };

        fn tryBuildDirectTemplatePattern(self: *Self, tl: anytype) error{OutOfMemory}!?TemplatePatternIr {
            if (tl.spans.len == 0 or tl.spans.len > lower_unions.max_template_pattern_spans) return null;
            var prefix_buf: std.ArrayList(u8) = .empty;
            errdefer prefix_buf.deinit(self.alloc);
            try prefix_buf.appendSlice(self.alloc, self.str(tl.head));

            var pending: std.ArrayList(PendingTemplateSpan) = .empty;
            defer {
                for (pending.items) |*ps| ps.tail.deinit(self.alloc);
                pending.deinit(self.scratch);
            }

            for (tl.spans) |sp| {
                var finite_strs: std.ArrayList([]const u8) = .empty;
                if (try self.tryExpandFiniteStringSet(sp.ty, &finite_strs, 0) and finite_strs.items.len > 0) {
                    var unique: std.ArrayList([]const u8) = .empty;
                    defer unique.deinit(self.scratch);
                    for (finite_strs.items) |s| {
                        var dup = false;
                        for (unique.items) |u| {
                            if (std.mem.eql(u8, u, s)) {
                                dup = true;
                                break;
                            }
                        }
                        if (!dup) try unique.append(self.scratch, s);
                    }
                    finite_strs.deinit(self.alloc);

                    if (unique.items.len == 1) {
                        const fold_target = if (pending.items.len > 0) &pending.items[pending.items.len - 1].tail else &prefix_buf;
                        try fold_target.appendSlice(self.alloc, unique.items[0]);
                        try fold_target.appendSlice(self.alloc, self.str(sp.literal));
                        continue;
                    }
                    var owned_choices = try self.alloc.alloc([]const u8, unique.items.len);
                    for (unique.items, 0..) |u, ci| {
                        owned_choices[ci] = try self.alloc.dupe(u8, u);
                    }
                    var tb: std.ArrayList(u8) = .empty;
                    try tb.appendSlice(self.alloc, self.str(sp.literal));
                    try pending.append(self.scratch, .{
                        .placeholder = .literal_set,
                        .choices = owned_choices,
                        .tail = tb,
                    });
                    continue;
                }
                finite_strs.deinit(self.alloc);

                if (self.classifyOpenSlotType(sp.ty, 0)) |slot_kind| {
                    var tb: std.ArrayList(u8) = .empty;
                    try tb.appendSlice(self.alloc, self.str(sp.literal));
                    try pending.append(self.scratch, .{
                        .placeholder = slot_kind,
                        .choices = &.{},
                        .tail = tb,
                    });
                } else {
                    prefix_buf.deinit(self.alloc);
                    return null;
                }
            }

            if (pending.items.len == 0) {
                prefix_buf.deinit(self.alloc);
                return null;
            }

            var out_spans = try self.alloc.alloc(TemplateSpanIr, pending.items.len);
            for (pending.items, 0..) |*ps, idx| {
                out_spans[idx] = .{
                    .placeholder = ps.placeholder,
                    .choices = ps.choices,
                    .literal_tail = try ps.tail.toOwnedSlice(self.alloc),
                };
            }
            return .{
                .head = try prefix_buf.toOwnedSlice(self.alloc),
                .spans = out_spans,
            };
        }

        fn lowerTemplateLiteralInline(
            self: *Self,
            ty_id: u32,
            tl: anytype,
            resolved_opt: ?u32,
            ref_cnt: u32,
            can_hoist_in_mod: bool,
            no_free_vars: bool,
            active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            visited: *std.AutoHashMapUnmanaged(u32, void),
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}!*TypeIr {
            if (tl.spans.len == 0) return self.makeType(.string_type);

            var finite_strs: std.ArrayList([]const u8) = .empty;
            defer finite_strs.deinit(self.alloc);
            if (try self.tryExpandFiniteStringSet(ty_id, &finite_strs, 0)) {
                if (finite_strs.items.len <= 1) return self.makeType(.string_type);
                const enum_ir = try self.buildStringEnumFromUniqueStrings(finite_strs.items);
                if (enum_ir.members.len <= 1) return self.makeType(.string_type);
                if (can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id)) and (ref_cnt > 1 or enum_ir.members.len > 8)) {
                    const h = try self.allocFreshAnonHelperName("__zigar_AnonEnum", active_tps);
                    const hloc = DeclLocation{
                        .module_index = self.cur_mod_idx,
                        .zig_path = h.path,
                        .type_param_defaults = &.{},
                    };
                    try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);
                    try self.cur_mod_decls_out.?.append(self.alloc, .{
                        .source_decl_id = null,
                        .zig_ident = h.zig_ident,
                        .logical_name = h.logical,
                        .wire_name = h.logical,
                        .is_exported = false,
                        .is_js_exported = false,
                        .is_default_export = false,
                        .jsdoc = null,
                        .kind = .{ .literal_enum_decl = enum_ir },
                    });
                    return self.makeHoistedDeclRef(hloc);
                }
                if (self.inline_anon_depth >= 3 or enum_ir.members.len > 64) {
                    return self.makeType(.string_type);
                }
                return self.makeType(.{ .inline_enum = enum_ir });
            }

            if (try self.tryBuildDirectTemplatePattern(tl)) |pat_ir| {
                needs_runtime.* = true;
                if (can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id)) and ref_cnt > 1) {
                    const h = try self.allocFreshAnonHelperName("__zigar_AnonTemplate", active_tps);
                    const hloc = DeclLocation{
                        .module_index = self.cur_mod_idx,
                        .zig_path = h.path,
                        .type_param_defaults = &.{},
                    };
                    try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);
                    try self.cur_mod_decls_out.?.append(self.alloc, .{
                        .source_decl_id = null,
                        .zig_ident = h.zig_ident,
                        .logical_name = h.logical,
                        .wire_name = h.logical,
                        .is_exported = false,
                        .is_js_exported = false,
                        .is_default_export = false,
                        .jsdoc = null,
                        .kind = .{ .template_pattern_decl = pat_ir },
                    });
                    return self.makeHoistedDeclRef(hloc);
                }
                if (self.inline_anon_depth >= 3) {
                    return self.makeType(.string_type);
                }
                return self.makeType(.{ .template_pattern = pat_ir });
            }

            // If TypeScript Checker distributed a union inside a template literal (`${"http"|"https"}://${string}`),
            // delegate to the resolved union!
            if (resolved_opt) |rt| {
                if (rt != ty_id and rt < self.graph.types.len and self.graph.types[rt].kind == .union_type) {
                    return self.lowerType(rt, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                }
            }
            return self.makeType(.string_type);
        }

        const MergedPropSpec = struct {
            prop_id: u32,
            name_sid: u32,
            wire: []const u8,
            ty: u32,
            optional: bool,
            readonly: bool,
            jsdoc: @TypeOf(@as(*const anyopaque, undefined)),
        };

        const RawObjectPropItem = struct {
            name_sid: u32,
            wire: []const u8,
            ty: u32,
            optional: bool,
            readonly: bool,
            source_prop_id: u32,
        };

        fn typeHasNarrowerLiteralInfo(self: *Self, ty_id: u32, depth: usize) error{OutOfMemory}!bool {
            if (ty_id >= self.graph.types.len or depth > 6) return false;
            if ((try self.extractClosedLiteralFromType(ty_id, 0)) != null) return true;
            const tn = self.graph.types[ty_id];
            if (tn.kind == .union_type) {
                for (tn.kind.union_type) |aid| {
                    if (aid < self.graph.types.len) {
                        const ak = self.graph.types[aid].kind;
                        if (ak == .never_type) continue;
                        if ((try self.extractClosedLiteralFromType(aid, 0)) == null) return false;
                    }
                }
                return tn.kind.union_type.len > 0;
            }
            return false;
        }

        fn mergePropIntoList(
            self: *Self,
            list: *std.ArrayList(RawObjectPropItem),
            item: RawObjectPropItem,
        ) error{OutOfMemory}!void {
            for (list.items) |*existing| {
                if (std.mem.eql(u8, existing.wire, item.wire)) {
                    existing.optional = existing.optional and item.optional;
                    existing.readonly = existing.readonly and item.readonly;
                    const item_narrow = try self.typeHasNarrowerLiteralInfo(item.ty, 0);
                    const exist_narrow = try self.typeHasNarrowerLiteralInfo(existing.ty, 0);
                    if (item_narrow and !exist_narrow) {
                        existing.ty = item.ty;
                        existing.source_prop_id = item.source_prop_id;
                    } else if (!exist_narrow) {
                        existing.ty = item.ty;
                        existing.source_prop_id = item.source_prop_id;
                    }
                    return;
                }
            }
            try list.append(self.scratch, item);
        }

        fn collectObjectArmProps(
            self: *Self,
            ty_id: u32,
            allow_class_decl: bool,
            out: *std.ArrayList(RawObjectPropItem),
            depth: usize,
        ) error{OutOfMemory}!bool {
            if (ty_id >= self.graph.types.len or depth > 8) return false;
            const tn = self.graph.types[ty_id];
            switch (tn.kind) {
                .object_literal => |obj| {
                    if (obj.call_signatures.len > 0 or obj.construct_signatures.len > 0) return false;
                    if (!allow_class_decl and self.classifyObjectLiteral(obj).kind == .handle_wrapper) return false;
                    for (obj.properties) |pid| {
                        if (pid >= self.graph.properties.len) continue;
                        const p = self.graph.properties[pid];
                        if (p.modifiers.method_mod or p.modifiers.private_mod or p.modifiers.protected_mod or p.modifiers.static_mod) continue;
                        try self.mergePropIntoList(out, .{
                            .name_sid = p.name,
                            .wire = self.str(p.name),
                            .ty = p.ty,
                            .optional = p.modifiers.optional_mod,
                            .readonly = p.modifiers.readonly_mod,
                            .source_prop_id = pid,
                        });
                    }
                    return true;
                },
                .intersection => |parts| {
                    if (parts.len == 0) return false;
                    for (parts) |pid| {
                        if (!try self.collectObjectArmProps(pid, allow_class_decl, out, depth + 1)) return false;
                    }
                    return true;
                },
                .reference => |ref| {
                    if (self.isBuiltinMappedReference(self.str(ref.target_name), ref.type_args.len, ref.target_decl)) return false;
                    const rname = self.str(ref.target_name);
                    if (std.mem.eql(u8, rname, "Array") or std.mem.eql(u8, rname, "ReadonlyArray") or
                        std.mem.eql(u8, rname, "Promise") or std.mem.eql(u8, rname, "PromiseLike") or
                        std.mem.eql(u8, rname, "Map") or std.mem.eql(u8, rname, "ReadonlyMap") or
                        std.mem.eql(u8, rname, "Set") or std.mem.eql(u8, rname, "ReadonlySet"))
                    {
                        return false;
                    }
                    if (ref.target_decl) |td| {
                        if (td >= self.graph.decls.len) return false;
                        const d = self.graph.decls[td];
                        // For generic references (`Box<T>`), only inspect when 0 type args or resolved_type is concrete.
                        if (d.type_params.len > 0 and ref.type_args.len > 0) {
                            if (d.kind == .type_alias_decl) {
                                if (tn.resolved_type) |rt| {
                                    if (rt != ty_id) return self.collectObjectArmProps(rt, allow_class_decl, out, depth + 1);
                                }
                            }
                            return false;
                        }
                        switch (d.kind) {
                            .interface_decl => |iface| {
                                if (iface.call_signatures.len > 0 or iface.construct_signatures.len > 0) return false;
                                if (!allow_class_decl and (try self.classifyDecl(td)).kind == .handle_wrapper) {
                                    return false;
                                }
                                for (iface.extends_clauses) |hc| {
                                    _ = try self.collectObjectArmProps(hc.target_type, allow_class_decl, out, depth + 1);
                                }
                                for (iface.properties) |pid| {
                                    if (pid >= self.graph.properties.len) continue;
                                    const p = self.graph.properties[pid];
                                    if (p.modifiers.private_mod or p.modifiers.protected_mod or p.modifiers.static_mod) continue;
                                    try self.mergePropIntoList(out, .{
                                        .name_sid = p.name,
                                        .wire = self.str(p.name),
                                        .ty = p.ty,
                                        .optional = p.modifiers.optional_mod,
                                        .readonly = p.modifiers.readonly_mod,
                                        .source_prop_id = pid,
                                    });
                                }
                                return true;
                            },
                            .class_decl => |cls| {
                                if (!allow_class_decl) return false;
                                if (cls.extends_clause) |hc| {
                                    _ = try self.collectObjectArmProps(hc.target_type, allow_class_decl, out, depth + 1);
                                }
                                for (cls.implements_clauses) |hc| {
                                    _ = try self.collectObjectArmProps(hc.target_type, allow_class_decl, out, depth + 1);
                                }
                                for (cls.properties) |pid| {
                                    if (pid >= self.graph.properties.len) continue;
                                    const p = self.graph.properties[pid];
                                    if (p.modifiers.private_mod or p.modifiers.protected_mod or p.modifiers.static_mod) continue;
                                    try self.mergePropIntoList(out, .{
                                        .name_sid = p.name,
                                        .wire = self.str(p.name),
                                        .ty = p.ty,
                                        .optional = p.modifiers.optional_mod,
                                        .readonly = p.modifiers.readonly_mod,
                                        .source_prop_id = pid,
                                    });
                                }
                                return true;
                            },
                            .type_alias_decl => |alias_ty| {
                                return self.collectObjectArmProps(alias_ty, allow_class_decl, out, depth + 1);
                            },
                            else => return false,
                        }
                    } else if (tn.resolved_type) |rt| {
                        if (rt != ty_id) return self.collectObjectArmProps(rt, allow_class_decl, out, depth + 1);
                    }
                    return false;
                },
                else => return false,
            }
        }

        fn lowerMergedRawProps(
            self: *Self,
            raw_props: []const RawObjectPropItem,
            field_scope: *naming.ScopeNamer,
            active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            visited: *std.AutoHashMapUnmanaged(u32, void),
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}![]FieldIr {
            var list: std.ArrayList(FieldIr) = .empty;
            errdefer list.deinit(self.alloc);

            for (raw_props) |rp| {
                const bound = try field_scope.bind(rp.wire, .snake);
                const zig_ident = try self.alloc.dupe(u8, bound.zig_ident);
                const logical = try self.alloc.dupe(u8, bound.logical_name);
                const wire_copy = try self.alloc.dupe(u8, bound.wire_name);
                bound.deinit(self.scratch);

                var f_ty = try self.lowerType(rp.ty, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                var lit_constraint: ?FieldLiteralConstraintIr = null;
                if (rp.optional) {
                    f_ty = try self.wrapOptional(f_ty);
                } else {
                    lit_constraint = try self.extractCompatibleFieldLiteralConstraint(rp.ty, f_ty);
                }
                const jsdoc = if (rp.source_prop_id < self.graph.properties.len)
                    try self.lowerJsDoc(self.graph.properties[rp.source_prop_id].jsdoc)
                else
                    null;

                try list.append(self.alloc, .{
                    .zig_ident = zig_ident,
                    .logical_name = logical,
                    .wire_name = wire_copy,
                    .ty = f_ty,
                    .is_optional = rp.optional,
                    .is_readonly = rp.readonly,
                    .nullish_kind = if (f_ty.* == .optional) f_ty.optional.nullish_kind else .none,
                    .literal_constraint = lit_constraint,
                    .jsdoc = jsdoc,
                });
            }
            return try list.toOwnedSlice(self.alloc);
        }

        fn lowerIntersectionInline(
            self: *Self,
            ty_id: u32,
            parts: []const u32,
            ref_cnt: u32,
            can_hoist_in_mod: bool,
            no_free_vars: bool,
            active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            visited: *std.AutoHashMapUnmanaged(u32, void),
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}!*TypeIr {
            if (self.detectOpenPrimitiveIntersection(parts)) |opk| {
                return switch (opk) {
                    .str => self.makeType(.string_type),
                    .num => self.makeType(.f64_type),
                    .bigint => self.makeType(.i64_type),
                };
            }

            var merged_props: std.ArrayList(RawObjectPropItem) = .empty;
            defer merged_props.deinit(self.scratch);
            if (try self.collectObjectArmProps(ty_id, false, &merged_props, 0) and merged_props.items.len > 0) {
                if (ref_cnt > 1 and can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id))) {
                    const h = try self.allocFreshAnonHelperName("__zigar_AnonObj", active_tps);
                    const hloc = DeclLocation{
                        .module_index = self.cur_mod_idx,
                        .zig_path = h.path,
                        .type_param_defaults = &.{},
                    };
                    try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);

                    var anon_scope = naming.ScopeNamer.initContainer(self.scratch, null);
                    defer anon_scope.deinit();
                    try anon_scope.reserve("zigar_js");

                    var fresh_visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
                    defer fresh_visited.deinit(self.scratch);
                    const saved_depth = self.inline_anon_depth;
                    self.inline_anon_depth = 0;
                    defer self.inline_anon_depth = saved_depth;

                    const fields = try self.lowerMergedRawProps(
                        merged_props.items,
                        &anon_scope,
                        &.{},
                        null,
                        &fresh_visited,
                        imports_used,
                        needs_runtime,
                    );
                    const target_ty = try self.makeType(.{ .anon_struct = fields });
                    try self.cur_mod_decls_out.?.append(self.alloc, .{
                        .source_decl_id = null,
                        .zig_ident = h.zig_ident,
                        .logical_name = h.logical,
                        .wire_name = h.logical,
                        .is_exported = false,
                        .is_js_exported = false,
                        .is_default_export = false,
                        .jsdoc = null,
                        .kind = .{ .type_alias = .{ .type_params = &.{}, .target = target_ty } },
                    });
                    return self.makeHoistedDeclRef(hloc);
                }

                if (self.inline_anon_depth >= 3 or merged_props.items.len > 48) {
                    needs_runtime.* = true;
                    return self.makeType(.js_object);
                }

                var anon_scope = naming.ScopeNamer.initContainer(self.scratch, null);
                defer anon_scope.deinit();
                try anon_scope.reserve("zigar_js");
                self.inline_anon_depth += 1;
                defer self.inline_anon_depth -= 1;

                const fields = try self.lowerMergedRawProps(
                    merged_props.items,
                    &anon_scope,
                    active_tps,
                    self_ident_opt,
                    visited,
                    imports_used,
                    needs_runtime,
                );
                return self.makeType(.{ .anon_struct = fields });
            }

            const inter_cls = try self.classifyObjectType(ty_id);
            if (inter_cls.kind == .handle_wrapper) {
                var inter_props: std.ArrayList(SourcedProp) = .empty;
                defer inter_props.deinit(self.scratch);
                var inter_methods: std.ArrayList(SourcedMethod) = .empty;
                defer inter_methods.deinit(self.scratch);
                var inter_calls: std.ArrayList(SourcedSig) = .empty;
                defer inter_calls.deinit(self.scratch);
                var inter_ctors: std.ArrayList(SourcedSig) = .empty;
                defer inter_ctors.deinit(self.scratch);

                if (try self.collectHandleIntersectionMembers(
                    ty_id,
                    &inter_props,
                    &inter_methods,
                    &inter_calls,
                    &inter_ctors,
                ) and (inter_props.items.len > 0 or inter_methods.items.len > 0 or
                    inter_calls.items.len > 0 or inter_ctors.items.len > 0))
                {
                    const is_closed = no_free_vars or try self.isClosedTypeSubgraph(ty_id);
                    if (can_hoist_in_mod and is_closed and self.cur_mod_root_scope != null) {
                        const h = try self.allocFreshAnonHelperName("__zigar_AnonHandle", active_tps);
                        const hloc = DeclLocation{
                            .module_index = self.cur_mod_idx,
                            .zig_path = h.path,
                            .type_param_defaults = &.{},
                        };
                        try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);

                        var empty_names: std.AutoHashMapUnmanaged(u32, naming.BoundName) = .empty;
                        var empty_ovs: std.AutoHashMapUnmanaged(u32, []naming.BoundName) = .empty;
                        var empty_active: std.AutoHashMapUnmanaged(u32, void) = .empty;
                        defer empty_active.deinit(self.scratch);

                        const saved_depth = self.inline_anon_depth;
                        self.inline_anon_depth = 0;
                        defer self.inline_anon_depth = saved_depth;

                        const struct_ir = try self.lowerStructDecl(
                            self.cur_mod_idx,
                            std.math.maxInt(u32),
                            inter_cls,
                            false,
                            false,
                            &.{},
                            &.{},
                            inter_props.items,
                            &.{},
                            inter_methods.items,
                            inter_calls.items,
                            inter_ctors.items,
                            &.{},
                            self.cur_mod_root_scope.?,
                            &empty_names,
                            &empty_ovs,
                            &.{},
                            imports_used,
                            needs_runtime,
                            &empty_active,
                        );
                        try self.cur_mod_decls_out.?.append(self.alloc, .{
                            .source_decl_id = null,
                            .zig_ident = h.zig_ident,
                            .logical_name = h.logical,
                            .wire_name = h.logical,
                            .is_exported = false,
                            .is_js_exported = false,
                            .is_default_export = false,
                            .jsdoc = null,
                            .kind = .{ .struct_decl = struct_ir },
                        });
                        return self.makeHoistedDeclRef(hloc);
                    }
                    needs_runtime.* = true;
                    return self.makeType(if (inter_cls.is_callable_handle) .js_function else .js_object);
                }
            }

            if (ty_id < self.graph.types.len) {
                if (self.graph.types[ty_id].resolved_type) |rt| {
                    if (rt != ty_id and rt < self.graph.types.len and self.graph.types[rt].kind == .object_literal) {
                        var safe_to_follow = true;
                        for (parts) |pid| {
                            if (pid < self.graph.types.len and self.graph.types[pid].kind == .reference) {
                                if (self.graph.types[pid].kind.reference.target_decl) |td| {
                                    if (self.lookupDeclLocation(td) == null and
                                        (td >= self.graph.decls.len or self.graph.decls[td].kind != .type_alias_decl))
                                    {
                                        safe_to_follow = false;
                                        break;
                                    }
                                }
                            }
                        }
                        if (safe_to_follow) {
                            return self.lowerType(rt, false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                        }
                    }
                }
            }

            needs_runtime.* = true;
            return self.makeType(.js_value);
        }

        fn collectFlattenedUnionArms(
            self: *const Self,
            arms: []const u32,
            non_null: *std.ArrayList(u32),
            nullish: *lower_types.NullishKind,
            depth: usize,
        ) error{OutOfMemory}!void {
            if (depth > 8) return;
            for (arms) |arm_id| {
                if (arm_id >= self.graph.types.len) continue;
                switch (self.graph.types[arm_id].kind) {
                    .null_type => nullish.* = nullish.merge(.null_only),
                    .undefined_type, .void_type => nullish.* = nullish.merge(.undefined_only),
                    .never_type => {},
                    .union_type => |sub_arms| try self.collectFlattenedUnionArms(sub_arms, non_null, nullish, depth + 1),
                    else => try non_null.append(self.scratch, arm_id),
                }
            }
        }

        fn closedLiteralToEnumValue(self: *Self, clv: lower_unions.ClosedLiteralValue) error{OutOfMemory}!EnumValueIr {
            return switch (clv) {
                .str => |s| .{ .str = try self.alloc.dupe(u8, s) },
                .num => |n| .{ .num = n },
                .boolean => |b| .{ .boolean = b },
                .bigint_val => |bi| .{ .bigint_val = try lower_types.normalizeBigIntLiteral(self.alloc, bi) },
            };
        }

        fn buildEnumMembersFromClosedLiterals(
            self: *Self,
            vals: []const lower_unions.ClosedLiteralValue,
        ) error{OutOfMemory}!InlineEnumIr {
            const analysis = try lower_unions.analyzeClosedEnumValues(self.scratch, vals);
            defer analysis.deinit(self.scratch);

            var tag_scope = naming.ScopeNamer.init(self.scratch, null);
            defer tag_scope.deinit();
            try tag_scope.reserve("zigar_js");

            var members = try self.alloc.alloc(EnumMemberIr, vals.len);
            for (vals, 0..) |v, idx| {
                const hint = try lower_unions.formatLiteralTagHint(self.scratch, v);
                defer self.scratch.free(hint);
                const bound = try tag_scope.bind(hint, .snake);
                const wire_str: []const u8 = switch (v) {
                    .str => |s| try self.alloc.dupe(u8, s),
                    else => try self.alloc.dupe(u8, bound.logical_name),
                };
                members[idx] = .{
                    .zig_ident = try self.alloc.dupe(u8, bound.zig_ident),
                    .logical_name = try self.alloc.dupe(u8, bound.logical_name),
                    .wire_name = wire_str,
                    .value = try self.closedLiteralToEnumValue(v),
                    .int_backing_val = analysis.layouts[idx].int_tag_value,
                    .alias_of_zig_ident = if (analysis.layouts[idx].alias_of_index) |pidx| members[pidx].zig_ident else null,
                    .alias_of_logical_name = if (analysis.layouts[idx].alias_of_index) |pidx| members[pidx].logical_name else null,
                    .jsdoc = null,
                };
                bound.deinit(self.scratch);
            }
            return .{ .backing = analysis.backing, .members = members };
        }

        fn appendUniqueClosedLiteral(
            self: *Self,
            list: *std.ArrayList(lower_unions.ClosedLiteralValue),
            val: lower_unions.ClosedLiteralValue,
        ) error{OutOfMemory}!void {
            for (list.items) |existing| {
                if (lower_unions.closedLiteralEql(existing, val)) return;
            }
            try list.append(self.scratch, val);
        }

        fn tryCollectClosedLiteralsFromArm(
            self: *Self,
            arm_id: u32,
            out: *std.ArrayList(lower_unions.ClosedLiteralValue),
            expand_alias_refs: bool,
            depth: usize,
        ) error{OutOfMemory}!bool {
            if (arm_id >= self.graph.types.len or depth > 6) return false;
            const tn = self.graph.types[arm_id];
            switch (tn.kind) {
                .literal => {
                    if (try self.extractClosedLiteralFromType(arm_id, 0)) |clv| {
                        try self.appendUniqueClosedLiteral(out, clv);
                        return out.items.len <= 128;
                    }
                    return false;
                },
                .template_literal => {
                    var strs: std.ArrayList([]const u8) = .empty;
                    defer strs.deinit(self.alloc);
                    if (!try self.tryExpandFiniteStringSet(arm_id, &strs, 0)) return false;
                    for (strs.items) |s| {
                        try self.appendUniqueClosedLiteral(out, .{ .str = s });
                        if (out.items.len > 128) return false;
                    }
                    return true;
                },
                .intrinsic => {
                    if (tn.resolved_type) |rt| {
                        if (rt != arm_id) return self.tryCollectClosedLiteralsFromArm(rt, out, expand_alias_refs, depth + 1);
                    }
                    return false;
                },
                .union_type => |sub_arms| {
                    for (sub_arms) |sa| {
                        if (sa < self.graph.types.len and self.graph.types[sa].kind == .never_type) continue;
                        if (!try self.tryCollectClosedLiteralsFromArm(sa, out, expand_alias_refs, depth + 1)) return false;
                    }
                    return true;
                },
                .reference => |ref| {
                    if (try self.resolveEnumMemberReference(arm_id)) |em| {
                        const clv: lower_unions.ClosedLiteralValue = switch (em.value) {
                            .str => |s| .{ .str = s },
                            .num => |n| .{ .num = n },
                            .boolean => |b| .{ .boolean = b },
                            .bigint_val => |bi| .{ .bigint_val = try lower_types.normalizeBigIntLiteral(self.alloc, bi) },
                            .unknown => return false,
                        };
                        try self.appendUniqueClosedLiteral(out, clv);
                        return out.items.len <= 128;
                    }
                    if (expand_alias_refs) {
                        if (ref.target_decl) |td| {
                            if (td < self.graph.decls.len and ref.type_args.len == 0) {
                                const d = self.graph.decls[td];
                                if (d.kind == .type_alias_decl and d.type_params.len == 0) {
                                    return self.tryCollectClosedLiteralsFromArm(d.kind.type_alias_decl, out, true, depth + 1);
                                }
                            }
                        } else if (tn.resolved_type) |rt| {
                            if (rt != arm_id) return self.tryCollectClosedLiteralsFromArm(rt, out, true, depth + 1);
                        }
                    } else if (ref.target_decl == null) {
                        if (tn.resolved_type) |rt| {
                            if (rt != arm_id) return self.tryCollectClosedLiteralsFromArm(rt, out, false, depth + 1);
                        }
                    }
                    return false;
                },
                else => return false,
            }
        }

        fn isExactBooleanPair(vals: []const lower_unions.ClosedLiteralValue) bool {
            if (vals.len != 2) return false;
            if (vals[0] != .boolean or vals[1] != .boolean) return false;
            return vals[0].boolean != vals[1].boolean;
        }

        fn tryBuildClosedLiteralEnum(
            self: *Self,
            non_null_arms: []const u32,
        ) error{OutOfMemory}!?InlineEnumIr {
            if (non_null_arms.len == 0) return null;
            var vals: std.ArrayList(lower_unions.ClosedLiteralValue) = .empty;
            defer vals.deinit(self.scratch);
            for (non_null_arms) |aid| {
                if (!try self.tryCollectClosedLiteralsFromArm(aid, &vals, false, 0)) return null;
            }
            if (vals.items.len < 2) return null;
            if (isExactBooleanPair(vals.items)) return null;
            return try self.buildEnumMembersFromClosedLiterals(vals.items);
        }

        fn tryBuildOpenLiteralUnion(
            self: *Self,
            non_null_arms: []const u32,
        ) error{OutOfMemory}!?OpenLiteralUnionIr {
            if (non_null_arms.len < 2) return null;
            var open_prim_opt: ?lower_unions.OpenPrimitiveKind = null;
            var vals: std.ArrayList(lower_unions.ClosedLiteralValue) = .empty;
            defer vals.deinit(self.scratch);

            for (non_null_arms) |aid| {
                if (aid >= self.graph.types.len) return null;
                const tn = self.graph.types[aid];
                if (tn.kind == .intersection) {
                    if (self.detectOpenPrimitiveIntersection(tn.kind.intersection)) |opk| {
                        if (open_prim_opt != null and open_prim_opt.? != opk) return null;
                        open_prim_opt = opk;
                        continue;
                    }
                }
                if (!try self.tryCollectClosedLiteralsFromArm(aid, &vals, true, 0)) return null;
            }

            const open_prim = open_prim_opt orelse return null;
            if (vals.items.len == 0 or vals.items.len > 128) return null;

            for (vals.items) |v| {
                const matches_prim = switch (open_prim) {
                    .str => v == .str,
                    .num => v == .num,
                    .bigint => blk: {
                        if (v != .bigint_val) break :blk false;
                        _ = std.fmt.parseInt(i64, v.bigint_val, 0) catch break :blk false;
                        break :blk true;
                    },
                };
                if (!matches_prim) return null;
            }

            var tag_scope = naming.ScopeNamer.init(self.scratch, null);
            defer tag_scope.deinit();
            try tag_scope.reserve("zigar_js");

            var known_members = try self.alloc.alloc(EnumMemberIr, vals.items.len);
            for (vals.items, 0..) |v, idx| {
                const hint = try lower_unions.formatLiteralTagHint(self.scratch, v);
                defer self.scratch.free(hint);
                const bound = try tag_scope.bind(hint, .snake);
                const wire_str: []const u8 = switch (v) {
                    .str => |s| try self.alloc.dupe(u8, s),
                    else => try self.alloc.dupe(u8, bound.logical_name),
                };
                known_members[idx] = .{
                    .zig_ident = try self.alloc.dupe(u8, bound.zig_ident),
                    .logical_name = try self.alloc.dupe(u8, bound.logical_name),
                    .wire_name = wire_str,
                    .value = try self.closedLiteralToEnumValue(v),
                    .jsdoc = null,
                };
                bound.deinit(self.scratch);
            }

            const custom_bound = try tag_scope.bind("custom", .snake);
            const custom_ident = try self.alloc.dupe(u8, custom_bound.zig_ident);
            const custom_logical = try self.alloc.dupe(u8, custom_bound.logical_name);
            custom_bound.deinit(self.scratch);

            const custom_payload = switch (open_prim) {
                .str => try self.makeType(.string_type),
                .num => try self.makeType(.f64_type),
                .bigint => try self.makeType(.i64_type),
            };

            return .{
                .base_kind = open_prim,
                .known_members = known_members,
                .custom_tag_ident = custom_ident,
                .custom_logical_name = custom_logical,
                .custom_payload = custom_payload,
            };
        }

        fn fieldConstraintEql(a: ?FieldLiteralConstraintIr, b: ?FieldLiteralConstraintIr) bool {
            if (a == null and b == null) return true;
            if (a == null or b == null) return false;
            const va = a.?;
            const vb = b.?;
            if (@as(std.meta.Tag(FieldLiteralConstraintIr), va) != @as(std.meta.Tag(FieldLiteralConstraintIr), vb)) return false;
            return switch (va) {
                .str => |sa| std.mem.eql(u8, sa, vb.str),
                .num => |na| na == vb.num,
                .boolean => |ba| ba == vb.boolean,
                .bigint_val => |bia| std.mem.eql(u8, bia, vb.bigint_val),
                .enum_member => |ema| ema.enum_decl_id == vb.enum_member.enum_decl_id and
                    std.mem.eql(u8, ema.tag_logical_name, vb.enum_member.tag_logical_name),
            };
        }

        fn typeIrEql(a: *const TypeIr, b: *const TypeIr, depth: usize) bool {
            if (a == b) return true;
            if (depth > 8) return false;
            if (@as(std.meta.Tag(TypeIr), a.*) != @as(std.meta.Tag(TypeIr), b.*)) return false;
            return switch (a.*) {
                .void_type,
                .noreturn_type,
                .bool_type,
                .f64_type,
                .i64_type,
                .string_type,
                .bytes_type,
                .js_value,
                .js_any,
                .js_unknown,
                .js_object,
                .js_function,
                .js_symbol,
                .js_bigint,
                .js_string,
                => true,
                .typed_slice => |pa| pa == b.typed_slice,
                .binary_view => |ba| ba == b.binary_view,
                .self_type => |sa| std.mem.eql(u8, sa, b.self_type),
                .type_param_ref => |ta| std.mem.eql(u8, ta, b.type_param_ref),
                .optional => |oa| oa.nullish_kind == b.optional.nullish_kind and oa.is_pure_nullish == b.optional.is_pure_nullish and typeIrEql(oa.child, b.optional.child, depth + 1),
                .pointer_const => |ia| typeIrEql(ia, b.pointer_const, depth + 1),
                .slice => |sa| typeIrEql(sa, b.slice, depth + 1),
                .promise => |pa| typeIrEql(pa, b.promise, depth + 1),
                .js_map => |ma| typeIrEql(ma.key, b.js_map.key, depth + 1) and typeIrEql(ma.value, b.js_map.value, depth + 1),
                .decl_ref => |da| blk: {
                    const db = b.decl_ref;
                    if (da.module_index != db.module_index or da.target_decl_id != db.target_decl_id or da.indirect != db.indirect) break :blk false;
                    if (da.decl_zig_path.len != db.decl_zig_path.len or da.type_args.len != db.type_args.len) break :blk false;
                    for (da.decl_zig_path, db.decl_zig_path) |sa, sb| {
                        if (!std.mem.eql(u8, sa, sb)) break :blk false;
                    }
                    for (da.type_args, db.type_args) |taa, tab| {
                        if (!typeIrEql(taa, tab, depth + 1)) break :blk false;
                    }
                    break :blk true;
                },
                .tuple => |ta| blk: {
                    const tb = b.tuple;
                    if (ta.len != tb.len) break :blk false;
                    for (ta, tb) |ea, eb| {
                        if (ea.is_optional != eb.is_optional or ea.is_variadic != eb.is_variadic or ea.nullish_kind != eb.nullish_kind) break :blk false;
                        if (!typeIrEql(ea.ty, eb.ty, depth + 1)) break :blk false;
                    }
                    break :blk true;
                },
                .anon_struct => |fa| blk: {
                    const fb = b.anon_struct;
                    if (fa.len != fb.len) break :blk false;
                    for (fa, fb) |xa, xb| {
                        if (!std.mem.eql(u8, xa.wire_name, xb.wire_name) or xa.is_optional != xb.is_optional) break :blk false;
                        if (!fieldConstraintEql(xa.literal_constraint, xb.literal_constraint)) break :blk false;
                        if (!typeIrEql(xa.ty, xb.ty, depth + 1)) break :blk false;
                    }
                    break :blk true;
                },
                .template_pattern => |pa| blk: {
                    const pb = b.template_pattern;
                    if (!std.mem.eql(u8, pa.head, pb.head) or pa.spans.len != pb.spans.len) break :blk false;
                    for (pa.spans, pb.spans) |sa, sb| {
                        if (sa.placeholder != sb.placeholder or
                            !std.mem.eql(u8, sa.literal_tail, sb.literal_tail) or
                            sa.choices.len != sb.choices.len) break :blk false;
                        for (sa.choices, sb.choices) |ca, cb| {
                            if (!std.mem.eql(u8, ca, cb)) break :blk false;
                        }
                    }
                    break :blk true;
                },
                else => false,
            };
        }

        const LoweredArmEntry = struct {
            ast_arm_id: u32,
            ty: *TypeIr,
        };

        const GeneralUnionOutcome = struct {
            extra_nullish: lower_types.NullishKind = .none,
            body: union(enum) {
                single: *TypeIr,
                tagged: TaggedUnionIr,
            },
        };

        fn trySelectDiscriminantForArms(
            self: *Self,
            arms: []const LoweredArmEntry,
        ) error{OutOfMemory}!?lower_unions.SelectedDiscriminant {
            if (arms.len < 2) return null;

            var arm_prop_lists = try self.scratch.alloc([]const lower_unions.CandidateDiscProp, arms.len);
            var prop_SubSlices: std.ArrayList([]lower_unions.CandidateDiscProp) = .empty;
            var val_SubSlices: std.ArrayList([]lower_unions.ClosedLiteralValue) = .empty;
            defer {
                for (val_SubSlices.items) |s| self.scratch.free(s);
                val_SubSlices.deinit(self.scratch);
                for (prop_SubSlices.items) |s| self.scratch.free(s);
                prop_SubSlices.deinit(self.scratch);
                self.scratch.free(arm_prop_lists);
            }

            for (arms, 0..) |entry, idx| {
                // Only consider plain/class object arms for object-property discriminant dispatch.
                switch (entry.ty.*) {
                    .anon_struct, .decl_ref => {},
                    else => return null,
                }
                var raw_props: std.ArrayList(RawObjectPropItem) = .empty;
                defer raw_props.deinit(self.scratch);
                if (!try self.collectObjectArmProps(entry.ast_arm_id, true, &raw_props, 0)) return null;
                if (raw_props.items.len == 0) return null;

                var infos: std.ArrayList(lower_unions.CandidateDiscProp) = .empty;
                for (raw_props.items) |rp| {
                    if (rp.optional) continue;
                    var enum_hint_opt: ?[]const u8 = null;
                    if (try self.resolveEnumMemberReference(rp.ty)) |em| {
                        enum_hint_opt = em.tag_logical_name;
                    }
                    var lits: std.ArrayList(lower_unions.ClosedLiteralValue) = .empty;
                    if (try self.tryCollectClosedLiteralsFromArm(rp.ty, &lits, true, 0) and lits.items.len > 0) {
                        const lit_slice = try lits.toOwnedSlice(self.scratch);
                        try val_SubSlices.append(self.scratch, lit_slice);
                        try infos.append(self.scratch, .{
                            .wire_name = rp.wire,
                            .values = lit_slice,
                            .enum_member_hint = enum_hint_opt,
                        });
                    } else {
                        lits.deinit(self.scratch);
                    }
                }
                if (infos.items.len == 0) {
                    infos.deinit(self.scratch);
                    return null;
                }
                const info_slice = try infos.toOwnedSlice(self.scratch);
                try prop_SubSlices.append(self.scratch, info_slice);
                arm_prop_lists[idx] = info_slice;
            }

            return try lower_unions.selectDiscriminantProperty(self.alloc, arm_prop_lists);
        }

        fn buildGeneralUnionOutcome(
            self: *Self,
            non_null_arms: []const u32,
            active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            visited: *std.AutoHashMapUnmanaged(u32, void),
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}!GeneralUnionOutcome {
            var has_open_str = false;
            var has_open_num = false;
            var has_open_bigint = false;
            var has_open_bool = false;

            for (non_null_arms) |aid| {
                const k = self.graph.types[aid].kind;
                switch (k) {
                    .string_type => has_open_str = true,
                    .number_type => has_open_num = true,
                    .bigint_type => has_open_bigint = true,
                    .boolean_type => has_open_bool = true,
                    .intersection => |parts| {
                        if (self.detectOpenPrimitiveIntersection(parts)) |opk| {
                            switch (opk) {
                                .str => has_open_str = true,
                                .num => has_open_num = true,
                                .bigint => has_open_bigint = true,
                            }
                        }
                    },
                    else => {},
                }
            }

            var raw_lits: std.ArrayList(lower_unions.ClosedLiteralValue) = .empty;
            defer raw_lits.deinit(self.scratch);
            var other_arm_ids: std.ArrayList(u32) = .empty;
            defer other_arm_ids.deinit(self.scratch);
            var first_bool_lit_arm: ?u32 = null;

            for (non_null_arms) |aid| {
                var arm_lits: std.ArrayList(lower_unions.ClosedLiteralValue) = .empty;
                defer arm_lits.deinit(self.scratch);
                if (try self.tryCollectClosedLiteralsFromArm(aid, &arm_lits, false, 0) and arm_lits.items.len > 0) {
                    for (arm_lits.items) |clv| {
                        if (clv == .boolean and first_bool_lit_arm == null) {
                            first_bool_lit_arm = aid;
                        }
                        try self.appendUniqueClosedLiteral(&raw_lits, clv);
                    }
                } else {
                    try other_arm_ids.append(self.scratch, aid);
                }
            }

            // Detect `true | false` pair among literal arms -> promote to open `boolean`!
            var saw_true = false;
            var saw_false = false;
            for (raw_lits.items) |clv| {
                if (clv == .boolean) {
                    if (clv.boolean) saw_true = true else saw_false = true;
                }
            }
            const promote_bool_pair = !has_open_bool and saw_true and saw_false;
            if (promote_bool_pair) has_open_bool = true;

            var rem_lits: std.ArrayList(lower_unions.ClosedLiteralValue) = .empty;
            defer rem_lits.deinit(self.scratch);
            for (raw_lits.items) |clv| {
                const absorbed = switch (clv) {
                    .str => has_open_str,
                    .num => has_open_num,
                    .boolean => has_open_bool,
                    .bigint_val => has_open_bigint,
                };
                if (!absorbed) try rem_lits.append(self.scratch, clv);
            }

            var deduped_others: std.ArrayList(LoweredArmEntry) = .empty;
            defer deduped_others.deinit(self.scratch);

            if (promote_bool_pair) {
                try deduped_others.append(self.scratch, .{
                    .ast_arm_id = first_bool_lit_arm orelse non_null_arms[0],
                    .ty = try self.makeType(.bool_type),
                });
            }

            var extra_nullish: lower_types.NullishKind = .none;
            for (other_arm_ids.items) |aid| {
                var arm_visited = try visited.clone(self.scratch);
                defer arm_visited.deinit(self.scratch);
                var payload = try self.lowerType(aid, false, active_tps, self_ident_opt, &arm_visited, imports_used, needs_runtime);
                if (payload.* == .noreturn_type) continue;
                if (payload.* == .void_type) {
                    extra_nullish = extra_nullish.merge(.undefined_only);
                    continue;
                }
                if (payload.* == .optional) {
                    const was_pure_nullish = payload.optional.is_pure_nullish;
                    extra_nullish = extra_nullish.merge(payload.optional.nullish_kind);
                    if (was_pure_nullish) continue;
                    payload = try self.makeType(payload.optional.child.*);
                    if (payload.* == .void_type or payload.* == .noreturn_type) continue;
                }
                switch (payload.*) {
                    .string_type => has_open_str = true,
                    .f64_type => has_open_num = true,
                    .i64_type => has_open_bigint = true,
                    .bool_type => has_open_bool = true,
                    else => {},
                }
                var is_dup = false;
                for (deduped_others.items) |existing| {
                    if (typeIrEql(existing.ty, payload, 0)) {
                        is_dup = true;
                        break;
                    }
                }
                if (!is_dup) {
                    try deduped_others.append(self.scratch, .{ .ast_arm_id = aid, .ty = payload });
                }
            }

            // Re-filter `rem_lits` in case a substituted type param or alias lowered to an open scalar!
            {
                var write_idx: usize = 0;
                for (rem_lits.items) |clv| {
                    const absorbed = switch (clv) {
                        .str => has_open_str,
                        .num => has_open_num,
                        .boolean => has_open_bool,
                        .bigint_val => has_open_bigint,
                    };
                    if (!absorbed) {
                        rem_lits.items[write_idx] = clv;
                        write_idx += 1;
                    }
                }
                rem_lits.items.len = write_idx;
            }

            if (rem_lits.items.len == 0 and deduped_others.items.len == 1) {
                return .{ .extra_nullish = extra_nullish, .body = .{ .single = deduped_others.items[0].ty } };
            }
            if (deduped_others.items.len == 0 and rem_lits.items.len > 0 and rem_lits.items.len <= 64) {
                const inline_en = try self.buildEnumMembersFromClosedLiterals(rem_lits.items);
                return .{ .extra_nullish = extra_nullish, .body = .{ .single = try self.makeType(.{ .inline_enum = inline_en }) } };
            }
            if (rem_lits.items.len == 0 and deduped_others.items.len == 0) {
                if (extra_nullish == .null_only or extra_nullish == .null_or_undefined) {
                    needs_runtime.* = true;
                    const pure_opt = try self.makeType(.{
                        .optional = .{
                            .child = try self.makeType(.js_any),
                            .nullish_kind = extra_nullish,
                            .is_pure_nullish = true,
                        },
                    });
                    return .{ .extra_nullish = extra_nullish, .body = .{ .single = pure_opt } };
                }
                return .{ .extra_nullish = .none, .body = .{ .single = try self.makeType(.void_type) } };
            }

            needs_runtime.* = true;

            var disc_sel_opt: ?lower_unions.SelectedDiscriminant = null;
            defer if (disc_sel_opt) |ds| ds.deinit(self.alloc);
            if (rem_lits.items.len == 0 and deduped_others.items.len >= 2) {
                disc_sel_opt = try self.trySelectDiscriminantForArms(deduped_others.items);
            }

            var var_scope = naming.ScopeNamer.init(self.scratch, null);
            defer var_scope.deinit();
            try var_scope.reserve("zigar_js");

            var variants: std.ArrayList(UnionVariantIr) = .empty;
            errdefer variants.deinit(self.alloc);

            if (rem_lits.items.len > 0 and rem_lits.items.len <= 16) {
                const void_ty = try self.makeType(.void_type);
                for (rem_lits.items) |clv| {
                    const hint = try lower_unions.formatLiteralTagHint(self.scratch, clv);
                    defer self.scratch.free(hint);
                    const bound = try var_scope.bind(hint, .snake);
                    const wire_str: []const u8 = switch (clv) {
                        .str => |s| try self.alloc.dupe(u8, s),
                        else => try self.alloc.dupe(u8, bound.logical_name),
                    };
                    try variants.append(self.alloc, .{
                        .zig_ident = try self.alloc.dupe(u8, bound.zig_ident),
                        .logical_name = try self.alloc.dupe(u8, bound.logical_name),
                        .wire_tag = wire_str,
                        .payload = void_ty,
                        .unit_literal = try self.closedLiteralToEnumValue(clv),
                    });
                    bound.deinit(self.scratch);
                }
            } else if (rem_lits.items.len > 16) {
                const inline_en = try self.buildEnumMembersFromClosedLiterals(rem_lits.items);
                const en_ty = try self.makeType(.{ .inline_enum = inline_en });
                const bound = try var_scope.bind("literal", .snake);
                try variants.append(self.alloc, .{
                    .zig_ident = try self.alloc.dupe(u8, bound.zig_ident),
                    .logical_name = try self.alloc.dupe(u8, bound.logical_name),
                    .wire_tag = try self.alloc.dupe(u8, bound.wire_name),
                    .payload = en_ty,
                });
                bound.deinit(self.scratch);
            }

            for (deduped_others.items, 0..) |entry, idx| {
                var disc_vals_ir: []VariantDiscriminantValueIr = &.{};
                var hint: []const u8 = "";
                var free_hint = false;

                if (disc_sel_opt) |ds| {
                    const arm_dvals = ds.arm_values[idx];
                    disc_vals_ir = try self.alloc.alloc(VariantDiscriminantValueIr, arm_dvals.len);
                    for (arm_dvals, 0..) |dv, di| {
                        disc_vals_ir[di] = switch (dv) {
                            .str => |s| .{ .str = try self.alloc.dupe(u8, s) },
                            .num => |n| .{ .num = n },
                            .boolean => |b| .{ .boolean = b },
                            .bigint_val => |bi| .{ .bigint_val = try lower_types.normalizeBigIntLiteral(self.alloc, bi) },
                        };
                    }
                    if (self.graph.types[entry.ast_arm_id].kind == .reference) {
                        const rname = self.str(self.graph.types[entry.ast_arm_id].kind.reference.target_name);
                        hint = lower_types.stripGlobalQualifier(rname);
                    } else {
                        hint = try lower_unions.formatDiscriminantVariantHint(
                            self.scratch,
                            ds.wire_name,
                            arm_dvals,
                            ds.arm_hints[idx],
                        );
                        free_hint = true;
                    }
                } else {
                    hint = self.deriveVariantTagHint(entry.ast_arm_id, entry.ty, idx);
                }
                defer if (free_hint) self.scratch.free(hint);

                const bound = try var_scope.bind(hint, .snake);
                try variants.append(self.alloc, .{
                    .zig_ident = try self.alloc.dupe(u8, bound.zig_ident),
                    .logical_name = try self.alloc.dupe(u8, bound.logical_name),
                    .wire_tag = try self.alloc.dupe(u8, bound.wire_name),
                    .payload = entry.ty,
                    .disc_values = disc_vals_ir,
                });
                bound.deinit(self.scratch);
            }

            const disc_prop_copy: ?[]const u8 = if (disc_sel_opt) |ds|
                try self.alloc.dupe(u8, ds.wire_name)
            else
                null;

            return .{
                .extra_nullish = extra_nullish,
                .body = .{
                    .tagged = .{
                        .discriminant_prop = disc_prop_copy,
                        .variants = try variants.toOwnedSlice(self.alloc),
                    },
                },
            };
        }

        fn lowerUnionTypeInline(
            self: *Self,
            ty_id: u32,
            arms: []const u32,
            ref_cnt: u32,
            can_hoist_in_mod: bool,
            no_free_vars: bool,
            active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            visited: *std.AutoHashMapUnmanaged(u32, void),
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}!*TypeIr {
            var non_null: std.ArrayList(u32) = .empty;
            defer non_null.deinit(self.scratch);
            var nullish: lower_types.NullishKind = .none;
            try self.collectFlattenedUnionArms(arms, &non_null, &nullish, 0);

            if (non_null.items.len == 0) {
                if (nullish != .none) {
                    needs_runtime.* = true;
                    const jv = try self.makeType(.js_any);
                    return self.makeType(.{ .optional = .{ .child = jv, .nullish_kind = nullish, .is_pure_nullish = true } });
                }
                return self.makeType(.void_type);
            }

            if (non_null.items.len == 1) {
                const base_ty = try self.lowerType(non_null.items[0], false, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                const final_u = if (nullish != .none) try self.wrapOptionalWithNullish(base_ty, nullish) else base_ty;
                if (ref_cnt > 1 and can_hoist_in_mod and isSafeToShareTypeIrPtr(final_u) and (no_free_vars or try self.isClosedTypeSubgraph(ty_id))) {
                    try self.cur_mod_closed_types.put(self.scratch, ty_id, final_u);
                }
                return final_u;
            }

            // 1. Open-literal autocomplete union (`"red" | "green" | (string & {})`)!
            if (try self.tryBuildOpenLiteralUnion(non_null.items)) |olu| {
                const base_ty: *TypeIr = if (can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id)) and ref_cnt > 1) blk: {
                    const h = try self.allocFreshAnonHelperName("__zigar_AnonUnion", active_tps);
                    const hloc = DeclLocation{
                        .module_index = self.cur_mod_idx,
                        .zig_path = h.path,
                        .type_param_defaults = &.{},
                    };
                    if (nullish == .none) try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);
                    try self.cur_mod_decls_out.?.append(self.alloc, .{
                        .source_decl_id = null,
                        .zig_ident = h.zig_ident,
                        .logical_name = h.logical,
                        .wire_name = h.logical,
                        .is_exported = false,
                        .is_js_exported = false,
                        .is_default_export = false,
                        .jsdoc = null,
                        .kind = .{ .open_literal_decl = olu },
                    });
                    break :blk try self.makeHoistedDeclRef(hloc);
                } else if (self.inline_anon_depth >= 3)
                    switch (olu.base_kind) {
                        .str => try self.makeType(.string_type),
                        .num => try self.makeType(.f64_type),
                        .bigint => try self.makeType(.i64_type),
                    }
                else
                    try self.makeType(.{ .open_literal_union = olu });

                return if (nullish != .none) try self.wrapOptionalWithNullish(base_ty, nullish) else base_ty;
            }

            // 2. Closed scalar literal union (`"a" | "b"`, `200 | 404`, `"auto" | 0 | false | 10n`)!
            if (try self.tryBuildClosedLiteralEnum(non_null.items)) |enum_ir| {
                const base_ty: *TypeIr = if (can_hoist_in_mod and (no_free_vars or try self.isClosedTypeSubgraph(ty_id)) and (ref_cnt > 1 or enum_ir.members.len > 8)) blk: {
                    const h = try self.allocFreshAnonHelperName("__zigar_AnonEnum", active_tps);
                    const hloc = DeclLocation{
                        .module_index = self.cur_mod_idx,
                        .zig_path = h.path,
                        .type_param_defaults = &.{},
                    };
                    if (nullish == .none) try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);
                    try self.cur_mod_decls_out.?.append(self.alloc, .{
                        .source_decl_id = null,
                        .zig_ident = h.zig_ident,
                        .logical_name = h.logical,
                        .wire_name = h.logical,
                        .is_exported = false,
                        .is_js_exported = false,
                        .is_default_export = false,
                        .jsdoc = null,
                        .kind = .{ .literal_enum_decl = enum_ir },
                    });
                    break :blk try self.makeHoistedDeclRef(hloc);
                } else if (self.inline_anon_depth >= 3 or enum_ir.members.len > 64) blk: {
                    if (self.allArmsSameScalarKind(non_null.items)) |scalar_ty| {
                        break :blk try self.makeType(scalar_ty);
                    }
                    needs_runtime.* = true;
                    break :blk try self.makeType(.js_any);
                } else try self.makeType(.{ .inline_enum = enum_ir });

                return if (nullish != .none) try self.wrapOptionalWithNullish(base_ty, nullish) else base_ty;
            }

            // 3. Exact `true | false` or absorbed homogeneous scalar union (`string | "foo"`, `number | 0`).
            if (self.allArmsSameScalarKind(non_null.items)) |scalar_ty| {
                const base_ty = try self.makeType(scalar_ty);
                const final_u = if (nullish != .none) try self.wrapOptionalWithNullish(base_ty, nullish) else base_ty;
                if (ref_cnt > 1 and can_hoist_in_mod and isSafeToShareTypeIrPtr(final_u) and (no_free_vars or try self.isClosedTypeSubgraph(ty_id))) {
                    try self.cur_mod_closed_types.put(self.scratch, ty_id, final_u);
                }
                return final_u;
            }

            // 4. Discriminated or heterogeneous multi-arm union (`A | B`, `Buffer | string`, etc.)!
            if (non_null.items.len > 32) {
                needs_runtime.* = true;
                const jv = try self.makeType(.js_any);
                return if (nullish != .none) try self.wrapOptionalWithNullish(jv, nullish) else jv;
            }

            const can_hoist_union = can_hoist_in_mod and ref_cnt > 1 and (no_free_vars or try self.isClosedTypeSubgraph(ty_id));
            if (can_hoist_union and nullish == .none) {
                const h = try self.allocFreshAnonHelperName("__zigar_AnonUnion", active_tps);
                const hloc = DeclLocation{
                    .module_index = self.cur_mod_idx,
                    .zig_path = h.path,
                    .type_param_defaults = &.{},
                };
                try self.cur_mod_hoisted_locs.put(self.scratch, ty_id, hloc);

                var fresh_visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer fresh_visited.deinit(self.scratch);
                const saved_depth = self.inline_anon_depth;
                self.inline_anon_depth = 0;
                defer self.inline_anon_depth = saved_depth;

                const outcome = try self.buildGeneralUnionOutcome(non_null.items, &.{}, null, &fresh_visited, imports_used, needs_runtime);
                switch (outcome.body) {
                    .single => |single_ty| {
                        const eff_single = if (outcome.extra_nullish != .none)
                            try self.wrapOptionalWithNullish(single_ty, outcome.extra_nullish)
                        else
                            single_ty;
                        try self.cur_mod_decls_out.?.append(self.alloc, .{
                            .source_decl_id = null,
                            .zig_ident = h.zig_ident,
                            .logical_name = h.logical,
                            .wire_name = h.logical,
                            .is_exported = false,
                            .is_js_exported = false,
                            .is_default_export = false,
                            .jsdoc = null,
                            .kind = .{ .type_alias = .{ .type_params = &.{}, .target = eff_single } },
                        });
                        return self.makeHoistedDeclRef(hloc);
                    },
                    .tagged => |tu| {
                        try self.cur_mod_decls_out.?.append(self.alloc, .{
                            .source_decl_id = null,
                            .zig_ident = h.zig_ident,
                            .logical_name = h.logical,
                            .wire_name = h.logical,
                            .is_exported = false,
                            .is_js_exported = false,
                            .is_default_export = false,
                            .jsdoc = null,
                            .kind = .{
                                .union_decl = .{
                                    .type_params = &.{},
                                    .discriminant_prop = tu.discriminant_prop,
                                    .variants = tu.variants,
                                },
                            },
                        });
                        const href = try self.makeHoistedDeclRef(hloc);
                        if (outcome.extra_nullish != .none) {
                            _ = self.cur_mod_hoisted_locs.remove(ty_id);
                            return self.wrapOptionalWithNullish(href, outcome.extra_nullish);
                        }
                        return href;
                    },
                }
            }

            if (!can_hoist_union and self.inline_anon_depth >= 3) {
                needs_runtime.* = true;
                const jv = try self.makeType(.js_any);
                return if (nullish != .none) try self.wrapOptionalWithNullish(jv, nullish) else jv;
            }

            self.inline_anon_depth += 1;
            defer self.inline_anon_depth -= 1;

            const outcome = try self.buildGeneralUnionOutcome(non_null.items, active_tps, self_ident_opt, visited, imports_used, needs_runtime);
            const eff_nullish = nullish.merge(outcome.extra_nullish);
            const base_ty: *TypeIr = switch (outcome.body) {
                .single => |single_ty| single_ty,
                .tagged => |tu| blk: {
                    if (can_hoist_union) {
                        const h = try self.allocFreshAnonHelperName("__zigar_AnonUnion", active_tps);
                        const hloc = DeclLocation{
                            .module_index = self.cur_mod_idx,
                            .zig_path = h.path,
                            .type_param_defaults = &.{},
                        };
                        try self.cur_mod_decls_out.?.append(self.alloc, .{
                            .source_decl_id = null,
                            .zig_ident = h.zig_ident,
                            .logical_name = h.logical,
                            .wire_name = h.logical,
                            .is_exported = false,
                            .is_js_exported = false,
                            .is_default_export = false,
                            .jsdoc = null,
                            .kind = .{
                                .union_decl = .{
                                    .type_params = &.{},
                                    .discriminant_prop = tu.discriminant_prop,
                                    .variants = tu.variants,
                                },
                            },
                        });
                        break :blk try self.makeHoistedDeclRef(hloc);
                    }
                    break :blk try self.makeType(.{ .tagged_union = tu });
                },
            };
            return if (eff_nullish != .none) try self.wrapOptionalWithNullish(base_ty, eff_nullish) else base_ty;
        }

        fn tryLowerUnionDeclVariants(
            self: *Self,
            ty_id: u32,
            active_tps: []const ActiveTypeParam,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}!?TaggedUnionIr {
            if (ty_id >= self.graph.types.len) return null;
            const tn = self.graph.types[ty_id];
            const union_arms: []const u32 = if (tn.kind == .union_type)
                tn.kind.union_type
            else if (tn.kind == .template_literal and tn.resolved_type != null and tn.resolved_type.? < self.graph.types.len and self.graph.types[tn.resolved_type.?].kind == .union_type)
                self.graph.types[tn.resolved_type.?].kind.union_type
            else
                return null;

            // Keep nullable unions (`T | null`, `A | B | undefined`) as `?Target` type aliases so `.nullish` metadata is preserved!
            var non_null: std.ArrayList(u32) = .empty;
            defer non_null.deinit(self.scratch);
            var nullish: lower_types.NullishKind = .none;
            try self.collectFlattenedUnionArms(union_arms, &non_null, &nullish, 0);
            if (nullish != .none or non_null.items.len < 2 or non_null.items.len > 64) return null;

            // Let homogeneous scalar unions like `string | "foo"` or `true | false` collapse cleanly to `[]const u8` / `bool`!
            if (self.allArmsSameScalarKind(non_null.items) != null) return null;

            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(self.scratch);
            const outcome = try self.buildGeneralUnionOutcome(non_null.items, active_tps, null, &visited, imports_used, needs_runtime);
            if (outcome.extra_nullish != .none) return null;
            return switch (outcome.body) {
                .single => null,
                .tagged => |tu| tu,
            };
        }

        fn deriveVariantTagHint(self: *Self, arm_ty_id: u32, lowered_payload: *const TypeIr, idx: usize) []const u8 {
            const ak = self.graph.types[arm_ty_id].kind;
            switch (ak) {
                .string_type => return "str",
                .number_type => return "num",
                .boolean_type => return "boolean",
                .bigint_type => return "bigint",
                .symbol_type, .unique_symbol => return "symbol",
                .object_type => return "object",
                .array, .readonly_array => return "array",
                .tuple, .readonly_tuple => return "tuple",
                .function_type => return "func",
                .template_literal => return "pattern",
                .reference => |ref| return lower_types.stripGlobalQualifier(self.str(ref.target_name)),
                .intersection => |parts| {
                    if (self.detectOpenPrimitiveIntersection(parts)) |opk| {
                        return switch (opk) {
                            .str => "str",
                            .num => "num",
                            .bigint => "bigint",
                        };
                    }
                },
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
            switch (lowered_payload.*) {
                .bool_type => return "boolean",
                .string_type => return "str",
                .f64_type => return "num",
                .i64_type => return "bigint",
                .binary_view => |bvk| return bvk.zigTypeIdent(),
                .slice => return "array",
                .tuple => return "tuple",
                .fn_ptr => return "func",
                .anon_struct => return "record",
                .js_object => return "object",
                .js_function => return "func",
                .js_map => return "map",
                .promise => return "promise",
                else => {},
            }
            return std.fmt.allocPrint(self.alloc, "variant_{d}", .{idx}) catch "variant";
        }

        fn lowerDeclIntoList(
            self: *Self,
            final_mod_idx: u32,
            decl_id: u32,
            is_top_level: bool,
            scope: *naming.ScopeNamer,
            prebound_names: *const std.AutoHashMapUnmanaged(u32, naming.BoundName),
            prebound_overloads: *const std.AutoHashMapUnmanaged(u32, []naming.BoundName),
            outer_active_tps: []const ActiveTypeParam,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
            out_list: *std.ArrayList(DeclIr),
        ) error{OutOfMemory}!void {
            var active_decls: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer active_decls.deinit(self.scratch);
            try self.lowerDeclIntoListInner(
                final_mod_idx,
                decl_id,
                is_top_level,
                scope,
                prebound_names,
                prebound_overloads,
                outer_active_tps,
                imports_used,
                needs_runtime,
                out_list,
                &active_decls,
            );
        }

        fn lowerDeclIntoListInner(
            self: *Self,
            final_mod_idx: u32,
            decl_id: u32,
            is_top_level: bool,
            scope: *naming.ScopeNamer,
            prebound_names: *const std.AutoHashMapUnmanaged(u32, naming.BoundName),
            prebound_overloads: *const std.AutoHashMapUnmanaged(u32, []naming.BoundName),
            outer_active_tps: []const ActiveTypeParam,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
            out_list: *std.ArrayList(DeclIr),
            active_decls: *std.AutoHashMapUnmanaged(u32, void),
        ) error{OutOfMemory}!void {
            if (decl_id >= self.graph.decls.len) return;
            if (self.merged_ns_consumed.contains(decl_id)) return;
            if (self.merged_iface_consumed.contains(decl_id)) return;
            if (self.merged_ctor_var_consumed.contains(decl_id)) return;
            if (active_decls.contains(decl_id)) return;
            try active_decls.put(self.scratch, decl_id, {});
            defer _ = active_decls.remove(decl_id);

            const d = self.graph.decls[decl_id];
            const bound = prebound_names.get(decl_id) orelse return;
            const top_jsdoc = try self.lowerJsDoc(d.jsdoc);
            const is_exported = !d.modifiers.private_mod and !d.modifiers.protected_mod;
            const suppress_js_export = self.merged_generic_ns_set.contains(decl_id) or
                self.pure_export_equals_ns.contains(decl_id);

            var companion_exported = false;
            var companion_default = false;
            var companion_global = false;
            if (d.kind == .interface_decl) {
                for (d.merged_with) |mid| {
                    if (self.merged_ctor_var_consumed.contains(mid) and mid < self.graph.decls.len) {
                        const vd = self.graph.decls[mid];
                        if (vd.modifiers.export_decl) companion_exported = true;
                        if (vd.modifiers.default_export) companion_default = true;
                        if (self.global_aug_decls.contains(mid)) companion_global = true;
                    }
                }
            }

            const is_js_exported = if (suppress_js_export)
                false
            else if (is_top_level)
                (is_exported and self.js_exported_decls.contains(decl_id))
            else
                (is_exported and (d.modifiers.export_decl or companion_exported));
            const is_default_export = d.modifiers.default_export or companion_default;
            const is_global_scope = self.global_aug_decls.contains(decl_id) or companion_global;

            switch (d.kind) {
                .function_decl => |sigs| {
                    needs_runtime.* = true;
                    if (sigs.len == 0) {
                        const empty_sig = SignatureIr{
                            .self_param_ident = null,
                            .alloc_param_ident = "allocator",
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
                            .is_js_exported = is_js_exported,
                            .is_default_export = is_default_export,
                            .is_global_scope = is_global_scope,
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
                        var alloc_comp: ?[]const u8 = null;
                        if (try self.typeMayAllocateOnDecode(sig_ir.return_type)) {
                            const raw_alloc_name = try std.fmt.allocPrint(self.scratch, "{s}Alloc", .{logical});
                            defer self.scratch.free(raw_alloc_name);
                            const ab = try scope.bind(raw_alloc_name, .camel);
                            alloc_comp = try self.alloc.dupe(u8, ab.zig_ident);
                            ab.deinit(self.scratch);
                        }
                        try out_list.append(self.alloc, .{
                            .source_decl_id = decl_id,
                            .zig_ident = ident,
                            .logical_name = logical,
                            .wire_name = bound.wire_name,
                            .is_exported = is_exported,
                            .is_js_exported = is_js_exported,
                            .is_default_export = is_default_export and s_idx == 0,
                            .is_global_scope = is_global_scope,
                            .alloc_companion_ident = alloc_comp,
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
                            .is_js_exported = is_js_exported,
                            .is_default_export = is_default_export,
                            .is_global_scope = is_global_scope,
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
                            .is_js_exported = is_js_exported,
                            .is_default_export = is_default_export,
                            .is_global_scope = is_global_scope,
                            .jsdoc = top_jsdoc,
                            .kind = .{ .global_var = lowered_ty },
                        });
                    }
                },
                .interface_decl => |iface| {
                    const icls = try self.classifyDecl(decl_id);

                    var combined_props: std.ArrayList(SourcedProp) = .empty;
                    defer combined_props.deinit(self.scratch);

                    var combined_methods: std.ArrayList(SourcedMethod) = .empty;
                    defer combined_methods.deinit(self.scratch);
                    for (iface.methods) |m| try combined_methods.append(self.scratch, .{ .method = m });

                    var combined_call_sigs: std.ArrayList(SourcedSig) = .empty;
                    defer combined_call_sigs.deinit(self.scratch);
                    for (iface.call_signatures) |sid| try appendUniqueSourcedSig(&combined_call_sigs, self.scratch, .{ .sid = sid });

                    var combined_construct_sigs: std.ArrayList(SourcedSig) = .empty;
                    defer combined_construct_sigs.deinit(self.scratch);
                    for (iface.construct_signatures) |sid| try appendUniqueSourcedSig(&combined_construct_sigs, self.scratch, .{ .sid = sid });

                    var seen_methods: std.StringHashMapUnmanaged(void) = .empty;
                    defer seen_methods.deinit(self.scratch);
                    var derived_methods: std.StringHashMapUnmanaged(void) = .empty;
                    defer derived_methods.deinit(self.scratch);

                    for (iface.methods) |m| {
                        if (m.modifiers.static_mod or m.modifiers.private_mod or m.modifiers.protected_mod or m.computed_symbol != null) continue;
                        const mw = self.str(m.name);
                        try seen_methods.put(self.scratch, mw, {});
                        try derived_methods.put(self.scratch, mw, {});
                    }
                    for (iface.properties) |pid| {
                        if (pid >= self.graph.properties.len) continue;
                        const p = self.graph.properties[pid];
                        if (p.modifiers.static_mod or p.modifiers.private_mod or p.modifiers.protected_mod or p.computed_symbol != null) continue;
                        try seen_methods.put(self.scratch, self.str(p.name), {});
                    }
                    for (d.merged_with) |mid| {
                        if (mid == decl_id or mid >= self.graph.decls.len) continue;
                        const md = self.graph.decls[mid];
                        if (md.kind != .interface_decl) continue;
                        const miface = md.kind.interface_decl;
                        for (miface.methods) |m| {
                            try self.appendMethodIfMissing(&combined_methods, .{ .method = m });
                            if (m.modifiers.static_mod or m.modifiers.private_mod or m.modifiers.protected_mod or m.computed_symbol != null) continue;
                            const mw = self.str(m.name);
                            try seen_methods.put(self.scratch, mw, {});
                            try derived_methods.put(self.scratch, mw, {});
                        }
                        for (miface.properties) |pid| {
                            if (pid >= self.graph.properties.len) continue;
                            const p = self.graph.properties[pid];
                            if (p.modifiers.static_mod or p.modifiers.private_mod or p.modifiers.protected_mod or p.computed_symbol != null) continue;
                            try seen_methods.put(self.scratch, self.str(p.name), {});
                        }
                        for (miface.call_signatures) |sid| try appendUniqueSourcedSig(&combined_call_sigs, self.scratch, .{ .sid = sid });
                        for (miface.construct_signatures) |sid| try appendUniqueSourcedSig(&combined_construct_sigs, self.scratch, .{ .sid = sid });
                    }

                    var visited_bases: std.AutoHashMapUnmanaged(u32, void) = .empty;
                    defer visited_bases.deinit(self.scratch);
                    try visited_bases.put(self.scratch, decl_id, {});
                    for (d.merged_with) |mid| {
                        if (mid == decl_id or mid >= self.graph.decls.len) continue;
                        if (self.graph.decls[mid].kind == .interface_decl) {
                            try visited_bases.put(self.scratch, mid, {});
                        }
                    }

                    try self.collectInheritedHeritageClauses(
                        null,
                        iface.extends_clauses,
                        &combined_props,
                        &combined_methods,
                        &combined_call_sigs,
                        &combined_construct_sigs,
                        &seen_methods,
                        &derived_methods,
                        &visited_bases,
                    );
                    for (d.merged_with) |mid| {
                        if (mid == decl_id or mid >= self.graph.decls.len) continue;
                        const md = self.graph.decls[mid];
                        if (md.kind != .interface_decl) continue;
                        try self.collectInheritedHeritageClauses(
                            null,
                            md.kind.interface_decl.extends_clauses,
                            &combined_props,
                            &combined_methods,
                            &combined_call_sigs,
                            &combined_construct_sigs,
                            &seen_methods,
                            &derived_methods,
                            &visited_bases,
                        );
                    }
                    for (iface.properties) |pid| {
                        try self.upsertPropByWireName(&combined_props, .{ .pid = pid });
                    }
                    for (d.merged_with) |mid| {
                        if (mid == decl_id or mid >= self.graph.decls.len) continue;
                        const md = self.graph.decls[mid];
                        if (md.kind != .interface_decl) continue;
                        const miface = md.kind.interface_decl;
                        for (miface.properties) |pid| try self.upsertPropByWireName(&combined_props, .{ .pid = pid });
                    }

                    // Fold companion constructable `var` (`interface URL` + `declare var URL: URLConstructor`) when non-generic!
                    var companion_ctors: std.ArrayList(u32) = .empty;
                    defer companion_ctors.deinit(self.scratch);
                    var companion_static_props: std.ArrayList(u32) = .empty;
                    defer companion_static_props.deinit(self.scratch);
                    if (icls.companion_var_decl_id) |var_did| {
                        if (self.merged_ctor_var_consumed.contains(var_did)) {
                            var companion_static_methods: std.ArrayList(MethodNodeType) = .empty;
                            defer companion_static_methods.deinit(self.scratch);
                            var tmp_cls = classify_decls.Classifier(GraphType).init(self.scratch, &self.graph);
                            defer tmp_cls.deinit();
                            try tmp_cls.collectCompanionVarCtorMembers(
                                var_did,
                                &companion_ctors,
                                &companion_static_props,
                                &companion_static_methods,
                                self.scratch,
                            );
                            for (companion_static_methods.items) |cm| {
                                try combined_methods.append(self.scratch, .{ .method = cm });
                            }
                        }
                    }

                    const struct_ir = try self.lowerStructDecl(
                        final_mod_idx,
                        decl_id,
                        icls,
                        false,
                        false,
                        d.type_params,
                        companion_ctors.items,
                        combined_props.items,
                        companion_static_props.items,
                        combined_methods.items,
                        combined_call_sigs.items,
                        combined_construct_sigs.items,
                        d.merged_with,
                        scope,
                        prebound_names,
                        prebound_overloads,
                        outer_active_tps,
                        imports_used,
                        needs_runtime,
                        active_decls,
                    );
                    try out_list.append(self.alloc, .{
                        .source_decl_id = decl_id,
                        .zig_ident = bound.zig_ident,
                        .logical_name = bound.logical_name,
                        .wire_name = bound.wire_name,
                        .is_exported = is_exported,
                        .is_js_exported = is_js_exported,
                        .is_default_export = is_default_export,
                        .is_global_scope = is_global_scope,
                        .jsdoc = top_jsdoc,
                        .kind = .{ .struct_decl = struct_ir },
                    });
                },
                .class_decl => |cls| {
                    const ccls = try self.classifyDecl(decl_id);
                    var combined_props: std.ArrayList(SourcedProp) = .empty;
                    defer combined_props.deinit(self.scratch);

                    var combined_methods: std.ArrayList(SourcedMethod) = .empty;
                    defer combined_methods.deinit(self.scratch);
                    for (cls.methods) |m| try combined_methods.append(self.scratch, .{ .method = m });

                    var combined_call_sigs: std.ArrayList(SourcedSig) = .empty;
                    defer combined_call_sigs.deinit(self.scratch);
                    var ignored_construct_sigs: std.ArrayList(SourcedSig) = .empty;
                    defer ignored_construct_sigs.deinit(self.scratch);

                    var seen_methods: std.StringHashMapUnmanaged(void) = .empty;
                    defer seen_methods.deinit(self.scratch);
                    var derived_methods: std.StringHashMapUnmanaged(void) = .empty;
                    defer derived_methods.deinit(self.scratch);

                    for (cls.methods) |m| {
                        if (m.modifiers.static_mod or m.modifiers.private_mod or m.modifiers.protected_mod or m.computed_symbol != null) continue;
                        const mw = self.str(m.name);
                        try seen_methods.put(self.scratch, mw, {});
                        try derived_methods.put(self.scratch, mw, {});
                    }
                    for (cls.properties) |pid| {
                        if (pid >= self.graph.properties.len) continue;
                        const p = self.graph.properties[pid];
                        if (p.modifiers.static_mod or p.modifiers.private_mod or p.modifiers.protected_mod or p.computed_symbol != null) continue;
                        try seen_methods.put(self.scratch, self.str(p.name), {});
                    }

                    // Fold consumed merged `interface_decl` members FIRST before walking `extends`.
                    for (d.merged_with) |mid| {
                        if (!self.merged_iface_consumed.contains(mid) or mid >= self.graph.decls.len) continue;
                        const mdecl = self.graph.decls[mid];
                        if (mdecl.kind != .interface_decl) continue;
                        const miface = mdecl.kind.interface_decl;
                        for (miface.methods) |m| {
                            try combined_methods.append(self.scratch, .{ .method = m });
                            if (m.modifiers.static_mod or m.modifiers.private_mod or m.modifiers.protected_mod or m.computed_symbol != null) continue;
                            const mw = self.str(m.name);
                            try seen_methods.put(self.scratch, mw, {});
                            try derived_methods.put(self.scratch, mw, {});
                        }
                        for (miface.properties) |pid| {
                            if (pid >= self.graph.properties.len) continue;
                            const p = self.graph.properties[pid];
                            if (p.modifiers.static_mod or p.modifiers.private_mod or p.modifiers.protected_mod or p.computed_symbol != null) continue;
                            try seen_methods.put(self.scratch, self.str(p.name), {});
                        }
                        for (miface.call_signatures) |sid| try appendUniqueSourcedSig(&combined_call_sigs, self.scratch, .{ .sid = sid });
                    }

                    var visited_bases: std.AutoHashMapUnmanaged(u32, void) = .empty;
                    defer visited_bases.deinit(self.scratch);
                    try visited_bases.put(self.scratch, decl_id, {});
                    for (d.merged_with) |mid| {
                        if (mid < self.graph.decls.len and self.graph.decls[mid].kind == .interface_decl) {
                            try visited_bases.put(self.scratch, mid, {});
                        }
                    }

                    if (cls.extends_clause) |hc| {
                        try self.collectInheritedHeritageClause(
                            null,
                            hc,
                            &combined_props,
                            &combined_methods,
                            &combined_call_sigs,
                            &ignored_construct_sigs,
                            &seen_methods,
                            &derived_methods,
                            &visited_bases,
                        );
                    }
                    for (d.merged_with) |mid| {
                        if (!self.merged_iface_consumed.contains(mid) or mid >= self.graph.decls.len) continue;
                        const mdecl = self.graph.decls[mid];
                        if (mdecl.kind != .interface_decl) continue;
                        try self.collectInheritedHeritageClauses(
                            null,
                            mdecl.kind.interface_decl.extends_clauses,
                            &combined_props,
                            &combined_methods,
                            &combined_call_sigs,
                            &ignored_construct_sigs,
                            &seen_methods,
                            &derived_methods,
                            &visited_bases,
                        );
                    }

                    // Apply merged interface properties, then own `cls.properties` so derived overrides base!
                    for (d.merged_with) |mid| {
                        if (!self.merged_iface_consumed.contains(mid) or mid >= self.graph.decls.len) continue;
                        const mdecl = self.graph.decls[mid];
                        if (mdecl.kind != .interface_decl) continue;
                        for (mdecl.kind.interface_decl.properties) |pid| {
                            try self.upsertPropByWireName(&combined_props, .{ .pid = pid });
                        }
                    }
                    for (cls.properties) |pid| try self.upsertPropByWireName(&combined_props, .{ .pid = pid });

                    const struct_ir = try self.lowerStructDecl(
                        final_mod_idx,
                        decl_id,
                        ccls,
                        d.modifiers.abstract_mod,
                        cls.extends_clause != null,
                        d.type_params,
                        cls.constructors,
                        combined_props.items,
                        &.{},
                        combined_methods.items,
                        combined_call_sigs.items,
                        &.{},
                        d.merged_with,
                        scope,
                        prebound_names,
                        prebound_overloads,
                        outer_active_tps,
                        imports_used,
                        needs_runtime,
                        active_decls,
                    );
                    try out_list.append(self.alloc, .{
                        .source_decl_id = decl_id,
                        .zig_ident = bound.zig_ident,
                        .logical_name = bound.logical_name,
                        .wire_name = bound.wire_name,
                        .is_exported = is_exported,
                        .is_js_exported = is_js_exported,
                        .is_default_export = is_default_export,
                        .is_global_scope = is_global_scope,
                        .jsdoc = top_jsdoc,
                        .kind = .{ .struct_decl = struct_ir },
                    });
                },
                .enum_decl => |en| {
                    var member_scope = naming.ScopeNamer.initContainer(self.scratch, null);
                    defer member_scope.deinit();
                    try member_scope.reserve("zigar_js");
                    try member_scope.reserve("__zigar_value");

                    var has_unknown = (en.members.len == 0);
                    var members = try self.alloc.alloc(EnumMemberIr, en.members.len);
                    for (en.members, 0..) |m, idx| {
                        const m_wire = self.str(m.name);
                        const mb = try member_scope.bind(m_wire, .snake);
                        const val_ir: EnumValueIr = if (m.value) |mv| switch (mv) {
                            .num => |n| blk: {
                                if (!std.math.isFinite(n)) {
                                    has_unknown = true;
                                    break :blk .unknown;
                                }
                                break :blk .{ .num = n };
                            },
                            .str => |sid| .{ .str = try self.alloc.dupe(u8, self.str(sid)) },
                            .boolean => |b| .{ .boolean = b },
                            .bigint_literal => |sid| .{ .bigint_val = try lower_types.normalizeBigIntLiteral(self.alloc, self.str(sid)) },
                        } else blk: {
                            has_unknown = true;
                            break :blk .unknown;
                        };
                        members[idx] = .{
                            .zig_ident = try self.alloc.dupe(u8, mb.zig_ident),
                            .logical_name = try self.alloc.dupe(u8, mb.logical_name),
                            .wire_name = try self.alloc.dupe(u8, mb.wire_name),
                            .value = val_ir,
                            .jsdoc = try self.lowerJsDoc(m.jsdoc),
                        };
                        mb.deinit(self.scratch);
                    }

                    var backing: lower_unions.EnumBackingKind = .none;
                    if (!has_unknown) {
                        var closed_vals = try self.scratch.alloc(lower_unions.ClosedLiteralValue, members.len);
                        defer self.scratch.free(closed_vals);
                        for (members, 0..) |m, idx| {
                            closed_vals[idx] = switch (m.value) {
                                .num => |n| .{ .num = n },
                                .str => |s| .{ .str = s },
                                .boolean => |b| .{ .boolean = b },
                                .bigint_val => |bi| .{ .bigint_val = bi },
                                .unknown => unreachable,
                            };
                        }
                        const analysis = try lower_unions.analyzeClosedEnumValues(self.scratch, closed_vals);
                        defer analysis.deinit(self.scratch);
                        backing = analysis.backing;
                        for (members, 0..) |*m, idx| {
                            m.int_backing_val = analysis.layouts[idx].int_tag_value;
                            if (analysis.layouts[idx].alias_of_index) |pidx| {
                                m.alias_of_zig_ident = members[pidx].zig_ident;
                                m.alias_of_logical_name = members[pidx].logical_name;
                            }
                        }
                    } else {
                        needs_runtime.* = true;
                    }

                    try out_list.append(self.alloc, .{
                        .source_decl_id = decl_id,
                        .zig_ident = bound.zig_ident,
                        .logical_name = bound.logical_name,
                        .wire_name = bound.wire_name,
                        .is_exported = is_exported,
                        .is_js_exported = is_js_exported,
                        .is_default_export = is_default_export,
                        .is_global_scope = is_global_scope,
                        .jsdoc = top_jsdoc,
                        .kind = .{
                            .enum_decl = .{
                                .is_const = en.is_const,
                                .has_unknown_values = has_unknown,
                                .backing = backing,
                                .members = members,
                            },
                        },
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

                    if (d.type_params.len == 0 and ty_id < self.graph.types.len) {
                        const tn_alias = self.graph.types[ty_id];
                        switch (tn_alias.kind) {
                            .union_type => |u_arms| {
                                var non_null: std.ArrayList(u32) = .empty;
                                defer non_null.deinit(self.scratch);
                                var nullish: lower_types.NullishKind = .none;
                                try self.collectFlattenedUnionArms(u_arms, &non_null, &nullish, 0);

                                if (nullish == .none and non_null.items.len > 0) {
                                    // 1a. Open-literal autocomplete union (`"red" | "green" | (string & {})`)!
                                    if (try self.tryBuildOpenLiteralUnion(non_null.items)) |olu| {
                                        try out_list.append(self.alloc, .{
                                            .source_decl_id = decl_id,
                                            .zig_ident = bound.zig_ident,
                                            .logical_name = bound.logical_name,
                                            .wire_name = bound.wire_name,
                                            .is_exported = is_exported,
                                            .is_js_exported = is_js_exported,
                                            .is_default_export = is_default_export,
                                            .is_global_scope = is_global_scope,
                                            .jsdoc = top_jsdoc,
                                            .kind = .{ .open_literal_decl = olu },
                                        });
                                        return;
                                    }

                                    // 1b. Closed literal / finite-template union -> first-class Zig `enum`!
                                    if (try self.tryBuildClosedLiteralEnum(non_null.items)) |enum_ir| {
                                        try out_list.append(self.alloc, .{
                                            .source_decl_id = decl_id,
                                            .zig_ident = bound.zig_ident,
                                            .logical_name = bound.logical_name,
                                            .wire_name = bound.wire_name,
                                            .is_exported = is_exported,
                                            .is_js_exported = is_js_exported,
                                            .is_default_export = is_default_export,
                                            .is_global_scope = is_global_scope,
                                            .jsdoc = top_jsdoc,
                                            .kind = .{ .literal_enum_decl = enum_ir },
                                        });
                                        return;
                                    }
                                }
                            },
                            .template_literal => |tl| {
                                if (tl.spans.len > 0) {
                                    var finite_strs: std.ArrayList([]const u8) = .empty;
                                    defer finite_strs.deinit(self.alloc);
                                    if (try self.tryExpandFiniteStringSet(ty_id, &finite_strs, 0)) {
                                        if (finite_strs.items.len >= 2) {
                                            const enum_ir = try self.buildStringEnumFromUniqueStrings(finite_strs.items);
                                            if (enum_ir.members.len >= 2) {
                                                try out_list.append(self.alloc, .{
                                                    .source_decl_id = decl_id,
                                                    .zig_ident = bound.zig_ident,
                                                    .logical_name = bound.logical_name,
                                                    .wire_name = bound.wire_name,
                                                    .is_exported = is_exported,
                                                    .is_js_exported = is_js_exported,
                                                    .is_default_export = is_default_export,
                                                    .is_global_scope = is_global_scope,
                                                    .jsdoc = top_jsdoc,
                                                    .kind = .{ .literal_enum_decl = enum_ir },
                                                });
                                                return;
                                            }
                                        }
                                    } else if (try self.tryBuildDirectTemplatePattern(tl)) |pat_ir| {
                                        needs_runtime.* = true;
                                        try out_list.append(self.alloc, .{
                                            .source_decl_id = decl_id,
                                            .zig_ident = bound.zig_ident,
                                            .logical_name = bound.logical_name,
                                            .wire_name = bound.wire_name,
                                            .is_exported = is_exported,
                                            .is_js_exported = is_js_exported,
                                            .is_default_export = is_default_export,
                                            .is_global_scope = is_global_scope,
                                            .jsdoc = top_jsdoc,
                                            .kind = .{ .template_pattern_decl = pat_ir },
                                        });
                                        return;
                                    }
                                }
                            },
                            else => {},
                        }
                    }

                    // 2. Multi-arm discriminated/heterogeneous union -> Zig `union(enum)`!
                    if (try self.tryLowerUnionDeclVariants(ty_id, tp_res.active, imports_used, needs_runtime)) |tu| {
                        try out_list.append(self.alloc, .{
                            .source_decl_id = decl_id,
                            .zig_ident = bound.zig_ident,
                            .logical_name = bound.logical_name,
                            .wire_name = bound.wire_name,
                            .is_exported = is_exported,
                            .is_js_exported = is_js_exported,
                            .is_default_export = is_default_export,
                            .is_global_scope = is_global_scope,
                            .jsdoc = top_jsdoc,
                            .kind = .{
                                .union_decl = .{
                                    .type_params = tp_res.ir,
                                    .discriminant_prop = tu.discriminant_prop,
                                    .variants = tu.variants,
                                },
                            },
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
                            const obj_cls = self.classifyObjectLiteral(obj);
                            const split = try self.splitObjectLiteralPropsAndMethods(obj.properties);
                            const sourced_calls = try self.wrapUnsourcedSigs(obj.call_signatures);
                            const sourced_ctors = try self.wrapUnsourcedSigs(obj.construct_signatures);
                            const struct_ir = try self.lowerStructDecl(
                                final_mod_idx,
                                decl_id,
                                obj_cls,
                                false,
                                false,
                                d.type_params,
                                &.{},
                                split.props,
                                &.{},
                                split.methods,
                                sourced_calls,
                                sourced_ctors,
                                &.{},
                                scope,
                                prebound_names,
                                prebound_overloads,
                                outer_active_tps,
                                imports_used,
                                needs_runtime,
                                active_decls,
                            );
                            try out_list.append(self.alloc, .{
                                .source_decl_id = decl_id,
                                .zig_ident = bound.zig_ident,
                                .logical_name = bound.logical_name,
                                .wire_name = bound.wire_name,
                                .is_exported = is_exported,
                                .is_js_exported = is_js_exported,
                                .is_default_export = is_default_export,
                                .is_global_scope = is_global_scope,
                                .jsdoc = top_jsdoc,
                                .kind = .{ .struct_decl = struct_ir },
                            });
                            return;
                        }
                    }

                    // 3b. Handle-bearing intersection type alias (`type Inter = { a: number } & { run(): void }`,
                    //     `type Both = LoggerT & { extra: number }`) -> merged `.handle_wrapper` `struct`!
                    if (ty_id < self.graph.types.len and self.graph.types[ty_id].kind == .intersection) {
                        const inter_cls = try self.classifyDecl(decl_id);
                        if (inter_cls.kind == .handle_wrapper) {
                            var inter_props: std.ArrayList(SourcedProp) = .empty;
                            defer inter_props.deinit(self.scratch);
                            var inter_methods: std.ArrayList(SourcedMethod) = .empty;
                            defer inter_methods.deinit(self.scratch);
                            var inter_calls: std.ArrayList(SourcedSig) = .empty;
                            defer inter_calls.deinit(self.scratch);
                            var inter_ctors: std.ArrayList(SourcedSig) = .empty;
                            defer inter_ctors.deinit(self.scratch);

                            if (try self.collectHandleIntersectionMembers(
                                ty_id,
                                &inter_props,
                                &inter_methods,
                                &inter_calls,
                                &inter_ctors,
                            ) and (inter_props.items.len > 0 or inter_methods.items.len > 0 or
                                inter_calls.items.len > 0 or inter_ctors.items.len > 0))
                            {
                                const struct_ir = try self.lowerStructDecl(
                                    final_mod_idx,
                                    decl_id,
                                    inter_cls,
                                    false,
                                    false,
                                    d.type_params,
                                    &.{},
                                    inter_props.items,
                                    &.{},
                                    inter_methods.items,
                                    inter_calls.items,
                                    inter_ctors.items,
                                    &.{},
                                    scope,
                                    prebound_names,
                                    prebound_overloads,
                                    outer_active_tps,
                                    imports_used,
                                    needs_runtime,
                                    active_decls,
                                );
                                try out_list.append(self.alloc, .{
                                    .source_decl_id = decl_id,
                                    .zig_ident = bound.zig_ident,
                                    .logical_name = bound.logical_name,
                                    .wire_name = bound.wire_name,
                                    .is_exported = is_exported,
                                    .is_js_exported = is_js_exported,
                                    .is_default_export = is_default_export,
                                    .is_global_scope = is_global_scope,
                                    .jsdoc = top_jsdoc,
                                    .kind = .{ .struct_decl = struct_ir },
                                });
                                return;
                            }
                        }
                    }

                    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
                    defer visited.deinit(self.scratch);
                    const is_never_alias = (ty_id < self.graph.types.len and self.graph.types[ty_id].kind == .never_type);
                    const target = try self.lowerType(ty_id, is_never_alias, tp_res.active, null, &visited, imports_used, needs_runtime);
                    try out_list.append(self.alloc, .{
                        .source_decl_id = decl_id,
                        .zig_ident = bound.zig_ident,
                        .logical_name = bound.logical_name,
                        .wire_name = bound.wire_name,
                        .is_exported = is_exported,
                        .is_js_exported = is_js_exported,
                        .is_default_export = is_default_export,
                        .is_global_scope = is_global_scope,
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
                        try self.lowerDeclIntoListInner(
                            final_mod_idx,
                            cid,
                            false,
                            &ns_scope,
                            prebound_names,
                            prebound_overloads,
                            outer_active_tps,
                            imports_used,
                            needs_runtime,
                            &child_irs,
                            active_decls,
                        );
                    }
                    try deduplicateDeclIrsInPlace(self.scratch, &child_irs);
                    try out_list.append(self.alloc, .{
                        .source_decl_id = decl_id,
                        .zig_ident = bound.zig_ident,
                        .logical_name = bound.logical_name,
                        .wire_name = bound.wire_name,
                        .is_exported = is_exported,
                        .is_js_exported = is_js_exported,
                        .is_default_export = is_default_export,
                        .is_global_scope = is_global_scope,
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
                        const is_self_noop = is_top_level and
                            loc.module_index == final_mod_idx and
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
                            const is_self_noop = is_top_level and
                                loc.module_index == final_mod_idx and
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

        fn propsShareIdentity(self: *const Self, a_id: u32, b_id: u32) bool {
            if (a_id >= self.graph.properties.len or b_id >= self.graph.properties.len) return false;
            const a = self.graph.properties[a_id];
            const b = self.graph.properties[b_id];
            if (a.modifiers.static_mod != b.modifiers.static_mod) return false;
            if (a.computed_symbol != null or b.computed_symbol != null) {
                if (a.computed_symbol == null or b.computed_symbol == null) return false;
                return std.meta.eql(a.computed_symbol.?, b.computed_symbol.?);
            }
            return std.mem.eql(u8, self.str(a.name), self.str(b.name));
        }

        fn wrapUnsourcedProps(self: *Self, prop_ids: []const u32) error{OutOfMemory}![]SourcedProp {
            const res = try self.scratch.alloc(SourcedProp, prop_ids.len);
            for (prop_ids, 0..) |pid, idx| {
                res[idx] = .{ .pid = pid, .env = null };
            }
            return res;
        }

        const ObjectLiteralMemberSplit = struct {
            props: []SourcedProp,
            methods: []SourcedMethod,
        };

        fn collectMethodSigsFromType(
            self: *const Self,
            ty_id: u32,
            out_sigs: *std.ArrayList(u32),
            depth: usize,
        ) error{OutOfMemory}!void {
            if (depth > 8 or ty_id >= self.graph.types.len) return;
            switch (self.graph.types[ty_id].kind) {
                .function_type => |sid| {
                    for (out_sigs.items) |existing| {
                        if (existing == sid) return;
                    }
                    try out_sigs.append(self.scratch, sid);
                },
                .intersection, .union_type => |parts| {
                    for (parts) |part_id| {
                        try self.collectMethodSigsFromType(part_id, out_sigs, depth + 1);
                    }
                },
                else => {},
            }
        }

        fn splitObjectLiteralPropsAndMethods(self: *Self, prop_ids: []const u32) error{OutOfMemory}!ObjectLiteralMemberSplit {
            return self.splitObjectLiteralPropsAndMethodsWithEnv(prop_ids, null);
        }

        fn splitObjectLiteralPropsAndMethodsWithEnv(
            self: *Self,
            prop_ids: []const u32,
            env: ?*const HeritageEnv,
        ) error{OutOfMemory}!ObjectLiteralMemberSplit {
            var props: std.ArrayList(SourcedProp) = .empty;
            var methods: std.ArrayList(SourcedMethod) = .empty;
            for (prop_ids) |pid| {
                if (pid < self.graph.properties.len) {
                    const p = self.graph.properties[pid];
                    if (p.modifiers.method_mod and !p.has_getter and !p.has_setter) {
                        var sigs: std.ArrayList(u32) = .empty;
                        try self.collectMethodSigsFromType(p.ty, &sigs, 0);
                        if (sigs.items.len > 0) {
                            try methods.append(self.scratch, .{
                                .method = .{
                                    .name = p.name,
                                    .computed_symbol = p.computed_symbol,
                                    .signatures = try sigs.toOwnedSlice(self.scratch),
                                    .modifiers = p.modifiers,
                                    .jsdoc = p.jsdoc,
                                },
                                .env = env,
                            });
                            continue;
                        }
                        sigs.deinit(self.scratch);
                    }
                }
                try props.append(self.scratch, .{ .pid = pid, .env = env });
            }
            return .{
                .props = try props.toOwnedSlice(self.scratch),
                .methods = try methods.toOwnedSlice(self.scratch),
            };
        }

        fn wrapUnsourcedSigs(self: *Self, sig_ids: []const u32) error{OutOfMemory}![]SourcedSig {
            const res = try self.scratch.alloc(SourcedSig, sig_ids.len);
            for (sig_ids, 0..) |sid, idx| {
                res[idx] = .{ .sid = sid, .env = null };
            }
            return res;
        }

        fn appendUniqueSourcedSig(
            list: *std.ArrayList(SourcedSig),
            scratch: std.mem.Allocator,
            item: SourcedSig,
        ) error{OutOfMemory}!void {
            for (list.items) |existing| {
                if (existing.sid == item.sid) return;
            }
            try list.append(scratch, item);
        }

        fn upsertPropByWireName(self: *Self, list: *std.ArrayList(SourcedProp), sp: SourcedProp) error{OutOfMemory}!void {
            return self.upsertPropWithMode(list, sp, false);
        }

        fn upsertPropWithMode(
            self: *Self,
            list: *std.ArrayList(SourcedProp),
            sp: SourcedProp,
            prefer_required: bool,
        ) error{OutOfMemory}!void {
            if (sp.pid >= self.graph.properties.len) return;
            const new_prop = self.graph.properties[sp.pid];
            for (list.items, 0..) |existing, idx| {
                if (self.propsShareIdentity(existing.pid, sp.pid)) {
                    if (prefer_required and existing.pid < self.graph.properties.len) {
                        const old_prop = self.graph.properties[existing.pid];
                        if (!old_prop.modifiers.optional_mod and new_prop.modifiers.optional_mod) {
                            return;
                        }
                    }
                    list.items[idx] = sp;
                    return;
                }
            }
            try list.append(self.scratch, sp);
        }

        fn appendMethodIfMissing(self: *Self, list: *std.ArrayList(SourcedMethod), sm: SourcedMethod) error{OutOfMemory}!void {
            const m = sm.method;
            const m_wire = self.str(m.name);
            for (list.items) |existing_sm| {
                const existing = existing_sm.method;
                if (existing.modifiers.static_mod != m.modifiers.static_mod) continue;
                if (existing.computed_symbol != null or m.computed_symbol != null) {
                    if (existing.computed_symbol != null and m.computed_symbol != null and
                        std.meta.eql(existing.computed_symbol.?, m.computed_symbol.?))
                    {
                        return;
                    }
                    continue;
                }
                if (std.mem.eql(u8, self.str(existing.name), m_wire)) return;
            }
            try list.append(self.scratch, sm);
        }

        fn buildHeritageEnv(
            self: *Self,
            parent_env: ?*const HeritageEnv,
            base_tps: []const u32,
            hc_type_args: []const u32,
        ) error{OutOfMemory}!?*const HeritageEnv {
            if (base_tps.len == 0) return null;
            const bindings = try self.scratch.alloc(HeritageBinding, base_tps.len);
            for (base_tps, 0..) |tp_id, i| {
                const tp_name = if (tp_id < self.graph.type_params.len)
                    self.str(self.graph.type_params[tp_id].name)
                else
                    "";
                if (i < hc_type_args.len) {
                    bindings[i] = .{
                        .ts_name = tp_name,
                        .arg_ty_id = hc_type_args[i],
                        .arg_in_self_env = false,
                    };
                } else if (tp_id < self.graph.type_params.len and self.graph.type_params[tp_id].default_type != null) {
                    bindings[i] = .{
                        .ts_name = tp_name,
                        .arg_ty_id = self.graph.type_params[tp_id].default_type,
                        .arg_in_self_env = true,
                    };
                } else if (tp_id < self.graph.type_params.len and self.graph.type_params[tp_id].constraint != null) {
                    bindings[i] = .{
                        .ts_name = tp_name,
                        .arg_ty_id = self.graph.type_params[tp_id].constraint,
                        .arg_in_self_env = true,
                    };
                } else {
                    bindings[i] = .{
                        .ts_name = tp_name,
                        .arg_ty_id = null,
                        .arg_in_self_env = false,
                    };
                }
            }
            const env_ptr = try self.scratch.create(HeritageEnv);
            env_ptr.* = .{
                .bindings = bindings,
                .parent = parent_env,
            };
            return env_ptr;
        }

        fn resolveHeritageActiveTps(
            self: *Self,
            env_opt: ?*const HeritageEnv,
            owner_active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
            cache: *std.AutoHashMapUnmanaged(*const HeritageEnv, []const ActiveTypeParam),
            depth: usize,
        ) error{OutOfMemory}![]const ActiveTypeParam {
            const env = env_opt orelse return owner_active_tps;
            if (cache.get(env)) |cached| return cached;
            if (depth >= 24) return owner_active_tps;

            const parent_active = try self.resolveHeritageActiveTps(
                env.parent,
                owner_active_tps,
                self_ident_opt,
                imports_used,
                needs_runtime,
                cache,
                depth + 1,
            );

            const list = try self.scratch.alloc(ActiveTypeParam, env.bindings.len);
            var built_len: usize = 0;
            for (env.bindings, 0..) |b, idx| {
                const sub_ty: *TypeIr = if (b.arg_ty_id) |aty_id| blk: {
                    var v: std.AutoHashMapUnmanaged(u32, void) = .empty;
                    defer v.deinit(self.scratch);
                    const eval_tps = if (b.arg_in_self_env) list[0..built_len] else parent_active;
                    break :blk try self.lowerType(
                        aty_id,
                        false,
                        eval_tps,
                        self_ident_opt,
                        &v,
                        imports_used,
                        needs_runtime,
                    );
                } else blk: {
                    needs_runtime.* = true;
                    break :blk try self.makeType(.js_any);
                };
                list[idx] = .{
                    .ts_name = b.ts_name,
                    .zig_ident = "",
                    .subst_ty = sub_ty,
                };
                built_len = idx + 1;
            }
            try cache.put(self.scratch, env, list);
            return list;
        }

        fn resolvePropGraphTypeForLiteralConstraint(
            self: *const Self,
            prop_ty_id: u32,
            env_opt: ?*const HeritageEnv,
            depth: usize,
        ) u32 {
            if (depth >= 16 or prop_ty_id >= self.graph.types.len) return prop_ty_id;
            const env = env_opt orelse return prop_ty_id;
            const tn = self.graph.types[prop_ty_id];
            const tp_name: ?[]const u8 = switch (tn.kind) {
                .type_param, .infer_type => |tp_id| if (tp_id < self.graph.type_params.len)
                    self.str(self.graph.type_params[tp_id].name)
                else
                    null,
                .reference => |ref| if (ref.target_decl == null and ref.type_args.len == 0)
                    self.str(ref.target_name)
                else
                    null,
                else => null,
            };
            const name = tp_name orelse return prop_ty_id;
            var i: usize = env.bindings.len;
            while (i > 0) {
                i -= 1;
                const b = env.bindings[i];
                if (std.mem.eql(u8, b.ts_name, name)) {
                    const aty = b.arg_ty_id orelse return prop_ty_id;
                    const next_env = if (b.arg_in_self_env) env else env.parent;
                    return self.resolvePropGraphTypeForLiteralConstraint(aty, next_env, depth + 1);
                }
            }
            return prop_ty_id;
        }

        fn resolveHeritageTargetDecl(self: *const Self, hc: anytype) ?u32 {
            if (hc.target_decl) |td| {
                if (td < self.graph.decls.len) return td;
            }
            if (hc.target_type < self.graph.types.len) {
                const tn = self.graph.types[hc.target_type];
                if (tn.kind == .reference) {
                    if (tn.kind.reference.target_decl) |td| {
                        if (td < self.graph.decls.len) return td;
                    }
                }
            }
            return null;
        }

        fn collectInheritedHeritageClauses(
            self: *Self,
            parent_env: ?*const HeritageEnv,
            extends_clauses: anytype,
            out_props: *std.ArrayList(SourcedProp),
            out_methods: *std.ArrayList(SourcedMethod),
            out_call_sigs: *std.ArrayList(SourcedSig),
            out_construct_sigs: *std.ArrayList(SourcedSig),
            seen_methods: *std.StringHashMapUnmanaged(void),
            derived_methods: *std.StringHashMapUnmanaged(void),
            visited_bases: *std.AutoHashMapUnmanaged(u32, void),
        ) error{OutOfMemory}!void {
            for (extends_clauses) |hc| {
                try self.collectInheritedHeritageClause(
                    parent_env,
                    hc,
                    out_props,
                    out_methods,
                    out_call_sigs,
                    out_construct_sigs,
                    seen_methods,
                    derived_methods,
                    visited_bases,
                );
            }
        }

        fn collectHandleIntersectionMembers(
            self: *Self,
            ty_id: u32,
            out_props: *std.ArrayList(SourcedProp),
            out_methods: *std.ArrayList(SourcedMethod),
            out_call_sigs: *std.ArrayList(SourcedSig),
            out_construct_sigs: *std.ArrayList(SourcedSig),
        ) error{OutOfMemory}!bool {
            var seen_methods: std.StringHashMapUnmanaged(void) = .empty;
            defer seen_methods.deinit(self.scratch);
            var derived_methods: std.StringHashMapUnmanaged(void) = .empty;
            defer derived_methods.deinit(self.scratch);
            var visited_bases: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited_bases.deinit(self.scratch);
            var newly_seen: std.ArrayList([]const u8) = .empty;
            defer newly_seen.deinit(self.scratch);
            return self.collectStructuralTypeMembers(
                ty_id,
                null,
                out_props,
                out_methods,
                out_call_sigs,
                out_construct_sigs,
                &seen_methods,
                &derived_methods,
                &visited_bases,
                &newly_seen,
                true,
                0,
            );
        }

        fn collectStructuralTypeMembers(
            self: *Self,
            ty_id: u32,
            env: ?*const HeritageEnv,
            out_props: *std.ArrayList(SourcedProp),
            out_methods: *std.ArrayList(SourcedMethod),
            out_call_sigs: *std.ArrayList(SourcedSig),
            out_construct_sigs: *std.ArrayList(SourcedSig),
            seen_methods: *std.StringHashMapUnmanaged(void),
            derived_methods: *std.StringHashMapUnmanaged(void),
            visited_bases: *std.AutoHashMapUnmanaged(u32, void),
            newly_seen_methods: *std.ArrayList([]const u8),
            prefer_required_props: bool,
            depth: usize,
        ) error{OutOfMemory}!bool {
            if (ty_id >= self.graph.types.len or depth > 16) return false;
            const tn = self.graph.types[ty_id];
            switch (tn.kind) {
                .object_literal => |obj| {
                    const split = try self.splitObjectLiteralPropsAndMethodsWithEnv(obj.properties, env);
                    for (split.methods) |sm| {
                        if (sm.method.modifiers.static_mod or sm.method.modifiers.private_mod or
                            sm.method.modifiers.protected_mod or sm.method.computed_symbol != null)
                        {
                            continue;
                        }
                        const mw = self.str(sm.method.name);
                        if (!seen_methods.contains(mw)) {
                            try out_methods.append(self.scratch, sm);
                            try newly_seen_methods.append(self.scratch, mw);
                        }
                    }
                    for (split.props) |sp| {
                        if (sp.pid >= self.graph.properties.len) continue;
                        const p = self.graph.properties[sp.pid];
                        if (p.modifiers.static_mod or p.modifiers.private_mod or
                            p.modifiers.protected_mod or p.computed_symbol != null)
                        {
                            continue;
                        }
                        const pw = self.str(p.name);
                        if (!derived_methods.contains(pw)) {
                            try self.upsertPropWithMode(out_props, sp, prefer_required_props);
                        }
                        try newly_seen_methods.append(self.scratch, pw);
                    }
                    for (obj.call_signatures) |sid| {
                        try appendUniqueSourcedSig(out_call_sigs, self.scratch, .{ .sid = sid, .env = env });
                    }
                    for (obj.construct_signatures) |sid| {
                        try appendUniqueSourcedSig(out_construct_sigs, self.scratch, .{ .sid = sid, .env = env });
                    }
                    return true;
                },
                .intersection => |parts| {
                    if (parts.len == 0 or self.detectOpenPrimitiveIntersection(parts) != null) return false;

                    var tmp_props: std.ArrayList(SourcedProp) = .empty;
                    defer tmp_props.deinit(self.scratch);
                    var tmp_methods: std.ArrayList(SourcedMethod) = .empty;
                    defer tmp_methods.deinit(self.scratch);
                    var tmp_calls: std.ArrayList(SourcedSig) = .empty;
                    defer tmp_calls.deinit(self.scratch);
                    var tmp_ctors: std.ArrayList(SourcedSig) = .empty;
                    defer tmp_ctors.deinit(self.scratch);
                    var tmp_bases = try visited_bases.clone(self.scratch);
                    defer tmp_bases.deinit(self.scratch);
                    var tmp_newly_seen: std.ArrayList([]const u8) = .empty;
                    defer tmp_newly_seen.deinit(self.scratch);

                    for (parts) |pid| {
                        var part_seen = try seen_methods.clone(self.scratch);
                        defer part_seen.deinit(self.scratch);
                        if (!try self.collectStructuralTypeMembers(
                            pid,
                            env,
                            &tmp_props,
                            &tmp_methods,
                            &tmp_calls,
                            &tmp_ctors,
                            &part_seen,
                            derived_methods,
                            &tmp_bases,
                            &tmp_newly_seen,
                            true,
                            depth + 1,
                        )) {
                            return false;
                        }
                    }

                    for (tmp_methods.items) |sm| try out_methods.append(self.scratch, sm);
                    for (tmp_props.items) |sp| try self.upsertPropWithMode(out_props, sp, prefer_required_props);
                    for (tmp_calls.items) |ss| try appendUniqueSourcedSig(out_call_sigs, self.scratch, ss);
                    for (tmp_ctors.items) |ss| try appendUniqueSourcedSig(out_construct_sigs, self.scratch, ss);
                    for (tmp_newly_seen.items) |mw| try newly_seen_methods.append(self.scratch, mw);
                    var bit = tmp_bases.keyIterator();
                    while (bit.next()) |k| try visited_bases.put(self.scratch, k.*, {});
                    return true;
                },
                .reference => |ref| {
                    const rname = self.str(ref.target_name);
                    if (self.isBuiltinMappedReference(rname, ref.type_args.len, ref.target_decl)) return false;
                    if (std.mem.eql(u8, rname, "Array") or std.mem.eql(u8, rname, "ReadonlyArray") or
                        std.mem.eql(u8, rname, "Iterable") or std.mem.eql(u8, rname, "IterableIterator") or
                        std.mem.eql(u8, rname, "Promise") or std.mem.eql(u8, rname, "PromiseLike") or
                        std.mem.eql(u8, rname, "Map") or std.mem.eql(u8, rname, "ReadonlyMap") or
                        std.mem.eql(u8, rname, "Set") or std.mem.eql(u8, rname, "ReadonlySet") or
                        std.mem.eql(u8, rname, "Record"))
                    {
                        return false;
                    }
                    if (ref.target_decl) |td| {
                        if (td >= self.graph.decls.len) return false;
                        const bd = self.graph.decls[td];
                        if (self.isBundledLibDecl(td)) {
                            if (bd.kind == .type_alias_decl) {
                                if (tn.resolved_type) |rt| {
                                    if (rt != ty_id) {
                                        return self.collectStructuralTypeMembers(
                                            rt,
                                            env,
                                            out_props,
                                            out_methods,
                                            out_call_sigs,
                                            out_construct_sigs,
                                            seen_methods,
                                            derived_methods,
                                            visited_bases,
                                            newly_seen_methods,
                                            prefer_required_props,
                                            depth + 1,
                                        );
                                    }
                                }
                            }
                            return false;
                        }
                        switch (bd.kind) {
                            .interface_decl, .class_decl => {
                                var sub_seen = try seen_methods.clone(self.scratch);
                                defer sub_seen.deinit(self.scratch);
                                const before_methods = out_methods.items.len;
                                const before_props = out_props.items.len;
                                try self.collectInheritedDeclMembers(
                                    env,
                                    td,
                                    ref.type_args,
                                    out_props,
                                    out_methods,
                                    out_call_sigs,
                                    out_construct_sigs,
                                    &sub_seen,
                                    derived_methods,
                                    visited_bases,
                                    prefer_required_props,
                                );
                                for (out_methods.items[before_methods..]) |sm| {
                                    try newly_seen_methods.append(self.scratch, self.str(sm.method.name));
                                }
                                for (out_props.items[before_props..]) |sp| {
                                    if (sp.pid < self.graph.properties.len) {
                                        try newly_seen_methods.append(self.scratch, self.str(self.graph.properties[sp.pid].name));
                                    }
                                }
                                return true;
                            },
                            .type_alias_decl => |alias_ty| {
                                if (visited_bases.contains(td)) return true;
                                try visited_bases.put(self.scratch, td, {});
                                const child_env = try self.buildHeritageEnv(env, bd.type_params, ref.type_args);
                                if (try self.collectStructuralTypeMembers(
                                    alias_ty,
                                    child_env,
                                    out_props,
                                    out_methods,
                                    out_call_sigs,
                                    out_construct_sigs,
                                    seen_methods,
                                    derived_methods,
                                    visited_bases,
                                    newly_seen_methods,
                                    prefer_required_props,
                                    depth + 1,
                                )) {
                                    return true;
                                }
                                if (tn.resolved_type) |rt| {
                                    if (rt != ty_id) {
                                        return self.collectStructuralTypeMembers(
                                            rt,
                                            env,
                                            out_props,
                                            out_methods,
                                            out_call_sigs,
                                            out_construct_sigs,
                                            seen_methods,
                                            derived_methods,
                                            visited_bases,
                                            newly_seen_methods,
                                            prefer_required_props,
                                            depth + 1,
                                        );
                                    }
                                }
                                return false;
                            },
                            else => return false,
                        }
                    }
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) {
                            return self.collectStructuralTypeMembers(
                                rt,
                                env,
                                out_props,
                                out_methods,
                                out_call_sigs,
                                out_construct_sigs,
                                seen_methods,
                                derived_methods,
                                visited_bases,
                                newly_seen_methods,
                                prefer_required_props,
                                depth + 1,
                            );
                        }
                    }
                    return false;
                },
                else => {
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) {
                            return self.collectStructuralTypeMembers(
                                rt,
                                env,
                                out_props,
                                out_methods,
                                out_call_sigs,
                                out_construct_sigs,
                                seen_methods,
                                derived_methods,
                                visited_bases,
                                newly_seen_methods,
                                prefer_required_props,
                                depth + 1,
                            );
                        }
                    }
                    return false;
                },
            }
        }

        fn collectInheritedHeritageClause(
            self: *Self,
            parent_env: ?*const HeritageEnv,
            hc: anytype,
            out_props: *std.ArrayList(SourcedProp),
            out_methods: *std.ArrayList(SourcedMethod),
            out_call_sigs: *std.ArrayList(SourcedSig),
            out_construct_sigs: *std.ArrayList(SourcedSig),
            seen_methods: *std.StringHashMapUnmanaged(void),
            derived_methods: *std.StringHashMapUnmanaged(void),
            visited_bases: *std.AutoHashMapUnmanaged(u32, void),
        ) error{OutOfMemory}!void {
            if (self.resolveHeritageTargetDecl(hc)) |base_did| {
                const bd = self.graph.decls[base_did];
                if (self.isBundledLibDecl(base_did)) {
                    if (bd.kind == .type_alias_decl and hc.target_type < self.graph.types.len) {
                        var newly_seen: std.ArrayList([]const u8) = .empty;
                        defer newly_seen.deinit(self.scratch);
                        _ = try self.collectStructuralTypeMembers(
                            hc.target_type,
                            parent_env,
                            out_props,
                            out_methods,
                            out_call_sigs,
                            out_construct_sigs,
                            seen_methods,
                            derived_methods,
                            visited_bases,
                            &newly_seen,
                            false,
                            0,
                        );
                        for (newly_seen.items) |mw| try seen_methods.put(self.scratch, mw, {});
                    }
                    return;
                }
                if (bd.kind == .interface_decl or bd.kind == .class_decl) {
                    try self.collectInheritedDeclMembers(
                        parent_env,
                        base_did,
                        hc.type_args,
                        out_props,
                        out_methods,
                        out_call_sigs,
                        out_construct_sigs,
                        seen_methods,
                        derived_methods,
                        visited_bases,
                        false,
                    );
                    return;
                }
                if (bd.kind == .type_alias_decl) {
                    if (visited_bases.contains(base_did)) return;
                    try visited_bases.put(self.scratch, base_did, {});
                    const child_env = try self.buildHeritageEnv(parent_env, bd.type_params, hc.type_args);
                    var newly_seen: std.ArrayList([]const u8) = .empty;
                    defer newly_seen.deinit(self.scratch);
                    const ok = try self.collectStructuralTypeMembers(
                        bd.kind.type_alias_decl,
                        child_env,
                        out_props,
                        out_methods,
                        out_call_sigs,
                        out_construct_sigs,
                        seen_methods,
                        derived_methods,
                        visited_bases,
                        &newly_seen,
                        false,
                        0,
                    );
                    if (!ok and hc.target_type < self.graph.types.len) {
                        if (self.graph.types[hc.target_type].resolved_type) |rt| {
                            if (rt != hc.target_type) {
                                _ = try self.collectStructuralTypeMembers(
                                    rt,
                                    parent_env,
                                    out_props,
                                    out_methods,
                                    out_call_sigs,
                                    out_construct_sigs,
                                    seen_methods,
                                    derived_methods,
                                    visited_bases,
                                    &newly_seen,
                                    false,
                                    0,
                                );
                            }
                        }
                    }
                    for (newly_seen.items) |mw| try seen_methods.put(self.scratch, mw, {});
                    return;
                }
                return;
            }

            if (hc.target_type < self.graph.types.len) {
                var newly_seen: std.ArrayList([]const u8) = .empty;
                defer newly_seen.deinit(self.scratch);
                _ = try self.collectStructuralTypeMembers(
                    hc.target_type,
                    parent_env,
                    out_props,
                    out_methods,
                    out_call_sigs,
                    out_construct_sigs,
                    seen_methods,
                    derived_methods,
                    visited_bases,
                    &newly_seen,
                    false,
                    0,
                );
                for (newly_seen.items) |mw| try seen_methods.put(self.scratch, mw, {});
            }
        }

        fn collectInheritedDeclMembers(
            self: *Self,
            parent_env: ?*const HeritageEnv,
            base_did: u32,
            type_args: []const u32,
            out_props: *std.ArrayList(SourcedProp),
            out_methods: *std.ArrayList(SourcedMethod),
            out_call_sigs: *std.ArrayList(SourcedSig),
            out_construct_sigs: *std.ArrayList(SourcedSig),
            seen_methods: *std.StringHashMapUnmanaged(void),
            derived_methods: *std.StringHashMapUnmanaged(void),
            visited_bases: *std.AutoHashMapUnmanaged(u32, void),
            prefer_required_props: bool,
        ) error{OutOfMemory}!void {
            if (self.isBundledLibDecl(base_did)) return;
            if (visited_bases.contains(base_did)) return;
            const bd = self.graph.decls[base_did];
            if (bd.kind != .interface_decl and bd.kind != .class_decl) return;

            const child_env = try self.buildHeritageEnv(parent_env, bd.type_params, type_args);

            try visited_bases.put(self.scratch, base_did, {});
            for (bd.merged_with) |mid| {
                if (mid < self.graph.decls.len and self.graph.decls[mid].kind == .interface_decl) {
                    try visited_bases.put(self.scratch, mid, {});
                }
            }

            var bd_props: std.ArrayList(SourcedProp) = .empty;
            defer bd_props.deinit(self.scratch);
            var newly_seen_methods: std.ArrayList([]const u8) = .empty;
            defer newly_seen_methods.deinit(self.scratch);

            switch (bd.kind) {
                .interface_decl => |biface| {
                    for (biface.methods) |bm| {
                        if (bm.modifiers.static_mod or bm.modifiers.private_mod or bm.modifiers.protected_mod or bm.computed_symbol != null) continue;
                        const mw = self.str(bm.name);
                        if (!seen_methods.contains(mw)) {
                            try out_methods.append(self.scratch, .{ .method = bm, .env = child_env });
                            try newly_seen_methods.append(self.scratch, mw);
                        }
                    }
                    for (biface.properties) |pid| {
                        if (pid >= self.graph.properties.len) continue;
                        const p = self.graph.properties[pid];
                        if (p.modifiers.static_mod or p.modifiers.private_mod or p.modifiers.protected_mod or p.computed_symbol != null) continue;
                        const pw = self.str(p.name);
                        if (!derived_methods.contains(pw)) {
                            try self.upsertPropByWireName(&bd_props, .{ .pid = pid, .env = child_env });
                        }
                        try newly_seen_methods.append(self.scratch, pw);
                    }
                    for (biface.call_signatures) |sid| try appendUniqueSourcedSig(out_call_sigs, self.scratch, .{ .sid = sid, .env = child_env });
                    for (biface.construct_signatures) |sid| try appendUniqueSourcedSig(out_construct_sigs, self.scratch, .{ .sid = sid, .env = child_env });
                },
                .class_decl => |bcls| {
                    for (bcls.methods) |bm| {
                        if (bm.modifiers.static_mod or bm.modifiers.private_mod or bm.modifiers.protected_mod or bm.computed_symbol != null) continue;
                        const mw = self.str(bm.name);
                        if (!seen_methods.contains(mw)) {
                            try out_methods.append(self.scratch, .{ .method = bm, .env = child_env });
                            try newly_seen_methods.append(self.scratch, mw);
                        }
                    }
                    for (bcls.properties) |pid| {
                        if (pid >= self.graph.properties.len) continue;
                        const p = self.graph.properties[pid];
                        if (p.modifiers.static_mod or p.modifiers.private_mod or p.modifiers.protected_mod or p.computed_symbol != null) continue;
                        const pw = self.str(p.name);
                        if (!derived_methods.contains(pw)) {
                            try self.upsertPropByWireName(&bd_props, .{ .pid = pid, .env = child_env });
                        }
                        try newly_seen_methods.append(self.scratch, pw);
                    }
                },
                else => unreachable,
            }

            // Also include same-symbol merged `interface_decl` members on `bd` at the same inheritance depth!
            for (bd.merged_with) |mid| {
                if (mid == base_did or mid >= self.graph.decls.len) continue;
                const mdecl = self.graph.decls[mid];
                if (mdecl.kind != .interface_decl) continue;
                const miface = mdecl.kind.interface_decl;
                for (miface.methods) |bm| {
                    if (bm.modifiers.static_mod or bm.modifiers.private_mod or bm.modifiers.protected_mod or bm.computed_symbol != null) continue;
                    const mw = self.str(bm.name);
                    if (!seen_methods.contains(mw)) {
                        try out_methods.append(self.scratch, .{ .method = bm, .env = child_env });
                        try newly_seen_methods.append(self.scratch, mw);
                    }
                }
                for (miface.properties) |pid| {
                    if (pid >= self.graph.properties.len) continue;
                    const p = self.graph.properties[pid];
                    if (p.modifiers.static_mod or p.modifiers.private_mod or p.modifiers.protected_mod or p.computed_symbol != null) continue;
                    const pw = self.str(p.name);
                    if (!derived_methods.contains(pw)) {
                        try self.upsertPropByWireName(&bd_props, .{ .pid = pid, .env = child_env });
                    }
                    try newly_seen_methods.append(self.scratch, pw);
                }
                for (miface.call_signatures) |sid| try appendUniqueSourcedSig(out_call_sigs, self.scratch, .{ .sid = sid, .env = child_env });
                if (bd.kind == .interface_decl) {
                    for (miface.construct_signatures) |sid| try appendUniqueSourcedSig(out_construct_sigs, self.scratch, .{ .sid = sid, .env = child_env });
                }
            }

            // Record `bd`'s instance members BEFORE recursing into `GrandBase` so `bd` overrides `GrandBase`.
            var sub_derived_methods = try derived_methods.clone(self.scratch);
            defer sub_derived_methods.deinit(self.scratch);
            for (newly_seen_methods.items) |name| {
                try seen_methods.put(self.scratch, name, {});
            }
            switch (bd.kind) {
                .interface_decl => |biface| {
                    for (biface.methods) |bm| {
                        if (bm.modifiers.static_mod or bm.modifiers.private_mod or bm.modifiers.protected_mod or bm.computed_symbol != null) continue;
                        try sub_derived_methods.put(self.scratch, self.str(bm.name), {});
                    }
                },
                .class_decl => |bcls| {
                    for (bcls.methods) |bm| {
                        if (bm.modifiers.static_mod or bm.modifiers.private_mod or bm.modifiers.protected_mod or bm.computed_symbol != null) continue;
                        try sub_derived_methods.put(self.scratch, self.str(bm.name), {});
                    }
                },
                else => unreachable,
            }
            for (bd.merged_with) |mid| {
                if (mid == base_did or mid >= self.graph.decls.len) continue;
                const mdecl = self.graph.decls[mid];
                if (mdecl.kind != .interface_decl) continue;
                for (mdecl.kind.interface_decl.methods) |bm| {
                    if (bm.modifiers.static_mod or bm.modifiers.private_mod or bm.modifiers.protected_mod or bm.computed_symbol != null) continue;
                    try sub_derived_methods.put(self.scratch, self.str(bm.name), {});
                }
            }

            // Recurse into ancestors FIRST so ancestor properties precede `bd_props`!
            switch (bd.kind) {
                .interface_decl => |biface| {
                    try self.collectInheritedHeritageClauses(
                        child_env,
                        biface.extends_clauses,
                        out_props,
                        out_methods,
                        out_call_sigs,
                        out_construct_sigs,
                        seen_methods,
                        &sub_derived_methods,
                        visited_bases,
                    );
                },
                .class_decl => |bcls| {
                    if (bcls.extends_clause) |bhc| {
                        try self.collectInheritedHeritageClause(
                            child_env,
                            bhc,
                            out_props,
                            out_methods,
                            out_call_sigs,
                            out_construct_sigs,
                            seen_methods,
                            &sub_derived_methods,
                            visited_bases,
                        );
                    }
                },
                else => unreachable,
            }
            for (bd.merged_with) |mid| {
                if (mid == base_did or mid >= self.graph.decls.len) continue;
                const mdecl = self.graph.decls[mid];
                if (mdecl.kind != .interface_decl) continue;
                try self.collectInheritedHeritageClauses(
                    child_env,
                    mdecl.kind.interface_decl.extends_clauses,
                    out_props,
                    out_methods,
                    out_call_sigs,
                    out_construct_sigs,
                    seen_methods,
                    &sub_derived_methods,
                    visited_bases,
                );
            }

            for (bd_props.items) |sp| {
                try self.upsertPropWithMode(out_props, sp, prefer_required_props);
            }
        }

        fn previewSigMayAllocateOnDecode(
            self: *Self,
            sig_id: u32,
            enclosing_scope: *const naming.ScopeNamer,
            outer_active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
        ) error{OutOfMemory}!bool {
            if (sig_id >= self.graph.signatures.len) return false;
            const sig = self.graph.signatures[sig_id];
            if (sig.type_predicate != null) return false;
            var tmp_scope = naming.ScopeNamer.initParam(self.scratch, enclosing_scope);
            defer tmp_scope.deinit();
            const tp_res = try self.lowerTypeParams(
                sig.type_params,
                &tmp_scope,
                outer_active_tps,
                self_ident_opt,
                imports_used,
                needs_runtime,
            );
            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(self.scratch);
            const ret_ty = try self.lowerType(
                sig.return_type,
                true,
                tp_res.active,
                self_ident_opt,
                &visited,
                imports_used,
                needs_runtime,
            );
            return try self.typeMayAllocateOnDecode(ret_ty);
        }

        fn lowerSourcedFields(
            self: *Self,
            sourced_props: []const SourcedProp,
            only_instance: bool,
            field_scope: *naming.ScopeNamer,
            owner_active_tps: []const ActiveTypeParam,
            self_ident_opt: ?[]const u8,
            visited: *std.AutoHashMapUnmanaged(u32, void),
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
            env_cache: *std.AutoHashMapUnmanaged(*const HeritageEnv, []const ActiveTypeParam),
        ) error{OutOfMemory}![]FieldIr {
            var list: std.ArrayList(FieldIr) = .empty;
            errdefer list.deinit(self.alloc);

            for (sourced_props) |sp| {
                const pid = sp.pid;
                if (pid >= self.graph.properties.len) continue;
                const p = self.graph.properties[pid];
                if (p.modifiers.private_mod or p.modifiers.protected_mod) continue;
                if (only_instance and p.modifiers.static_mod) continue;
                const wire = self.str(p.name);
                const bound = try field_scope.bind(wire, .snake);
                const zig_ident = try self.alloc.dupe(u8, bound.zig_ident);
                const logical = try self.alloc.dupe(u8, bound.logical_name);
                const wire_copy = try self.alloc.dupe(u8, bound.wire_name);
                bound.deinit(self.scratch);

                const field_active_tps = try self.resolveHeritageActiveTps(
                    sp.env,
                    owner_active_tps,
                    self_ident_opt,
                    imports_used,
                    needs_runtime,
                    env_cache,
                    0,
                );
                visited.clearRetainingCapacity();
                var f_ty = try self.lowerType(p.ty, false, field_active_tps, self_ident_opt, visited, imports_used, needs_runtime);
                var lit_constraint: ?FieldLiteralConstraintIr = null;
                if (p.modifiers.optional_mod) {
                    f_ty = try self.wrapOptional(f_ty);
                } else {
                    const lit_ty_id = self.resolvePropGraphTypeForLiteralConstraint(p.ty, sp.env, 0);
                    lit_constraint = try self.extractCompatibleFieldLiteralConstraint(lit_ty_id, f_ty);
                }

                try list.append(self.alloc, .{
                    .zig_ident = zig_ident,
                    .logical_name = logical,
                    .wire_name = wire_copy,
                    .ty = f_ty,
                    .is_optional = p.modifiers.optional_mod,
                    .is_readonly = p.modifiers.readonly_mod,
                    .nullish_kind = if (f_ty.* == .optional) f_ty.optional.nullish_kind else .none,
                    .literal_constraint = lit_constraint,
                    .jsdoc = try self.lowerJsDoc(p.jsdoc),
                });
            }

            return try list.toOwnedSlice(self.alloc);
        }

        fn lowerStructDecl(
            self: *Self,
            final_mod_idx: u32,
            owner_decl_id: u32,
            explicit_cls: classify_decls.DeclClassification,
            is_abstract: bool,
            has_explicit_extends: bool,
            raw_tps: []const u32,
            raw_ctors: []const u32,
            raw_props: []const SourcedProp,
            companion_static_props: []const u32,
            raw_methods: []const SourcedMethod,
            call_sigs: []const SourcedSig,
            construct_sigs: []const SourcedSig,
            merged_ids: []const u32,
            parent_scope: *const naming.ScopeNamer,
            prebound_names: *const std.AutoHashMapUnmanaged(u32, naming.BoundName),
            prebound_overloads: *const std.AutoHashMapUnmanaged(u32, []naming.BoundName),
            outer_active_tps: []const ActiveTypeParam,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
            active_decls: *std.AutoHashMapUnmanaged(u32, void),
        ) error{OutOfMemory}!StructDeclIr {
            const repr = explicit_cls.kind;
            const is_class = explicit_cls.is_class;
            const is_callable_handle = explicit_cls.is_callable_handle;
            const owner_is_class_decl = owner_decl_id < self.graph.decls.len and
                self.graph.decls[owner_decl_id].kind == .class_decl;

            const saved_in_handle = self.in_handle_struct;
            self.in_handle_struct = (repr == .handle_wrapper);
            defer self.in_handle_struct = saved_in_handle;

            if (repr == .handle_wrapper or is_class) {
                needs_runtime.* = true;
            }

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

            var has_non_public_members = false;
            for (raw_props) |sp| {
                if (sp.pid >= self.graph.properties.len) continue;
                const p = self.graph.properties[sp.pid];
                if (p.modifiers.private_mod or p.modifiers.protected_mod) {
                    has_non_public_members = true;
                    break;
                }
            }
            for (raw_methods) |sm| {
                const m = sm.method;
                if (m.modifiers.private_mod or m.modifiers.protected_mod) {
                    has_non_public_members = true;
                    break;
                }
            }

            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(self.scratch);
            var env_cache: std.AutoHashMapUnmanaged(*const HeritageEnv, []const ActiveTypeParam) = .empty;
            defer env_cache.deinit(self.scratch);

            if (repr == .value_struct) {
                const fields = try self.lowerSourcedFields(
                    raw_props,
                    true,
                    &struct_scope,
                    tp_res.active,
                    self_ident,
                    &visited,
                    imports_used,
                    needs_runtime,
                    &env_cache,
                );

                var nested_decls: std.ArrayList(DeclIr) = .empty;
                try self.lowerMergedStructNestedDecls(
                    final_mod_idx,
                    owner_decl_id,
                    merged_ids,
                    &struct_scope,
                    prebound_names,
                    prebound_overloads,
                    tp_res.active,
                    imports_used,
                    needs_runtime,
                    &nested_decls,
                    active_decls,
                );

                const to_js_ref_ident = try lower_objects.tryBindOptionalHelperIdent(&struct_scope, self.scratch, self.alloc, "toJsRef");
                const from_js_ref_ident = try lower_objects.tryBindOptionalHelperIdent(&struct_scope, self.scratch, self.alloc, "fromJsRef");
                const from_js_ref_alloc_ident = try lower_objects.tryBindOptionalHelperIdent(&struct_scope, self.scratch, self.alloc, "fromJsRefAlloc");
                if (to_js_ref_ident != null or from_js_ref_ident != null or from_js_ref_alloc_ident != null) {
                    needs_runtime.* = true;
                }
                const self_param_ident = try lower_objects.chooseNonShadowingParamIdent(&struct_scope, self.scratch, self.alloc, "self");
                const raw_param_ident = try lower_objects.chooseNonShadowingParamIdent(&struct_scope, self.scratch, self.alloc, "raw");
                const alloc_param_ident = try lower_objects.chooseNonShadowingParamIdent(&struct_scope, self.scratch, self.alloc, "allocator");

                return .{
                    .repr = .value_struct,
                    .is_class = false,
                    .is_abstract = false,
                    .is_callable_handle = false,
                    .has_private_constructor = false,
                    .has_non_public_members = has_non_public_members,
                    .self_ident = self_ident,
                    .self_param_ident = self_param_ident,
                    .raw_param_ident = raw_param_ident,
                    .alloc_param_ident = alloc_param_ident,
                    .to_js_ref_ident = to_js_ref_ident,
                    .from_js_ref_ident = from_js_ref_ident,
                    .from_js_ref_alloc_ident = from_js_ref_alloc_ident,
                    .type_params = tp_res.ir,
                    .fields = fields,
                    .static_props = &.{},
                    .constructors = &.{},
                    .methods = &.{},
                    .nested_decls = try nested_decls.toOwnedSlice(self.alloc),
                };
            }

            // `.handle_wrapper`: pre-bind ALL struct-level declarations in `struct_scope` BEFORE
            // calling `lowerSignature` so Zig 0.17 function parameters NEVER shadow struct members!

            // 1. Static properties (`raw_props` with `static_mod` + `companion_static_props`).
            var static_prop_ids: std.ArrayList(u32) = .empty;
            defer static_prop_ids.deinit(self.scratch);
            for (raw_props) |sp| {
                const pid = sp.pid;
                if (pid >= self.graph.properties.len) continue;
                const p = self.graph.properties[pid];
                if (p.modifiers.private_mod or p.modifiers.protected_mod) {
                    has_non_public_members = true;
                    continue;
                }
                if (!p.modifiers.static_mod) continue;
                if (p.computed_symbol != null) continue;
                try static_prop_ids.append(self.scratch, pid);
            }
            for (companion_static_props) |pid| {
                if (pid >= self.graph.properties.len) continue;
                const p = self.graph.properties[pid];
                if (p.modifiers.private_mod or p.modifiers.protected_mod) continue;
                if (p.computed_symbol != null) continue;
                const pwire = self.str(p.name);
                if (std.mem.eql(u8, pwire, "prototype")) continue;
                var dup = false;
                for (static_prop_ids.items) |epid| {
                    if (std.mem.eql(u8, self.str(self.graph.properties[epid].name), pwire)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) try static_prop_ids.append(self.scratch, pid);
            }

            var static_props: std.ArrayList(StaticPropIr) = .empty;
            for (static_prop_ids.items) |pid| {
                const p = self.graph.properties[pid];
                const wire = self.str(p.name);
                const access = lower_objects.analyzePropAccess(p);
                if (!access.is_readable and !access.is_writable) continue;

                const style: naming.NameStyle = if (isAllUpperOrUnderscore(wire)) .preserve else .snake;
                const sb = try struct_scope.bind(wire, style);
                defer sb.deinit(self.scratch);

                visited.clearRetainingCapacity();
                const primary_ty_id = if (!access.is_readable and access.is_writable) access.write_ty_id else access.read_ty_id;
                var sty = try self.lowerType(primary_ty_id, false, tp_res.active, self_ident, &visited, imports_used, needs_runtime);
                if (p.modifiers.optional_mod) {
                    sty = try self.wrapOptional(sty);
                }

                var setter_ty_ir: ?*const TypeIr = null;
                const access_kind: lower_objects.StaticPropAccessKind = if (!access.is_readable and access.is_writable)
                    .write_only
                else if (access.is_readable and !access.is_writable)
                    .read_only
                else if (access.has_divergent_setter) blk: {
                    visited.clearRetainingCapacity();
                    var wty = try self.lowerType(access.write_ty_id, false, tp_res.active, self_ident, &visited, imports_used, needs_runtime);
                    if (p.modifiers.optional_mod) wty = try self.wrapOptional(wty);
                    setter_ty_ir = wty;
                    break :blk .divergent_read_write;
                } else .read_write;

                var lit_opt: ?LiteralValueIr = null;
                if (access.is_literal_const_candidate and !p.modifiers.optional_mod and
                    p.ty < self.graph.types.len and self.graph.types[p.ty].kind == .literal)
                {
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
                    .setter_ty = setter_ty_ir,
                    .access_kind = access_kind,
                    .literal = lit_opt,
                    .jsdoc = try self.lowerJsDoc(p.jsdoc),
                });
            }

            // 2. Class / companion-var constructors (`init`, `init_2`, ...).
            //    `abstract class` declarations cannot be constructed directly via `new` (`TS2511`),
            //    even when they declare a `constructor(...)` signature for `super(...)` calls.
            var cand_ctor_sigs: std.ArrayList(SourcedSig) = .empty;
            defer cand_ctor_sigs.deinit(self.scratch);
            if (is_class and !is_abstract) {
                if (raw_ctors.len > 0) {
                    for (raw_ctors) |sid| try cand_ctor_sigs.append(self.scratch, .{ .sid = sid, .env = null });
                } else {
                    for (construct_sigs) |ss| try cand_ctor_sigs.append(self.scratch, ss);
                }
            }
            var public_ctor_sigs: std.ArrayList(SourcedSig) = .empty;
            defer public_ctor_sigs.deinit(self.scratch);
            var saw_non_public_ctor = false;
            for (cand_ctor_sigs.items) |ss| {
                if (ss.sid < self.graph.signatures.len) {
                    const csig = self.graph.signatures[ss.sid];
                    if (csig.modifiers.private_mod or csig.modifiers.protected_mod) {
                        saw_non_public_ctor = true;
                        continue;
                    }
                }
                try public_ctor_sigs.append(self.scratch, ss);
            }
            const has_private_constructor = saw_non_public_ctor and (public_ctor_sigs.items.len == 0);
            const synthesize_default_ctor = owner_is_class_decl and
                !is_abstract and
                !has_private_constructor and
                cand_ctor_sigs.items.len == 0 and
                !has_explicit_extends;

            const ctor_count = if (synthesize_default_ctor) @as(usize, 1) else public_ctor_sigs.items.len;
            var ctor_idents = try self.scratch.alloc([]const u8, ctor_count);
            defer self.scratch.free(ctor_idents);
            for (0..ctor_count) |idx| {
                const cb = try struct_scope.bind("init", .camel);
                ctor_idents[idx] = try self.alloc.dupe(u8, cb.zig_ident);
                cb.deinit(self.scratch);
            }

            // 3. Explicit methods, call signatures, and standalone construct signatures (primary names).
            const BoundMethodSlot = struct {
                zig_ident: []const u8,
                logical_name: []const u8,
                wire_name: []const u8,
                alloc_companion_ident: ?[]const u8 = null,
                is_static: bool,
                call_kind: lower_objects.MethodCallKind,
                sig_id: u32,
                env: ?*const HeritageEnv,
                prop_jsdoc: ?JsDocIr,
            };
            var method_slots: std.ArrayList(BoundMethodSlot) = .empty;
            defer method_slots.deinit(self.scratch);

            var required_methods: std.ArrayList([]const u8) = .empty;
            var required_props: std.ArrayList([]const u8) = .empty;

            for (raw_methods) |sm| {
                const m = sm.method;
                if (m.modifiers.private_mod or m.modifiers.protected_mod) {
                    has_non_public_members = true;
                    continue;
                }
                if (m.computed_symbol != null) continue;
                const m_wire = self.str(m.name);
                if (!is_class and !m.modifiers.static_mod and !m.modifiers.optional_mod and
                    required_methods.items.len < lower_objects.max_required_handle_checks)
                {
                    var seen_rm = false;
                    for (required_methods.items) |existing_rm| {
                        if (std.mem.eql(u8, existing_rm, m_wire)) {
                            seen_rm = true;
                            break;
                        }
                    }
                    if (!seen_rm) {
                        try required_methods.append(self.alloc, try self.alloc.dupe(u8, m_wire));
                    }
                }
                const m_jsdoc = try self.lowerJsDoc(m.jsdoc);
                for (m.signatures) |sid| {
                    const mb = try struct_scope.bind(m_wire, .camel);
                    try method_slots.append(self.scratch, .{
                        .zig_ident = try self.alloc.dupe(u8, mb.zig_ident),
                        .logical_name = try self.alloc.dupe(u8, mb.logical_name),
                        .wire_name = try self.alloc.dupe(u8, mb.wire_name),
                        .is_static = m.modifiers.static_mod,
                        .call_kind = .method,
                        .sig_id = sid,
                        .env = sm.env,
                        .prop_jsdoc = m_jsdoc,
                    });
                    mb.deinit(self.scratch);
                }
            }
            for (call_sigs) |ss| {
                const mb = try struct_scope.bind("call", .camel);
                try method_slots.append(self.scratch, .{
                    .zig_ident = try self.alloc.dupe(u8, mb.zig_ident),
                    .logical_name = try self.alloc.dupe(u8, mb.logical_name),
                    .wire_name = try self.alloc.dupe(u8, "call"),
                    .is_static = false,
                    .call_kind = .call_sig,
                    .sig_id = ss.sid,
                    .env = ss.env,
                    .prop_jsdoc = null,
                });
                mb.deinit(self.scratch);
            }
            if (!is_class) {
                for (construct_sigs) |ss| {
                    const mb = try struct_scope.bind("construct", .camel);
                    try method_slots.append(self.scratch, .{
                        .zig_ident = try self.alloc.dupe(u8, mb.zig_ident),
                        .logical_name = try self.alloc.dupe(u8, mb.logical_name),
                        .wire_name = try self.alloc.dupe(u8, "construct"),
                        .is_static = false,
                        .call_kind = .construct_sig,
                        .sig_id = ss.sid,
                        .env = ss.env,
                        .prop_jsdoc = null,
                    });
                    mb.deinit(self.scratch);
                }
            }

            // 4. Instance property getters / `*Alloc` getters / setters.
            var instance_props: std.ArrayList(InstancePropIr) = .empty;
            for (raw_props) |sp| {
                const pid = sp.pid;
                if (pid >= self.graph.properties.len) continue;
                const p = self.graph.properties[pid];
                if (p.modifiers.private_mod or p.modifiers.protected_mod) continue;
                if (p.modifiers.static_mod) continue;
                if (p.computed_symbol != null) continue;

                const wire = self.str(p.name);
                const access = lower_objects.analyzePropAccess(p);
                if (!access.is_readable and !access.is_writable) continue;

                const prop_active_tps = try self.resolveHeritageActiveTps(
                    sp.env,
                    tp_res.active,
                    self_ident,
                    imports_used,
                    needs_runtime,
                    &env_cache,
                    0,
                );

                var getter_ident: ?[]const u8 = null;
                var getter_alloc_ident: ?[]const u8 = null;
                var getter_ty: ?*const TypeIr = null;
                if (access.is_readable) {
                    const gb = try struct_scope.bind(wire, .camel);
                    getter_ident = try self.alloc.dupe(u8, gb.zig_ident);
                    const getter_logical = try self.scratch.dupe(u8, gb.logical_name);
                    defer self.scratch.free(getter_logical);
                    gb.deinit(self.scratch);

                    visited.clearRetainingCapacity();
                    var gty = try self.lowerType(access.read_ty_id, false, prop_active_tps, self_ident, &visited, imports_used, needs_runtime);
                    if (p.modifiers.optional_mod) gty = try self.wrapOptional(gty);
                    getter_ty = gty;

                    if (try self.typeMayAllocateOnDecode(gty)) {
                        const raw_ga = try std.fmt.allocPrint(self.scratch, "{s}Alloc", .{getter_logical});
                        defer self.scratch.free(raw_ga);
                        const gab = try struct_scope.bind(raw_ga, .camel);
                        getter_alloc_ident = try self.alloc.dupe(u8, gab.zig_ident);
                        gab.deinit(self.scratch);
                    }

                    if (!is_class and !p.modifiers.optional_mod and
                        required_props.items.len < lower_objects.max_required_handle_checks)
                    {
                        const allows_undef = switch (gty.*) {
                            .optional => |opt| opt.nullish_kind != .null_only,
                            .js_any, .js_unknown, .js_value, .void_type => true,
                            else => false,
                        };
                        if (!allows_undef) {
                            var seen_rp = false;
                            for (required_props.items) |existing_rp| {
                                if (std.mem.eql(u8, existing_rp, wire)) {
                                    seen_rp = true;
                                    break;
                                }
                            }
                            if (!seen_rp) {
                                try required_props.append(self.alloc, try self.alloc.dupe(u8, wire));
                            }
                        }
                    }
                }

                var setter_ident: ?[]const u8 = null;
                var setter_ty: ?*const TypeIr = null;
                if (access.is_writable) {
                    const raw_setter = try lower_objects.buildSetterRawName(self.scratch, wire);
                    defer self.scratch.free(raw_setter);
                    const sb = try struct_scope.bind(raw_setter, .camel);
                    setter_ident = try self.alloc.dupe(u8, sb.zig_ident);
                    sb.deinit(self.scratch);

                    if (access.has_divergent_setter) {
                        visited.clearRetainingCapacity();
                        var wty = try self.lowerType(access.write_ty_id, false, prop_active_tps, self_ident, &visited, imports_used, needs_runtime);
                        if (p.modifiers.optional_mod) wty = try self.wrapOptional(wty);
                        setter_ty = wty;
                    } else if (getter_ty) |gty| {
                        setter_ty = gty;
                    } else {
                        visited.clearRetainingCapacity();
                        var wty = try self.lowerType(access.write_ty_id, false, prop_active_tps, self_ident, &visited, imports_used, needs_runtime);
                        if (p.modifiers.optional_mod) wty = try self.wrapOptional(wty);
                        setter_ty = wty;
                    }
                }

                try instance_props.append(self.alloc, .{
                    .wire_name = try self.alloc.dupe(u8, wire),
                    .is_optional = p.modifiers.optional_mod,
                    .getter_ident = getter_ident,
                    .getter_alloc_ident = getter_alloc_ident,
                    .getter_ty = getter_ty,
                    .setter_ident = setter_ident,
                    .setter_ty = setter_ty,
                    .setter_is_optional = p.modifiers.optional_mod,
                    .jsdoc = try self.lowerJsDoc(p.jsdoc),
                });
            }

            // 5. Backing `ref` field (`ref` or `__zigar_ref` when `.ref()` exists) + lifecycle helpers!
            const ref_field_ident = try lower_objects.bindBackingRefFieldIdent(&struct_scope, self.scratch, self.alloc);
            const deinit_ident = try lower_objects.tryBindOptionalHelperIdent(&struct_scope, self.scratch, self.alloc, "deinit");
            const to_js_ref_ident = try lower_objects.tryBindOptionalHelperIdent(&struct_scope, self.scratch, self.alloc, "toJsRef");
            const from_js_ref_ident = try lower_objects.tryBindOptionalHelperIdent(&struct_scope, self.scratch, self.alloc, "fromJsRef");

            // 6. Method `*Alloc` companions (bound AFTER explicit methods/props/helpers, BEFORE `lowerSignature`).
            for (method_slots.items) |*slot| {
                const slot_active_tps = try self.resolveHeritageActiveTps(
                    slot.env,
                    tp_res.active,
                    self_ident,
                    imports_used,
                    needs_runtime,
                    &env_cache,
                    0,
                );
                if (try self.previewSigMayAllocateOnDecode(
                    slot.sig_id,
                    &struct_scope,
                    slot_active_tps,
                    self_ident,
                    imports_used,
                    needs_runtime,
                )) {
                    const raw_alloc = try std.fmt.allocPrint(self.scratch, "{s}Alloc", .{slot.logical_name});
                    defer self.scratch.free(raw_alloc);
                    const ab = try struct_scope.bind(raw_alloc, .camel);
                    slot.alloc_companion_ident = try self.alloc.dupe(u8, ab.zig_ident);
                    ab.deinit(self.scratch);
                }
            }

            // 7. Nested declarations (`merged_ns_consumed` & `merged_generic_ns_peer`) so any newly
            // added sibling aliases are ALSO in `struct_scope` before parameter naming!
            var nested_decls: std.ArrayList(DeclIr) = .empty;
            try self.lowerMergedStructNestedDecls(
                final_mod_idx,
                owner_decl_id,
                merged_ids,
                &struct_scope,
                prebound_names,
                prebound_overloads,
                tp_res.active,
                imports_used,
                needs_runtime,
                &nested_decls,
                active_decls,
            );

            // 8. Now `struct_scope` has EVERY declaration in this struct: lower constructors, methods,
            // and non-shadowing helper/accessor parameter names!
            const self_param_ident = try lower_objects.chooseNonShadowingParamIdent(
                &struct_scope,
                self.scratch,
                self.alloc,
                "self",
            );
            const raw_param_ident = try lower_objects.chooseNonShadowingParamIdent(
                &struct_scope,
                self.scratch,
                self.alloc,
                "raw",
            );
            for (instance_props.items) |*ip| {
                if (ip.getter_alloc_ident != null) {
                    ip.getter_alloc_param_ident = try lower_objects.chooseNonShadowingParamIdent(
                        &struct_scope,
                        self.scratch,
                        self.alloc,
                        "allocator",
                    );
                }
                if (ip.setter_ident != null) {
                    ip.setter_param_ident = try lower_objects.chooseNonShadowingParamIdent(
                        &struct_scope,
                        self.scratch,
                        self.alloc,
                        "value",
                    );
                }
            }

            var ctors = try self.alloc.alloc(ConstructorIr, ctor_count);
            if (synthesize_default_ctor) {
                const alloc_param = try lower_objects.chooseNonShadowingParamIdent(
                    &struct_scope,
                    self.scratch,
                    self.alloc,
                    "allocator",
                );
                ctors[0] = .{
                    .zig_ident = ctor_idents[0],
                    .signature = .{
                        .self_param_ident = null,
                        .alloc_param_ident = alloc_param,
                        .type_params = &.{},
                        .params = &.{},
                        .return_type = try self.makeType(.{ .self_type = self_ident }),
                        .has_type_predicate = false,
                        .type_predicate_asserts = false,
                        .jsdoc = null,
                    },
                    .jsdoc = null,
                };
            } else {
                for (public_ctor_sigs.items, 0..) |ss, idx| {
                    const ctor_active_tps = try self.resolveHeritageActiveTps(
                        ss.env,
                        tp_res.active,
                        self_ident,
                        imports_used,
                        needs_runtime,
                        &env_cache,
                        0,
                    );
                    var c_sig = try self.lowerSignature(ss.sid, &struct_scope, false, ctor_active_tps, self_ident, imports_used, needs_runtime);
                    c_sig.return_type = try self.makeType(.{ .self_type = self_ident });
                    ctors[idx] = .{
                        .zig_ident = ctor_idents[idx],
                        .signature = c_sig,
                        .jsdoc = c_sig.jsdoc,
                    };
                }
            }

            var methods = try self.alloc.alloc(MethodIr, method_slots.items.len);
            for (method_slots.items, 0..) |slot, idx| {
                const slot_active_tps = try self.resolveHeritageActiveTps(
                    slot.env,
                    tp_res.active,
                    self_ident,
                    imports_used,
                    needs_runtime,
                    &env_cache,
                    0,
                );
                const m_sig = try self.lowerSignature(
                    slot.sig_id,
                    &struct_scope,
                    !slot.is_static,
                    slot_active_tps,
                    self_ident,
                    imports_used,
                    needs_runtime,
                );
                methods[idx] = .{
                    .zig_ident = slot.zig_ident,
                    .logical_name = slot.logical_name,
                    .wire_name = slot.wire_name,
                    .alloc_companion_ident = slot.alloc_companion_ident,
                    .is_static = slot.is_static,
                    .call_kind = slot.call_kind,
                    .signature = m_sig,
                    .jsdoc = m_sig.jsdoc orelse slot.prop_jsdoc,
                };
            }

            return .{
                .repr = .handle_wrapper,
                .is_class = is_class,
                .is_abstract = is_abstract,
                .is_callable_handle = is_callable_handle,
                .has_private_constructor = has_private_constructor,
                .has_non_public_members = has_non_public_members,
                .self_ident = self_ident,
                .ref_field_ident = ref_field_ident,
                .self_param_ident = self_param_ident,
                .raw_param_ident = raw_param_ident,
                .to_js_ref_ident = to_js_ref_ident,
                .from_js_ref_ident = from_js_ref_ident,
                .deinit_ident = deinit_ident,
                .required_methods = try required_methods.toOwnedSlice(self.alloc),
                .required_props = try required_props.toOwnedSlice(self.alloc),
                .type_params = tp_res.ir,
                .fields = &.{},
                .instance_props = try instance_props.toOwnedSlice(self.alloc),
                .static_props = try static_props.toOwnedSlice(self.alloc),
                .constructors = ctors,
                .methods = methods,
                .nested_decls = try nested_decls.toOwnedSlice(self.alloc),
            };
        }

        fn lowerMergedStructNestedDecls(
            self: *Self,
            final_mod_idx: u32,
            owner_decl_id: u32,
            merged_ids: []const u32,
            struct_scope: *naming.ScopeNamer,
            prebound_names: *const std.AutoHashMapUnmanaged(u32, naming.BoundName),
            prebound_overloads: *const std.AutoHashMapUnmanaged(u32, []naming.BoundName),
            active_tps: []const ActiveTypeParam,
            imports_used: *std.AutoHashMapUnmanaged(u32, void),
            needs_runtime: *bool,
            nested_decls: *std.ArrayList(DeclIr),
            active_decls: *std.AutoHashMapUnmanaged(u32, void),
        ) error{OutOfMemory}!void {
            for (merged_ids) |mid| {
                if (self.merged_ns_consumed.contains(mid)) {
                    for (self.graph.decls[mid].kind.namespace_decl) |cid| {
                        try self.lowerDeclIntoListInner(
                            final_mod_idx,
                            cid,
                            false,
                            struct_scope,
                            prebound_names,
                            prebound_overloads,
                            active_tps,
                            imports_used,
                            needs_runtime,
                            nested_decls,
                            active_decls,
                        );
                    }
                }
            }

            if (self.merged_generic_ns_peer.get(owner_decl_id)) |ns_peer_id| {
                if (ns_peer_id < self.graph.decls.len and self.graph.decls[ns_peer_id].kind == .namespace_decl) {
                    for (self.graph.decls[ns_peer_id].kind.namespace_decl) |cid| {
                        if (cid >= self.graph.decls.len) continue;
                        const cd = self.graph.decls[cid];
                        if (!cd.modifiers.export_decl) continue;
                        const cloc = (try self.resolveEffectiveReExportTarget(cid, 0)) orelse continue;
                        if (cloc.zig_path.len == 0) continue;
                        const cwire = if (cd.export_name) |esid| self.str(esid) else self.str(cd.name);
                        const cstyle = self.declNameStyle(cd);
                        const desired = switch (cstyle) {
                            .preserve => try self.scratch.dupe(u8, cwire),
                            .camel => try naming.toCamelCase(self.scratch, cwire),
                            .pascal => try naming.toPascalCase(self.scratch, cwire),
                            .snake => try naming.toSnakeCase(self.scratch, cwire),
                        };
                        defer self.scratch.free(desired);
                        if (desired.len == 0 or struct_scope.isTaken(desired)) continue;
                        const ab = try struct_scope.bind(cwire, cstyle);
                        if (cloc.module_index != final_mod_idx) {
                            try imports_used.put(self.scratch, cloc.module_index, {});
                        }
                        try nested_decls.append(self.alloc, .{
                            .source_decl_id = cid,
                            .zig_ident = try self.alloc.dupe(u8, ab.zig_ident),
                            .logical_name = try self.alloc.dupe(u8, ab.logical_name),
                            .wire_name = try self.alloc.dupe(u8, ab.wire_name),
                            .is_exported = true,
                            .is_js_exported = true,
                            .is_default_export = false,
                            .jsdoc = null,
                            .kind = .{
                                .re_export_decl = .{
                                    .target_module_index = cloc.module_index,
                                    .target_zig_path = cloc.zig_path,
                                },
                            },
                        });
                        ab.deinit(self.scratch);
                    }
                }
            }
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
            try self.computeTypeRefCounts();
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
                try ms.reserve("__zigar_args");
                try ms.reserve("__zigar_argc");
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
                    // Do not pre-seed `same_mod_export_equals_children` in `seen_export_wires` before
                    // binding them below as top-level `planned_re_exports`!
                    var is_same_mod_eq_child = false;
                    for (cand.same_mod_export_equals_children.items) |eq_cid| {
                        if (eq_cid == edid) {
                            is_same_mod_eq_child = true;
                            break;
                        }
                    }
                    if (is_same_mod_eq_child) continue;
                    const ed = self.graph.decls[edid];
                    if (ed.modifiers.default_export) continue;
                    const ew = if (ed.export_name) |esid| self.str(esid) else self.str(ed.name);
                    if (ew.len > 0) try seen_export_wires.put(self.scratch, ew, {});
                }

                // Expose exported members of a same-module `export = <namespace>` at module top-level (`H4`)!
                for (cand.same_mod_export_equals_children.items) |eq_cid| {
                    if (eq_cid >= self.graph.decls.len) continue;
                    const sd = self.graph.decls[eq_cid];
                    const loc = (try self.resolveEffectiveReExportTarget(eq_cid, 0)) orelse continue;
                    if (loc.zig_path.len == 0) continue;
                    const export_wire = if (sd.export_name) |esid| self.str(esid) else self.str(sd.name);
                    if (seen_non_default_decls.contains(eq_cid) or seen_export_wires.contains(export_wire)) continue;
                    const style = self.declNameStyle(sd);
                    const desired_styled = switch (style) {
                        .preserve => try self.scratch.dupe(u8, export_wire),
                        .camel => try naming.toCamelCase(self.scratch, export_wire),
                        .pascal => try naming.toPascalCase(self.scratch, export_wire),
                        .snake => try naming.toSnakeCase(self.scratch, export_wire),
                    };
                    defer self.scratch.free(desired_styled);
                    const base_check = if (desired_styled.len == 0) "_empty" else desired_styled;
                    if (ms.isTaken(base_check)) continue;
                    try seen_non_default_decls.put(self.scratch, eq_cid, {});
                    if (export_wire.len > 0) try seen_export_wires.put(self.scratch, export_wire, {});

                    const sb = try ms.bind(export_wire, style);
                    try planned_re_exports[final_i].append(self.scratch, .{
                        .source_decl_id = eq_cid,
                        .zig_ident = try self.alloc.dupe(u8, sb.zig_ident),
                        .logical_name = try self.alloc.dupe(u8, sb.logical_name),
                        .wire_name = try self.alloc.dupe(u8, sb.wire_name),
                        .is_default_export = false,
                        .target_module_index = loc.module_index,
                        .target_zig_path = loc.zig_path,
                    });
                    sb.deinit(self.scratch);
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
                self.cur_mod_idx = final_mod_idx;
                self.cur_mod_hoisted_locs.clearRetainingCapacity();
                self.cur_mod_closed_types.clearRetainingCapacity();
                self.cur_mod_decls_out = &decl_irs;
                self.cur_mod_root_scope = ms;
                self.cur_mod_anon_counter = 0;
                self.inline_anon_depth = 0;
                defer {
                    self.cur_mod_decls_out = null;
                    self.cur_mod_root_scope = null;
                }

                for (cand.decl_ids.items) |did| {
                    try self.lowerDeclIntoList(
                        final_mod_idx,
                        did,
                        true,
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
                    if (pre.target_module_index != final_mod_idx) {
                        try imports_used.put(self.scratch, pre.target_module_index, {});
                    }
                    const is_pure_eq_ns = self.pure_export_equals_ns.contains(pre.source_decl_id);
                    try decl_irs.append(self.alloc, .{
                        .source_decl_id = pre.source_decl_id,
                        .zig_ident = pre.zig_ident,
                        .logical_name = pre.logical_name,
                        .wire_name = pre.wire_name,
                        .is_exported = true,
                        .is_js_exported = !is_pure_eq_ns,
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

                try deduplicateDeclIrsInPlace(self.scratch, &decl_irs);

                var export_equals_ident: ?[]const u8 = null;
                var export_equals_wire_name: ?[]const u8 = null;
                if (cand.export_equals_decl_id) |eq_did| {
                    for (decl_irs.items) |di| {
                        if (di.source_decl_id == eq_did) {
                            export_equals_ident = di.zig_ident;
                            export_equals_wire_name = di.wire_name;
                            break;
                        }
                    }
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
                    .export_equals_ident = export_equals_ident,
                    .export_equals_wire_name = export_equals_wire_name,
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

fn deduplicateDeclIrsInPlace(scratch: std.mem.Allocator, list: *std.ArrayList(DeclIr)) error{OutOfMemory}!void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(scratch);
    var write_idx: usize = 0;
    for (list.items) |item| {
        const gop = try seen.getOrPut(scratch, item.zig_ident);
        if (!gop.found_existing) {
            list.items[write_idx] = item;
            write_idx += 1;
        }
    }
    list.items.len = write_idx;
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
    if (prefix.len >= 64) return;
    for (decls) |*d| {
        const key = try formatDeclCycleKey(allocator, mod_idx, prefix, d.zig_ident);
        const gop = try map.getOrPut(allocator, key);
        if (gop.found_existing) {
            allocator.free(key);
            continue;
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
            if (st.repr == .value_struct) {
                for (st.fields) |f| {
                    try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(f.ty), decl_map, state);
                }
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
        .optional => |opt| {
            try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(opt.child), decl_map, state);
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
        .tagged_union => |tu| {
            for (tu.variants) |v| {
                try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(v.payload), decl_map, state);
            }
        },
        .decl_ref => {
            if (ty.decl_ref.indirect) return;
            const target_key = try formatDeclCycleKey(state_alloc, ty.decl_ref.module_index, ty.decl_ref.decl_zig_path, null);
            defer state_alloc.free(target_key);
            const cur_state = state.get(target_key);
            if (cur_state) |st| {
                if (st == 1) {
                    // Cycle back-edge detected! Mutate `ty.decl_ref` directly in place (`*const Target`).
                    ty.decl_ref.indirect = true;
                    return;
                }
            }
            if (decl_map.get(target_key)) |target_decl| {
                if (ty.decl_ref.type_args.len > 0) {
                    const tps = switch (target_decl.kind) {
                        .type_alias => |ta| ta.type_params,
                        .struct_decl => |st_decl| st_decl.type_params,
                        .union_decl => |un_decl| un_decl.type_params,
                        else => &[_]TypeParamIr{},
                    };
                    for (ty.decl_ref.type_args, 0..) |arg_ty, idx| {
                        const by_val = if (idx < tps.len)
                            declUsesTypeParamByValue(state_alloc, target_decl, tps[idx].zig_ident, decl_map, 0)
                        else
                            false;
                        if (by_val) {
                            try dfsValueCycleTypeByPath(state_alloc, ir_alloc, @constCast(arg_ty), decl_map, state);
                        }
                    }
                }
                if (cur_state == null) {
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
            }
        },
        else => {},
    }
}

fn declUsesTypeParamByValue(
    state_alloc: std.mem.Allocator,
    d: *const DeclIr,
    tp_ident: []const u8,
    decl_map: *const std.StringHashMapUnmanaged(*DeclIr),
    depth: usize,
) bool {
    if (depth >= 16) return true;
    return switch (d.kind) {
        .type_alias => |ta| typeUsesParamByValue(state_alloc, ta.target, tp_ident, decl_map, depth + 1),
        .struct_decl => |st| blk: {
            for (st.fields) |f| {
                if (typeUsesParamByValue(state_alloc, f.ty, tp_ident, decl_map, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .union_decl => |un| blk: {
            for (un.variants) |v| {
                if (typeUsesParamByValue(state_alloc, v.payload, tp_ident, decl_map, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn typeUsesParamByValue(
    state_alloc: std.mem.Allocator,
    ty: *const TypeIr,
    tp_ident: []const u8,
    decl_map: *const std.StringHashMapUnmanaged(*DeclIr),
    depth: usize,
) bool {
    if (depth >= 16) return true;
    return switch (ty.*) {
        .slice, .pointer_const, .fn_ptr, .promise, .js_map => false,
        .type_param_ref => |id| std.mem.eql(u8, id, tp_ident),
        .optional => |opt| typeUsesParamByValue(state_alloc, opt.child, tp_ident, decl_map, depth + 1),
        .tuple => |elems| blk: {
            for (elems) |el| {
                if (!el.is_variadic and typeUsesParamByValue(state_alloc, el.ty, tp_ident, decl_map, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .anon_struct => |fields| blk: {
            for (fields) |f| {
                if (typeUsesParamByValue(state_alloc, f.ty, tp_ident, decl_map, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .tagged_union => |tu| blk: {
            for (tu.variants) |v| {
                if (typeUsesParamByValue(state_alloc, v.payload, tp_ident, decl_map, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .decl_ref => |dr| blk: {
            if (dr.indirect or dr.type_args.len == 0) break :blk false;
            const target_key = formatDeclCycleKey(state_alloc, dr.module_index, dr.decl_zig_path, null) catch break :blk true;
            defer state_alloc.free(target_key);
            if (decl_map.get(target_key)) |td| {
                const tps = switch (td.kind) {
                    .type_alias => |ta| ta.type_params,
                    .struct_decl => |st_decl| st_decl.type_params,
                    .union_decl => |un_decl| un_decl.type_params,
                    else => &[_]TypeParamIr{},
                };
                for (dr.type_args, 0..) |arg_ty, idx| {
                    if (idx < tps.len and
                        declUsesTypeParamByValue(state_alloc, td, tps[idx].zig_ident, decl_map, depth + 1) and
                        typeUsesParamByValue(state_alloc, arg_ty, tp_ident, decl_map, depth + 1))
                    {
                        break :blk true;
                    }
                }
                break :blk false;
            }
            for (dr.type_args) |arg_ty| {
                if (typeUsesParamByValue(state_alloc, arg_ty, tp_ident, decl_map, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
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
