//! Ergonomic Zig host client for `typescript-compiler.component.wasm` (`zigar:typescript@7.1.0`).
//!
//! Works identically across:
//!   - Native Zig CLI / tests (`TypeScriptHost.spawnNode` via Node 26 V8 WebAssembly IPC),
//!   - WASM-compiled Zig running inside `zigar-compiler` / Node 26 V8 (`TypeScriptHost.initWasmExtern`),
//!   - Zigar JS callback bridges (`ZigarCallbacksBackend`) and pure-Zig mock backends (`MockGuestBackend`).

const std = @import("std");
const builtin = @import("builtin");
const wit_zigar = @import("wit_zigar");
const ts = @import("generated_ts_wasm32");

pub const component_host = wit_zigar.component_host;
pub const ComponentHost = component_host.ComponentHost;
pub const ComponentPlan = component_host.ComponentPlan;
pub const GuestMemoryBackend = component_host.GuestMemoryBackend;
pub const HostError = component_host.HostError;

pub const types = ts.types;
pub const compiler = ts.compiler;
pub const extractor = ts.extractor;

const WorldClient = ts.HostClient(ComponentHost);
const CompilerClient = compiler.HostClient(ComponentHost);
const ExtractorClient = extractor.HostClient(ComponentHost);

pub fn defaultCompilerOptions() compiler.CompilerOptions {
    return .{
        .target = .esnext,
        .module = .esnext,
        .module_resolution = .bundler,
        .strict = true,
        .exact_optional_property_types = false,
        .no_unchecked_indexed_access = false,
        .declaration = true,
        .emit_declaration_only = false,
        .allow_js = false,
        .skip_lib_check = true,
        .base_url = null,
        .type_roots = &.{},
        .types = &.{},
    };
}

pub fn defaultExtractConfig(root_files: []const []const u8) types.ExtractConfig {
    return .{
        .root_files = root_files,
        .module_specifiers = &.{},
        .follow_re_exports = true,
        .expand_utility_types = true,
        .include_jsdoc = true,
        .include_private_members = false,
    };
}

