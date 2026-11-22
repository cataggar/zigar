const std = @import("std");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const m = gen.m3_heritage_esm;
const base_mod = gen.m3_heritage_base;
const cjs_mod = gen.m3_heritage_cjs;
const def_mod = gen.m3_heritage_def;

var gpa: zigar.mem.TrackingAllocator = .init(zigar.mem.allocator);
const tracked_alloc = gpa.allocator();

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn liveZigAllocs() usize {
    return gpa.activeCount();
}

pub fn hasPendingCapturedError() bool {
    return js.hasLastError();
}

fn checkInvariants(handles_before: u32, allocs_before: usize) !void {
    if (js.activeHandleCount() != handles_before) return error.Unexpected;
    if (gpa.activeCount() != allocs_before) return error.Unexpected;
    if (js.hasLastError()) return error.Unexpected;
}

// 1. Multi-level class inheritance + multiple `implements` + borrowed `.as` upcasts + `.clone` + `.tryAs` downcasts
pub fn exerciseClassHeritageUpcastCloneAndDowncast(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = gpa.activeCount();

    {
        const dup = try m.Duplex.init(64);
        defer dup.deinit();

        if (!try dup.write("hi")) return error.Unexpected;

        const chunk1_opt = try dup.readAlloc(tracked_alloc, 4);
        defer js.freeDecoded(?[]const u8, tracked_alloc, chunk1_opt);
        if (chunk1_opt == null or !std.mem.eql(u8, chunk1_opt.?, "alpha:4")) return error.Unexpected;

        const self2 = try dup.on("tick");
        defer self2.deinit();
        if (!try dup.emit("tick")) return error.Unexpected;
        if ((try dup.listenerCount("tick")) != 1) return error.Unexpected;

        const piped = try dup.pipeAlloc(tracked_alloc, "out");
        defer js.freeDecoded([]const u8, tracked_alloc, piped);
        if (!std.mem.eql(u8, piped, "pipe:out:listeners=1")) return error.Unexpected;

        const aug = try dup.augmentedTagAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, aug);
        if (!std.mem.eql(u8, aug, "aug:1:rev=49")) return error.Unexpected;

        // Zero-cost borrowed `.as(Base)` upcast across 3 levels (`Duplex -> Readable -> Stream -> EventEmitter`)
        // and implemented interfaces (`Closable`, `WritableLike`) without duplicating/leaking handles!
        const handles_mid = js.activeHandleCount();
        const ee_desc = try m.inspectAsEmitterAlloc(tracked_alloc, dup.as(base_mod.EventEmitter));
        defer js.freeDecoded([]const u8, tracked_alloc, ee_desc);
        if (!std.mem.eql(u8, ee_desc, "ee:true:1")) return error.Unexpected;

        const st_desc = try m.inspectAsStreamAlloc(tracked_alloc, dup.as(base_mod.Stream));
        defer js.freeDecoded([]const u8, tracked_alloc, st_desc);
        if (!std.mem.eql(u8, st_desc, "pipe:sink:listeners=1")) return error.Unexpected;

        const cl_desc = try m.inspectAsClosableAlloc(tracked_alloc, dup.as(m.Closable));
        defer js.freeDecoded([]const u8, tracked_alloc, cl_desc);
        if (!std.mem.eql(u8, cl_desc, "closable:false")) return error.Unexpected;
        if (js.activeHandleCount() != handles_mid) return error.Unexpected;

        // `.clone()` acquires an independent handle slot; closing via cloned handle mutates same JS instance
        // while `cloned.deinit()` leaves `dup` valid!
        {
            const cloned = try dup.clone();
            defer cloned.deinit();
            if (js.activeHandleCount() != handles_mid + 1) return error.Unexpected;
            if (!try cloned.as(m.WritableLike).write("more")) return error.Unexpected;
            try cloned.as(m.Closable).close();
        }
        if (js.activeHandleCount() != handles_mid) return error.Unexpected;

        const summary = try dup.duplexSummaryAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, summary);
        if (!std.mem.eql(u8, summary, "hwm=64|closed=true|written=hi,more")) return error.Unexpected;
    }

    // Runtime `.tryAs(Sub)` downcasting (`instanceof` for classes, non-invoking `Reflect.has` duck check for interfaces)
    {
        const mystery_dup = try m.makeMysteryEmitter(.duplex);
        defer mystery_dup.deinit();

        const as_dup_opt = try mystery_dup.tryAs(m.Duplex);
        if (as_dup_opt == null) return error.Unexpected;
        defer as_dup_opt.?.deinit();
        if ((try as_dup_opt.?.readableHighWaterMark()) != 64) return error.Unexpected;

        const mystery_read = try m.makeMysteryEmitter(.readable);
        defer mystery_read.deinit();

        if ((try mystery_read.tryAs(m.Duplex)) != null) return error.Unexpected;
        const as_read_opt = try mystery_read.tryAs(m.Readable);
        if (as_read_opt == null) return error.Unexpected;
        defer as_read_opt.?.deinit();
        if ((try as_read_opt.?.readableHighWaterMark()) != 32) return error.Unexpected;

        try m.resetClosableGetterSideEffects();
        const mystery_cl = try m.makeMysteryEmitter(.closable_emitter);
        defer mystery_cl.deinit();

        const cl_opt = try mystery_cl.tryAs(m.Closable);
        if (cl_opt == null) return error.Unexpected;
        defer cl_opt.?.deinit();
        if ((try m.closableGetterSideEffects()) != 0) return error.Unexpected;
        if (try cl_opt.?.isClosed()) return error.Unexpected;
        if ((try m.closableGetterSideEffects()) != 1) return error.Unexpected;
    }

    try checkInvariants(handles_before, allocs_before);
    return try out_alloc.dupe(u8, "class-heritage-upcast-clone-downcast-ok");
}

