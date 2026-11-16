const std = @import("std");
const zigar = @import("zigar");
const libs = @import("libs50.zig");

const js = zigar.js;
const Ref = js.Ref;

pub const HostError = js.CallError;

const NodePath = js.Module("node:path");
const NodeUrl = js.Module("node:url");
const LocalEsm = js.Module("./esm-helper.mjs");
const LocalCjsFn = js.Module("./cjs-export-equals.cjs");
const LocalCjsClass = js.Module("./cjs-class.cjs");
const SingletonEsm = js.Module("./singleton-esm.mjs");
const NamedCjs = js.Module("./named.cjs");
const FalsyEsm = js.Module("./falsy.mjs");
const FacadeEsm = js.Module("./facade.mjs");
const FnCjs = js.Module("./fn.cjs");
const TsCjs = js.Module("./ts.cjs");

pub const unused_mod_desc = js.Module("unused-parity-mod");

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn exerciseNodeBuiltins(alloc: std.mem.Allocator) ![]const u8 {
    const joined = try libs.pathJoin(alloc, "dir", "sub/item.zig");
    defer alloc.free(joined);

    const base = try NodePath.call(
        fn (std.mem.Allocator, []const u8) HostError![]const u8,
        "basename",
        .{ alloc, joined },
    );
    defer alloc.free(base);

    const path_def = try NodePath.default(Ref(js.Object));
    defer path_def.deinit();
    const def_joined = try path_def.call(
        fn (std.mem.Allocator, []const u8, []const u8) HostError![]const u8,
        "join",
        .{ alloc, "p", base },
    );
    defer alloc.free(def_joined);

    const url_obj = try NodeUrl.construct(
        fn ([]const u8, []const u8) HostError!Ref(js.Object),
        "URL",
        .{ "/docs/spec?v=2", "https://example.org" },
    );
    defer url_obj.deinit();
    const href = try url_obj.getAlloc(alloc, HostError![]const u8, "href");
    defer alloc.free(href);

    const file_url = try NodeUrl.call(
        fn ([]const u8) HostError!Ref(js.Object),
        "pathToFileURL",
        .{ "/var/data/demo.txt" },
    );
    defer file_url.deinit();
    const protocol = try file_url.getAlloc(alloc, HostError![]const u8, "protocol");
    defer alloc.free(protocol);

    return std.fmt.allocPrint(alloc, "{s}|{s}|{s}|{s}", .{ base, def_joined, href, protocol });
}

pub fn exerciseLocalEsm(alloc: std.mem.Allocator, who: []const u8) ![]const u8 {
    const has_fmt = try LocalEsm.has("formatPair");
    if (!has_fmt) return error.JsException;

    const ver = try LocalEsm.get(i32, "version");
    const paired = try LocalEsm.call(
        fn (std.mem.Allocator, []const u8, []const u8) HostError![]const u8,
        "formatPair",
        .{ alloc, "zig", "esm" },
    );
    defer alloc.free(paired);

    const greeted = try LocalEsm.callDefault(
        fn (std.mem.Allocator, []const u8) HostError![]const u8,
        .{ alloc, who },
    );
    defer alloc.free(greeted);

    const ns = try LocalEsm.namespace();
    defer ns.deinit();
    const ns_ver = ns.get(i32, "version");

    const def_fn = try LocalEsm.default(Ref(js.Function));
    defer def_fn.deinit();
    const via_handle = try def_fn.invoke(
        fn (std.mem.Allocator, []const u8) HostError![]const u8,
        .{ alloc, "handle" },
    );
    defer alloc.free(via_handle);

    return std.fmt.allocPrint(alloc, "v{d}=v{d}|{s}|{s}|{s}", .{ ver, ns_ver, paired, greeted, via_handle });
}

pub fn exerciseLocalCjsExportEquals(alloc: std.mem.Allocator, a: i32, b: i32) ![]const u8 {
    const computed = try LocalCjsFn.callExportEquals(fn (i32, i32) HostError!i32, .{ a, b });

    const has_extra = try LocalCjsFn.has("extra");
    if (!has_extra) return error.JsException;

    const extra = try LocalCjsFn.getAlloc(alloc, []const u8, "extra");
    defer alloc.free(extra);

    const described = try LocalCjsFn.call(
        fn (std.mem.Allocator, []const u8) HostError![]const u8,
        "describe",
        .{ alloc, "ok" },
    );
    defer alloc.free(described);

    const raw_fn = try LocalCjsFn.default(Ref(js.Function));
    defer raw_fn.deinit();
    const direct_call = raw_fn.invoke(fn (i32, i32) i32, .{ 7, 8 });

    const class_tag = try LocalCjsClass.getAlloc(alloc, []const u8, "tag");
    defer alloc.free(class_tag);

    const acc = try LocalCjsClass.constructExportEquals(fn (i32) HostError!Ref(js.Object), .{ 100 });
    defer acc.deinit();
    const acc_total = acc.call(fn (i32) i32, "add", .{ 55 });

    return std.fmt.allocPrint(
        alloc,
        "{d}|{s}|{s}|{d}|{s}|{d}",
        .{ computed, extra, described, direct_call, class_tag, acc_total },
    );
}

