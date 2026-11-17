const std = @import("std");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const m = gen.m3_objects_esm;
const cjs_mod = gen.m3_objects_cjs;
const def_mod = gen.m3_objects_def;

var live_allocs = std.atomic.Value(usize).init(0);

const TrackingAllocator = struct {
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const ptr = zigar.mem.allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = live_allocs.fetchAdd(1, .acq_rel);
        return ptr;
    }

    fn resize(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return zigar.mem.allocator.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return zigar.mem.allocator.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn free(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        zigar.mem.allocator.rawFree(buf, alignment, ret_addr);
        _ = live_allocs.fetchSub(1, .acq_rel);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator() std.mem.Allocator {
        return .{ .ptr = undefined, .vtable = &vtable };
    }
};

const tracked_alloc = TrackingAllocator.allocator();

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn liveZigAllocs() usize {
    return live_allocs.load(.acquire);
}

pub fn hasPendingCapturedError() bool {
    return js.hasLastError();
}

fn checkInvariants(handles_before: u32, allocs_before: usize) !void {
    if (js.activeHandleCount() != handles_before) return error.Unexpected;
    if (live_allocs.load(.acquire) != allocs_before) return error.Unexpected;
    if (js.hasLastError()) return error.Unexpected;
}

// 1. Plain options structs (`.{ .host = ..., .port = ... }` with omitted optionals, inherited fields,
//    anonymous inline structs with explicit `null`, and cyclic `LinkedNode` `.toJsRef()` / `.fromJsRefAlloc()`).
pub fn exercisePlainOptionsAndCyclicStructs(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    {
        const desc1 = try m.describeRequestOptionsAlloc(
            tracked_alloc,
            .{ .host = "127.0.0.1", .port = 8080 },
            .{ .label = "boot", .reason = null },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, desc1);
        if (!std.mem.eql(u8, desc1, "127.0.0.1:8080|ka=omitted|ret=omitted|hdr=omitted|boot:null")) {
            return error.Unexpected;
        }

        const hdrs = [_][]const u8{ "accept", "x-zigar" };
        const desc2 = try m.describeRequestOptionsAlloc(
            tracked_alloc,
            .{ .host = "zigar.dev", .keep_alive = false, .retries = 3, .headers = &hdrs },
            .{ .label = "retry", .reason = "timeout" },
        );
        defer js.freeDecoded([]const u8, tracked_alloc, desc2);
        if (!std.mem.eql(u8, desc2, "zigar.dev:omitted|ka=false|ret=3|hdr=accept,x-zigar|retry:timeout")) {
            return error.Unexpected;
        }

        const def_opts = try m.makeDefaultOptionsAlloc(tracked_alloc);
        defer js.freeDecoded(m.RequestOptions, tracked_alloc, def_opts);
        if (!std.mem.eql(u8, def_opts.host, "0.0.0.0")) return error.Unexpected;
        if (def_opts.port != 3000 or def_opts.keep_alive != true or def_opts.retries != null) {
            return error.Unexpected;
        }
        const got_hdrs = def_opts.headers orelse return error.Unexpected;
        if (got_hdrs.len != 2 or !std.mem.eql(u8, got_hdrs[1], "x-two")) return error.Unexpected;

        // Cyclic plain value struct `LinkedNode` passed on stack AND roundtripped via `.toJsRef()` / `.fromJsRefAlloc()`!
        const n3 = m.LinkedNode{ .id = "c", .value = 30 };
        const n2 = m.LinkedNode{ .id = "b", .value = 20, .next = &n3 };
        const n1 = m.LinkedNode{ .id = "a", .value = 10, .next = &n2 };

        const sum_desc = try m.sumLinkedNodesAlloc(tracked_alloc, n1);
        defer js.freeDecoded([]const u8, tracked_alloc, sum_desc);
        if (!std.mem.eql(u8, sum_desc, "a->b->c=60")) return error.Unexpected;

        const raw_chain = try n1.toJsRef();
        defer raw_chain.deinit();
        const decoded_chain = try m.LinkedNode.fromJsRefAlloc(tracked_alloc, raw_chain);
        defer js.freeDecoded(m.LinkedNode, tracked_alloc, decoded_chain);
        if (!std.mem.eql(u8, decoded_chain.id, "a") or decoded_chain.value != 10) return error.Unexpected;
        const dn2 = decoded_chain.next orelse return error.Unexpected;
        const dn3 = dn2.next orelse return error.Unexpected;
        if (!std.mem.eql(u8, dn3.id, "c") or dn3.value != 30 or dn3.next != null) return error.Unexpected;
    }

    try checkInvariants(handles_before, allocs_before);
    return out_alloc.dupe(u8, "plain-options-and-cyclic-ok");
}

// 2. Abstract base class, `extends` inheritance, overloaded `init`/`init_2`, readonly/RW/WO/divergent/nominal
//    instance properties, static RW/RO/WO/divergent properties & static methods, and `instanceof` guard.
pub fn exerciseClassesInheritanceAndAccessors(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    {
        if (m.BaseTransport.SPEC_VERSION != 2) return error.Unexpected;
        if (@hasDecl(m.BaseTransport, "init")) return error.Unexpected;
        if ((try m.BaseTransport.supportedCount()) != 3) return error.Unexpected;

        // Static properties on `HttpClient`: RW (`default_port`), RO (`version`), WO (`log_sink`), divergent (`env`)
        if ((try m.HttpClient.default_port.get()) != 443) return error.Unexpected;
        try m.HttpClient.default_port.set(8443);
        if ((try m.HttpClient.default_port.get()) != 8443) return error.Unexpected;

        const ver = try m.HttpClient.version.getAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, ver);
        if (!std.mem.eql(u8, ver, "26.0.0")) return error.Unexpected;

        try m.HttpClient.log_sink.set("journald");
        try m.HttpClient.env.set(null);
        const env_unset = try m.HttpClient.env.getAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, env_unset);
        if (!std.mem.eql(u8, env_unset, "unset")) return error.Unexpected;
        try m.HttpClient.env.set("staging");

        // Overloaded constructors + static factory
        var c1 = try m.HttpClient.init("https://api.zigar.dev");
        defer c1.deinit();
        if ((try c1.timeout()) != 1000) return error.Unexpected;
        if (!(try c1.ping())) return error.Unexpected;
        const c1_proto = try c1.protocolAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, c1_proto);
        if (!std.mem.eql(u8, c1_proto, "https:")) return error.Unexpected;

        var c2 = try m.HttpClient.init_2("http://localhost", 5000);
        defer c2.deinit();
        if ((try c2.timeout()) != 5000) return error.Unexpected;
        try c2.setTimeout(2500);
        if ((try c2.timeout()) != 2500) return error.Unexpected;

        // Shared inline nominal enum property (`mode`: `"fast" | "slow"`) roundtrip!
        const initial_mode = try c2.mode();
        if (initial_mode != .fast) return error.Unexpected;
        try c2.setMode(.slow);
        if ((try c2.mode()) != .slow) return error.Unexpected;

        // Divergent getter (`[]const u8`) + setter (`union(enum) { str: []const u8, num: f64 }`)
        try c2.setEndpoint(.{ .num = 9090 });
        const ep1 = try c2.endpointAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, ep1);
        if (!std.mem.eql(u8, ep1, "http://localhost:9090")) return error.Unexpected;

        try c2.setEndpoint(.{ .str = "/v3" });
        const ep2 = try c2.endpointAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, ep2);
        if (!std.mem.eql(u8, ep2, "http://localhost/v3")) return error.Unexpected;

        // Write-only setter (`setAuthToken`) + method taking optional `RequestOptions`
        try c2.setAuthToken("tok-abc");
        const req_out = try c2.requestAlloc(tracked_alloc, "/items", .{ .host = "10.0.0.1" });
        defer js.freeDecoded([]const u8, tracked_alloc, req_out);
        if (!std.mem.eql(u8, req_out, "slow|2500|http://localhost/v3/items|10.0.0.1:8443")) {
            return error.Unexpected;
        }

        const state_out = try m.verifyClientAndStateAlloc(tracked_alloc, c2);
        defer js.freeDecoded([]const u8, tracked_alloc, state_out);
        if (!std.mem.eql(u8, state_out, "sink=journald|env=staging|tok=tok-abc")) {
            return error.Unexpected;
        }

        // Upcast to `BaseTransport` (`instanceof BaseTransport` passes) vs impostor rejection!
        var base_handle = try m.upcastTransport(c2);
        defer base_handle.deinit();
        if (!(try base_handle.ping())) return error.Unexpected;

        try std.testing.expectError(error.TypeError, m.produceImpostorTransport());

        var c_def = try m.HttpClient.createDefault();
        defer c_def.deinit();
        const def_url = try c_def.baseUrlAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, def_url);
        if (!std.mem.eql(u8, def_url, "https://default.zigar.dev")) return error.Unexpected;

        // Restore static port for idempotency
        try m.HttpClient.default_port.set(443);
    }

    try checkInvariants(handles_before, allocs_before);
    return out_alloc.dupe(u8, "classes-inheritance-and-accessors-ok");
}

