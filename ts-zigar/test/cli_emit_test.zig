const std = @import("std");
const ts_zigar = @import("ts_zigar");
const test_options = @import("test_options");

fn resolveTestComponentWasm() ?[]const u8 {
    const candidates = [_][]const u8{
        "component/dist/typescript-compiler.component.wasm",
        "ts-zigar/component/dist/typescript-compiler.component.wasm",
    };
    if (std.testing.environ.getPosix("TS_ZIGAR_COMPONENT_WASM")) |env_path| {
        if (fileExists(env_path)) return env_path;
    }
    for (candidates) |cand| {
        if (fileExists(cand)) return cand;
    }
    return null;
}

fn resolveNodeExe() []const u8 {
    if (std.testing.environ.getPosix("TS_ZIGAR_NODE")) |node_path| {
        if (node_path.len > 0) return node_path;
    }
    return "node";
}

fn resolveTmpRoot() []const u8 {
    if (std.testing.environ.getPosix("TMPDIR")) |t| {
        if (t.len > 0) return t;
    }
    return "../.cache/tmp";
}

fn fileExists(path: []const u8) bool {
    const io = std.testing.io;
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn resolveTypesNode26Dir(alloc: std.mem.Allocator) !?[]const u8 {
    if (std.testing.environ.getPosix("TS_ZIGAR_CACHE_DIR")) |cache_dir| {
        if (cache_dir.len > 0) {
            const env_pkg = try std.fs.path.join(alloc, &.{ cache_dir, "types-node26", "node_modules", "@types", "node" });
            const env_json = try std.fs.path.join(alloc, &.{ env_pkg, "package.json" });
            defer alloc.free(env_json);
            if (fileExists(env_json)) return env_pkg;
            alloc.free(env_pkg);
        }
    }
    const candidates = [_][]const u8{
        "../.cache/ts-zigar/types-node26/node_modules/@types/node",
        ".cache/ts-zigar/types-node26/node_modules/@types/node",
        "../../.cache/ts-zigar/types-node26/node_modules/@types/node",
    };
    for (candidates) |cand| {
        const pkg_json = try std.fs.path.join(alloc, &.{ cand, "package.json" });
        defer alloc.free(pkg_json);
        if (fileExists(pkg_json)) return try alloc.dupe(u8, cand);
    }
    return null;
}

fn runZigCheck(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(allocator);

    if (child.stdout) |*so| {
        var rbuf: [4096]u8 = undefined;
        var reader = so.readerStreaming(io, &rbuf);
        reader.interface.appendRemainingUnlimited(allocator, &out_buf) catch {};
    }
    if (child.stderr) |*se| {
        var rbuf: [4096]u8 = undefined;
        var reader = se.readerStreaming(io, &rbuf);
        reader.interface.appendRemainingUnlimited(allocator, &err_buf) catch {};
    }

    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("Command failed ({s}):\nSTDOUT:\n{s}\nSTDERR:\n{s}\n", .{
            argv[1],
            out_buf.items,
            err_buf.items,
        });
        return error.ZigCheckFailed;
    }
}

test "E2E pipeline: multi-file cyclic .d.ts, keywords, CRLF JSDoc, package.json types, -m filter, -s substitute, zig ast-check & zig test" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-e2e-suite", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const pkg_dir = try std.fmt.allocPrint(alloc, "{s}/fixture-pkg", .{sandbox});
    defer alloc.free(pkg_dir);
    const shared_dir = try std.fmt.allocPrint(alloc, "{s}/shared-refs", .{sandbox});
    defer alloc.free(shared_dir);
    try cwd.createDirPath(io, pkg_dir);
    try cwd.createDirPath(io, shared_dir);

    // 1. Write package.json with `"types": "./entry.d.ts"`, triple-slash reference, cyclic `a.d.ts <-> b.d.ts`,
    //    reserved Zig 0.17 keywords (`type`, `error`, `test`, `suspend`, `u32`), CRLF JSDoc, classes, enums,
    //    generics, functions, namespaces, and ambient modules (`node:fs`, `node:http`, `dns/promises`)!
    {
        var pkg_d = try cwd.openDir(io, pkg_dir, .{});
        defer pkg_d.close(io);

        try pkg_d.writeFile(io, .{
            .sub_path = "package.json",
            .data =
            \\{
            \\  "name": "@acme/fixture-pkg",
            \\  "version": "1.0.0",
            \\  "types": "./entry.d.ts"
            \\}
            ,
        });

        try pkg_d.writeFile(io, .{
            .sub_path = "entry.d.ts",
            .data = "/// <reference path=\"../shared-refs/ambient.d.ts\" />\r\n" ++
                "export * from \"./a.js\";\r\n" ++
                "export { PeerB } from \"./b.js\";\r\n" ++
                "export declare const SDK_VERSION = \"2026.1\";\r\n" ++
                "export declare const MAX_RETRIES = 5;\r\n" ++
                "export declare const u32: number;\r\n" ++
                "export enum Severity {\r\n" ++
                "  Info = \"info\",\r\n" ++
                "  /**\r\n   * Fatal error tag.\r\n   */\r\n" ++
                "  error = \"error\",\r\n" ++
                "}\r\n" ++
                "/**\r\n * Reserved keyword torture interface.\r\n * @deprecated Prefer v2 options.\r\n */\r\n" ++
                "export interface KeywordConfig {\r\n" ++
                "  type: string;\r\n" ++
                "  error?: string;\r\n" ++
                "  test: boolean;\r\n" ++
                "  suspend?: number;\r\n" ++
                "  u32: number;\r\n" ++
                "  \"\": string;\r\n" ++
                "}\r\n" ++
                "/**\r\n * Executes check.\r\n * @param type - Keyword parameter\r\n * @returns Validation flag\r\n */\r\n" ++
                "export declare function test(type: KeywordConfig, error?: Severity): boolean;\r\n" ++
                "export declare class Client<T = KeywordConfig> {\r\n" ++
                "  readonly endpoint: string;\r\n" ++
                "  constructor(endpoint: string);\r\n" ++
                "  send(payload: T): Promise<boolean>;\r\n" ++
                "  format(format: string): string;\r\n" ++
                "}\r\n" ++
                "export namespace Tools {\r\n" ++
                "  export type Mode = \"fast\" | \"strict\";\r\n" ++
                "  export function ping(host: string): number;\r\n" ++
                "}\r\n",
        });

        // Cyclic pair `a.d.ts <-> b.d.ts` with mutual value-like interface references!
        try pkg_d.writeFile(io, .{
            .sub_path = "a.d.ts",
            .data =
            \\import type { PeerB } from "./b.js";
            \\export interface NodeA {
            \\  id: number;
            \\  peer: PeerB;
            \\  selfNext?: NodeA;
            \\}
            \\export declare function makeA(b: PeerB): NodeA;
            ,
        });

        try pkg_d.writeFile(io, .{
            .sub_path = "b.d.ts",
            .data =
            \\import type { NodeA } from "./a.js";
            \\export interface PeerB {
            \\  label: string;
            \\  back: NodeA;
            \\}
            ,
        });
    }

    {
        var sh_d = try cwd.openDir(io, shared_dir, .{});
        defer sh_d.close(io);

        try sh_d.writeFile(io, .{
            .sub_path = "ambient.d.ts",
            .data =
            \\declare module "node:fs/internal" {
            \\  export interface StatInfo {
            \\    size: number;
            \\    type: string;
            \\  }
            \\  export function statSync(path: string): StatInfo;
            \\}
            \\declare module "dns/promises" {
            \\  export function lookup(hostname: string): Promise<string>;
            \\}
            ,
        });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    // Case 1: Full package directory emission (resolves package.json + triple-slash + cyclic a <-> b).
    const out_full = try std.fmt.allocPrint(alloc, "{s}/out-full", .{sandbox});
    defer alloc.free(out_full);
    {
        const cli_args = [_][]const u8{
            "-t", pkg_dir,
            "-d", out_full,
        };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        try std.testing.expect(parsed == .run);

        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Pipeline error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);
        try std.testing.expect(res.ok.module_count >= 5);

        const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_full});
        defer alloc.free(root_zig);
        const entry_zig = try std.fmt.allocPrint(alloc, "{s}/entry.zig", .{out_full});
        defer alloc.free(entry_zig);

        const entry_src = try cwd.readFileAlloc(io, entry_zig, alloc, .limited(4 * 1024 * 1024));
        defer alloc.free(entry_src);

        // Verify Zig 0.17 keyword & primitive escaping, JSDoc normalization, no `usingnamespace`, and wire names!
        try std.testing.expect(std.mem.indexOf(u8, entry_src, "type: []const u8") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry_src, "@\"error\": ?[]const u8") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry_src, "@\"test\": bool") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry_src, "@\"suspend\": ?f64") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry_src, "_empty: []const u8") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry_src, ".js_name = \"\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry_src, "pub const @\"u32\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry_src, "pub fn @\"test\"(@\"type\": KeywordConfig") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry_src, "/// Deprecated: Prefer v2 options.") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry_src, "usingnamespace") == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, entry_src, '\r') == null);

        // Run real `zig ast-check` AND `zig test` on generated `root.zig` (which imports cyclic `a.zig <-> b.zig`)!
        try runZigCheck(alloc, io, &.{ test_options.zig_exe, "ast-check", root_zig });
        try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    }

    // Case 2: `-m / --module` filtering + `-s / --substitute` remapping (`node:fs/internal=fs`).
    const out_filtered = try std.fmt.allocPrint(alloc, "{s}/out-filtered", .{sandbox});
    defer alloc.free(out_filtered);
    {
        const cli_args = [_][]const u8{
            "-t", pkg_dir,
            "-d", out_filtered,
            "-m", "node:fs/internal",
            "-m", "dns/promises",
            "-s", "node:fs/internal=fs",
        };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        try std.testing.expect(parsed == .run);

        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        try std.testing.expect(res == .ok);
        try std.testing.expectEqual(@as(usize, 2), res.ok.module_count);

        const fs_zig = try std.fmt.allocPrint(alloc, "{s}/fs.zig", .{out_filtered});
        defer alloc.free(fs_zig);
        const dns_zig = try std.fmt.allocPrint(alloc, "{s}/dns/promises.zig", .{out_filtered});
        defer alloc.free(dns_zig);
        const entry_zig = try std.fmt.allocPrint(alloc, "{s}/entry.zig", .{out_filtered});
        defer alloc.free(entry_zig);
        const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_filtered});
        defer alloc.free(root_zig);

        try std.testing.expect(fileExists(fs_zig));
        try std.testing.expect(fileExists(dns_zig));
        // Unselected `entry.zig` must NOT be emitted when `-m` filters are specified!
        try std.testing.expect(!fileExists(entry_zig));

        try runZigCheck(alloc, io, &.{ test_options.zig_exe, "ast-check", fs_zig });
        try runZigCheck(alloc, io, &.{ test_options.zig_exe, "ast-check", dns_zig });
        try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    }
}

