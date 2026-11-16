import { expect } from 'chai';
import { cpSync, existsSync, mkdirSync, rmSync } from 'fs';
import { writeFile } from 'fs/promises';
import 'mocha-skip-if';
import { dirname, join, resolve } from 'path';
import { fileURLToPath, pathToFileURL } from 'url';
import { runWit } from '../src/compilation.js';
import {
  getComponentHostRegistry,
  HostResourceTable,
  instantiateComponentHost,
  sliceMemoryU8,
  toUnsignedPtr,
  unpackComponent,
  wrapWasiImportsUnsigned,
} from '../src/component-host.js';
import { transpile } from '../src/transpilation.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../..');
const WORKTREE_CACHE_DIR = join(REPO_ROOT, '.cache');
const TMP_BASE = process.env.TMPDIR || join(WORKTREE_CACHE_DIR, 'tmp');
const TMP_ROOT = join(TMP_BASE, `component-host-test-${process.pid}`);
const LOCAL_CACHE_DIR = join(TMP_ROOT, 'zig-cache');
const GLOBAL_CACHE_DIR = process.env.ZIG_GLOBAL_CACHE_DIR || join(TMP_ROOT, 'zig-global-cache');
const XDG_CACHE_DIR = process.env.XDG_CACHE_HOME || join(TMP_ROOT, 'xdg-cache');
const BUILD_DIR = join(TMP_ROOT, 'build');
const ZIG_SRC_DIR = join(TMP_ROOT, 'zig-src');
const MODULE_OUT_DIR = join(TMP_ROOT, 'modules');

const RUNTIME_SRC_DIR = join(REPO_ROOT, 'zigar-runtime/src');
const WIT_ZIGAR_SRC_DIR = join(REPO_ROOT, 'wit-zigar/src');
const TS_ZIGAR_SRC_DIR = join(REPO_ROOT, 'ts-zigar/src');
const TS_WIT_PATH = join(REPO_ROOT, 'ts-zigar/wit/typescript.wit');
const COMPONENT_WASM_PATH = process.env.TS_ZIGAR_COMPONENT_WASM
  ? resolve(process.env.TS_ZIGAR_COMPONENT_WASM)
  : join(REPO_ROOT, 'ts-zigar/component/dist/typescript-compiler.component.wasm');

const WAZIG_CANDIDATES = [
  '/d/zigar-worktrees/.tools/bin/wazig',
  '/d/zig/wazig/bin/wazig',
];
const WAZIG_BIN = WAZIG_CANDIDATES.find((p) => existsSync(p)) || 'wazig';

const prevEnv = {
  ZIG_LOCAL_CACHE_DIR: process.env.ZIG_LOCAL_CACHE_DIR,
  ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR,
  XDG_CACHE_HOME: process.env.XDG_CACHE_HOME,
  TMPDIR: process.env.TMPDIR,
};