// 3. `export default class`, CJS `export = class` with `.ref()` collision (`__zigar_ref`),
//    and `interface CustomUrl` + `declare var CustomUrl: CustomUrlConstructor` companion folding.
pub fn exerciseDefaultCjsAndCompanionConstructors(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    {
        if (!std.mem.eql(u8, cjs_mod.CjsSocket.zigar_js.ref_field, "__zigar_ref")) {
            return error.Unexpected;
        }

        var sock = try cjs_mod.CjsSocket.init(443);
        defer sock.deinit();
        if ((try sock.port()) != 443) return error.Unexpected;

        var unrefed = try sock.unref();
        defer unrefed.deinit();
        if (try sock.isRefed()) return error.Unexpected;

        var refed = try sock.ref();
        defer refed.deinit();
        if (!(try refed.isRefed())) return error.Unexpected;

        var sess = try def_mod.Default.init("alice");
        defer sess.deinit();
        if ((try def_mod.Default.active_count.get()) != 1) return error.Unexpected;

        const pair_desc = try m.verifySocketAndSessionAlloc(tracked_alloc, sock, sess);
        defer js.freeDecoded([]const u8, tracked_alloc, pair_desc);
        if (!std.mem.eql(u8, pair_desc, "sock:443:true|sess:alice:1")) return error.Unexpected;

        const closed_msg = try sess.closeAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, closed_msg);
        if (!std.mem.eql(u8, closed_msg, "closed:alice")) return error.Unexpected;
        if ((try def_mod.Default.active_count.get()) != 0) return error.Unexpected;

        try std.testing.expectError(error.TypeError, m.produceImpostorSocket());

        // Companion `interface CustomUrl` + `declare var CustomUrl: CustomUrlConstructor`
        if ((try m.CustomUrl.scheme_version.get()) != 1) return error.Unexpected;
        if (!(try m.CustomUrl.canParse("/docs", "https://zigar.dev"))) return error.Unexpected;
        if (try m.CustomUrl.canParse(":::bad-url:::", null)) return error.Unexpected;

        var u = try m.CustomUrl.init("/guide", "https://zigar.dev");
        defer u.deinit();
        const orig = try u.originAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, orig);
        if (!std.mem.eql(u8, orig, "https://zigar.dev")) return error.Unexpected;

        const href1 = try u.hrefAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, href1);
        if (!std.mem.eql(u8, href1, "https://zigar.dev/guide")) return error.Unexpected;

        try u.setHref("https://zigar.dev/v2");
        const json_out = try u.toJsonAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, json_out);
        if (!std.mem.eql(u8, json_out, "https://zigar.dev/v2")) return error.Unexpected;

        try std.testing.expectError(error.TypeError, m.produceImpostorCustomUrl());
    }

    try checkInvariants(handles_before, allocs_before);
    return out_alloc.dupe(u8, "default-cjs-and-companion-ctors-ok");
}