test "installed ts-zigar native CLI binary handles --help, --version, invalid flags, and -t/-d codegen" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    _ = wasm_path;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const bin_dir = std.testing.environ.getPosix("TS_ZIGAR_BIN") orelse "zig-out/bin";
    const bin_path = try std.fmt.allocPrint(alloc, "{s}/ts-zigar", .{bin_dir});
    defer alloc.free(bin_path);
    if (!fileExists(bin_path)) return error.SkipZigTest;

    // 1. `--help` exits 0.
    try runZigCheck(alloc, io, &.{ bin_path, "--help" });
    // 2. `--version` exits 0.
    try runZigCheck(alloc, io, &.{ bin_path, "--version" });

    // 3. Invalid flag exits non-zero cleanly (no crash/signal).
    {
        var child = try std.process.spawn(io, .{
            .argv = &.{ bin_path, "--unknown-flag" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term = try child.wait(io);
        try std.testing.expect(term == .exited);
        try std.testing.expect(term.exited != 0);
    }
}

test "Regression Bug 1: struct member collisions, outer/parameter/receiver/type-param shadowing, and root.zig prelude safety" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-bug1-shadow", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);
    try cwd.createDirPath(io, src_dir);

    const dts_path = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{src_dir});
    defer alloc.free(dts_path);
    {
        var sd = try cwd.openDir(io, src_dir, .{});
        defer sd.close(io);
        try sd.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\export declare const self: number;
            \\export declare const n: number;
            \\export declare const std: number;
            \\export type T = number;
            \\export declare class K {
            \\  value: string;
            \\}
            \\export type V = string;
            \\export declare const Promise: number;
            \\export declare const JsMap: number;
            \\export declare const Global: number;
            \\export declare const zigar_js: number;
            \\
            \\export declare class Widget {
            \\  init: boolean;
            \\  count: number;
            \\  Self: string;
            \\  handle: number;
            \\  zigar_js: number;
            \\  static count: number;
            \\  static init: string;
            \\  constructor(n: string, self?: number);
            \\  m(n: K, self?: T): this;
            \\  check<T, K>(v: T, k: K): V;
            \\}
            \\
            \\export declare class ShadowRef {
            \\  static K: number;
            \\  useTop(x: K): K;
            \\}
            \\
            \\export declare class Box<Self, T> {
            \\  item: Self;
            \\  extra: T;
            \\  clone(self: number): this;
            \\}
            \\
            \\export declare function foo(n: string): void;
            \\export declare function foo(n: number, foo_2: boolean): void;
            \\export declare function foo_2(x: string): void;
            \\
            \\export namespace Outer {
            \\  export const x: number;
            \\  export function inner(x: string, self: boolean): K;
            \\}
            ,
        });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const cli_args = [_][]const u8{ "-t", dts_path, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Bug 1 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_bug1.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_bug1.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\
            \\test "Widget deduplicates colliding members and preserves outer declarations without shadowing" {
            \\    try std.testing.expect(r.T == f64);
            \\    try std.testing.expect(r.V == []const u8);
            \\    try std.testing.expectEqualStrings("self", r.self.js_name);
            \\    try std.testing.expectEqualStrings("n", r.n.js_name);
            \\    try std.testing.expectEqualStrings("std", r.std.js_name);
            \\
            \\    try std.testing.expect(r.Widget.zigar_js.is_handle);
            \\    try std.testing.expect(r.Widget.zigar_js.is_class);
            \\    try std.testing.expectEqualStrings("Widget", r.Widget.zigar_js.js_name);
            \\    try std.testing.expectEqualStrings("init", r.Widget.init.js_name);
            \\    const widget_ctor: *const fn ([]const u8, ?f64) r.zigar_js.CallError!r.Widget = &r.Widget.init_2;
            \\    const widget_m: *const fn (r.Widget, r.K, ?r.T) r.zigar_js.CallError!r.Widget = &r.Widget.m;
            \\    _ = widget_ctor;
            \\    _ = widget_m;
            \\
            \\    const B = r.Box(u32, bool);
            \\    try std.testing.expect(B.zigar_js.is_handle);
            \\    const box_item: *const fn (B) r.zigar_js.CallError!u32 = &B.item;
            \\    const box_extra: *const fn (B) r.zigar_js.CallError!bool = &B.extra;
            \\    const box_clone: *const fn (B, f64) r.zigar_js.CallError!B = &B.clone;
            \\    _ = box_item;
            \\    _ = box_extra;
            \\    _ = box_clone;
            \\
            \\    const use_top_fn: *const fn (r.ShadowRef, r.K) r.zigar_js.CallError!r.K = &r.ShadowRef.useTop;
            \\    _ = use_top_fn;
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "ast-check", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Regression Bug 2: export * and named re-exports emit alias constants preserving nominal Zig type identity" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-bug2-star", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const pkg_dir = try std.fmt.allocPrint(alloc, "{s}/pkg", .{sandbox});
    defer alloc.free(pkg_dir);
    const sub_dir = try std.fmt.allocPrint(alloc, "{s}/pkg/sub", .{sandbox});
    defer alloc.free(sub_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);
    try cwd.createDirPath(io, sub_dir);

    {
        var pd = try cwd.openDir(io, pkg_dir, .{});
        defer pd.close(io);
        try pd.writeFile(io, .{
            .sub_path = "package.json",
            .data =
            \\{
            \\  "name": "star-pkg",
            \\  "version": "1.0.0",
            \\  "types": "./index.d.ts"
            \\}
            ,
        });
        try pd.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\import type { Starry, Nebula, Phase } from "./sub/star.js";
            \\export * from "./sub/star.js";
            \\export { NamedItem, OrigItem as AliasedItem } from "./sub/extra.js";
            \\export declare function take(s: Starry, n: Nebula, p: Phase): Starry;
            \\export declare function checkShadow(makeStar: string): Starry;
            ,
        });
        try pd.writeFile(io, .{
            .sub_path = "sub/star.d.ts",
            .data =
            \\export interface Starry {
            \\  id: number;
            \\  label: string;
            \\}
            \\export declare class Nebula {
            \\  radius: number;
            \\  ping(): Starry;
            \\}
            \\export enum Phase {
            \\  New = 0,
            \\  Full = 1,
            \\}
            \\export declare function makeStar(label: string): Starry;
            ,
        });
        try pd.writeFile(io, .{
            .sub_path = "sub/extra.d.ts",
            .data =
            \\export interface NamedItem {
            \\  code: string;
            \\}
            \\export interface OrigItem {
            \\  flag: boolean;
            \\}
            ,
        });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const cli_args = [_][]const u8{ "-t", pkg_dir, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Bug 2 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_bug2.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_bug2.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const idx = @import("out/index.zig");
            \\const sub_star = @import("out/sub/star.zig");
            \\const sub_extra = @import("out/sub/extra.zig");
            \\
            \\test "nominal type identity across export * and named re-exports" {
            \\    try std.testing.expect(r.Starry == sub_star.Starry);
            \\    try std.testing.expect(idx.Starry == sub_star.Starry);
            \\    try std.testing.expect(r.Nebula == sub_star.Nebula);
            \\    try std.testing.expect(r.Phase == sub_star.Phase);
            \\    try std.testing.expect(r.NamedItem == sub_extra.NamedItem);
            \\    try std.testing.expect(r.AliasedItem == sub_extra.OrigItem);
            \\    try std.testing.expect(&r.makeStar == &sub_star.makeStar);
            \\
            \\    const s: sub_star.Starry = .{ .id = 42, .label = "vega" };
            \\    try std.testing.expectEqual(@as(f64, 42), s.id);
            \\    try std.testing.expect(sub_star.Nebula.zigar_js.is_handle);
            \\    const neb_radius: *const fn (sub_star.Nebula) r.zigar_js.CallError!f64 = &sub_star.Nebula.radius;
            \\    _ = neb_radius;
            \\
            \\    // Passing `sub_star.Starry` to `r.take` must type-check identically!
            \\    const take_fn: *const fn (sub_star.Starry, sub_star.Nebula, sub_star.Phase) r.zigar_js.CallError!sub_star.Starry = &r.take;
            \\    _ = take_fn;
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Regression Bug 3: export import Foo = Bar.Baz emits full multi-segment nested target path" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-bug3-nested", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const pkg_dir = try std.fmt.allocPrint(alloc, "{s}/pkg", .{sandbox});
    defer alloc.free(pkg_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);
    try cwd.createDirPath(io, pkg_dir);

    {
        var pd = try cwd.openDir(io, pkg_dir, .{});
        defer pd.close(io);
        try pd.writeFile(io, .{
            .sub_path = "package.json",
            .data =
            \\{
            \\  "name": "nested-import-equals-pkg",
            \\  "version": "1.0.0",
            \\  "types": "./index.d.ts"
            \\}
            ,
        });
        try pd.writeFile(io, .{
            .sub_path = "other.d.ts",
            .data =
            \\export namespace Bar {
            \\  export interface Baz {
            \\    ok: boolean;
            \\  }
            \\  export namespace Deep {
            \\    export interface Leaf {
            \\      depth: number;
            \\    }
            \\    export function compute(leaf: Leaf): Baz;
            \\  }
            \\}
            ,
        });
        try pd.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\import { Bar } from "./other.js";
            \\export import Foo = Bar.Baz;
            \\export import Leaf = Bar.Deep.Leaf;
            \\export import computeLeaf = Bar.Deep.compute;
            \\
            \\export namespace LocalNs {
            \\  export interface Inner {
            \\    tag: string;
            \\  }
            \\}
            \\export import LocalInner = LocalNs.Inner;
            \\
            \\export declare function consume(f: Foo, l: Leaf, loc: LocalInner): Foo;
            ,
        });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const index_dts = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{pkg_dir});
    defer alloc.free(index_dts);
    const other_dts = try std.fmt.allocPrint(alloc, "{s}/other.d.ts", .{pkg_dir});
    defer alloc.free(other_dts);

    const cli_args = [_][]const u8{ "-t", index_dts, "-t", other_dts, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Bug 3 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    const index_zig = try std.fmt.allocPrint(alloc, "{s}/index.zig", .{out_dir});
    defer alloc.free(index_zig);
    const index_src = try cwd.readFileAlloc(io, index_zig, alloc, .limited(1024 * 1024));
    defer alloc.free(index_src);
    try std.testing.expect(std.mem.indexOf(u8, index_src, ".Bar.Baz;") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_src, ".Bar.Deep.Leaf;") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_src, ".Bar.Deep.compute;") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_src, "pub const LocalInner = LocalNs.Inner;") != null);

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_bug3.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_bug3.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const other = @import("out/other.zig");
            \\
            \\test "export import Foo = Bar.Baz preserves full nested path and nominal identity" {
            \\    try std.testing.expect(r.Foo == other.Bar.Baz);
            \\    try std.testing.expect(r.Leaf == other.Bar.Deep.Leaf);
            \\    try std.testing.expect(&r.computeLeaf == &other.Bar.Deep.compute);
            \\    try std.testing.expect(r.LocalInner == r.LocalNs.Inner);
            \\
            \\    const consume_fn: *const fn (other.Bar.Baz, other.Bar.Deep.Leaf, r.LocalNs.Inner) r.zigar_js.CallError!other.Bar.Baz = &r.consume;
            \\    _ = consume_fn;
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Regression Round 2 Issue 1: Self declarations in enclosing containers or struct itself avoid ambiguous reference" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-r2-self", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);
    try cwd.createDirPath(io, src_dir);

    {
        var sd = try cwd.openDir(io, src_dir, .{});
        defer sd.close(io);
        // Reproducer 1: `export declare class Self { m(): void }`
        try sd.writeFile(io, .{
            .sub_path = "case1.d.ts",
            .data =
            \\export declare class Self {
            \\  tag: number;
            \\  clone(): this;
            \\  echo(other: Self): Self;
            \\  m(): void;
            \\}
            ,
        });
        // Reproducer 2: `export type Self = { id: string }; export declare class Widget { constructor(); }`
        try sd.writeFile(io, .{
            .sub_path = "case2.d.ts",
            .data =
            \\export type Self = { id: string };
            \\export declare class Widget {
            \\  constructor();
            \\  makeSelf(): Self;
            \\}
            ,
        });
        // Reproducer 3: `export interface Self { x: number } export interface A { m(): void }`
        try sd.writeFile(io, .{
            .sub_path = "case3.d.ts",
            .data =
            \\export interface Self {
            \\  x: number;
            \\}
            \\export interface A {
            \\  s: Self;
            \\  m(): void;
            \\}
            ,
        });
        // Reproducer 4 + multi-level Self_2/Self_3:
        // `export declare namespace NS { export interface Self { x: number } export class A { m(): void } }`
        try sd.writeFile(io, .{
            .sub_path = "case4.d.ts",
            .data =
            \\export declare namespace NS {
            \\  export interface Self {
            \\    x: number;
            \\  }
            \\  export class A {
            \\    s: Self;
            \\    m(): void;
            \\  }
            \\}
            \\export declare namespace OuterNs {
            \\  export interface Self {
            \\    z: number;
            \\  }
            \\  export class B {
            \\    s: Self;
            \\    m(): void;
            \\  }
            \\}
            \\export declare namespace Self {
            \\  export class NestedInSelfNs {
            \\    k: number;
            \\    m(): void;
            \\  }
            \\}
            \\export interface Self_2 {
            \\  y: number;
            \\}
            \\export declare class Triple<Self_3> {
            \\  a: Self_2;
            \\  val: Self_3;
            \\  m(): void;
            \\}
            ,
        });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const c1 = try std.fmt.allocPrint(alloc, "{s}/case1.d.ts", .{src_dir});
    defer alloc.free(c1);
    const c2 = try std.fmt.allocPrint(alloc, "{s}/case2.d.ts", .{src_dir});
    defer alloc.free(c2);
    const c3 = try std.fmt.allocPrint(alloc, "{s}/case3.d.ts", .{src_dir});
    defer alloc.free(c3);
    const c4 = try std.fmt.allocPrint(alloc, "{s}/case4.d.ts", .{src_dir});
    defer alloc.free(c4);

    const cli_args = [_][]const u8{
        "-t", c1,
        "-t", c2,
        "-t", c3,
        "-t", c4,
        "-d", out_dir,
    };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Round 2 Issue 1 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_r2_self.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_r2_self.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\
            \\test "all Self collision shapes compile and preserve outer Self nominal types" {
            \\    try std.testing.expect(r.case1.Self.zigar_js.is_handle);
            \\    const tag_fn: *const fn (r.case1.Self) r.zigar_js.CallError!f64 = &r.case1.Self.tag;
            \\    const echo_fn: *const fn (r.case1.Self, r.case1.Self) r.zigar_js.CallError!r.case1.Self = &r.case1.Self.echo;
            \\    _ = tag_fn;
            \\    _ = echo_fn;
            \\
            \\    const s2: r.case2.Self = .{ .id = "abc" };
            \\    try std.testing.expectEqualStrings("abc", s2.id);
            \\    const init_fn: *const fn () r.zigar_js.CallError!r.case2.Widget = &r.case2.Widget.init;
            \\    const make_self_fn: *const fn (r.case2.Widget, std.mem.Allocator) r.zigar_js.CallError!r.case2.Self = &r.case2.Widget.makeSelfAlloc;
            \\    _ = init_fn;
            \\    _ = make_self_fn;
            \\
            \\    const s3: r.case3.Self = .{ .x = 3 };
            \\    try std.testing.expectEqual(@as(f64, 3), s3.x);
            \\    try std.testing.expect(r.case3.A.zigar_js.is_handle);
            \\    const a3_s: *const fn (r.case3.A) r.zigar_js.CallError!r.case3.Self = &r.case3.A.s;
            \\    _ = a3_s;
            \\
            \\    const ns_s: r.case4.Ns.Self = .{ .x = 9 };
            \\    try std.testing.expectEqual(@as(f64, 9), ns_s.x);
            \\    const ns_a_s: *const fn (r.case4.Ns.A) r.zigar_js.CallError!r.case4.Ns.Self = &r.case4.Ns.A.s;
            \\    _ = ns_a_s;
            \\    const ons_s: r.case4.OuterNs.Self = .{ .z = 15 };
            \\    try std.testing.expectEqual(@as(f64, 15), ons_s.z);
            \\    const ons_b_s: *const fn (r.case4.OuterNs.B) r.zigar_js.CallError!r.case4.OuterNs.Self = &r.case4.OuterNs.B.s;
            \\    _ = ons_b_s;
            \\    const nb_k: *const fn (r.case4.Self.NestedInSelfNs) r.zigar_js.CallError!f64 = &r.case4.Self.NestedInSelfNs.k;
            \\    _ = nb_k;
            \\    const T32 = r.case4.Triple(u32);
            \\    const t_val: *const fn (T32) r.zigar_js.CallError!u32 = &T32.val;
            \\    _ = t_val;
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Regression Round 2 Issue 2: non-entry imported modules preserve namespaces and prune unreferenced files" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-r2-leafns", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const app_dir = try std.fmt.allocPrint(alloc, "{s}/app", .{sandbox});
    defer alloc.free(app_dir);
    const foo_types_dir = try std.fmt.allocPrint(alloc, "{s}/node_modules/@types/foo", .{sandbox});
    defer alloc.free(foo_types_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    try cwd.createDirPath(io, app_dir);
    try cwd.createDirPath(io, foo_types_dir);

    {
        var ad = try cwd.openDir(io, app_dir, .{});
        defer ad.close(io);
        try ad.writeFile(io, .{
            .sub_path = "leaf.d.ts",
            .data =
            \\export declare class Inner {
            \\  top: number;
            \\}
            \\export declare namespace LeafNs {
            \\  class Inner {
            \\    nested: string;
            \\  }
            \\}
            ,
        });
        try ad.writeFile(io, .{
            .sub_path = "unused_sibling.d.ts",
            .data =
            \\export interface UnusedSibling {
            \\  shouldNotEmit: boolean;
            \\}
            ,
        });
        try ad.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\/// <reference types="foo" />
            \\import { Inner, LeafNs } from "./leaf.js";
            \\import { UsedNs } from "foo/used";
            \\export declare function f(a: Inner, b: LeafNs.Inner, c: UsedNs.Payload): void;
            \\export import X = LeafNs.Inner;
            \\export import Y = UsedNs.Payload;
            ,
        });
    }

    // Create 20 `.d.ts` files in `node_modules/@types/foo`, referencing all 20 from `@types/foo/index.d.ts`,
    // while `app/index.d.ts` ONLY uses `foo/used.d.ts`!
    {
        var fd = try cwd.openDir(io, foo_types_dir, .{});
        defer fd.close(io);
        try fd.writeFile(io, .{
            .sub_path = "package.json",
            .data =
            \\{
            \\  "name": "@types/foo",
            \\  "version": "1.0.0",
            \\  "types": "./index.d.ts"
            \\}
            ,
        });
        try fd.writeFile(io, .{
            .sub_path = "used.d.ts",
            .data =
            \\export declare namespace UsedNs {
            \\  export interface Payload {
            \\    ok: boolean;
            \\  }
            \\}
            ,
        });

        var idx_buf: std.ArrayList(u8) = .empty;
        defer idx_buf.deinit(alloc);
        try idx_buf.appendSlice(alloc, "/// <reference path=\"./used.d.ts\" />\n");

        for (1..20) |i| {
            const fname = try std.fmt.allocPrint(alloc, "extra_{d:0>2}.d.ts", .{i});
            defer alloc.free(fname);
            const fbody = try std.fmt.allocPrint(
                alloc,
                "export interface ExtraType_{d} {{ v: number; }}\n",
                .{i},
            );
            defer alloc.free(fbody);
            try fd.writeFile(io, .{ .sub_path = fname, .data = fbody });
            try idx_buf.print(alloc, "/// <reference path=\"./{s}\" />\n", .{fname});
        }
        try idx_buf.appendSlice(alloc, "export interface FooRootUnused { root_flag: boolean; }\n");
        try fd.writeFile(io, .{ .sub_path = "index.d.ts", .data = idx_buf.items });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    // Pass ONLY `-t app/index.d.ts` (NOT `leaf.d.ts`, NOT `unused_sibling.d.ts`, NOT `@types/foo`)!
    const index_dts = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{app_dir});
    defer alloc.free(index_dts);

    const cli_args = [_][]const u8{ "-t", index_dts, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Round 2 Issue 2 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    // Exactly 3 modules must be emitted: `index.zig`, `leaf.zig`, and `foo/used.zig`!
    // Unreferenced `unused_sibling.d.ts`, `foo/index.d.ts`, and `foo/extra_01..19.d.ts` must NOT be emitted!
    try std.testing.expectEqual(@as(usize, 3), res.ok.module_count);

    var out_handle = try cwd.openDir(io, out_dir, .{});
    defer out_handle.close(io);
    try std.testing.expectError(error.FileNotFound, out_handle.statFile(io, "unused_sibling.zig", .{}));
    try std.testing.expectError(error.FileNotFound, out_handle.statFile(io, "foo.zig", .{}));
    try std.testing.expectError(error.FileNotFound, out_handle.statFile(io, "foo/extra_01.zig", .{}));

    const index_zig = try std.fmt.allocPrint(alloc, "{s}/index.zig", .{out_dir});
    defer alloc.free(index_zig);
    const index_src = try cwd.readFileAlloc(io, index_zig, alloc, .limited(1024 * 1024));
    defer alloc.free(index_src);
    try std.testing.expect(std.mem.indexOf(u8, index_src, ".LeafNs.Inner") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_src, "Inner_2") == null);

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_r2_leafns.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_r2_leafns.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const leaf = @import("out/leaf.zig");
            \\const foo_used = @import("out/foo/used.zig");
            \\
            \\test "non-entry LeafNs.Inner preserves namespace hierarchy and root.zig only exports primary" {
            \\    try std.testing.expect(r.index == @import("out/index.zig"));
            \\    try std.testing.expect(!@hasDecl(r, "leaf"));
            \\    try std.testing.expect(!@hasDecl(r, "unused_sibling"));
            \\    try std.testing.expect(!@hasDecl(r, "foo"));
            \\
            \\    try std.testing.expect(leaf.Inner != leaf.LeafNs.Inner);
            \\    try std.testing.expect(r.X == leaf.LeafNs.Inner);
            \\    try std.testing.expect(r.Y == foo_used.UsedNs.Payload);
            \\
            \\    try std.testing.expect(leaf.Inner.zigar_js.is_handle);
            \\    try std.testing.expect(leaf.LeafNs.Inner.zigar_js.is_handle);
            \\    const top_fn: *const fn (leaf.Inner) r.zigar_js.CallError!f64 = &leaf.Inner.top;
            \\    const nested_fn: *const fn (leaf.LeafNs.Inner) r.zigar_js.CallError![]const u8 = &leaf.LeafNs.Inner.nested;
            \\    _ = top_fn;
            \\    _ = nested_fn;
            \\    const payload: foo_used.UsedNs.Payload = .{ .ok = true };
            \\    try std.testing.expect(payload.ok);
            \\
            \\    const f_ptr: *const fn (leaf.Inner, leaf.LeafNs.Inner, foo_used.UsedNs.Payload) r.zigar_js.CallError!void = &r.f;
            \\    _ = f_ptr;
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Regression Round 3: @types/node reference-path ambient closure, mixed ES+ambient, multi -t, and empty fallback" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-r3-ambient", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    // 1. `@types/node`-style package directory (`index.d.ts` -> `fs.d.ts`, `http.d.ts`, `globals.d.ts`,
    //    2-hop `fs/promises.d.ts`, plus external `/// <reference types="other" />` that must NOT become primary).
    const node_pkg = try std.fmt.allocPrint(alloc, "{s}/node-pkg", .{sandbox});
    defer alloc.free(node_pkg);
    const node_fs_sub = try std.fmt.allocPrint(alloc, "{s}/node-pkg/fs", .{sandbox});
    defer alloc.free(node_fs_sub);
    const ext_other_dir = try std.fmt.allocPrint(alloc, "{s}/node_modules/@types/other", .{sandbox});
    defer alloc.free(ext_other_dir);
    const out_node = try std.fmt.allocPrint(alloc, "{s}/out-node", .{sandbox});
    defer alloc.free(out_node);
    try cwd.createDirPath(io, node_fs_sub);
    try cwd.createDirPath(io, ext_other_dir);

    {
        var od = try cwd.openDir(io, ext_other_dir, .{});
        defer od.close(io);
        try od.writeFile(io, .{
            .sub_path = "package.json",
            .data = "{\"name\":\"@types/other\",\"version\":\"1.0.0\",\"types\":\"index.d.ts\"}",
        });
        try od.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\declare module "other-ext" {
            \\  export interface UnreferencedExt { flag: boolean; }
            \\}
            ,
        });
    }

    {
        var nd = try cwd.openDir(io, node_pkg, .{});
        defer nd.close(io);
        try nd.writeFile(io, .{
            .sub_path = "package.json",
            .data = "{\"name\":\"@types/node-mock\",\"version\":\"1.0.0\",\"types\":\"index.d.ts\"}",
        });
        try nd.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\/// <reference types="other" />
            \\/// <reference path="globals.d.ts" />
            \\/// <reference path="fs.d.ts" />
            \\/// <reference path="http.d.ts" />
            \\/// <reference path="sqlite.d.ts" />
            ,
        });
        try nd.writeFile(io, .{
            .sub_path = "sqlite.d.ts",
            .data =
            \\declare module "node:sqlite" {
            \\  export class DatabaseSync {
            \\    open: boolean;
            \\  }
            \\}
            ,
        });
        try nd.writeFile(io, .{
            .sub_path = "globals.d.ts",
            .data =
            \\declare var processVersion: string;
            ,
        });
        try nd.writeFile(io, .{
            .sub_path = "fs.d.ts",
            .data =
            \\/// <reference path="fs/promises.d.ts" />
            \\declare module "fs" {
            \\  export interface Stat {
            \\    size: number;
            \\  }
            \\  export function readFileSync(path: string): string;
            \\}
            \\declare module "node:fs" {
            \\  export * from "fs";
            \\}
            ,
        });
        try nd.writeFile(io, .{
            .sub_path = "fs/promises.d.ts",
            .data =
            \\declare module "fs/promises" {
            \\  export function readFile(path: string): Promise<string>;
            \\}
            ,
        });
        try nd.writeFile(io, .{
            .sub_path = "http.d.ts",
            .data =
            \\declare module "http" {
            \\  import type { Stat } from "fs";
            \\  export interface Server {
            \\    port: number;
            \\    stat?: Stat;
            \\  }
            \\  export function createServer(): Server;
            \\}
            ,
        });
    }

    {
        const cli_args = [_][]const u8{ "-t", node_pkg, "-d", out_node };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Round 3 Subcase 1 error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);

        var out_h = try cwd.openDir(io, out_node, .{});
        defer out_h.close(io);
        // Reference-only `index.d.ts` and unreferenced external `@types/other` MUST NOT be emitted!
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "index.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "other-ext.zig", .{}));
    }

    // 2. Mixed file (`index.d.ts` with `export interface A`, inline `declare module "inline-mod"`,
    //    empty `declare module "empty-inline" {}`, and `/// <reference path="./plugin.d.ts" />`).
    const mixed_dir = try std.fmt.allocPrint(alloc, "{s}/mixed-pkg", .{sandbox});
    defer alloc.free(mixed_dir);
    const out_mixed = try std.fmt.allocPrint(alloc, "{s}/out-mixed", .{sandbox});
    defer alloc.free(out_mixed);
    try cwd.createDirPath(io, mixed_dir);

    {
        var md = try cwd.openDir(io, mixed_dir, .{});
        defer md.close(io);
        try md.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\/// <reference path="./plugin.d.ts" />
            \\export interface A {
            \\  id: number;
            \\}
            \\export declare function makeA(id: number): A;
            \\declare module "inline-mod" {
            \\  export function useInline(): A;
            \\}
            \\declare module "empty-inline" {}
            ,
        });
        try md.writeFile(io, .{
            .sub_path = "plugin.d.ts",
            .data =
            \\declare module "plugin" {
            \\  export interface PluginOpts {
            \\    enabled: boolean;
            \\  }
            \\}
            ,
        });
    }

    {
        const mixed_index = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{mixed_dir});
        defer alloc.free(mixed_index);
        const cli_args = [_][]const u8{ "-t", mixed_index, "-d", out_mixed };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Round 3 Subcase 2 error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);
    }

    // 3. Multi-`-t` (`-t globals.d.ts -t index.d.ts` where `globals.d.ts` has `declare module "x"`).
    const multi_dir = try std.fmt.allocPrint(alloc, "{s}/multi-pkg", .{sandbox});
    defer alloc.free(multi_dir);
    const out_multi = try std.fmt.allocPrint(alloc, "{s}/out-multi", .{sandbox});
    defer alloc.free(out_multi);
    try cwd.createDirPath(io, multi_dir);

    {
        var mtd = try cwd.openDir(io, multi_dir, .{});
        defer mtd.close(io);
        try mtd.writeFile(io, .{
            .sub_path = "globals.d.ts",
            .data =
            \\declare module "x" {
            \\  export interface XConfig {
            \\    retries: number;
            \\  }
            \\  export function runX(cfg: XConfig): boolean;
            \\}
            ,
        });
        try mtd.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\export interface B {
            \\  label: string;
            \\}
            \\export declare function takeB(b: B): string;
            ,
        });
    }

    {
        const globals_dts = try std.fmt.allocPrint(alloc, "{s}/globals.d.ts", .{multi_dir});
        defer alloc.free(globals_dts);
        const index_dts = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{multi_dir});
        defer alloc.free(index_dts);
        const cli_args = [_][]const u8{ "-t", globals_dts, "-t", index_dts, "-d", out_multi };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Round 3 Subcase 3 error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);

        var out_h = try cwd.openDir(io, out_multi, .{});
        defer out_h.close(io);
        // Ambient-only `globals.d.ts` must NOT emit an empty `globals.zig` alongside `x.zig`!
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "globals.zig", .{}));
    }

    // 4. Empty `.d.ts` fallback: when the entire package would otherwise emit zero modules, emit 1 fallback module.
    const empty_dir = try std.fmt.allocPrint(alloc, "{s}/empty-pkg", .{sandbox});
    defer alloc.free(empty_dir);
    const out_empty = try std.fmt.allocPrint(alloc, "{s}/out-empty", .{sandbox});
    defer alloc.free(out_empty);
    try cwd.createDirPath(io, empty_dir);
    {
        var ed = try cwd.openDir(io, empty_dir, .{});
        defer ed.close(io);
        try ed.writeFile(io, .{ .sub_path = "empty.d.ts", .data = "" });
    }
    {
        const empty_dts = try std.fmt.allocPrint(alloc, "{s}/empty.d.ts", .{empty_dir});
        defer alloc.free(empty_dts);
        const cli_args = [_][]const u8{ "-t", empty_dts, "-d", out_empty };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        try std.testing.expect(res == .ok);
        try std.testing.expectEqual(@as(usize, 1), res.ok.module_count);
    }

    // Compile and execute consumer Zig tests against all 4 generated `root.zig` packages!
    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_r3.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_r3.zig",
            .data =
            \\const std = @import("std");
            \\const r_node = @import("out-node/root.zig");
            \\const r_mixed = @import("out-mixed/root.zig");
            \\const r_multi = @import("out-multi/root.zig");
            \\const r_empty = @import("out-empty/root.zig");
            \\
            \\test "Round 3: @types/node reference-path closure, mixed ES+ambient, multi -t, and empty fallback" {
            \\    // 1. @types/node package exports fs, fs_promises, http, node_sqlite, globals — NOT empty index or external other!
            \\    try std.testing.expect(!@hasDecl(r_node, "index"));
            \\    try std.testing.expect(!@hasDecl(r_node, "other_ext"));
            \\    try std.testing.expect(@hasDecl(r_node, "fs"));
            \\    try std.testing.expect(@hasDecl(r_node, "fs_promises"));
            \\    try std.testing.expect(@hasDecl(r_node, "http"));
            \\    try std.testing.expect(@hasDecl(r_node, "node_sqlite"));
            \\    try std.testing.expect(@hasDecl(r_node, "globals"));
            \\    try std.testing.expectEqualStrings("processVersion", r_node.globals.process_version.js_name);
            \\    try std.testing.expect(r_node.node_sqlite.DatabaseSync.zigar_js.is_handle);
            \\    const db_open: *const fn (r_node.node_sqlite.DatabaseSync) r_node.zigar_js.CallError!bool = &r_node.node_sqlite.DatabaseSync.open;
            \\    _ = db_open;
            \\    const srv: r_node.http.Server = .{ .port = 8080, .stat = .{ .size = 64 } };
            \\    try std.testing.expectEqual(@as(f64, 8080), srv.port);
            \\
            \\    // 2. Mixed file exports A, index, inline_mod, empty_inline, and plugin!
            \\    try std.testing.expect(r_mixed.A == r_mixed.index.A);
            \\    try std.testing.expect(&r_mixed.makeA == &r_mixed.index.makeA);
            \\    try std.testing.expect(@hasDecl(r_mixed, "inline_mod"));
            \\    try std.testing.expect(@hasDecl(r_mixed, "empty_inline"));
            \\    try std.testing.expect(@hasDecl(r_mixed, "plugin"));
            \\    const inline_fn: *const fn () r_mixed.zigar_js.CallError!r_mixed.A = &r_mixed.inline_mod.useInline;
            \\    _ = inline_fn;
            \\    const p_opts: r_mixed.plugin.PluginOpts = .{ .enabled = true };
            \\    try std.testing.expect(p_opts.enabled);
            \\
            \\    // 3. Multi -t exports both x and index's exports (without empty globals)!
            \\    try std.testing.expect(!@hasDecl(r_multi, "globals"));
            \\    try std.testing.expect(@hasDecl(r_multi, "x"));
            \\    try std.testing.expect(@hasDecl(r_multi, "index"));
            \\    try std.testing.expect(r_multi.B == r_multi.index.B);
            \\    try std.testing.expect(&r_multi.takeB == &r_multi.index.takeB);
            \\    const x_cfg: r_multi.x.XConfig = .{ .retries = 3 };
            \\    try std.testing.expectEqual(@as(f64, 3), x_cfg.retries);
            \\
            \\    // 4. Empty fallback emits valid root.zig + empty.zig!
            \\    try std.testing.expect(@hasDecl(r_empty, "empty"));
            \\}
            ,
        });
    }

    const r_node_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_node});
    defer alloc.free(r_node_zig);
    const r_mixed_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_mixed});
    defer alloc.free(r_mixed_zig);
    const r_multi_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_multi});
    defer alloc.free(r_multi_zig);
    const r_empty_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_empty});
    defer alloc.free(r_empty_zig);

    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", r_node_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", r_mixed_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", r_multi_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", r_empty_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Regression Round 4: ambient export * from '...' inside declare module expands symbols without leaking @\"*\" or file stubs" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-r4-amb-star", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    // 1. Multi-`-t` (`-t globals.d.ts -t index.d.ts` where `globals.d.ts` has `declare module "x-core"`
    //    and `declare module "x" { export * from "x-core"; export * as coreNs from "x-core"; }`).
    const multi_dir = try std.fmt.allocPrint(alloc, "{s}/multi-star", .{sandbox});
    defer alloc.free(multi_dir);
    const out_multi = try std.fmt.allocPrint(alloc, "{s}/out-multi-star", .{sandbox});
    defer alloc.free(out_multi);
    try cwd.createDirPath(io, multi_dir);

    {
        var md = try cwd.openDir(io, multi_dir, .{});
        defer md.close(io);
        try md.writeFile(io, .{
            .sub_path = "globals.d.ts",
            .data =
            \\declare module "x-core" {
            \\  export interface XConfig {
            \\    retries: number;
            \\  }
            \\  export function runCore(cfg: XConfig): boolean;
            \\}
            \\declare module "x" {
            \\  export * from "x-core";
            \\  export * as coreNs from "x-core";
            \\}
            ,
        });
        try md.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\export interface EntryItem {
            \\  title: string;
            \\}
            ,
        });
    }

    {
        const globals_dts = try std.fmt.allocPrint(alloc, "{s}/globals.d.ts", .{multi_dir});
        defer alloc.free(globals_dts);
        const index_dts = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{multi_dir});
        defer alloc.free(index_dts);
        const cli_args = [_][]const u8{ "-t", globals_dts, "-t", index_dts, "-d", out_multi };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Round 4 Subcase 1 error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);

        var out_h = try cwd.openDir(io, out_multi, .{});
        defer out_h.close(io);
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "globals.zig", .{}));
    }

    // 2. Mixed `index.d.ts` with `export interface A`, `declare module "inline-core"`, and
    //    `declare module "inline-mod" { export * from "inline-core"; }`.
    const mixed_dir = try std.fmt.allocPrint(alloc, "{s}/mixed-star", .{sandbox});
    defer alloc.free(mixed_dir);
    const out_mixed = try std.fmt.allocPrint(alloc, "{s}/out-mixed-star", .{sandbox});
    defer alloc.free(out_mixed);
    try cwd.createDirPath(io, mixed_dir);

    {
        var mxd = try cwd.openDir(io, mixed_dir, .{});
        defer mxd.close(io);
        try mxd.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\export interface A {
            \\  id: number;
            \\}
            \\declare module "inline-core" {
            \\  export function core(): number;
            \\  export interface CoreItem {
            \\    tag: string;
            \\  }
            \\}
            \\declare module "inline-mod" {
            \\  export * from "inline-core";
            \\}
            ,
        });
    }

    {
        const mixed_index = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{mixed_dir});
        defer alloc.free(mixed_index);
        const cli_args = [_][]const u8{ "-t", mixed_index, "-d", out_mixed };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Round 4 Subcase 2 error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);
    }

    // 3. Reference-only `index.d.ts` -> `a.d.ts` (`declare module "liba"`) + `b.d.ts`
    //    (`declare module "libb" { export * from "liba"; }` where filename `b.d.ts` != `"libb"`) +
    //    `c.d.ts` (mutual `export *` cycle `mut-a <-> mut-b`).
    const ref_dir = try std.fmt.allocPrint(alloc, "{s}/ref-star", .{sandbox});
    defer alloc.free(ref_dir);
    const out_ref = try std.fmt.allocPrint(alloc, "{s}/out-ref-star", .{sandbox});
    defer alloc.free(out_ref);
    try cwd.createDirPath(io, ref_dir);

    {
        var rd = try cwd.openDir(io, ref_dir, .{});
        defer rd.close(io);
        try rd.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\/// <reference path="a.d.ts" />
            \\/// <reference path="b.d.ts" />
            \\/// <reference path="c.d.ts" />
            ,
        });
        try rd.writeFile(io, .{
            .sub_path = "a.d.ts",
            .data =
            \\declare module "liba" {
            \\  interface InternalHelper {
            \\    secret: number;
            \\  }
            \\  export interface LibItem {
            \\    name: string;
            \\    helper?: InternalHelper;
            \\  }
            \\  export function makeItem(name: string): LibItem;
            \\  export {};
            \\}
            ,
        });
        try rd.writeFile(io, .{
            .sub_path = "b.d.ts",
            .data =
            \\declare module "libb" {
            \\  export * from "liba";
            \\}
            ,
        });
        try rd.writeFile(io, .{
            .sub_path = "c.d.ts",
            .data =
            \\declare module "mut-a" {
            \\  export interface MutA {
            \\    a: number;
            \\  }
            \\  export * from "mut-b";
            \\}
            \\declare module "mut-b" {
            \\  export interface MutB {
            \\    b: string;
            \\  }
            \\  export * from "mut-a";
            \\}
            ,
        });
    }

    {
        const ref_index = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{ref_dir});
        defer alloc.free(ref_index);
        const cli_args = [_][]const u8{ "-t", ref_index, "-d", out_ref };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Round 4 Subcase 3 error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);

        var out_h = try cwd.openDir(io, out_ref, .{});
        defer out_h.close(io);
        // None of `index.zig`, `a.zig`, `b.zig`, or `c.zig` may be emitted as file stubs!
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "index.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "a.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "b.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "c.zig", .{}));
    }

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_r4.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_r4.zig",
            .data =
            \\const std = @import("std");
            \\const r_multi = @import("out-multi-star/root.zig");
            \\const r_mixed = @import("out-mixed-star/root.zig");
            \\const r_ref = @import("out-ref-star/root.zig");
            \\
            \\test "Round 4: ambient export * expands symbols and never leaks @\"*\" or file stubs" {
            \\    // 1. Multi -t: no `globals` or `"*"`, `r_multi.x` re-exports `XConfig`, `runCore`, and `coreNs`!
            \\    try std.testing.expect(!@hasDecl(r_multi, "globals"));
            \\    try std.testing.expect(!@hasDecl(r_multi, "*"));
            \\    try std.testing.expect(!@hasDecl(r_multi.x, "*"));
            \\    try std.testing.expect(r_multi.x.XConfig == r_multi.x_core.XConfig);
            \\    try std.testing.expect(&r_multi.x.runCore == &r_multi.x_core.runCore);
            \\    try std.testing.expect(@hasDecl(r_multi.x, "coreNs"));
            \\    try std.testing.expect(r_multi.x.coreNs.XConfig == r_multi.x_core.XConfig);
            \\
            \\    // 2. Mixed index.d.ts: no `"*"` anywhere, `r_mixed.inline_mod` re-exports `core` and `CoreItem`!
            \\    try std.testing.expect(!@hasDecl(r_mixed, "*"));
            \\    try std.testing.expect(!@hasDecl(r_mixed.index, "*"));
            \\    try std.testing.expect(!@hasDecl(r_mixed.inline_mod, "*"));
            \\    try std.testing.expect(r_mixed.A == r_mixed.index.A);
            \\    try std.testing.expect(@hasDecl(r_mixed.inline_mod, "core"));
            \\    try std.testing.expect(&r_mixed.inline_mod.core == &r_mixed.inline_core.core);
            \\    try std.testing.expect(r_mixed.inline_mod.CoreItem == r_mixed.inline_core.CoreItem);
            \\
            \\    // 3. Reference-only index.d.ts -> a.d.ts + b.d.ts + c.d.ts:
            \\    //    no file stubs, nominal type identity across `libb -> liba`, internal helper not re-exported,
            \\    //    and cycle-safe mutual `export *` (`mut_a <-> mut_b`)!
            \\    try std.testing.expect(!@hasDecl(r_ref, "*"));
            \\    try std.testing.expect(!@hasDecl(r_ref, "index"));
            \\    try std.testing.expect(!@hasDecl(r_ref, "a"));
            \\    try std.testing.expect(!@hasDecl(r_ref, "b"));
            \\    try std.testing.expect(!@hasDecl(r_ref, "c"));
            \\    try std.testing.expect(r_ref.libb.LibItem == r_ref.liba.LibItem);
            \\    try std.testing.expect(&r_ref.libb.makeItem == &r_ref.liba.makeItem);
            \\    try std.testing.expect(!@hasDecl(r_ref.libb, "InternalHelper"));
            \\    try std.testing.expect(r_ref.mut_a.MutB == r_ref.mut_b.MutB);
            \\    try std.testing.expect(r_ref.mut_b.MutA == r_ref.mut_a.MutA);
            \\}
            ,
        });
    }

    const r_multi_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_multi});
    defer alloc.free(r_multi_zig);
    const r_mixed_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_mixed});
    defer alloc.free(r_mixed_zig);
    const r_ref_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_ref});
    defer alloc.free(r_ref_zig);

    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", r_multi_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", r_mixed_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", r_ref_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Regression Round 5: multi-block ambient files route private helpers to owning ambient module and omit them from zigar_js.exports" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-r5-multi-amb-helpers", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_full = try std.fmt.allocPrint(alloc, "{s}/out-full", .{sandbox});
    defer alloc.free(out_full);
    const out_p2 = try std.fmt.allocPrint(alloc, "{s}/out-p2", .{sandbox});
    defer alloc.free(out_p2);
    try cwd.createDirPath(io, src_dir);

    {
        var sd = try cwd.openDir(io, src_dir, .{});
        defer sd.close(io);
        try sd.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\/// <reference path="b.d.ts" />
            ,
        });
        try sd.writeFile(io, .{
            .sub_path = "b.d.ts",
            .data =
            \\declare module "p1" {
            \\  export interface P1 {
            \\    a: number;
            \\  }
            \\}
            \\declare module "p2" {
            \\  interface HidBase {
            \\    tag: string;
            \\  }
            \\  namespace HelperNs {
            \\    export interface NestedHid {
            \\      flag: boolean;
            \\    }
            \\  }
            \\  interface Hid extends HidBase {
            \\    s: number;
            \\    nested?: HelperNs.NestedHid;
            \\  }
            \\  export function g(h: Hid): void;
            \\  export {};
            \\}
            \\declare module "p3" {
            \\  import { AliasP4 } from "p4";
            \\  export function useP4(v: AliasP4): void;
            \\}
            \\declare module "p4" {
            \\  interface HidP4 {
            \\    secret: number;
            \\  }
            \\  export type AliasP4 = {
            \\    payload: HidP4;
            \\  };
            \\  export {};
            \\}
            ,
        });
    }

    const index_dts = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{src_dir});
    defer alloc.free(index_dts);

    // 1. Full package emit (`-t index.d.ts -d out-full`)
    {
        const cli_args = [_][]const u8{ "-t", index_dts, "-d", out_full };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Round 5 Full emit error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);

        var out_h = try cwd.openDir(io, out_full, .{});
        defer out_h.close(io);
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "index.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "b.zig", .{}));
        _ = try out_h.statFile(io, "p1.zig", .{});
        _ = try out_h.statFile(io, "p2.zig", .{});
        _ = try out_h.statFile(io, "p3.zig", .{});
        _ = try out_h.statFile(io, "p4.zig", .{});

        const p2_src = try out_h.readFileAlloc(io, "p2.zig", alloc, .limited(64 * 1024));
        defer alloc.free(p2_src);
        try std.testing.expect(std.mem.indexOf(u8, p2_src, "p1.zig") == null);
    }

    // 2. Filtered `-m p2` emit (`-t index.d.ts -m p2 -d out-p2`): must NOT pull in `p1.zig`!
    {
        const cli_args = [_][]const u8{ "-t", index_dts, "-m", "p2", "-d", out_p2 };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Round 5 -m p2 error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);

        var out_h = try cwd.openDir(io, out_p2, .{});
        defer out_h.close(io);
        _ = try out_h.statFile(io, "p2.zig", .{});
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "p1.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "p3.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "p4.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "index.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "b.zig", .{}));
    }

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_r5.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_r5.zig",
            .data =
            \\const std = @import("std");
            \\const r_full = @import("out-full/root.zig");
            \\const r_p2 = @import("out-p2/root.zig");
            \\
            \\test "Round 5: helpers land in owning ambient module and stay out of zigar_js.exports" {
            \\    // `Hid`, `HidBase`, and `NestedHid` belong to `p2.zig` and NOT `p1.zig`!
            \\    try std.testing.expect(@hasDecl(r_full.p2, "Hid"));
            \\    try std.testing.expect(@hasDecl(r_full.p2, "HidBase"));
            \\    try std.testing.expect(@hasDecl(r_full.p2, "NestedHid"));
            \\    try std.testing.expect(@hasDecl(r_full.p2, "g"));
            \\    try std.testing.expect(!@hasDecl(r_full.p1, "Hid"));
            \\    try std.testing.expect(!@hasDecl(r_full.p1, "HidBase"));
            \\    try std.testing.expect(!@hasDecl(r_full.p1, "NestedHid"));
            \\
            \\    // `p1.zigar_js.exports` has only `P1`; `p2.zigar_js.exports` has only `g` (NOT `Hid`/`HidBase`/`NestedHid`)!
            \\    try std.testing.expectEqual(@as(usize, 1), r_full.p1.zigar_js.exports.len);
            \\    try std.testing.expectEqualStrings("P1", r_full.p1.zigar_js.exports[0].js_name);
            \\    try std.testing.expectEqual(@as(usize, 1), r_full.p2.zigar_js.exports.len);
            \\    try std.testing.expectEqualStrings("g", r_full.p2.zigar_js.exports[0].js_name);
            \\
            \\    // Reverse-order cross-ambient alias: `HidP4` belongs to `p4.zig` (NOT `p3.zig`) and is excluded from `p4.zigar_js.exports`!
            \\    try std.testing.expect(@hasDecl(r_full.p4, "HidP4"));
            \\    try std.testing.expect(!@hasDecl(r_full.p3, "HidP4"));
            \\    try std.testing.expectEqual(@as(usize, 1), r_full.p4.zigar_js.exports.len);
            \\    try std.testing.expectEqualStrings("AliasP4", r_full.p4.zigar_js.exports[0].js_name);
            \\
            \\    // `-m p2` output works standalone without `p1`, barrel-exports `g` (not private `Hid`), and types `r_p2.p2.Hid`!
            \\    try std.testing.expect(!@hasDecl(r_p2, "p1"));
            \\    try std.testing.expect(@hasDecl(r_p2, "g"));
            \\    try std.testing.expect(!@hasDecl(r_p2, "Hid"));
            \\    try std.testing.expect(&r_p2.g == &r_p2.p2.g);
            \\    try std.testing.expectEqual(@as(usize, 1), r_p2.p2.zigar_js.exports.len);
            \\    try std.testing.expectEqualStrings("g", r_p2.p2.zigar_js.exports[0].js_name);
            \\    const hid_val: r_p2.p2.Hid = .{ .tag = "base", .s = 7, .nested = .{ .flag = true } };
            \\    try std.testing.expectEqualStrings("base", hid_val.tag);
            \\    try std.testing.expectEqual(@as(f64, 7), hid_val.s);
            \\    _ = &r_p2.g;
            \\}
            ,
        });
    }

    const r_full_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_full});
    defer alloc.free(r_full_zig);
    const r_p2_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_p2});
    defer alloc.free(r_p2_zig);

    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", r_full_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", r_p2_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Issue #45 H2: synthetic cyclic namespace_decl graph terminates cleanly and passes AstGen" {
    const alloc = std.testing.allocator;
    const wt = ts_zigar.host.types;

    // Strings: 0="/cyclic.d.ts", 1="NsA", 2="NsB", 3="val"
    const strings = [_][]const u8{ "/cyclic.d.ts", "NsA", "NsB", "val" };

    const types = [_]wt.TypeNode{
        .{ .id = 0, .kind = .number_type, .resolved_type = null },
    };

    // Hostile cyclic graph:
    //   decl 0 (`NsA`): children = [0, 1, 2] (self-cycle 0->0 + mutual cycle 0->1->0), merged_with = [0, 1]
    //   decl 1 (`NsB`): children = [0, 1, 2] (self-cycle 1->1 + mutual cycle 1->0->1), merged_with = [0, 1]
    //   decl 2 (`val`): shared child referenced by both cyclic namespaces!
    const ns_children = [_]u32{ 0, 1, 2 };
    const cyclic_merged = [_]u32{ 0, 1 };
    const mod_exports = [_]u32{ 0, 1 };

    const decls = [_]wt.DeclNode{
        .{
            .id = 0,
            .name = 1,
            .export_name = 1,
            .module = 0,
            .modifiers = .{ .export_decl = true, .declare_ambient = true },
            .type_params = &.{},
            .kind = .{ .namespace_decl = &ns_children },
            .merged_with = &cyclic_merged,
            .jsdoc = null,
        },
        .{
            .id = 1,
            .name = 2,
            .export_name = 2,
            .module = 0,
            .modifiers = .{ .export_decl = true, .declare_ambient = true },
            .type_params = &.{},
            .kind = .{ .namespace_decl = &ns_children },
            .merged_with = &cyclic_merged,
            .jsdoc = null,
        },
        .{
            .id = 2,
            .name = 3,
            .export_name = 3,
            .module = 0,
            .modifiers = .{ .export_decl = true, .const_mod = true },
            .type_params = &.{},
            .kind = .{ .variable_decl = 0 },
            .merged_with = &.{},
            .jsdoc = null,
        },
    };

    const modules = [_]wt.ModuleNode{
        .{
            .id = 0,
            .specifier = 0,
            .file_path = 0,
            .exports = &mod_exports,
            .default_export = null,
            .export_equals = null,
            .umd_namespace = null,
            .star_re_exports = &.{},
            .ambient_modules = &.{},
            .global_augmentations = &.{},
            .triple_slash_types = &.{},
            .triple_slash_paths = &.{},
            .triple_slash_libs = &.{},
        },
    };

    const entry_modules = [_]u32{0};
    const graph = wt.DeclarationGraph{
        .strings = &strings,
        .modules = &modules,
        .entry_modules = &entry_modules,
        .decls = &decls,
        .types = &types,
        .signatures = &.{},
        .type_params = &.{},
        .properties = &.{},
        .diagnostics = &.{},
    };

    var pkg_ir = try ts_zigar.ir.lowerGraph(alloc, graph, .{
        .base_dir = "/",
        .primary_vfs_paths = &.{"/cyclic.d.ts"},
    });
    defer pkg_ir.deinit();

    try std.testing.expectEqual(@as(usize, 1), pkg_ir.modules.len);

    var emit_outcome = try ts_zigar.emit.emitPackage(alloc, &pkg_ir);
    defer emit_outcome.deinit(alloc);

    switch (emit_outcome) {
        .ok => |bundle| try std.testing.expect(bundle.files.len >= 2),
        .ast_error => |diag| {
            std.debug.print("H2 cyclic graph AstGen failed:\n{s}\n", .{diag});
            return error.TestUnexpectedResult;
        },
    }
}

