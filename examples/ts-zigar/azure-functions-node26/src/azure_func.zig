const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");
const pkg = @import("azure_functions");

const js = pkg.zigar_js;
const nc = pkg.crypto;
const ntp = pkg.timers_promises;
const azure = pkg.azure_functions;

const is_wasm = builtin.cpu.arch.isWasm();

var live_allocs = std.atomic.Value(usize).init(0);

const TrackingAllocator = struct {
    const backing: std.mem.Allocator = if (is_wasm)
        std.heap.wasm_allocator
    else
        std.heap.smp_allocator;

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator() std.mem.Allocator {
        return .{ .ptr = undefined, .vtable = &vtable };
    }

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const ptr = backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        if (len > 0) _ = live_allocs.fetchAdd(1, .acq_rel);
        return ptr;
    }

    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        if (!backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (memory.len == 0 and new_len > 0) {
            _ = live_allocs.fetchAdd(1, .acq_rel);
        } else if (memory.len > 0 and new_len == 0) {
            _ = live_allocs.fetchSub(1, .acq_rel);
        }
        return true;
    }

    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const ptr = backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (memory.len == 0 and new_len > 0) {
            _ = live_allocs.fetchAdd(1, .acq_rel);
        } else if (memory.len > 0 and new_len == 0) {
            _ = live_allocs.fetchSub(1, .acq_rel);
        }
        return ptr;
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        backing.rawFree(memory, alignment, ret_addr);
        if (memory.len > 0) _ = live_allocs.fetchSub(1, .acq_rel);
    }
};

const tracked_alloc = TrackingAllocator.allocator();

pub fn activeAllocCount() usize {
    return live_allocs.load(.acquire);
}

pub fn activeJsHandleCount() usize {
    return js.activeHandleCount();
}

pub fn activeJsCallbackCount() usize {
    return js.activeCallbackCount();
}

/// Registers Azure Functions v4 HTTP triggers (`hello` and `healthz`) directly from Zig
/// via `@azure/functions` (`app.http` and `app.get`).
pub fn registerHttpTriggers(raw_handler: js.Function) !void {
    defer raw_handler.deinit();
    if (raw_handler.isNullOrUndefined()) return error.InvalidHttpHandler;

    const handler = azure.HttpHandler.fromRef(raw_handler) catch return error.InvalidHttpHandler;
    defer handler.deinit();

    const methods: [2]azure.HttpMethod = .{ .get, .post };
    try azure.app.http("hello", .{
        .methods = &methods,
        .auth_level = .anonymous,
        .route = "hello/{category?}",
        .handler = handler,
    });

    try azure.app.getHttpMethodFunctionOptions("healthz", .{
        .auth_level = .anonymous,
        .route = "healthz",
        .handler = handler,
    });
}

fn appendJsonString(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: []const u8) !void {
    try out.append(alloc, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var esc: [6]u8 = undefined;
                const s = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{ch}) catch unreachable;
                try out.appendSlice(alloc, s);
            },
            else => try out.append(alloc, ch),
        }
    }
    try out.append(alloc, '"');
}

fn emitInvocationTelemetry(
    ctx: azure.InvocationContext,
    is_warn: bool,
    invocation_id: []const u8,
    fn_name: []const u8,
    trace_parent: ?[]const u8,
    method: []const u8,
    url: []const u8,
    status_code: u16,
) void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(tracked_alloc);

    buildTelemetryJson(
        &line,
        if (is_warn) "WARN" else "INFO",
        invocation_id,
        fn_name,
        trace_parent,
        method,
        url,
        status_code,
    ) catch return;

    if (is_warn) {
        ctx.warn(.{line.items}) catch {};
    } else {
        ctx.info(.{line.items}) catch {};
    }
}

