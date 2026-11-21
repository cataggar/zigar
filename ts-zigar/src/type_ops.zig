const std = @import("std");

/// Standard TypeScript built-in utility types (`lib.es5.d.ts` .. `lib.es2024.d.ts`).
pub const BuiltinUtilityKind = enum {
    partial,
    required,
    readonly_type,
    pick,
    omit,
    record,
    exclude,
    extract,
    non_nullable,
    parameters,
    constructor_parameters,
    return_type,
    instance_type,
    this_parameter_type,
    omit_this_parameter,
    awaited,
    no_infer,
    uppercase,
    lowercase,
    capitalize,
    uncapitalize,
};

/// Classifies an unqualified TypeScript standard utility reference by name and arity.
pub fn classifyBuiltinUtility(raw_name: []const u8, arity: usize) ?BuiltinUtilityKind {
    if (arity == 1) {
        if (std.mem.eql(u8, raw_name, "Partial")) return .partial;
        if (std.mem.eql(u8, raw_name, "Required")) return .required;
        if (std.mem.eql(u8, raw_name, "Readonly")) return .readonly_type;
        if (std.mem.eql(u8, raw_name, "NonNullable")) return .non_nullable;
        if (std.mem.eql(u8, raw_name, "Parameters")) return .parameters;
        if (std.mem.eql(u8, raw_name, "ConstructorParameters")) return .constructor_parameters;
        if (std.mem.eql(u8, raw_name, "ReturnType")) return .return_type;
        if (std.mem.eql(u8, raw_name, "InstanceType")) return .instance_type;
        if (std.mem.eql(u8, raw_name, "ThisParameterType")) return .this_parameter_type;
        if (std.mem.eql(u8, raw_name, "OmitThisParameter")) return .omit_this_parameter;
        if (std.mem.eql(u8, raw_name, "Awaited")) return .awaited;
        if (std.mem.eql(u8, raw_name, "NoInfer")) return .no_infer;
        if (std.mem.eql(u8, raw_name, "Uppercase")) return .uppercase;
        if (std.mem.eql(u8, raw_name, "Lowercase")) return .lowercase;
        if (std.mem.eql(u8, raw_name, "Capitalize")) return .capitalize;
        if (std.mem.eql(u8, raw_name, "Uncapitalize")) return .uncapitalize;
    } else if (arity == 2) {
        if (std.mem.eql(u8, raw_name, "Pick")) return .pick;
        if (std.mem.eql(u8, raw_name, "Omit")) return .omit;
        if (std.mem.eql(u8, raw_name, "Record")) return .record;
        if (std.mem.eql(u8, raw_name, "Exclude")) return .exclude;
        if (std.mem.eql(u8, raw_name, "Extract")) return .extract;
    }
    return null;
}

/// Unary comptime type transformers backed by `__zigar_js.<Op>(T)`.
pub const UnaryTypeOp = enum {
    partial,
    required,
    readonly_type,
    non_nullable,
    awaited,
    keyof,
    infer_callback_promise_payload,
    instance_type,
    parameters,
    return_type,
    constructor_parameters,
    constructor_of,

    pub fn runtimeHelperName(self: UnaryTypeOp) []const u8 {
        return switch (self) {
            .partial => "Partial",
            .required => "Required",
            .readonly_type => "Readonly",
            .non_nullable => "NonNullable",
            .awaited => "Awaited",
            .keyof => "KeyOf",
            .infer_callback_promise_payload => "InferCallbackPromisePayload",
            .instance_type => "InstanceType",
            .parameters => "Parameters",
            .return_type => "ReturnType",
            .constructor_parameters => "ConstructorParameters",
            .constructor_of => "ConstructorOf",
        };
    }
};

/// Key-filtering comptime type transformers (`__zigar_js.Pick` / `__zigar_js.Omit`).
pub const KeyFilterKind = enum {
    pick,
    omit,

    pub fn runtimeHelperName(self: KeyFilterKind) []const u8 {
        return switch (self) {
            .pick => "Pick",
            .omit => "Omit",
        };
    }
};

/// Optionality modifier on an open mapped type (`?`, `-?`, or unmodified).
pub const OpenMappedOptionalMod = enum {
    none,
    add,
    remove,
};

