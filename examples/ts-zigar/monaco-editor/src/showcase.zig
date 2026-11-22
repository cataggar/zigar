//! `monaco-editor` — Browser DOM subset + `monaco-editor` (`monaco.d.ts`) Zig 0.17 showcase.
//!
//! Exercises generated `@import("web").dom` and `@import("web").monaco` bindings across:
//! - `MonacoEnvironment` (`Environment.init()`, `setGetWorkerUrl`, `setGetWorker`, `monaco_environment.set/get`)
//! - Browser DOM globals (`dom.window`, `dom.document.getElementById`, `dom.Worker.init`)
//! - Real Monaco Editor primitives (`Uri`, `Range`, `Position`, `Selection`, `KeyMod`, `KeyCode`, `MarkerSeverity`)
//! - `monaco.languages.register` / `getLanguages` and `monaco.editor.create` / `getValue` / `setValue` / `dispose`
//! - Explicit handle & persistent closure cleanup (`shutdown()`, `activeHandles()`, `activeCallbacks()`)

const std = @import("std");
const zigar = @import("zigar");
const web = @import("web");
const dom = web.dom;
const monaco = web.monaco;
const js = web.zigar_js;

const WorkerUrlClosure = js.Closure(*WorkerEnvState, WorkerEnvState.getWorkerUrl);
const WorkerFactoryClosure = js.Closure(*WorkerEnvState, WorkerEnvState.getWorker);

const WorkerEnvState = struct {
    url_closure: ?WorkerUrlClosure = null,
    worker_closure: ?WorkerFactoryClosure = null,
    url_requests: usize = 0,
    worker_requests: usize = 0,

    fn getWorkerUrl(self: *WorkerEnvState, _: []const u8, label: []const u8) []const u8 {
        self.url_requests += 1;
        if (std.mem.eql(u8, label, "typescript") or std.mem.eql(u8, label, "javascript")) {
            return "./ts.worker.js";
        }
        if (std.mem.eql(u8, label, "json")) {
            return "./json.worker.js";
        }
        if (std.mem.eql(u8, label, "css") or std.mem.eql(u8, label, "scss") or std.mem.eql(u8, label, "less")) {
            return "./css.worker.js";
        }
        if (std.mem.eql(u8, label, "html") or std.mem.eql(u8, label, "handlebars") or std.mem.eql(u8, label, "razor")) {
            return "./html.worker.js";
        }
        return "./editor.worker.js";
    }

    fn getWorker(self: *WorkerEnvState, _: []const u8, label: []const u8) js.CallError!dom.Worker {
        self.worker_requests += 1;
        const url = if (std.mem.eql(u8, label, "typescript") or std.mem.eql(u8, label, "javascript"))
            "./ts.worker.js"
        else if (std.mem.eql(u8, label, "json"))
            "./json.worker.js"
        else
            "./editor.worker.js";
        return dom.Worker.init(.{ .str = url }, .{ .name = label, .@"type" = .module });
    }

    fn reset(self: *WorkerEnvState) void {
        if (self.url_closure) |*c| {
            c.deinit();
            self.url_closure = null;
        }
        if (self.worker_closure) |*c| {
            c.deinit();
            self.worker_closure = null;
        }
    }
};

var env_state: WorkerEnvState = .{};

pub const ShowcaseSummary = struct {
    container_id: []const u8,
    uri_scheme: []const u8,
    uri_path: []const u8,
    range_contains_cursor: bool,
    selection_text: []const u8,
    save_chord: f64,
    error_severity: i32,
    registered_zig_language: bool,
    initial_length: usize,
    final_value: []const u8,
    worker_url_typescript: []const u8,
    worker_url_requests: usize,
    worker_factory_requests: usize,
};

/// Install `globalThis.MonacoEnvironment` with a persistent `getWorkerUrl` Zig closure.
pub fn configureWorkerUrlEnvironment() !void {
    var new_closure = try WorkerUrlClosure.tryInit(&env_state);
    {
        errdefer new_closure.deinit();

        const env = try monaco.Environment.init();
        defer env.deinit();
        try env.setGlobalApi(false);
        try env.setBaseUrl("./vs");
        try env.setGetWorkerUrl(&new_closure);
        try monaco.monaco_environment.set(env);
    }
    env_state.reset();
    env_state.url_closure = new_closure;
}

/// Install `globalThis.MonacoEnvironment` with a persistent `getWorker` Zig factory closure.
pub fn configureWorkerFactoryEnvironment() !void {
    var new_closure = try WorkerFactoryClosure.tryInit(&env_state);
    {
        errdefer new_closure.deinit();

        const env = try monaco.Environment.init();
        defer env.deinit();
        try env.setGlobalApi(false);
        try env.setGetWorker(&new_closure);
        try monaco.monaco_environment.set(env);
    }
    env_state.reset();
    env_state.worker_closure = new_closure;
}