fn buildTelemetryJson(
    line: *std.ArrayList(u8),
    level: []const u8,
    invocation_id: []const u8,
    fn_name: []const u8,
    trace_parent: ?[]const u8,
    method: []const u8,
    url: []const u8,
    status_code: u16,
) !void {
    try line.appendSlice(tracked_alloc, "{\"level\":");
    try appendJsonString(line, tracked_alloc, level);
    try line.appendSlice(tracked_alloc, ",\"invocationId\":");
    try appendJsonString(line, tracked_alloc, invocation_id);
    try line.appendSlice(tracked_alloc, ",\"functionName\":");
    try appendJsonString(line, tracked_alloc, fn_name);
    if (trace_parent) |tp| {
        try line.appendSlice(tracked_alloc, ",\"traceParent\":");
        try appendJsonString(line, tracked_alloc, tp);
    }
    try line.appendSlice(tracked_alloc, ",\"method\":");
    try appendJsonString(line, tracked_alloc, method);
    try line.appendSlice(tracked_alloc, ",\"url\":");
    try appendJsonString(line, tracked_alloc, url);
    var status_buf: [16]u8 = undefined;
    const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{status_code});
    try line.appendSlice(tracked_alloc, ",\"statusCode\":");
    try line.appendSlice(tracked_alloc, status_str);
    try line.appendSlice(tracked_alloc, ",\"service\":\"ts-zigar-azure-functions-node26\"}");
}

fn computeAsyncSha256Hex(payload: []const u8) ![64]u8 {
    const subtle = try nc.subtle.get();
    defer subtle.deinit();

    const u8_in = try js.Uint8Array.fromSlice(payload);
    defer u8_in.deinit();

    const ab = try subtle.digest(.from("SHA-256"), .from(u8_in));
    defer ab.deinit();

    const digest_bytes = try ab.toOwnedSlice(tracked_alloc);
    defer tracked_alloc.free(digest_bytes);

    if (digest_bytes.len != 32) return error.UnexpectedDigestLength;

    var hex: [64]u8 = undefined;
    const lut = "0123456789abcdef";
    for (digest_bytes, 0..) |b, idx| {
        hex[idx * 2] = lut[b >> 4];
        hex[idx * 2 + 1] = lut[b & 0x0f];
    }
    return hex;
}

fn buildHttpResponse(
    status_code: u16,
    invocation_id: []const u8,
    trace_parent: ?[]const u8,
    cookie_invocation: ?[]const u8,
    json_body: []const u8,
) !js.Any {
    var out_headers = try js.Record([]const u8, []const u8).init();
    defer out_headers.deinit();
    try out_headers.set("content-type", "application/json; charset=utf-8");
    try out_headers.set("cache-control", "no-store");
    try out_headers.set("x-ms-invocation-id", invocation_id);
    if (trace_parent) |tp| {
        try out_headers.set("traceparent", tp);
    }

    var cookies_buf: [1]azure.Cookie = undefined;
    const cookies_slice: ?[]const azure.Cookie = if (cookie_invocation) |cv| blk: {
        cookies_buf[0] = .{
            .name = "zigar-invocation",
            .value = cv,
            .path = "/",
            .http_only = true,
            .same_site = .lax,
            .max_age = 3600,
        };
        break :blk cookies_buf[0..1];
    } else null;

    const resp = try azure.HttpResponse.init(.{
        .status = @floatFromInt(status_code),
        .headers = .{ .record = out_headers },
        .cookies = cookies_slice,
        .body = .{ .str = json_body },
    });
    return resp.toJsRef();
}