pub const TypeScriptHost = struct {
    allocator: ?std.mem.Allocator = null,
    owned_node_backend: if (component_host.has_process_support) ?*component_host.NodeProcessBackend else void =
        if (component_host.has_process_support) null else {},
    owned_wasm_extern_state: ?*component_host.WasmExternBackend = null,
    owned_zigar_cb_state: ?*component_host.ZigarCallbacksBackend = null,
    host: *ComponentHost,
    owned_host: bool = false,

    pub const Vfs = struct {
        inner: CompilerClient.VfsClient,

        pub fn handle(self: Vfs) i32 {
            return self.inner.handle();
        }

        pub fn asBorrow(self: Vfs) ts.Borrow(compiler.Vfs) {
            return self.inner.asBorrow();
        }

        pub fn writeFile(self: Vfs, allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
            return self.inner.writeFile(allocator, path, contents);
        }

        /// Alias for `writeFile` matching common VFS host conventions.
        pub const setFile = writeFile;

        pub fn readFile(self: Vfs, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
            return self.inner.readFile(allocator, path);
        }

        pub fn fileExists(self: Vfs, allocator: std.mem.Allocator, path: []const u8) !bool {
            return self.inner.fileExists(allocator, path);
        }

        pub fn deleteFile(self: Vfs, allocator: std.mem.Allocator, path: []const u8) !bool {
            return self.inner.deleteFile(allocator, path);
        }

        pub fn listFiles(self: Vfs, allocator: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
            return self.inner.listFiles(allocator, dir);
        }

        pub fn drop(self: *Vfs) !void {
            try self.inner.drop();
        }

        pub fn deinit(self: *Vfs) void {
            self.inner.deinit();
        }
    };

    pub const Checker = struct {
        inner: CompilerClient.CheckerClient,

        pub fn handle(self: Checker) i32 {
            return self.inner.handle();
        }

        pub fn asBorrow(self: Checker) ts.Borrow(compiler.Checker) {
            return self.inner.asBorrow();
        }

        pub fn typeToString(self: Checker, allocator: std.mem.Allocator, file_name: []const u8, offset: u32) !?[]const u8 {
            return self.inner.typeToString(allocator, file_name, offset);
        }

        pub fn inspectTypeAt(self: Checker, allocator: std.mem.Allocator, file_name: []const u8, offset: u32) !?compiler.TypeInfo {
            return self.inner.inspectTypeAt(allocator, file_name, offset);
        }

        pub fn inspectSymbolAt(self: Checker, allocator: std.mem.Allocator, file_name: []const u8, offset: u32) !?compiler.SymbolInfo {
            return self.inner.inspectSymbolAt(allocator, file_name, offset);
        }

        pub fn resolveModuleExports(self: Checker, allocator: std.mem.Allocator, file_name: []const u8) ![]const compiler.SymbolInfo {
            return self.inner.resolveModuleExports(allocator, file_name);
        }

        pub const getExportedSymbols = resolveModuleExports;

        pub fn drop(self: *Checker) !void {
            try self.inner.drop();
        }

        pub fn deinit(self: *Checker) void {
            self.inner.deinit();
        }
    };

    pub const Program = struct {
        inner: CompilerClient.ProgramClient,

        pub fn handle(self: Program) i32 {
            return self.inner.handle();
        }

        pub fn asBorrow(self: Program) ts.Borrow(compiler.Program) {
            return self.inner.asBorrow();
        }

        pub fn getRootFiles(self: Program, allocator: std.mem.Allocator) ![]const []const u8 {
            return self.inner.getRootFiles(allocator);
        }

        pub fn getSyntacticDiagnostics(self: Program, allocator: std.mem.Allocator, file_name: ?[]const u8) ![]const types.Diagnostic {
            return self.inner.getSyntacticDiagnostics(allocator, file_name);
        }

        pub fn getSemanticDiagnostics(self: Program, allocator: std.mem.Allocator, file_name: ?[]const u8) ![]const types.Diagnostic {
            return self.inner.getSemanticDiagnostics(allocator, file_name);
        }

        pub fn getGlobalDiagnostics(self: Program, allocator: std.mem.Allocator) ![]const types.Diagnostic {
            return self.inner.getGlobalDiagnostics(allocator);
        }

        /// Returns combined syntactic + semantic diagnostics for `file_name` (or all files when `null`).
        pub fn getDiagnostics(self: Program, allocator: std.mem.Allocator, file_name: ?[]const u8) ![]const types.Diagnostic {
            const syn = try self.getSyntacticDiagnostics(allocator, file_name);
            errdefer ComponentHost.free([]const types.Diagnostic, allocator, syn);
            const sem = try self.getSemanticDiagnostics(allocator, file_name);
            errdefer ComponentHost.free([]const types.Diagnostic, allocator, sem);

            if (sem.len == 0) {
                allocator.free(sem);
                return syn;
            }
            if (syn.len == 0) {
                allocator.free(syn);
                return sem;
            }

            const combined = try allocator.alloc(types.Diagnostic, syn.len + sem.len);
            @memcpy(combined[0..syn.len], syn);
            @memcpy(combined[syn.len..], sem);
            allocator.free(syn);
            allocator.free(sem);
            return combined;
        }

        pub fn emitDeclarations(self: Program, allocator: std.mem.Allocator, file_name: ?[]const u8) !compiler.EmitOutput {
            return self.inner.emitDeclarations(allocator, file_name);
        }

        pub fn getChecker(self: Program, allocator: std.mem.Allocator) !Checker {
            const own_chk = try self.inner.getChecker(allocator);
            return .{
                .inner = CompilerClient.CheckerClient.wrap(self.inner.host, own_chk),
            };
        }

        pub fn drop(self: *Program) !void {
            try self.inner.drop();
        }

        pub fn deinit(self: *Program) void {
            self.inner.deinit();
        }
    };

    /// Wrap an existing `ComponentHost` pointer without taking ownership.
    pub fn fromComponentHost(host_ptr: *ComponentHost) TypeScriptHost {
        return .{
            .host = host_ptr,
            .owned_host = false,
        };
    }

    /// Create an owned `TypeScriptHost` around any `GuestMemoryBackend`.
    pub fn initBackend(allocator: std.mem.Allocator, backend: GuestMemoryBackend) !TypeScriptHost {
        const host_box = try allocator.create(ComponentHost);
        host_box.* = ComponentHost.init(backend);
        return .{
            .allocator = allocator,
            .host = host_box,
            .owned_host = true,
        };
    }

    /// Instantiate a `TypeScriptHost` inside a WASM-compiled Zig module running under
    /// `zigar-compiler` / Node 26 V8 WebAssembly (`"zigar:component-host"` extern imports),
    /// bound to the default-registered `instantiateComponentHost(...)` instance (`instanceId == 1`).
    pub fn initWasmExtern(allocator: std.mem.Allocator) !TypeScriptHost {
        return initWasmExternId(allocator, 1);
    }

    /// Like `initWasmExtern`, bound to a specific JS `instantiateComponentHost` `instanceId`.
    pub fn initWasmExternId(allocator: std.mem.Allocator, instance_id: u32) !TypeScriptHost {
        const ext_box = try allocator.create(component_host.WasmExternBackend);
        errdefer allocator.destroy(ext_box);
        ext_box.* = .{ .instance_id = instance_id };

        const host_box = try allocator.create(ComponentHost);
        host_box.* = ComponentHost.init(ext_box.backend());
        return .{
            .allocator = allocator,
            .owned_wasm_extern_state = ext_box,
            .host = host_box,
            .owned_host = true,
        };
    }

    /// Instantiate a `TypeScriptHost` backed by Zigar JS function callbacks (`createZigarCallbacks()`),
    /// usable from both WASM Zigar modules and native `node-zigar` addons.
    pub fn initZigarCallbacks(allocator: std.mem.Allocator, callbacks: component_host.ZigarCallbacks) !TypeScriptHost {
        const cb_box = try allocator.create(component_host.ZigarCallbacksBackend);
        errdefer allocator.destroy(cb_box);
        cb_box.* = component_host.ZigarCallbacksBackend.init(callbacks);

        const host_box = try allocator.create(ComponentHost);
        host_box.* = ComponentHost.init(cb_box.backend());
        return .{
            .allocator = allocator,
            .owned_zigar_cb_state = cb_box,
            .host = host_box,
            .owned_host = true,
        };
    }

    /// Spawn a persistent Node 26 V8 WebAssembly worker process hosting
    /// `typescript-compiler.component.wasm` over binary-framed stdio IPC.
    pub fn spawnNode(
        allocator: std.mem.Allocator,
        io: if (component_host.has_process_support) std.Io else void,
        opts: if (component_host.has_process_support) component_host.NodeProcessBackend.SpawnOptions else void,
    ) !TypeScriptHost {
        if (!component_host.has_process_support) {
            return error.BackendIoError;
        }
        const nb_box = try allocator.create(component_host.NodeProcessBackend);
        errdefer allocator.destroy(nb_box);
        nb_box.* = try component_host.NodeProcessBackend.init(allocator, io, opts);
        errdefer nb_box.deinit();

        const host_box = try allocator.create(ComponentHost);
        host_box.* = ComponentHost.init(nb_box.backend());
        return .{
            .allocator = allocator,
            .owned_node_backend = nb_box,
            .host = host_box,
            .owned_host = true,
        };
    }

    pub fn deinit(self: *TypeScriptHost) void {
        if (self.owned_host) {
            if (self.allocator) |alloc| {
                alloc.destroy(self.host);
                if (self.owned_wasm_extern_state) |ext_ptr| {
                    alloc.destroy(ext_ptr);
                }
                if (self.owned_zigar_cb_state) |cb_ptr| {
                    alloc.destroy(cb_ptr);
                }
                if (component_host.has_process_support) {
                    if (self.owned_node_backend) |nb_ptr| {
                        nb_ptr.deinit();
                        alloc.destroy(nb_ptr);
                    }
                }
            }
        }
        self.* = undefined;
    }

    pub fn freeValue(comptime T: type, allocator: std.mem.Allocator, value: T) void {
        ComponentHost.free(T, allocator, value);
    }

    pub fn liveResourceCount(self: *const TypeScriptHost) u32 {
        return self.host.liveResourceCount();
    }

    pub fn worldClient(self: *const TypeScriptHost) WorldClient {
        return ts.bindHost(self.host);
    }

    pub fn compilerClient(self: *const TypeScriptHost) CompilerClient {
        return compiler.bindHost(self.host);
    }

    pub fn extractorClient(self: *const TypeScriptHost) ExtractorClient {
        return extractor.bindHost(self.host);
    }

    pub fn compilerVersion(self: *const TypeScriptHost, allocator: std.mem.Allocator) ![]const u8 {
        return self.compilerClient().compilerVersion(allocator);
    }

    pub fn createVfs(self: *const TypeScriptHost, allocator: std.mem.Allocator, use_bundled_libs: bool) !Vfs {
        return .{
            .inner = try self.compilerClient().createVfs(allocator, use_bundled_libs),
        };
    }

    pub const CreateProgramOutcome = union(enum) {
        ok: Program,
        err: []const types.Diagnostic,

        pub fn deinitErr(self: CreateProgramOutcome, allocator: std.mem.Allocator) void {
            if (self == .err) {
                ComponentHost.free([]const types.Diagnostic, allocator, self.err);
            }
        }
    };

    pub fn createProgram(
        self: *const TypeScriptHost,
        allocator: std.mem.Allocator,
        vfs: Vfs,
        root_files: []const []const u8,
        options: compiler.CompilerOptions,
    ) !CreateProgramOutcome {
        const res = try self.compilerClient().createProgram(allocator, vfs.asBorrow(), root_files, options);
        return switch (res) {
            .ok => |own_prog| .{ .ok = .{ .inner = self.compilerClient().wrapProgram(own_prog) } },
            .err => |diags| .{ .err = diags },
        };
    }

    pub fn transpileModule(
        self: *const TypeScriptHost,
        allocator: std.mem.Allocator,
        source: []const u8,
        file_name: []const u8,
    ) !compiler.EmitOutput {
        return self.compilerClient().transpileModule(allocator, source, file_name);
    }

    pub fn extractModuleGraph(
        self: *const TypeScriptHost,
        allocator: std.mem.Allocator,
        prog: Program,
        config: types.ExtractConfig,
    ) !ts.Result(types.DeclarationGraph, []const types.Diagnostic) {
        return self.extractorClient().extractModuleGraph(allocator, prog.asBorrow(), config);
    }
};