// 2. Diamond multiple interface inheritance + value-struct `.as(Base)` projection (with inline nominal enums)
pub fn exerciseDiamondInterfacesAndValueStructProjection(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = gpa.activeCount();

    {
        const dc = try m.makeDiamondChannel("ch-1", "net");
        defer dc.deinit();

        if (!try dc.open(1)) return error.Unexpected;
        if (try dc.open(0)) return error.Unexpected;

        const opened_path = try dc.openAlloc(tracked_alloc, "/ws");
        defer js.freeDecoded([]const u8, tracked_alloc, opened_path);
        if (!std.mem.eql(u8, opened_path, "opened:/ws@ch-1")) return error.Unexpected;

        const q_str = try dc.queryAlloc(tracked_alloc, "route");
        defer js.freeDecoded([]const u8, tracked_alloc, q_str);
        if (!std.mem.eql(u8, q_str, "net:route")) return error.Unexpected;

        if ((try dc.query(5)) != 50) return error.Unexpected;
        if ((try dc.queryNumber(5)) != 50) return error.Unexpected;
        if ((try dc.ping()) != 204) return error.Unexpected;

        // Optionality tightening (`BaseNode.tag?: string` -> `DiamondChannel.tag: string`)
        const tag_s = try dc.tagAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, tag_s);
        if (!std.mem.eql(u8, tag_s, "net")) return error.Unexpected;

        // Transitive `.bases` upcast (`DiamondChannel -> LeftReader/RightReader -> BaseNode`)
        if (!try dc.as(m.LeftReader).open(7)) return error.Unexpected;
        if ((try dc.as(m.RightReader).query(3)) != 30) return error.Unexpected;
        if ((try dc.as(m.BaseNode).status()) != .open) return error.Unexpected;
    }

    // Value-struct `.as(Base)` field projection (including distinct inline nominal enum types!)
    {
        const srv = m.ServerConfig{
            .host = "api.zigar.dev",
            .port = 443,
            .tls = true,
            .alpn = .h2,
            .workers = 4,
        };
        const host_desc1 = try m.describeHostConfigAlloc(tracked_alloc, srv.as(m.HostConfig));
        defer js.freeDecoded([]const u8, tracked_alloc, host_desc1);
        if (!std.mem.eql(u8, host_desc1, "api.zigar.dev:443")) return error.Unexpected;

        const tls_desc1 = try m.describeTlsConfigAlloc(tracked_alloc, srv.as(m.TlsConfig));
        defer js.freeDecoded([]const u8, tracked_alloc, tls_desc1);
        if (!std.mem.eql(u8, tls_desc1, "tls=true|alpn=h2")) return error.Unexpected;

        const comb = m.CombinedConfig{
            .host = "edge.zigar.dev",
            .tls = false,
            .alpn = .http_1_1,
            .workers = 8,
        };
        const host_desc2 = try m.describeHostConfigAlloc(tracked_alloc, comb.as(m.HostConfig));
        defer js.freeDecoded([]const u8, tracked_alloc, host_desc2);
        if (!std.mem.eql(u8, host_desc2, "edge.zigar.dev:default")) return error.Unexpected;

        const comb_desc = try m.describeCombinedConfigAlloc(tracked_alloc, comb);
        defer js.freeDecoded([]const u8, tracked_alloc, comb_desc);
        if (!std.mem.eql(u8, comb_desc, "edge.zigar.dev:default|tls=false|alpn=http/1.1|w=8")) return error.Unexpected;
    }

    try checkInvariants(handles_before, allocs_before);
    return try out_alloc.dupe(u8, "diamond-interfaces-and-value-projection-ok");
}