/// Run an end-to-end Monaco + DOM workflow and return a Zig summary value.
pub fn runEditorWorkflow(
    allocator: std.mem.Allocator,
    container_id: []const u8,
    initial_code: []const u8,
    updated_code: []const u8,
) !ShowcaseSummary {
    // 1. Configure `MonacoEnvironment` with `getWorkerUrl` and verify roundtrip via `monaco_environment.get()`
    try configureWorkerUrlEnvironment();
    const worker_url_ts = blk: {
        const current_env = (try monaco.monaco_environment.get()) orelse return error.MissingMonacoEnvironment;
        defer current_env.deinit();
        break :blk try current_env.getWorkerUrlAlloc(allocator, "workerMain.js", "typescript");
    };
    errdefer allocator.free(worker_url_ts);

    // 2. Also verify `setGetWorker` (`dom.Worker` construction) and restore `getWorkerUrl`
    try configureWorkerFactoryEnvironment();
    {
        const factory_env = (try monaco.monaco_environment.get()) orelse return error.MissingMonacoEnvironment;
        defer factory_env.deinit();
        const worker_union = try factory_env.getWorker("workerMain.js", "typescript");
        switch (worker_union) {
            .worker => |w| w.deinit(),
            .promise => |p| p.deinit(),
        }
    }
    try configureWorkerUrlEnvironment();

    // 3. Access `dom.window` and `dom.document.getElementById(container_id)`
    const win = try dom.window.get();
    win.deinit();

    const doc = try dom.document.get();
    defer doc.deinit();
    const container = (try doc.getElementById(container_id)) orelse return error.ContainerNotFound;
    defer container.deinit();
    const resolved_id = try container.idAlloc(allocator);
    errdefer allocator.free(resolved_id);

    // 4. Exercise real Monaco `Uri`, `Position`, `Range`, `Selection`, `KeyMod`, `KeyCode`, and `MarkerSeverity`
    const uri = try monaco.Uri.parse("file:///workspace/src/main.ts", true);
    defer uri.deinit();
    const uri_scheme = try uri.schemeAlloc(allocator);
    errdefer allocator.free(uri_scheme);
    const uri_path = try uri.pathAlloc(allocator);
    errdefer allocator.free(uri_path);

    const pos = try monaco.Position.init(2, 5);
    defer pos.deinit();
    const range = try monaco.Range.init(1, 1, 3, 20);
    defer range.deinit();
    const contains_cursor = !(try range.isEmpty()) and
        try range.containsPosition(.{ .line_number = 2, .column = 5 });

    const sel = try monaco.Selection.init(1, 1, 1, 14);
    defer sel.deinit();
    const selection_text = try sel.toStringAlloc(allocator);
    errdefer allocator.free(selection_text);

    const ctrl_cmd = try monaco.KeyMod.ctrl_cmd.get();
    const shift = try monaco.KeyMod.shift.get();
    const key_s: f64 = @floatFromInt(@intFromEnum(monaco.KeyCode.key_s));
    const save_chord = try monaco.KeyMod.chord(ctrl_cmd + shift, ctrl_cmd + key_s);

    // 5. Register a custom language via `monaco.languages` and query registered languages
    try monaco.languages.register(.{
        .id = "zig",
        .extensions = &.{".zig"},
        .aliases = &.{ "Zig", "zig" },
    });
    const langs = try monaco.languages.getLanguagesAlloc(zigar.mem.allocator);
    defer js.freeDecoded(@TypeOf(langs), zigar.mem.allocator, langs);
    var found_zig = false;
    for (langs) |lang| {
        if (std.mem.eql(u8, lang.id, "zig")) {
            found_zig = true;
            break;
        }
    }

    // 6. Create standalone Monaco editor on `#container`, inspect/update buffer, and dispose
    const editor_instance = try monaco.editor.create(
        container,
        .{
            .value = initial_code,
            .language = "typescript",
            .theme = "vs-dark",
            .automatic_layout = true,
            .tab_size = 2,
            .read_only = false,
            .minimap = .{ .enabled = false },
        },
        null,
    );
    defer editor_instance.deinit();

    const current_val = try editor_instance.getValueAlloc(zigar.mem.allocator, null);
    const initial_len = current_val.len;
    js.freeDecoded([]const u8, zigar.mem.allocator, current_val);

    try editor_instance.setValue(updated_code);
    const final_value = try editor_instance.getValueAlloc(allocator, null);
    errdefer allocator.free(final_value);

    try editor_instance.dispose();

    return .{
        .container_id = resolved_id,
        .uri_scheme = uri_scheme,
        .uri_path = uri_path,
        .range_contains_cursor = contains_cursor,
        .selection_text = selection_text,
        .save_chord = save_chord,
        .error_severity = @intFromEnum(monaco.MarkerSeverity.@"error"),
        .registered_zig_language = found_zig,
        .initial_length = initial_len,
        .final_value = final_value,
        .worker_url_typescript = worker_url_ts,
        .worker_url_requests = env_state.url_requests,
        .worker_factory_requests = env_state.worker_requests,
    };
}

/// Clear `globalThis.MonacoEnvironment` and release all retained Zig worker closures.
pub fn shutdown() !void {
    try monaco.monaco_environment.set(null);
    env_state.reset();
    env_state.url_requests = 0;
    env_state.worker_requests = 0;
}

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn activeCallbacks() u32 {
    return js.activeCallbackCount();
}
