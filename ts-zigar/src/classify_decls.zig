//! Automatic declaration classification for Milestone 3.2a (`#48`):
//! Plain Data / Options Value Structs vs Handle-Backed Stateful Interfaces & Classes.
//!
//! Rules:
//! 1. **Handle-Backed Wrappers (`.handle_wrapper`)**:
//!    - Every `class` and `abstract class` declaration (`is_class = true`).
//!    - Every `interface` merged with a `class`, `function`, or constructable `var` (`interface URL` +
//!      `declare var URL: { prototype: URL; new(...): URL }` -> `is_class = true`).
//!    - Every `interface` (or `type Foo = { ... }` object-literal alias) with:
//!      - methods (`iface.methods.len > 0`),
//!      - `call_signatures` or `construct_signatures`,
//!      - `get` / `set` / `accessor` properties (`has_getter`, `has_setter`, `accessor_mod`),
//!      - non-public / `#private` brand members (`private_mod`, `protected_mod`, `__zigar_private_brand`), or
//!      - transitive `extends` heritage reaching a `class` or `.handle_wrapper` declaration.
//! 2. **Plain Data / Options Structs (`.value_struct`)**:
//!    - Pure structural property-only non-class `interface`s and `{ ... }` object-literal aliases
//!      (including `readonly` data fields, optional fields defaulting to `= null`, callback property
//!      fields `onConnect?: () => void`, merged type-only `namespace`s, and `extends` chains of other
//!      plain `.value_struct` interfaces).

const std = @import("std");

pub const ObjectDeclKind = enum {
    value_struct,
    handle_wrapper,
};

pub const CompanionCtorMembers = struct {
    construct_sigs: []const u32 = &.{},
    static_props: []const u32 = &.{},
};

pub const DeclClassification = struct {
    kind: ObjectDeclKind = .value_struct,
    /// True when backed by a runtime JS constructor (`class` or `interface` + constructable `var`),
    /// enabling `ctor_target` resolution for `Reflect.construct` and `instanceof` checks.
    is_class: bool = false,
    /// True when the handle itself is a callable or constructable JS `function` value
    /// (`call_signatures` on an interface, or standalone `construct_signatures` without `is_class`).
    is_callable_handle: bool = false,
    /// When `interface Foo` merges with `declare var Foo: { new(...): Foo; ... }`, holds that `var_decl` ID.
    companion_var_decl_id: ?u32 = null,
};