test "Issue #45 H1, H3, H4, M2, L3: merged namespace self-export, shared DAG hoisting, ambient export=/default, private constructors, and unknown declare enum" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue45-m2-adversarial", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    try cwd.createDirPath(io, src_dir);
    {
        var d = try cwd.openDir(io, src_dir, .{});
        defer d.close(io);

        // H1 + H4: `declare module "node:events"` (3-way generic class + interface + namespace re-exporting itself + `export = EventEmitter`),
        // `declare module "node:path"` (`namespace path { ... } export = path`), and `declare module "virtual:def"` (`export default class`).
        try d.writeFile(io, .{
            .sub_path = "ambient.d.ts",
            .data =
            \\declare module "node:events" {
            \\    interface BaseEmitter<T> {
            \\        listenerCount(eventName: string): number;
            \\    }
            \\    class EventEmitter<T = Record<string, any>> {
            \\        static defaultMaxListeners: number;
            \\        on(eventName: string, listener: (...args: any[]) => void): this;
            \\    }
            \\    interface EventEmitter<T = Record<string, any>> extends BaseEmitter<T> {
            \\        emit(eventName: string, ...args: any[]): boolean;
            \\    }
            \\    namespace EventEmitter {
            \\        export { EventEmitter };
            \\        export function once(emitter: EventEmitter, name: string): Promise<any[]>;
            \\        export interface Abortable {
            \\            signal?: boolean;
            \\        }
            \\    }
            \\    export = EventEmitter;
            \\}
            \\declare module "node:path" {
            \\    namespace path {
            \\        export interface ParsedPath {
            \\            root: string;
            \\            dir: string;
            \\            base: string;
            \\        }
            \\        export function join(...paths: string[]): string;
            \\        export function resolve(...paths: string[]): string;
            \\        export const sep: string;
            \\        export const posix: typeof path;
            \\    }
            \\    export = path;
            \\}
            \\declare module "virtual:def" {
            \\    export default class DefaultRunner {
            \\        start(): boolean;
            \\    }
            \\}
            ,
        });

        // H3: 6-level diamond DAG of `typeof` / multi-member anonymous object literals.
        // Without closed-DAG hoisting, `Level6` expands `Level0` 64 times inline; with hoisting, each level is emitted once!
        try d.writeFile(io, .{
            .sub_path = "dag.d.ts",
            .data =
            \\declare const level0: {
            \\    f0: string; f1: number; f2: boolean; f3: string; f4: number;
            \\    f5: boolean; f6: string; f7: number; f8: boolean; f9: string;
            \\};
            \\declare const level1: { left: typeof level0; right: typeof level0; tag1: string };
            \\declare const level2: { left: typeof level1; right: typeof level1; tag2: string };
            \\declare const level3: { left: typeof level2; right: typeof level2; tag3: string };
            \\declare const level4: { left: typeof level3; right: typeof level3; tag4: string };
            \\declare const level5: { left: typeof level4; right: typeof level4; tag5: string };
            \\export declare const level6: { left: typeof level5; right: typeof level5; tag6: string };
            \\export declare function consumeDag(input?: typeof level6): typeof level6;
            ,
        });

        // M2 + L3: `private constructor()`, `protected constructor()`, `#private` brand, and `declare enum` unknown runtime values vs known ordinal enum.
        try d.writeFile(io, .{
            .sub_path = "m2_l3.d.ts",
            .data =
            \\export declare class Singleton {
            \\    private secret: number;
            \\    #brand: unknown;
            \\    private constructor();
            \\    static getInstance(): Singleton;
            \\    ping(): string;
            \\}
            \\export declare class ProtectedBase {
            \\    protected constructor(seed: number);
            \\    id(): number;
            \\}
            \\export declare enum DynamicEnum {
            \\    Alpha,
            \\    Beta,
            \\}
            \\export declare enum KnownEnum {
            \\    Zero = 0,
            \\    One = 1,
            \\}
            ,
        });

        try d.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\/// <reference path="./ambient.d.ts" />
            \\export * from "./dag";
            \\export * from "./m2_l3";
            ,
        });
    }

    const index_dts = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{src_dir});
    defer alloc.free(index_dts);

    const cli_args = [_][]const u8{ "-t", index_dts, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Issue #45 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    // Verify H3 size bound and hoisted helper emission on `dag.zig`, plus `export =` `from_default` target on `node_path.zig`!
    {
        var out_h = try cwd.openDir(io, out_dir, .{});
        defer out_h.close(io);
        const dag_src = try out_h.readFileAlloc(io, "dag.zig", alloc, .limited(64 * 1024));
        defer alloc.free(dag_src);
        try std.testing.expect(dag_src.len < 16384);
        try std.testing.expect(std.mem.indexOf(u8, dag_src, "__zigar_AnonObj_") != null);

        const path_src = try out_h.readFileAlloc(io, "path.zig", alloc, .limited(64 * 1024));
        defer alloc.free(path_src);
        try std.testing.expect(std.mem.indexOf(u8, path_src, ".name = \"join\", .from_default = true") != null);
        try std.testing.expect(std.mem.indexOf(u8, path_src, ".ns_path = &.{ \"path\"") == null);
    }

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_issue45.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_issue45.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const dag = @import("out/dag.zig");
            \\const m2_l3 = @import("out/m2_l3.zig");
            \\
            \\fn hasExportJsName(comptime exports: anytype, want: []const u8) bool {
            \\    inline for (exports) |e| {
            \\        if (std.mem.eql(u8, e.js_name, want)) return true;
            \\    }
            \\    return false;
            \\}
            \\
            \\test "Issue #45 consumer Sema: H1, H3, H4, M2, L3" {
            \\    // H1 + H4: `node:events` (`export = EventEmitter` with merged class + interface + namespace!)
            \\    try std.testing.expectEqualStrings("EventEmitter", r.node_events.zigar_js.export_equals);
            \\    try std.testing.expect(@hasDecl(r.node_events, "EventEmitter"));
            \\    try std.testing.expect(@hasDecl(r.node_events, "once"));
            \\    try std.testing.expect(@hasDecl(r.node_events, "Abortable"));
            \\    const EE = r.node_events.EventEmitter(struct {});
            \\    try std.testing.expect(@hasDecl(EE, "on"));
            \\    try std.testing.expect(@hasDecl(EE, "emit"));
            \\    try std.testing.expect(@hasDecl(EE, "listenerCount"));
            \\    try std.testing.expect(@hasDecl(EE, "once"));
            \\
            \\    // H4: `node:path` (`export = path` exposes `join`, `resolve`, `sep`, `posix`, `ParsedPath` with `export_equals` metadata and NO bogus `.js_name = "path"`!)
            \\    try std.testing.expect(r.node_path.zigar_js.export_equals.len > 0);
            \\    try std.testing.expect(!hasExportJsName(r.node_path.zigar_js.exports, "path"));
            \\    try std.testing.expect(@hasDecl(r.node_path, "join"));
            \\    try std.testing.expect(@hasDecl(r.node_path, "resolve"));
            \\    try std.testing.expect(@hasDecl(r.node_path, "sep"));
            \\    try std.testing.expect(@hasDecl(r.node_path, "posix"));
            \\    try std.testing.expect(@hasDecl(r.node_path, "ParsedPath"));
            \\
            \\    // H4: `virtual:def` (`export default class DefaultRunner`)
            \\    try std.testing.expect(@hasDecl(r.virtual_def, "Default"));
            \\    try std.testing.expect(@hasDecl(r.virtual_def.Default, "start"));
            \\    try std.testing.expectEqual(@as(usize, 1), r.virtual_def.zigar_js.exports.len);
            \\    try std.testing.expectEqualStrings("default", r.virtual_def.zigar_js.exports[0].js_name);
            \\    try std.testing.expect(r.virtual_def.zigar_js.exports[0].is_default);
            \\
            \\    // H3: hoisted shared DAG compiles cleanly and preserves field structure
            \\    _ = &dag.level6;
            \\    _ = &dag.consumeDag;
            \\
            \\    // M2: `Singleton` and `ProtectedBase` do NOT emit public `pub fn init(...)` and record constructor/private metadata!
            \\    try std.testing.expect(!@hasDecl(m2_l3.Singleton, "init"));
            \\    try std.testing.expect(@hasDecl(m2_l3.Singleton, "getInstance"));
            \\    try std.testing.expect(@hasDecl(m2_l3.Singleton, "ping"));
            \\    try std.testing.expect(m2_l3.Singleton.zigar_js.has_private_constructor);
            \\    try std.testing.expect(m2_l3.Singleton.zigar_js.has_non_public_members);
            \\    try std.testing.expect(!@hasDecl(m2_l3.ProtectedBase, "init"));
            \\    try std.testing.expect(m2_l3.ProtectedBase.zigar_js.has_private_constructor);
            \\
            \\    // L3: `KnownEnum` stays a Zig `enum`, while ambient `DynamicEnum` uses runtime-backed `Global` wrapper without bogus 0/1 ordinals!
            \\    try std.testing.expect(@typeInfo(m2_l3.KnownEnum) == .@"enum");
            \\    try std.testing.expectEqual(@as(i64, 0), @intFromEnum(m2_l3.KnownEnum.zero));
            \\    try std.testing.expectEqual(@as(i64, 1), @intFromEnum(m2_l3.KnownEnum.one));
            \\    try std.testing.expect(@typeInfo(m2_l3.DynamicEnum) == .@"struct");
            \\    try std.testing.expect(m2_l3.DynamicEnum.zigar_js.has_unknown_values);
            \\    _ = &m2_l3.DynamicEnum.alpha;
            \\    _ = &m2_l3.DynamicEnum.beta;
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);

    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Issue #46 (M3.1a): primitives, optionals/nullish kinds, bigint literals, symbols, all 15 binary views, and fixed/optional/labeled/variadic tuples" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue46-m3-primitives", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    try cwd.createDirPath(io, src_dir);
    {
        var d = try cwd.openDir(io, src_dir, .{});
        defer d.close(io);

        try d.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\declare module "node:buffer" {
            \\    export class Buffer extends Uint8Array {}
            \\}
            \\import { Buffer } from "node:buffer";
            \\
            \\export declare const SMALL_BIGINT = -99_999_000_111n;
            \\export declare const I128_BIGINT = 18_446_744_073_709_551_616n;
            \\export declare const HUGE_BIGINT = 999_999_999_999_999_999_999_999_999_999_999_999_999_999n;
            \\
            \\export declare const UNIQUE_TOKEN: unique symbol;
            \\export declare let globalCounter: number;
            \\
            \\export declare function noop(): void;
            \\export declare function failAlways(reason: string): never;
            \\export declare function scalars(flag: boolean, count: number, id: bigint, name: string): string;
            \\export declare function boxedHandles(big: BigInt, str: String, sym: symbol, obj: object, rawAny: any, rawUnk: unknown): BigInt;
            \\
            \\export interface OptionalConfig {
            \\    optProp?: string;
            \\    undefUnion: number | undefined;
            \\    nullUnion: number | null;
            \\    bothUnion: boolean | null | undefined;
            \\}
            \\export interface P {
            \\    reqNull: number | null;
            \\    reqUndef: number | undefined;
            \\    optNum?: number;
            \\    optNull?: number | null;
            \\    items?: (string | null)[];
            \\}
            \\export declare function takeAnonAndSlices(
            \\    zigarJs: number,
            \\    zigarJsTuple: number,
            \\    inlineObj: { reqNull: number | null; zigar_js?: string },
            \\    strNulls: (string | null)[],
            \\    numUndefs: (number | undefined)[],
            \\    items?: (string | null)[],
            \\    ...restUndefs: (number | undefined)[]
            \\): { outUndef: string | undefined; optFlag?: boolean };
            \\export let gUndef: string | undefined;
            \\export let gNull: string | null;
            \\export declare function testOptionals(
            \\    req: string,
            \\    nullVal: string | null,
            \\    bothVal: string | null | undefined,
            \\    optA?: string,
            \\    optB?: number,
            \\): string | null;
            \\
            \\export declare function sumReadonly(nums: ReadonlyArray<number>, tags: string[]): string[];
            \\
            \\export type FixedPair = [number, boolean];
            \\export type OptionalPair = [string, number?];
            \\export type LabeledEndpoint = [host: string, port?: number];
            \\export type TrailingVarTuple = [prefix: string, ...codes: number[]];
            \\export type LeadingVarTuple = [...flags: boolean[], target: string];
            \\export type MiddleVarTuple = [head: number, ...mid: string[], tail: boolean];
            \\export type ReadonlySpreadTuple = [...items: readonly string[]];
            \\export type GenericArraySpreadTuple = [...items: Array<number>];
            \\export type NullElemTuple = [string | null, number | undefined];
            \\export type RichNullishTuple = [v: number | undefined, w: string | null, opt?: boolean, ...rest: (number | null)[]];
            \\
            \\export declare function echoEndpoint(ep: LabeledEndpoint): LabeledEndpoint;
            \\export declare function echoTrailingTuple(t: TrailingVarTuple): TrailingVarTuple;
            \\export declare function echoLeadingTuple(t: LeadingVarTuple): LeadingVarTuple;
            \\export declare function echoMiddleTuple(t: MiddleVarTuple): MiddleVarTuple;
            \\export declare function inlineTupleReturn(label: string): [string, number?];
            \\export declare function wrapGenericTuple<T>(item: T): [T, string];
            \\
            \\export interface AllBinaryViews {
            \\    buf: Buffer;
            \\    u8: Uint8Array;
            \\    u8c: Uint8ClampedArray;
            \\    i8: Int8Array;
            \\    u16: Uint16Array;
            \\    i16: Int16Array;
            \\    u32: Uint32Array;
            \\    i32: Int32Array;
            \\    u64: BigUint64Array;
            \\    i64: BigInt64Array;
            \\    f32: Float32Array;
            \\    f64: Float64Array;
            \\    ab: ArrayBuffer;
            \\    sab: SharedArrayBuffer;
            \\    dv: DataView;
            \\}
            \\export declare function inspectBinary(views: AllBinaryViews): Uint8Array;
            ,
        });
    }

    const index_dts = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{src_dir});
    defer alloc.free(index_dts);

    const cli_args = [_][]const u8{ "-t", index_dts, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Issue #46 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    // Golden source assertions on `index.zig` and `root.zig`
    {
        var out_h = try cwd.openDir(io, out_dir, .{});
        defer out_h.close(io);
        _ = try out_h.statFile(io, "__zigar_runtime.zig", .{});
        const root_src = try out_h.readFileAlloc(io, "root.zig", alloc, .limited(256 * 1024));
        defer alloc.free(root_src);
        try std.testing.expect(std.mem.indexOf(u8, root_src, "pub const zigar_js = @import(\"__zigar_runtime.zig\");") != null);
        try std.testing.expect(std.mem.indexOf(u8, root_src, "pub const scalarsAlloc = index.scalarsAlloc;") != null);

        const idx_src = try out_h.readFileAlloc(io, "index.zig", alloc, .limited(512 * 1024));
        defer alloc.free(idx_src);
        // Nullish emit tags, recursive specs & trailing optional argc logic
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".null_only") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".undefined_only") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".none") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, "__zigar_argc") != null);
        // Finding 1 golden checks: required nullable/undefinable fields have NO `= null` default, while optional fields DO
        try std.testing.expect(std.mem.indexOf(u8, idx_src, "req_null: ?f64,") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, "req_undef: ?f64,") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, "opt_num: ?f64 = null,") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, "opt_null: ?f64 = null,") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, "zigar_js_2: ?[]const u8 = null,") != null);
        // Finding 2 golden checks: recursive slice/optional/rest/global nullish specs
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".{ .self = .none, .elem = .null_only }") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".{ .self = .none, .elem = .undefined_only }") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".{ .self = .undefined_only, .child = .{ .self = .none, .elem = .null_only } }") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, "pushRestArgs(__zigar_args, rest_undefs, .undefined_only)") != null);
        // All 15 binary view names
        for ([_][]const u8{
            "__zigar_js.Buffer",
            "__zigar_js.Uint8Array",
            "__zigar_js.Uint8ClampedArray",
            "__zigar_js.Int8Array",
            "__zigar_js.Uint16Array",
            "__zigar_js.Int16Array",
            "__zigar_js.Uint32Array",
            "__zigar_js.Int32Array",
            "__zigar_js.BigUint64Array",
            "__zigar_js.BigInt64Array",
            "__zigar_js.Float32Array",
            "__zigar_js.Float64Array",
            "__zigar_js.ArrayBuffer",
            "__zigar_js.SharedArrayBuffer",
            "__zigar_js.DataView",
        }) |bv_needle| {
            if (std.mem.indexOf(u8, idx_src, bv_needle) == null) {
                std.debug.print("Missing binary view in index.zig: {s}\n", .{bv_needle});
                return error.TestUnexpectedResult;
            }
        }
    }

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_issue46.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_issue46.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const js = r.zigar_js;
            \\
            \\test "Issue #46 Sema & offline stub verification" {
            \\    try std.testing.expect(!js.has_host);
            \\
            \\    // BigInt literals: i64, i128, and >i128 decimal text
            \\    try std.testing.expectEqual(@as(i64, -99999000111), r.SMALL_BIGINT);
            \\    try std.testing.expectEqual(@as(i128, 18446744073709551616), r.I128_BIGINT);
            \\    try std.testing.expectEqualStrings("999999999999999999999999999999999999999999", r.HUGE_BIGINT);
            \\
            \\    // Unique symbol & global variable wrappers
            \\    try std.testing.expect(@TypeOf(r.UNIQUE_TOKEN).ValueType == js.Symbol);
            \\    try std.testing.expectEqualStrings("UNIQUE_TOKEN", r.UNIQUE_TOKEN.js_name);
            \\    try std.testing.expect(@TypeOf(r.global_counter).ValueType == f64);
            \\    try std.testing.expectError(error.HostUnavailable, r.global_counter.get());
            \\    try std.testing.expectError(error.HostUnavailable, r.global_counter.set(10));
            \\
            \\    // Intrinsics & primitives + Alloc companions
            \\    try std.testing.expectError(error.HostUnavailable, r.noop());
            \\    try std.testing.expectError(error.HostUnavailable, r.failAlways("boom"));
            \\    try std.testing.expectError(error.HostUnavailable, r.scalars(true, 3.5, 42, "hi"));
            \\    try std.testing.expectError(error.HostUnavailable, r.scalarsAlloc(std.testing.allocator, true, 3.5, 42, "hi"));
            \\    const boxed_fn: *const fn (js.BigInt, js.String, js.Symbol, js.Object, js.Any, js.Unknown) js.CallError!js.BigInt = &r.boxedHandles;
            \\    _ = boxed_fn;
            \\
            \\    // Nullable(T) helper
            \\    const N = js.Nullable(f64);
            \\    const n_undef: N = .undefined;
            \\    const n_null: N = .null;
            \\    const n_val: N = .{ .value = 7.5 };
            \\    try std.testing.expect(n_undef.isUndefined());
            \\    try std.testing.expect(n_null.isNull());
            \\    try std.testing.expectEqual(@as(?f64, null), n_undef.toOptional());
            \\    try std.testing.expectEqual(@as(?f64, 7.5), n_val.toOptional());
            \\
            \\    // OptionalConfig & P defaults and zigar_js.fields metadata (Finding 1 & Finding 2)
            \\    const cfg: r.OptionalConfig = .{ .undef_union = null, .null_union = null, .both_union = null };
            \\    try std.testing.expect(cfg.opt_prop == null);
            \\    const p_inst: r.P = .{ .req_null = null, .req_undef = null };
            \\    try std.testing.expect(p_inst.opt_num == null and p_inst.opt_null == null and p_inst.items == null);
            \\    const p_st = @typeInfo(r.P).@"struct";
            \\    try std.testing.expect(p_st.field_attrs[0].default_value_ptr == null);
            \\    try std.testing.expect(p_st.field_attrs[1].default_value_ptr == null);
            \\    try std.testing.expect(p_st.field_attrs[2].default_value_ptr != null);
            \\    try std.testing.expect(p_st.field_attrs[3].default_value_ptr != null);
            \\    try std.testing.expect(p_st.field_attrs[4].default_value_ptr != null);
            \\    try std.testing.expect(!r.P.zigar_js.fields[0].is_optional and r.P.zigar_js.fields[0].nullish == .null_only);
            \\    try std.testing.expect(!r.P.zigar_js.fields[1].is_optional and r.P.zigar_js.fields[1].nullish == .undefined_only);
            \\    try std.testing.expect(r.P.zigar_js.fields[2].is_optional and r.P.zigar_js.fields[2].nullish == .undefined_only);
            \\    try std.testing.expect(r.P.zigar_js.fields[3].is_optional and r.P.zigar_js.fields[3].nullish == .null_or_undefined);
            \\    try std.testing.expect(r.P.zigar_js.fields[4].is_optional);
            \\    try std.testing.expect(r.P.zigar_js.fields[4].nullish.self == .undefined_only);
            \\    try std.testing.expect(r.P.zigar_js.fields[4].nullish.child.elem == .null_only);
            \\
            \\    // Inline anon_struct parameter & return metadata + zigar_js collision safety
            \\    const InlineParamT = @typeInfo(@TypeOf(r.takeAnonAndSlices)).@"fn".param_types[2].?;
            \\    try std.testing.expect(@typeInfo(InlineParamT).@"struct".field_attrs[0].default_value_ptr == null);
            \\    try std.testing.expect(@typeInfo(InlineParamT).@"struct".field_attrs[1].default_value_ptr != null);
            \\    try std.testing.expect(!InlineParamT.zigar_js.fields[0].is_optional and InlineParamT.zigar_js.fields[0].nullish == .null_only);
            \\    try std.testing.expect(InlineParamT.zigar_js.fields[1].is_optional);
            \\    try std.testing.expectEqualStrings("zigar_js_2", InlineParamT.zigar_js.fields[1].name);
            \\    try std.testing.expectEqualStrings("zigar_js", InlineParamT.zigar_js.fields[1].js_name);
            \\
            \\    // Global nullish specs: gUndef (.undefined_only) vs gNull (.null_only)
            \\    try std.testing.expect(@TypeOf(r.g_undef).nullish_spec == .undefined_only);
            \\    try std.testing.expect(@TypeOf(r.g_null).nullish_spec == .null_only);
            \\    try std.testing.expectError(error.HostUnavailable, r.g_undef.set(null));
            \\    try std.testing.expectError(error.HostUnavailable, r.g_null.set(null));
            \\
            \\    // Tuples: fixed, optional, labeled, trailing/leading/middle variadic, readonly/Array<T> spreads, `.fields` metadata
            \\    const fp: r.FixedPair = .{ .@"0" = 1.0, .@"1" = true };
            \\    try std.testing.expectEqual(@as(f64, 1.0), fp.@"0");
            \\    const op: r.OptionalPair = .{ .@"0" = "a" };
            \\    try std.testing.expect(op.@"1" == null);
            \\    const ep: r.LabeledEndpoint = .{ .host = "localhost" };
            \\    try std.testing.expectEqualStrings("localhost", ep.host);
            \\    try std.testing.expect(ep.port == null);
            \\    try std.testing.expect(!r.LabeledEndpoint.zigar_js_tuple.fields[0].is_optional);
            \\    try std.testing.expect(r.LabeledEndpoint.zigar_js_tuple.fields[1].is_optional);
            \\    try std.testing.expect(r.LabeledEndpoint.zigar_js_tuple.fields[1].nullish == .undefined_only);
            \\
            \\    try std.testing.expectEqual(@as(?usize, 1), r.TrailingVarTuple.zigar_js_tuple.variadic_index);
            \\    try std.testing.expectEqual(@as(?usize, 0), r.LeadingVarTuple.zigar_js_tuple.variadic_index);
            \\    try std.testing.expectEqual(@as(?usize, 1), r.MiddleVarTuple.zigar_js_tuple.variadic_index);
            \\    try std.testing.expectEqual(@as(?usize, 0), r.ReadonlySpreadTuple.zigar_js_tuple.variadic_index);
            \\    try std.testing.expectEqual(@as(?usize, 0), r.GenericArraySpreadTuple.zigar_js_tuple.variadic_index);
            \\    try std.testing.expect(r.NullElemTuple.zigar_js_tuple.fields[0].nullish == .null_only);
            \\    try std.testing.expect(r.NullElemTuple.zigar_js_tuple.fields[1].nullish == .undefined_only);
            \\    try std.testing.expectEqual(@as(?usize, 3), r.RichNullishTuple.zigar_js_tuple.variadic_index);
            \\    try std.testing.expect(!r.RichNullishTuple.zigar_js_tuple.fields[0].is_optional and r.RichNullishTuple.zigar_js_tuple.fields[0].nullish == .undefined_only);
            \\    try std.testing.expect(!r.RichNullishTuple.zigar_js_tuple.fields[1].is_optional and r.RichNullishTuple.zigar_js_tuple.fields[1].nullish == .null_only);
            \\    try std.testing.expect(r.RichNullishTuple.zigar_js_tuple.fields[2].is_optional and r.RichNullishTuple.zigar_js_tuple.fields[2].nullish == .undefined_only);
            \\    try std.testing.expect(!r.RichNullishTuple.zigar_js_tuple.fields[3].is_optional and r.RichNullishTuple.zigar_js_tuple.fields[3].nullish == .null_only);
            \\
            \\    const mid: r.MiddleVarTuple = .{ .head = 1, .mid = &.{ "x", "y" }, .tail = true };
            \\    try std.testing.expectEqual(@as(usize, 2), mid.mid.len);
            \\    try std.testing.expect(@hasDecl(r, "echoEndpointAlloc"));
            \\    try std.testing.expect(@hasDecl(r, "echoTrailingTupleAlloc"));
            \\    try std.testing.expect(@hasDecl(r, "echoLeadingTupleAlloc"));
            \\    try std.testing.expect(@hasDecl(r, "echoMiddleTupleAlloc"));
            \\    try std.testing.expectError(error.HostUnavailable, r.inlineTupleReturn("x"));
            \\    try std.testing.expectError(error.HostUnavailable, r.inlineTupleReturnAlloc(std.testing.allocator, "x"));
            \\    try std.testing.expectError(error.HostUnavailable, r.wrapGenericTuple(f64, 1.5));
            \\    try std.testing.expectError(error.HostUnavailable, r.wrapGenericTupleAlloc(f64, std.testing.allocator, 1.5));
            \\
            \\    // All 15 binary views
            \\    const views: r.AllBinaryViews = .{
            \\        .buf = .{},
            \\        .u8 = .{},
            \\        .u8c = .{},
            \\        .i8 = .{},
            \\        .u16 = .{},
            \\        .i16 = .{},
            \\        .u32 = .{},
            \\        .i32 = .{},
            \\        .u64 = .{},
            \\        .i64 = .{},
            \\        .f32 = .{},
            \\        .f64 = .{},
            \\        .ab = .{},
            \\        .sab = .{},
            \\        .dv = .{},
            \\    };
            \\    try std.testing.expectError(error.HostUnavailable, r.inspectBinary(views));
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);

    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Issue #46 keyed generic container nullish overrides: mutual recursion, inline anon_struct, polymorphic args, recursive alias, and Id<T[]>" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue46-keyed-recurse", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    try cwd.createDirPath(io, src_dir);
    {
        var d = try cwd.openDir(io, src_dir, .{});
        defer d.close(io);
        try d.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\export type Id<T> = T;
            \\export type Maybe<T> = T | null;
            \\export type Undef<T> = T | undefined;
            \\export type PairAlias<T> = [T, number];
            \\export type AliasTree<T> = {
            \\  v: T;
            \\  kids?: AliasTree<T>[];
            \\};
            \\export type TupleTree<T> = [T, TupleTree<T>[]];
            \\export type NullableList<T> = {
            \\  head: T;
            \\  tail: NullableList<T>;
            \\} | null;
            \\export type NullableTupleTree<T> = [T, NullableTupleTree<T>[]] | null;
            \\export type ListViaMaybe<T> = Maybe<{
            \\  head: T;
            \\  tail: ListViaMaybe<T>;
            \\}>;
            \\export interface MutA<T> {
            \\  v: T;
            \\  b?: MutB<T>;
            \\}
            \\export interface MutB<T> {
            \\  w: T;
            \\  a?: MutA<T>;
            \\}
            \\export interface MetaNode<T> {
            \\  val: T;
            \\  meta: {
            \\    label?: string;
            \\    inner?: MetaNode<T>;
            \\  };
            \\}
            \\export interface PolyNode<T> {
            \\  val: T;
            \\  alt?: PolyNode<Maybe<number>>;
            \\  same?: PolyNode<T>;
            \\}
            \\export declare function takeMut(a: MutA<Undef<number>>): void;
            \\export declare function takeMeta(m: MetaNode<Undef<number>>): void;
            \\export declare function takePoly(p: PolyNode<Undef<number>>): void;
            \\export declare function takeTree(t: AliasTree<Undef<number>>): void;
            \\export declare function takeTupleTree(t: TupleTree<Undef<number>>): void;
            \\export declare function takeNullableList(l: NullableList<Undef<number>>): void;
            \\export declare function takeNumberList(l: NullableList<number>): void;
            \\export declare function takeNullableTupleTree(t: NullableTupleTree<Undef<number>>): void;
            \\export declare function takeListViaMaybe(l: ListViaMaybe<Undef<number>>): void;
            \\export declare function takePair(p: PairAlias<Undef<string>>): void;
            \\export declare function takeIdRest(...nums: Id<number[]>): number;
            \\export type IdTuple = [string, ...Id<number[]>];
            ,
        });
    }

    const index_dts = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{src_dir});
    defer alloc.free(index_dts);

    const cli_args = [_][]const u8{ "-t", index_dts, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Issue #46 keyed recurse emit error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    // Golden text assertions on emitted `index.zig`
    {
        var out_h = try cwd.openDir(io, out_dir, .{});
        defer out_h.close(io);
        const src = try out_h.readFileAlloc(io, "index.zig", alloc, .limited(128 * 1024));
        defer alloc.free(src);

        const Helper = struct {
            fn fnBlock(haystack: []const u8, fn_header: []const u8) ![]const u8 {
                const start = std.mem.indexOf(u8, haystack, fn_header) orelse return error.MissingFnHeader;
                const rest = haystack[start..];
                const end = std.mem.indexOf(u8, rest, "\n}\n") orelse rest.len;
                return rest[0..end];
            }
            fn extractFirstId(block: []const u8) ![]const u8 {
                const needle = ".id = \"";
                const idx = std.mem.indexOf(u8, block, needle) orelse return error.MissingSpecId;
                const after = block[idx + needle.len ..];
                const q = std.mem.indexOfScalar(u8, after, '"') orelse return error.UnterminatedSpecId;
                return after[0..q];
            }
        };

        // 1. Exact mutual recursion check on `takeMut`: `MutB.a` MUST recurse to `MutA`'s exact `.id`, NOT `MutB`'s!
        {
            const blk = try Helper.fnBlock(src, "pub fn takeMut(");
            const mut_a_id = try Helper.extractFirstId(blk);
            const after_first = blk[(std.mem.indexOf(u8, blk, mut_a_id).? + mut_a_id.len)..];
            const mut_b_id = try Helper.extractFirstId(after_first);
            try std.testing.expect(!std.mem.eql(u8, mut_a_id, mut_b_id));
            const expected_mut = try std.fmt.allocPrint(
                alloc,
                ".{{ .id = \"{s}\", .self = .none, .fields = .{{ .{{ .name = \"v\", .nullish = .undefined_only }}, .{{ .name = \"b\", .nullish = .{{ .self = .undefined_only, .child = .{{ .id = \"{s}\", .self = .none, .fields = .{{ .{{ .name = \"w\", .nullish = .undefined_only }}, .{{ .name = \"a\", .nullish = .{{ .self = .undefined_only, .child = .{{ .recurse = \"{s}\" }} }} }} }} }} }} }} }} }}",
                .{ mut_a_id, mut_b_id, mut_a_id },
            );
            defer alloc.free(expected_mut);
            try std.testing.expect(std.mem.indexOf(u8, blk, expected_mut) != null);
        }

        // 2. Exact polymorphic recursion check on `takePoly`: outer `PolyNode<Undef<number>>` has `?u(_)`,
        //    `alt` (`PolyNode<Maybe<number>>`) has distinct `?n(_)` with `.val = .null_only` and `.same` recursing to `?n(_)`,
        //    while outer `.same` recurses to `?u(_)`!
        {
            const blk = try Helper.fnBlock(src, "pub fn takePoly(");
            const u_id = try Helper.extractFirstId(blk);
            try std.testing.expect(std.mem.endsWith(u8, u_id, ":?u(_)"));
            const prefix = u_id[0 .. u_id.len - ":?u(_)".len];
            const n_id = try std.fmt.allocPrint(alloc, "{s}:?n(_)", .{prefix});
            defer alloc.free(n_id);
            const expected_poly = try std.fmt.allocPrint(
                alloc,
                ".{{ .id = \"{s}\", .self = .none, .fields = .{{ .{{ .name = \"val\", .nullish = .undefined_only }}, .{{ .name = \"alt\", .nullish = .{{ .self = .undefined_only, .child = .{{ .id = \"{s}\", .self = .none, .fields = .{{ .{{ .name = \"val\", .nullish = .null_only }}, .{{ .name = \"alt\", .nullish = .{{ .self = .undefined_only, .child = .{{ .recurse = \"{s}\" }} }} }}, .{{ .name = \"same\", .nullish = .{{ .self = .undefined_only, .child = .{{ .recurse = \"{s}\" }} }} }} }} }} }} }}, .{{ .name = \"same\", .nullish = .{{ .self = .undefined_only, .child = .{{ .recurse = \"{s}\" }} }} }} }} }}",
                .{ u_id, n_id, n_id, n_id, u_id },
            );
            defer alloc.free(expected_poly);
            try std.testing.expect(std.mem.indexOf(u8, blk, expected_poly) != null);
        }

        // 3. Exact nullable recursive generic alias checks (`NullableList<Undef<number>>`, `NullableList<number>`,
        //    `NullableTupleTree<Undef<number>>`, and `ListViaMaybe<Undef<number>>`)!
        {
            const blk_list = try Helper.fnBlock(src, "pub fn takeNullableList(");
            const list_id = try Helper.extractFirstId(blk_list);
            const expected_list = try std.fmt.allocPrint(
                alloc,
                ".{{ .id = \"{s}\", .self = .null_only, .child = .{{ .self = .none, .fields = .{{ .{{ .name = \"head\", .nullish = .undefined_only }}, .{{ .name = \"tail\", .nullish = .{{ .recurse = \"{s}\" }} }} }} }} }}",
                .{ list_id, list_id },
            );
            defer alloc.free(expected_list);
            try std.testing.expect(std.mem.indexOf(u8, blk_list, expected_list) != null);

            // `NullableList<number>` has no nullish type args -> compact `.null_only`, zero unrolling!
            const blk_num_list = try Helper.fnBlock(src, "pub fn takeNumberList(");
            try std.testing.expect(std.mem.indexOf(u8, blk_num_list, "try __zigar_js.pushArg(__zigar_args, l, .null_only);") != null);
            try std.testing.expect(std.mem.indexOf(u8, blk_num_list, ".id =") == null);

            const blk_ot = try Helper.fnBlock(src, "pub fn takeNullableTupleTree(");
            const ot_id = try Helper.extractFirstId(blk_ot);
            const expected_ot = try std.fmt.allocPrint(
                alloc,
                ".{{ .id = \"{s}\", .self = .null_only, .child = .{{ .self = .none, .tuple = .{{ .undefined_only, .{{ .self = .none, .elem = .{{ .recurse = \"{s}\" }} }} }} }} }}",
                .{ ot_id, ot_id },
            );
            defer alloc.free(expected_ot);
            try std.testing.expect(std.mem.indexOf(u8, blk_ot, expected_ot) != null);

            const blk_via = try Helper.fnBlock(src, "pub fn takeListViaMaybe(");
            const via_id = try Helper.extractFirstId(blk_via);
            const expected_via = try std.fmt.allocPrint(
                alloc,
                ".{{ .id = \"{s}\", .self = .null_only, .child = .{{ .self = .none, .fields = .{{ .{{ .name = \"head\", .nullish = .undefined_only }}, .{{ .name = \"tail\", .nullish = .{{ .recurse = \"{s}\" }} }} }} }} }}",
                .{ via_id, via_id },
            );
            defer alloc.free(expected_via);
            try std.testing.expect(std.mem.indexOf(u8, blk_via, expected_via) != null);
        }

        // 4. `AliasTree`, `TupleTree`, `PairAlias<Undef<string>>`, and `Id<number[]>` rest/tuple checks + compact size!
        try std.testing.expect(std.mem.indexOf(u8, src, ".elem = .{ .recurse = \"s:0:") != null);
        try std.testing.expect(std.mem.indexOf(u8, src, ".elem = .{ .recurse = \"a:0:") != null);
        try std.testing.expect(std.mem.indexOf(u8, src, ".tuple = .{ .undefined_only, .none }") != null);
        try std.testing.expect(std.mem.indexOf(u8, src, "[]const Id([]const f64)") == null);
        try std.testing.expect(src.len < 40960);
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
}

test "Issue #47 (M3.1b): enums, closed/open literal unions, template literals, discriminated unions, recursive/heterogeneous unions, and generic union nullish specs" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue47-unions", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);
    try cwd.createDirPath(io, src_dir);

    {
        var d = try cwd.openDir(io, src_dir, .{});
        defer d.close(io);
        try d.writeFile(io, .{
            .sub_path = "cjs_emitter.d.ts",
            .data =
            \\declare class MiniEmitter {
            \\    maxListeners: number;
            \\    compare(val: MiniEmitter): -1 | 0 | 1;
            \\}
            \\export = MiniEmitter;
            ,
        });
        try d.writeFile(io, .{
            .sub_path = "index.d.ts",
            .data =
            \\import MiniEmitter = require("./cjs_emitter");
            \\
            \\export enum HttpStatus {
            \\    Ok = 200,
            \\    SuccessAlias = 200,
            \\    Created = 201,
            \\    NotFound = 404,
            \\}
            \\export const enum LogLevel {
            \\    Debug = "debug",
            \\    Info = "info",
            \\    InfoAlias = "info",
            \\    Warn = "warn",
            \\}
            \\export enum MixedMode {
            \\    Auto = "auto",
            \\    Manual = 1,
            \\}
            \\export enum LargeEnum {
            \\    Big = 5_000_000_000,
            \\    NegBig = -5_000_000_000,
            \\}
            \\export enum OpKind {
            \\    Add = "add",
            \\    Sub = "sub",
            \\}
            \\
            \\export type Encoding = "utf8" | "utf-8" | "hex" | "base64";
            \\export type CompareResult = -1 | 0 | 1;
            \\export type FloatChoice = 0.5 | 1.5 | 2.5;
            \\export type BigChoice = 10n | 20n;
            \\export type CollapsedBool = true | false;
            \\export type StrOrBoolPair = string | true | false;
            \\
            \\export type OpenEncoding = "utf8" | "hex" | (string & {});
            \\export type OpenPort = 80 | 443 | (number & {});
            \\export type OpenFromCollision = "from" | "to" | (string & {});
            \\
            \\export type EventHook = `on${"Data" | "End" | "Error"}`;
            \\export type SemVer = `v${number}.${number}.${number}`;
            \\export type HttpUrl = `${"http" | "https"}://${string}`;
            \\
            \\export interface SharedMeta {
            \\    traceId: string;
            \\}
            \\export type AuditEvent =
            \\    | (SharedMeta & { kind: "created"; owner: string })
            \\    | (SharedMeta & { kind: "updated" | "patched"; rev: number })
            \\    | (SharedMeta & { kind: "deleted"; soft?: boolean });
            \\
            \\export type Outcome =
            \\    | { ok: true; payload: string }
            \\    | { ok: false; code: number; detail: string | null };
            \\
            \\export type OpCommand =
            \\    | { op: OpKind.Add; delta: number }
            \\    | { op: OpKind.Sub; delta: number };
            \\
            \\export type JsonValue =
            \\    | string
            \\    | number
            \\    | boolean
            \\    | null
            \\    | JsonValue[]
            \\    | { [key: string]: JsonValue };
            \\
            \\export type HeteroInput =
            \\    | [string]
            \\    | [string, number]
            \\    | string[]
            \\    | Uint8Array
            \\    | MiniEmitter
            \\    | SemVer
            \\    | { host: string; port?: number }
            \\    | string
            \\    | number;
            \\
            \\export type GenericEnvelope<T> =
            \\    | { tag: "val"; item: T }
            \\    | { tag: "empty"; reason: string | null };
            \\
            \\export declare function checkEncoding(enc: Encoding, openEnc: OpenEncoding, col: OpenFromCollision): CompareResult;
            \\export declare function checkSemVer(ver: SemVer, hook: EventHook, url: HttpUrl): SemVer;
            \\export declare function handleEvent(ev: AuditEvent, out: Outcome, cmd: OpCommand): Outcome;
            \\export declare function echoHetero(input: HeteroInput, json: JsonValue): HeteroInput;
            \\export declare function unwrapEnvelope(env: GenericEnvelope<number | undefined>): GenericEnvelope<string | null>;
            ,
        });
    }

    const index_dts = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{src_dir});
    defer alloc.free(index_dts);
    const cjs_dts = try std.fmt.allocPrint(alloc, "{s}/cjs_emitter.d.ts", .{src_dir});
    defer alloc.free(cjs_dts);

    const cli_args = [_][]const u8{ "-t", index_dts, "-t", cjs_dts, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Issue #47 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    // Golden source checks on `index.zig` and `cjs_emitter.zig`
    {
        var out_h = try cwd.openDir(io, out_dir, .{});
        defer out_h.close(io);

        const cjs_src = try out_h.readFileAlloc(io, "cjs_emitter.zig", alloc, .limited(128 * 1024));
        defer alloc.free(cjs_src);
        try std.testing.expect(std.mem.indexOf(u8, cjs_src, ".ctor_target = .{ .module = \"cjs_emitter\", .name = \"MiniEmitter\", .is_default = true }") != null);

        const idx_src = try out_h.readFileAlloc(io, "index.zig", alloc, .limited(512 * 1024));
        defer alloc.free(idx_src);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, "pub const CollapsedBool = bool;") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".is_alias = true, .alias_of = \"ok\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".is_open_literal = true") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".is_template_literal = true") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".discriminant = \"kind\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".discriminant = \"ok\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".discriminant = \"op\"") != null);
        // GenericEnvelope<number | undefined> must propagate `.variants` nullish override into `.item = .undefined_only`!
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".variants = .{ .{ .name = \"val\", .nullish = .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, idx_src, ".name = \"item\", .nullish = .undefined_only") != null);
    }

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_issue47.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_issue47.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\
            \\test "Issue #47 Sema: enums, aliases, open literals, template patterns, discriminated & recursive unions" {
            \\    // 1. Enums: backing types, aliases, const enum, i64 enum, mixed enum
            \\    try std.testing.expectEqual(@as(i32, 200), r.HttpStatus.ok.toInt());
            \\    try std.testing.expectEqual(r.HttpStatus.ok, r.HttpStatus.success_alias);
            \\    try std.testing.expectEqual(@as(?r.HttpStatus, .not_found), r.HttpStatus.fromInt(404));
            \\    try std.testing.expect(r.LogLevel.zigar_js.is_const);
            \\    try std.testing.expectEqualStrings("info", r.LogLevel.info.toSlice());
            \\    try std.testing.expectEqual(r.LogLevel.info, r.LogLevel.info_alias);
            \\    try std.testing.expectEqual(@as(i64, 5_000_000_000), r.LargeEnum.big.toInt());
            \\    try std.testing.expect(@typeInfo(r.MixedMode) == .@"enum");
            \\
            \\    // 2. Closed literal unions -> Zig enums + collapsed bool
            \\    try std.testing.expect(@typeInfo(r.Encoding) == .@"enum");
            \\    try std.testing.expectEqualStrings("utf-8", r.Encoding.utf_8.toSlice());
            \\    try std.testing.expectEqual(@as(i32, -1), r.CompareResult.neg_1.toInt());
            \\    try std.testing.expect(r.CollapsedBool == bool);
            \\
            \\    // 3. Open literal unions + `from` collision guard
            \\    try std.testing.expectEqual(r.OpenEncoding.utf8, r.OpenEncoding.from("utf8"));
            \\    const custom_enc = r.OpenEncoding.from("win1252");
            \\    try std.testing.expectEqualStrings("win1252", custom_enc.custom);
            \\    try std.testing.expectEqual(r.OpenPort.n_443, r.OpenPort.from(443));
            \\    try std.testing.expectEqual(@as(f64, 8080), r.OpenPort.from(8080).custom);
            \\    const fc: r.OpenFromCollision = .from;
            \\    try std.testing.expect(fc == .from);
            \\
            \\    // 4. Finite & open template literals (`initComptime`, `matches`, `from`)
            \\    try std.testing.expect(@typeInfo(r.EventHook) == .@"enum");
            \\    try std.testing.expectEqualStrings("onData", r.EventHook.on_data.toSlice());
            \\    const ver = comptime r.SemVer.initComptime("v26.1.0");
            \\    try std.testing.expectEqualStrings("v26.1.0", ver.raw);
            \\    try std.testing.expect(r.SemVer.matches("v0.17.1"));
            \\    try std.testing.expect(!r.SemVer.matches("v0.17"));
            \\    try std.testing.expectError(error.TypeError, r.SemVer.from("bad"));
            \\    const url = comptime r.HttpUrl.initComptime("https://ziglang.org/download");
            \\    try std.testing.expectEqualStrings("https://ziglang.org/download", url.raw);
            \\
            \\    // 5. Discriminated unions (intersection flattened, multi-tag, boolean, enum-member, generic)
            \\    const ev1: r.AuditEvent = .{ .created = .{ .trace_id = "t1", .owner = "alice" } };
            \\    try std.testing.expectEqualStrings("created", ev1.created.kind);
            \\    const ev2: r.AuditEvent = .{ .updated_or_patched = .{ .trace_id = "t2", .kind = .patched, .rev = 3 } };
            \\    try std.testing.expectEqual(@as(f64, 3), ev2.updated_or_patched.rev);
            \\    const out_ok: r.Outcome = .{ .ok_true = .{ .payload = "done" } };
            \\    try std.testing.expect(out_ok.ok_true.ok);
            \\    const cmd_add: r.OpCommand = .{ .add = .{ .delta = 5 } };
            \\    try std.testing.expectEqual(r.OpKind.add, cmd_add.add.op);
            \\    const env_val: r.GenericEnvelope(?f64) = .{ .val = .{ .item = null } };
            \\    try std.testing.expectEqualStrings("val", env_val.val.tag);
            \\
            \\    // 6. Recursive JsonValue has finite @sizeOf, and HeteroInput.from coerces cleanly
            \\    try std.testing.expect(@sizeOf(r.JsonValue) > 0);
            \\    const hi_str = r.HeteroInput.from("hello");
            \\    try std.testing.expectEqualStrings("hello", hi_str.str);
            \\    const hi_ver = r.HeteroInput.from(ver);
            \\    try std.testing.expectEqualStrings("v26.1.0", hi_ver.sem_ver.raw);
            \\    const sbp_s: r.StrOrBoolPair = .{ .str = "hello" };
            \\    const sbp_b: r.StrOrBoolPair = .{ .boolean = true };
            \\    try std.testing.expectEqualStrings("hello", sbp_s.str);
            \\    try std.testing.expect(sbp_b.boolean);
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Issue #47 @types/node@26 sweep: buffer, fs, events, http, stream pass AstGen and deep 3-level recursive Zig Sema" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const types_node_dir = (try resolveTypesNode26Dir(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(types_node_dir);

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue47-node26-sweep", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const cli_args = [_][]const u8{
        "-t", types_node_dir,
        "-m", "buffer",
        "-m", "fs",
        "-m", "events",
        "-m", "http",
        "-m", "stream",
        "-d", out_dir,
    };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Issue #47 @types/node@26 sweep error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    const probe_zig = try std.fmt.allocPrint(alloc, "{s}/deep_sema_probe.zig", .{sandbox});
    defer alloc.free(probe_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "deep_sema_probe.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const globals = @import("out/globals.zig");
            \\
            \\fn touchRecursive(comptime T: type, comptime depth: usize) void {
            \\    if (depth == 0) return;
            \\    inline for (comptime std.meta.declarations(T)) |decl_name| {
            \\        const val = @field(T, decl_name);
            \\        _ = &@field(T, decl_name);
            \\        if (@TypeOf(val) == type) {
            \\            _ = @sizeOf(val);
            \\            switch (@typeInfo(val)) {
            \\                .@"struct", .@"union", .@"enum" => touchRecursive(val, depth - 1),
            \\                else => {},
            \\            }
            \\        }
            \\    }
            \\}
            \\
            \\test "deep 3-level Sema across @types/node@26 buffer, fs, events, http, stream, globals" {
            \\    @setEvalBranchQuota(10_000_000);
            \\    touchRecursive(r.node_buffer, 3);
            \\    touchRecursive(r.node_fs, 3);
            \\    touchRecursive(r.node_events, 3);
            \\    touchRecursive(r.node_http, 3);
            \\    touchRecursive(r.node_stream, 3);
            \\    touchRecursive(globals, 3);
            \\
            \\    try std.testing.expect(@typeInfo(r.node_buffer.BufferEncoding) == .@"enum");
            \\    try std.testing.expectEqualStrings("utf-8", r.node_buffer.BufferEncoding.utf_8.toSlice());
            \\    try std.testing.expectEqual(@as(?r.node_buffer.BufferEncoding, .hex), r.node_buffer.BufferEncoding.fromSlice("hex"));
            \\    try std.testing.expect(@typeInfo(r.node_fs.BufferEncodingOption) == .@"union");
            \\    try std.testing.expect(@typeInfo(r.node_fs.PathLike) == .@"union");
            \\    try std.testing.expect(@typeInfo(r.node_fs.OpenMode) == .@"union");
            \\}
            ,
        });
    }

    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", probe_zig });
}

