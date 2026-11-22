//! `node-console-hello-world` — Node.js 26 Active LTS (`@types/node@26`) console & CLI example.
//!
//! Mirrors `taggartsoftware/ts2rs/node-console-hello-world`: reads `process.argv`
//! and logs both a greeting and the command-line argument slice via `console.log`.

const std = @import("std");
const zigar = @import("zigar");
const node = @import("node");
const js = zigar.js;

pub fn hello(allocator: std.mem.Allocator, name: []const u8) !void {
    const proc = try node.globals.process.get();
    defer proc.deinit();

    const argv = try proc.argvAlloc(allocator);
    defer js.freeDecoded([]const []const u8, allocator, argv);

    const greeting = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
    defer allocator.free(greeting);

    const con = try node.globals.console.get();
    defer con.deinit();

    try con.log(.{greeting});
    try con.log(.{ "args:", argv });
}

pub fn activeHandles() usize {
    return js.activeHandleCount();
}

pub fn activeCallbacks() usize {
    return js.activeCallbackCount();
}
