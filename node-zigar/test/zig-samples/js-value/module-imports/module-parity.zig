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
