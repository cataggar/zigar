const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");
const pkg = @import("aws_lambda");

const js = pkg.zigar_js;
const g = pkg.globals;
const nc = pkg.crypto;
const nb = pkg.buffer;
const ntp = pkg.timers_promises;
const lambda = pkg.aws_lambda_index;

const is_wasm = builtin.cpu.arch.isWasm();

var gpa: zigar.mem.TrackingAllocator = .init(zigar.mem.allocator);
const tracked_alloc = gpa.allocator();

pub fn activeAllocCount() usize {
    return gpa.activeCount();
}

pub fn activeAllocBytes() usize {
    return gpa.activeBytes();
}

pub fn activeJsHandleCount() usize {
    return js.activeHandleCount();
}

pub fn activeJsCallbackCount() usize {
    return js.activeCallbackCount();
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

fn writeCloudWatchJsonLog(
    level: []const u8,
    aws_request_id: []const u8,
    trace_id: ?[]const u8,
    method: []const u8,
    path: []const u8,
    status_code: u16,
) void {
    const proc = g.process.get() catch return;
    defer proc.deinit();

    const env = proc.env() catch return;
    defer env.deinit();

    const log_fmt = (env.getAlloc(tracked_alloc, "AWS_LAMBDA_LOG_FORMAT") catch null);
    defer if (log_fmt) |v| tracked_alloc.free(v);
    if (log_fmt == null or !std.ascii.eqlIgnoreCase(log_fmt.?, "JSON")) return;

    const con = pkg.console.console.get() catch return;
    defer con.deinit();

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(tracked_alloc);

    buildCloudWatchLogLine(&line, level, aws_request_id, trace_id, method, path, status_code) catch return;
    con.log(.{line.items}) catch {};
}

fn buildCloudWatchLogLine(
    line: *std.ArrayList(u8),
    level: []const u8,
    aws_request_id: []const u8,
    trace_id: ?[]const u8,
    method: []const u8,
    path: []const u8,
    status_code: u16,
) !void {
    try line.appendSlice(tracked_alloc, "{\"level\":");
    try appendJsonString(line, tracked_alloc, level);
    try line.appendSlice(tracked_alloc, ",\"requestId\":");
    try appendJsonString(line, tracked_alloc, aws_request_id);
    if (trace_id) |tid| {
        try line.appendSlice(tracked_alloc, ",\"traceId\":");
        try appendJsonString(line, tracked_alloc, tid);
    }
    try line.appendSlice(tracked_alloc, ",\"method\":");
    try appendJsonString(line, tracked_alloc, method);
    try line.appendSlice(tracked_alloc, ",\"path\":");
    try appendJsonString(line, tracked_alloc, path);
    var status_buf: [16]u8 = undefined;
    const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{status_code});
    try line.appendSlice(tracked_alloc, ",\"statusCode\":");
    try line.appendSlice(tracked_alloc, status_str);
    try line.appendSlice(tracked_alloc, ",\"service\":\"ts-zigar-aws-lambda-node26\"}");
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

fn decodeEventPayload(event: lambda.ApiGatewayProxyEventV2) !?[]u8 {
    const raw_body = event.body orelse return null;
    if (!event.is_base64_encoded) {
        return try tracked_alloc.dupe(u8, raw_body);
    }
    const buf_ctor = try nb.buffer.get();
    defer buf_ctor.deinit();

    const decoded_buf = try buf_ctor.fromWithImplicitCoercionStringBufferEncodingOpt(
        nb.WithImplicitCoercion([]const u8).from(raw_body),
        .base64,
    );
    defer decoded_buf.deinit();

    return try decoded_buf.toOwnedSlice(tracked_alloc);
}

fn buildJsonResult(
    status_code: u16,
    aws_request_id: []const u8,
    trace_id: ?[]const u8,
    cookie_opt: ?[]const u8,
    json_body: []const u8,
) !js.Any {
    var out_headers = try lambda.ApiGatewayProxyEventHeaders.init();
    defer out_headers.deinit();
    try out_headers.set("content-type", "application/json; charset=utf-8");
    try out_headers.set("cache-control", "no-store");
    try out_headers.set("x-aws-request-id", aws_request_id);
    if (trace_id) |tid| {
        try out_headers.set("x-amzn-trace-id", tid);
    }

    var cookie_arr: [1][]const u8 = undefined;
    const cookies_slice: ?[]const []const u8 = if (cookie_opt) |c| blk: {
        cookie_arr[0] = c;
        break :blk cookie_arr[0..1];
    } else null;

    const result: lambda.ApiGatewayProxyStructuredResultV2 = .{
        .status_code = @floatFromInt(status_code),
        .headers = out_headers.ref,
        .body = json_body,
        .is_base64_encoded = false,
        .cookies = cookies_slice,
    };
    return try result.toJsRef();
}

const worker_ns = struct {
    pub fn invoke(raw_event: js.Object, raw_context: js.Object) !js.Any {
        defer raw_event.deinit();
        defer raw_context.deinit();

        if (raw_event.isNullOrUndefined()) return error.InvalidLambdaEvent;
        if (raw_context.isNullOrUndefined()) return error.InvalidLambdaContext;

        const ctx = lambda.Context.fromJsRef(raw_context) catch return error.InvalidLambdaContext;
        defer ctx.deinit();

        const aws_request_id = ctx.awsRequestIdAlloc(tracked_alloc) catch return error.InvalidLambdaContext;
        defer tracked_alloc.free(aws_request_id);

        const fn_name = ctx.functionNameAlloc(tracked_alloc) catch return error.InvalidLambdaContext;
        defer tracked_alloc.free(fn_name);

        const fn_version = ctx.functionVersionAlloc(tracked_alloc) catch return error.InvalidLambdaContext;
        defer tracked_alloc.free(fn_version);

        const mem_limit_mb = ctx.memoryLimitInMbAlloc(tracked_alloc) catch return error.InvalidLambdaContext;
        defer tracked_alloc.free(mem_limit_mb);

        const remaining_ms = ctx.getRemainingTimeInMillis() catch return error.InvalidLambdaContext;

        const event = lambda.ApiGatewayProxyEventV2.fromJsRefAlloc(tracked_alloc, raw_event) catch return error.InvalidLambdaEvent;
        defer js.freeDecoded(lambda.ApiGatewayProxyEventV2, tracked_alloc, event);

        const method = event.request_context.http.method;
        const path = event.raw_path;
        const api_request_id = event.request_context.request_id;

        var trace_id = try event.headers.getAlloc(tracked_alloc, "x-amzn-trace-id");
        if (trace_id == null) {
            trace_id = try event.headers.getAlloc(tracked_alloc, "X-Amzn-Trace-Id");
        }
        defer if (trace_id) |tid| tracked_alloc.free(tid);

        if (std.mem.eql(u8, path, "/healthz") and std.mem.eql(u8, method, "GET")) {
            var body_buf: std.ArrayList(u8) = .empty;
            defer body_buf.deinit(tracked_alloc);

            try body_buf.appendSlice(tracked_alloc, "{\"status\":\"ok\",\"service\":\"ts-zigar-aws-lambda-node26\",\"awsRequestId\":");
            try appendJsonString(&body_buf, tracked_alloc, aws_request_id);
            var rem_buf: [32]u8 = undefined;
            const rem_str = try std.fmt.bufPrint(&rem_buf, "{d:.0}", .{remaining_ms});
            try body_buf.appendSlice(tracked_alloc, ",\"remainingTimeMs\":");
            try body_buf.appendSlice(tracked_alloc, rem_str);
            try body_buf.append(tracked_alloc, '}');

            writeCloudWatchJsonLog("INFO", aws_request_id, trace_id, method, path, 200);
            return buildJsonResult(200, aws_request_id, trace_id, null, body_buf.items);
        }

        const is_root_get = std.mem.eql(u8, path, "/") and std.mem.eql(u8, method, "GET");
        const is_digest_post = std.mem.eql(u8, path, "/digest") and std.mem.eql(u8, method, "POST");

        if (is_root_get or is_digest_post) {
            const payload_opt = try decodeEventPayload(event);
            defer if (payload_opt) |p| tracked_alloc.free(p);

            if (is_digest_post and (payload_opt == null or payload_opt.?.len == 0)) {
                var err_buf: std.ArrayList(u8) = .empty;
                defer err_buf.deinit(tracked_alloc);
                try err_buf.appendSlice(tracked_alloc, "{\"error\":\"missing_body\",\"message\":\"POST /digest requires a non-empty request body\",\"awsRequestId\":");
                try appendJsonString(&err_buf, tracked_alloc, aws_request_id);
                try err_buf.append(tracked_alloc, '}');

                writeCloudWatchJsonLog("WARN", aws_request_id, trace_id, method, path, 400);
                return buildJsonResult(400, aws_request_id, trace_id, null, err_buf.items);
            }

            var name_param: ?[]const u8 = null;
            if (event.query_string_parameters) |qsp| {
                name_param = try qsp.getAlloc(tracked_alloc, "name");
            }
            defer if (name_param) |np| tracked_alloc.free(np);

            const who = if (name_param) |np| (if (np.len > 0) np else "AWS Lambda") else "AWS Lambda";

            // Exercise Node.js 26 `node:timers/promises` + WebCrypto `crypto.subtle.digest` across async suspension
            try ntp.setTimeoutDefault(1, null, null);

            const digest_input = payload_opt orelse who;
            const sha256_hex = try computeAsyncSha256Hex(digest_input);

            const greeting = try std.fmt.allocPrint(tracked_alloc, "Hello, {s}, from Zig on AWS Lambda nodejs26.x!", .{who});
            defer tracked_alloc.free(greeting);

            const cookie_line = try std.fmt.allocPrint(
                tracked_alloc,
                "zigar-request={s}; Path=/; HttpOnly; SameSite=Lax",
                .{aws_request_id},
            );
            defer tracked_alloc.free(cookie_line);

            var body_buf: std.ArrayList(u8) = .empty;
            defer body_buf.deinit(tracked_alloc);

            try body_buf.appendSlice(tracked_alloc, "{\"service\":\"ts-zigar-aws-lambda-node26\",\"runtime\":\"nodejs26.x\",\"backend\":");
            try appendJsonString(&body_buf, tracked_alloc, if (is_wasm) "wasm-jspi" else "node-zigar-native");
            try body_buf.appendSlice(tracked_alloc, ",\"functionName\":");
            try appendJsonString(&body_buf, tracked_alloc, fn_name);
            try body_buf.appendSlice(tracked_alloc, ",\"functionVersion\":");
            try appendJsonString(&body_buf, tracked_alloc, fn_version);
            try body_buf.appendSlice(tracked_alloc, ",\"memoryLimitInMB\":");
            try appendJsonString(&body_buf, tracked_alloc, mem_limit_mb);
            try body_buf.appendSlice(tracked_alloc, ",\"awsRequestId\":");
            try appendJsonString(&body_buf, tracked_alloc, aws_request_id);
            try body_buf.appendSlice(tracked_alloc, ",\"apiRequestId\":");
            try appendJsonString(&body_buf, tracked_alloc, api_request_id);
            try body_buf.appendSlice(tracked_alloc, ",\"traceId\":");
            if (trace_id) |tid| {
                try appendJsonString(&body_buf, tracked_alloc, tid);
            } else {
                try body_buf.appendSlice(tracked_alloc, "null");
            }
            try body_buf.appendSlice(tracked_alloc, ",\"method\":");
            try appendJsonString(&body_buf, tracked_alloc, method);
            try body_buf.appendSlice(tracked_alloc, ",\"path\":");
            try appendJsonString(&body_buf, tracked_alloc, path);
            try body_buf.appendSlice(tracked_alloc, ",\"greeting\":");
            try appendJsonString(&body_buf, tracked_alloc, greeting);
            var len_buf: [24]u8 = undefined;
            const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{digest_input.len});
            try body_buf.appendSlice(tracked_alloc, ",\"payloadBytes\":");
            try body_buf.appendSlice(tracked_alloc, len_str);
            try body_buf.appendSlice(tracked_alloc, ",\"sha256\":");
            try appendJsonString(&body_buf, tracked_alloc, &sha256_hex);
            var rem_buf: [32]u8 = undefined;
            const rem_str = try std.fmt.bufPrint(&rem_buf, "{d:.0}", .{remaining_ms});
            try body_buf.appendSlice(tracked_alloc, ",\"remainingTimeMs\":");
            try body_buf.appendSlice(tracked_alloc, rem_str);
            try body_buf.append(tracked_alloc, '}');

            writeCloudWatchJsonLog("INFO", aws_request_id, trace_id, method, path, 200);
            return buildJsonResult(200, aws_request_id, trace_id, cookie_line, body_buf.items);
        }

        var nf_buf: std.ArrayList(u8) = .empty;
        defer nf_buf.deinit(tracked_alloc);
        try nf_buf.appendSlice(tracked_alloc, "{\"error\":\"not_found\",\"path\":");
        try appendJsonString(&nf_buf, tracked_alloc, path);
        try nf_buf.appendSlice(tracked_alloc, ",\"awsRequestId\":");
        try appendJsonString(&nf_buf, tracked_alloc, aws_request_id);
        try nf_buf.append(tracked_alloc, '}');

        writeCloudWatchJsonLog("WARN", aws_request_id, trace_id, method, path, 404);
        return buildJsonResult(404, aws_request_id, trace_id, null, nf_buf.items);
    }
};

var work_queue: zigar.thread.WorkQueue(worker_ns) = .{};

fn wasmStartupNoop(_: usize) void {}
fn wasmShutdownNoop() void {}

pub const startup = if (is_wasm) wasmStartupNoop else work_queue.promisify(.startup);
pub const shutdown = if (is_wasm) wasmShutdownNoop else work_queue.promisify(.shutdown);
pub const invoke = if (is_wasm) worker_ns.invoke else work_queue.promisify(worker_ns.invoke);