/// Recognized pattern for an open generic mapped type `{ [P in Constraint]: Value }`.
pub const OpenMappedPattern = union(enum) {
    /// `{ [P in keyof T]+?: T[P] }` -> `Partial(T)`
    homomorphic_partial: u32,
    /// `{ [P in keyof T]-?: T[P] }` -> `Required(T)`
    homomorphic_required: u32,
    /// `{ +readonly [P in keyof T]: T[P] }` or `{ [P in keyof T]: T[P] }` -> `Readonly(T)`
    homomorphic_readonly: u32,
    /// `{ [P in keyof T] (?|-?|<none>): V }` where `name_type == null` and `V` does not depend on `P`
    /// -> `MappedValues(T, V)` (composed with `Partial(...)` for `.add` or `Required(...)` for `.remove`).
    homomorphic_mapped_values: struct {
        target_obj_id: u32,
        value_ty: u32,
        optional_mod: OpenMappedOptionalMod,
    },
    /// `{ [P in K] (?|<none>): V }` where `name_type == null`, `K` is not `keyof T`, and `V` does not depend on `P`
    /// -> `Record(K, V)` (composed with `Partial(...)` when `make_partial` is true).
    uniform_record: struct {
        key_ty: u32,
        value_ty: u32,
        make_partial: bool,
    },
    /// Arbitrary key-remapped or dependent mapped type that requires concrete instantiation.
    dynamic_object,
};

/// Inspects an open `mapped_type_data` node in `graph` to recognize homomorphic
/// `Partial<T>` / `Required<T>` / `Readonly<T>` / `MappedValues<T, V>` or uniform `Record<K, V>` shapes!
/// Generic over `graph` and `mp` so both `wasm32` and `wasm64` WIT bindings share the logic.
pub fn recognizeOpenMappedPattern(
    graph: anytype,
    mp: anytype,
    value_mentions_loop_tp: bool,
) OpenMappedPattern {
    // Key-remapped mapped types (`[P in K as NewKey<P>]: ...`) cannot be represented as simple Record/Partial
    // when open unless instantiated by the TypeScript checker.
    if (mp.name_type != null) return .dynamic_object;

    if (mp.type_param >= graph.type_params.len) return .dynamic_object;
    const loop_tp = graph.type_params[mp.type_param];
    const constraint_id = loop_tp.constraint orelse return .dynamic_object;
    if (constraint_id >= graph.types.len) return .dynamic_object;

    // Check homomorphic `[P in keyof T]: ...`:
    if (graph.types[constraint_id].kind == .keyof_type) {
        const target_obj_id = graph.types[constraint_id].kind.keyof_type;
        if (mp.value_type < graph.types.len and graph.types[mp.value_type].kind == .indexed_access) {
            const ia = graph.types[mp.value_type].kind.indexed_access;
            if (sameTypeNodeOrTypeParam(graph, ia.object_ty, target_obj_id) and
                typeNodeMatchesTypeParam(graph, ia.index_ty, mp.type_param))
            {
                if (mp.optional_modifier == .add) return .{ .homomorphic_partial = target_obj_id };
                if (mp.optional_modifier == .remove) return .{ .homomorphic_required = target_obj_id };
                return .{ .homomorphic_readonly = target_obj_id };
            }
        }
        if (!value_mentions_loop_tp) {
            return .{
                .homomorphic_mapped_values = .{
                    .target_obj_id = target_obj_id,
                    .value_ty = mp.value_type,
                    .optional_mod = switch (mp.optional_modifier) {
                        .add => .add,
                        .remove => .remove,
                        .none => .none,
                    },
                },
            };
        }
        return .dynamic_object;
    }

    // Check uniform `{ [P in K]: V }` where `V` does not reference loop type param `P`.
    if (!value_mentions_loop_tp) {
        return .{
            .uniform_record = .{
                .key_ty = constraint_id,
                .value_ty = mp.value_type,
                .make_partial = (mp.optional_modifier == .add),
            },
        };
    }

    return .dynamic_object;
}