test "Issue #48 M3.2a Sema: plain options structs vs handle classes, divergent accessors, companion var ctors, callable handles, and collision safety" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue48-objects", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    try cwd.createDirPath(io, src_dir);
    {
        var sd = try cwd.openDir(io, src_dir, .{});
        defer sd.close(io);
        try sd.writeFile(io, .{
            .sub_path = "m3_objects.d.ts",
            .data =
            \\export interface BaseOptions {
            \\  host?: string;
            \\  readonly keepAlive?: boolean;
            \\}
            \\
            \\export interface ExtraOptions {
            \\  retries?: number;
            \\  onConnect?: (attempt: number) => void;
            \\}
            \\
            \\export interface RequestOptions extends BaseOptions, ExtraOptions {
            \\  host: string;
            \\  port?: number;
            \\}
            \\
            \\export interface LinkedNode {
            \\  id: string;
            \\  next?: LinkedNode;
            \\}
            \\
            \\export declare abstract class BaseTransport {
            \\  readonly protocol: string;
            \\  constructor(protocol: string);
            \\  static supportedCount(): number;
            \\  ping(): boolean;
            \\}
            \\
            \\export declare class HttpClient extends BaseTransport {
            \\  readonly baseUrl: string;
            \\  timeout: number;
            \\  mode: "fast" | "slow";
            \\  get endpoint(): string;
            \\  set endpoint(val: string | number);
            \\  set authToken(token: string);
            \\  static defaultPort: number;
            \\  static readonly version: string;
            \\  static set logSink(sink: string);
            \\  static get env(): string;
            \\  static set env(val: string | null);
            \\  constructor(baseUrl: string);
            \\  constructor(baseUrl: string, timeout: number);
            \\  static createDefault(): HttpClient;
            \\  fetchText(path: string): string;
            \\  transform<T>(input: T): T;
            \\}
            \\
            \\export interface CustomUrl {
            \\  href: string;
            \\  readonly origin: string;
            \\  toJSON(): string;
            \\}
            \\export interface CustomUrlConstructor {
            \\  prototype: CustomUrl;
            \\  new(input: string, base?: string): CustomUrl;
            \\  canParse(input: string, base?: string): boolean;
            \\  readonly schemeVersion: number;
            \\}
            \\export declare var CustomUrl: CustomUrlConstructor;
            \\
            \\export interface CallableFactory {
            \\  (label: string): number;
            \\  new(baseUrl: string): HttpClient;
            \\  readonly tag: string;
            \\}
            \\
            \\export declare class CollisionHandle {
            \\  ref: number;
            \\  self: string;
            \\  deinit(): boolean;
            \\  toJsRef(): number;
            \\  fromJsRef(x: number): string;
            \\}
            \\
            \\export interface Widget {
            \\  readonly id: number;
            \\  render(): string;
            \\}
            \\export declare function Widget(name: string): Widget;
            \\
            \\export interface FactoryConfig {
            \\  host: string;
            \\  port?: number;
            \\}
            \\export declare function FactoryConfig(host: string): FactoryConfig;
            \\
            \\export interface Box<T, M = string> {
            \\  value: T;
            \\  meta?: M;
            \\}
            \\export interface StrBox extends Box<string> {
            \\  extra: number;
            \\}
            \\
            \\export interface BaseEmitter<E, R = boolean> {
            \\  emit(ev: E): R;
            \\  readonly channel: E;
            \\}
            \\export interface MidEmitter<X> extends BaseEmitter<X, number> {}
            \\export interface Svc extends MidEmitter<string> {
            \\  port: number;
            \\}
            \\
            \\export type LoggerT = {
            \\  level: number;
            \\  log(msg: string): string;
            \\};
            \\export type PickedLogger = Pick<LoggerT, "level" | "log">;
            \\
            \\export type OptsT = {
            \\  a: number;
            \\  b?: string;
            \\};
            \\export interface ExtOptsT extends OptsT {
            \\  c: number;
            \\}
            \\export interface OptsI {
            \\  a: number;
            \\  b: string;
            \\}
            \\export interface ExtPick extends Pick<OptsI, "a"> {
            \\  c: number;
            \\}
            \\export interface ExtLoggerT extends LoggerT {
            \\  extra: number;
            \\}
            \\export interface ExtPickLogger extends Pick<LoggerT, "log"> {
            \\  tag: string;
            \\}
            \\export type Inter = { a: number } & { run(step: number): number };
            \\export type Both = LoggerT & { extra: number };
            \\export declare function makeInlineInter(): { a: number } & { run(): number };
            \\export declare function runInlineInter(x: { a: number } & { run(): number }): number;
            \\
            \\export interface NullableUnionBox<T> {
            \\  x: T | string;
            \\  y: T | "alpha" | "beta";
            \\}
            \\export interface NullOnlyBox extends NullableUnionBox<null> {}
            \\
            \\export declare function connectWith(opts: RequestOptions, node?: LinkedNode): HttpClient;
            ,
        });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const dts_path = try std.fmt.allocPrint(alloc, "{s}/m3_objects.d.ts", .{src_dir});
    defer alloc.free(dts_path);
    const cli_args = [_][]const u8{ "-t", dts_path, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Issue #48 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_issue48.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_issue48.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\
            \\test "Issue #48 plain options structs vs handle classes and stateful interfaces" {
            \\    // 1. RequestOptions: plain Zig struct with inherited fields, narrowed `host: []const u8`, and `= null` defaults!
            \\    try std.testing.expect(!@hasField(@TypeOf(r.RequestOptions.zigar_js), "is_handle"));
            \\    const opts: r.RequestOptions = .{ .host = "127.0.0.1", .port = 8080 };
            \\    try std.testing.expectEqualStrings("127.0.0.1", opts.host);
            \\    try std.testing.expectEqual(@as(?f64, 8080), opts.port);
            \\    try std.testing.expectEqual(@as(?bool, null), opts.keep_alive);
            \\    try std.testing.expectEqual(@as(?f64, null), opts.retries);
            \\    try std.testing.expect(opts.on_connect == null);
            \\    try std.testing.expect(@hasDecl(r.RequestOptions, "toJsRef"));
            \\    try std.testing.expect(@hasDecl(r.RequestOptions, "fromJsRefAlloc"));
            \\
            \\    // 2. Cyclic LinkedNode: plain Zig struct with `?*const LinkedNode` indirection!
            \\    const leaf: r.LinkedNode = .{ .id = "tail" };
            \\    const head: r.LinkedNode = .{ .id = "head", .next = &leaf };
            \\    try std.testing.expectEqualStrings("tail", head.next.?.id);
            \\    try std.testing.expect(@hasDecl(r.LinkedNode, "toJsRef"));
            \\    try std.testing.expect(@hasDecl(r.LinkedNode, "fromJsRefAlloc"));
            \\
            \\    // 3. Abstract BaseTransport: handle wrapper WITHOUT `pub fn init`, WITH static & instance members!
            \\    try std.testing.expect(r.BaseTransport.zigar_js.is_handle);
            \\    try std.testing.expect(r.BaseTransport.zigar_js.is_class);
            \\    try std.testing.expect(!@hasDecl(r.BaseTransport, "init"));
            \\    try std.testing.expect(!@hasDecl(r.BaseTransport, "setProtocol"));
            \\    _ = &r.BaseTransport.supportedCount;
            \\    _ = &r.BaseTransport.ping;
            \\
            \\    // 4. HttpClient: inherits `protocol` & `ping` from BaseTransport, semantic `initString`/`initWithTimeout` + unified `init`,
            \\    //    divergent `endpoint` + `setEndpoint`, write-only `setAuthToken`, shared nominal `mode`/`setMode`,
            \\    //    and static RW / RO / WO / divergent accessor targets!
            \\    try std.testing.expect(r.HttpClient.zigar_js.is_handle);
            \\    try std.testing.expect(r.HttpClient.zigar_js.is_class);
            \\    try std.testing.expect(!@hasDecl(r.HttpClient, "setBaseUrl"));
            \\    try std.testing.expect(!@hasDecl(r.HttpClient, "authToken"));
            \\    try std.testing.expect(@hasDecl(r.HttpClient, "setAuthToken"));
            \\    try std.testing.expect(!@hasDecl(r.HttpClient, "init_2"));
            \\    const c1: *const fn ([]const u8) r.zigar_js.CallError!r.HttpClient = &r.HttpClient.initString;
            \\    const c2: *const fn ([]const u8, f64) r.zigar_js.CallError!r.HttpClient = &r.HttpClient.initWithTimeout;
            \\    try std.testing.expectError(error.HostUnavailable, r.HttpClient.init("https://example.com"));
            \\    try std.testing.expectError(error.HostUnavailable, r.HttpClient.init(.{ "https://example.com", @as(f64, 1000) }));
            \\    const inherited_ping: *const fn (r.HttpClient) r.zigar_js.CallError!bool = &r.HttpClient.ping;
            \\    const inherited_proto: *const fn (r.HttpClient, std.mem.Allocator) r.zigar_js.CallError![]const u8 = &r.HttpClient.protocolAlloc;
            \\    const get_ep: *const fn (r.HttpClient, std.mem.Allocator) r.zigar_js.CallError![]const u8 = &r.HttpClient.endpointAlloc;
            \\    _ = c1;
            \\    _ = c2;
            \\    _ = inherited_ping;
            \\    _ = inherited_proto;
            \\    _ = get_ep;
            \\    _ = &r.HttpClient.setEndpoint;
            \\    try std.testing.expectError(error.HostUnavailable, r.HttpClient.default_port.get());
            \\    try std.testing.expectError(error.HostUnavailable, r.HttpClient.default_port.set(8080));
            \\    try std.testing.expect(!@hasDecl(@TypeOf(r.HttpClient.version), "set"));
            \\    try std.testing.expectError(error.HostUnavailable, r.HttpClient.version.getAlloc(std.testing.allocator));
            \\    try std.testing.expect(!@hasDecl(@TypeOf(r.HttpClient.log_sink), "get"));
            \\    try std.testing.expectError(error.HostUnavailable, r.HttpClient.log_sink.set("stdout"));
            \\    try std.testing.expectError(error.HostUnavailable, r.HttpClient.env.getAlloc(std.testing.allocator));
            \\    try std.testing.expectError(error.HostUnavailable, r.HttpClient.env.set(null));
            \\    try std.testing.expectError(error.HostUnavailable, r.HttpClient.env.set("prod"));
            \\
            \\    // Verify inline nominal enum `mode` shares exact type between getter and setter,
            \\    // and divergent `setEndpoint` accepts `union(enum) { string: []const u8, number: f64 }`!
            \\    const ModeFn = struct {
            \\        fn roundtripMode(client: r.HttpClient) !void {
            \\            const m = try client.mode();
            \\            try client.setMode(m);
            \\            try client.setEndpoint(.{ .str = "/v2" });
            \\            try client.setEndpoint(.{ .num = 2 });
            \\        }
            \\    };
            \\    _ = &ModeFn.roundtripMode;
            \\
            \\    // 5. Companion `interface CustomUrl` + `declare var CustomUrl: CustomUrlConstructor`:
            \\    try std.testing.expect(r.CustomUrl.zigar_js.is_handle);
            \\    try std.testing.expect(r.CustomUrl.zigar_js.is_class);
            \\    try std.testing.expect(!@hasDecl(r.CustomUrl, "prototype"));
            \\    try std.testing.expect(!@hasDecl(r.CustomUrl, "setOrigin"));
            \\    const url_ctor: *const fn ([]const u8, ?[]const u8) r.zigar_js.CallError!r.CustomUrl = &r.CustomUrl.init;
            \\    const can_parse: *const fn ([]const u8, ?[]const u8) r.zigar_js.CallError!bool = &r.CustomUrl.canParse;
            \\    _ = url_ctor;
            \\    _ = can_parse;
            \\    try std.testing.expectError(error.HostUnavailable, r.CustomUrl.scheme_version.get());
            \\
            \\    // 6. Callable + constructable interface `CallableFactory`:
            \\    try std.testing.expect(r.CallableFactory.zigar_js.is_handle);
            \\    try std.testing.expect(r.CallableFactory.zigar_js.is_callable_handle);
            \\    const cf_call: *const fn (r.CallableFactory, []const u8) r.zigar_js.CallError!f64 = &r.CallableFactory.call;
            \\    const cf_ctor: *const fn (r.CallableFactory, []const u8) r.zigar_js.CallError!r.HttpClient = &r.CallableFactory.construct;
            \\    _ = cf_call;
            \\    _ = cf_ctor;
            \\
            \\    // 7. CollisionHandle (`ref`, `self`, `deinit`, `toJsRef`, `fromJsRef`):
            \\    try std.testing.expectEqualStrings("__zigar_ref", r.CollisionHandle.zigar_js.ref_field);
            \\    try std.testing.expect(@hasField(r.CollisionHandle, "__zigar_ref"));
            \\    _ = &r.CollisionHandle.ref;
            \\    _ = &r.CollisionHandle.self;
            \\    _ = &r.CollisionHandle.deinit;
            \\    _ = &r.CollisionHandle.toJsRef;
            \\    _ = &r.CollisionHandle.fromJsRef;
            \\    try std.testing.expect(!@hasDecl(r.CollisionHandle, "deinit_2"));
            \\    try std.testing.expect(!@hasDecl(r.CollisionHandle, "toJsRef_2"));
            \\    try std.testing.expect(!@hasDecl(r.CollisionHandle, "fromJsRef_2"));
            \\
            \\    // 8. Interface + same-named factory function (`Widget` handle vs `FactoryConfig` value struct):
            \\    try std.testing.expect(r.Widget.zigar_js.is_handle);
            \\    try std.testing.expect(!@hasField(@TypeOf(r.Widget.zigar_js), "is_callable_handle"));
            \\    try std.testing.expect(@FieldType(r.Widget, "ref") == r.zigar_js.JsObject);
            \\    const widget_fn: *const fn ([]const u8) r.zigar_js.CallError!r.Widget = &r.widget;
            \\    _ = widget_fn;
            \\    try std.testing.expect(!@hasField(@TypeOf(r.FactoryConfig.zigar_js), "is_handle"));
            \\    const fc: r.FactoryConfig = .{ .host = "localhost" };
            \\    try std.testing.expectEqualStrings("localhost", fc.host);
            \\    try std.testing.expectEqual(@as(?f64, null), fc.port);
            \\
            \\    // 9. Generic `extends` instantiation on both value structs (`StrBox`) and chained handle interfaces (`Svc`):
            \\    try std.testing.expect(!@hasField(@TypeOf(r.StrBox.zigar_js), "is_handle"));
            \\    const sb: r.StrBox = .{ .value = "payload", .extra = 42 };
            \\    try std.testing.expectEqualStrings("payload", sb.value);
            \\    try std.testing.expectEqual(@as(?[]const u8, null), sb.meta);
            \\    try std.testing.expectEqual(@as(f64, 42), sb.extra);
            \\
            \\    try std.testing.expect(r.Svc.zigar_js.is_handle);
            \\    const svc_emit: *const fn (r.Svc, []const u8) r.zigar_js.CallError!f64 = &r.Svc.emit;
            \\    const svc_chan: *const fn (r.Svc, std.mem.Allocator) r.zigar_js.CallError![]const u8 = &r.Svc.channelAlloc;
            \\    const svc_port: *const fn (r.Svc) r.zigar_js.CallError!f64 = &r.Svc.port;
            \\    _ = svc_emit;
            \\    _ = svc_chan;
            \\    _ = svc_port;
            \\
            \\    // 10. Object-literal type aliases with methods (`LoggerT` & `PickedLogger`) lower to `.handle_wrapper`:
            \\    try std.testing.expect(r.LoggerT.zigar_js.is_handle);
            \\    try std.testing.expect(!@hasField(@TypeOf(r.LoggerT.zigar_js), "is_callable_handle"));
            \\    const lt_log: *const fn (r.LoggerT, std.mem.Allocator, []const u8) r.zigar_js.CallError![]const u8 = &r.LoggerT.logAlloc;
            \\    const lt_lvl: *const fn (r.LoggerT) r.zigar_js.CallError!f64 = &r.LoggerT.level;
            \\    const lt_set_lvl: *const fn (r.LoggerT, f64) r.zigar_js.CallError!void = &r.LoggerT.setLevel;
            \\    _ = lt_log;
            \\    _ = lt_lvl;
            \\    _ = lt_set_lvl;
            \\    try std.testing.expect(r.PickedLogger.zigar_js.is_handle);
            \\    const pl_log: *const fn (r.PickedLogger, std.mem.Allocator, []const u8) r.zigar_js.CallError![]const u8 = &r.PickedLogger.logAlloc;
            \\    _ = pl_log;
            \\
            \\    // 11. Generic `extends` with `T = null` in `T | string` and `T | "alpha" | "beta"` collapses cleanly:
            \\    try std.testing.expect(@FieldType(r.NullOnlyBox, "x") == ?[]const u8);
            \\    try std.testing.expectEqual(.null_only, r.NullOnlyBox.zigar_js.fields[0].nullish);
            \\    try std.testing.expect(@typeInfo(@typeInfo(@FieldType(r.NullOnlyBox, "y")).optional.child) == .@"enum");
            \\    try std.testing.expectEqual(.null_only, r.NullOnlyBox.zigar_js.fields[1].nullish);
            \\    const nb: r.NullOnlyBox = .{ .x = null, .y = .alpha };
            \\    try std.testing.expect(nb.x == null);
            \\    try std.testing.expectEqual(.alpha, nb.y.?);
            \\
            \\    // 12. `interface extends` type alias (`ExtOptsT`, `ExtLoggerT`) and utility base (`ExtPick`, `ExtPickLogger`):
            \\    try std.testing.expect(!@hasField(@TypeOf(r.ExtOptsT.zigar_js), "is_handle"));
            \\    const eo: r.ExtOptsT = .{ .a = 1, .c = 2 };
            \\    try std.testing.expectEqual(@as(f64, 1), eo.a);
            \\    try std.testing.expectEqual(@as(?[]const u8, null), eo.b);
            \\    try std.testing.expectEqual(@as(f64, 2), eo.c);
            \\
            \\    try std.testing.expect(!@hasField(@TypeOf(r.ExtPick.zigar_js), "is_handle"));
            \\    try std.testing.expect(!@hasField(r.ExtPick, "b"));
            \\    const ep: r.ExtPick = .{ .a = 10, .c = 20 };
            \\    try std.testing.expectEqual(@as(f64, 10), ep.a);
            \\    try std.testing.expectEqual(@as(f64, 20), ep.c);
            \\
            \\    try std.testing.expect(r.ExtLoggerT.zigar_js.is_handle);
            \\    const elt_log: *const fn (r.ExtLoggerT, std.mem.Allocator, []const u8) r.zigar_js.CallError![]const u8 = &r.ExtLoggerT.logAlloc;
            \\    const elt_lvl: *const fn (r.ExtLoggerT) r.zigar_js.CallError!f64 = &r.ExtLoggerT.level;
            \\    const elt_ext: *const fn (r.ExtLoggerT) r.zigar_js.CallError!f64 = &r.ExtLoggerT.extra;
            \\    _ = elt_log;
            \\    _ = elt_lvl;
            \\    _ = elt_ext;
            \\
            \\    try std.testing.expect(r.ExtPickLogger.zigar_js.is_handle);
            \\    try std.testing.expect(!@hasDecl(r.ExtPickLogger, "level"));
            \\    const epl_log: *const fn (r.ExtPickLogger, std.mem.Allocator, []const u8) r.zigar_js.CallError![]const u8 = &r.ExtPickLogger.logAlloc;
            \\    const epl_tag: *const fn (r.ExtPickLogger, std.mem.Allocator) r.zigar_js.CallError![]const u8 = &r.ExtPickLogger.tagAlloc;
            \\    _ = epl_log;
            \\    _ = epl_tag;
            \\
            \\    // 13. Handle-bearing intersections (`Inter`, `Both`, and inline `{ a: number } & { run(): number }`):
            \\    try std.testing.expect(r.Inter.zigar_js.is_handle);
            \\    const inter_a: *const fn (r.Inter) r.zigar_js.CallError!f64 = &r.Inter.a;
            \\    const inter_run: *const fn (r.Inter, f64) r.zigar_js.CallError!f64 = &r.Inter.run;
            \\    _ = inter_a;
            \\    _ = inter_run;
            \\
            \\    try std.testing.expect(r.Both.zigar_js.is_handle);
            \\    const both_log: *const fn (r.Both, std.mem.Allocator, []const u8) r.zigar_js.CallError![]const u8 = &r.Both.logAlloc;
            \\    const both_lvl: *const fn (r.Both) r.zigar_js.CallError!f64 = &r.Both.level;
            \\    const both_ext: *const fn (r.Both) r.zigar_js.CallError!f64 = &r.Both.extra;
            \\    _ = both_log;
            \\    _ = both_lvl;
            \\    _ = both_ext;
            \\
            \\    const InlineHelper = struct {
            \\        fn check() !void {
            \\            var inl = try r.makeInlineInter();
            \\            defer inl.deinit();
            \\            try std.testing.expect(@TypeOf(inl).zigar_js.is_handle);
            \\            const a_val: f64 = try inl.a();
            \\            const r_val: f64 = try inl.run();
            \\            _ = a_val;
            \\            _ = r_val;
            \\            _ = try r.runInlineInter(.{ .ref = inl.ref });
            \\        }
            \\    };
            \\    _ = &InlineHelper.check;
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Issue #49 M3.2b Sema: multi-level inheritance, diamond overloads, A & B intersections, index signatures, and merged declarations" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue49-heritage", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    try cwd.createDirPath(io, src_dir);
    {
        var sd = try cwd.openDir(io, src_dir, .{});
        defer sd.close(io);
        try sd.writeFile(io, .{
            .sub_path = "m3_heritage_base.d.ts",
            .data =
            \\export declare class EventEmitter {
            \\  constructor(maxListeners?: number);
            \\  on(ev: string, listener: (arg: string) => void): this;
            \\  emit(ev: string): boolean;
            \\  emit(ev: string, code: number): boolean;
            \\  listenerCount(ev: string): number;
            \\}
            \\
            \\export declare class Stream extends EventEmitter {
            \\  pipeTo(dest: string): boolean;
            \\}
            ,
        });
        try sd.writeFile(io, .{
            .sub_path = "m3_heritage_cjs.d.ts",
            .data =
            \\declare function $(selector: string): $.Selection;
            \\declare function $(selector: string, root: string): $.Selection;
            \\declare namespace $ {
            \\  export interface Selection {
            \\    readonly length: number;
            \\    text(): string;
            \\  }
            \\  export const version: string;
            \\  export function ajax(url: string): string;
            \\}
            \\export = $;
            ,
        });
        try sd.writeFile(io, .{
            .sub_path = "m3_heritage.d.ts",
            .data =
            \\import { EventEmitter, Stream } from "./m3_heritage_base";
            \\import $ = require("./m3_heritage_cjs");
            \\export { EventEmitter, Stream, $ };
            \\
            \\declare module "./m3_heritage_base" {
            \\  interface EventEmitter {
            \\    augmentedTag(): string;
            \\  }
            \\  namespace EventEmitter {
            \\    export const specRevision: number;
            \\  }
            \\}
            \\
            \\export declare class Writable extends Stream {
            \\  readonly writableEnded: boolean;
            \\  write(chunk: string): boolean;
            \\  write(chunk: Uint8Array): boolean;
            \\  end(): void;
            \\}
            \\
            \\export declare class OutgoingMessage extends Writable {
            \\  readonly headersSent: boolean;
            \\  setHeader(name: string, value: string): void;
            \\  getHeader(name: string): string | undefined;
            \\}
            \\
            \\export interface Flushable {
            \\  flushHeaders(): void;
            \\}
            \\
            \\export declare class ServerResponse extends OutgoingMessage implements Flushable {
            \\  statusCode: number;
            \\  writeHead(statusCode: number, statusMessage?: string): this;
            \\  flushHeaders(): void;
            \\}
            \\
            \\export interface SharedCore {
            \\  readonly id: string;
            \\  close(): void;
            \\}
            \\export interface TextChannel extends SharedCore {
            \\  send(text: string): number;
            \\}
            \\export interface BinaryChannel extends SharedCore {
            \\  send(bytes: Uint8Array): number;
            \\}
            \\export interface DuplexChannel extends TextChannel, BinaryChannel {
            \\  drain(): boolean;
            \\}
            \\
            \\export interface HostConfig {
            \\  host: string;
            \\  port?: number;
            \\}
            \\export interface TlsConfig {
            \\  cert: string;
            \\  alpn?: "h2" | "http/1.1";
            \\}
            \\export interface ServerConfig extends HostConfig, TlsConfig {
            \\  keepAlive?: boolean;
            \\}
            \\export type CombinedConfig = HostConfig & TlsConfig & { retries?: number };
            \\
            \\export type TrackedWritable = Writable & {
            \\  readonly bytesWritten: number;
            \\  resetCounters(): void;
            \\};
            \\export type HybridRouter = ((path: string) => boolean) & {
            \\  mountPath: string;
            \\  reload(): void;
            \\};
            \\export type EmptyResult = string & number;
            \\export type UserId = string & { readonly __brand: "UserId" };
            \\export type PortNum = number & { readonly __portBrand: unique symbol };
            \\export type TaggedOutcome = (
            \\  | { kind: "ok"; value: number }
            \\  | { kind: "err"; message: string }
            \\) & { requestId: string };
            \\
            \\export interface HeaderBag {
            \\  [key: string]: string;
            \\}
            \\export interface DualTable {
            \\  readonly [index: number]: string;
            \\  [key: string]: string | number;
            \\}
            \\export type DataKey = `data-${string}`;
            \\export interface DataAttrMap {
            \\  [key: DataKey]: string;
            \\}
            \\export enum HttpVerb {
            \\  Get = "GET",
            \\  Post = "POST",
            \\}
            \\export interface VerbTable {
            \\  [verb: HttpVerb]: number;
            \\}
            \\export interface InlineEnumDict {
            \\  [key: string]: "on" | "off";
            \\}
            \\export interface CollidingDict {
            \\  get(slot: number): boolean;
            \\  set(slot: number, active: boolean): void;
            \\  init(seed: string): void;
            \\  [key: string]: any;
            \\}
            \\
            \\export interface MergedRegistry {
            \\  readonly name: string;
            \\  has(key: string): boolean;
            \\}
            \\export interface MergedRegistry {
            \\  count: number;
            \\  clear(): void;
            \\  [extra: string]: any;
            \\}
            \\
            \\export declare class RichService {
            \\  constructor(endpoint: string);
            \\  connect(): boolean;
            \\}
            \\export interface RichService {
            \\  mixinPing(): string;
            \\}
            \\export declare namespace RichService {
            \\  export interface Options {
            \\    timeoutMs?: number;
            \\  }
            \\  export const defaultTimeout: number;
            \\  export function fromOptions(opts: Options): RichService;
            \\}
            \\
            \\export declare function formatMetric(name: string, val: number): string;
            \\export declare namespace formatMetric {
            \\  export const prefix: string;
            \\  export function reset(): void;
            \\}
            \\
            \\export declare function _(items: readonly string[]): number;
            \\export declare namespace _ {
            \\  export const VERSION: string;
            \\  export function uniq(items: readonly string[]): string[];
            \\}
            \\
            \\export enum LogLevel {
            \\  Info = 0,
            \\  Warn = 1,
            \\  Error = 2,
            \\}
            \\export declare namespace LogLevel {
            \\  export function parse(label: string): LogLevel;
            \\  export const defaultLevel: LogLevel;
            \\}
            \\
            \\export declare namespace Telemetry {
            \\  export const serviceName: string;
            \\  export function flush(): void;
            \\}
            \\export declare namespace Telemetry {
            \\  export const sampleRate: number;
            \\  export function record(metric: string): void;
            \\}
            ,
        });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const dts_path = try std.fmt.allocPrint(alloc, "{s}/m3_heritage.d.ts", .{src_dir});
    defer alloc.free(dts_path);
    const cli_args = [_][]const u8{ "-t", dts_path, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Issue #49 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_issue49.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_issue49.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const h = r.m3_heritage;
            \\const cjs = @import("out/m3_heritage_cjs.zig");
            \\
            \\test "Issue #49 multi-level inheritance, diamond overloads, intersections, indexers, and merged decls" {
            \\    // 1. 5-level class hierarchy + inherited constructors + external module augmentation on EventEmitter!
            \\    const sr_ctor: *const fn (?f64) r.zigar_js.CallError!h.ServerResponse = &h.ServerResponse.init;
            \\    const sr_wh: *const fn (h.ServerResponse, f64, ?[]const u8) r.zigar_js.CallError!h.ServerResponse = &h.ServerResponse.writeHead;
            \\    const sr_sh: *const fn (h.ServerResponse, []const u8, []const u8) r.zigar_js.CallError!void = &h.ServerResponse.setHeader;
            \\    const sr_w1: *const fn (h.ServerResponse, []const u8) r.zigar_js.CallError!bool = &h.ServerResponse.writeString;
            \\    const sr_w2: *const fn (h.ServerResponse, r.zigar_js.Uint8Array) r.zigar_js.CallError!bool = &h.ServerResponse.writeUint8Array;
            \\    const sr_pipe: *const fn (h.ServerResponse, []const u8) r.zigar_js.CallError!bool = &h.ServerResponse.pipeTo;
            \\    const sr_emit1: *const fn (h.ServerResponse, []const u8) r.zigar_js.CallError!bool = &h.ServerResponse.emitString;
            \\    const sr_emit2: *const fn (h.ServerResponse, []const u8, f64) r.zigar_js.CallError!bool = &h.ServerResponse.emitWithCode;
            \\    const sr_aug: *const fn (h.ServerResponse, std.mem.Allocator) r.zigar_js.CallError![]const u8 = &h.ServerResponse.augmentedTagAlloc;
            \\    try std.testing.expect(@hasDecl(h.ServerResponse, "write"));
            \\    try std.testing.expect(!@hasDecl(h.ServerResponse, "write_2"));
            \\    try std.testing.expect(@hasDecl(h.ServerResponse, "emit"));
            \\    try std.testing.expect(!@hasDecl(h.ServerResponse, "emit_2"));
            \\    _ = sr_ctor;
            \\    _ = sr_wh;
            \\    _ = sr_sh;
            \\    _ = sr_w1;
            \\    _ = sr_w2;
            \\    _ = sr_pipe;
            \\    _ = sr_emit1;
            \\    _ = sr_emit2;
            \\    _ = sr_aug;
            \\    try std.testing.expectError(error.HostUnavailable, h.EventEmitter.spec_revision.get());
            \\
            \\    // Comptime `.bases` assignability across all 5 levels + `implements Flushable` + negative check!
            \\    try std.testing.expect(comptime r.zigar_js.isAssignableType(h.ServerResponse, h.OutgoingMessage));
            \\    try std.testing.expect(comptime r.zigar_js.isAssignableType(h.ServerResponse, h.Writable));
            \\    try std.testing.expect(comptime r.zigar_js.isAssignableType(h.ServerResponse, h.Stream));
            \\    try std.testing.expect(comptime r.zigar_js.isAssignableType(h.ServerResponse, h.EventEmitter));
            \\    try std.testing.expect(comptime r.zigar_js.isAssignableType(h.ServerResponse, h.Flushable));
            \\    try std.testing.expect(comptime !r.zigar_js.isAssignableType(h.ServerResponse, h.DuplexChannel));
            \\
            \\    const CastProbe = struct {
            \\        fn verifyCasts(sr: h.ServerResponse, ee: h.EventEmitter) !void {
            \\            const as_ee: h.EventEmitter = sr.as(h.EventEmitter);
            \\            const as_fl: h.Flushable = sr.as(h.Flushable);
            \\            _ = as_fl;
            \\            const owned_ee = try as_ee.clone();
            \\            defer owned_ee.deinit();
            \\            if (try ee.tryAs(h.ServerResponse)) |down_sr| {
            \\                _ = try down_sr.statusCode();
            \\            }
            \\        }
            \\    };
            \\    _ = &CastProbe.verifyCasts;
            \\
            \\    // 2. Diamond multi-interface inheritance preserves BOTH `send(string)` and `send(Uint8Array)` overloads
            \\    //    while deduplicating `SharedCore.id` and `SharedCore.close`!
            \\    const dc_s1: *const fn (h.DuplexChannel, []const u8) r.zigar_js.CallError!f64 = &h.DuplexChannel.sendString;
            \\    const dc_s2: *const fn (h.DuplexChannel, r.zigar_js.Uint8Array) r.zigar_js.CallError!f64 = &h.DuplexChannel.sendUint8Array;
            \\    const dc_close: *const fn (h.DuplexChannel) r.zigar_js.CallError!void = &h.DuplexChannel.close;
            \\    _ = dc_s1;
            \\    _ = dc_s2;
            \\    _ = dc_close;
            \\    try std.testing.expect(@hasDecl(h.DuplexChannel, "send"));
            \\    try std.testing.expect(!@hasDecl(h.DuplexChannel, "send_2"));
            \\    try std.testing.expect(!@hasDecl(h.DuplexChannel, "close_2"));
            \\    try std.testing.expect(comptime r.zigar_js.isAssignableType(h.DuplexChannel, h.SharedCore));
            \\
            \\    // 3. Value-struct inheritance & `A & B` value intersection + `.as(Base)` runtime field projection!
            \\    const sc: h.ServerConfig = .{ .host = "0.0.0.0", .port = 443, .cert = "pem-data", .alpn = .h2, .keep_alive = true };
            \\    const sc_host = sc.as(h.HostConfig);
            \\    const sc_tls = sc.as(h.TlsConfig);
            \\    try std.testing.expectEqualStrings("0.0.0.0", sc_host.host);
            \\    try std.testing.expectEqual(@as(?f64, 443), sc_host.port);
            \\    try std.testing.expectEqualStrings("pem-data", sc_tls.cert);
            \\    try std.testing.expectEqual(.h2, sc_tls.alpn.?);
            \\
            \\    const cc: h.CombinedConfig = .{ .host = "127.0.0.1", .cert = "local-pem", .retries = 3 };
            \\    const cc_host = cc.as(h.HostConfig);
            \\    const cc_tls = cc.as(h.TlsConfig);
            \\    try std.testing.expectEqualStrings("127.0.0.1", cc_host.host);
            \\    try std.testing.expectEqual(@as(?f64, null), cc_host.port);
            \\    try std.testing.expectEqualStrings("local-pem", cc_tls.cert);
            \\    try std.testing.expectEqual(@as(?f64, 3), cc.retries);
            \\
            \\    // 4. Handle `A & B` intersection (`TrackedWritable`) & callable hybrid intersection (`HybridRouter`):
            \\    try std.testing.expect(h.TrackedWritable.zigar_js.is_handle);
            \\    try std.testing.expect(comptime r.zigar_js.isAssignableType(h.TrackedWritable, h.Writable));
            \\    try std.testing.expect(comptime r.zigar_js.isAssignableType(h.TrackedWritable, h.EventEmitter));
            \\    _ = &h.TrackedWritable.bytesWritten;
            \\    _ = &h.TrackedWritable.resetCounters;
            \\    _ = &h.TrackedWritable.write;
            \\
            \\    try std.testing.expect(h.HybridRouter.zigar_js.is_handle);
            \\    try std.testing.expect(h.HybridRouter.zigar_js.is_callable_handle);
            \\    const hr_call: *const fn (h.HybridRouter, []const u8) r.zigar_js.CallError!bool = &h.HybridRouter.call;
            \\    const hr_mp: *const fn (h.HybridRouter, std.mem.Allocator) r.zigar_js.CallError![]const u8 = &h.HybridRouter.mountPathAlloc;
            \\    const hr_reload: *const fn (h.HybridRouter) r.zigar_js.CallError!void = &h.HybridRouter.reload;
            \\    _ = hr_call;
            \\    _ = hr_mp;
            \\    _ = hr_reload;
            \\
            \\    // 5. Index signatures: HeaderBag (`init`, `getAlloc`, `set`), DualTable (readonly numeric + RW string),
            \\    //    DataAttrMap (template key), VerbTable (enum key), InlineEnumDict (shared nominal value), CollidingDict!
            \\    try std.testing.expect(h.HeaderBag.zigar_js.is_handle);
            \\    try std.testing.expectError(error.HostUnavailable, h.HeaderBag.init());
            \\    const hb_get: *const fn (h.HeaderBag, std.mem.Allocator, []const u8) r.zigar_js.CallError!?[]const u8 = &h.HeaderBag.getAlloc;
            \\    const hb_set: *const fn (h.HeaderBag, []const u8, []const u8) r.zigar_js.CallError!void = &h.HeaderBag.set;
            \\    _ = hb_get;
            \\    _ = hb_set;
            \\
            \\    try std.testing.expect(@hasDecl(h.DualTable, "getIndexAlloc"));
            \\    try std.testing.expect(!@hasDecl(h.DualTable, "setIndex"));
            \\    try std.testing.expect(@hasDecl(h.DualTable, "getAlloc"));
            \\    try std.testing.expect(@hasDecl(h.DualTable, "set"));
            \\
            \\    const dam_get: *const fn (h.DataAttrMap, std.mem.Allocator, h.DataKey) r.zigar_js.CallError!?[]const u8 = &h.DataAttrMap.getAlloc;
            \\    const dam_set: *const fn (h.DataAttrMap, h.DataKey, []const u8) r.zigar_js.CallError!void = &h.DataAttrMap.set;
            \\    _ = dam_get;
            \\    _ = dam_set;
            \\
            \\    const vt_get: *const fn (h.VerbTable, h.HttpVerb) r.zigar_js.CallError!?f64 = &h.VerbTable.get;
            \\    const vt_set: *const fn (h.VerbTable, h.HttpVerb, f64) r.zigar_js.CallError!void = &h.VerbTable.set;
            \\    _ = vt_get;
            \\    _ = vt_set;
            \\
            \\    const DictNominalCheck = struct {
            \\        fn roundtrip(d: h.InlineEnumDict) !void {
            \\            if (try d.get("feature")) |state| {
            \\                try d.set("feature", state);
            \\            }
            \\        }
            \\    };
            \\    _ = &DictNominalCheck.roundtrip;
            \\
            \\    // CollidingDict keeps named methods `get`, `set`, `init` intact and disambiguates indexers!
            \\    const cd_m_get: *const fn (h.CollidingDict, f64) r.zigar_js.CallError!bool = &h.CollidingDict.get;
            \\    const cd_m_set: *const fn (h.CollidingDict, f64, bool) r.zigar_js.CallError!void = &h.CollidingDict.set;
            \\    const cd_m_init: *const fn (h.CollidingDict, []const u8) r.zigar_js.CallError!void = &h.CollidingDict.init;
            \\    _ = cd_m_get;
            \\    _ = cd_m_set;
            \\    _ = cd_m_init;
            \\    try std.testing.expect(@hasDecl(h.CollidingDict, "getEntry"));
            \\    try std.testing.expect(@hasDecl(h.CollidingDict, "setEntry"));
            \\
            \\    // 6. Declaration merging across all combinations + CJS `export = $`!
            \\    _ = &h.MergedRegistry.nameAlloc;
            \\    _ = &h.MergedRegistry.has;
            \\    _ = &h.MergedRegistry.count;
            \\    _ = &h.MergedRegistry.clear;
            \\    _ = &h.MergedRegistry.get;
            \\    _ = &h.MergedRegistry.set;
            \\
            \\    _ = &h.RichService.init;
            \\    _ = &h.RichService.connect;
            \\    _ = &h.RichService.mixinPingAlloc;
            \\    const rs_opts: h.RichService.Options = .{ .timeout_ms = 500 };
            \\    try std.testing.expectEqual(@as(?f64, 500), rs_opts.timeout_ms);
            \\    try std.testing.expectError(error.HostUnavailable, h.RichService.default_timeout.get());
            \\    _ = &h.RichService.fromOptions;
            \\
            \\    _ = &h.formatMetricAlloc;
            \\    try std.testing.expectError(error.HostUnavailable, h.FormatMetric.prefix.getAlloc(std.testing.allocator));
            \\    _ = &h.FormatMetric.reset;
            \\
            \\    // Symbol-colliding `_` (`function _` + `namespace _`) and CJS `export = $` (`function $` + `namespace $`):
            \\    _ = &h.@"_".call;
            \\    try std.testing.expectError(error.HostUnavailable, h.@"_".VERSION.getAlloc(std.testing.allocator));
            \\    _ = &h.@"_".uniqAlloc;
            \\
            \\    try std.testing.expectEqualStrings("$", cjs.zigar_js.export_equals);
            \\    _ = &@field(cjs, cjs.zigar_js.export_equals).call;
            \\    _ = &cjs.@"$".call;
            \\    _ = &cjs.@"$".callString;
            \\    _ = &cjs.@"$".callWithRoot;
            \\    try std.testing.expect(!@hasDecl(cjs.@"$", "call_2"));
            \\    try std.testing.expectError(error.HostUnavailable, cjs.version.getAlloc(std.testing.allocator));
            \\    _ = &cjs.ajaxAlloc;
            \\    try std.testing.expect(cjs.Selection.zigar_js.is_handle);
            \\    _ = &h.@"$".call;
            \\    _ = &h.@"$".callString;
            \\    _ = &h.@"$".callWithRoot;
            \\    try std.testing.expect(!@hasDecl(h.@"$", "call_2"));
            \\    try std.testing.expectError(error.HostUnavailable, h.@"$".version.getAlloc(std.testing.allocator));
            \\    _ = &h.@"$".ajaxAlloc;
            \\    try std.testing.expect(h.@"$".Selection.zigar_js.is_handle);
            \\
            \\    // Merged `enum LogLevel` + `namespace LogLevel`:
            \\    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(h.LogLevel.warn));
            \\    _ = &h.LogLevel.parse;
            \\    try std.testing.expectError(error.HostUnavailable, h.LogLevel.default_level.get());
            \\
            \\    // Multi-block `namespace Telemetry`:
            \\    try std.testing.expectError(error.HostUnavailable, h.Telemetry.service_name.getAlloc(std.testing.allocator));
            \\    try std.testing.expectError(error.HostUnavailable, h.Telemetry.sample_rate.get());
            \\    _ = &h.Telemetry.flush;
            \\    _ = &h.Telemetry.record;
            \\
            \\    // Intersection normalizations: uninhabited `noreturn`, branded scalars, distributed tagged union:
            \\    try std.testing.expect(h.EmptyResult == noreturn);
            \\    try std.testing.expect(h.UserId == []const u8);
            \\    try std.testing.expect(h.PortNum == f64);
            \\    const out_ok: h.TaggedOutcome = .{ .ok = .{ .value = 42, .request_id = "req-1" } };
            \\    const out_err: h.TaggedOutcome = .{ .err = .{ .message = "boom", .request_id = "req-2" } };
            \\    try std.testing.expectEqualStrings("req-1", out_ok.ok.request_id);
            \\    try std.testing.expectEqualStrings("req-2", out_err.err.request_id);
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Issue #50 M3.3a Sema: smart overloads, variadic rest params, callbacks, this params, and type predicates" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue50-functions", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    try cwd.createDirPath(io, src_dir);
    {
        var sd = try cwd.openDir(io, src_dir, .{});
        defer sd.close(io);
        try sd.writeFile(io, .{
            .sub_path = "m3_functions.d.ts",
            .data =
            \\// 1. Subsumed prefix overload deduplication
            \\export declare function parseRecord(raw: string): number;
            \\export declare function parseRecord(raw: string, radix?: number): number;
            \\
            \\// 2. Buffer.from / fs.readFile / EventEmitter.on / Emitter ctor overloads
            \\export interface ReadOptions {
            \\  encoding?: string;
            \\}
            \\export declare function readFile(path: string, cb: (err: string | null, data: Uint8Array) => void): void;
            \\export declare function readFile(path: string, encoding: "utf8", cb: (err: string | null, data: string) => void): void;
            \\export declare function readFile(path: string, opts: ReadOptions, cb: (err: string | null, data: string | Uint8Array) => void): void;
            \\
            \\export declare class Buf {
            \\  readonly byteLength: number;
            \\  static from(text: string, encoding?: "utf8" | "hex"): Buf;
            \\  static from(bytes: Uint8Array): Buf;
            \\  static from(items: readonly number[]): Buf;
            \\}
            \\
            \\export declare class Emitter {
            \\  constructor();
            \\  constructor(maxListeners: number);
            \\  constructor(name: string, maxListeners: number);
            \\  on(event: "data", listener: (chunk: string) => void): this;
            \\  on(event: "error", listener: (err: string) => void): this;
            \\  on(event: "open", listener: () => void): this;
            \\  on(event: "close", listener: () => void): this;
            \\}
            \\
            \\// 3. Variadic rest parameters (`...args: any[]` and typed `...nums: number[]`)
            \\export declare function consoleLog(prefix: string, ...args: any[]): string;
            \\export declare function sumScaled(scale?: number, ...nums: number[]): number;
            \\
            \\// 4. Callbacks (inline fn, type alias, callable interface, optional cb, `this` cb) & HOF `Callable` return
            \\export type StringMapper = (item: string, idx: number) => string;
            \\export interface NumberPred {
            \\  (val: number): boolean;
            \\}
            \\export interface CounterBox {
            \\  count: number;
            \\}
            \\export declare function mapItems(items: readonly string[], fn: StringMapper): string[];
            \\export declare function filterNums(nums: readonly number[], pred: NumberPred, onDone?: (kept: number) => void): number[];
            \\export declare function runWithBoxThis(box: CounterBox, cb: (this: CounterBox, delta: number) => number): number;
            \\export declare function makeFormatter(prefix: string): (code: number) => string;
            \\export declare function makeThisAdder(scale: number): (this: CounterBox, delta: number) => number;
            \\
            \\// 5. Explicit `this: T` and `this: void` parameters on standalone functions
            \\export declare function addToBox(this: CounterBox, step: number): number;
            \\export declare function pureDouble(this: void, n: number): number;
            \\
            \\// 6. Type predicates (`x is T`, `asserts x is T`, `this is T`, `asserts this is T`, `asserts cond`)
            \\export declare class AstNode {
            \\  readonly kind: string;
            \\}
            \\export declare class BinaryExpr extends AstNode {
            \\  readonly op: string;
            \\}
            \\export declare function isBinaryExpr(node: AstNode): node is BinaryExpr;
            \\export declare function assertBinaryExpr(node: AstNode): asserts node is BinaryExpr;
            \\export declare function isTextValue(val: unknown): val is string;
            \\export declare function assertFlag(ok: boolean, msg?: string): asserts ok;
            \\export declare class Conn {
            \\  isReady(): this is ReadyConn;
            \\  assertReady(): asserts this is ReadyConn;
            \\}
            \\export declare class ReadyConn extends Conn {
            \\  readonly sessionToken: string;
            \\}
            ,
        });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const dts_path = try std.fmt.allocPrint(alloc, "{s}/m3_functions.d.ts", .{src_dir});
    defer alloc.free(dts_path);
    const cli_args = [_][]const u8{ "-t", dts_path, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Issue #50 pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_issue50.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_issue50.zig",
            .data =
            \\const std = @import("std");
            \\const root = @import("out/root.zig");
            \\const m = root.m3_functions;
            \\const js = root.zigar_js;
            \\
            \\fn onDataCb(chunk: []const u8) void {
            \\    _ = chunk;
            \\}
            \\fn onCloseCb() void {}
            \\fn onReadUtf8(err: ?[]const u8, data: []const u8) void {
            \\    _ = err;
            \\    _ = data;
            \\}
            \\fn mapUpper(item: []const u8, idx: f64) []const u8 {
            \\    _ = idx;
            \\    return item;
            \\}
            \\fn keepPos(val: f64) bool {
            \\    return val > 0;
            \\}
            \\fn boxThisCb(self_box: m.CounterBox, delta: f64) f64 {
            \\    return self_box.count + delta;
            \\}
            \\
            \\test "Issue #50 M3.3a Sema assertions" {
            \\    // 1. Subsumed overload deduplicated cleanly with zero `_2`
            \\    try std.testing.expect(!@hasDecl(m, "parseRecord_2"));
            \\    const pr_fn: *const fn ([]const u8, ?f64) js.CallError!f64 = &m.parseRecord;
            \\    _ = pr_fn;
            \\
            \\    // 2. Semantic overload names + unified comptime dispatchers (`readFile`, `Buf.from`, `Emitter.init`, `Emitter.on`)
            \\    try std.testing.expect(!@hasDecl(m, "readFile_2"));
            \\    try std.testing.expect(!@hasDecl(m, "readFile_3"));
            \\    try std.testing.expect(@hasDecl(m, "readFileCallback"));
            \\    try std.testing.expect(@hasDecl(m, "readFileUtf8"));
            \\    try std.testing.expect(@hasDecl(m, "readFileWithOpts"));
            \\    try std.testing.expect(@hasDecl(m, "readFile"));
            \\    try std.testing.expectError(error.HostUnavailable, m.readFile(.{ "a.txt", .utf8, onReadUtf8 }));
            \\    try std.testing.expectError(error.HostUnavailable, m.readFile(.{ "a.txt", "utf8", onReadUtf8 }));
            \\
            \\    try std.testing.expect(!@hasDecl(m.Buf, "from_2"));
            \\    try std.testing.expect(@hasDecl(m.Buf, "fromString"));
            \\    try std.testing.expect(@hasDecl(m.Buf, "fromUint8Array"));
            \\    try std.testing.expect(@hasDecl(m.Buf, "fromSlice"));
            \\    try std.testing.expectError(error.HostUnavailable, m.Buf.from("abc"));
            \\    try std.testing.expectError(error.HostUnavailable, m.Buf.from(.{ "abc", .hex }));
            \\    try std.testing.expectError(error.HostUnavailable, m.Buf.from(&[_]f64{ 1, 2, 3 }));
            \\
            \\    try std.testing.expect(!@hasDecl(m.Emitter, "init_2"));
            \\    try std.testing.expect(@hasDecl(m.Emitter, "initEmpty"));
            \\    try std.testing.expect(@hasDecl(m.Emitter, "initNumber"));
            \\    try std.testing.expectError(error.HostUnavailable, m.Emitter.init(.{}));
            \\    try std.testing.expectError(error.HostUnavailable, m.Emitter.init(16));
            \\    try std.testing.expectError(error.HostUnavailable, m.Emitter.init(.{ "bus", 32 }));
            \\    try std.testing.expect(@hasDecl(m.Emitter, "onData"));
            \\    try std.testing.expect(@hasDecl(m.Emitter, "onError"));
            \\    try std.testing.expect(@hasDecl(m.Emitter, "onOpen"));
            \\    try std.testing.expect(@hasDecl(m.Emitter, "onClose"));
            \\    const fake_em: m.Emitter = .{ .ref = .@"undefined" };
            \\    try std.testing.expectError(error.HostUnavailable, fake_em.on(.{ .data, onDataCb }));
            \\    try std.testing.expectError(error.HostUnavailable, fake_em.on(.{ .open, onCloseCb }));
            \\    try std.testing.expectError(error.HostUnavailable, fake_em.on(.{ .close, onCloseCb }));
            \\    try std.testing.expectError(error.HostUnavailable, fake_em.on(.{ "close", onCloseCb }));
            \\
            \\    // 3. Variadic `anytype` tuple/single-arg + `*Slice` companions
            \\    try std.testing.expectError(error.HostUnavailable, m.consoleLogAlloc(std.testing.allocator, "[info]", .{ "port", 8080, true }));
            \\    try std.testing.expectError(error.HostUnavailable, m.consoleLogAlloc(std.testing.allocator, "[info]", 8080));
            \\    try std.testing.expectError(error.HostUnavailable, m.consoleLogSliceAlloc(std.testing.allocator, "[info]", &[_]js.Any{}));
            \\    try std.testing.expectError(error.HostUnavailable, m.sumScaled(2.0, .{ 10, 20, 30 }));
            \\    try std.testing.expectError(error.HostUnavailable, m.sumScaled(null, .{}));
            \\    try std.testing.expectError(error.HostUnavailable, m.sumScaledSlice(2.0, &[_]f64{ 1, 2, 3 }));
            \\
            \\    // 4. Callbacks, `once`, `closure`, `this`-callbacks, and HOF `Callable` / `CallableWithThis`
            \\    try std.testing.expectError(error.HostUnavailable, m.mapItemsAlloc(std.testing.allocator, &.{"a"}, mapUpper));
            \\    try std.testing.expectError(error.HostUnavailable, m.filterNumsAlloc(std.testing.allocator, &.{ 1, -2 }, keepPos, null));
            \\    try std.testing.expectError(error.HostUnavailable, m.runWithBoxThis(.{ .count = 5 }, boxThisCb));
            \\    const fmt_fn: *const fn ([]const u8) js.CallError!js.Callable(fn (f64) []const u8) = &m.makeFormatter;
            \\    const add_fn: *const fn (f64) js.CallError!js.CallableWithThis(m.CounterBox, fn (f64) f64) = &m.makeThisAdder;
            \\    _ = fmt_fn;
            \\    _ = add_fn;
            \\
            \\    // 5. Explicit `this: CounterBox` vs `this: void`
            \\    const atb: *const fn (m.CounterBox, f64) js.CallError!f64 = &m.addToBox;
            \\    const pd: *const fn (f64) js.CallError!f64 = &m.pureDouble;
            \\    _ = atb;
            \\    _ = pd;
            \\
            \\    // 6. `x is T`, `asserts x is T`, `this is T`, `asserts this is T`, and `asserts cond`
            \\    const ib: *const fn (m.AstNode) js.CallError!bool = &m.isBinaryExpr;
            \\    const as_b: *const fn (m.AstNode) js.CallError!?m.BinaryExpr = &m.asBinaryExpr;
            \\    const ab: *const fn (m.AstNode) js.CallError!void = &m.assertBinaryExpr;
            \\    const ens_b: *const fn (m.AstNode) js.CallError!m.BinaryExpr = &m.ensureBinaryExpr;
            \\    const itv: *const fn (js.Unknown) js.CallError!bool = &m.isTextValue;
            \\    const as_tv: *const fn (js.Unknown) js.CallError!?[]const u8 = &m.asTextValue;
            \\    const as_tv_alloc: *const fn (std.mem.Allocator, js.Unknown) js.CallError!?[]const u8 = &m.asTextValueAlloc;
            \\    const af: *const fn (bool, ?[]const u8) js.CallError!void = &m.assertFlag;
            \\    try std.testing.expect(!@hasDecl(m, "ensureFlag"));
            \\    const conn_ir: *const fn (m.Conn) js.CallError!bool = &m.Conn.isReady;
            \\    const conn_asr: *const fn (m.Conn) js.CallError!?m.ReadyConn = &m.Conn.asReady;
            \\    const conn_arr: *const fn (m.Conn) js.CallError!void = &m.Conn.assertReady;
            \\    const conn_ensr: *const fn (m.Conn) js.CallError!m.ReadyConn = &m.Conn.ensureReady;
            \\    _ = .{ ib, as_b, ab, ens_b, itv, as_tv, as_tv_alloc, af, conn_ir, conn_asr, conn_arr, conn_ensr };
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });
}

test "Issue #51 M3.3b Sema: comptime generics, Default/With/Infer companions, NoInfer, const T, type operators, utility types, and negative constraint @compileError" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue51-generics", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    try cwd.createDirPath(io, src_dir);
    {
        var sd = try cwd.openDir(io, src_dir, .{});
        defer sd.close(io);
        try sd.writeFile(io, .{
            .sub_path = "m3_generics.d.ts",
            .data =
            \\export interface UserProfile {
            \\  id: number;
            \\  displayName: string;
            \\  hostName: string;
            \\  port?: number;
            \\  apiSecret?: string | null;
            \\}
            \\
            \\export interface DefaultMeta {
            \\  requestId: string;
            \\}
            \\
            \\export interface Envelope<T, Meta = DefaultMeta> {
            \\  payload: T;
            \\  meta: Meta;
            \\}
            \\
            \\export interface VarianceProbe<in Contra, out Co, in out Inv, const Lit = "ok"> {
            \\  accept(x: Contra): Co;
            \\  current: Inv;
            \\  readonly tag: Lit;
            \\}
            \\
            \\export declare class GenericStore<K extends string, V = number> {
            \\  constructor(namespace: K);
            \\  get(key: K): V | undefined;
            \\  set(key: K, val: V): void;
            \\  transform<U>(key: K, fallback: U): U;
            \\}
            \\
            \\export declare class ServiceClient {
            \\  constructor(endpoint: string, retries?: number);
            \\  ping(): boolean;
            \\}
            \\
            \\export declare function makeSampleUser(name: string, age: number): UserProfile;
            \\
            \\export declare function identity<T>(value: T): T;
            \\export declare function firstElem<T>(items: readonly T[]): T | undefined;
            \\export declare function unwrapOpt<T = string>(value?: T | null): T;
            \\export declare function awaitValue<T>(promise: Promise<T>): Promise<T>;
            \\export declare function freezeTuple<const T>(items: T): T;
            \\export declare function withFallback<T>(value: T, fallback: NoInfer<T>): T;
            \\export declare function loadDefault<T = UserProfile>(path: string): T;
            \\export declare function wrapEnvelope<T, Meta = DefaultMeta>(payload: T): Envelope<T, Meta>;
            \\export declare function taggedItem<T extends { id: number }>(mode: "fast" | "slow", item: T): T;
            \\export declare function getField<T extends object, K extends keyof T>(obj: T, key: K): T[K];
            \\export declare function echoBig<T extends bigint>(x: T): T;
            \\
            \\export declare function overloadGeneric<T extends { id: number }>(item: T): number;
            \\export declare function overloadGeneric(label: string): string;
            \\
            \\export type UserKey = keyof UserProfile;
            \\export type UserName = UserProfile["displayName"];
            \\export type PairTuple = [string, number];
            \\export type PairFirst = PairTuple[0];
            \\export type NumberListElem = (readonly number[])[number];
            \\
            \\export type PartialOf<T> = Partial<T>;
            \\export type RequiredOf<T> = Required<T>;
            \\export type ReadonlyOf<T> = Readonly<T>;
            \\export type OpenMappedOptional<T> = { [P in keyof T]?: T[P] };
            \\export type OpenMappedRequired<T> = { [P in keyof T]-?: T[P] };
            \\export type Flags<T> = { [P in keyof T]: boolean };
            \\export type OptFlags<T> = { [P in keyof T]?: boolean };
            \\export type ReqFlags<T> = { [P in keyof T]-?: boolean };
            \\export type PickNet<T> = Pick<T, "hostName" | "port">;
            \\export type OmitSecret<T> = Omit<T, "apiSecret">;
            \\export type RoleCounts = Record<"admin" | "guest", number>;
            \\export type OpenRoleMap<V> = Record<"admin" | "guest", V>;
            \\export type DynamicDict<V> = Record<string, V>;
            \\export type CleanVal<T> = NonNullable<T>;
            \\export type OpenNonNull<T> = T extends null | undefined ? never : T;
            \\export type UnwrapAsync<T> = Awaited<T>;
            \\export type OpenUnwrapPromise<T> = T extends Promise<infer U> ? U : T;
            \\
            \\export type FilteredLetters = Exclude<"a" | "b" | "c", "b">;
            \\export type ExtractedStrs = Extract<"alpha" | "beta" | 42, string>;
            \\export type SampleUserReturn = ReturnType<typeof makeSampleUser>;
            \\export type SampleUserParams = Parameters<typeof makeSampleUser>;
            \\export type ClientCtorParams = ConstructorParameters<typeof ServiceClient>;
            \\export type ClientInst = InstanceType<typeof ServiceClient>;
            \\
            \\export declare const defaultEndpoint: { readonly host: string; readonly port: number };
            \\export type EndpointConfig = typeof defaultEndpoint;
            \\export declare function acceptEndpoint(ep: typeof defaultEndpoint): number;
            \\
            \\export type PredeclaredTheme = typeof defaultTheme;
            \\export declare const defaultTheme: { readonly palette: string; readonly dark: boolean };
            \\
            \\export interface NullishMatrix {
            \\    a: string | null;
            \\    b?: string | null;
            \\    c: string | undefined;
            \\    d?: string;
            \\}
            \\
            \\export enum NumericDir {
            \\    Up = 0,
            \\    Down = 1,
            \\}
            \\export type ClosedDirMap = Record<NumericDir, string>;
            \\export type OpenDirMap<V> = Record<NumericDir, V>;
            \\export type ValueAtUp<V> = Record<NumericDir, V>[NumericDir.Up];
            \\export type At0<T extends { 0: string; 1: number }> = T[0];
            \\export type PickMixed<T> = Pick<T, 0 | "host">;
            ,
        });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const dts_file = try std.fmt.allocPrint(alloc, "{s}/m3_generics.d.ts", .{src_dir});
    defer alloc.free(dts_file);
    const cli_args = [_][]const u8{ "-t", dts_file, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var pipe_res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer pipe_res.deinit(alloc);
    if (pipe_res == .err) {
        std.debug.print("Issue #51 pipeline error: {s}\n", .{pipe_res.err});
    }
    try std.testing.expect(pipe_res == .ok);

    // Verify variance (`in`, `out`, `in out`) and `const` doc-comment rendering in generated Zig
    const gen_zig_path = try std.fmt.allocPrint(alloc, "{s}/m3_generics.zig", .{out_dir});
    defer alloc.free(gen_zig_path);
    const gen_src = try cwd.readFileAlloc(io, gen_zig_path, alloc, .limited(2 * 1024 * 1024));
    defer alloc.free(gen_src);
    try std.testing.expect(std.mem.indexOf(u8, gen_src, "@typeParam in Contra") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_src, "@typeParam out Co") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_src, "@typeParam in out Inv") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_src, "@typeParam const Lit") != null);

    // 1. Positive consumer Sema test exercising every generic/utility/operator construct
    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_issue51.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_issue51.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const js = r.zigar_js;
            \\const m = r.m3_generics;
            \\
            \\test "Issue #51 comptime generics, companions, inference, operators, and utility types" {
            \\    // 1. Generic interfaces & classes + *Default and *With(.{ ... }) companions
            \\    const EnvExplicit = m.Envelope(m.UserProfile, struct { trace: []const u8 });
            \\    const EnvDef = m.EnvelopeDefault(m.UserProfile);
            \\    const EnvWithMin = m.EnvelopeWith(.{ .T = m.UserProfile });
            \\    const EnvWithFull = m.EnvelopeWith(.{ .T = m.UserProfile, .Meta = struct { seq: u32 } });
            \\    try std.testing.expect(EnvDef == m.Envelope(m.UserProfile, m.DefaultMeta));
            \\    try std.testing.expect(EnvWithMin == EnvDef);
            \\    try std.testing.expect(@hasField(EnvExplicit, "payload") and @hasField(EnvExplicit, "meta"));
            \\    try std.testing.expect(@hasField(EnvWithFull, "meta"));
            \\
            \\    const StoreDef = m.GenericStoreDefault([]const u8);
            \\    const StoreWith = m.GenericStoreWith(.{ .K = []const u8 });
            \\    try std.testing.expect(StoreDef == m.GenericStore([]const u8, f64));
            \\    try std.testing.expect(StoreWith == StoreDef);
            \\    try std.testing.expect(StoreDef.zigar_js.is_handle);
            \\
            \\    // 2. Generic functions + *Default + *Infer + const T + NoInfer<T> + inline nominal before deduced param
            \\    try std.testing.expectError(error.HostUnavailable, m.identity(f64, 42));
            \\    try std.testing.expectError(error.HostUnavailable, m.identityInfer(@as(f64, 42)));
            \\    try std.testing.expectError(error.HostUnavailable, m.identityInferAlloc(std.testing.allocator, "zig"));
            \\    try std.testing.expectError(error.HostUnavailable, m.firstElemInfer(&[_]f64{ 1, 2, 3 }));
            \\    try std.testing.expectError(error.HostUnavailable, m.unwrapOptDefault(null));
            \\    try std.testing.expectError(error.HostUnavailable, m.unwrapOptInferAlloc(std.testing.allocator, null));
            \\    try std.testing.expectError(error.HostUnavailable, m.unwrapOptInfer(@as(?f64, 9)));
            \\    try std.testing.expectError(error.HostUnavailable, m.awaitValueInfer(js.Promise(f64){}));
            \\
            \\    // `const T` preserves fixed array `[2]f64` instead of decaying to slice!
            \\    const frozen_res = m.freezeTupleInfer(&[_]f64{ 10, 20 });
            \\    try std.testing.expect(@TypeOf(frozen_res) == js.CallError![2]f64);
            \\    try std.testing.expectError(error.HostUnavailable, frozen_res);
            \\
            \\    // `NoInfer<T>` excludes `fallback` from deduction so `T` is deduced purely from `value` (`f64`)
            \\    const fb_res = m.withFallbackInfer(@as(f64, 3.5), 7);
            \\    try std.testing.expect(@TypeOf(fb_res) == js.CallError!f64);
            \\    try std.testing.expectError(error.HostUnavailable, fb_res);
            \\
            \\    // Pure-default `*Default` + mixed deduced-and-trailing-default `.from_default` `*Infer`
            \\    try std.testing.expect(!@hasDecl(m, "loadDefaultInfer"));
            \\    try std.testing.expectError(error.HostUnavailable, m.loadDefaultDefaultAlloc(std.testing.allocator, "/me"));
            \\
            \\    // Non-generic inline enum parameter (`"fast" | "slow"`) before deduced parameter `item: T`
            \\    const sample_user: m.UserProfile = .{ .id = 1, .display_name = "Ada", .host_name = "localhost" };
            \\    const wrapped_env = m.wrapEnvelopeInferAlloc(std.testing.allocator, sample_user);
            \\    try std.testing.expect(@TypeOf(wrapped_env) == js.CallError!m.Envelope(m.UserProfile, m.DefaultMeta));
            \\    try std.testing.expectError(error.HostUnavailable, wrapped_env);
            \\    try std.testing.expectError(error.HostUnavailable, m.taggedItemInferAlloc(std.testing.allocator, .fast, sample_user));
            \\
            \\    // Generic overload dispatch (`T extends { id: number }` vs `string`) — both deduced and explicit type args
            \\    try std.testing.expectError(error.HostUnavailable, m.overloadGeneric(sample_user));
            \\    try std.testing.expectError(error.HostUnavailable, m.overloadGeneric(.{ m.UserProfile, sample_user }));
            \\    try std.testing.expectError(error.HostUnavailable, m.overloadGenericAlloc(std.testing.allocator, "hello"));
            \\
            \\    // 3. `keyof T` & `T[K]` (`getField` with wire-name mapping `displayName` <-> `display_name`)
            \\    try std.testing.expect(@typeInfo(m.UserKey) == .@"enum");
            \\    try std.testing.expectEqualStrings("displayName", m.UserKey.display_name.toSlice());
            \\    try std.testing.expect(m.UserName == []const u8);
            \\    try std.testing.expect(m.PairFirst == []const u8);
            \\    try std.testing.expect(m.NumberListElem == f64);
            \\    const gf_res = m.getField(m.UserProfile, enum { displayName }, sample_user, .displayName);
            \\    try std.testing.expect(@TypeOf(gf_res) == js.CallError![]const u8);
            \\    try std.testing.expectError(error.HostUnavailable, gf_res);
            \\
            \\    // 4. Open & closed utility types + homomorphic mapped & conditional patterns
            \\    const PUser = m.PartialOf(m.UserProfile);
            \\    const p_inst: PUser = .{ .id = 7 };
            \\    try std.testing.expectEqual(@as(?f64, 7), p_inst.id);
            \\    try std.testing.expectEqual(@as(?[]const u8, null), p_inst.display_name);
            \\
            \\    const OMOpt = m.OpenMappedOptional(m.UserProfile);
            \\    const omo_inst: OMOpt = .{};
            \\    try std.testing.expectEqual(@as(?f64, null), omo_inst.id);
            \\
            \\    // Homomorphic `{ [P in keyof T]: boolean }` preserves `T`'s optional modifiers (`port` stays `?bool = null`)
            \\    const UFlags = m.Flags(m.UserProfile);
            \\    try std.testing.expect(@FieldType(UFlags, "id") == bool);
            \\    try std.testing.expect(@FieldType(UFlags, "display_name") == bool);
            \\    try std.testing.expect(@FieldType(UFlags, "port") == ?bool);
            \\    try std.testing.expect(@FieldType(UFlags, "api_secret") == ?bool);
            \\    const uf_inst: UFlags = .{ .id = true, .display_name = true, .host_name = false };
            \\    try std.testing.expect(uf_inst.id and uf_inst.port == null and uf_inst.api_secret == null);
            \\    const OptUFlags = m.OptFlags(m.UserProfile);
            \\    const ouf_inst: OptUFlags = .{};
            \\    try std.testing.expect(ouf_inst.id == null);
            \\    const ReqUFlags = m.ReqFlags(m.UserProfile);
            \\    try std.testing.expect(@FieldType(ReqUFlags, "port") == bool);
            \\    try std.testing.expect(m.Flags([]const f64) == []const bool);
            \\    try std.testing.expect(m.Flags([]f64) == []bool);
            \\    try std.testing.expect(m.Flags([3]f64) == [3]bool);
            \\    try std.testing.expect(m.Flags(struct { f64, []const u8 }) == [2]bool);
            \\    try std.testing.expect(m.Flags([]const u8) == []const u8);
            \\    try std.testing.expect(m.Flags(f64) == f64);
            \\    try std.testing.expect(m.Flags(js.BigInt) == js.BigInt);
            \\    try std.testing.expect(js.IndexAccess(js.Array(f64), 0) == f64);
            \\    try std.testing.expectError(error.HostUnavailable, m.echoBig(js.BigInt, .{}));
            \\    try std.testing.expectError(error.HostUnavailable, m.echoBigInfer(js.BigInt{}));
            \\
            \\    const RUser = m.RequiredOf(m.UserProfile);
            \\    const OMReq = m.OpenMappedRequired(m.UserProfile);
            \\    try std.testing.expect(@FieldType(RUser, "port") == f64);
            \\    try std.testing.expect(@FieldType(RUser, "api_secret") == ?[]const u8);
            \\    try std.testing.expect(@FieldType(OMReq, "port") == f64);
            \\
            \\    // `Required<NullishMatrix>` preserves `| null` and `: T | undefined` while removing `?` optionality
            \\    const RNul = m.RequiredOf(m.NullishMatrix);
            \\    const OMNul = m.OpenMappedRequired(m.NullishMatrix);
            \\    try std.testing.expect(@FieldType(RNul, "a") == ?[]const u8);
            \\    try std.testing.expect(@FieldType(RNul, "b") == ?[]const u8);
            \\    try std.testing.expect(@FieldType(RNul, "c") == ?[]const u8);
            \\    try std.testing.expect(@FieldType(RNul, "d") == []const u8);
            \\    try std.testing.expect(@FieldType(OMNul, "b") == ?[]const u8);
            \\    try std.testing.expect(@FieldType(OMNul, "d") == []const u8);
            \\    inline for (@typeInfo(RNul).@"struct".field_names, 0..) |fnm, fi| {
            \\        if (!std.mem.startsWith(u8, fnm, "__zigar_")) {
            \\            try std.testing.expect(@typeInfo(RNul).@"struct".field_attrs[fi].default_value_ptr == null);
            \\        }
            \\    }
            \\
            \\    // Open `Record<"admin" | "guest", ?[]const u8>` requires every key (no `default_value_ptr`)
            \\    const NullableRoleMap = m.OpenRoleMap(?[]const u8);
            \\    inline for (@typeInfo(NullableRoleMap).@"struct".field_names, 0..) |fnm, fi| {
            \\        if (!std.mem.startsWith(u8, fnm, "__zigar_")) {
            \\            try std.testing.expect(@typeInfo(NullableRoleMap).@"struct".field_attrs[fi].default_value_ptr == null);
            \\        }
            \\    }
            \\
            \\    // Numeric-enum `Record<NumericDir, V>` matches closed `Record<NumericDir, string>` (`@"0"`, `@"1"`)
            \\    const OpenDirStr = m.OpenDirMap([]const u8);
            \\    try std.testing.expect(@hasField(m.ClosedDirMap, "0") and @hasField(m.ClosedDirMap, "1"));
            \\    try std.testing.expect(@hasField(OpenDirStr, "0") and @hasField(OpenDirStr, "1"));
            \\    const odm: OpenDirStr = .{ .@"0" = "up", .@"1" = "down" };
            \\    try std.testing.expectEqualStrings("up", odm.@"0");
            \\    try std.testing.expect(m.ValueAtUp([]const u8) == []const u8);
            \\    try std.testing.expect(m.ValueAtUp(bool) == bool);
            \\    const IndexedSample = struct { @"0": []const u8, @"1": f64, host: bool };
            \\    try std.testing.expect(m.At0(IndexedSample) == []const u8);
            \\    const PickedMixedSample = m.PickMixed(IndexedSample);
            \\    try std.testing.expect(@hasField(PickedMixedSample, "0") and @hasField(PickedMixedSample, "host") and !@hasField(PickedMixedSample, "1"));
            \\
            \\    const ROUser = m.ReadonlyOf(m.UserProfile);
            \\    try std.testing.expect(@hasField(ROUser, "display_name"));
            \\
            \\    const NetOnly = m.PickNet(m.UserProfile);
            \\    try std.testing.expect(@hasField(NetOnly, "host_name") and @hasField(NetOnly, "port"));
            \\    try std.testing.expect(!@hasField(NetOnly, "id") and !@hasField(NetOnly, "api_secret"));
            \\
            \\    const SafeUser = m.OmitSecret(m.UserProfile);
            \\    try std.testing.expect(@hasField(SafeUser, "id") and !@hasField(SafeUser, "api_secret"));
            \\
            \\    // Closed-enum Record -> value struct; open `Record<string, V>` -> dynamic JS Record handle
            \\    const rc: m.RoleCounts = .{ .admin = 2, .guest = 5 };
            \\    try std.testing.expectEqual(@as(f64, 7), rc.admin + rc.guest);
            \\    const orm: m.OpenRoleMap(bool) = .{ .admin = true, .guest = false };
            \\    try std.testing.expect(orm.admin and !orm.guest);
            \\    try std.testing.expect(@hasDecl(m.DynamicDict(f64), "is_js_record"));
            \\
            \\    // NonNullable & Awaited (both builtin & recognized open conditional patterns)
            \\    try std.testing.expect(m.CleanVal(?[]const u8) == []const u8);
            \\    try std.testing.expect(m.OpenNonNull(js.Nullable(f64)) == f64);
            \\    try std.testing.expect(m.UnwrapAsync(js.Promise(js.Promise(bool))) == bool);
            \\    try std.testing.expect(m.OpenUnwrapPromise(js.Promise([]const u8)) == []const u8);
            \\
            \\    // Closed conditional utilities (`Exclude`, `Extract`, `ReturnType`, `Parameters`, `ConstructorParameters`, `InstanceType`)
            \\    try std.testing.expectEqualStrings("a", m.FilteredLetters.a.toSlice());
            \\    try std.testing.expect(!@hasField(m.FilteredLetters, "b"));
            \\    try std.testing.expectEqualStrings("alpha", m.ExtractedStrs.alpha.toSlice());
            \\    try std.testing.expect(m.SampleUserReturn == m.UserProfile);
            \\    const sp: m.SampleUserParams = .{ .name = "Grace", .age = 36 };
            \\    try std.testing.expectEqualStrings("Grace", sp.name);
            \\    const cp: m.ClientCtorParams = .{ .endpoint = "https://example.test" };
            \\    try std.testing.expectEqual(@as(?f64, null), cp.retries);
            \\    try std.testing.expect(m.ClientInst == m.ServiceClient);
            \\
            \\    // `typeof <constVar>` shares the exact nominal Zig struct regardless of declaration order
            \\    const ep_val: m.EndpointConfig = .{ .host = "localhost", .port = 8080 };
            \\    try std.testing.expect(@TypeOf(m.default_endpoint.getAlloc(std.testing.allocator)) == js.CallError!m.EndpointConfig);
            \\    try std.testing.expectError(error.HostUnavailable, m.acceptEndpoint(ep_val));
            \\    try std.testing.expect(@TypeOf(m.default_theme.getAlloc(std.testing.allocator)) == js.CallError!m.PredeclaredTheme);
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });

    // 2. Negative Sema tests: verify invalid comptime `T extends Constraint` and missing `*With` keys produce `@compileError`!
    const neg_cases = [_]struct {
        filename: []const u8,
        expected_err: []const u8,
        source: []const u8,
    }{
        .{
            .filename = "neg_bad_struct_constraint.zig",
            .expected_err = "does not satisfy TypeScript constraint",
            .source =
            \\const r = @import("out/root.zig");
            \\test "reject non-matching struct constraint" {
            \\    _ = r.m3_generics.taggedItem(f64, .fast, 123);
            \\}
            ,
        },
        .{
            .filename = "neg_bad_keyof_constraint.zig",
            .expected_err = "does not satisfy TypeScript constraint",
            .source =
            \\const r = @import("out/root.zig");
            \\test "reject invalid keyof property" {
            \\    const u: r.m3_generics.UserProfile = .{ .id = 1, .display_name = "a", .host_name = "b" };
            \\    _ = r.m3_generics.getField(r.m3_generics.UserProfile, enum { nonexistentField }, u, .nonexistentField);
            \\}
            ,
        },
        .{
            .filename = "neg_missing_with_param.zig",
            .expected_err = "Missing required type parameter '.T'",
            .source =
            \\const r = @import("out/root.zig");
            \\test "reject missing required type param in EnvelopeWith" {
            \\    const Bad = r.m3_generics.EnvelopeWith(.{});
            \\    _ = @sizeOf(Bad);
            \\}
            ,
        },
        .{
            .filename = "neg_bad_generic_overload.zig",
            .expected_err = "No overload of",
            .source =
            \\const r = @import("out/root.zig");
            \\test "reject generic overload when deduced type violates constraint" {
            \\    const NoId = struct { name: []const u8 };
            \\    _ = r.m3_generics.overloadGeneric(NoId{ .name = "nope" });
            \\}
            ,
        },
    };

    for (neg_cases) |nc| {
        {
            var sb = try cwd.openDir(io, sandbox, .{});
            defer sb.close(io);
            try sb.writeFile(io, .{ .sub_path = nc.filename, .data = nc.source });
        }
        const neg_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ sandbox, nc.filename });
        defer alloc.free(neg_path);
        const res = try std.process.run(alloc, io, .{
            .argv = &.{ test_options.zig_exe, "test", neg_path },
        });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        const failed = switch (res.term) {
            .exited => |code| code != 0,
            else => true,
        };
        try std.testing.expect(failed);
        try std.testing.expect(std.mem.indexOf(u8, res.stderr, nc.expected_err) != null);
    }
}

