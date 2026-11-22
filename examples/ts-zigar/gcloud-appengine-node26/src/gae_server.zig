//! `gcloud-appengine-node26` — Google App Engine Standard (`runtime: nodejs26`, Ubuntu 24.04)
//! HTTP service written in Zig 0.17 using `zigar ts` bindings for `@types/node@26`.
//!
//! Binds `0.0.0.0:$PORT` (defaulting to `8080`, or `0` for an ephemeral OS port), serves `/`,
//! `/_ah/warmup`, and `/healthz`, parses `x-cloud-trace-context` headers, emits structured
//! Google Cloud Logging JSON entries (`logging.googleapis.com/severity`, `httpRequest`, and
//! `logging.googleapis.com/trace`), and drains cleanly on `SIGTERM`.

const std = @import("std");
const zigar = @import("zigar");
const node = @import("node");
const js = zigar.js;
const http = node.http;

pub const DEFAULT_PORT: u16 = 8080;
pub const DEFAULT_HOST: []const u8 = "0.0.0.0";

var live_allocs = std.atomic.Value(usize).init(0);

const TrackingAllocator = struct {
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const ptr = zigar.mem.allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = live_allocs.fetchAdd(1, .acq_rel);
        return ptr;
    }

    fn resize(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return zigar.mem.allocator.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return zigar.mem.allocator.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn free(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        zigar.mem.allocator.rawFree(buf, alignment, ret_addr);
        _ = live_allocs.fetchSub(1, .acq_rel);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator() std.mem.Allocator {
        return .{ .ptr = undefined, .vtable = &vtable };
    }
};

const tracked_alloc = TrackingAllocator.allocator();

const RequestServer = http.ServerDefault();
const RequestResponse = http.ServerResponseDefault();

const RequestClosure = js.Closure(*ServerState, ServerState.onRequest);
const ListeningClosure = js.Closure(*ServerState, ServerState.onListening);
const ErrorClosure = js.Closure(*ServerState, ServerState.onError);
const CloseClosure = js.Closure(*ServerState, ServerState.onClosed);

const CloudTrace = struct {
    trace_id: []const u8 = "",
    span_hex_buf: [16]u8 = @splat('0'),
    raw_span_id: []const u8 = "",
    has_formatted_span: bool = false,
    sampled: bool = false,

    fn spanId(self: *const CloudTrace) []const u8 {
        if (self.has_formatted_span) return self.span_hex_buf[0..];
        return self.raw_span_id;
    }
};

fn parseCloudTraceHeader(raw_val: []const u8) CloudTrace {
    const trimmed = std.mem.trim(u8, raw_val, " \t\r\n");
    if (trimmed.len == 0) return .{};

    var main_part = trimmed;
    var sampled = false;
    if (std.mem.indexOfScalar(u8, trimmed, ';')) |semi_idx| {
        main_part = trimmed[0..semi_idx];
        const opts = trimmed[semi_idx + 1 ..];
        var it = std.mem.splitScalar(u8, opts, ';');
        while (it.next()) |opt| {
            const o = std.mem.trim(u8, opt, " \t");
            if (std.mem.eql(u8, o, "o=1")) sampled = true;
        }
    }

    if (std.mem.indexOfScalar(u8, main_part, '/')) |slash_idx| {
        const raw_span = main_part[slash_idx + 1 ..];
        var trace: CloudTrace = .{
            .trace_id = main_part[0..slash_idx],
            .raw_span_id = raw_span,
            .sampled = sampled,
        };
        if (raw_span.len > 0) {
            if (std.fmt.parseInt(u64, raw_span, 10)) |span_num| {
                _ = std.fmt.bufPrint(&trace.span_hex_buf, "{x:0>16}", .{span_num}) catch unreachable;
                trace.has_formatted_span = true;
            } else |_| {}
        }
        return trace;
    }
    return .{
        .trace_id = main_part,
        .sampled = sampled,
    };
}

fn stripQuery(raw_url: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, raw_url, '?')) |q_idx| {
        const p = raw_url[0..q_idx];
        return if (p.len == 0) "/" else p;
    }
    return if (raw_url.len == 0) "/" else raw_url;
}

fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\x08' => try out.appendSlice(alloc, "\\b"),
            '\x0c' => try out.appendSlice(alloc, "\\f"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => if (c < 0x20) {
                var esc: [6]u8 = undefined;
                const slice = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch unreachable;
                try out.appendSlice(alloc, slice);
            } else {
                try out.append(alloc, c);
            },
        }
    }
    try out.append(alloc, '"');
}

fn appendUnsigned(alloc: std.mem.Allocator, out: *std.ArrayList(u8), val: usize) !void {
    var num_buf: [32]u8 = undefined;
    const slice = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch unreachable;
    try out.appendSlice(alloc, slice);
}

fn emitConsoleLine(line: []const u8) js.CallError!void {
    const con = try node.globals.console.get();
    defer con.deinit();
    try con.log(.{line});
}

const ServerConfig = struct {
    host: []u8 = &.{},
    service: []u8 = &.{},
    version: []u8 = &.{},
    instance: []u8 = &.{},
    project: []u8 = &.{},
    node_version: []u8 = &.{},
    requested_port: u16 = DEFAULT_PORT,

    fn deinit(self: *ServerConfig, alloc: std.mem.Allocator) void {
        if (self.host.len > 0) alloc.free(self.host);
        if (self.service.len > 0) alloc.free(self.service);
        if (self.version.len > 0) alloc.free(self.version);
        if (self.instance.len > 0) alloc.free(self.instance);
        if (self.project.len > 0) alloc.free(self.project);
        if (self.node_version.len > 0) alloc.free(self.node_version);
        self.* = .{};
    }
};

fn readEnvOrDefault(alloc: std.mem.Allocator, env: anytype, key: []const u8, fallback: []const u8) ![]u8 {
    if (try env.getAlloc(alloc, key)) |val| {
        defer js.freeDecoded([]const u8, alloc, val);
        if (val.len > 0) {
            return try alloc.dupe(u8, val);
        }
    }
    return try alloc.dupe(u8, fallback);
}

fn loadServerConfig(alloc: std.mem.Allocator) !ServerConfig {
    const proc = try node.globals.process.get();
    defer proc.deinit();

    const env = try proc.env();
    defer env.deinit();

    var cfg: ServerConfig = .{};
    errdefer cfg.deinit(alloc);

    var port: u16 = DEFAULT_PORT;
    if (try env.getAlloc(alloc, "PORT")) |port_str| {
        defer js.freeDecoded([]const u8, alloc, port_str);
        if (port_str.len > 0) {
            port = std.fmt.parseInt(u16, port_str, 10) catch DEFAULT_PORT;
        }
    }
    cfg.requested_port = port;
    cfg.host = try readEnvOrDefault(alloc, env, "HOST", DEFAULT_HOST);
    cfg.service = try readEnvOrDefault(alloc, env, "GAE_SERVICE", "default");
    cfg.version = try readEnvOrDefault(alloc, env, "GAE_VERSION", "dev");
    cfg.instance = try readEnvOrDefault(alloc, env, "GAE_INSTANCE", "local");
    cfg.project = try readEnvOrDefault(alloc, env, "GOOGLE_CLOUD_PROJECT", "demo-project");

    const ver = try proc.versionAlloc(alloc);
    defer js.freeDecoded([]const u8, alloc, ver);
    cfg.node_version = try alloc.dupe(u8, ver);

    return cfg;
}