const ZIG_WASM_HOST_SOURCE = `const std = @import("std");
const ch = @import("wit_zigar/component_host.zig");
const ts = @import("generated_ts.zig");

pub const PipelineSummary = struct {
    compiler_version: []const u8,
    type_text: []const u8,
    symbol_doc: []const u8,
    exported_count: u32,
    emitted_files_count: u32,
    emitted_total_bytes: u32,
    found_big_dts: bool,
    transpiled_has_fn: bool,
    graph_modules_count: u32,
    diagnostic_code: u32,
    live_resources_after_drop: u32,
};

fn containsSubstr(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

pub fn invokeCompilerVersionViaCallbacks(
    allocator: std.mem.Allocator,
    callbacks: ch.ZigarCallbacks,
) ![]const u8 {
    var cb_backend = ch.ZigarCallbacksBackend.init(callbacks);
    var host = ch.ComponentHost.init(cb_backend.backend());
    const world = ts.bindHost(&host);
    return try world.compiler.compilerVersion(allocator);
}

pub fn runFullTypeScriptPipeline(
    allocator: std.mem.Allocator,
    instance_id: u32,
    record_count: u32,
) !PipelineSummary {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa_impl.deinit() == .leak) @panic("Zig GPA memory leak detected in WASM host!");
    }
    const scratch = gpa_impl.allocator();

    var ext_backend = ch.WasmExternBackend.init(instance_id);
    var host = ch.ComponentHost.init(ext_backend.backend());
    const world = ts.bindHost(&host);

    // 1. compiler-version
    const ver_tmp = try world.compiler.compilerVersion(scratch);
    defer ch.freeValue([]const u8, scratch, ver_tmp);
    const ver_out = try allocator.dupe(u8, ver_tmp);
    errdefer allocator.free(ver_out);

    // 2. VFS resource + bundled TypeScript 7.1 libs
    var vfs = try world.compiler.createVfs(scratch, true);
    defer vfs.deinit();

    const index_src =
        \\\\export interface User {
        \\\\  readonly id: number;
        \\\\  name: string;
        \\\\}
        \\\\
        \\\\/** Greets a user across WASM memories. */
        \\\\export function greet(u: User) {
        \\\\  return "hi " + u.name;
        \\\\}
        \\\\
    ;
    try vfs.writeFile(scratch, "/index.ts", index_src);

    // Generate a multi-megabyte TypeScript source file in WASM host memory
    // and lower it across into the Go component's separate WASM linear memory.
    var big_ts: std.ArrayList(u8) = .empty;
    defer big_ts.deinit(scratch);
    {
        var i: u32 = 0;
        while (i < record_count) : (i += 1) {
            var line_buf: [160]u8 = undefined;
            const line = try std.fmt.bufPrint(
                &line_buf,
                "export interface WasmBridgeRecord_{d:0>5} {{ readonly key_{d:0>5}: string; readonly count_{d:0>5}: number; }}\\n",
                .{ i, i, i },
            );
            try big_ts.appendSlice(scratch, line);
        }
    }
    try vfs.writeFile(scratch, "/big.ts", big_ts.items);

    const opts = ts.compiler.CompilerOptions{
        .target = .es2024,
        .module = .esnext,
        .module_resolution = .bundler,
        .strict = true,
        .exact_optional_property_types = false,
        .no_unchecked_indexed_access = false,
        .declaration = true,
        .emit_declaration_only = true,
        .allow_js = false,
        .skip_lib_check = true,
        .base_url = null,
        .type_roots = &.{},
        .types = &.{},
    };

    const prog_res = try world.compiler.createProgram(
        scratch,
        vfs.asBorrow(),
        &.{ "/index.ts", "/big.ts" },
        opts,
    );
    if (prog_res != .ok) {
        ch.freeValue(@TypeOf(prog_res), scratch, prog_res);
        return error.UnexpectedCreateProgramFailure;
    }
    var program = world.compiler.wrapProgram(prog_res.ok);
    defer program.deinit();

    // 3. Checker queries
    var checker = world.compiler.wrapChecker(try program.getChecker(scratch));
    defer checker.deinit();

    const greet_off: u32 = @intCast(std.mem.indexOf(u8, index_src, "greet(").?);
    const type_opt = try checker.typeToString(scratch, "/index.ts", greet_off);
    defer ch.freeValue(?[]const u8, scratch, type_opt);
    const type_out = try allocator.dupe(u8, type_opt orelse "");
    errdefer allocator.free(type_out);

    const sym_opt = try checker.inspectSymbolAt(scratch, "/index.ts", greet_off);
    defer ch.freeValue(?ts.compiler.SymbolInfo, scratch, sym_opt);
    const doc_slice = if (sym_opt) |si| (si.documentation orelse "") else "";
    const doc_out = try allocator.dupe(u8, doc_slice);
    errdefer allocator.free(doc_out);

    const exports_list = try checker.resolveModuleExports(scratch, "/index.ts");
    defer ch.freeValue([]const ts.compiler.SymbolInfo, scratch, exports_list);
    const exported_count: u32 = @intCast(exports_list.len);

    // 4. Multi-megabyte emitDeclarations across Guest WASM -> Host WASM memories
    const emit_out = try program.emitDeclarations(scratch, null);
    defer ch.freeValue(ts.compiler.EmitOutput, scratch, emit_out);

    var emitted_total_bytes: u32 = 0;
    var found_big_dts = false;
    var last_rec_buf: [48]u8 = undefined;
    const last_rec_name = if (record_count > 0)
        try std.fmt.bufPrint(&last_rec_buf, "WasmBridgeRecord_{d:0>5}", .{record_count - 1})
    else
        "";
    for (emit_out.output_files) |ef| {
        emitted_total_bytes += @intCast(ef.contents.len);
        if (std.mem.eql(u8, ef.file_name, "/big.d.ts")) {
            found_big_dts = last_rec_name.len == 0 or containsSubstr(ef.contents, last_rec_name);
        }
    }
    const emitted_files_count: u32 = @intCast(emit_out.output_files.len);

    // 5. transpileModule & extractModuleGraph
    const transpiled = try world.compiler.transpileModule(
        scratch,
        "interface Pair { a: number; b: number }\\nexport function addPair(p: Pair): number { return p.a + p.b; }\\n",
        "/pair.ts",
    );
    defer ch.freeValue(ts.compiler.EmitOutput, scratch, transpiled);
    const transpiled_has_fn = transpiled.output_files.len > 0 and
        containsSubstr(transpiled.output_files[0].contents, "addPair") and
        !containsSubstr(transpiled.output_files[0].contents, "interface Pair");

    const graph_res = try world.extractor.extractModuleGraph(scratch, program.asBorrow(), .{
        .root_files = &.{"/index.ts"},
        .module_specifiers = &.{},
        .follow_re_exports = true,
        .expand_utility_types = true,
        .include_jsdoc = true,
        .include_private_members = false,
    });
    defer ch.freeValue(@TypeOf(graph_res), scratch, graph_res);
    const graph_modules_count: u32 = if (graph_res == .ok) @intCast(graph_res.ok.modules.len) else 0;

    // 6. Semantic diagnostic check (TS2322)
    try vfs.writeFile(scratch, "/bad.ts", "export const n: number = \\"oops\\";\\n");
    const bad_prog_res = try world.compiler.createProgram(scratch, vfs.asBorrow(), &.{"/bad.ts"}, opts);
    if (bad_prog_res != .ok) {
        ch.freeValue(@TypeOf(bad_prog_res), scratch, bad_prog_res);
        return error.UnexpectedCreateProgramFailure;
    }
    var bad_prog = world.compiler.wrapProgram(bad_prog_res.ok);
    defer bad_prog.deinit();

    const sem_diags = try bad_prog.getSemanticDiagnostics(scratch, "/bad.ts");
    defer ch.freeValue([]const ts.types.Diagnostic, scratch, sem_diags);
    const diagnostic_code: u32 = if (sem_diags.len > 0) sem_diags[0].code else 0;

    // 7. Explicitly drop all 4 resources (bad_prog, checker, program, vfs)
    try bad_prog.drop();
    try checker.drop();
    try program.drop();
    try vfs.drop();

    return .{
        .compiler_version = ver_out,
        .type_text = type_out,
        .symbol_doc = doc_out,
        .exported_count = exported_count,
        .emitted_files_count = emitted_files_count,
        .emitted_total_bytes = emitted_total_bytes,
        .found_big_dts = found_big_dts,
        .transpiled_has_fn = transpiled_has_fn,
        .graph_modules_count = graph_modules_count,
        .diagnostic_code = diagnostic_code,
        .live_resources_after_drop = host.liveResourceCount(),
    };
}
`;