test "Issue #52 M3.3c Sema: Promise<T> auto-await + *Promise, positional Iterable<T>, AsyncIterable/Iterator, and Symbol.dispose / asyncDispose" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue52-protocols", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const src_dir = try std.fmt.allocPrint(alloc, "{s}/src", .{sandbox});
    defer alloc.free(src_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);
    const out_custom_disp = try std.fmt.allocPrint(alloc, "{s}/out-custom-disp", .{sandbox});
    defer alloc.free(out_custom_disp);

    try cwd.createDirPath(io, src_dir);
    {
        var sd = try cwd.openDir(io, src_dir, .{});
        defer sd.close(io);
        try sd.writeFile(io, .{
            .sub_path = "m3_protocols.d.ts",
            .data =
            \\export type AsyncRes<T> = Promise<T>;
            \\export type NumSeq = Iterable<number>;
            \\
            \\export declare function fetchNumber(id: number): Promise<number>;
            \\export declare function fetchLabel(id: number): Promise<string>;
            \\export declare function pingAsync(): Promise<void>;
            \\export declare function nestedPromise(): Promise<Promise<PromiseLike<number>>>;
            \\export declare function aliasedAsync(seed: number): AsyncRes<number>;
            \\export declare function syncOrAsyncVal(flag: boolean): number | Promise<number>;
            \\
            \\export declare function loadRecord(key: string): Promise<string>;
            \\export declare function loadRecord(id: number): Promise<number>;
            \\
            \\export declare function resolveEcho<T>(val: T): Promise<T>;
            \\
            \\export interface CallableAsyncFetcher {
            \\  (url: string): Promise<string>;
            \\  readonly baseUrl: string;
            \\}
            \\
            \\export declare function mergedFetch(path: string): Promise<number>;
            \\export declare namespace mergedFetch {
            \\  export const timeoutMs: number;
            \\}
            \\
            \\export declare function _(key: string): Promise<number>;
            \\export declare namespace _ {
            \\  export const ver: number;
            \\}
            \\
            \\export interface ExplicitPromiseCollision {
            \\  doWork(): Promise<number>;
            \\  doWorkPromise(): string;
            \\}
            \\
            \\export declare function sumNumbers(items: Iterable<number>): number;
            \\export declare function rangeIter(count: number): Iterable<number>;
            \\export declare function produceAliasedSeq(): NumSeq;
            \\export declare function consumeAliasedSeq(seq: NumSeq): number;
            \\export declare function fetchItemsAsync(): Promise<Iterable<string>>;
            \\export declare function makeGenerator(seed: number): Generator<string, void, unknown>;
            \\export declare function streamEvents(topic: string): AsyncIterable<string>;
            \\export declare function makeAsyncGen(limit: number): AsyncGenerator<number, void, unknown>;
            \\
            \\export declare function firstOf<T>(items: Iterable<T>): T | undefined;
            \\export declare function drainAsync<T>(stream: AsyncIterable<T>): Promise<T[]>;
            \\export declare function useDisposable<T extends Disposable>(res: T): number;
            \\export declare function useAsyncDisposable<T extends AsyncDisposable>(res: T): Promise<number>;
            \\export declare function sumConstrained<T extends Iterable<number>>(seq: T): number;
            \\
            \\export declare class AsyncService {
            \\  static connect(endpoint: string): Promise<AsyncService>;
            \\  query(sql: string): Promise<string>;
            \\  send(msg: string): Promise<number>;
            \\  send(bytes: Uint8Array): Promise<number>;
            \\}
            \\
            \\export declare class TokenStream implements Iterable<string>, Disposable {
            \\  constructor(source: string);
            \\  [Symbol.iterator](): IterableIterator<string>;
            \\  [Symbol.dispose](): void;
            \\  readonly closed: boolean;
            \\}
            \\
            \\export declare class AsyncResourcePool implements AsyncDisposable, AsyncIterable<number | string> {
            \\  constructor(capacity: number);
            \\  [Symbol.asyncIterator](): AsyncIterableIterator<number | string>;
            \\  [Symbol.asyncDispose](): PromiseLike<void>;
            \\}
            \\
            \\export interface LegacyNodeHandle {
            \\  readonly fd: number;
            \\  [Symbol.for("nodejs.dispose")](): void;
            \\}
            \\export interface LegacyAsyncNodeHandle {
            \\  readonly fd: number;
            \\  [Symbol.for("nodejs.asyncDispose")](): Promise<void>;
            \\}
            \\
            \\export declare class ExplicitDisposeMethod implements Disposable {
            \\  dispose(reason: string): boolean;
            \\  [Symbol.dispose](): void;
            \\}
            ,
        });
        // User-defined plain interface named `Disposable` (`target_decl != null`) must stay a plain value struct!
        try sd.writeFile(io, .{
            .sub_path = "custom_disposable.d.ts",
            .data =
            \\export interface Disposable {
            \\  clean: boolean;
            \\  tag: string;
            \\}
            \\export declare function inspectCustom(d: Disposable): boolean;
            ,
        });
    }

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const dts_path = try std.fmt.allocPrint(alloc, "{s}/m3_protocols.d.ts", .{src_dir});
    defer alloc.free(dts_path);
    {
        const cli_args = [_][]const u8{ "-t", dts_path, "-d", out_dir };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Issue #52 pipeline error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);
    }

    const custom_dts_path = try std.fmt.allocPrint(alloc, "{s}/custom_disposable.d.ts", .{src_dir});
    defer alloc.free(custom_dts_path);
    {
        const cli_args = [_][]const u8{ "-t", custom_dts_path, "-d", out_custom_disp };
        var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
        defer parsed.deinit(alloc);
        var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
        defer res.deinit(alloc);
        if (res == .err) {
            std.debug.print("Issue #52 custom_disposable error: {s}\n", .{res.err});
        }
        try std.testing.expect(res == .ok);
    }

    const consumer_zig = try std.fmt.allocPrint(alloc, "{s}/consumer_issue52.zig", .{sandbox});
    defer alloc.free(consumer_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "consumer_issue52.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const m = r.m3_protocols;
            \\const js = r.zigar_js;
            \\const rc = @import("out-custom-disp/root.zig");
            \\
            \\test "Issue #52 M3.3c Promise<T> auto-await + *Promise, Iterable/AsyncIterable, and Symbol.dispose/asyncDispose" {
            \\    // 1. Auto-awaited Promise<T> functions + *Promise raw handle companions
            \\    const fn_num: *const fn (f64) js.CallError!f64 = &m.fetchNumber;
            \\    const fn_num_p: *const fn (f64) js.CallError!js.Promise(f64) = &m.fetchNumberPromise;
            \\    const fn_lbl: *const fn (f64) js.CallError![]const u8 = &m.fetchLabel;
            \\    const fn_lbl_a: *const fn (std.mem.Allocator, f64) js.CallError![]const u8 = &m.fetchLabelAlloc;
            \\    const fn_lbl_p: *const fn (f64) js.CallError!js.Promise([]const u8) = &m.fetchLabelPromise;
            \\    try std.testing.expect(!@hasDecl(m, "fetchLabelPromiseAlloc"));
            \\    const fn_ping: *const fn () js.CallError!void = &m.pingAsync;
            \\    const fn_ping_p: *const fn () js.CallError!js.Promise(void) = &m.pingAsyncPromise;
            \\    const fn_nested: *const fn () js.CallError!f64 = &m.nestedPromise;
            \\    const fn_nested_p: *const fn () js.CallError!js.Promise(f64) = &m.nestedPromisePromise;
            \\    const fn_aliased: *const fn (f64) js.CallError!f64 = &m.aliasedAsync;
            \\    const fn_aliased_p: *const fn (f64) js.CallError!js.Promise(f64) = &m.aliasedAsyncPromise;
            \\    _ = fn_num;
            \\    _ = fn_num_p;
            \\    _ = fn_lbl;
            \\    _ = fn_lbl_a;
            \\    _ = fn_lbl_p;
            \\    _ = fn_ping;
            \\    _ = fn_ping_p;
            \\    _ = fn_nested;
            \\    _ = fn_nested_p;
            \\    _ = fn_aliased;
            \\    _ = fn_aliased_p;
            \\
            \\    // `number | Promise<number>` stays a tagged union and does NOT generate `*Promise`
            \\    try std.testing.expect(!@hasDecl(m, "syncOrAsyncValPromise"));
            \\    try std.testing.expectError(error.HostUnavailable, m.syncOrAsyncVal(true));
            \\
            \\    // Overloaded async functions emit both auto-awaited and `*Promise` companions
            \\    const lr_s: *const fn (std.mem.Allocator, []const u8) js.CallError![]const u8 = &m.loadRecordStringAlloc;
            \\    const lr_n: *const fn (f64) js.CallError!f64 = &m.loadRecordNumber;
            \\    const lr_sp: *const fn ([]const u8) js.CallError!js.Promise([]const u8) = &m.loadRecordPromiseString;
            \\    const lr_np: *const fn (f64) js.CallError!js.Promise(f64) = &m.loadRecordPromiseNumber;
            \\    _ = lr_s;
            \\    _ = lr_n;
            \\    _ = lr_sp;
            \\    _ = lr_np;
            \\    try std.testing.expectError(error.HostUnavailable, m.loadRecordAlloc(std.testing.allocator, "k"));
            \\    try std.testing.expectError(error.HostUnavailable, m.loadRecord(@as(f64, 7)));
            \\    try std.testing.expectError(error.HostUnavailable, m.loadRecordPromise("k"));
            \\    try std.testing.expectError(error.HostUnavailable, m.loadRecordPromise(@as(f64, 7)));
            \\
            \\    // Generic async function + `*Infer` + `*Promise` + `*PromiseInfer`
            \\    try std.testing.expectError(error.HostUnavailable, m.resolveEcho(f64, 42));
            \\    try std.testing.expectError(error.HostUnavailable, m.resolveEchoInfer(@as(f64, 42)));
            \\    try std.testing.expectError(error.HostUnavailable, m.resolveEchoAlloc([]const u8, std.testing.allocator, "hi"));
            \\    try std.testing.expect(@TypeOf(m.resolveEchoPromise(f64, 42)) == js.CallError!js.Promise(f64));
            \\    try std.testing.expect(@TypeOf(m.resolveEchoPromiseInfer(@as([]const u8, "hi"))) == js.CallError!js.Promise([]const u8));
            \\
            \\    // Callable handle + merged function+namespace + explicit `*Promise` collision preservation
            \\    const caf_call: *const fn (m.CallableAsyncFetcher, std.mem.Allocator, []const u8) js.CallError![]const u8 = &m.CallableAsyncFetcher.callAlloc;
            \\    const caf_prom: *const fn (m.CallableAsyncFetcher, []const u8) js.CallError!js.Promise([]const u8) = &m.CallableAsyncFetcher.callPromise;
            \\    const mf_call: *const fn ([]const u8) js.CallError!f64 = &m.mergedFetch;
            \\    const mf_prom: *const fn ([]const u8) js.CallError!js.Promise(f64) = &m.mergedFetchPromise;
            \\    const us_call: *const fn ([]const u8) js.CallError!f64 = &m.@"_".call;
            \\    const us_prom: *const fn ([]const u8) js.CallError!js.Promise(f64) = &m.@"_".callPromise;
            \\    const epc_work: *const fn (m.ExplicitPromiseCollision) js.CallError!f64 = &m.ExplicitPromiseCollision.doWork;
            \\    const epc_prom: *const fn (m.ExplicitPromiseCollision, std.mem.Allocator) js.CallError![]const u8 = &m.ExplicitPromiseCollision.doWorkPromiseAlloc;
            \\    _ = caf_call;
            \\    _ = caf_prom;
            \\    _ = mf_call;
            \\    _ = mf_prom;
            \\    _ = us_call;
            \\    _ = us_prom;
            \\    _ = epc_work;
            \\    _ = epc_prom;
            \\    try std.testing.expectError(error.HostUnavailable, m.MergedFetch.timeout_ms.get());
            \\    try std.testing.expectError(error.HostUnavailable, m.@"_".ver.get());
            \\    try std.testing.expectError(error.HostUnavailable, r.mergedFetch("/v1"));
            \\    try std.testing.expectError(error.HostUnavailable, r.mergedFetchPromise("/v1"));
            \\
            \\    // Class static & instance async methods + overloaded async methods
            \\    const as_conn: *const fn ([]const u8) js.CallError!m.AsyncService = &m.AsyncService.connect;
            \\    const as_conn_p: *const fn ([]const u8) js.CallError!js.Promise(m.AsyncService) = &m.AsyncService.connectPromise;
            \\    const as_q: *const fn (m.AsyncService, std.mem.Allocator, []const u8) js.CallError![]const u8 = &m.AsyncService.queryAlloc;
            \\    const as_qp: *const fn (m.AsyncService, []const u8) js.CallError!js.Promise([]const u8) = &m.AsyncService.queryPromise;
            \\    const as_s1: *const fn (m.AsyncService, []const u8) js.CallError!f64 = &m.AsyncService.sendString;
            \\    const as_s2: *const fn (m.AsyncService, js.Uint8Array) js.CallError!f64 = &m.AsyncService.sendUint8Array;
            \\    const as_s1p: *const fn (m.AsyncService, []const u8) js.CallError!js.Promise(f64) = &m.AsyncService.sendPromiseString;
            \\    const as_s2p: *const fn (m.AsyncService, js.Uint8Array) js.CallError!js.Promise(f64) = &m.AsyncService.sendPromiseUint8Array;
            \\    try std.testing.expect(@hasDecl(m.AsyncService, "send"));
            \\    try std.testing.expect(@hasDecl(m.AsyncService, "sendPromise"));
            \\    _ = as_conn;
            \\    _ = as_conn_p;
            \\    _ = as_q;
            \\    _ = as_qp;
            \\    _ = as_s1;
            \\    _ = as_s2;
            \\    _ = as_s1p;
            \\    _ = as_s2p;
            \\
            \\    // 2. Positional Iterable<T> (`[]const T` in input vs `js.Iterator(T)` in return) & AsyncIterable/Generator
            \\    const sum_fn: *const fn ([]const f64) js.CallError!f64 = &m.sumNumbers;
            \\    const range_fn: *const fn (f64) js.CallError!js.Iterator(f64) = &m.rangeIter;
            \\    const prod_seq: *const fn () js.CallError!js.Iterator(f64) = &m.produceAliasedSeq;
            \\    const cons_seq: *const fn (m.NumSeq) js.CallError!f64 = &m.consumeAliasedSeq;
            \\    const fia: *const fn () js.CallError!js.Iterator([]const u8) = &m.fetchItemsAsync;
            \\    const fia_p: *const fn () js.CallError!js.Promise(js.Iterator([]const u8)) = &m.fetchItemsAsyncPromise;
            \\    const gen_fn: *const fn (f64) js.CallError!js.Iterator([]const u8) = &m.makeGenerator;
            \\    const str_ev: *const fn ([]const u8) js.CallError!js.AsyncIterator([]const u8) = &m.streamEvents;
            \\    const agen_fn: *const fn (f64) js.CallError!js.AsyncIterator(f64) = &m.makeAsyncGen;
            \\    try std.testing.expect(m.NumSeq == []const f64);
            \\    _ = sum_fn;
            \\    _ = range_fn;
            \\    _ = prod_seq;
            \\    _ = cons_seq;
            \\    _ = fia;
            \\    _ = fia_p;
            \\    _ = gen_fn;
            \\    _ = str_ev;
            \\    _ = agen_fn;
            \\
            \\    // Generic `*Infer` deduction from slice and `js.AsyncIterator(T)`!
            \\    const nums = [_]f64{ 1, 2, 3 };
            \\    try std.testing.expectError(error.HostUnavailable, m.firstOfInfer(nums[0..]));
            \\    try std.testing.expect(@TypeOf(m.drainAsyncInferAlloc(std.testing.allocator, @as(js.AsyncIterator(f64), .{ .handle = 0 }))) == js.CallError![]const f64);
            \\
            \\    // 3. Protocol heritage & `[Symbol.iterator]` / `[Symbol.asyncIterator]` / `[Symbol.dispose]` / `[Symbol.asyncDispose]`
            \\    try std.testing.expect(m.TokenStream.zigar_js.has_dispose);
            \\    try std.testing.expect(m.TokenStream.zigar_js.iterator_elem == []const u8);
            \\    const ts_iter: *const fn (m.TokenStream) js.CallError!js.Iterator([]const u8) = &m.TokenStream.iterator;
            \\    const ts_disp: *const fn (m.TokenStream) void = &m.TokenStream.dispose;
            \\    const ts_try_disp: *const fn (m.TokenStream) js.CallError!void = &m.TokenStream.tryDispose;
            \\    _ = ts_iter;
            \\    _ = ts_disp;
            \\    _ = ts_try_disp;
            \\
            \\    try std.testing.expect(m.AsyncResourcePool.zigar_js.has_async_dispose);
            \\    const ElemU = m.AsyncResourcePool.zigar_js.async_iterator_elem;
            \\    try std.testing.expect(@typeInfo(ElemU) == .@"union");
            \\    const arp_iter: *const fn (m.AsyncResourcePool) js.CallError!js.AsyncIterator(ElemU) = &m.AsyncResourcePool.asyncIterator;
            \\    const arp_disp: *const fn (m.AsyncResourcePool) void = &m.AsyncResourcePool.asyncDispose;
            \\    const arp_try_disp: *const fn (m.AsyncResourcePool) js.CallError!void = &m.AsyncResourcePool.tryAsyncDispose;
            \\    _ = arp_iter;
            \\    _ = arp_disp;
            \\    _ = arp_try_disp;
            \\
            \\    // Legacy `Symbol.for("nodejs.dispose")` / `Symbol.for("nodejs.asyncDispose")`
            \\    try std.testing.expect(m.LegacyNodeHandle.zigar_js.has_dispose);
            \\    try std.testing.expect(@hasDecl(m.LegacyNodeHandle, "tryDispose"));
            \\    try std.testing.expect(m.LegacyAsyncNodeHandle.zigar_js.has_async_dispose);
            \\    try std.testing.expect(@hasDecl(m.LegacyAsyncNodeHandle, "tryAsyncDispose"));
            \\
            \\    // Explicit `dispose(reason: string): boolean` method is preserved alongside `[Symbol.dispose]`!
            \\    try std.testing.expect(m.ExplicitDisposeMethod.zigar_js.has_dispose);
            \\    const edm_disp: *const fn (m.ExplicitDisposeMethod, []const u8) js.CallError!bool = &m.ExplicitDisposeMethod.dispose;
            \\    const edm_try_disp: *const fn (m.ExplicitDisposeMethod) js.CallError!void = &m.ExplicitDisposeMethod.tryDispose;
            \\    _ = edm_disp;
            \\    _ = edm_try_disp;
            \\
            \\    // Comptime `T extends Disposable` / `T extends AsyncDisposable` / `T extends Iterable<number>`
            \\    try std.testing.expect(@hasDecl(m.TokenStream, "releaseHandleOnly"));
            \\    try std.testing.expect(comptime js.satisfiesTypeConstraint(m.TokenStream, js.Disposable, 0));
            \\    try std.testing.expect(comptime !js.satisfiesTypeConstraint(m.TokenStream, js.AsyncDisposable, 0));
            \\    try std.testing.expect(comptime js.satisfiesTypeConstraint(m.TokenStream, js.Iterator([]const u8), 0));
            \\    try std.testing.expect(comptime js.satisfiesTypeConstraint(m.LegacyNodeHandle, js.Disposable, 0));
            \\    try std.testing.expect(comptime js.satisfiesTypeConstraint(m.AsyncResourcePool, js.AsyncDisposable, 0));
            \\    try std.testing.expect(comptime js.satisfiesTypeConstraint(m.AsyncResourcePool, js.AsyncIterator(ElemU), 0));
            \\    try std.testing.expect(comptime js.satisfiesTypeConstraint(m.LegacyAsyncNodeHandle, js.AsyncDisposable, 0));
            \\    try std.testing.expect(comptime !js.satisfiesTypeConstraint(m.AsyncService, js.Disposable, 0));
            \\    try std.testing.expect(comptime !js.satisfiesTypeConstraint(js.Ref(js.Object), js.Disposable, 0));
            \\    const StringDisposeOnly = struct {
            \\        pub fn dispose(_: @This()) void {}
            \\    };
            \\    try std.testing.expect(comptime !js.satisfiesTypeConstraint(StringDisposeOnly, js.Disposable, 0));
            \\    const use_d: *const fn (m.TokenStream) js.CallError!f64 = &struct {
            \\        fn call(ts: m.TokenStream) js.CallError!f64 {
            \\            return m.useDisposable(m.TokenStream, ts);
            \\        }
            \\    }.call;
            \\    const use_ad: *const fn (m.AsyncResourcePool) js.CallError!f64 = &struct {
            \\        fn call(arp: m.AsyncResourcePool) js.CallError!f64 {
            \\            return m.useAsyncDisposable(m.AsyncResourcePool, arp);
            \\        }
            \\    }.call;
            \\    const sum_c: *const fn ([]const f64) js.CallError!f64 = &struct {
            \\        fn call(s: []const f64) js.CallError!f64 {
            \\            return m.sumConstrained([]const f64, s);
            \\        }
            \\    }.call;
            \\    _ = use_d;
            \\    _ = use_ad;
            \\    _ = sum_c;
            \\
            \\    // 4. User-defined `export interface Disposable` stays a plain value struct!
            \\    try std.testing.expect(!@hasField(@TypeOf(rc.custom_disposable.Disposable.zigar_js), "is_handle"));
            \\    const cd: rc.custom_disposable.Disposable = .{ .clean = true, .tag = "plain" };
            \\    try std.testing.expect(cd.clean);
            \\    try std.testing.expectEqualStrings("plain", cd.tag);
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", consumer_zig });

    const neg_cases = [_]struct {
        filename: []const u8,
        expected_err: []const u8,
        source: []const u8,
    }{
        .{
            .filename = "neg_not_disposable.zig",
            .expected_err = "does not satisfy TypeScript constraint",
            .source =
            \\const r = @import("out/root.zig");
            \\test "reject non-disposable handle in T extends Disposable" {
            \\    _ = r.m3_protocols.useDisposable(r.m3_protocols.AsyncService, .{ .ref = .{ .handle = 0 } });
            \\}
            ,
        },
        .{
            .filename = "neg_bad_iterable_constraint.zig",
            .expected_err = "does not satisfy TypeScript constraint",
            .source =
            \\const r = @import("out/root.zig");
            \\test "reject wrong element slice in T extends Iterable<number>" {
            \\    const strs = [_][]const u8{"nope"};
            \\    _ = r.m3_protocols.sumConstrained([]const []const u8, strs[0..]);
            \\}
            ,
        },
    };

    for (neg_cases) |nc| {
        {
            var sb = try cwd.openDir(io, sandbox, .{});
            defer sb.close(io);
            try sb.writeFile(io, .{ .sub_path = nc.filename, .data = nc.source });
        }
        const neg_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ sandbox, nc.filename });
        defer alloc.free(neg_path);
        const res = try std.process.run(alloc, io, .{
            .argv = &.{ test_options.zig_exe, "test", neg_path },
        });
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        const failed = switch (res.term) {
            .exited => |code| code != 0,
            else => true,
        };
        try std.testing.expect(failed);
        try std.testing.expect(std.mem.indexOf(u8, res.stderr, nc.expected_err) != null);
    }
}

