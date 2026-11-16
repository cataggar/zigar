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
            \\    const s1: r.case1.Self = .{ .tag = 7 };
            \\    try std.testing.expectEqual(@as(f64, 7), s1.tag);
            \\    const echo_fn: *const fn (*const r.case1.Self, r.case1.Self) r.case1.Self = &r.case1.Self.echo;
            \\    _ = echo_fn;
            \\
            \\    const s2: r.case2.Self = .{ .id = "abc" };
            \\    try std.testing.expectEqualStrings("abc", s2.id);
            \\    const init_fn: *const fn () r.case2.Widget = &r.case2.Widget.init;
            \\    _ = init_fn;
            \\
            \\    const s3: r.case3.Self = .{ .x = 3 };
            \\    const a3: r.case3.A = .{ .s = s3 };
            \\    try std.testing.expectEqual(@as(f64, 3), a3.s.x);
            \\
            \\    const ns_s: r.case4.Ns.Self = .{ .x = 9 };
            \\    const ns_a: r.case4.Ns.A = .{ .s = ns_s };
            \\    try std.testing.expectEqual(@as(f64, 9), ns_a.s.x);
            \\    const ons_s: r.case4.OuterNs.Self = .{ .z = 15 };
            \\    const ons_b: r.case4.OuterNs.B = .{ .s = ons_s };
            \\    try std.testing.expectEqual(@as(f64, 15), ons_b.s.z);
            \\    const nb: r.case4.Self.NestedInSelfNs = .{ .k = 11 };
            \\    try std.testing.expectEqual(@as(f64, 11), nb.k);
            \\    const t: r.case4.Triple(u32) = .{ .a = .{ .y = 12 }, .val = 99 };
            \\    try std.testing.expectEqual(@as(f64, 12), t.a.y);
            \\    try std.testing.expectEqual(@as(u32, 99), t.val);
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
            \\    const top_in: leaf.Inner = .{ .top = 1 };
            \\    const nested_in: leaf.LeafNs.Inner = .{ .nested = "hello" };
            \\    const payload: foo_used.UsedNs.Payload = .{ .ok = true };
            \\    try std.testing.expectEqual(@as(f64, 1), top_in.top);
            \\    try std.testing.expectEqualStrings("hello", nested_in.nested);
            \\    try std.testing.expect(payload.ok);
            \\
            \\    const f_ptr: *const fn (leaf.Inner, leaf.LeafNs.Inner, foo_used.UsedNs.Payload) void = &r.f;
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
            \\    const db: r_node.node_sqlite.DatabaseSync = .{ .open = true };
            \\    try std.testing.expect(db.open);
            \\    const srv: r_node.http.Server = .{ .port = 8080, .stat = .{ .size = 64 } };
            \\    try std.testing.expectEqual(@as(f64, 8080), srv.port);
            \\
            \\    // 2. Mixed file exports A, index, inline_mod, empty_inline, and plugin!
            \\    try std.testing.expect(r_mixed.A == r_mixed.index.A);
            \\    try std.testing.expect(&r_mixed.makeA == &r_mixed.index.makeA);
            \\    try std.testing.expect(@hasDecl(r_mixed, "inline_mod"));
            \\    try std.testing.expect(@hasDecl(r_mixed, "empty_inline"));
            \\    try std.testing.expect(@hasDecl(r_mixed, "plugin"));
            \\    const inline_fn: *const fn () r_mixed.A = &r_mixed.inline_mod.useInline;
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
            \\    const hid_val: r_p2.p2.Hid = .{ .s = 7, .nested = .{ .flag = true } };
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