// 4. Stateful duck-typed handles (`Reflect.has` zero-side-effect check), accessor-only live handles,
//    and callable + constructable function-handle interfaces (`call` + `construct`).
pub fn exerciseStatefulDuckHandlesAndCallableInterfaces(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    {
        const items = [_][]const u8{ "alpha", "beta" };
        var cur = try m.makeCursor(&items);
        defer cur.deinit();

        // `Reflect.has` duck-type validation MUST NOT invoke `get position()` during handle decode!
        if ((try m.cursorPositionGetterReads()) != 0) return error.Unexpected;

        if ((try cur.position()) != 0) return error.Unexpected;
        if ((try m.cursorPositionGetterReads()) != 1) return error.Unexpected;

        const first_opt = try cur.nextAlloc(tracked_alloc);
        defer js.freeDecoded(?[]const u8, tracked_alloc, first_opt);
        if (!std.mem.eql(u8, first_opt orelse return error.Unexpected, "alpha")) return error.Unexpected;

        const second_opt = try cur.nextAlloc(tracked_alloc);
        defer js.freeDecoded(?[]const u8, tracked_alloc, second_opt);
        if (!std.mem.eql(u8, second_opt orelse return error.Unexpected, "beta")) return error.Unexpected;

        const end_opt = try cur.nextAlloc(tracked_alloc);
        defer js.freeDecoded(?[]const u8, tracked_alloc, end_opt);
        if (end_opt != null) return error.Unexpected;

        try cur.reset();
        if ((try cur.position()) != 0) return error.Unexpected;

        for ([_]f64{ 0, 1, 2 }) |bad_mode| {
            try std.testing.expectError(error.TypeError, m.produceBadCursor(bad_mode));
        }

        // Accessor-only handle interface `LiveCounter` (`get count(): number; set count(v: number | string)`)
        var lc = try m.makeLiveCounter(10);
        defer lc.deinit();
        if ((try lc.count()) != 10) return error.Unexpected;
        try lc.setCount(.{ .str = "42" });
        if ((try lc.count()) != 42) return error.Unexpected;
        if ((try m.readLastCounterValue()) != 42) return error.Unexpected;
        try std.testing.expectError(error.TypeError, m.produceArrayAsCounter());

        // Callable + constructable interface `CallableFactory` (`call` + `construct` + `tag`)
        var fac = try m.getCallableFactory();
        defer fac.deinit();

        const fac_tag = try fac.tagAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, fac_tag);
        if (!std.mem.eql(u8, fac_tag, "v1-factory")) return error.Unexpected;

        const called = try fac.callAlloc(tracked_alloc, "job");
        defer js.freeDecoded([]const u8, tracked_alloc, called);
        if (!std.mem.eql(u8, called, "v1-factory:job")) return error.Unexpected;

        var constructed = try fac.construct("https://built.zigar.dev");
        defer constructed.deinit();
        if ((try constructed.timeout()) != 3200) return error.Unexpected;
        const built_url = try constructed.baseUrlAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, built_url);
        if (!std.mem.eql(u8, built_url, "https://built.zigar.dev")) return error.Unexpected;

        try std.testing.expectError(error.TypeError, m.produceBadCallableFactory());
    }

    try checkInvariants(handles_before, allocs_before);
    return out_alloc.dupe(u8, "stateful-duck-and-callable-handles-ok");
}

