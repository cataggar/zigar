const std = @import("std");
const zigar = @import("zigar");

const js = zigar.js;
const Ref = js.Ref;

pub const HostError = js.CallError;

const PlainCjs = js.Module("./cjs-pkg/plain-cjs.js");
const FacadeOverride = js.Module("./facade-override.js");

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn exercisePlainDotJsCjs(alloc: std.mem.Allocator) ![]const u8 {
    const initial = try PlainCjs.get(i32, "count");
    const bumped = try PlainCjs.call(fn () HostError!i32, "bump", .{});
    const after_bump = try PlainCjs.get(i32, "count");

    try PlainCjs.set("count", @as(i32, 42));
    const after_set = try PlainCjs.get(i32, "count");
    const bumped_after_set = try PlainCjs.call(fn () HostError!i32, "bump", .{});

    try PlainCjs.set("count", @as(i32, 1));
    const restored = try PlainCjs.get(i32, "count");

    return std.fmt.allocPrint(
        alloc,
        "{d}|{d}={d}|{d}->{d}|restored={d}",
        .{ initial, bumped, after_bump, after_set, bumped_after_set, restored },
    );
}

pub fn exerciseFacadeOverrideDotJsEsm(alloc: std.mem.Allocator) ![]const u8 {
    const facade_count = try FacadeOverride.get(i32, "count");
    const cjs_before = try PlainCjs.get(i32, "count");

    var set_failed = false;
    if (FacadeOverride.set("count", @as(i32, 77))) |_| {
        return error.UnexpectedMutationSuccess;
    } else |err| {
        if (err != error.TypeError and err != error.JsException) return err;
        set_failed = true;
    }

    const cjs_after_failed_set = try PlainCjs.get(i32, "count");
    const facade_after_failed_set = try FacadeOverride.get(i32, "count");
    const bumped_via_reexport = try FacadeOverride.call(fn () HostError!i32, "bump", .{});
    const facade_still_overridden = try FacadeOverride.get(i32, "count");
    try PlainCjs.set("count", @as(i32, 1));

    const def_obj = try FacadeOverride.default(Ref(js.Object));
    defer def_obj.deinit();
    const def_count = def_obj.get(i32, "count");

    return std.fmt.allocPrint(
        alloc,
        "facade={d}:cjs={d}|set_err={any}:cjs={d}:facade={d}|bumped={d}:facade={d}:def={d}",
        .{
            facade_count,
            cjs_before,
            set_failed,
            cjs_after_failed_set,
            facade_after_failed_set,
            bumped_via_reexport,
            facade_still_overridden,
            def_count,
        },
    );
}
