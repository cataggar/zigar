//! `node-server-hello-world` — Node.js 26 Active LTS (`@types/node@26`) HTTP server example.
//!
//! Mirrors `taggartsoftware/ts2rs/node-server-hello-world`: reads `process.env.PORT`
//! (defaulting to `3000`, or `0` for an ephemeral OS port), starts an `http.createServer`
//! responder returning `200 text/plain; charset=utf-8` `"Hello, World!\n"`, logs the
//! bound `http://127.0.0.1:<port>/` address once listening, and provides graceful
//! `shutdown()` releasing all server, listener, and closure handles.

const std = @import("std");
const zigar = @import("zigar");
const node = @import("node");
const js = zigar.js;
const http = node.http;

pub const DEFAULT_PORT: u16 = 3000;

const RequestServer = http.ServerDefault();
const RequestResponse = http.ServerResponseDefault();

const RequestClosure = js.Closure(*ServerState, ServerState.onRequest);
const ListeningClosure = js.Closure(*ServerState, ServerState.onListening);

const ServerState = struct {
    server: ?RequestServer = null,
    request_closure: ?RequestClosure = null,
    listening_closure: ?ListeningClosure = null,
    bound_port: u16 = 0,
    request_count: usize = 0,

    fn onRequest(
        st: *ServerState,
        req: http.IncomingMessage,
        res: RequestResponse,
    ) js.CallError!void {
        st.request_count += 1;

        const alloc = zigar.mem.allocator;
        const req_url = try req.urlAlloc(alloc);
        defer if (req_url) |u| js.freeDecoded([]const u8, alloc, u);

        const headers = try http.OutgoingHttpHeaders.init();
        defer headers.deinit();
        try headers.setContentType("text/plain; charset=utf-8");
        if (req_url) |path_slice| {
            try headers.set("x-request-path", .from(path_slice));
        }

        const head_res = try res.writeHead(.{ 200, headers });
        head_res.deinit();

        const body = try js.toJsRef([]const u8, "Hello, World!\n");
        defer body.deinit();

        const end_res = try res.end(.{body});
        end_res.deinit();
    }

    fn onListening(st: *ServerState) js.CallError!void {
        const srv = st.server orelse return;

        const alloc = zigar.mem.allocator;
        if (try srv.addressAlloc(alloc)) |addr| {
            defer js.freeDecoded(@TypeOf(addr), alloc, addr);
            switch (addr) {
                .address_info => |info| {
                    st.bound_port = @intFromFloat(info.port);
                },
                .str => {},
            }
        }

        var msg_buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "Server running at http://127.0.0.1:{d}/",
            .{st.bound_port},
        ) catch "Server running";

        const con = try node.globals.console.get();
        defer con.deinit();
        try con.log(.{msg});
    }
};

var state: ServerState = .{};

fn readConfiguredPort(allocator: std.mem.Allocator) !u16 {
    const proc = try node.globals.process.get();
    defer proc.deinit();

    const env = try proc.env();
    defer env.deinit();

    if (try env.getAlloc(allocator, "PORT")) |port_str| {
        defer js.freeDecoded([]const u8, allocator, port_str);
        if (port_str.len > 0) {
            return std.fmt.parseInt(u16, port_str, 10) catch DEFAULT_PORT;
        }
    }
    return DEFAULT_PORT;
}

pub fn start(allocator: std.mem.Allocator) !u16 {
    if (state.server != null) return error.AlreadyRunning;

    const requested_port = try readConfiguredPort(allocator);

    const req_closure = try RequestClosure.tryInit(&state);
    errdefer req_closure.deinit();

    const listening_closure = try ListeningClosure.tryInit(&state);
    errdefer listening_closure.deinit();

    const srv = try http.createServer(.{&req_closure});

    state = .{
        .server = srv,
        .request_closure = req_closure,
        .listening_closure = listening_closure,
        .bound_port = requested_port,
        .request_count = 0,
    };
    errdefer {
        if (srv.removeAllListenersEventName(null)) |rm| rm.deinit() else |_| {}
        srv.deinit();
        state = .{};
    }

    const listen_ref = try srv.listen(.{
        @as(f64, @floatFromInt(requested_port)),
        "127.0.0.1",
        &listening_closure,
    });
    listen_ref.deinit();

    return requested_port;
}

pub fn boundPort() u16 {
    return state.bound_port;
}

pub fn requestCount() usize {
    return state.request_count;
}

pub fn shutdown() !void {
    if (state.server) |srv| {
        defer {
            srv.deinit();
            if (state.listening_closure) |lc| lc.deinit();
            if (state.request_closure) |rc| rc.deinit();
            state = .{};
        }
        try srv.closeAllConnections();
        const closed = try srv.close(null);
        closed.deinit();
        const removed = try srv.removeAllListenersEventName(null);
        removed.deinit();
    }
}

pub fn activeHandles() usize {
    return js.activeHandleCount();
}

pub fn activeCallbacks() usize {
    return js.activeCallbackCount();
}