// 5. Same-named factory functions (`interface Widget` + `function Widget`, `interface FactoryConfig` + `function FactoryConfig`)
//    and generic `extends` instantiation (`StrBox extends Box<string>`, `Svc extends MidEmitter<string>`, `NumberStore extends StoreBase<number>`).
pub fn exerciseFactoryMergedAndGenericExtends(out_alloc: std.mem.Allocator) ![]const u8 {
    const handles_before = js.activeHandleCount();
    const allocs_before = live_allocs.load(.acquire);

    {
        // Plain object returned by `Widget("nav")` must decode as `JsObject` handle (NOT `JsFunction`!)
        var w = try m.widget("nav");
        defer w.deinit();
        if ((try w.id()) != 7) return error.Unexpected;
        const rendered = try w.renderAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, rendered);
        if (!std.mem.eql(u8, rendered, "<widget:nav>")) return error.Unexpected;

        // `FactoryConfig` merged with `function FactoryConfig` stays a plain value struct!
        const cfg1 = try m.factoryConfigAlloc(tracked_alloc, "api.zigar.dev");
        defer js.freeDecoded(m.FactoryConfig, tracked_alloc, cfg1);
        if (!std.mem.eql(u8, cfg1.host, "api.zigar.dev") or cfg1.port != 9000) return error.Unexpected;

        const cfg_str = try m.formatFactoryConfigAlloc(tracked_alloc, .{ .host = "edge.zigar.dev" });
        defer js.freeDecoded([]const u8, tracked_alloc, cfg_str);
        if (!std.mem.eql(u8, cfg_str, "edge.zigar.dev:default")) return error.Unexpected;

        // `StrBox extends Box<string>` inherits `value: []const u8` and `meta: ?[]const u8 = null`
        const echoed = try m.echoStrBoxAlloc(tracked_alloc, .{ .value = "zig", .extra = 9 });
        defer js.freeDecoded(m.StrBox, tracked_alloc, echoed);
        if (!std.mem.eql(u8, echoed.value, "zig!") or echoed.extra != 10) return error.Unexpected;
        if (!std.mem.eql(u8, echoed.meta orelse return error.Unexpected, "auto-meta")) return error.Unexpected;

        // Chained generic handle inheritance `Svc extends MidEmitter<string>` (`BaseEmitter<string, number>`)
        var svc = try m.makeSvc("jobs", 8081);
        defer svc.deinit();
        if ((try svc.port()) != 8081) return error.Unexpected;
        const topic = try svc.topicAlloc(tracked_alloc);
        defer js.freeDecoded([]const u8, tracked_alloc, topic);
        if (!std.mem.eql(u8, topic, "jobs")) return error.Unexpected;
        if ((try svc.emit("done")) != 9) return error.Unexpected;
        try std.testing.expectError(error.TypeError, m.produceBadSvc());

        // Generic base class instantiation `NumberStore extends StoreBase<number>`
        var store = try m.NumberStore.init(10);
        defer store.deinit();
        if ((try store.getCurrent()) != 10) return error.Unexpected;
        try store.setCurrent(25);
        if ((try store.step()) != 26) return error.Unexpected;
        if ((try store.getCurrent()) != 26) return error.Unexpected;

        // Object-literal type alias with method (`LoggerT = { level: number; log(msg: string): string }`)
        // lowers to `.handle_wrapper`, preserves receiver `this.level`, and validates `required_methods`!
        var logger = try m.makeLoggerT(2);
        defer logger.deinit();
        if ((try logger.level()) != 2) return error.Unexpected;
        try logger.setLevel(5);
        const logged = try logger.logAlloc(tracked_alloc, "boot");
        defer js.freeDecoded([]const u8, tracked_alloc, logged);
        if (!std.mem.eql(u8, logged, "[5] boot")) return error.Unexpected;
        try std.testing.expectError(error.TypeError, m.produceBadLoggerT());

        // `NullOnlyBox extends NullableUnionBox<null>` collapses `null | string` -> `?[]const u8` (`.null_only`)
        // and `null | "alpha" | "beta"` -> `?enum { alpha, beta }` (`.null_only`), rejecting numbers (`no Any arm`)!
        const n1 = try m.echoNullOnlyBoxAlloc(tracked_alloc, .{ .x = null, .y = null });
        defer js.freeDecoded(m.NullOnlyBox, tracked_alloc, n1);
        if (n1.x != null or n1.y != null) return error.Unexpected;

        const n2 = try m.echoNullOnlyBoxAlloc(tracked_alloc, .{ .x = "ok", .y = .alpha });
        defer js.freeDecoded(m.NullOnlyBox, tracked_alloc, n2);
        if (!std.mem.eql(u8, n2.x orelse return error.Unexpected, "ok!")) return error.Unexpected;
        if (n2.y != .beta) return error.Unexpected;

        try std.testing.expectError(error.TypeError, m.produceNumericNullOnlyBoxAlloc(tracked_alloc));

        // `ExtOptsT extends OptsT` and `ExtPick extends Pick<OptsI, 'a'>` preserve inherited fields cleanly!
        const eo = try m.echoExtOptsTAlloc(tracked_alloc, .{ .a = 10, .c = 20 });
        defer js.freeDecoded(m.ExtOptsT, tracked_alloc, eo);
        if (eo.a != 11 or eo.c != 22) return error.Unexpected;
        if (!std.mem.eql(u8, eo.b orelse return error.Unexpected, "from-js")) return error.Unexpected;

        const ep = try m.echoExtPick(.{ .a = 3, .c = 4 });
        if (ep.a != 6 or ep.c != 12) return error.Unexpected;

        // `ExtLoggerT extends LoggerT` inherits `level` + `log` from object-literal type alias AND validates `extra`!
        var ext_log = try m.makeExtLoggerT(3, 7);
        defer ext_log.deinit();
        if ((try ext_log.level()) != 3 or (try ext_log.extra()) != 7) return error.Unexpected;
        const ext_msg = try ext_log.logAlloc(tracked_alloc, "up");
        defer js.freeDecoded([]const u8, tracked_alloc, ext_msg);
        if (!std.mem.eql(u8, ext_msg, "[3+7] up")) return error.Unexpected;
        try std.testing.expectError(error.TypeError, m.produceBadExtLoggerT());

        // Handle-bearing intersections: `Inter`, `Both = LoggerT & { extra: number }`, and inline `{ a: number } & { run(): number }`!
        var inter = try m.makeInter(10);
        defer inter.deinit();
        if ((try inter.a()) != 10) return error.Unexpected;
        if ((try inter.run(5)) != 15) return error.Unexpected;
        if ((try inter.a()) != 15) return error.Unexpected;
        try std.testing.expectError(error.TypeError, m.produceBadInter());

        var both = try m.makeBoth(4, 9);
        defer both.deinit();
        if ((try both.level()) != 4 or (try both.extra()) != 9) return error.Unexpected;
        const both_msg = try both.logAlloc(tracked_alloc, "hi");
        defer js.freeDecoded([]const u8, tracked_alloc, both_msg);
        if (!std.mem.eql(u8, both_msg, "4:9:hi")) return error.Unexpected;

        var inl = try m.makeInlineInter(20);
        defer inl.deinit();
        if ((try inl.a()) != 20) return error.Unexpected;
        if ((try inl.run()) != 21) return error.Unexpected;
        if ((try m.consumeInlineInter(.{ .ref = inl.ref })) != 44) return error.Unexpected;
    }

    try checkInvariants(handles_before, allocs_before);
    return out_alloc.dupe(u8, "factory-merged-and-generic-extends-ok");
}