/// Inspects an open `conditional_type_data` node (`Check extends Extends ? True : False`)
/// for canonical TypeScript type-level idioms (`NonNullable<T>`, `Awaited<T>`, `IfEventMap`,
/// guarded indexed access `K extends keyof Obj ? Obj[K] : Fallback`, and `PipelineResult<S>`).
pub const OpenConditionalPattern = union(enum) {
    /// `T extends null | undefined ? never : T` or `T extends {} ? T : never`
    non_nullable: u32,
    /// `T extends Promise<infer U> ? U : T` or `T extends PromiseLike<infer U> ? U : T`
    awaited: u32,
    /// `{} extends Target ? True : False` (e.g. Node `IfEventMap<Events, True, False>`)
    empty_object_extends: struct {
        target_ty: u32,
        true_ty: u32,
        false_ty: u32,
    },
    /// `K extends keyof Obj ? Obj[K] : Fallback` (e.g. Node `Args<T, E>` / `Listener<T, E>`)
    conditional_index_access: struct {
        object_ty: u32,
        key_ty: u32,
        fallback_ty: u32,
    },
    /// `S extends (...args: any[]) => PromiseLike<infer R> ? Promise<R> : Promise<void>` (`PipelineResult<S>`)
    conditional_promise_return: u32,
    /// Uninstantiated general conditional type.
    dynamic_any,
};

pub fn recognizeOpenConditionalPattern(
    graph: anytype,
    cond: anytype,
) OpenConditionalPattern {
    // Pattern 1: `Check extends (null | undefined) ? never : Check`
    if (cond.true_type < graph.types.len and graph.types[cond.true_type].kind == .never_type and
        sameTypeNodeOrTypeParam(graph, cond.check_type, cond.false_type) and
        isPureNullishTypeNode(graph, cond.extends_type))
    {
        return .{ .non_nullable = cond.check_type };
    }

    // Pattern 2: `Check extends {} ? Check : never`
    if (cond.false_type < graph.types.len and graph.types[cond.false_type].kind == .never_type and
        sameTypeNodeOrTypeParam(graph, cond.check_type, cond.true_type) and
        isEmptyNonNullishObjectConstraint(graph, cond.extends_type))
    {
        return .{ .non_nullable = cond.check_type };
    }

    // Pattern 3: `Check extends Promise<infer U> ? U : Check` / `PromiseLike<infer U>`
    if (@hasField(@TypeOf(cond), "infer_params") and cond.infer_params.len == 1 and
        sameTypeNodeOrTypeParam(graph, cond.check_type, cond.false_type))
    {
        const infer_tp_id = cond.infer_params[0];
        if (typeNodeMatchesTypeParam(graph, cond.true_type, infer_tp_id) and
            cond.extends_type < graph.types.len)
        {
            const ek = graph.types[cond.extends_type].kind;
            if (@hasField(@TypeOf(ek), "reference") and ek == .reference) {
                const er = ek.reference;
                if (er.target_decl == null and er.type_args.len == 1 and
                    typeNodeMatchesTypeParam(graph, er.type_args[0], infer_tp_id) and
                    @hasField(@TypeOf(graph), "strings") and er.target_name < graph.strings.len)
                {
                    const tname = graph.strings[er.target_name];
                    if (std.mem.eql(u8, tname, "Promise") or std.mem.eql(u8, tname, "PromiseLike")) {
                        return .{ .awaited = cond.check_type };
                    }
                }
            }
        }
    }

    // Pattern 4: `{} extends Target ? True : False` (`IfEventMap<Events, True, False>`)
    if (isEmptyNonNullishObjectConstraint(graph, cond.check_type) and
        cond.extends_type < graph.types.len)
    {
        const ext_k = graph.types[cond.extends_type].kind;
        if (ext_k == .type_param or (@hasField(@TypeOf(ext_k), "reference") and ext_k == .reference)) {
            return .{ .empty_object_extends = .{
                .target_ty = cond.extends_type,
                .true_ty = cond.true_type,
                .false_ty = cond.false_type,
            } };
        }
    }

    // Pattern 5: `K extends keyof Obj ? Obj[K] : Fallback`
    if (cond.extends_type < graph.types.len and cond.true_type < graph.types.len) {
        const ext_k = graph.types[cond.extends_type].kind;
        const true_k = graph.types[cond.true_type].kind;
        if (@hasField(@TypeOf(ext_k), "keyof_type") and ext_k == .keyof_type and
            @hasField(@TypeOf(true_k), "indexed_access") and true_k == .indexed_access)
        {
            const ia = true_k.indexed_access;
            if (sameTypeNodeOrTypeParam(graph, ia.object_ty, ext_k.keyof_type) and
                sameTypeNodeOrTypeParam(graph, ia.index_ty, cond.check_type))
            {
                return .{ .conditional_index_access = .{
                    .object_ty = ia.object_ty,
                    .key_ty = ia.index_ty,
                    .fallback_ty = cond.false_type,
                } };
            }
        }
    }

    // Pattern 6: `S extends (...args: any[]) => PromiseLike<infer R> ? Promise<R> : Promise<void>` (`PipelineResult<S>`)
    if (@hasField(@TypeOf(cond), "infer_params") and cond.infer_params.len == 1 and
        cond.extends_type < graph.types.len)
    {
        const infer_tp_id = cond.infer_params[0];
        const ext_k = graph.types[cond.extends_type].kind;
        if (@hasField(@TypeOf(ext_k), "function_type") and ext_k == .function_type and
            @hasField(@TypeOf(graph), "signatures") and ext_k.function_type < graph.signatures.len)
        {
            const ext_sig = graph.signatures[ext_k.function_type];
            const ext_ret_arg = unwrapPromiseLikeArg(graph, ext_sig.return_type);
            const true_prom_arg = unwrapExactPromiseArg(graph, cond.true_type);
            const false_prom_arg = unwrapExactPromiseArg(graph, cond.false_type);
            if (ext_ret_arg != null and true_prom_arg != null and false_prom_arg != null and
                typeNodeMatchesTypeParam(graph, ext_ret_arg.?, infer_tp_id) and
                typeNodeMatchesTypeParam(graph, true_prom_arg.?, infer_tp_id) and
                false_prom_arg.? < graph.types.len and graph.types[false_prom_arg.?].kind == .void_type)
            {
                return .{ .conditional_promise_return = cond.check_type };
            }
        }
    }

    return .dynamic_any;
}