const ServerState = struct {
    server: ?RequestServer = null,
    request_closure: ?RequestClosure = null,
    listening_closure: ?ListeningClosure = null,
    error_closure: ?ErrorClosure = null,
    close_closure: ?CloseClosure = null,
    cfg: ServerConfig = .{},
    bound_port: u16 = 0,
    request_count: usize = 0,
    warmup_count: usize = 0,
    in_flight: usize = 0,
    had_error: bool = false,
    draining: bool = false,
    closed: bool = false,

    fn logLifecycleEvent(st: *const ServerState, severity: []const u8, event_name: []const u8, msg: []const u8) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(tracked_alloc);

        try line.appendSlice(tracked_alloc, "{\"severity\":");
        try appendJsonString(tracked_alloc, &line, severity);
        try line.appendSlice(tracked_alloc, ",\"logging.googleapis.com/severity\":");
        try appendJsonString(tracked_alloc, &line, severity);
        try line.appendSlice(tracked_alloc, ",\"event\":");
        try appendJsonString(tracked_alloc, &line, event_name);
        try line.appendSlice(tracked_alloc, ",\"message\":");
        try appendJsonString(tracked_alloc, &line, msg);
        try line.appendSlice(tracked_alloc, ",\"host\":");
        try appendJsonString(tracked_alloc, &line, st.cfg.host);
        try line.appendSlice(tracked_alloc, ",\"port\":");
        try appendUnsigned(tracked_alloc, &line, st.bound_port);
        try line.appendSlice(tracked_alloc, ",\"service\":");
        try appendJsonString(tracked_alloc, &line, st.cfg.service);
        try line.appendSlice(tracked_alloc, ",\"version\":");
        try appendJsonString(tracked_alloc, &line, st.cfg.version);
        try line.append(tracked_alloc, '}');

        try emitConsoleLine(line.items);
    }

    fn logHttpRequest(
        st: *const ServerState,
        severity: []const u8,
        method: []const u8,
        url: []const u8,
        status: u16,
        user_agent: []const u8,
        trace: CloudTrace,
    ) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(tracked_alloc);

        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} {s} -> {d}", .{ method, url, status }) catch "HTTP request";

        try line.appendSlice(tracked_alloc, "{\"severity\":");
        try appendJsonString(tracked_alloc, &line, severity);
        try line.appendSlice(tracked_alloc, ",\"logging.googleapis.com/severity\":");
        try appendJsonString(tracked_alloc, &line, severity);
        try line.appendSlice(tracked_alloc, ",\"message\":");
        try appendJsonString(tracked_alloc, &line, msg);
        try line.appendSlice(tracked_alloc, ",\"service\":");
        try appendJsonString(tracked_alloc, &line, st.cfg.service);
        try line.appendSlice(tracked_alloc, ",\"httpRequest\":{\"requestMethod\":");
        try appendJsonString(tracked_alloc, &line, method);
        try line.appendSlice(tracked_alloc, ",\"requestUrl\":");
        try appendJsonString(tracked_alloc, &line, url);
        try line.appendSlice(tracked_alloc, ",\"status\":");
        try appendUnsigned(tracked_alloc, &line, status);
        try line.appendSlice(tracked_alloc, ",\"userAgent\":");
        try appendJsonString(tracked_alloc, &line, user_agent);
        try line.append(tracked_alloc, '}');

        if (trace.trace_id.len > 0) {
            const full_trace = try std.fmt.allocPrint(
                tracked_alloc,
                "projects/{s}/traces/{s}",
                .{ st.cfg.project, trace.trace_id },
            );
            defer tracked_alloc.free(full_trace);

            try line.appendSlice(tracked_alloc, ",\"logging.googleapis.com/trace\":");
            try appendJsonString(tracked_alloc, &line, full_trace);
            const span_str = trace.spanId();
            if (span_str.len > 0) {
                try line.appendSlice(tracked_alloc, ",\"logging.googleapis.com/spanId\":");
                try appendJsonString(tracked_alloc, &line, span_str);
            }
            try line.appendSlice(
                tracked_alloc,
                if (trace.sampled)
                    ",\"logging.googleapis.com/trace_sampled\":true"
                else
                    ",\"logging.googleapis.com/trace_sampled\":false",
            );
        }

        try line.append(tracked_alloc, '}');
        try emitConsoleLine(line.items);
    }

    fn onRequest(
        st: *ServerState,
        req: http.IncomingMessage,
        res: RequestResponse,
    ) void {
        st.in_flight += 1;
        defer st.in_flight -= 1;

        st.handleRequest(req, res) catch {
            st.logLifecycleEvent("ERROR", "request_error", "Unhandled error while serving HTTP request") catch {};
        };
    }

    fn handleRequest(
        st: *ServerState,
        req: http.IncomingMessage,
        res: RequestResponse,
    ) !void {
        st.request_count += 1;

        var responded = false;
        errdefer if (!responded) {
            if (res.writeHead(.{500})) |hr| hr.deinit() else |_| {}
            if (res.end("{\"error\":\"Internal Server Error\"}\n")) |er| er.deinit() else |_| {}
        };

        const req_method_opt = try req.methodAlloc(tracked_alloc);
        defer if (req_method_opt) |m| js.freeDecoded([]const u8, tracked_alloc, m);
        const method = req_method_opt orelse "GET";

        const req_url_opt = try req.urlAlloc(tracked_alloc);
        defer if (req_url_opt) |u| js.freeDecoded([]const u8, tracked_alloc, u);
        const raw_url = req_url_opt orelse "/";
        const route_path = stripQuery(raw_url);

        const req_headers = try req.headers();
        defer req_headers.deinit();

        const ua_opt = try req_headers.userAgentAlloc(tracked_alloc);
        defer if (ua_opt) |ua| js.freeDecoded([]const u8, tracked_alloc, ua);
        const user_agent = ua_opt orelse "";

        const trace_hdr_opt = try req_headers.getAlloc(tracked_alloc, "x-cloud-trace-context");
        defer if (trace_hdr_opt) |th| js.freeDecoded(@TypeOf(th), tracked_alloc, th);
        const raw_trace: []const u8 = if (trace_hdr_opt) |th| switch (th) {
            .str => |s| s,
            .array => |arr| if (arr.len > 0) arr[0] else "",
        } else "";
        const trace = parseCloudTraceHeader(raw_trace);

        const is_get = std.mem.eql(u8, method, "GET");
        const is_head = std.mem.eql(u8, method, "HEAD");
        const is_known_route = std.mem.eql(u8, route_path, "/") or
            std.mem.eql(u8, route_path, "/_ah/warmup") or
            std.mem.eql(u8, route_path, "/healthz");

        var status_code: u16 = 200;
        var severity: []const u8 = "INFO";
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(tracked_alloc);

        const out_headers = try http.OutgoingHttpHeaders.init();
        defer out_headers.deinit();
        try out_headers.setContentType("application/json; charset=utf-8");
        try out_headers.set("x-appengine-service", .from(st.cfg.service));
        if (trace.trace_id.len > 0) {
            try out_headers.set("x-cloud-trace-id", .from(trace.trace_id));
        }

        if (is_known_route and !is_get and !is_head) {
            status_code = 405;
            severity = "WARNING";
            try out_headers.setAllow("GET, HEAD");
            try body.appendSlice(tracked_alloc, "{\"error\":\"Method Not Allowed\",\"allow\":\"GET, HEAD\"}\n");
        } else if (std.mem.eql(u8, route_path, "/")) {
            try body.appendSlice(tracked_alloc, "{\"status\":\"ok\",\"platform\":\"google-app-engine\",\"runtime\":\"nodejs26\",\"nodeVersion\":");
            try appendJsonString(tracked_alloc, &body, st.cfg.node_version);
            try body.appendSlice(tracked_alloc, ",\"service\":");
            try appendJsonString(tracked_alloc, &body, st.cfg.service);
            try body.appendSlice(tracked_alloc, ",\"version\":");
            try appendJsonString(tracked_alloc, &body, st.cfg.version);
            try body.appendSlice(tracked_alloc, ",\"instance\":");
            try appendJsonString(tracked_alloc, &body, st.cfg.instance);
            try body.appendSlice(tracked_alloc, ",\"project\":");
            try appendJsonString(tracked_alloc, &body, st.cfg.project);
            try body.appendSlice(tracked_alloc, ",\"requestCount\":");
            try appendUnsigned(tracked_alloc, &body, st.request_count);
            try body.appendSlice(tracked_alloc, ",\"warmupCount\":");
            try appendUnsigned(tracked_alloc, &body, st.warmup_count);
            try body.appendSlice(tracked_alloc, ",\"traceId\":");
            if (trace.trace_id.len > 0) {
                try appendJsonString(tracked_alloc, &body, trace.trace_id);
            } else {
                try body.appendSlice(tracked_alloc, "null");
            }
            try body.appendSlice(tracked_alloc, "}\n");
        } else if (std.mem.eql(u8, route_path, "/_ah/warmup")) {
            st.warmup_count += 1;
            try body.appendSlice(tracked_alloc, "{\"status\":\"warmed\",\"warmupCount\":");
            try appendUnsigned(tracked_alloc, &body, st.warmup_count);
            try body.appendSlice(tracked_alloc, ",\"service\":");
            try appendJsonString(tracked_alloc, &body, st.cfg.service);
            try body.appendSlice(tracked_alloc, "}\n");
        } else if (std.mem.eql(u8, route_path, "/healthz")) {
            try body.appendSlice(tracked_alloc, "{\"status\":\"healthy\",\"ready\":true,\"service\":");
            try appendJsonString(tracked_alloc, &body, st.cfg.service);
            try body.appendSlice(tracked_alloc, "}\n");
        } else {
            status_code = 404;
            severity = "WARNING";
            try body.appendSlice(tracked_alloc, "{\"error\":\"Not Found\",\"path\":");
            try appendJsonString(tracked_alloc, &body, route_path);
            try body.appendSlice(tracked_alloc, "}\n");
        }

        (try res.writeHead(.{ status_code, out_headers })).deinit();
        if (is_head) {
            (try res.end(null)).deinit();
        } else {
            (try res.end(body.items)).deinit();
        }
        responded = true;

        try st.logHttpRequest(severity, method, raw_url, status_code, user_agent, trace);
    }

    fn onError(st: *ServerState, err: js.Ref(js.Object)) void {
        defer err.deinit();
        st.had_error = true;
        if (!st.draining and st.bound_port == 0) {
            st.closed = true;
        }
        st.logLifecycleEvent("ERROR", "server_error", "HTTP server failed to listen or encountered socket error") catch {};
    }

    fn onClosed(st: *ServerState, err: ?js.Ref(js.Object)) void {
        if (err) |e| e.deinit();
        st.closed = true;
    }

    fn onListening(st: *ServerState) void {
        const srv = st.server orelse return;

        if (srv.addressAlloc(tracked_alloc) catch null) |addr| {
            defer js.freeDecoded(@TypeOf(addr), tracked_alloc, addr);
            switch (addr) {
                .address_info => |info| {
                    st.bound_port = @intFromFloat(info.port);
                },
                .str => {},
            }
        }

        var msg_buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "GAE server listening on http://{s}:{d}/",
            .{ st.cfg.host, st.bound_port },
        ) catch "GAE server listening";
        st.logLifecycleEvent("INFO", "server_listening", msg) catch {};
    }
};