// 3. Intersections: uninhabited `noreturn`, branded primitives, `(A | B) & C` union distribution,
//    and stateful `A & B` handle intersections with recursive `.bases` validation
pub fn exerciseIntersectionsBrandsUnionsAndRecursiveGuards(out_alloc: std.mem.Allocator) ![]const u8 {
    comptime {
        if (m.EmptyResult != noreturn) @compileError("EmptyResult must lower to noreturn");
        if (m.UserId != []const u8) @compileError("UserId must lower to []const u8");
        if (m.PortNum != f64) @compileError("PortNum must lower to f64");
    }

    const handles_before = js.activeHandleCount();
    const allocs_before = gpa.activeCount();

    {
        const brand_res = try m.echoBrandPairAlloc(tracked_alloc, "usr_49", 8443);
        defer js.freeDecoded([]const u8, tracked_alloc, brand_res);
        if (!std.mem.eql(u8, brand_res, "uid=usr_49|port=8443")) return error.Unexpected;

        const ok_res = try m.formatTaggedOutcomeAlloc(
            tracked_alloc,
            .{ .ok = .{ .value = 99, .request_id = "r-ok" } },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, ok_res);
        if (!std.mem.eql(u8, ok_res, "[r-ok]ok=99")) return error.Unexpected;

        const err_res = try m.formatTaggedOutcomeAlloc(
            tracked_alloc,
            .{ .err = .{ .message = "denied", .request_id = "r-err" } },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, err_res);
        if (!std.mem.eql(u8, err_res, "[r-err]err=denied")) return error.Unexpected;
    }

    {
        try m.resetClosableGetterSideEffects();
        const sess = try m.makeAdminSession(true);
        defer sess.deinit();

        // Decode guard must NOT invoke `isClosed` getter!
        if ((try m.closableGetterSideEffects()) != 0) return error.Unexpected;
        if ((try sess.role()) != .admin) return error.Unexpected;

        const aud = try sess.auditAlloc(tracked_alloc, "login");
        defer js.freeDecoded([]const u8, tracked_alloc, aud);
        if (!std.mem.eql(u8, aud, "audit:admin:login")) return error.Unexpected;

        const rd_opt = try sess.readAlloc(tracked_alloc, null);
        defer js.freeDecoded(?[]const u8, tracked_alloc, rd_opt);
        if (rd_opt == null or !std.mem.eql(u8, rd_opt.?, "alpha")) return error.Unexpected;

        const ee_s = try m.inspectAsEmitterAlloc(tracked_alloc, sess.as(base_mod.EventEmitter));
        defer js.freeDecoded([]const u8, tracked_alloc, ee_s);
        if (!std.mem.eql(u8, ee_s, "ee:true:0")) return error.Unexpected;

        try sess.close();
        const cl_s = try m.inspectAsClosableAlloc(tracked_alloc, sess.as(m.Closable));
        defer js.freeDecoded([]const u8, tracked_alloc, cl_s);
        if (!std.mem.eql(u8, cl_s, "closable:true")) return error.Unexpected;

        // Invalid `AdminSession` missing `Closable` members must fail recursive `.bases` guard cleanly!
        if (m.makeAdminSession(false)) |bad| {
            bad.deinit();
            return error.Unexpected;
        } else |err| {
            if (err != error.TypeError) return error.Unexpected;
        }
    }

    try checkInvariants(handles_before, allocs_before);
    return try out_alloc.dupe(u8, "intersections-brands-unions-and-guards-ok");
}