fn unwrapPromiseLikeArg(graph: anytype, tid: u32) ?u32 {
    if (tid >= graph.types.len) return null;
    const k = graph.types[tid].kind;
    if (@hasField(@TypeOf(k), "reference") and k == .reference and
        @hasField(@TypeOf(graph), "strings"))
    {
        const r = k.reference;
        if (r.type_args.len == 1 and r.target_name < graph.strings.len) {
            const tname = graph.strings[r.target_name];
            if (std.mem.eql(u8, tname, "Promise") or std.mem.eql(u8, tname, "PromiseLike")) {
                return r.type_args[0];
            }
        }
    }
    return null;
}

fn unwrapExactPromiseArg(graph: anytype, tid: u32) ?u32 {
    if (tid >= graph.types.len) return null;
    const k = graph.types[tid].kind;
    if (@hasField(@TypeOf(k), "reference") and k == .reference and
        @hasField(@TypeOf(graph), "strings"))
    {
        const r = k.reference;
        if (r.type_args.len == 1 and r.target_name < graph.strings.len) {
            const tname = graph.strings[r.target_name];
            if (std.mem.eql(u8, tname, "Promise")) {
                return r.type_args[0];
            }
        }
    }
    return null;
}

pub fn typeNodeMatchesTypeParam(graph: anytype, tid: u32, tp_id: u32) bool {
    if (tid >= graph.types.len) return false;
    const k = graph.types[tid].kind;
    if (k == .type_param) return k.type_param == tp_id;
    if (@hasField(@TypeOf(k), "infer_type") and k == .infer_type) return k.infer_type == tp_id;
    if (@hasField(@TypeOf(k), "reference") and k == .reference and
        @hasField(@TypeOf(graph), "type_params") and tp_id < graph.type_params.len)
    {
        const r = k.reference;
        return r.target_decl == null and r.type_args.len == 0 and r.target_name == graph.type_params[tp_id].name;
    }
    return false;
}

fn sameTypeNodeOrTypeParam(graph: anytype, a: u32, b: u32) bool {
    if (a == b) return true;
    if (a >= graph.types.len or b >= graph.types.len) return false;
    const ka = graph.types[a].kind;
    const kb = graph.types[b].kind;
    if (ka == .type_param and kb == .type_param) {
        return ka.type_param == kb.type_param;
    }
    if (@hasField(@TypeOf(ka), "reference")) {
        if (ka == .reference and kb == .reference) {
            const ra = ka.reference;
            const rb = kb.reference;
            return ra.target_decl == rb.target_decl and
                ra.target_name == rb.target_name and
                ra.type_args.len == 0 and rb.type_args.len == 0;
        }
        if (ka == .type_param and kb == .reference) {
            return typeNodeMatchesTypeParam(graph, b, ka.type_param);
        }
        if (ka == .reference and kb == .type_param) {
            return typeNodeMatchesTypeParam(graph, a, kb.type_param);
        }
    }
    return false;
}