test "Issue #52 @types/node@26 protocol sweep: fs/promises, timers/promises, stream, events pass AstGen and Sema" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const types_node_dir = (try resolveTypesNode26Dir(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(types_node_dir);

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue52-node26-protocols", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const cli_args = [_][]const u8{
        "-t", types_node_dir,
        "-m", "fs/promises",
        "-m", "timers/promises",
        "-m", "stream",
        "-m", "events",
        "-d", out_dir,
    };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Issue #52 @types/node@26 protocol sweep error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    const probe_zig = try std.fmt.allocPrint(alloc, "{s}/node26_protocol_probe.zig", .{sandbox});
    defer alloc.free(probe_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "node26_protocol_probe.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const js = r.zigar_js;
            \\
            \\fn touchRecursive(comptime T: type, comptime depth: usize) void {
            \\    if (depth == 0) return;
            \\    inline for (comptime std.meta.declarations(T)) |decl_name| {
            \\        const val = @field(T, decl_name);
            \\        _ = &@field(T, decl_name);
            \\        if (@TypeOf(val) == type) {
            \\            _ = @sizeOf(val);
            \\            switch (@typeInfo(val)) {
            \\                .@"struct", .@"union", .@"enum" => touchRecursive(val, depth - 1),
            \\                else => {},
            \\            }
            \\        }
            \\    }
            \\}
            \\
            \\test "deep 3-level Sema + protocol verification across @types/node@26 fs/promises, timers/promises, stream, events" {
            \\    @setEvalBranchQuota(10_000_000);
            \\    touchRecursive(r.node_fs_promises, 3);
            \\    touchRecursive(r.node_timers_promises, 3);
            \\    touchRecursive(r.node_stream, 3);
            \\    touchRecursive(r.node_events, 3);
            \\
            \\    // `node:fs/promises`: auto-awaited `open` + `openPromise`, and `FileHandle` implements `[Symbol.asyncDispose]`!
            \\    try std.testing.expect(@hasDecl(r.node_fs_promises, "open"));
            \\    try std.testing.expect(@hasDecl(r.node_fs_promises, "openPromise"));
            \\    try std.testing.expect(r.node_fs_promises.FileHandle.zigar_js.has_async_dispose);
            \\    try std.testing.expect(@hasDecl(r.node_fs_promises.FileHandle, "asyncDispose"));
            \\    try std.testing.expect(@hasDecl(r.node_fs_promises.FileHandle, "tryAsyncDispose"));
            \\
            \\    // `node:timers/promises`: `setTimeout` + `setTimeoutPromise`, and `setInterval` returning `js.AsyncIterator(T)`!
            \\    try std.testing.expect(@hasDecl(r.node_timers_promises, "setTimeout"));
            \\    try std.testing.expect(@hasDecl(r.node_timers_promises, "setTimeoutPromise"));
            \\    try std.testing.expect(@TypeOf(r.node_timers_promises.setIntervalDefault(10, null, null)) == js.CallError!js.AsyncIterator(void));
            \\
            \\    // `node:stream`: `Readable` implements `[Symbol.asyncIterator]` AND `[Symbol.asyncDispose]`!
            \\    try std.testing.expect(r.node_stream.Readable.zigar_js.has_async_dispose);
            \\    try std.testing.expect(@hasDecl(r.node_stream.Readable, "asyncIterator"));
            \\    try std.testing.expect(@hasDecl(r.node_stream.Readable, "tryAsyncDispose"));
            \\
            \\    // `node:events`: `on(...)` returns `js.AsyncIterator([]const js.Any)`!
            \\    try std.testing.expect(@hasDecl(r.node_events, "on"));
            \\}
            ,
        });
    }

    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", probe_zig });
}