pub fn exerciseNamespaceShadowMutation(alloc: std.mem.Allocator) ![]const u8 {
    const live_before = try SingletonEsm.get(i32, "live");
    const def_obj = try SingletonEsm.default(Ref(js.Object));
    defer def_obj.deinit();
    const def_live_before = def_obj.get(i32, "live");

    var set_failed = false;
    if (SingletonEsm.set("live", @as(i32, 5))) |_| {
        return error.UnexpectedMutationSuccess;
    } else |err| {
        if (err != error.TypeError and err != error.JsException) return err;
        set_failed = true;
    }

    const live_after_set = try SingletonEsm.get(i32, "live");
    const def_live_after_set = def_obj.get(i32, "live");

    const deleted_live = try SingletonEsm.delete("live");
    const has_live = try SingletonEsm.has("live");
    const def_live_after_del = def_obj.get(i32, "live");

    try SingletonEsm.set("onlyOnDefault", @as(i32, 77));
    const only_via_mod = try SingletonEsm.get(i32, "onlyOnDefault");
    const only_via_def = def_obj.get(i32, "onlyOnDefault");

    const deleted_only = try SingletonEsm.delete("onlyOnDefault");
    const has_only_after_del = try SingletonEsm.has("onlyOnDefault");

    try SingletonEsm.set("onlyOnDefault", @as(i32, 42));

    return std.fmt.allocPrint(
        alloc,
        "{d}:{d}|{s}|{d}:{d}|del={any}:has={any}:def={d}|only={d}={d}|del_only={any}:has_only={any}",
        .{
            live_before,
            def_live_before,
            if (set_failed) "set_err" else "no_err",
            live_after_set,
            def_live_after_set,
            deleted_live,
            has_live,
            def_live_after_del,
            only_via_mod,
            only_via_def,
            deleted_only,
            has_only_after_del,
        },
    );
}

pub fn bumpSingletonVisits(delta: i32) !i32 {
    return SingletonEsm.call(fn (i32) HostError!i32, "recordVisit", .{delta});
}

pub fn exerciseNamedCjs(alloc: std.mem.Allocator) ![]const u8 {
    const initial = try NamedCjs.get(i32, "counter");
    const bumped = try NamedCjs.call(fn () HostError!i32, "bump", .{});
    const after_bump = try NamedCjs.get(i32, "counter");

    try NamedCjs.set("counter", @as(i32, 42));
    const after_set = try NamedCjs.get(i32, "counter");
    const bumped_after_set = try NamedCjs.call(fn () HostError!i32, "bump", .{});

    const deleted = try NamedCjs.delete("counter");
    const has_after_del = try NamedCjs.has("counter");

    const def_obj = try NamedCjs.default(Ref(js.Object));
    defer def_obj.deinit();
    const def_has_after_del = def_obj.has("counter");

    try NamedCjs.set("counter", @as(i32, 1));
    const restored = try NamedCjs.get(i32, "counter");

    return std.fmt.allocPrint(
        alloc,
        "{d}|{d}={d}|{d}->{d}|del={any}:has={any}:def_has={any}|restored={d}",
        .{
            initial,
            bumped,
            after_bump,
            after_set,
            bumped_after_set,
            deleted,
            has_after_del,
            def_has_after_del,
            restored,
        },
    );
}