var state: ServerState = .{};

fn detachListeners(st: *ServerState, srv: RequestServer) void {
    if (st.close_closure) |*cc| {
        if (srv.removeListener(.{ .close, cc })) |rm| rm.deinit() else |_| {}
    }
    if (st.request_closure) |*rc| {
        if (srv.removeListener(.{ .request, rc })) |rm| rm.deinit() else |_| {}
    }
    if (st.listening_closure) |*lc| {
        if (srv.removeListener(.{ .listening, lc })) |rm| rm.deinit() else |_| {}
    }
    if (st.error_closure) |*ec| {
        if (srv.removeListener(.{ .@"error", ec })) |rm| rm.deinit() else |_| {}
    }
}

fn releaseServerState(st: *ServerState) void {
    if (st.server) |srv| {
        detachListeners(st, srv);
        srv.deinit();
    }
    if (st.close_closure) |cc| cc.deinit();
    if (st.error_closure) |ec| ec.deinit();
    if (st.listening_closure) |lc| lc.deinit();
    if (st.request_closure) |rc| rc.deinit();
    st.cfg.deinit(tracked_alloc);
    st.* = .{};
}

pub fn start() !u16 {
    if (state.server != null) return error.AlreadyRunning;

    var moved_to_state = false;

    var cfg = try loadServerConfig(tracked_alloc);
    errdefer if (!moved_to_state) cfg.deinit(tracked_alloc);

    if (std.mem.indexOfScalar(u8, cfg.host, 0) != null) {
        return error.InvalidBindHost;
    }

    const req_closure = try RequestClosure.tryInit(&state);
    errdefer if (!moved_to_state) req_closure.deinit();

    const listening_closure = try ListeningClosure.tryInit(&state);
    errdefer if (!moved_to_state) listening_closure.deinit();

    const error_closure = try ErrorClosure.tryInit(&state);
    errdefer if (!moved_to_state) error_closure.deinit();

    const close_closure = try CloseClosure.tryInit(&state);
    errdefer if (!moved_to_state) close_closure.deinit();

    const srv = try http.createServer(.{&req_closure});
    errdefer if (!moved_to_state) {
        if (srv.removeListener(.{ .request, &req_closure })) |rm| rm.deinit() else |_| {}
        srv.deinit();
    };

    const requested_port = cfg.requested_port;

    state = .{
        .server = srv,
        .request_closure = req_closure,
        .listening_closure = listening_closure,
        .error_closure = error_closure,
        .close_closure = close_closure,
        .cfg = cfg,
        .bound_port = requested_port,
        .request_count = 0,
        .warmup_count = 0,
        .in_flight = 0,
        .had_error = false,
        .draining = false,
        .closed = false,
    };
    moved_to_state = true;
    errdefer releaseServerState(&state);

    (try srv.on(.{ .@"error", &state.error_closure.? })).deinit();
    (try srv.listen(.{ requested_port, state.cfg.host, &state.listening_closure.? })).deinit();

    return requested_port;
}