pub fn Classifier(comptime Graph: type) type {
    return struct {
        const Self = @This();

        const VisitState = enum(u8) {
            visiting,
            done,
        };

        graph: *const Graph,
        alloc: std.mem.Allocator,
        state: std.AutoHashMapUnmanaged(u32, VisitState) = .empty,
        memo: std.AutoHashMapUnmanaged(u32, DeclClassification) = .empty,

        pub fn init(alloc: std.mem.Allocator, graph: *const Graph) Self {
            return .{
                .graph = graph,
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            self.state.deinit(self.alloc);
            self.memo.deinit(self.alloc);
        }

        fn str(self: *const Self, sid: u32) []const u8 {
            return if (sid < self.graph.strings.len) self.graph.strings[sid] else "";
        }

        pub fn propRequiresHandle(self: *const Self, pid: u32) bool {
            if (pid >= self.graph.properties.len) return false;
            const p = self.graph.properties[pid];
            if (p.has_getter or p.has_setter) return true;
            if (p.modifiers.method_mod or p.modifiers.accessor_mod or p.modifiers.private_mod or p.modifiers.protected_mod) return true;
            if (std.mem.eql(u8, self.str(p.name), "__zigar_private_brand")) return true;
            return false;
        }

        pub fn classifyObjectLiteralData(self: *const Self, obj: anytype) DeclClassification {
            if (obj.call_signatures.len > 0 or obj.construct_signatures.len > 0) {
                return .{
                    .kind = .handle_wrapper,
                    .is_class = false,
                    .is_callable_handle = true,
                };
            }
            for (obj.properties) |pid| {
                if (self.propRequiresHandle(pid)) {
                    return .{
                        .kind = .handle_wrapper,
                        .is_class = false,
                        .is_callable_handle = false,
                    };
                }
            }
            return .{ .kind = .value_struct };
        }

        /// Inspects whether a `TypeId` describes a JS constructor object (`{ new(...): ... }` or
        /// `FooConstructor` interface with `construct_signatures` or a `"prototype"` property).
        pub fn typeHasConstructorShape(self: *const Self, ty_id: u32, depth: usize) bool {
            if (ty_id >= self.graph.types.len or depth > 12) return false;
            const tn = self.graph.types[ty_id];
            switch (tn.kind) {
                .object_literal => |obj| {
                    if (obj.construct_signatures.len > 0) return true;
                    for (obj.properties) |pid| {
                        if (pid < self.graph.properties.len and
                            std.mem.eql(u8, self.str(self.graph.properties[pid].name), "prototype"))
                        {
                            return true;
                        }
                    }
                    return false;
                },
                .intersection => |parts| {
                    for (parts) |part_id| {
                        if (self.typeHasConstructorShape(part_id, depth + 1)) return true;
                    }
                    return false;
                },
                .reference => |ref| {
                    if (ref.target_decl) |td| {
                        if (td < self.graph.decls.len) {
                            const d = self.graph.decls[td];
                            switch (d.kind) {
                                .interface_decl => |iface| {
                                    if (iface.construct_signatures.len > 0) return true;
                                    for (iface.properties) |pid| {
                                        if (pid < self.graph.properties.len and
                                            std.mem.eql(u8, self.str(self.graph.properties[pid].name), "prototype"))
                                        {
                                            return true;
                                        }
                                    }
                                    for (iface.extends_clauses) |hc| {
                                        if (self.typeHasConstructorShape(hc.target_type, depth + 1)) return true;
                                    }
                                },
                                .type_alias_decl => |alias_ty| {
                                    if (self.typeHasConstructorShape(alias_ty, depth + 1)) return true;
                                },
                                else => {},
                            }
                        }
                    }
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) return self.typeHasConstructorShape(rt, depth + 1);
                    }
                    return false;
                },
                else => return false,
            }
        }

        /// Collects construct signatures, static properties (excluding `"prototype"`), and static methods
        /// from a companion `declare var Foo: FooConstructor` declaration's type.
        pub fn collectCompanionVarCtorMembers(
            self: *const Self,
            var_decl_id: u32,
            out_ctor_sigs: *std.ArrayList(u32),
            out_static_props: *std.ArrayList(u32),
            out_static_methods: anytype,
            scratch: std.mem.Allocator,
        ) error{OutOfMemory}!void {
            if (var_decl_id >= self.graph.decls.len) return;
            const vd = self.graph.decls[var_decl_id];
            if (vd.kind != .variable_decl) return;
            try self.collectCtorTypeMembersInner(
                vd.kind.variable_decl,
                out_ctor_sigs,
                out_static_props,
                out_static_methods,
                scratch,
                0,
            );
        }

        fn appendUniqueU32(list: *std.ArrayList(u32), alloc: std.mem.Allocator, val: u32) !void {
            for (list.items) |existing| {
                if (existing == val) return;
            }
            try list.append(alloc, val);
        }

        fn collectCtorTypeMembersInner(
            self: *const Self,
            ty_id: u32,
            out_ctor_sigs: *std.ArrayList(u32),
            out_static_props: *std.ArrayList(u32),
            out_static_methods: anytype,
            scratch: std.mem.Allocator,
            depth: usize,
        ) error{OutOfMemory}!void {
            if (ty_id >= self.graph.types.len or depth > 12) return;
            const tn = self.graph.types[ty_id];
            switch (tn.kind) {
                .object_literal => |obj| {
                    for (obj.construct_signatures) |sid| {
                        try appendUniqueU32(out_ctor_sigs, scratch, sid);
                    }
                    for (obj.properties) |pid| {
                        if (pid >= self.graph.properties.len) continue;
                        const p = self.graph.properties[pid];
                        if (std.mem.eql(u8, self.str(p.name), "prototype")) continue;
                        // On anonymous `object_literal`, `extractObjectLiteralMembersAST` encodes method
                        // signatures as `function_type` (or intersection of `function_type`s) in `properties`!
                        if (p.ty < self.graph.types.len and (p.modifiers.method_mod or !p.modifiers.optional_mod) and !p.has_getter and !p.has_setter) {
                            const ptn = self.graph.types[p.ty];
                            if (ptn.kind == .function_type) {
                                const sig_slice = try scratch.alloc(u32, 1);
                                sig_slice[0] = ptn.kind.function_type;
                                var mods = p.modifiers;
                                mods.static_mod = true;
                                try out_static_methods.append(scratch, .{
                                    .name = p.name,
                                    .computed_symbol = p.computed_symbol,
                                    .signatures = sig_slice,
                                    .modifiers = mods,
                                    .jsdoc = p.jsdoc,
                                });
                                continue;
                            } else if (ptn.kind == .intersection) {
                                var all_fn = ptn.kind.intersection.len > 0;
                                for (ptn.kind.intersection) |part_ty| {
                                    if (part_ty >= self.graph.types.len or self.graph.types[part_ty].kind != .function_type) {
                                        all_fn = false;
                                        break;
                                    }
                                }
                                if (all_fn) {
                                    const sig_slice = try scratch.alloc(u32, ptn.kind.intersection.len);
                                    for (ptn.kind.intersection, 0..) |part_ty, idx| {
                                        sig_slice[idx] = self.graph.types[part_ty].kind.function_type;
                                    }
                                    var mods = p.modifiers;
                                    mods.static_mod = true;
                                    try out_static_methods.append(scratch, .{
                                        .name = p.name,
                                        .computed_symbol = p.computed_symbol,
                                        .signatures = sig_slice,
                                        .modifiers = mods,
                                        .jsdoc = p.jsdoc,
                                    });
                                    continue;
                                }
                            }
                        }
                        try appendUniqueU32(out_static_props, scratch, pid);
                    }
                },
                .intersection => |parts| {
                    for (parts) |part_id| {
                        try self.collectCtorTypeMembersInner(
                            part_id,
                            out_ctor_sigs,
                            out_static_props,
                            out_static_methods,
                            scratch,
                            depth + 1,
                        );
                    }
                },
                .reference => |ref| {
                    if (ref.target_decl) |td| {
                        if (td < self.graph.decls.len) {
                            const d = self.graph.decls[td];
                            switch (d.kind) {
                                .interface_decl => |iface| {
                                    for (iface.extends_clauses) |hc| {
                                        try self.collectCtorTypeMembersInner(
                                            hc.target_type,
                                            out_ctor_sigs,
                                            out_static_props,
                                            out_static_methods,
                                            scratch,
                                            depth + 1,
                                        );
                                    }
                                    for (iface.construct_signatures) |sid| {
                                        try appendUniqueU32(out_ctor_sigs, scratch, sid);
                                    }
                                    for (iface.properties) |pid| {
                                        if (pid >= self.graph.properties.len) continue;
                                        const p = self.graph.properties[pid];
                                        if (std.mem.eql(u8, self.str(p.name), "prototype")) continue;
                                        try appendUniqueU32(out_static_props, scratch, pid);
                                    }
                                    for (iface.methods) |m| {
                                        var mods = m.modifiers;
                                        mods.static_mod = true;
                                        try out_static_methods.append(scratch, .{
                                            .name = m.name,
                                            .computed_symbol = m.computed_symbol,
                                            .signatures = m.signatures,
                                            .modifiers = mods,
                                            .jsdoc = m.jsdoc,
                                        });
                                    }
                                    return;
                                },
                                .type_alias_decl => |alias_ty| {
                                    try self.collectCtorTypeMembersInner(
                                        alias_ty,
                                        out_ctor_sigs,
                                        out_static_props,
                                        out_static_methods,
                                        scratch,
                                        depth + 1,
                                    );
                                    return;
                                },
                                else => {},
                            }
                        }
                    }
                    if (tn.resolved_type) |rt| {
                        if (rt != ty_id) {
                            try self.collectCtorTypeMembersInner(
                                rt,
                                out_ctor_sigs,
                                out_static_props,
                                out_static_methods,
                                scratch,
                                depth + 1,
                            );
                        }
                    }
                },
                else => {},
            }
        }

        pub fn classifyDecl(self: *Self, decl_id: u32) error{OutOfMemory}!DeclClassification {
            if (decl_id >= self.graph.decls.len) return .{};
            if (self.memo.get(decl_id)) |cached| return cached;
            if (self.state.get(decl_id)) |st| {
                if (st == .visiting) {
                    // Cycle back-edge on heritage (`interface A extends B` / `interface B extends A`):
                    // assume plain `.value_struct` unless another non-cyclic branch requires `.handle_wrapper`.
                    return .{ .kind = .value_struct };
                }
            }

            try self.state.put(self.alloc, decl_id, .visiting);
            const result = try self.classifyDeclUncached(decl_id);
            try self.state.put(self.alloc, decl_id, .done);
            try self.memo.put(self.alloc, decl_id, result);
            return result;
        }

        fn classifyHeritageClause(self: *Self, hc: anytype) error{OutOfMemory}!DeclClassification {
            if (hc.target_decl) |td| {
                if (td < self.graph.decls.len) {
                    return try self.classifyDecl(td);
                }
            }
            if (hc.target_type < self.graph.types.len) {
                const tn = self.graph.types[hc.target_type];
                if (tn.kind == .reference) {
                    if (tn.kind.reference.target_decl) |td| {
                        return try self.classifyDecl(td);
                    }
                }
            }
            return .{ .kind = .value_struct };
        }

        fn classifyDeclUncached(self: *Self, decl_id: u32) error{OutOfMemory}!DeclClassification {
            const d = self.graph.decls[decl_id];
            switch (d.kind) {
                .class_decl => |cls| {
                    var is_callable = false;
                    for (d.merged_with) |mid| {
                        if (mid < self.graph.decls.len) {
                            const md = self.graph.decls[mid];
                            if (md.kind == .interface_decl and md.kind.interface_decl.call_signatures.len > 0) {
                                is_callable = true;
                            }
                        }
                    }
                    if (!is_callable) {
                        if (cls.extends_clause) |hc| {
                            const base_cls = try self.classifyHeritageClause(hc);
                            if (base_cls.is_callable_handle) is_callable = true;
                        }
                    }
                    return .{
                        .kind = .handle_wrapper,
                        .is_class = true,
                        .is_callable_handle = is_callable,
                    };
                },
                .interface_decl => |iface| {
                    var companion_var: ?u32 = null;
                    var has_merged_class = false;
                    var has_call_sigs = iface.call_signatures.len > 0;
                    var has_construct_sigs = iface.construct_signatures.len > 0;
                    var needs_handle = iface.methods.len > 0;

                    if (!needs_handle) {
                        for (iface.properties) |pid| {
                            if (self.propRequiresHandle(pid)) {
                                needs_handle = true;
                                break;
                            }
                        }
                    }

                    // Note: a merged `function_decl` (`interface Widget` + `declare function Widget(): Widget`)
                    // is a separate value-level factory function and does NOT make `Widget` instances callable.
                    for (d.merged_with) |mid| {
                        if (mid >= self.graph.decls.len or mid == decl_id) continue;
                        const md = self.graph.decls[mid];
                        switch (md.kind) {
                            .class_decl => has_merged_class = true,
                            .variable_decl => |vty_id| {
                                if (md.module == d.module and self.typeHasConstructorShape(vty_id, 0)) {
                                    companion_var = mid;
                                }
                            },
                            .interface_decl => |miface| {
                                if (miface.call_signatures.len > 0) has_call_sigs = true;
                                if (miface.construct_signatures.len > 0) has_construct_sigs = true;
                                if (miface.methods.len > 0) needs_handle = true;
                                if (!needs_handle) {
                                    for (miface.properties) |pid| {
                                        if (self.propRequiresHandle(pid)) {
                                            needs_handle = true;
                                            break;
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }

                    var inherited_callable = false;
                    for (iface.extends_clauses) |hc| {
                        const base_cls = try self.classifyHeritageClause(hc);
                        if (base_cls.kind == .handle_wrapper) {
                            needs_handle = true;
                            if (base_cls.is_callable_handle) inherited_callable = true;
                        }
                    }
                    for (d.merged_with) |mid| {
                        if (mid >= self.graph.decls.len or mid == decl_id) continue;
                        const md = self.graph.decls[mid];
                        if (md.kind == .interface_decl) {
                            for (md.kind.interface_decl.extends_clauses) |hc| {
                                const base_cls = try self.classifyHeritageClause(hc);
                                if (base_cls.kind == .handle_wrapper) {
                                    needs_handle = true;
                                    if (base_cls.is_callable_handle) inherited_callable = true;
                                }
                            }
                        }
                    }

                    if (has_merged_class or companion_var != null) {
                        return .{
                            .kind = .handle_wrapper,
                            .is_class = true,
                            .is_callable_handle = has_call_sigs or inherited_callable,
                            .companion_var_decl_id = companion_var,
                        };
                    }

                    const is_callable = has_call_sigs or has_construct_sigs or inherited_callable;
                    if (is_callable or needs_handle) {
                        return .{
                            .kind = .handle_wrapper,
                            .is_class = false,
                            .is_callable_handle = is_callable,
                        };
                    }

                    return .{ .kind = .value_struct };
                },
                .type_alias_decl => |ty_id| {
                    if (ty_id >= self.graph.types.len) return .{ .kind = .value_struct };
                    const tn = self.graph.types[ty_id];
                    switch (tn.kind) {
                        .object_literal => |obj| return self.classifyObjectLiteralData(obj),
                        .reference => |ref| {
                            if (ref.target_decl) |td| {
                                if (td != decl_id) return try self.classifyDecl(td);
                            }
                            const rname = self.str(ref.target_name);
                            if (std.mem.eql(u8, rname, "Array") or std.mem.eql(u8, rname, "ReadonlyArray") or
                                std.mem.eql(u8, rname, "Iterable") or std.mem.eql(u8, rname, "IterableIterator") or
                                std.mem.eql(u8, rname, "Set") or std.mem.eql(u8, rname, "ReadonlySet"))
                            {
                                return .{ .kind = .value_struct };
                            }
                            if (tn.resolved_type) |rt| {
                                if (rt < self.graph.types.len and self.graph.types[rt].kind == .object_literal) {
                                    return self.classifyObjectLiteralData(self.graph.types[rt].kind.object_literal);
                                }
                            }
                            return .{ .kind = .value_struct };
                        },
                        else => {
                            if (tn.resolved_type) |rt| {
                                if (rt < self.graph.types.len and self.graph.types[rt].kind == .object_literal) {
                                    return self.classifyObjectLiteralData(self.graph.types[rt].kind.object_literal);
                                }
                            }
                            return .{ .kind = .value_struct };
                        },
                    }
                },
                else => return .{ .kind = .value_struct },
            }
        }
    };
}

test "Classifier distinguishes plain value_struct interfaces from classes, stateful interfaces, and var+interface constructors" {
    const ts = @import("generated_ts_wasm32");
    const alloc = std.testing.allocator;

    const strings = [_][]const u8{
        "RequestOptions", // 0
        "port", // 1
        "host", // 2
        "ExtendedOptions", // 3
        "timeout", // 4
        "Logger", // 5
        "log", // 6
        "AccessorBox", // 7
        "value", // 8
        "CustomToken", // 9
        "prototype", // 10
        "id", // 11
        "DefaultOpts", // 12
        "Client", // 13
        "DerivedHandle", // 14
        "Widget", // 15
        "FactoryConfig", // 16
        "LoggerT", // 17
    };

    const props = [_]ts.types.PropNode{
        // 0: port?: number
        .{
            .id = 0,
            .name = 1,
            .computed_symbol = null,
            .ty = 0,
            .setter_ty = null,
            .has_getter = false,
            .has_setter = false,
            .modifiers = .{ .optional_mod = true },
            .jsdoc = null,
        },
        // 1: readonly host: string
        .{
            .id = 1,
            .name = 2,
            .computed_symbol = null,
            .ty = 1,
            .setter_ty = null,
            .has_getter = false,
            .has_setter = false,
            .modifiers = .{ .readonly_mod = true },
            .jsdoc = null,
        },
        // 2: get value(): string; set value(v: string | number)
        .{
            .id = 2,
            .name = 8,
            .computed_symbol = null,
            .ty = 1,
            .setter_ty = 0,
            .has_getter = true,
            .has_setter = true,
            .modifiers = .{ .accessor_mod = true },
            .jsdoc = null,
        },
        // 3: prototype: CustomToken
        .{
            .id = 3,
            .name = 10,
            .computed_symbol = null,
            .ty = 2,
            .setter_ty = null,
            .has_getter = false,
            .has_setter = false,
            .modifiers = .{},
            .jsdoc = null,
        },
        // 4: readonly id: string
        .{
            .id = 4,
            .name = 11,
            .computed_symbol = null,
            .ty = 1,
            .setter_ty = null,
            .has_getter = false,
            .has_setter = false,
            .modifiers = .{ .readonly_mod = true },
            .jsdoc = null,
        },
        // 5: log(msg: string): CustomToken (method_mod = true on object_literal)
        .{
            .id = 5,
            .name = 6,
            .computed_symbol = null,
            .ty = 7,
            .setter_ty = null,
            .has_getter = false,
            .has_setter = false,
            .modifiers = .{ .method_mod = true },
            .jsdoc = null,
        },
    };

    const sigs = [_]ts.types.SignatureNode{
        .{
            .id = 0,
            .type_params = &.{},
            .this_param = null,
            .params = &.{},
            .return_type = 2,
            .type_predicate = null,
            .is_abstract = false,
            .modifiers = .{},
            .jsdoc = null,
        },
    };

    const types_arr = [_]ts.types.TypeNode{
        .{ .id = 0, .kind = .number_type, .resolved_type = null },
        .{ .id = 1, .kind = .string_type, .resolved_type = null },
        // 2: reference to CustomToken (decl 4)
        .{
            .id = 2,
            .kind = .{ .reference = .{ .target_decl = 4, .target_name = 9, .module_specifier = null, .type_args = &.{} } },
            .resolved_type = null,
        },
        // 3: object_literal `{ prototype: CustomToken; new(): CustomToken }`
        .{
            .id = 3,
            .kind = .{
                .object_literal = .{
                    .properties = &.{3},
                    .call_signatures = &.{},
                    .construct_signatures = &.{0},
                    .index_signatures = &.{},
                },
            },
            .resolved_type = null,
        },
        // 4: reference to DefaultOpts (decl 6)
        .{
            .id = 4,
            .kind = .{ .reference = .{ .target_decl = 6, .target_name = 12, .module_specifier = null, .type_args = &.{} } },
            .resolved_type = null,
        },
        // 5: reference to RequestOptions (decl 0)
        .{
            .id = 5,
            .kind = .{ .reference = .{ .target_decl = 0, .target_name = 0, .module_specifier = null, .type_args = &.{} } },
            .resolved_type = null,
        },
        // 6: reference to Logger (decl 2)
        .{
            .id = 6,
            .kind = .{ .reference = .{ .target_decl = 2, .target_name = 5, .module_specifier = null, .type_args = &.{} } },
            .resolved_type = null,
        },
        // 7: function_type(sig 0)
        .{
            .id = 7,
            .kind = .{ .function_type = 0 },
            .resolved_type = null,
        },
        // 8: object_literal `{ port?: number; log(): CustomToken }`
        .{
            .id = 8,
            .kind = .{
                .object_literal = .{
                    .properties = &.{ 0, 5 },
                    .call_signatures = &.{},
                    .construct_signatures = &.{},
                    .index_signatures = &.{},
                },
            },
            .resolved_type = null,
        },
    };

    const logger_methods = [_]ts.types.MethodNode{
        .{
            .name = 6,
            .computed_symbol = null,
            .signatures = &.{0},
            .modifiers = .{},
            .jsdoc = null,
        },
    };

    const ext_req_opts = [_]ts.types.HeritageClause{
        .{ .target_type = 5, .target_decl = 0, .type_args = &.{} },
    };
    const ext_logger = [_]ts.types.HeritageClause{
        .{ .target_type = 6, .target_decl = 2, .type_args = &.{} },
    };

    const decls = [_]ts.types.DeclNode{
        // 0: interface RequestOptions { port?: number; readonly host: string } -> .value_struct
        .{
            .id = 0,
            .name = 0,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{},
            .kind = .{
                .interface_decl = .{
                    .extends_clauses = &.{},
                    .properties = &.{ 0, 1 },
                    .methods = &.{},
                    .call_signatures = &.{},
                    .construct_signatures = &.{},
                    .index_signatures = &.{},
                },
            },
        },
        // 1: interface ExtendedOptions extends RequestOptions { port?: number } -> .value_struct
        .{
            .id = 1,
            .name = 3,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{},
            .kind = .{
                .interface_decl = .{
                    .extends_clauses = &ext_req_opts,
                    .properties = &.{0},
                    .methods = &.{},
                    .call_signatures = &.{},
                    .construct_signatures = &.{},
                    .index_signatures = &.{},
                },
            },
        },
        // 2: interface Logger { log(): void } -> .handle_wrapper
        .{
            .id = 2,
            .name = 5,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{},
            .kind = .{
                .interface_decl = .{
                    .extends_clauses = &.{},
                    .properties = &.{},
                    .methods = &logger_methods,
                    .call_signatures = &.{},
                    .construct_signatures = &.{},
                    .index_signatures = &.{},
                },
            },
        },
        // 3: interface AccessorBox { get value(): string; set value(v: number) } -> .handle_wrapper
        .{
            .id = 3,
            .name = 7,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{},
            .kind = .{
                .interface_decl = .{
                    .extends_clauses = &.{},
                    .properties = &.{2},
                    .methods = &.{},
                    .call_signatures = &.{},
                    .construct_signatures = &.{},
                    .index_signatures = &.{},
                },
            },
        },
        // 4: interface CustomToken { readonly id: string } merged with 5: declare var CustomToken: { prototype: CustomToken; new(): CustomToken }
        .{
            .id = 4,
            .name = 9,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{ 4, 5 },
            .kind = .{
                .interface_decl = .{
                    .extends_clauses = &.{},
                    .properties = &.{4},
                    .methods = &.{},
                    .call_signatures = &.{},
                    .construct_signatures = &.{},
                    .index_signatures = &.{},
                },
            },
        },
        // 5: declare var CustomToken
        .{
            .id = 5,
            .name = 9,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{ 4, 5 },
            .kind = .{ .variable_decl = 3 },
        },
        // 6: interface DefaultOpts { port?: number } merged with 7: declare const DefaultOpts: DefaultOpts (NOT a constructor!)
        .{
            .id = 6,
            .name = 12,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{ 6, 7 },
            .kind = .{
                .interface_decl = .{
                    .extends_clauses = &.{},
                    .properties = &.{0},
                    .methods = &.{},
                    .call_signatures = &.{},
                    .construct_signatures = &.{},
                    .index_signatures = &.{},
                },
            },
        },
        // 7: declare const DefaultOpts: DefaultOpts
        .{
            .id = 7,
            .name = 12,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{ 6, 7 },
            .kind = .{ .variable_decl = 4 },
        },
        // 8: class Client {} -> .handle_wrapper (is_class = true)
        .{
            .id = 8,
            .name = 13,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{},
            .kind = .{
                .class_decl = .{
                    .constructors = &.{},
                    .extends_clause = null,
                    .implements_clauses = &.{},
                    .properties = &.{},
                    .methods = &.{},
                    .index_signatures = &.{},
                },
            },
        },
        // 9: interface DerivedHandle extends Logger { port?: number } -> .handle_wrapper (inherits stateful Logger!)
        .{
            .id = 9,
            .name = 14,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{},
            .kind = .{
                .interface_decl = .{
                    .extends_clauses = &ext_logger,
                    .properties = &.{0},
                    .methods = &.{},
                    .call_signatures = &.{},
                    .construct_signatures = &.{},
                    .index_signatures = &.{},
                },
            },
        },
        // 10: interface Widget { log(): void } merged with 11: declare function Widget(): Widget
        // -> .handle_wrapper, NOT callable (`is_callable_handle == false`)!
        .{
            .id = 10,
            .name = 15,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{ 10, 11 },
            .kind = .{
                .interface_decl = .{
                    .extends_clauses = &.{},
                    .properties = &.{},
                    .methods = &logger_methods,
                    .call_signatures = &.{},
                    .construct_signatures = &.{},
                    .index_signatures = &.{},
                },
            },
        },
        .{
            .id = 11,
            .name = 15,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{ 10, 11 },
            .kind = .{ .function_decl = &.{0} },
        },
        // 12: interface FactoryConfig { port?: number } merged with 13: declare function FactoryConfig(): FactoryConfig
        // -> .value_struct (`is_callable_handle == false`)!
        .{
            .id = 12,
            .name = 16,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{ 12, 13 },
            .kind = .{
                .interface_decl = .{
                    .extends_clauses = &.{},
                    .properties = &.{0},
                    .methods = &.{},
                    .call_signatures = &.{},
                    .construct_signatures = &.{},
                    .index_signatures = &.{},
                },
            },
        },
        .{
            .id = 13,
            .name = 16,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{ 12, 13 },
            .kind = .{ .function_decl = &.{0} },
        },
        // 14: type LoggerT = { port?: number; log(): CustomToken } -> .handle_wrapper (`!is_callable_handle`)
        .{
            .id = 14,
            .name = 17,
            .export_name = null,
            .module = 0,
            .type_params = &.{},
            .modifiers = .{ .export_decl = true },
            .jsdoc = null,
            .merged_with = &.{},
            .kind = .{ .type_alias_decl = 8 },
        },
    };

    const graph = ts.types.DeclarationGraph{
        .strings = &strings,
        .modules = &.{},
        .entry_modules = &.{},
        .decls = &decls,
        .types = &types_arr,
        .signatures = &sigs,
        .properties = &props,
        .type_params = &.{},
        .diagnostics = &.{},
    };

    var cls = Classifier(ts.types.DeclarationGraph).init(alloc, &graph);
    defer cls.deinit();

    const c0 = try cls.classifyDecl(0);
    try std.testing.expectEqual(ObjectDeclKind.value_struct, c0.kind);
    try std.testing.expect(!c0.is_class);

    const c1 = try cls.classifyDecl(1);
    try std.testing.expectEqual(ObjectDeclKind.value_struct, c1.kind);

    const c2 = try cls.classifyDecl(2);
    try std.testing.expectEqual(ObjectDeclKind.handle_wrapper, c2.kind);
    try std.testing.expect(!c2.is_class);

    const c3 = try cls.classifyDecl(3);
    try std.testing.expectEqual(ObjectDeclKind.handle_wrapper, c3.kind);

    const c4 = try cls.classifyDecl(4);
    try std.testing.expectEqual(ObjectDeclKind.handle_wrapper, c4.kind);
    try std.testing.expect(c4.is_class);
    try std.testing.expectEqual(@as(?u32, 5), c4.companion_var_decl_id);

    const c6 = try cls.classifyDecl(6);
    try std.testing.expectEqual(ObjectDeclKind.value_struct, c6.kind);
    try std.testing.expectEqual(@as(?u32, null), c6.companion_var_decl_id);

    const c8 = try cls.classifyDecl(8);
    try std.testing.expectEqual(ObjectDeclKind.handle_wrapper, c8.kind);
    try std.testing.expect(c8.is_class);

    const c9 = try cls.classifyDecl(9);
    try std.testing.expectEqual(ObjectDeclKind.handle_wrapper, c9.kind);

    const c10 = try cls.classifyDecl(10);
    try std.testing.expectEqual(ObjectDeclKind.handle_wrapper, c10.kind);
    try std.testing.expect(!c10.is_callable_handle);

    const c12 = try cls.classifyDecl(12);
    try std.testing.expectEqual(ObjectDeclKind.value_struct, c12.kind);
    try std.testing.expect(!c12.is_callable_handle);

    const c14 = try cls.classifyDecl(14);
    try std.testing.expectEqual(ObjectDeclKind.handle_wrapper, c14.kind);
    try std.testing.expect(!c14.is_class);
    try std.testing.expect(!c14.is_callable_handle);
}
