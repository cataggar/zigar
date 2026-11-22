const std = @import("std");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const m = gen.m3_generics_esm;
const cjs = gen.m3_generics_cjs;

var gpa: zigar.mem.TrackingAllocator = .init(zigar.mem.allocator);
const tracked_alloc = gpa.allocator();

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn activeCallbacks() u32 {
    return js.activeCallbackCount();
}

pub fn liveZigAllocs() usize {
    return gpa.activeCount();
}

pub fn hasPendingCapturedError() bool {
    return js.hasLastError();
}

fn checkInvariants(handles_before: u32, cbs_before: u32, allocs_before: usize) !void {
    if (js.activeHandleCount() != handles_before) return error.Unexpected;
    if (js.activeCallbackCount() != cbs_before) return error.Unexpected;
    if (gpa.activeCount() != allocs_before) return error.Unexpected;
    if (js.hasLastError()) return error.Unexpected;
}

// 1. Generic functions: explicit type args, `*Default`, `*Infer`, `.from_default`, `const T` fixed tuple/array, `NoInfer<T>`
pub fn exerciseGenericFunctionsConstAndNoInfer(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = gpa.activeCount();

    var summary: []const u8 = &.{};
    {
        const id_num = try m.identity(f64, 42.5);
        if (id_num != 42.5) return error.Unexpected;

        const id_def = try m.identityDefaultAlloc(tracked_alloc, "hello");
        defer js.freeDecoded([]const u8, tracked_alloc, id_def);

        const id_inf_num = try m.identityInfer(@as(i32, -9));
        if (id_inf_num != -9) return error.Unexpected;

        const id_inf_str = try m.identityInferAlloc(tracked_alloc, "zig");
        defer js.freeDecoded([]const u8, tracked_alloc, id_inf_str);

        // Explicit + `*With` (`.from_default`) on `Envelope<T, Meta = DefaultMeta>`
        const EnvStr = m.EnvelopeWith(.{ .T = []const u8, .Meta = .from_default });
        const env_def: EnvStr = try m.wrapEnvelopeAlloc([]const u8, m.DefaultMeta, tracked_alloc, "auto", null);
        defer js.freeDecoded(EnvStr, tracked_alloc, env_def);
        if (!env_def.ok or env_def.meta.version != 1) return error.Unexpected;

        // `wrapEnvelopeInferAlloc` deducing `T` and filling `Meta = DefaultMeta`
        const env_inf = try m.wrapEnvelopeInferAlloc(tracked_alloc, @as(f64, 15), null);
        defer js.freeDecoded(m.Envelope(f64, m.DefaultMeta), tracked_alloc, env_inf);
        if (env_inf.payload != 15 or !std.mem.eql(u8, env_inf.meta.tag, "default")) return error.Unexpected;

        // `const T` fixed-array preservation across live JS array round-trip (`[3]f64` doubled in JS -> `[3]f64{ 20, 40, 60 }`)
        const fixed_doubled = try m.freezeTupleInfer([3]f64{ 10, 20, 30 });
        comptime {
            if (@TypeOf(fixed_doubled) != [3]f64) @compileError("expected [3]f64 from const T inference");
        }
        const fixed_sum: i64 = @intFromFloat(fixed_doubled[0] + fixed_doubled[1] + fixed_doubled[2]);

        // `NoInfer<T>` candidate deduction (`[4, 8]` -> 4, empty `&[_]f64{}` -> 99)
        const picked_first = try m.selectWithFallbackInfer(&[_]f64{ 4, 8 }, 99);
        const picked_fallback = try m.selectWithFallbackInfer(&[_]f64{}, 99);
        if (picked_first != 4 or picked_fallback != 99) return error.Unexpected;

        summary = try std.fmt.allocPrint(
            out_alloc,
            "def={s}|inf={d},{s}|env={s}:{s}|arr={d}|fb={d},{d}",
            .{
                id_def,
                id_inf_num,
                id_inf_str,
                env_def.payload,
                env_def.meta.tag,
                fixed_sum,
                @as(i64, @intFromFloat(picked_first)),
                @as(i64, @intFromFloat(picked_fallback)),
            },
        );
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return summary;
}

// 2. Constrained generics (`T extends { id: number }`), `K extends keyof T -> T[K]` wire-name lookup, generic overload dispatch & CJS `export =`
pub fn exerciseConstraintsKeyofAndGenericOverloads(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = gpa.activeCount();

    var formatted_out: []const u8 = &.{};
    {
        const user: m.UserProfile = .{
            .id = 77,
            .display_name = "Ada",
            .host_name = "zigar.local",
            .port = 8443,
        };

        const ident_tag = try m.formatIdentifiedInferAlloc(tracked_alloc, user, "U");
        defer js.freeDecoded([]const u8, tracked_alloc, ident_tag);

        // `getField<T, K extends keyof T>` with narrow property literal (`[]const u8`, `f64`, `?f64`) AND full `UserProfileKey` union!
        const got_name = try m.getFieldAlloc(m.UserProfile, enum { displayName }, tracked_alloc, user, .displayName);
        defer js.freeDecoded([]const u8, tracked_alloc, got_name);
        const got_id = try m.getField(m.UserProfile, enum { id }, user, .id);
        const got_port = try m.getField(m.UserProfile, enum { port }, user, .port);
        const got_dyn_union = try m.getFieldAlloc(m.UserProfile, m.UserProfileKey, tracked_alloc, user, .host_name);
        defer js.freeDecoded(@TypeOf(got_dyn_union), tracked_alloc, got_dyn_union);
        if (got_id != 77 or got_port == null or got_port.? != 8443) return error.Unexpected;

        // Generic overload dispatcher: deduced `T extends { id: number }`, explicit `.{ UserProfile, user }`, and `string` overload
        const d_deduced = try m.describeInputAlloc(tracked_alloc, user);
        defer js.freeDecoded([]const u8, tracked_alloc, d_deduced);
        const d_explicit = try m.describeInputAlloc(tracked_alloc, .{ m.UserProfile, user });
        defer js.freeDecoded([]const u8, tracked_alloc, d_explicit);
        const d_str = try m.describeInputAlloc(tracked_alloc, "plain");
        defer js.freeDecoded([]const u8, tracked_alloc, d_str);
        if (!std.mem.eql(u8, d_deduced, d_explicit)) return error.Unexpected;

        // CJS `export = cjsGenerics` generic box + `pluckKey`
        const cjs_box = try cjs.CjsGenerics.makeBoxDefault(314, 2);
        const cjs_str_box = try cjs.CjsGenerics.makeBoxInferAlloc(tracked_alloc, "cjs-ok", 5);
        defer js.freeDecoded(cjs.CjsGenerics.Box([]const u8), tracked_alloc, cjs_str_box);
        const CjsBoxDef = cjs.CjsGenerics.BoxDefault();
        const plucked_rev = try cjs.CjsGenerics.pluckKey(CjsBoxDef, enum { revision }, cjs_box, .revision);

        formatted_out = try std.fmt.allocPrint(
            out_alloc,
            "{s}|name={s}|ov={s},{s}|cjs={s}@{d}/{d}",
            .{
                ident_tag,
                got_name,
                d_deduced,
                d_str,
                cjs_str_box.value,
                @as(i64, @intFromFloat(cjs_box.value)),
                @as(i64, @intFromFloat(plucked_rev)),
            },
        );
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return formatted_out;
}

// 3. Generic handle class (`GenericStore<K, V>`, `*Default`, `*With`, generic method `transformGet<R>` with Zig closure)
pub fn exerciseGenericHandleClassAndMethods(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = gpa.activeCount();

    var out_text: []const u8 = &.{};
    {
        // Explicit instantiation `GenericStore([]const u8, UserProfile)`
        const user_store = try m.GenericStore([]const u8, m.UserProfile).init("users");
        defer user_store.deinit();

        try user_store.set("primary", .{
            .id = 9,
            .display_name = "Grace",
            .host_name = "hopper.org",
            .port = 9000,
        });

        const fetched_opt = try user_store.getAlloc(tracked_alloc, "primary");
        defer js.freeDecoded(?m.UserProfile, tracked_alloc, fetched_opt);
        const fetched = fetched_opt orelse return error.Unexpected;

        const missing_opt = try user_store.getAlloc(tracked_alloc, "missing");
        defer js.freeDecoded(?m.UserProfile, tracked_alloc, missing_opt);
        if (missing_opt != null) return error.Unexpected;

        const snap_opt = try user_store.snapshotAlloc(tracked_alloc, "primary");
        defer js.freeDecoded(?m.Envelope(m.UserProfile, []const u8), tracked_alloc, snap_opt);
        const snap = snap_opt orelse return error.Unexpected;

        // Generic method `transformGet<R = string>` with stateful Zig closure!
        const MapperCtx = struct {
            bonus: f64,
            fn scoreUser(self: *const @This(), u: m.UserProfile) f64 {
                return u.id * 10 + self.bonus;
            }
        };
        const mctx: MapperCtx = .{ .bonus = 5 };
        const mapped_score = (try user_store.transformGet(f64, "primary", js.closure(&mctx, MapperCtx.scoreUser))) orelse return error.Unexpected;

        // `*Default` (`GenericStore<string, number>`) and `*With` (`GenericStoreWith(.{ .V = bool })`)
        const def_store = try m.GenericStoreDefault().init("counts");
        defer def_store.deinit();
        try def_store.set("hits", 12);
        const hits = (try def_store.get("hits")) orelse return error.Unexpected;

        const bool_store = try m.GenericStoreWith(.{ .V = bool }).init("flags");
        defer bool_store.deinit();
        try bool_store.set("enabled", true);
        const enabled = (try bool_store.get("enabled")) orelse return error.Unexpected;

        const label_str = try user_store.labelAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, label_str);
        const sz = try user_store.size();

        out_text = try std.fmt.allocPrint(
            out_alloc,
            "{s}[{d}]:{s}@{s}|score={d}|hits={d}|flag={}",
            .{
                label_str,
                @as(i64, @intFromFloat(sz)),
                fetched.display_name,
                snap.meta,
                @as(i64, @intFromFloat(mapped_score)),
                @as(i64, @intFromFloat(hits)),
                enabled,
            },
        );
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return out_text;
}

// 4. Utility types & open mapped/conditional patterns (`Partial`, `Required`, `Readonly`, `Pick`, `Omit`, `EnumRecord`, `js.Record`, `NonNullable`, `Awaited`, `MutablePatch`)
pub fn exerciseUtilityTypesAndOpenMappedConditional(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = gpa.activeCount();

    var out_text: []const u8 = &.{};
    {
        const base: m.UserProfile = .{
            .id = 3,
            .display_name = "Linus",
            .host_name = "kernel.dev",
            .port = null,
        };
        const patched = try m.applyUserPatchAlloc(tracked_alloc, base, .{
            .display_name = "Linus2",
        });
        defer js.freeDecoded(@TypeOf(patched), tracked_alloc, patched);
        if (patched.port != 443) return error.Unexpected;

        // Open generic `Partial<T>` -> `Required<T>` via `js.Partial` / `js.Required` comptime struct transformers
        const gen_patched = try m.applyGenericPatchAlloc(m.UserProfile, tracked_alloc, base, .{
            .display_name = "Linus2",
        });
        comptime {
            if (@TypeOf(gen_patched) != js.Required(m.UserProfile)) @compileError("expected js.Required(UserProfile)");
        }
        defer js.freeDecoded(js.Required(m.UserProfile), tracked_alloc, gen_patched);
        if (gen_patched.port != 443 or !std.mem.eql(u8, gen_patched.display_name, "Linus2")) return error.Unexpected;

        // Open generic `Pick<T, K>` + `Omit<T, K>` with wire-name mapping (`displayName` <-> `display_name`)
        const PickIdAndName = enum { id, displayName };
        const merged_po = try m.mergePickedAndOmittedAlloc(
            m.UserProfile,
            PickIdAndName,
            tracked_alloc,
            .{ .id = 99, .display_name = "Merged" },
            .{ .host_name = "po.local", .port = 8080 },
        );
        defer js.freeDecoded(m.UserProfile, tracked_alloc, merged_po);
        if (merged_po.id != 99 or !std.mem.eql(u8, merged_po.display_name, "Merged") or !std.mem.eql(u8, merged_po.host_name, "po.local")) {
            return error.Unexpected;
        }

        const omitted = try m.summarizeUserSummaryAlloc(tracked_alloc, .{
            .id = 3,
            .display_name = patched.display_name,
        });
        defer js.freeDecoded(@TypeOf(omitted), tracked_alloc, omitted);

        const ro_sum = try m.sumReadonlyCoords(&[_]f64{ 5, 15, 22 });

        // Closed-enum `Record<HttpVerb, number>` encoded as `{ GET: 10, POST: 5, DELETE: 2 }` -> `10 + 10 + 6 = 26`
        const verb_total = try m.totalVerbCounts(.{
            .get = 10,
            .post = 5,
            .delete = 2,
        });

        // Open `Record<string, number>` -> live `js.Record([]const u8, f64)` handle
        const dyn_rec = try m.buildDynamicScores("svc");
        defer dyn_rec.deinit();
        const alpha = (try dyn_rec.get("svc:alpha")) orelse return error.Unexpected;
        const beta = (try dyn_rec.get("svc:beta")) orelse return error.Unexpected;
        try dyn_rec.set("svc:gamma", 60);
        const gamma = (try dyn_rec.get("svc:gamma")) orelse return error.Unexpected;

        const req_txt = try m.requireTextAlloc(tracked_alloc, "solid");
        defer js.freeDecoded([]const u8, tracked_alloc, req_txt);

        // Open homomorphic mapped `MutablePatch<M>` (`-readonly [P in keyof M]?: M[P]`)
        const updated_meta = try m.patchMetaAlloc(
            m.DefaultMeta,
            tracked_alloc,
            .{ .version = 1, .tag = "old" },
            .{ .tag = "v2" },
        );
        defer js.freeDecoded(m.DefaultMeta, tracked_alloc, updated_meta);

        // Nested `Awaited<Promise<Promise<UnwrapAsync<Promise<UserProfile>>>>>` -> `UserProfile`
        const unwrapped_fmt = try m.formatUnwrappedProfileAlloc(tracked_alloc, .{
            .id = 3,
            .display_name = omitted.display_name,
            .host_name = omitted.host_name,
            .port = patched.port,
        });
        defer js.freeDecoded([]const u8, tracked_alloc, unwrapped_fmt);

        // `typeof defaultEndpoint`, `Parameters<typeof requireText>`, `ReturnType<typeof requireText>`, `UserProfile["displayName"]`
        const default_ep = try m.default_endpoint.getAlloc(tracked_alloc);
        defer js.freeDecoded(m.EndpointConfig, tracked_alloc, default_ep);
        const ep_args: m.RequireTextArgs = .{ .val = "tls" };
        const owner_name: m.UserDisplayName = "root";
        const ep_desc = try m.describeEndpointTupleAlloc(tracked_alloc, default_ep, ep_args, owner_name);
        defer js.freeDecoded([]const u8, tracked_alloc, ep_desc);

        // `Required<NullishConfig>` preserves `| null` (`reqNull: null`, `optNull: null`) & `: undefined` (`reqUndef: undefined`)
        const req_nul_check = try m.inspectRequiredNullishAlloc(m.NullishConfig, tracked_alloc, .{
            .req_null = null,
            .opt_null = null,
            .req_undef = null,
            .opt_str = "ok",
        });
        defer js.freeDecoded([]const u8, tracked_alloc, req_nul_check);

        // Generic `Record<HttpVerb, string | null>` preserves explicit `null` properties (`"GET" in rec && rec.GET === null`)
        const rec_nul_check = try m.inspectNullableVerbRecordAlloc(?[]const u8, tracked_alloc, .{
            .get = null,
            .post = "live",
            .delete = null,
        });
        defer js.freeDecoded([]const u8, tracked_alloc, rec_nul_check);

        // Generic `Record<Direction, string>` (numeric enum `Up = 0, Down = 1`) roundtrips JS keys `"0"` and `"1"`
        comptime {
            if (m.ValueAtUp([]const u8) != []const u8) @compileError("expected ValueAtUp([]const u8) == []const u8");
            if (m.At0(struct { @"0": []const u8, @"1": f64 }) != []const u8) @compileError("expected At0(...) == []const u8");
        }
        const dir_rec_out = try m.inspectNumericEnumRecordAlloc([]const u8, tracked_alloc, .{
            .@"0" = "north",
            .@"1" = "south",
        });
        defer js.freeDecoded(@TypeOf(dir_rec_out), tracked_alloc, dir_rec_out);

        // Homomorphic `{ [P in keyof T]: boolean }` (`Flags<UserProfile>`) preserves optional `port?: boolean`
        const user_flags = try m.flagsOf(m.UserProfile, .{
            .id = 1,
            .display_name = "a",
            .host_name = "h",
        });
        if (!user_flags.id or !user_flags.display_name or !user_flags.host_name or user_flags.port != null) {
            return error.Unexpected;
        }

        out_text = try std.fmt.allocPrint(
            out_alloc,
            "{s}|ro={d}|verbs={d}|dyn={d}|txt={s}|meta={s}@{d}|ep={s}|{s}|{s}|dir={s},{s}|flags={s}",
            .{
                unwrapped_fmt,
                @as(i64, @intFromFloat(ro_sum)),
                @as(i64, @intFromFloat(verb_total)),
                @as(i64, @intFromFloat(alpha + beta + gamma)),
                req_txt,
                updated_meta.tag,
                @as(i64, @intFromFloat(updated_meta.version)),
                ep_desc,
                req_nul_check,
                rec_nul_check,
                dir_rec_out.@"0",
                dir_rec_out.@"1",
                if (user_flags.port == null) "opt-ok" else "opt-bad",
            },
        );
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return out_text;
}

pub fn acceptUserFlags(flags: m.Flags(m.UserProfile)) bool {
    return flags.id and flags.display_name and !flags.host_name and flags.port == null;
}

// 5. Handle + plain-struct intersections (`Sync & { readonly gen: Gen }`, `GenericStore<K, V> & StoreOverlay`)
pub fn exerciseHandleStructIntersections(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = gpa.activeCount();

    var out_text: []const u8 = &.{};
    {
        const store = try m.GenericStoreDefault().init("overlay");
        defer store.deinit();
        try store.set("base", 100);

        const sync_fn = try m.makeSyncScorer(3);
        defer sync_fn.deinit();
        const gen_fn = try m.makeGenScorer("gen");
        defer gen_fn.deinit();

        const cached = try m.cacheGeneratorMethod(
            m.SyncScorer,
            m.GenScorer,
            .{ .handle = store.ref.handle },
            "score",
            sync_fn,
            gen_fn,
        );
        defer cached.deinit();
        comptime {
            if (!@TypeOf(cached).is_zigar_intersect_handle) {
                @compileError("expected IntersectHandleWrapper for Sync & { readonly gen: Gen }");
            }
        }

        const sync_res = try cached.as(m.SyncScorer).call(14);
        const gen_prop = try cached.get("gen");
        defer gen_prop.deinit();
        const gen_res = try gen_prop.callAlloc(tracked_alloc, 14);
        defer js.freeDecoded([]const u8, tracked_alloc, gen_res);

        const StoreT = m.GenericStore([]const u8, f64);
        const overlaid = try m.attachStoreOverlay(
            []const u8,
            f64,
            m.StoreOverlay,
            store,
            .{ .revision = 7, .owner_tag = "ts71" },
        );
        defer overlaid.deinit();

        const base_val = (try overlaid.as(StoreT).get("base")) orelse return error.Unexpected;
        const rev_before = try overlaid.get("revision");
        const tag_val = try overlaid.getAlloc(tracked_alloc, "owner_tag");
        defer js.freeDecoded([]const u8, tracked_alloc, tag_val);

        try overlaid.set("revision", 8);
        const projected = try overlaid.projectAlloc(m.StoreOverlay, tracked_alloc);
        defer js.freeDecoded(m.StoreOverlay, tracked_alloc, projected);

        out_text = try std.fmt.allocPrint(
            out_alloc,
            "sync={d}|gen={s}|base={d}|rev={d}->{d}|tag={s}",
            .{
                @as(i64, @intFromFloat(sync_res)),
                gen_res,
                @as(i64, @intFromFloat(base_val)),
                @as(i64, @intFromFloat(rev_before)),
                @as(i64, @intFromFloat(projected.revision)),
                tag_val,
            },
        );
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return out_text;
}