pub fn boundPort() u16 {
    return state.bound_port;
}

pub fn requestCount() usize {
    return state.request_count;
}

pub fn warmupCount() usize {
    return state.warmup_count;
}

pub fn inFlightCount() usize {
    return state.in_flight;
}

pub fn hadError() bool {
    return state.had_error;
}

pub fn isClosed() bool {
    return state.server == null or state.closed;
}

pub fn beginShutdown() !void {
    const srv = state.server orelse return;
    if (state.draining) return;
    state.draining = true;

    state.logLifecycleEvent("INFO", "server_stopping", "SIGTERM/shutdown received; draining HTTP server") catch {};
    try srv.closeIdleConnections();
    if (try srv.listening()) {
        (try srv.close(&state.close_closure.?)).deinit();
    } else {
        state.closed = true;
    }
}

pub fn finishShutdown(force_active: bool) !void {
    if (state.server) |srv| {
        defer releaseServerState(&state);
        if (!state.draining) {
            state.logLifecycleEvent("INFO", "server_stopping", "SIGTERM/shutdown received; draining HTTP server") catch {};
        }
        try srv.closeIdleConnections();
        if (force_active) {
            try srv.closeAllConnections();
        }
        if (!state.closed and (try srv.listening())) {
            (try srv.close(null)).deinit();
        }
    }
}

pub fn shutdown() !void {
    try finishShutdown(false);
}

pub fn activeHandles() usize {
    return js.activeHandleCount();
}

pub fn activeCallbacks() usize {
    return js.activeCallbackCount();
}

pub fn liveZigAllocs() usize {
    return live_allocs.load(.acquire);
}
