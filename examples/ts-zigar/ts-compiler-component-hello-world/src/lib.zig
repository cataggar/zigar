//! Shared Zig library driving `zigar:typescript@7.1.0/compiler` via `zigar wit`-generated
//! bindings and `wit-zigar`'s `ComponentHost`.
//!
//! Runs identically:
//!   1. Natively (`zig build run` / `zig build test`) via `NodeProcessBackend`, and
//!   2. Compiled to `wasm32-wasi` inside Node.js 26 (`run-wasm.mjs` / `npm test`) via
//!      `WasmExternBackend` + `zigar-compiler`'s `instantiateComponentHost`.

const std = @import("std");
const builtin = @import("builtin");
const wit_zigar = @import("wit_zigar");

/// Generated Zig 0.17 WIT bindings produced from `ts-zigar/wit/typescript.wit`
/// (`--world typescript-compiler`).
const bindings = @import("generated_ts");
const ch = wit_zigar.component_host;

pub const math_ts_path = "/app/math.ts";
pub const math_ts_source =
    \\export type NumericOutcome<T extends number> =
    \\  | { readonly ok: true; readonly value: T }
    \\  | { readonly ok: false; readonly reason: string };
    \\
    \\export type ReadonlySample<T> = {
    \\  readonly [K in keyof T]: T[K];
    \\};
    \\
    \\export function clamp<T extends number>(
    \\  value: T,
    \\  min: number,
    \\  max: number,
    \\): NumericOutcome<number> {
    \\  if (Number.isNaN(value)) {
    \\    return { ok: false, reason: "NaN is not a finite reading" };
    \\  }
    \\  const bounded = Math.min(Math.max(value, min), max);
    \\  return { ok: true, value: bounded };
    \\}
    \\
    \\export function sumReadings(readings: readonly number[]): number {
    \\  let total = 0;
    \\  for (const reading of readings) {
    \\    total += reading;
    \\  }
    \\  return total;
    \\}
    \\
;

pub const index_ts_path = "/app/index.ts";
pub const index_ts_source =
    \\import {
    \\  clamp,
    \\  sumReadings,
    \\  type NumericOutcome,
    \\  type ReadonlySample,
    \\} from "./math";
    \\
    \\export interface SensorBatch {
    \\  sensorId: string;
    \\  readings: number[];
    \\  unit: "celsius" | "kelvin";
    \\}
    \\
    \\/** Summarizes a sensor batch asynchronously using clamped totals. */
    \\export async function summarizeBatch(
    \\  batch: ReadonlySample<SensorBatch>,
    \\): Promise<NumericOutcome<number>> {
    \\  const total = sumReadings(batch.readings);
    \\  return clamp(total, -273.15, 1000);
    \\}
    \\
    \\export const formatOutcome = (outcome: NumericOutcome<number>): string =>
    \\  outcome.ok ? `ok:${outcome.value}` : `error:${outcome.reason}`;
    \\
;

pub const broken_ts_path = "/app/broken.ts";
pub const broken_ts_source =
    \\import { sumReadings } from "./math";
    \\
    \\export const invalidReading: number = "not-a-number";
    \\export const brokenTotal = sumReadings([invalidReading]);
    \\
;

pub const ExportedSymbolSummary = struct {
    name: []const u8,
    type_text: []const u8,
};

pub const EmittedDeclarationSummary = struct {
    file_name: []const u8,
    contents: []const u8,
};

pub const DiagnosticSummary = struct {
    code: u32,
    file_name: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
};

pub const DemoReport = struct {
    compiler_version: []const u8,
    syntactic_diagnostic_count: u32,
    semantic_diagnostic_count: u32,
    inferred_expression_type: []const u8,
    exported_symbols: []const ExportedSymbolSummary,
    emitted_declarations: []const EmittedDeclarationSummary,
    transpiled_js: []const u8,
    broken_diagnostic_count: u32,
    broken_diagnostic: DiagnosticSummary,
    live_resources_after_drop: u32,

    pub fn deinit(self: *const DemoReport, allocator: std.mem.Allocator) void {
        allocator.free(self.compiler_version);
        allocator.free(self.inferred_expression_type);
        freeExportedSymbols(allocator, self.exported_symbols);
        freeEmittedDeclarations(allocator, self.emitted_declarations);
        allocator.free(self.transpiled_js);
        freeDiagnosticSummary(allocator, &self.broken_diagnostic);
    }
};