describe('WebAssembly Component Host Runner (`component-host.js` + `wit-zigar` + `zigar-compiler`)', function() {
  this.timeout(0);

  before(function() {
    for (const dir of [ TMP_ROOT, LOCAL_CACHE_DIR, GLOBAL_CACHE_DIR, XDG_CACHE_DIR, BUILD_DIR, ZIG_SRC_DIR, MODULE_OUT_DIR ]) {
      mkdirSync(dir, { recursive: true });
    }
    process.env.ZIG_LOCAL_CACHE_DIR = LOCAL_CACHE_DIR;
    process.env.ZIG_GLOBAL_CACHE_DIR = GLOBAL_CACHE_DIR;
    process.env.XDG_CACHE_HOME = XDG_CACHE_DIR;
    process.env.TMPDIR = TMP_ROOT;
  });

  after(function() {
    for (const [ key, val ] of Object.entries(prevEnv)) {
      if (val === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = val;
      }
    }
    rmSync(TMP_ROOT, { recursive: true, force: true });
  });

  it('preserves unsigned >>> 0 pointer semantics (>= 2 GiB) and resource handle lifecycle in component-host.js', function() {
    expect(toUnsignedPtr(0x8000_0000 | 0)).to.equal(0x8000_0000);
    expect(toUnsignedPtr(-1)).to.equal(0xffff_ffff);

    const calls = [];
    const wrapped = wrapWasiImportsUnsigned({
      fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
        calls.push({ fd, iovsPtr, iovsLen, nwrittenPtr });
        return 0;
      },
      clock_time_get(clockId, precision, timePtr) {
        calls.push({ clockId, precision, timePtr });
        return 0;
      },
    });
    wrapped.fd_write(1, 0x8000_0000 | 0, 2, 0x9000_0010 | 0);
    wrapped.clock_time_get(1, 1000n, 0xa000_0020 | 0);
    expect(calls[0].iovsPtr).to.equal(0x8000_0000);
    expect(calls[0].nwrittenPtr).to.equal(0x9000_0010);
    expect(calls[1].timePtr).to.equal(0xa000_0020);

    // 32,769 pages = 2 GiB + 64 KiB
    const largeMem = new WebAssembly.Memory({ initial: 32769, maximum: 32770 });
    const signedOffset = 0x8000_0000 | 0;
    expect(signedOffset).to.be.below(0);
    const payload = new TextEncoder().encode('component-host-2gib-ok');
    sliceMemoryU8(largeMem.buffer, signedOffset, payload.byteLength).set(payload);
    const decoded = new TextDecoder().decode(sliceMemoryU8(largeMem.buffer, signedOffset, payload.byteLength));
    expect(decoded).to.equal('component-host-2gib-ok');

    // Resource handle table + dtor + double-drop / type-mismatch guards
    const droppedReps = [];
    const table = new HostResourceTable();
    table.bindDtor('zigar:typescript/compiler@7.1.0', 'vfs', (rep) => droppedReps.push(rep));
    const h = table.insert('zigar:typescript/compiler@7.1.0', 'vfs', 777);
    expect(table.liveCount).to.equal(1);
    expect(table.rep('zigar:typescript/extractor@7.1.0', 'vfs', h)).to.equal(777);
    expect(() => table.rep('zigar:typescript/compiler@7.1.0', 'program', h)).to.throw(/mismatch/i);
    table.drop('zigar:typescript/compiler@7.1.0', 'vfs', h);
    expect(table.liveCount).to.equal(0);
    expect(droppedReps).to.deep.equal([ 777 ]);
    expect(() => table.drop('zigar:typescript/compiler@7.1.0', 'vfs', h)).to.throw(/double-drop/i);
  });

  it('compiles Zig to WASM via zigar-compiler + zigar wit and drives typescript-compiler.component.wasm across separate WASM linear memories', async function() {
    if (!existsSync(COMPONENT_WASM_PATH)) {
      this.skip();
      return;
    }

    // 1. Verify unpackComponent & instantiateComponentHost
    const tsGuest = instantiateComponentHost(COMPONENT_WASM_PATH);
    expect(tsGuest.unpacked.coreModules.length).to.be.at.least(1);
    expect(tsGuest.memoryByteLength()).to.be.above(1024 * 1024);
    expect(getComponentHostRegistry().hosts.get(tsGuest.instanceId)).to.equal(tsGuest);

    try {
      // 2. Generate `generated_ts.zig` using `runWit` (`zigar wit`) and stage `wit_zigar`
      cpSync(WIT_ZIGAR_SRC_DIR, join(ZIG_SRC_DIR, 'wit_zigar'), { recursive: true });
      const generatedTsPath = join(ZIG_SRC_DIR, 'generated_ts.zig');
      const witRes = await runWit(
        [ TS_WIT_PATH, '--world', 'typescript-compiler', '-o', generatedTsPath ],
        { buildDir: BUILD_DIR, zigPath: WAZIG_BIN, silent: true },
      );
      expect(witRes.code).to.equal(0);
      expect(existsSync(generatedTsPath)).to.be.true;

      const hostZigPath = join(ZIG_SRC_DIR, 'ts_wasm_host.zig');
      await writeFile(hostZigPath, ZIG_WASM_HOST_SOURCE, 'utf8');

      // 3. Transpile `ts_wasm_host.zig` to WASM + ESM via `zigar-compiler`
      const { code } = await transpile(hostZigPath, {
        optimize: 'ReleaseSmall',
        embedWASM: true,
        stripWASM: true,
        useWazig: true,
        zigPath: WAZIG_BIN,
        buildDir: join(BUILD_DIR, 'wasm-host-mod'),
      });
      const resolvedCode = code
        .replace(
          /from\s+["']zigar-runtime["']/g,
          `from ${JSON.stringify(pathToFileURL(join(RUNTIME_SRC_DIR, 'index.js')).href)}`,
        )
        .replace(
          /import\s+["']zigar-runtime\/([^"']+)["']/g,
          (_, subPath) => `import ${JSON.stringify(pathToFileURL(join(RUNTIME_SRC_DIR, subPath)).href)}`,
        );

      const mjsPath = join(MODULE_OUT_DIR, `ts-wasm-host-${Date.now()}.mjs`);
      await writeFile(mjsPath, resolvedCode, 'utf8');
      const zigHostMod = await import(pathToFileURL(mjsPath).href);

      try {
        // 4a. Test `ZigarCallbacksBackend` from WASM Zig -> Go Component WASM
        const cbVersion = zigHostMod.invokeCompilerVersionViaCallbacks(tsGuest.createZigarCallbacks()).string;
        expect(cbVersion).to.match(/^7\.1\./);

        // 4b. Test `WasmExternBackend` full pipeline including >2 MiB cross-WASM-memory lift + resource drops
        const summary = zigHostMod.runFullTypeScriptPipeline(tsGuest.instanceId, 20000);
        expect(summary.compiler_version.string).to.match(/^7\.1\./);
        expect(summary.type_text.string).to.equal('(u: User) => string');
        expect(summary.symbol_doc.string).to.include('Greets a user across WASM memories');
        expect(summary.exported_count).to.equal(2);
        expect(summary.emitted_files_count).to.equal(2);
        expect(summary.emitted_total_bytes).to.be.above(2 * 1024 * 1024);
        expect(summary.found_big_dts).to.equal(true);
        expect(summary.transpiled_has_fn).to.equal(true);
        expect(summary.graph_modules_count).to.be.at.least(1);
        expect(summary.diagnostic_code).to.equal(2322);
        expect(summary.live_resources_after_drop).to.equal(0);
        expect(tsGuest.liveResourceCount()).to.equal(0);
      } finally {
        await zigHostMod.__zigar?.abandon();
      }

      // 5. Exercise `TypeScriptHost.initWasmExtern(allocator)` (without explicit `instanceId`)
      //    directly from `ts-zigar/src/host.zig` against the default-registered `tsGuest` (`instanceId === 1`).
      expect(tsGuest.instanceId).to.equal(1);
      const tsHostPkgDir = join(TMP_ROOT, 'ts-host-pkg');
      mkdirSync(tsHostPkgDir, { recursive: true });
      const buildExtraZig = `const std = @import("std");
pub fn getImports(b: *std.Build, args: anytype) []const std.Build.Module.Import {
    const wit_zigar_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = ${JSON.stringify(join(WIT_ZIGAR_SRC_DIR, 'root.zig'))} },
        .target = args.target,
        .optimize = args.optimize,
    });
    const gen_ts_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = ${JSON.stringify(generatedTsPath)} },
        .target = args.target,
        .optimize = args.optimize,
    });
    const ts_zigar_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = ${JSON.stringify(join(TS_ZIGAR_SRC_DIR, 'root.zig'))} },
        .target = args.target,
        .optimize = args.optimize,
        .imports = &.{
            .{ .name = "wit_zigar", .module = wit_zigar_mod },
            .{ .name = "generated_ts_wasm32", .module = gen_ts_mod },
            .{ .name = "generated_ts_wasm64", .module = gen_ts_mod },
        },
    });
    return &.{
        .{ .name = "ts_zigar", .module = ts_zigar_mod },
    };
}
`;
      const defaultHostZig = `const std = @import("std");
const ts_zigar = @import("ts_zigar");

pub fn checkDefaultInitWasmExtern(allocator: std.mem.Allocator) ![]const u8 {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa_impl.deinit() == .leak) @panic("Zig GPA leak in TypeScriptHost.initWasmExtern!");
    }
    const scratch = gpa_impl.allocator();

    var ts_host = try ts_zigar.TypeScriptHost.initWasmExtern(scratch);
    defer ts_host.deinit();

    const ver = try ts_host.compilerVersion(scratch);
    defer ts_zigar.TypeScriptHost.freeValue([]const u8, scratch, ver);
    return try allocator.dupe(u8, ver);
}
`;
      await writeFile(join(tsHostPkgDir, 'build.extra.zig'), buildExtraZig, 'utf8');
      const defaultHostPath = join(tsHostPkgDir, 'default_wasm_host.zig');
      await writeFile(defaultHostPath, defaultHostZig, 'utf8');

      const { code: defaultHostCode } = await transpile(defaultHostPath, {
        optimize: 'ReleaseSmall',
        embedWASM: true,
        stripWASM: true,
        zigPath: 'zig',
        buildDir: join(BUILD_DIR, 'default-wasm-host-mod'),
      });
      const resolvedDefaultCode = defaultHostCode
        .replace(
          /from\s+["']zigar-runtime["']/g,
          `from ${JSON.stringify(pathToFileURL(join(RUNTIME_SRC_DIR, 'index.js')).href)}`,
        )
        .replace(
          /import\s+["']zigar-runtime\/([^"']+)["']/g,
          (_, subPath) => `import ${JSON.stringify(pathToFileURL(join(RUNTIME_SRC_DIR, subPath)).href)}`,
        );
      const defaultMjsPath = join(MODULE_OUT_DIR, `default-ts-host-${Date.now()}.mjs`);
      await writeFile(defaultMjsPath, resolvedDefaultCode, 'utf8');
      const defaultHostMod = await import(pathToFileURL(defaultMjsPath).href);
      try {
        const defaultVer = defaultHostMod.checkDefaultInitWasmExtern().string;
        expect(defaultVer).to.match(/^7\.1\./);
        expect(tsGuest.liveResourceCount()).to.equal(0);
      } finally {
        await defaultHostMod.__zigar?.abandon();
      }
    } finally {
      tsGuest.dispose();
      expect(getComponentHostRegistry().hosts.has(tsGuest.instanceId)).to.equal(false);
    }
  });
});