// 4. Index signatures: `HeaderBag.init()`, `DualTable`, `DataAttrMap`, `VerbTable`, `InlineEnumDict`,
//    `SymbolVault`, and collision-safe `CollidingDict`
pub fn exerciseIndexSignaturesAndCollisionSafeDicts(out_alloc: std.mem.Allocator) ![]const u8 {
    comptime {
        if (@hasDecl(m.DualTable, "setIndex")) {
            @compileError("Readonly numeric index signature must not emit setIndex");
        }
    }

    const handles_before = js.activeHandleCount();
    const allocs_before = gpa.activeCount();

    // Pure dictionary `.init()` -> `{}` + `getAlloc` / `set`
    {
        const bag = try m.HeaderBag.init();
        defer bag.deinit();

        if ((try bag.getAlloc(tracked_alloc, "x-missing")) != null) return error.Unexpected;
        try bag.set("x-trace", "t1");
        try bag.set("accept", "json");

        const trace_opt = try bag.getAlloc(tracked_alloc, "x-trace");
        defer js.freeDecoded(?[]const u8, tracked_alloc, trace_opt);
        if (trace_opt == null or !std.mem.eql(u8, trace_opt.?, "t1")) return error.Unexpected;

        const sum = try m.summarizeHeaderBagAlloc(tracked_alloc, bag);
        defer js.freeDecoded([]const u8, tracked_alloc, sum);
        if (!std.mem.eql(u8, sum, "accept=json&x-trace=t1")) return error.Unexpected;
    }

    // Dual readonly numeric + RW string union dictionary
    {
        const dt = try m.makeDualTable();
        defer dt.deinit();

        const z_opt = try dt.getIndexAlloc(tracked_alloc, 0);
        defer js.freeDecoded(?[]const u8, tracked_alloc, z_opt);
        if (z_opt == null or !std.mem.eql(u8, z_opt.?, "zero")) return error.Unexpected;
        if ((try dt.getIndexAlloc(tracked_alloc, 99)) != null) return error.Unexpected;

        const mode_opt = try dt.getAlloc(tracked_alloc, "mode");
        defer js.freeDecoded(@TypeOf(mode_opt), tracked_alloc, mode_opt);
        if (mode_opt == null or mode_opt.? != .str or !std.mem.eql(u8, mode_opt.?.str, "auto")) {
            return error.Unexpected;
        }

        try dt.set("retries", .{ .num = 3 });
        const ret_opt = try dt.getAlloc(tracked_alloc, "retries");
        defer js.freeDecoded(@TypeOf(ret_opt), tracked_alloc, ret_opt);
        if (ret_opt == null or ret_opt.? != .num or ret_opt.?.num != 3) return error.Unexpected;
    }

    // Template-literal key (`DataKey`) + closed enum key (`HttpVerb`) + inline nominal enum value + `Symbol` key
    {
        const dam = try m.makeDataAttrMap();
        defer dam.deinit();

        if (m.DataKey.from("invalid")) |_| return error.Unexpected else |_| {}
        const role_opt = try dam.getAlloc(tracked_alloc, m.DataKey.initComptime("data-role"));
        defer js.freeDecoded(?[]const u8, tracked_alloc, role_opt);
        if (role_opt == null or !std.mem.eql(u8, role_opt.?, "dialog")) return error.Unexpected;

        try dam.set(try m.DataKey.from("data-state"), "ready");
        const st_opt = try dam.getAlloc(tracked_alloc, m.DataKey.initComptime("data-state"));
        defer js.freeDecoded(?[]const u8, tracked_alloc, st_opt);
        if (st_opt == null or !std.mem.eql(u8, st_opt.?, "ready")) return error.Unexpected;

        const vt = try m.makeVerbTable();
        defer vt.deinit();
        if ((try vt.get(.get)) != 200) return error.Unexpected;
        if ((try vt.get(.post)) != null) return error.Unexpected;
        try vt.set(.post, 201);
        if ((try vt.get(.post)) != 201) return error.Unexpected;

        const ied = try m.makeInlineEnumDict();
        defer ied.deinit();
        if ((try ied.getAlloc(tracked_alloc, "tls")) != .on) return error.Unexpected;
        try ied.set("cache", .off);
        if ((try ied.getAlloc(tracked_alloc, "cache")) != .off) return error.Unexpected;

        const sv = try m.makeSymbolVault();
        defer sv.deinit();
        const sym = try m.makeVaultSymbol("vault-key");
        defer sym.deinit();
        if ((try sv.getAlloc(tracked_alloc, sym)) != null) return error.Unexpected;
        try sv.set(sym, "top-secret");
        const sec_opt = try sv.getAlloc(tracked_alloc, sym);
        defer js.freeDecoded(?[]const u8, tracked_alloc, sec_opt);
        if (sec_opt == null or !std.mem.eql(u8, sec_opt.?, "top-secret")) return error.Unexpected;
    }

    // Collision-safe named `get` / `set` / `init` alongside `getEntry` / `setEntry` indexers
    {
        const cd = try m.makeCollidingDict();
        defer cd.deinit();

        try cd.init("slot-map");
        if (try cd.get(2)) return error.Unexpected;
        try cd.set(2, true);
        if (!try cd.get(2)) return error.Unexpected;

        const lbl = try m.collidingDictLabelAlloc(tracked_alloc, cd);
        defer js.freeDecoded([]const u8, tracked_alloc, lbl);
        if (!std.mem.eql(u8, lbl, "slot-map")) return error.Unexpected;

        if ((try cd.getEntry("alpha")) != 10) return error.Unexpected;
        try cd.setEntry("beta", 25);
        if ((try cd.getEntry("beta")) != 25) return error.Unexpected;
    }

    try checkInvariants(handles_before, allocs_before);
    return try out_alloc.dupe(u8, "index-signatures-and-collision-safe-dicts-ok");
}