fn extractPathname(url: []const u8) []const u8 {
    const scheme_sep = std.mem.indexOf(u8, url, "://");
    const after_host = if (scheme_sep) |idx| blk: {
        const rest = url[idx + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        break :blk rest[slash..];
    } else url;
    const q_idx = std.mem.indexOfScalar(u8, after_host, '?') orelse after_host.len;
    return after_host[0..q_idx];
}

const worker_ns = struct {
    pub fn invokeHttp(raw_request: js.Object, raw_context: js.Object) !js.Any {
        defer raw_request.deinit();
        defer raw_context.deinit();

        if (raw_request.isNullOrUndefined()) return error.InvalidHttpRequest;
        if (raw_context.isNullOrUndefined()) return error.InvalidInvocationContext;

        const ctx = azure.InvocationContext.fromJsRef(raw_context) catch return error.InvalidInvocationContext;
        defer ctx.deinit();

        const invocation_id = ctx.invocationIdAlloc(tracked_alloc) catch return error.InvalidInvocationContext;
        defer tracked_alloc.free(invocation_id);

        const fn_name = ctx.functionNameAlloc(tracked_alloc) catch return error.InvalidInvocationContext;
        defer tracked_alloc.free(fn_name);

        const trace_ctx = ctx.traceContextAlloc(tracked_alloc) catch return error.InvalidInvocationContext;
        defer js.freeDecoded(?azure.TraceContext, tracked_alloc, trace_ctx);

        const req = azure.HttpRequest.fromJsRef(raw_request) catch return error.InvalidHttpRequest;
        defer req.deinit();

        const method = req.methodAlloc(tracked_alloc) catch return error.InvalidHttpRequest;
        defer tracked_alloc.free(method);

        const url = req.urlAlloc(tracked_alloc) catch return error.InvalidHttpRequest;
        defer tracked_alloc.free(url);

        const req_headers = req.headers() catch return error.InvalidHttpRequest;
        defer req_headers.deinit();

        const header_tp = req_headers.getAlloc(tracked_alloc, "traceparent") catch return error.InvalidHttpRequest;
        defer if (header_tp) |h| tracked_alloc.free(h);

        const client_req_id = req_headers.getAlloc(tracked_alloc, "x-ms-client-request-id") catch return error.InvalidHttpRequest;
        defer if (client_req_id) |c| tracked_alloc.free(c);

        const trace_parent: ?[]const u8 = if (trace_ctx) |tc|
            (tc.trace_parent orelse header_tp)
        else
            header_tp;

        const pathname = extractPathname(url);
        if (std.mem.eql(u8, fn_name, "healthz") or std.mem.endsWith(u8, pathname, "/healthz")) {
            var body_buf: std.ArrayList(u8) = .empty;
            defer body_buf.deinit(tracked_alloc);

            try body_buf.appendSlice(tracked_alloc, "{\"status\":\"ok\",\"service\":\"ts-zigar-azure-functions-node26\",\"runtime\":\"NODE|26\",\"functionName\":");
            try appendJsonString(&body_buf, tracked_alloc, fn_name);
            try body_buf.appendSlice(tracked_alloc, ",\"invocationId\":");
            try appendJsonString(&body_buf, tracked_alloc, invocation_id);
            try body_buf.append(tracked_alloc, '}');

            emitInvocationTelemetry(ctx, false, invocation_id, fn_name, trace_parent, method, url, 200);
            return buildHttpResponse(200, invocation_id, trace_parent, null, body_buf.items);
        }

        const req_query = req.query() catch return error.InvalidHttpRequest;
        defer req_query.deinit();

        const name_param = try req_query.getAlloc(tracked_alloc, "name");
        defer if (name_param) |np| tracked_alloc.free(np);

        const req_params = req.paramsAlloc(tracked_alloc) catch return error.InvalidHttpRequest;
        defer js.freeDecoded(azure.HttpRequestParams, tracked_alloc, req_params);

        const category_opt = try req_params.getAlloc(tracked_alloc, "category");
        defer if (category_opt) |cp| tracked_alloc.free(cp);

        const category = if (category_opt) |c| (if (c.len > 0) c else "general") else "general";
        const is_post = std.ascii.eqlIgnoreCase(method, "POST");
        const is_get = std.ascii.eqlIgnoreCase(method, "GET");

        if (!is_get and !is_post) {
            var err_buf: std.ArrayList(u8) = .empty;
            defer err_buf.deinit(tracked_alloc);
            try err_buf.appendSlice(tracked_alloc, "{\"error\":\"method_not_allowed\",\"method\":");
            try appendJsonString(&err_buf, tracked_alloc, method);
            try err_buf.appendSlice(tracked_alloc, ",\"invocationId\":");
            try appendJsonString(&err_buf, tracked_alloc, invocation_id);
            try err_buf.append(tracked_alloc, '}');

            emitInvocationTelemetry(ctx, true, invocation_id, fn_name, trace_parent, method, url, 405);
            return buildHttpResponse(405, invocation_id, trace_parent, null, err_buf.items);
        }

        var body_bytes_opt: ?[]u8 = null;
        defer if (body_bytes_opt) |b| tracked_alloc.free(b);

        if (is_post) {
            const ab = try req.arrayBuffer();
            defer ab.deinit();
            const raw_bytes = try ab.toOwnedSlice(tracked_alloc);
            body_bytes_opt = raw_bytes;

            if (std.mem.eql(u8, category, "digest") and raw_bytes.len == 0) {
                var err_buf: std.ArrayList(u8) = .empty;
                defer err_buf.deinit(tracked_alloc);
                try err_buf.appendSlice(tracked_alloc, "{\"error\":\"missing_body\",\"message\":\"POST /api/hello/digest requires a non-empty request body\",\"invocationId\":");
                try appendJsonString(&err_buf, tracked_alloc, invocation_id);
                try err_buf.append(tracked_alloc, '}');

                emitInvocationTelemetry(ctx, true, invocation_id, fn_name, trace_parent, method, url, 400);
                return buildHttpResponse(400, invocation_id, trace_parent, null, err_buf.items);
            }
        }

        const who = if (name_param) |np| (if (np.len > 0) np else "Azure Functions") else "Azure Functions";

        // Exercise Node.js 26 `node:timers/promises` + WebCrypto `crypto.subtle.digest` across async suspension
        try ntp.setTimeoutDefault(1, null, null);

        const digest_input: []const u8 = if (body_bytes_opt) |b|
            (if (b.len > 0) b else who)
        else
            who;
        const sha256_hex = try computeAsyncSha256Hex(digest_input);

        const greeting = try std.fmt.allocPrint(
            tracked_alloc,
            "Hello, {s}, from Zig on Azure Functions v4 (Node.js 26)!",
            .{who},
        );
        defer tracked_alloc.free(greeting);

        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(tracked_alloc);

        try body_buf.appendSlice(tracked_alloc, "{\"service\":\"ts-zigar-azure-functions-node26\",\"runtime\":\"NODE|26\",\"backend\":");
        try appendJsonString(&body_buf, tracked_alloc, if (is_wasm) "wasm-jspi" else "node-zigar-native");
        try body_buf.appendSlice(tracked_alloc, ",\"functionName\":");
        try appendJsonString(&body_buf, tracked_alloc, fn_name);
        try body_buf.appendSlice(tracked_alloc, ",\"invocationId\":");
        try appendJsonString(&body_buf, tracked_alloc, invocation_id);
        try body_buf.appendSlice(tracked_alloc, ",\"clientRequestId\":");
        if (client_req_id) |cid| {
            try appendJsonString(&body_buf, tracked_alloc, cid);
        } else {
            try body_buf.appendSlice(tracked_alloc, "null");
        }
        try body_buf.appendSlice(tracked_alloc, ",\"traceParent\":");
        if (trace_parent) |tp| {
            try appendJsonString(&body_buf, tracked_alloc, tp);
        } else {
            try body_buf.appendSlice(tracked_alloc, "null");
        }
        try body_buf.appendSlice(tracked_alloc, ",\"method\":");
        try appendJsonString(&body_buf, tracked_alloc, method);
        try body_buf.appendSlice(tracked_alloc, ",\"category\":");
        try appendJsonString(&body_buf, tracked_alloc, category);
        try body_buf.appendSlice(tracked_alloc, ",\"greeting\":");
        try appendJsonString(&body_buf, tracked_alloc, greeting);
        var len_buf: [24]u8 = undefined;
        const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{digest_input.len});
        try body_buf.appendSlice(tracked_alloc, ",\"payloadBytes\":");
        try body_buf.appendSlice(tracked_alloc, len_str);
        try body_buf.appendSlice(tracked_alloc, ",\"sha256\":");
        try appendJsonString(&body_buf, tracked_alloc, &sha256_hex);
        try body_buf.append(tracked_alloc, '}');

        emitInvocationTelemetry(ctx, false, invocation_id, fn_name, trace_parent, method, url, 200);
        return buildHttpResponse(200, invocation_id, trace_parent, invocation_id, body_buf.items);
    }
};

var work_queue: zigar.thread.WorkQueue(worker_ns) = .{};

fn wasmStartupNoop(_: usize) void {}
fn wasmShutdownNoop() void {}

pub const startup = if (is_wasm) wasmStartupNoop else work_queue.promisify(.startup);
pub const shutdown = if (is_wasm) wasmShutdownNoop else work_queue.promisify(.shutdown);
pub const invokeHttp = if (is_wasm) worker_ns.invokeHttp else work_queue.promisify(worker_ns.invokeHttp);
