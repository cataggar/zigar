//! `monaco-editor-hello-world` — Browser Monaco Editor application in Zig 0.17.
//!
//! Port of `ts2rs/monaco-editor-hello-world` to Zig 0.17 + `ts-zigar` (`zigar ts`),
//! bundled for the browser with Vite and `rollup-plugin-zigar`:
//! - Configures `globalThis.MonacoEnvironment` with a persistent Zig `getWorkerUrl` closure
//!   routing `typescript`/`javascript` to `./ts.worker.js` and all other labels to `./editor.worker.js`.
//! - Looks up `#container` via `dom.document.getElementById("container")`.
//! - Mounts an interactive TypeScript Monaco editor with `vs-dark` theme via `monaco.editor.create(...)`.
//! - Provides clean `getValue`, `setValue`, `resolveWorkerUrl`, and leak-free `unmount` helpers.

const std = @import("std");
const web = @import("web");
const dom = web.dom;
const monaco = web.monaco;
// `web.zigar_js` bridges to `@import("zigar").js` under zigar-compiler and supports standalone `zig build test`.
const js = web.zigar_js;

pub const default_code =
    \\interface Greeting {
    \\  message: string;
    \\  runtime: "WebAssembly" | "Native";
    \\}
    \\
    \\export function hello(greeting: Greeting): string {
    \\  return `${greeting.message} from Zig 0.17 + Monaco (${greeting.runtime})!`;
    \\}
    \\
    \\console.log(hello({ message: "Hello world!", runtime: "WebAssembly" }));
    \\
;

const WorkerUrlClosure = js.Closure(*WorkerEnvState, WorkerEnvState.getWorkerUrl);

const WorkerEnvState = struct {
    closure: ?WorkerUrlClosure = null,
    requests: usize = 0,

    pub fn routeWorkerLabel(label: []const u8) []const u8 {
        if (std.mem.eql(u8, label, "typescript") or std.mem.eql(u8, label, "javascript")) {
            return "./ts.worker.js";
        }
        return "./editor.worker.js";
    }

    fn getWorkerUrl(self: *WorkerEnvState, _: []const u8, label: []const u8) []const u8 {
        self.requests += 1;
        return routeWorkerLabel(label);
    }

    fn releaseClosure(self: *WorkerEnvState) void {
        if (self.closure) |*c| {
            c.deinit();
            self.closure = null;
        }
    }
};

var env_state: WorkerEnvState = .{};
var active_editor: ?monaco.editor.IStandaloneCodeEditor = null;

/// Install `globalThis.MonacoEnvironment` with a persistent Zig `getWorkerUrl` closure.
pub fn configureMonacoEnvironment() !void {
    var next_closure = try WorkerUrlClosure.tryInit(&env_state);
    {
        errdefer next_closure.deinit();

        const env = try monaco.Environment.init();
        defer env.deinit();
        try env.setGlobalApi(false);
        try env.setGetWorkerUrl(&next_closure);
        try monaco.monaco_environment.set(env);
    }
    env_state.releaseClosure();
    env_state.closure = next_closure;
}

/// Mount a standalone Monaco editor inside `#<container_id>` using default TypeScript code and `vs-dark`.
pub fn mount(container_id: []const u8) !void {
    return mountWithOptions(container_id, default_code, "typescript", "vs-dark");
}

/// Mount a standalone Monaco editor inside `#<container_id>` with explicit code, language, and theme.
pub fn mountWithOptions(
    container_id: []const u8,
    initial_code: []const u8,
    language: []const u8,
    theme: []const u8,
) !void {
    const doc = try dom.document.get();
    defer doc.deinit();
    const container = (try doc.getElementById(container_id)) orelse return error.ContainerNotFound;
    defer container.deinit();

    const had_mounted_editor = active_editor != null;
    if (active_editor) |prev| {
        active_editor = null;
        defer prev.deinit();
        try prev.dispose();
    }

    const should_rollback_env = had_mounted_editor or (env_state.closure == null);
    try configureMonacoEnvironment();
    errdefer if (should_rollback_env) {
        monaco.monaco_environment.set(null) catch {};
        env_state.releaseClosure();
    };

    const editor_instance = try monaco.editor.create(
        container,
        .{
            .value = initial_code,
            .language = language,
            .theme = theme,
            .automatic_layout = true,
            .tab_size = 2,
            .minimap = .{ .enabled = false },
        },
        null,
    );
    active_editor = editor_instance;
}

/// Return whether an editor instance is currently mounted.
pub fn isMounted() bool {
    return active_editor != null;
}

/// Read the current text buffer from the mounted Monaco editor.
pub fn getValue(allocator: std.mem.Allocator) ![]const u8 {
    const ed = active_editor orelse return error.EditorNotMounted;
    return ed.getValueAlloc(allocator, null);
}

/// Replace the text buffer of the mounted Monaco editor.
pub fn setValue(code: []const u8) !void {
    const ed = active_editor orelse return error.EditorNotMounted;
    try ed.setValue(code);
}

/// Resolve a worker URL via the live `globalThis.MonacoEnvironment.getWorkerUrl` callback.
pub fn resolveWorkerUrl(
    allocator: std.mem.Allocator,
    module_id: []const u8,
    label: []const u8,
) ![]const u8 {
    const env = (try monaco.monaco_environment.get()) orelse return error.MissingMonacoEnvironment;
    defer env.deinit();
    return env.getWorkerUrlAlloc(allocator, module_id, label);
}

/// Dispose the mounted Monaco editor, clear `MonacoEnvironment`, and release all Zig handles/closures.
pub fn unmount() !void {
    var first_err: ?anyerror = null;
    if (active_editor) |ed| {
        active_editor = null;
        defer ed.deinit();
        ed.dispose() catch |err| {
            if (first_err == null) first_err = err;
        };
    }
    monaco.monaco_environment.set(null) catch |err| {
        if (first_err == null) first_err = err;
    };
    env_state.releaseClosure();
    env_state.requests = 0;
    if (first_err) |err| return err;
}

pub fn workerUrlRequests() usize {
    return env_state.requests;
}

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn activeCallbacks() u32 {
    return js.activeCallbackCount();
}