// 5. Declaration merging across `interface`+`interface`, `class`+`interface`+`namespace`,
//    `function`+`namespace` (`formatMetric`, `_`, CJS `$`, default `defaultCreate`),
//    `enum`+`namespace`, multi-block `namespace`, and external module augmentation (`declare module`)
pub fn exerciseDeclarationMergingAndAugmentations(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = gpa.activeCount();

    // Merged `interface MergedRegistry` x2
    {
        const reg = try m.makeMergedRegistry("core-reg");
        defer reg.deinit();

        const rname = try reg.nameAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, rname);
        if (!std.mem.eql(u8, rname, "core-reg")) return error.Unexpected;

        if (!try reg.has("seed")) return error.Unexpected;
        if ((try reg.get("seed")) != 7) return error.Unexpected;
        try reg.set("extra", 11);
        try reg.setCount(2);
        if ((try reg.count()) != 2) return error.Unexpected;
        if ((try reg.clear()) != 2) return error.Unexpected;
        if ((try reg.count()) != 0) return error.Unexpected;
        if ((try reg.get("seed")) != null) return error.Unexpected;
    }

    // Merged `class RichService` + `interface RichService` + `namespace RichService`
    {
        if ((try m.RichService.default_timeout.get()) != 1500) return error.Unexpected;
        try m.RichService.default_timeout.set(2500);
        defer m.RichService.default_timeout.set(1500) catch {};

        const svc1 = try m.RichService.init("https://a.test");
        defer svc1.deinit();
        if (!try svc1.connect()) return error.Unexpected;
        const p1 = try svc1.mixinPingAlloc(tracked_alloc, "p1");
        defer js.freeDecoded([]const u8, tracked_alloc, p1);
        if (!std.mem.eql(u8, p1, "https://a.test[2500]:p1:true")) return error.Unexpected;

        const svc2 = try m.RichService.fromOptions(.{ .endpoint = "https://b.test", .timeout_ms = 500 });
        defer svc2.deinit();
        const p2 = try svc2.mixinPingAlloc(tracked_alloc, "p2");
        defer js.freeDecoded([]const u8, tracked_alloc, p2);
        if (!std.mem.eql(u8, p2, "https://b.test[500]:p2:false")) return error.Unexpected;
    }

    // Merged `function formatMetric` + `namespace formatMetric` AND colliding `function _` + `namespace _`
    {
        const fm1 = try m.formatMetricAlloc(tracked_alloc, "lat", 12);
        defer js.freeDecoded([]const u8, tracked_alloc, fm1);
        if (!std.mem.eql(u8, fm1, "zigar:lat=12")) return error.Unexpected;

        try m.FormatMetric.prefix.set("custom");
        const fm2 = try m.FormatMetric.callAlloc(tracked_alloc, "lat", 12);
        defer js.freeDecoded([]const u8, tracked_alloc, fm2);
        if (!std.mem.eql(u8, fm2, "custom:lat=12")) return error.Unexpected;
        try m.FormatMetric.reset();

        const items = [_][]const u8{ "a", "b", "a" };
        if ((try m._.call(&items)) != 3) return error.Unexpected;
        const uver = try m._.VERSION.getAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, uver);
        if (!std.mem.eql(u8, uver, "4.17.21")) return error.Unexpected;

        const uniq = try m._.uniqAlloc(tracked_alloc, &items);
        defer js.freeDecoded([]const []const u8, tracked_alloc, uniq);
        if (uniq.len != 2 or !std.mem.eql(u8, uniq[0], "a") or !std.mem.eql(u8, uniq[1], "b")) {
            return error.Unexpected;
        }
    }

    // Merged CJS `export = $` AND merged `export default defaultCreate`
    {
        const sel1 = try m.@"$".call(".btn");
        defer sel1.deinit();
        if ((try sel1.length()) != 1) return error.Unexpected;
        const t1 = try sel1.textAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, t1);
        if (!std.mem.eql(u8, t1, ".btn")) return error.Unexpected;

        const sel2 = try cjs_mod.@"$".callWithRoot("li", "ul");
        defer sel2.deinit();
        if ((try sel2.length()) != 2) return error.Unexpected;
        const t2 = try sel2.textAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, t2);
        if (!std.mem.eql(u8, t2, "ul>>li")) return error.Unexpected;

        const ajax_res = try cjs_mod.ajaxAlloc(tracked_alloc, "/v1");
        defer js.freeDecoded([]const u8, tracked_alloc, ajax_res);
        if (!std.mem.eql(u8, ajax_res, "ajax[4.9.0]:/v1")) return error.Unexpected;

        _ = try def_mod.Default.reset();
        const d1 = try def_mod.defaultAlloc(tracked_alloc, "x");
        defer js.freeDecoded([]const u8, tracked_alloc, d1);
        if (!std.mem.eql(u8, d1, "def[1.0]:x#1")) return error.Unexpected;

        try def_mod.Default.version.set("2.0");
        defer def_mod.Default.version.set("1.0") catch {};

        const d2 = try def_mod.Default.callWithCountAlloc(tracked_alloc, "y", 3);
        defer js.freeDecoded([]const u8, tracked_alloc, d2);
        if (!std.mem.eql(u8, d2, "def[2.0]:yx3#2")) return error.Unexpected;

        const d3 = try m.checkDefaultBridgeAlloc(tracked_alloc, "z");
        defer js.freeDecoded([]const u8, tracked_alloc, d3);
        if (!std.mem.eql(u8, d3, "def[2.0]:z#3")) return error.Unexpected;
        if ((try def_mod.Default.reset()) != 3) return error.Unexpected;
    }

    // Merged `enum LogLevel` + `namespace LogLevel`, multi-block `Telemetry`, and external module augmentation
    {
        if ((try m.LogLevel.parse("err")) != .err) return error.Unexpected;
        if ((try m.LogLevel.default_level.get()) != .warn) return error.Unexpected;
        try m.LogLevel.default_level.set(.info);
        defer m.LogLevel.default_level.set(.warn) catch {};
        if ((try m.LogLevel.default_level.get()) != .info) return error.Unexpected;

        _ = try m.Telemetry.flush();
        try m.Telemetry.service_name.set("gw");
        try m.Telemetry.sample_rate.set(1.0);
        defer {
            m.Telemetry.service_name.set("core") catch {};
            m.Telemetry.sample_rate.set(0.5) catch {};
        }
        try m.Telemetry.record("boot");
        try m.Telemetry.record("ready");
        if ((try m.Telemetry.flush()) != 2) return error.Unexpected;

        if ((try base_mod.EventEmitter.spec_revision.get()) != 49) return error.Unexpected;
        try base_mod.EventEmitter.spec_revision.set(50);
        defer base_mod.EventEmitter.spec_revision.set(49) catch {};

        const ee = try base_mod.EventEmitter.init();
        defer ee.deinit();
        const aug_s = try ee.augmentedTagAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, aug_s);
        if (!std.mem.eql(u8, aug_s, "aug:0:rev=50")) return error.Unexpected;
    }

    try checkInvariants(handles_before, allocs_before);
    return try out_alloc.dupe(u8, "declaration-merging-and-augmentations-ok");
}