pub fn exerciseFalsyEsm(alloc: std.mem.Allocator) ![]const u8 {
    const zero = try FalsyEsm.get(i32, "zero");
    const nope = try FalsyEsm.get(bool, "nope");
    const nil_ref = try FalsyEsm.get(Ref(js.Any), "nil");
    defer nil_ref.deinit();
    const undef_ref = try FalsyEsm.get(Ref(js.Any), "undef");
    defer undef_ref.deinit();

    var set_failed = false;
    if (FalsyEsm.set("live", @as(i32, 5))) |_| {
        return error.UnexpectedMutationSuccess;
    } else |err| {
        if (err != error.TypeError and err != error.JsException) return err;
        set_failed = true;
    }
    const def_obj = try FalsyEsm.default(Ref(js.Object));
    defer def_obj.deinit();
    const def_live = def_obj.get(i32, "live");
    const deleted_live = try FalsyEsm.delete("live");

    return std.fmt.allocPrint(
        alloc,
        "z={d}|b={any}|null={any}|undef={any}|set_err={any}:def={d}:del={any}",
        .{
            zero,
            nope,
            nil_ref.handle == js.reserved_null_handle,
            undef_ref.handle == js.reserved_undefined_handle,
            set_failed,
            def_live,
            deleted_live,
        },
    );
}

pub fn exerciseRuntimeRelativeImport(spec: []const u8, a: i32, b: i32) !i32 {
    const dyn_mod = try js.importModuleDynamicAs(HostError!Ref(js.Function), spec);
    defer dyn_mod.deinit();
    return dyn_mod.invoke(fn (i32, i32) HostError!i32, .{ a, b });
}

pub fn exerciseEsmFacade(alloc: std.mem.Allocator) ![]const u8 {
    const has_ver = try FacadeEsm.has("version");
    const ver = try FacadeEsm.get(i32, "version");

    var set_failed = false;
    if (FacadeEsm.set("version", @as(i32, 9))) |_| {
        return error.UnexpectedMutationSuccess;
    } else |err| {
        if (err != error.TypeError and err != error.JsException) return err;
        set_failed = true;
    }
    const named_has_ver = try NamedCjs.has("version");
    const del_ver = try FacadeEsm.delete("version");
    const ver_after = try FacadeEsm.get(i32, "version");

    try FacadeEsm.set("facadeExtra", @as(i32, 33));
    const via_facade = try FacadeEsm.get(i32, "facadeExtra");
    const via_named = try NamedCjs.get(i32, "facadeExtra");
    const del_extra = try FacadeEsm.delete("facadeExtra");
    const has_extra_after = try FacadeEsm.has("facadeExtra");

    return std.fmt.allocPrint(
        alloc,
        "has={any}:v={d}|set_err={any}:named_has={any}:del={any}:after={d}|extra={d}={d}:del={any}:has={any}",
        .{
            has_ver,
            ver,
            set_failed,
            named_has_ver,
            del_ver,
            ver_after,
            via_facade,
            via_named,
            del_extra,
            has_extra_after,
        },
    );
}

pub fn exerciseFnCjs(alloc: std.mem.Allocator) ![]const u8 {
    const c1 = try FnCjs.callExportEquals(fn (i32) HostError!i32, .{10});
    const extra0 = try FnCjs.get(i32, "extra");

    try FnCjs.set("extra", @as(i32, 20));
    const extra1 = try FnCjs.get(i32, "extra");
    const c2 = try FnCjs.callExportEquals(fn (i32) HostError!i32, .{10});

    const deleted = try FnCjs.delete("extra");
    const has_after_del = try FnCjs.has("extra");

    try FnCjs.set("extra", @as(i32, 1));
    const c3 = try FnCjs.callExportEquals(fn (i32) HostError!i32, .{10});

    return std.fmt.allocPrint(
        alloc,
        "{d}:{d}|{d}->{d}|del={any}:has={any}|restored={d}",
        .{
            c1,
            extra0,
            extra1,
            c2,
            deleted,
            has_after_del,
            c3,
        },
    );
}

pub fn exerciseTsEsModuleCjs(alloc: std.mem.Allocator) ![]const u8 {
    const has_named = try TsCjs.has("named");
    const named = try TsCjs.get(i32, "named");
    const has_inner = try TsCjs.has("inner");
    const inner = try TsCjs.get(i32, "inner");

    const def_obj = try TsCjs.default(Ref(js.Object));
    defer def_obj.deinit();
    const def_inner = def_obj.get(i32, "inner");

    try TsCjs.set("added", @as(i32, 1));
    const has_added = try TsCjs.has("added");
    const added_via_mod = try TsCjs.get(i32, "added");
    const added_via_def = def_obj.get(i32, "added");

    const del_added = try TsCjs.delete("added");
    const has_added_after = try TsCjs.has("added");

    return std.fmt.allocPrint(
        alloc,
        "named={any}:{d}|inner={any}:{d}={d}|added={any}:{d}={d}|del={any}:has={any}",
        .{
            has_named,
            named,
            has_inner,
            inner,
            def_inner,
            has_added,
            added_via_mod,
            added_via_def,
            del_added,
            has_added_after,
        },
    );
}