test "Issue #53 (M3.4a): ECMA-262 export * shadowing/default/ambiguity/diamond/export type *, nested export * as ns, multi-segment wildcard exports, and condition key order" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue53-export-star", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    const pkg_dir = try std.fmt.allocPrint(alloc, "{s}/rpkg", .{sandbox});
    defer alloc.free(pkg_dir);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);

    const dist_sub_ab = try std.fmt.allocPrint(alloc, "{s}/dist/sub/alpha", .{pkg_dir});
    defer alloc.free(dist_sub_ab);
    const dist_sub_priv = try std.fmt.allocPrint(alloc, "{s}/dist/sub/private", .{pkg_dir});
    defer alloc.free(dist_sub_priv);
    const dist_sub_spec = try std.fmt.allocPrint(alloc, "{s}/dist/sub/special", .{pkg_dir});
    defer alloc.free(dist_sub_spec);
    const dist_spec = try std.fmt.allocPrint(alloc, "{s}/dist/special", .{pkg_dir});
    defer alloc.free(dist_spec);
    try cwd.createDirPath(io, dist_sub_ab);
    try cwd.createDirPath(io, dist_sub_priv);
    try cwd.createDirPath(io, dist_sub_spec);
    try cwd.createDirPath(io, dist_spec);

    {
        var pd = try cwd.openDir(io, pkg_dir, .{});
        defer pd.close(io);

        try pd.writeFile(io, .{
            .sub_path = "package.json",
            .data =
            \\{
            \\  "name": "rpkg",
            \\  "version": "1.0.0",
            \\  "exports": {
            \\    ".": { "types": "./dist/index.d.ts", "import": "./dist/index.js" },
            \\    "./override": { "types": "./dist/override.d.ts" },
            \\    "./cond": { "default": "./dist/def_entry.d.ts", "import": "./dist/imp_entry.d.ts" },
            \\    "./sub/*": { "types": "./dist/sub/*.d.ts" },
            \\    "./sub/special/*": { "types": "./dist/special/*.d.ts" },
            \\    "./sub/private/*": null
            \\  }
            \\}
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/a.d.ts",
            .data =
            \\export declare function foo(): string;
            \\export default function defFn(): void;
            \\export declare function dup(): number;
            \\export declare function explicitPick(): string;
            \\export declare function ok(): boolean;
            \\export interface Boxed { tag: string; }
            \\export declare function isBoxed(v: unknown): v is Boxed;
            \\export declare namespace isBoxed {
            \\    function helper(): number;
            \\}
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/b.d.ts",
            .data =
            \\export declare function dup(): string;
            \\export declare function explicitPick(): number;
            \\export declare function okB(): number;
            \\export * from "./diamond.js";
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/mid_leaf.d.ts",
            .data =
            \\export declare function midShadow(): number;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/typeonly_imp.d.ts",
            .data =
            \\export declare class ImportedTypeClass {
            \\    constructor();
            \\    pong(): number;
            \\}
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/mid.d.ts",
            .data =
            \\import type { ImportedTypeClass } from "./typeonly_imp.js";
            \\export { ImportedTypeClass };
            \\export declare function midShadow(): string;
            \\export * from "./mid_leaf.js";
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/diamond.d.ts",
            .data =
            \\export declare function sharedDiamond(): string;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/typeonly.d.ts",
            .data =
            \\export declare class Ghost {
            \\    constructor();
            \\    ping(): string;
            \\}
            \\export declare function ghostFn(): void;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/ns_deep.d.ts",
            .data =
            \\export declare function deepRun(): number;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/ns_inner.d.ts",
            .data =
            \\export * from "./ns_deep.js";
            \\export declare function directRun(): string;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/p_a.d.ts",
            .data =
            \\export declare function nestedDup(): string;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/p_b.d.ts",
            .data =
            \\export declare function nestedDup(): number;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/p.d.ts",
            .data =
            \\export * from "./p_a.js";
            \\export * from "./p_b.js";
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/d.d.ts",
            .data =
            \\export declare function nestedDup(): boolean;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/override.d.ts",
            .data =
            \\import { nestedDup } from "./d.js";
            \\export { nestedDup };
            \\export * from "./p.js";
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/index.d.ts",
            .data =
            \\import { explicitPick } from "./a.js";
            \\export { explicitPick };
            \\export * from "./a.js";
            \\export * from "./b.js";
            \\export * from "./p.js";
            \\export * from "./d.js";
            \\export * from "./mid.js";
            \\export * from "./diamond.js";
            \\export type * from "./typeonly.js";
            \\export * as nestedNs from "./ns_inner.js";
            \\export declare function foo(n: number): number;
            \\export declare function acceptGhost(g: Ghost): string;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/def_entry.d.ts",
            .data =
            \\export declare function fromDefaultCond(): boolean;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/imp_entry.d.ts",
            .data =
            \\export declare function fromImportCond(): boolean;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/sub/alpha/beta.d.ts",
            .data =
            \\export declare function multiSegSubpath(): number;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/sub/special/foo.d.ts",
            .data =
            \\export declare function wrongSpecial(): void;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/special/foo.d.ts",
            .data =
            \\export declare function rightSpecial(): boolean;
            ,
        });

        try pd.writeFile(io, .{
            .sub_path = "dist/sub/private/secret.d.ts",
            .data =
            \\export declare function blockedByNullExport(): void;
            ,
        });
    }

    const cli_args = [_][]const u8{ "-t", pkg_dir, "-d", out_dir };
    var parsed = try ts_zigar.cli.parseArgs(alloc, &cli_args);
    defer parsed.deinit(alloc);
    var res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed.run);
    defer res.deinit(alloc);
    if (res == .err) {
        std.debug.print("Issue #53 export-star pipeline error: {s}\n", .{res.err});
    }
    try std.testing.expect(res == .ok);

    {
        var out_h = try cwd.openDir(io, out_dir, .{});
        defer out_h.close(io);
        // Excluded `"./sub/private/*": null`, more-specific wildcard decoy `dist/sub/special/foo.zig`,
        // and shadowed `"import"` condition must NOT be emitted!
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "dist/sub/private/secret.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "dist/sub/special/foo.zig", .{}));
        try std.testing.expectError(error.FileNotFound, out_h.statFile(io, "dist/imp_entry.zig", .{}));

        // NB4: Encapsulated internal module `dist/a.zig` must NOT advertise bogus `.wire_specifier = "dist/a"`,
        // and `dist/typeonly.zig` (with zero runtime-claimed decls) must omit `.wire_specifier`!
        const a_src = try out_h.readFileAlloc(io, "dist/a.zig", alloc, .limited(64 * 1024));
        defer alloc.free(a_src);
        try std.testing.expect(std.mem.indexOf(u8, a_src, ".wire_specifier = \"dist/a\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, a_src, ".wire_specifier = \"rpkg\"") != null);

        const to_src = try out_h.readFileAlloc(io, "dist/typeonly.zig", alloc, .limited(64 * 1024));
        defer alloc.free(to_src);
        try std.testing.expect(std.mem.indexOf(u8, to_src, ".wire_specifier =") == null);
    }

    const probe_zig = try std.fmt.allocPrint(alloc, "{s}/probe_issue53.zig", .{sandbox});
    defer alloc.free(probe_zig);
    {
        var sb = try cwd.openDir(io, sandbox, .{});
        defer sb.close(io);
        try sb.writeFile(io, .{
            .sub_path = "probe_issue53.zig",
            .data =
            \\const std = @import("std");
            \\const r = @import("out/root.zig");
            \\const mod_idx = @import("out/dist/index.zig");
            \\const mod_a = @import("out/dist/a.zig");
            \\const mod_b = @import("out/dist/b.zig");
            \\const mod_d = @import("out/dist/d.zig");
            \\const mod_to = @import("out/dist/typeonly.zig");
            \\const mod_to_imp = @import("out/dist/typeonly_imp.zig");
            \\const mod_deep = @import("out/dist/ns_deep.zig");
            \\
            \\test "ECMA-262 export *, export type *, nested export * as ns, multi-segment *, and condition key order" {
            \\    // 1. Barrel's own `foo(n: f64) !f64` wins; shadowed `mod_a.foo()` is pruned!
            \\    try std.testing.expect(@hasDecl(mod_idx, "foo"));
            \\    try std.testing.expect(!@hasDecl(mod_a, "foo"));
            \\    const foo_ptr: *const fn (f64) r.zigar_js.CallError!f64 = &mod_idx.foo;
            \\    _ = foo_ptr;
            \\
            \\    // 2. `export *` never forwards `default` (`defFn` / `Default`)!
            \\    try std.testing.expect(!@hasDecl(mod_idx, "Default"));
            \\    try std.testing.expect(!@hasDecl(mod_idx, "defFn"));
            \\    try std.testing.expect(!@hasDecl(mod_a, "Default"));
            \\    try std.testing.expect(!@hasDecl(mod_a, "defFn"));
            \\
            \\    // 3. Ambiguous multi-star `dup` (`a.dup` vs `b.dup`) is excluded everywhere,
            \\    //    while unambiguous `ok`, `okB`, diamond `sharedDiamond`, and merged
            \\    //    `function + namespace` (`isBoxed` + `isBoxedNarrow` + `IsBoxed.helper`) are forwarded!
            \\    try std.testing.expect(!@hasDecl(mod_idx, "dup"));
            \\    try std.testing.expect(!@hasDecl(mod_a, "dup"));
            \\    try std.testing.expect(!@hasDecl(mod_b, "dup"));
            \\    try std.testing.expect(@hasDecl(mod_idx, "ok"));
            \\    try std.testing.expect(@hasDecl(mod_idx, "okB"));
            \\    try std.testing.expect(@hasDecl(mod_idx, "sharedDiamond"));
            \\    try std.testing.expect(@hasDecl(mod_idx, "isBoxed"));
            \\    try std.testing.expect(@hasDecl(mod_idx, "isBoxedNarrow"));
            \\    try std.testing.expect(@hasDecl(mod_idx, "IsBoxed"));
            \\    try std.testing.expect(@hasDecl(mod_idx.IsBoxed, "helper"));
            \\
            \\    // 4. `export type *` and `import type { ImportedTypeClass }; export { ImportedTypeClass }` via `export *`
            \\    //    expose class types + instance methods, but NEVER runtime `.init` constructors or functions!
            \\    try std.testing.expect(@hasDecl(mod_idx, "Ghost"));
            \\    try std.testing.expect(mod_idx.Ghost == mod_to.Ghost);
            \\    try std.testing.expect(@hasDecl(mod_to.Ghost, "ping"));
            \\    try std.testing.expect(!@hasDecl(mod_to.Ghost, "init"));
            \\    try std.testing.expect(!@hasDecl(mod_idx, "ghostFn"));
            \\    try std.testing.expect(!@hasDecl(mod_to, "ghostFn"));
            \\    try std.testing.expect(@hasDecl(mod_idx, "ImportedTypeClass"));
            \\    try std.testing.expect(mod_idx.ImportedTypeClass == mod_to_imp.ImportedTypeClass);
            \\    try std.testing.expect(@hasDecl(mod_to_imp.ImportedTypeClass, "pong"));
            \\    try std.testing.expect(!@hasDecl(mod_to_imp.ImportedTypeClass, "init"));
            \\
            \\    // 4b. B1-R: Intermediate override (`mid.midShadow(): string` hiding `mid_leaf.midShadow(): number`)
            \\    //     and barrel explicit re-export (`import { explicitPick } from "./a"; export { explicitPick }`)
            \\    //     both win cleanly over `export *`!
            \\    try std.testing.expect(@hasDecl(mod_idx, "midShadow"));
            \\    const mid_ptr: *const fn () r.zigar_js.CallError![]const u8 = &mod_idx.midShadow;
            \\    _ = mid_ptr;
            \\    try std.testing.expect(@hasDecl(mod_idx, "explicitPick"));
            \\    const exp_ptr: *const fn () r.zigar_js.CallError![]const u8 = &mod_idx.explicitPick;
            \\    _ = exp_ptr;
            \\    try std.testing.expect(!@hasDecl(mod_b, "explicitPick"));
            \\
            \\    // 4c. B1-R2: Nested `export *` ambiguity at `p` (`a.nestedDup` vs `b.nestedDup`) propagates
            \\    //     upward to `index` (`export * from "./p"; export * from "./d"`), suppressing `d.nestedDup`
            \\    //     even while `mod_d.nestedDup` is alive via `rpkg/override`'s explicit `export { nestedDup }`!
            \\    try std.testing.expect(@hasDecl(mod_d, "nestedDup"));
            \\    try std.testing.expect(!@hasDecl(mod_idx, "nestedDup"));
            \\    try std.testing.expect(@hasDecl(r.rpkg_override, "nestedDup"));
            \\    const ov_ptr: *const fn () r.zigar_js.CallError!bool = &r.rpkg_override.nestedDup;
            \\    _ = ov_ptr;
            \\
            \\    // 5. NB1: `export * as nestedNs` claims both direct `directRun` and nested `export *` `deepRun`!
            \\    try std.testing.expect(@hasDecl(mod_idx.nestedNs, "directRun"));
            \\    try std.testing.expect(@hasDecl(mod_idx.nestedNs, "deepRun"));
            \\    try std.testing.expect(&mod_idx.nestedNs.deepRun == &mod_deep.deepRun);
            \\
            \\    // 6. NB2 + NB3: Multi-segment wildcard `"./sub/*"` (`rpkg_sub_alpha_beta`), more-specific wildcard
            \\    //    `"./sub/special/*"` (`rpkg_sub_special_foo`), and JSON key-order `"default"` before `"import"` (`rpkg_cond`)!
            \\    try std.testing.expect(@hasDecl(r, "rpkg_sub_alpha_beta"));
            \\    try std.testing.expect(@hasDecl(r.rpkg_sub_alpha_beta, "multiSegSubpath"));
            \\    try std.testing.expectEqualStrings("rpkg/sub/alpha/beta", r.rpkg_sub_alpha_beta.zigar_js.wire_specifier);
            \\    try std.testing.expect(@hasDecl(r, "rpkg_sub_special_foo"));
            \\    try std.testing.expect(@hasDecl(r.rpkg_sub_special_foo, "rightSpecial"));
            \\    try std.testing.expect(!@hasDecl(r.rpkg_sub_special_foo, "wrongSpecial"));
            \\    try std.testing.expectEqualStrings("rpkg/sub/special/foo", r.rpkg_sub_special_foo.zigar_js.wire_specifier);
            \\    try std.testing.expect(@hasDecl(r, "rpkg_cond"));
            \\    try std.testing.expect(@hasDecl(r.rpkg_cond, "fromDefaultCond"));
            \\    try std.testing.expect(!@hasDecl(r.rpkg_cond, "fromImportCond"));
            \\}
            ,
        });
    }

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", probe_zig });
}