fn freeExportedSymbols(allocator: std.mem.Allocator, items: []const ExportedSymbolSummary) void {
    for (items) |item| {
        allocator.free(item.name);
        allocator.free(item.type_text);
    }
    allocator.free(items);
}

fn freeEmittedDeclarations(allocator: std.mem.Allocator, items: []const EmittedDeclarationSummary) void {
    for (items) |item| {
        allocator.free(item.file_name);
        allocator.free(item.contents);
    }
    allocator.free(items);
}

fn freeDiagnosticSummary(allocator: std.mem.Allocator, diag: *const DiagnosticSummary) void {
    allocator.free(diag.file_name);
    allocator.free(diag.message);
}

fn strictCompilerOptions() bindings.compiler.CompilerOptions {
    return .{
        .target = .es2024,
        .module = .esnext,
        .module_resolution = .bundler,
        .strict = true,
        .exact_optional_property_types = true,
        .no_unchecked_indexed_access = true,
        .declaration = true,
        .emit_declaration_only = true,
        .allow_js = false,
        .skip_lib_check = true,
        .base_url = null,
        .type_roots = &.{},
        .types = &.{},
    };
}

/// Runs the complete `zigar:typescript@7.1.0/compiler` showcase against any
/// `wit_zigar.component_host.ComponentHost` (native Node RPC or WASM extern).
fn runPipeline(
    out_allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    host: *ch.ComponentHost,
) !DemoReport {
    // Bind `zigar wit`-generated `zigar:typescript/compiler@7.1.0` client to `host`
    const compiler = bindings.compiler.bindHost(host);

    // (a) Query upstream TypeScript 7.1 compiler version
    const raw_version = try compiler.compilerVersion(scratch);
    defer ch.freeValue([]const u8, scratch, raw_version);
    const compiler_version = try out_allocator.dupe(u8, raw_version);
    errdefer out_allocator.free(compiler_version);

    // (b) Create an in-memory `vfs` pre-populated with bundled `lib.*.d.ts` files
    //     and mount multi-file TypeScript sources (`/app/math.ts`, `/app/index.ts`)
    var vfs = try compiler.createVfs(scratch, true);
    defer vfs.deinit();

    try vfs.writeFile(scratch, math_ts_path, math_ts_source);
    try vfs.writeFile(scratch, index_ts_path, index_ts_source);

    // (c) Create a strict `program` and verify 0 syntactic & 0 semantic diagnostics
    const root_files = [_][]const u8{ math_ts_path, index_ts_path };
    const prog_res = try compiler.createProgram(
        scratch,
        vfs.asBorrow(),
        &root_files,
        strictCompilerOptions(),
    );
    if (prog_res != .ok) {
        ch.freeValue(@TypeOf(prog_res), scratch, prog_res);
        return error.CreateProgramFailed;
    }
    var program = compiler.wrapProgram(prog_res.ok);
    defer program.deinit();

    const syntactic_diags = try program.getSyntacticDiagnostics(scratch, null);
    defer ch.freeValue([]const bindings.types.Diagnostic, scratch, syntactic_diags);

    const semantic_diags = try program.getSemanticDiagnostics(scratch, null);
    defer ch.freeValue([]const bindings.types.Diagnostic, scratch, semantic_diags);

    const syntactic_diagnostic_count: u32 = @intCast(syntactic_diags.len);
    const semantic_diagnostic_count: u32 = @intCast(semantic_diags.len);
    if (syntactic_diagnostic_count != 0 or semantic_diagnostic_count != 0) {
        return error.UnexpectedDiagnosticsOnValidProgram;
    }

    // (d) Acquire a `checker`, inspect expression/symbol types via `typeToString`,
    //     and enumerate module exports via `resolveModuleExports`
    var checker = compiler.wrapChecker(try program.getChecker(scratch));
    defer checker.deinit();

    const summarize_offset: u32 = @intCast(
        std.mem.indexOf(u8, index_ts_source, "summarizeBatch") orelse return error.OffsetNotFound,
    );
    const maybe_type_str = try checker.typeToString(scratch, index_ts_path, summarize_offset);
    const raw_type_str = maybe_type_str orelse return error.MissingTypeString;
    defer ch.freeValue([]const u8, scratch, raw_type_str);
    const inferred_expression_type = try out_allocator.dupe(u8, raw_type_str);
    errdefer out_allocator.free(inferred_expression_type);

    const raw_exports = try checker.resolveModuleExports(scratch, index_ts_path);
    defer ch.freeValue([]const bindings.compiler.SymbolInfo, scratch, raw_exports);

    var exported_symbols = try out_allocator.alloc(ExportedSymbolSummary, raw_exports.len);
    var initialized_exports: usize = 0;
    errdefer {
        for (exported_symbols[0..initialized_exports]) |item| {
            out_allocator.free(item.name);
            out_allocator.free(item.type_text);
        }
        out_allocator.free(exported_symbols);
    }
    for (raw_exports, 0..) |sym, idx| {
        const name_copy = try out_allocator.dupe(u8, sym.name);
        errdefer out_allocator.free(name_copy);
        const type_copy = try out_allocator.dupe(u8, sym.type_text);
        exported_symbols[idx] = .{
            .name = name_copy,
            .type_text = type_copy,
        };
        initialized_exports += 1;
    }

    // (e) Emit `.d.ts` declarations (`program.emitDeclarations`) and transpile
    //     TypeScript to JavaScript (`compiler.transpileModule`)
    const decl_emit = try program.emitDeclarations(scratch, null);
    defer ch.freeValue(bindings.compiler.EmitOutput, scratch, decl_emit);
    if (decl_emit.emit_skipped or decl_emit.diagnostics.len != 0 or decl_emit.output_files.len == 0) {
        return error.DeclarationEmitFailed;
    }

    var emitted_declarations = try out_allocator.alloc(EmittedDeclarationSummary, decl_emit.output_files.len);
    var initialized_decls: usize = 0;
    errdefer {
        for (emitted_declarations[0..initialized_decls]) |item| {
            out_allocator.free(item.file_name);
            out_allocator.free(item.contents);
        }
        out_allocator.free(emitted_declarations);
    }
    for (decl_emit.output_files, 0..) |ef, idx| {
        const fname_copy = try out_allocator.dupe(u8, ef.file_name);
        errdefer out_allocator.free(fname_copy);
        const contents_copy = try out_allocator.dupe(u8, ef.contents);
        emitted_declarations[idx] = .{
            .file_name = fname_copy,
            .contents = contents_copy,
        };
        initialized_decls += 1;
    }

    const transpiled = try compiler.transpileModule(scratch, index_ts_source, index_ts_path);
    defer ch.freeValue(bindings.compiler.EmitOutput, scratch, transpiled);
    if (transpiled.emit_skipped or transpiled.output_files.len == 0) {
        return error.TranspileFailed;
    }
    const transpiled_js = try out_allocator.dupe(u8, transpiled.output_files[0].contents);
    errdefer out_allocator.free(transpiled_js);

    // (f) Write a second TypeScript source containing an intentional type error
    //     (`TS2322`: assigning `"not-a-number"` to `number`) and inspect diagnostics
    try vfs.writeFile(scratch, broken_ts_path, broken_ts_source);
    const broken_roots = [_][]const u8{ math_ts_path, broken_ts_path };
    const broken_res = try compiler.createProgram(
        scratch,
        vfs.asBorrow(),
        &broken_roots,
        strictCompilerOptions(),
    );
    if (broken_res != .ok) {
        ch.freeValue(@TypeOf(broken_res), scratch, broken_res);
        return error.CreateBrokenProgramFailed;
    }
    var broken_program = compiler.wrapProgram(broken_res.ok);
    defer broken_program.deinit();

    const broken_diags = try broken_program.getSemanticDiagnostics(scratch, broken_ts_path);
    defer ch.freeValue([]const bindings.types.Diagnostic, scratch, broken_diags);
    const broken_diagnostic_count: u32 = @intCast(broken_diags.len);
    if (broken_diagnostic_count == 0) {
        return error.ExpectedSemanticTypeError;
    }

    const first_diag = broken_diags[0];
    const span = first_diag.span orelse return error.MissingDiagnosticSpan;
    const diag_file = try out_allocator.dupe(u8, span.file_name);
    errdefer out_allocator.free(diag_file);
    const diag_msg = try out_allocator.dupe(u8, first_diag.message);
    errdefer out_allocator.free(diag_msg);

    const broken_diagnostic = DiagnosticSummary{
        .code = first_diag.code,
        .file_name = diag_file,
        .line = span.line,
        .column = span.column,
        .message = diag_msg,
    };

    // (g) Drop all WIT resources in reverse order and verify zero leaked handles
    //     (`defer ...deinit()` above remains an idempotent safety net on error paths)
    try broken_program.drop();
    try checker.drop();
    try program.drop();
    try vfs.drop();

    const live_resources_after_drop = host.liveResourceCount();
    if (live_resources_after_drop != 0) {
        return error.LeakedWitResources;
    }

    return .{
        .compiler_version = compiler_version,
        .syntactic_diagnostic_count = syntactic_diagnostic_count,
        .semantic_diagnostic_count = semantic_diagnostic_count,
        .inferred_expression_type = inferred_expression_type,
        .exported_symbols = exported_symbols,
        .emitted_declarations = emitted_declarations,
        .transpiled_js = transpiled_js,
        .broken_diagnostic_count = broken_diagnostic_count,
        .broken_diagnostic = broken_diagnostic,
        .live_resources_after_drop = live_resources_after_drop,
    };
}

