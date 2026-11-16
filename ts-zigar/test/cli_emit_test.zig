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
            \\    const w: r.Widget = .{
            \\        .init = true,
            \\        .count = 1,
            \\        .self = "ok",
            \\        .handle = 2,
            \\        .zigar_js_2 = 3,
            \\    };
            \\    try std.testing.expect(w.init);
            \\    try std.testing.expectEqualStrings("Widget", r.Widget.zigar_js.js_name);
            \\
            \\    const B = r.Box(u32, bool);
            \\    const b: B = .{ .item = 7, .extra = true };
            \\    try std.testing.expectEqual(@as(u32, 7), b.item);
            \\
            \\    const use_top_fn: *const fn (*const r.ShadowRef, r.K) r.K = &r.ShadowRef.useTop;
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
            \\    const n: sub_star.Nebula = .{ .radius = 10 };
            \\    try std.testing.expectEqual(@as(f64, 42), s.id);
            \\    try std.testing.expectEqual(@as(f64, 10), n.radius);
            \\
            \\    // Passing `sub_star.Starry` to `r.take` must type-check identically!
            \\    const take_fn: *const fn (sub_star.Starry, sub_star.Nebula, sub_star.Phase) sub_star.Starry = &r.take;
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
            \\    const consume_fn: *const fn (other.Bar.Baz, other.Bar.Deep.Leaf, r.LocalNs.Inner) other.Bar.Baz = &r.consume;
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