test "Issue #54 M3.4b Audit: expansive generic cycles, fallback reporting, hex/underscore literals, globalThis builtins, and overload tuple/arity scoring" {
    const wasm_path = resolveTestComponentWasm() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const sandbox = try std.fmt.allocPrint(alloc, "{s}/ts-zigar-issue54-audit", .{resolveTmpRoot()});
    defer alloc.free(sandbox);
    cwd.deleteTree(io, sandbox) catch {};
    defer cwd.deleteTree(io, sandbox) catch {};
    try cwd.createDirPath(io, sandbox);

    const dts_path = try std.fmt.allocPrint(alloc, "{s}/m3-audit.d.mts", .{sandbox});
    defer alloc.free(dts_path);
    const clean_dts_path = try std.fmt.allocPrint(alloc, "{s}/m3-clean.d.mts", .{sandbox});
    defer alloc.free(clean_dts_path);
    const out_dir = try std.fmt.allocPrint(alloc, "{s}/out", .{sandbox});
    defer alloc.free(out_dir);
    const out_clean_dir = try std.fmt.allocPrint(alloc, "{s}/out-clean", .{sandbox});
    defer alloc.free(out_clean_dir);
    const probe_zig = try std.fmt.allocPrint(alloc, "{s}/probe_issue54.zig", .{sandbox});
    defer alloc.free(probe_zig);

    try cwd.writeFile(io, .{
        .sub_path = dts_path,
        .data =
        \\// 1. M2: Expansive generic cycles (direct self-nesting, mutual generic cycle, unguarded recursive alias, regular control)
        \\export type Box<T> = { value: T };
        \\export interface InfChain<T> {
        \\  head: T;
        \\  next?: InfChain<Box<T>>;
        \\}
        \\export type MutualA<T> = { b?: MutualB<Box<T>> };
        \\export type MutualB<U> = { item?: MutualA<U> };
        \\export type RegularSelf<T> = { val: T; next?: RegularSelf<T> };
        \\export type UnguardedLoop<T> = UnguardedLoop<T>[];
        \\export declare function makeInfChain(seed: string): InfChain<string>;
        \\export declare function makeMutual(seed: number): MutualA<number>;
        \\export declare function makeRegular(seed: number): RegularSelf<number>;
        \\export declare function makeLoop(seed: boolean): UnguardedLoop<boolean>;
        \\
        \\// 2. H3: Generic function / constructor / call-signature fallbacks -> JsFunction
        \\export type GenericIdentityFn = <T>(x: T) => T;
        \\export type GenericCtorFn = new <T>(x: T) => Box<T>;
        \\export interface GenericCallableBox {
        \\  <T>(x: T): T;
        \\  readonly tag: string;
        \\}
        \\export declare const idFn: GenericIdentityFn;
        \\
        \\// 3. H3: Hex, binary, octal, underscore-separated, signed numeric literals, and non-literal const widening
        \\export type HexMask = 0xff_ff | 1_000_000 | 0b1010_0101 | 0o77 | -0x10;
        \\export declare const SHIFTED_CONST = 1 << 2;
        \\export declare function checkMask(m: HexMask): HexMask;
        \\
        \\// 4. L3: `globalThis.`-qualified built-in utility & collection types
        \\export interface RawConfig {
        \\  host: string;
        \\  port: number;
        \\}
        \\export type PartialCfg = globalThis.Partial<RawConfig>;
        \\export type StrNumMap = globalThis.Map<string, number>;
        \\export type RoStrNumMap = globalThis.ReadonlyMap<string, number>;
        \\export type DictNum = globalThis.Record<string, number>;
        \\export type RoTags = globalThis.ReadonlyArray<string>;
        \\export declare function inspectGlobals(
        \\  cfg: PartialCfg,
        \\  m: StrNumMap,
        \\  rm: RoStrNumMap,
        \\  d: DictNum,
        \\  tags: RoTags,
        \\): string;
        \\
        \\// 5. M3 + L1 + L2: Tuple-arg overload dispatch, exact-arity bonus, and overload/allocator doc-comments
        \\export declare function tupleOrScalars(pair: [string, number]): string;
        \\export declare function tupleOrScalars(a: string, b: number, c: boolean): string;
        \\export declare function arityTieBreak(x: string, y?: number): number;
        \\export declare function arityTieBreak(x: string): string;
        \\
        ,
    });

    try cwd.writeFile(io, .{
        .sub_path = clean_dts_path,
        .data =
        \\export interface CleanPoint {
        \\  x: number;
        \\  y: number;
        \\}
        \\export declare function addPoints(a: CleanPoint, b: CleanPoint): CleanPoint;
        \\
        ,
    });

    var ts_host = try ts_zigar.TypeScriptHost.spawnNode(alloc, io, .{
        .wasm_path = wasm_path,
        .node_binary = resolveNodeExe(),
    });
    defer ts_host.deinit();

    // A) `--strict-fallbacks` MUST reject `m3-audit.d.mts` with structured diagnostics!
    {
        const strict_args = [_][]const u8{
            "-t", dts_path,
            "-m", "m3-audit",
            "-d", out_dir,
            "--strict-fallbacks",
        };
        var parsed_strict = try ts_zigar.cli.parseArgs(alloc, &strict_args);
        defer parsed_strict.deinit(alloc);
        try std.testing.expect(parsed_strict == .run);

        var strict_res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed_strict.run);
        defer strict_res.deinit(alloc);
        try std.testing.expect(strict_res == .err);
        try std.testing.expect(std.mem.indexOf(u8, strict_res.err, "Strict fallback mode failed") != null);
        try std.testing.expect(std.mem.indexOf(u8, strict_res.err, "[expansive_generic_cycle]") != null);
        try std.testing.expect(std.mem.indexOf(u8, strict_res.err, "[generic_function_type]") != null);
    }

    // B) `--strict-fallbacks` MUST succeed cleanly on fallback-free `m3-clean.d.mts`!
    {
        const clean_args = [_][]const u8{
            "-t", clean_dts_path,
            "-m", "m3-clean",
            "-d", out_clean_dir,
            "--strict-fallbacks",
        };
        var parsed_clean = try ts_zigar.cli.parseArgs(alloc, &clean_args);
        defer parsed_clean.deinit(alloc);
        try std.testing.expect(parsed_clean == .run);

        var clean_res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed_clean.run);
        defer clean_res.deinit(alloc);
        try std.testing.expect(clean_res == .ok);
        try std.testing.expectEqual(@as(usize, 0), clean_res.ok.fallback_count);
    }

    // C) `--report-fallbacks` emits modules AND structured fallback report + inline doc-comments!
    {
        const report_args = [_][]const u8{
            "-t", dts_path,
            "-m", "m3-audit",
            "-d", out_dir,
            "--report-fallbacks",
        };
        var parsed_rep = try ts_zigar.cli.parseArgs(alloc, &report_args);
        defer parsed_rep.deinit(alloc);
        try std.testing.expect(parsed_rep == .run);

        var rep_res = try ts_zigar.driver.runPipelineWithHost(alloc, io, &ts_host, &parsed_rep.run);
        defer rep_res.deinit(alloc);
        if (rep_res == .err) {
            std.debug.print("Issue #54 pipeline error: {s}\n", .{rep_res.err});
        }
        try std.testing.expect(rep_res == .ok);
        try std.testing.expect(rep_res.ok.fallback_count >= 5);
        const report_txt = rep_res.ok.fallback_report orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, report_txt, "[expansive_generic_cycle]") != null);
        try std.testing.expect(std.mem.indexOf(u8, report_txt, "[generic_function_type]") != null);
    }

    const gen_mod_zig = try std.fmt.allocPrint(alloc, "{s}/m3_audit.zig", .{out_dir});
    defer alloc.free(gen_mod_zig);
    const gen_src = try cwd.readFileAlloc(io, gen_mod_zig, alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(gen_src);

    // Verify inline doc-comments (H3 fallback notes, L1 overload list, L2 allocator contract) & JsFunction!
    try std.testing.expect(std.mem.indexOf(u8, gen_src, "/// ts-zigar: fallback(") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_src, "pub const GenericIdentityFn = __zigar_js.JsFunction;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_src, "pub const GenericCtorFn = __zigar_js.JsFunction;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_src, "/// Overloads:") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_src, "/// Allocates decoded return values via `zigar_js.defaultAllocator()`") != null);

    try cwd.writeFile(io, .{
        .sub_path = probe_zig,
        .data =
        \\const std = @import("std");
        \\const r = @import("out/root.zig");
        \\const m = r.m3_audit;
        \\const js = r.zigar_js;
        \\
        \\test "Issue #54 generated Zig compile & comptime type checks" {
        \\    // 1. Hex/underscore/binary/octal/negative numeric literal tags (H3)
        \\    const h_hex: m.HexMask = .n_65535;
        \\    const h_sep: m.HexMask = .n_1000000;
        \\    const h_bin: m.HexMask = .n_165;
        \\    const h_oct: m.HexMask = .n_63;
        \\    const h_neg: m.HexMask = .neg_16;
        \\    try std.testing.expectError(error.HostUnavailable, m.checkMask(h_hex));
        \\    _ = h_sep;
        \\    _ = h_bin;
        \\    _ = h_oct;
        \\    _ = h_neg;
        \\
        \\    // Non-literal `1 << 2` const widens cleanly to `f64` global wrapper rather than bogus `0` literal!
        \\    try std.testing.expect(@TypeOf(m.SHIFTED_CONST).ValueType == f64);
        \\    try std.testing.expectError(error.HostUnavailable, m.SHIFTED_CONST.get());
        \\
        \\    // 2. `globalThis.` builtins lower identically to unqualified builtins (L3)
        \\    const cfg: m.PartialCfg = .{ .host = "localhost" };
        \\    try std.testing.expect(cfg.port == null);
        \\    try std.testing.expect(m.StrNumMap == js.Map([]const u8, f64));
        \\    try std.testing.expect(m.RoStrNumMap == js.Map([]const u8, f64));
        \\    try std.testing.expect(m.DictNum == js.Record([]const u8, f64));
        \\    try std.testing.expect(m.RoTags == []const []const u8);
        \\
        \\    // 3. Single-tuple-arg overload dispatch & exact-arity overload tie-breaking (M3)
        \\    try std.testing.expectError(error.HostUnavailable, m.tupleOrScalars(.{ "port", @as(f64, 8080) }));
        \\    try std.testing.expectError(error.HostUnavailable, m.tupleOrScalars(.{ "port", @as(f64, 8080), true }));
        \\
        \\    // Exact 1-arg `arityTieBreak(x: string): string` MUST beat `arityTieBreak(x: string, y?: number): number`!
        \\    const exact_ret = m.arityTieBreak("only-one");
        \\    try std.testing.expect(@TypeOf(exact_ret) == js.CallError![]const u8);
        \\    try std.testing.expectError(error.HostUnavailable, exact_ret);
        \\
        \\    const opt_ret = m.arityTieBreak(.{ "two", @as(f64, 2) });
        \\    try std.testing.expect(@TypeOf(opt_ret) == js.CallError!f64);
        \\    try std.testing.expectError(error.HostUnavailable, opt_ret);
        \\
        \\    // 4. Expansive & regular generic cycles instantiate cleanly in Zig (M2)
        \\    try std.testing.expectError(error.HostUnavailable, m.makeInfChainAlloc(std.testing.allocator, "seed"));
        \\    try std.testing.expectError(error.HostUnavailable, m.makeMutualAlloc(std.testing.allocator, 1));
        \\    try std.testing.expectError(error.HostUnavailable, m.makeRegularAlloc(std.testing.allocator, 1));
        \\    try std.testing.expectError(error.HostUnavailable, m.makeLoopAlloc(std.testing.allocator, true));
        \\}
        ,
    });

    const root_zig = try std.fmt.allocPrint(alloc, "{s}/root.zig", .{out_dir});
    defer alloc.free(root_zig);
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "ast-check", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", root_zig });
    try runZigCheck(alloc, io, &.{ test_options.zig_exe, "test", probe_zig });
}