/// Native Zig host API (used by `zig build run` and `zig build test`).
/// Omitted on `wasm32` so `zigar-compiler`'s WASM exporter reflects only JS-facing types.
pub const native = if (!builtin.cpu.arch.isWasm()) struct {
    pub const wit_bindings = bindings;
    pub const component_host = ch;
    pub const runWithHost = runPipeline;

    pub fn runDemo(
        allocator: std.mem.Allocator,
        io: std.Io,
        component_wasm_path: []const u8,
        node_binary: []const u8,
    ) !DemoReport {
        var node_backend = try ch.NodeProcessBackend.init(allocator, io, .{
            .wasm_path = component_wasm_path,
            .node_binary = node_binary,
        });
        defer node_backend.deinit();

        var host = ch.ComponentHost.init(node_backend.backend());
        return runPipeline(allocator, allocator, &host);
    }
} else struct {};

/// WebAssembly guest entrypoint exported for `zigar-compiler` + `zigar-runtime`:
/// drives the `instantiateComponentHost(...)` instance registered at `instance_id`
/// across separate WebAssembly linear memories, with `DebugAllocator` leak checking
/// on all intermediate Canonical ABI allocations.
pub fn runWasmDemo(allocator: std.mem.Allocator, instance_id: u32) !DemoReport {
    var gpa_impl: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer {
        if (gpa_impl.deinit() == .leak) {
            @panic("Zig memory leak detected in runWasmDemo");
        }
    }
    const scratch = gpa_impl.allocator();

    var wasm_backend = ch.WasmExternBackend{ .instance_id = instance_id };
    var host = ch.ComponentHost.init(wasm_backend.backend());
    return runPipeline(allocator, scratch, &host);
}