fn isPureNullishTypeNode(graph: anytype, tid: u32) bool {
    if (tid >= graph.types.len) return false;
    return switch (graph.types[tid].kind) {
        .null_type, .undefined_type, .void_type => true,
        .union_type => |arms| blk: {
            if (arms.len == 0) break :blk false;
            for (arms) |arm| {
                if (!isPureNullishTypeNode(graph, arm)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn isEmptyNonNullishObjectConstraint(graph: anytype, tid: u32) bool {
    if (tid >= graph.types.len) return false;
    return switch (graph.types[tid].kind) {
        .object_literal => |obj| obj.properties.len == 0 and
            obj.call_signatures.len == 0 and
            obj.construct_signatures.len == 0 and
            obj.index_signatures.len == 0,
        else => false,
    };
}

/// Applies TypeScript's string-mapping intrinsics (`Uppercase`, `Lowercase`, `Capitalize`, `Uncapitalize`)
/// in pure Zig when evaluating literal strings directly without checker expansion.
pub fn applyStringIntrinsicAscii(
    allocator: std.mem.Allocator,
    kind: BuiltinUtilityKind,
    input: []const u8,
) error{OutOfMemory}![]u8 {
    const out = try allocator.dupe(u8, input);
    switch (kind) {
        .uppercase => {
            for (out) |*ch| ch.* = std.ascii.toUpper(ch.*);
        },
        .lowercase => {
            for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
        },
        .capitalize => {
            if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
        },
        .uncapitalize => {
            if (out.len > 0) out[0] = std.ascii.toLower(out[0]);
        },
        else => {},
    }
    return out;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "classifyBuiltinUtility matches standard TypeScript utility names and arities" {
    try std.testing.expectEqual(BuiltinUtilityKind.partial, classifyBuiltinUtility("Partial", 1).?);
    try std.testing.expectEqual(BuiltinUtilityKind.required, classifyBuiltinUtility("Required", 1).?);
    try std.testing.expectEqual(BuiltinUtilityKind.readonly_type, classifyBuiltinUtility("Readonly", 1).?);
    try std.testing.expectEqual(BuiltinUtilityKind.pick, classifyBuiltinUtility("Pick", 2).?);
    try std.testing.expectEqual(BuiltinUtilityKind.omit, classifyBuiltinUtility("Omit", 2).?);
    try std.testing.expectEqual(BuiltinUtilityKind.record, classifyBuiltinUtility("Record", 2).?);
    try std.testing.expectEqual(BuiltinUtilityKind.exclude, classifyBuiltinUtility("Exclude", 2).?);
    try std.testing.expectEqual(BuiltinUtilityKind.extract, classifyBuiltinUtility("Extract", 2).?);
    try std.testing.expectEqual(BuiltinUtilityKind.non_nullable, classifyBuiltinUtility("NonNullable", 1).?);
    try std.testing.expectEqual(BuiltinUtilityKind.return_type, classifyBuiltinUtility("ReturnType", 1).?);
    try std.testing.expectEqual(BuiltinUtilityKind.parameters, classifyBuiltinUtility("Parameters", 1).?);
    try std.testing.expectEqual(BuiltinUtilityKind.awaited, classifyBuiltinUtility("Awaited", 1).?);
    try std.testing.expectEqual(BuiltinUtilityKind.no_infer, classifyBuiltinUtility("NoInfer", 1).?);
    try std.testing.expectEqual(BuiltinUtilityKind.uppercase, classifyBuiltinUtility("Uppercase", 1).?);
    try std.testing.expect(classifyBuiltinUtility("Pick", 1) == null);
    try std.testing.expect(classifyBuiltinUtility("Partial", 2) == null);
    try std.testing.expect(classifyBuiltinUtility("UserDefined", 1) == null);
}

test "applyStringIntrinsicAscii transforms literal strings" {
    const alloc = std.testing.allocator;

    const up = try applyStringIntrinsicAscii(alloc, .uppercase, "helloWorld");
    defer alloc.free(up);
    try std.testing.expectEqualStrings("HELLOWORLD", up);

    const low = try applyStringIntrinsicAscii(alloc, .lowercase, "HelloWorld");
    defer alloc.free(low);
    try std.testing.expectEqualStrings("helloworld", low);

    const cap = try applyStringIntrinsicAscii(alloc, .capitalize, "hello");
    defer alloc.free(cap);
    try std.testing.expectEqualStrings("Hello", cap);

    const uncap = try applyStringIntrinsicAscii(alloc, .uncapitalize, "Hello");
    defer alloc.free(uncap);
    try std.testing.expectEqualStrings("hello", uncap);
}

test "recognizeOpenMappedPattern and recognizeOpenConditionalPattern detect homomorphic and NonNullable idioms" {
    const MockModifier = enum { none, add, remove };
    const MockIndexedAccess = struct { object_ty: u32, index_ty: u32 };
    const MockObjLit = struct {
        properties: []const u32 = &.{},
        call_signatures: []const u32 = &.{},
        construct_signatures: []const u32 = &.{},
        index_signatures: []const u32 = &.{},
    };
    const MockKind = union(enum) {
        type_param: u32,
        keyof_type: u32,
        indexed_access: MockIndexedAccess,
        null_type,
        undefined_type,
        void_type,
        never_type,
        string_type,
        union_type: []const u32,
        object_literal: MockObjLit,
    };
    const MockTypeNode = struct { kind: MockKind };
    const MockTypeParam = struct { constraint: ?u32 };
    const MockGraph = struct {
        types: []const MockTypeNode,
        type_params: []const MockTypeParam,
    };
    const MockMapped = struct {
        type_param: u32,
        name_type: ?u32,
        value_type: u32,
        readonly_modifier: MockModifier,
        optional_modifier: MockModifier,
    };
    const MockCond = struct {
        check_type: u32,
        extends_type: u32,
        true_type: u32,
        false_type: u32,
    };

    const null_undef = [_]u32{ 4, 5 };
    const types = [_]MockTypeNode{
        .{ .kind = .{ .type_param = 0 } }, // 0: T
        .{ .kind = .{ .keyof_type = 0 } }, // 1: keyof T
        .{ .kind = .{ .type_param = 1 } }, // 2: P
        .{ .kind = .{ .indexed_access = .{ .object_ty = 0, .index_ty = 2 } } }, // 3: T[P]
        .{ .kind = .null_type }, // 4: null
        .{ .kind = .undefined_type }, // 5: undefined
        .{ .kind = .{ .union_type = &null_undef } }, // 6: null | undefined
        .{ .kind = .never_type }, // 7: never
        .{ .kind = .string_type }, // 8: string
    };
    const tps = [_]MockTypeParam{
        .{ .constraint = null }, // 0: T
        .{ .constraint = 1 }, // 1: P extends keyof T
        .{ .constraint = 8 }, // 2: K extends string
    };
    const graph = MockGraph{ .types = &types, .type_params = &tps };

    const partial_pat = recognizeOpenMappedPattern(&graph, MockMapped{
        .type_param = 1,
        .name_type = null,
        .value_type = 3,
        .readonly_modifier = .none,
        .optional_modifier = .add,
    }, true);
    try std.testing.expectEqual(@as(u32, 0), partial_pat.homomorphic_partial);

    const required_pat = recognizeOpenMappedPattern(&graph, MockMapped{
        .type_param = 1,
        .name_type = null,
        .value_type = 3,
        .readonly_modifier = .none,
        .optional_modifier = .remove,
    }, true);
    try std.testing.expectEqual(@as(u32, 0), required_pat.homomorphic_required);

    const rec_pat = recognizeOpenMappedPattern(&graph, MockMapped{
        .type_param = 2,
        .name_type = null,
        .value_type = 0,
        .readonly_modifier = .none,
        .optional_modifier = .none,
    }, false);
    try std.testing.expectEqual(@as(u32, 8), rec_pat.uniform_record.key_ty);
    try std.testing.expectEqual(@as(u32, 0), rec_pat.uniform_record.value_ty);
    try std.testing.expect(!rec_pat.uniform_record.make_partial);

    const hom_val_pat = recognizeOpenMappedPattern(&graph, MockMapped{
        .type_param = 1,
        .name_type = null,
        .value_type = 8,
        .readonly_modifier = .none,
        .optional_modifier = .none,
    }, false);
    try std.testing.expectEqual(@as(u32, 0), hom_val_pat.homomorphic_mapped_values.target_obj_id);
    try std.testing.expectEqual(@as(u32, 8), hom_val_pat.homomorphic_mapped_values.value_ty);
    try std.testing.expectEqual(OpenMappedOptionalMod.none, hom_val_pat.homomorphic_mapped_values.optional_mod);

    const non_null_pat = recognizeOpenConditionalPattern(&graph, MockCond{
        .check_type = 0,
        .extends_type = 6,
        .true_type = 7,
        .false_type = 0,
    });
    try std.testing.expectEqual(@as(u32, 0), non_null_pat.non_nullable);
}

