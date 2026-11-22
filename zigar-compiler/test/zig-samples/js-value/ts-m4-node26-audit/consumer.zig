const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");
const node = @import("generated/root.zig");

const js = node.zigar_js;
const nhttp = node.http;
const nsql = node.sqlite;
const ns = node.stream;
const nsc = node.stream_consumers;
const nw = node.stream_web;
const ne = node.events;
const nfsp = node.fs_promises;
const np = node.path;

const is_wasm = builtin.cpu.arch.isWasm();

comptime {
    if (!std.mem.eql(u8, nhttp.zigar_js.wire_specifier, "node:http")) {
        @compileError("expected canonical node:http wire_specifier");
    }
    if (!std.mem.eql(u8, nsql.zigar_js.wire_specifier, "node:sqlite")) {
        @compileError("expected canonical node:sqlite wire_specifier");
    }
    _ = nw.ReadableStream(u8);
    if (!@hasDecl(js.InstanceType(@TypeOf(nhttp.web_socket).ValueType), "close")) {
        @compileError("expected http.web_socket ConstructorOf(WebSocket) instance to expose .close");
    }
}

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
};

var tracking_state: u8 = 0;
const tracked_alloc: std.mem.Allocator = .{
    .ptr = @ptrCast(&tracking_state),
    .vtable = &TrackingAllocator.vtable,
};

pub fn activeHandles() usize {
    return zigar.js.activeHandleCount();
}

pub fn activeCallbacks() usize {
    return zigar.js.activeCallbackCount();
}

pub fn liveZigAllocs() usize {
    return live_allocs.load(.monotonic);
}

pub fn hasPendingCapturedError() bool {
    if (zigar.js.takeLastError()) |err_obj| {
        err_obj.deinit();
        return true;
    }
    return false;
}

fn checkInvariants(handles_before: usize, cbs_before: usize, allocs_before: usize) !void {
    if (js.activeHandleCount() != handles_before) return error.Unexpected;
    if (js.activeCallbackCount() != cbs_before) return error.Unexpected;
    if (live_allocs.load(.acquire) != allocs_before) return error.Unexpected;
}

/// Exercises unfiltered 121-file `@types/node@26` `-s "node:="` bindings synchronously:
/// - `node.http.max_header_size` & `node.http.web_socket` (`typeof import("undici-types").WebSocket` -> `ConstructorOf`)
/// - `node.sqlite.DatabaseSync` (`[Symbol.dispose]`) + `SQLTagStore` (`TemplateStringsArray` -> `[]const []const u8`)
pub fn exerciseSyncM4Audit(out_alloc: std.mem.Allocator) ![]u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    // 1. `node.http.max_header_size` & `node.http.web_socket` (`ConstructorOf(WebSocket)`)
    {
        const max_hdr = try nhttp.max_header_size.get();
        if (!(max_hdr >= 8192.0)) {
            return out_alloc.dupe(u8, "fail:http_max_header_size");
        }
        const ws_ctor = try nhttp.web_socket.get();
        defer ws_ctor.deinit();
    }

    // 2. `node.sqlite.DatabaseSync` (`[Symbol.dispose]`) + `SQLTagStore` (`TemplateStringsArray`)
    {
        const db = try nsql.DatabaseSync.init(.{ .str = ":memory:" }, null);
        defer db.dispose();

        try db.exec("CREATE TABLE audit_items (id INTEGER PRIMARY KEY, label TEXT);");

        const tag = try db.createTagStore(null);
        defer tag.deinit();

        const chg = try tag.runAlloc(
            tracked_alloc,
            &.{ "INSERT INTO audit_items (label) VALUES (", ")" },
            .{@as(nsql.SqlInputValue, .{ .str = "m4-tag-ok" })},
        );
        defer js.freeDecoded(nsql.StatementResultingChanges, tracked_alloc, chg);

        const chg_count: f64 = switch (chg.changes) {
            .num => |n| n,
            .bigint => |b| @floatFromInt(b),
        };
        if (chg_count != 1.0) {
            return out_alloc.dupe(u8, "fail:tag_changes");
        }

        const rows = try tag.allAlloc(
            tracked_alloc,
            &.{"SELECT label FROM audit_items ORDER BY id"},
            .{},
        );
        defer js.freeDecoded(@TypeOf(rows), tracked_alloc, rows);
        if (rows.len != 1) {
            return std.fmt.allocPrint(out_alloc, "fail:tag_rows:{d}", .{rows.len});
        }

        const label_opt = (try rows[0].getAlloc(tracked_alloc, "label")) orelse
            return out_alloc.dupe(u8, "fail:tag_no_label");
        defer js.freeDecoded(nsql.SqlOutputValue, tracked_alloc, label_opt);
        const label_val = label_opt orelse return out_alloc.dupe(u8, "fail:tag_null_label");
        switch (label_val) {
            .str => |s| if (!std.mem.eql(u8, s, "m4-tag-ok")) return out_alloc.dupe(u8, "fail:tag_bad_label"),
            else => return out_alloc.dupe(u8, "fail:tag_label_tag"),
        }
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return out_alloc.dupe(u8, "sync-m4-audit-ok");
}

const HttpLoadCallbacks = struct {
    const State = struct {
        hits: usize = 0,
    };

    fn onRequest(state: *State, req: nhttp.IncomingMessage, res: nhttp.ServerResponse(nhttp.IncomingMessage)) js.CallError!void {
        state.hits += 1;
        const url_opt = try req.urlAlloc(tracked_alloc);
        defer if (url_opt) |u| tracked_alloc.free(u);
        const path_str = url_opt orelse "/";

        var reply_buf: [128]u8 = undefined;
        const reply = std.fmt.bufPrint(&reply_buf, "m4-load:{d}:{s}", .{ state.hits, path_str }) catch return error.Unexpected;
        const chunk_ref = try js.toJsRef([]const u8, reply);
        defer chunk_ref.deinit();
        const r_end = try res.endWithChunk(chunk_ref, null);
        r_end.deinit();
    }
};

const worker_ns = struct {
    /// M4.2c Load & Memory Safety Audit:
    /// 1. 25 sequential loopback HTTP request/response cycles through a Zig `Closure` `RequestListener`.
    /// 2. 20 sequential `fs/promises.open` + `FileHandle.asyncDispose()` (`[Symbol.asyncDispose]`) cycles.
    /// 3. 20 sequential `stream.Readable.from` + `Readable.asyncIterator()` multi-chunk stream cycles.
    /// Verifies zero handle leaks, zero callback leaks, and zero Zig allocator leaks after completion.
    pub fn exerciseAsyncM4LoadAudit(out_alloc: std.mem.Allocator, tmp_base: []const u8) ![]u8 {
        const handles_before = js.activeHandleCount();
        const cbs_before = js.activeCallbackCount();
        const allocs_before = live_allocs.load(.acquire);

        // 1. 25-request HTTP loopback load test
        {
            var state = HttpLoadCallbacks.State{};
            var req_cl = try js.Closure(*HttpLoadCallbacks.State, HttpLoadCallbacks.onRequest).tryInit(&state);
            defer req_cl.deinit();

            const srv = try nhttp.createServer(.{&req_cl});
            defer srv.deinit();

            const listen_prom = try ne.oncePromise(.{ srv.as(ne.EventEmitter(js.Any)), "listening", null });
            defer listen_prom.deinit();
            const l_self = try srv.listenWithHostname(0, "127.0.0.1", null);
            l_self.deinit();
            const listen_args = try listen_prom.awaitAlloc(tracked_alloc);
            js.freeDecoded([]const js.Any, tracked_alloc, listen_args);

            const addr_opt = try srv.addressAlloc(tracked_alloc);
            defer js.freeDecoded(@TypeOf(addr_opt), tracked_alloc, addr_opt);
            const port = switch (addr_opt orelse return out_alloc.dupe(u8, "fail:load_no_addr")) {
                .address_info => |ai| ai.port,
                .str => return out_alloc.dupe(u8, "fail:load_str_addr"),
            };
            const port_u32: u32 = @intFromFloat(port);

            const total_reqs: usize = 25;
            var i: usize = 0;
            while (i < total_reqs) : (i += 1) {
                const url_str = try std.fmt.allocPrint(tracked_alloc, "http://127.0.0.1:{d}/req-{d}", .{ port_u32, i });
                defer tracked_alloc.free(url_str);

                const client_req = try nhttp.requestCallback(.{ .str = url_str }, null);
                defer client_req.deinit();
                const resp_prom = try ne.oncePromise(.{ client_req.as(ne.EventEmitter(js.Any)), "response", null });
                defer resp_prom.deinit();
                const req_end = try client_req.end(null);
                req_end.deinit();
                const resp_args = try resp_prom.awaitAlloc(tracked_alloc);
                defer js.freeDecoded([]const js.Any, tracked_alloc, resp_args);

                const incoming = try nhttp.IncomingMessage.fromJsRef(resp_args[0]);
                defer incoming.deinit();
                if ((try incoming.statusCode()) != 200) {
                    return out_alloc.dupe(u8, "fail:load_http_status");
                }
                const body = try nsc.textAlloc(tracked_alloc, .from(incoming));
                defer tracked_alloc.free(body);

                var expected_buf: [128]u8 = undefined;
                const expected = try std.fmt.bufPrint(&expected_buf, "m4-load:{d}:/req-{d}", .{ i + 1, i });
                if (!std.mem.eql(u8, body, expected)) {
                    return std.fmt.allocPrint(out_alloc, "fail:load_http_body:{s}", .{body});
                }
            }
            if (state.hits != total_reqs) {
                return out_alloc.dupe(u8, "fail:load_http_hits");
            }

            try srv.closeAllConnections();
            const close_prom = try ne.oncePromise(.{ srv.as(ne.EventEmitter(js.Any)), "close", null });
            defer close_prom.deinit();
            const c_self = try srv.close(null);
            c_self.deinit();
            const close_args = try close_prom.awaitAlloc(tracked_alloc);
            js.freeDecoded([]const js.Any, tracked_alloc, close_args);
            const rm_self = try srv.as(ne.EventEmitter(js.Any)).removeAllListeners([]const u8, null);
            rm_self.deinit();
        }

        // 2. 20-iteration `FileHandle.asyncDispose()` (`[Symbol.asyncDispose]`) & `Readable` stream loop
        {
            const prefix = try np.joinAlloc(tracked_alloc, .{ tmp_base, "audit-59-" });
            defer tracked_alloc.free(prefix);
            const dir_path = try nfsp.mkdtempPrefixStringOptionsObjectEncodingOptionsOrBufferEncodingOptReturningStringAlloc(tracked_alloc, prefix, null);
            defer tracked_alloc.free(dir_path);

            const fpath = try np.joinAlloc(tracked_alloc, .{ dir_path, "audit.txt" });
            defer tracked_alloc.free(fpath);
            try nfsp.writeFile(.{ .path_like = .{ .str = fpath } }, .{ .str = "audit-payload-59" }, null);

            var iter: usize = 0;
            while (iter < 20) : (iter += 1) {
                {
                    const fh = try nfsp.open(.{ .str = fpath }, .{ .str = "r" }, null);
                    defer fh.asyncDispose();
                    if (!((try fh.fd()) >= 0)) return out_alloc.dupe(u8, "fail:load_fh_fd");
                }

                {
                    const c1 = try js.toJsRef([]const u8, "chunk-a:");
                    defer c1.deinit();
                    const c2 = try js.toJsRef([]const u8, "chunk-b:");
                    defer c2.deinit();
                    const c3 = try js.toJsRef([]const u8, "chunk-c");
                    defer c3.deinit();

                    const r_stream = try ns.Readable.from(.{ .iterable = &.{ c1, c2, c3 } }, null);
                    defer r_stream.deinit();
                    const ait = try r_stream.asyncIterator();
                    defer ait.deinit();

                    var total_bytes: usize = 0;
                    while (try ait.next()) |chunk_any| {
                        defer chunk_any.deinit();
                        const s = try js.fromJsRefAlloc([]const u8, tracked_alloc, chunk_any);
                        defer tracked_alloc.free(s);
                        total_bytes += s.len;
                    }
                    if (total_bytes != "chunk-a:chunk-b:chunk-c".len) {
                        return out_alloc.dupe(u8, "fail:load_stream_bytes");
                    }
                }
            }

            try nfsp.rm(.{ .str = dir_path }, .{ .recursive = true, .force = true });
        }

        try checkInvariants(handles_before, cbs_before, allocs_before);
        return out_alloc.dupe(u8, "async-m4-load-audit-ok");
    }
};

fn wasmStartupNoop(_: usize) void {}
fn wasmShutdownNoop() void {}

var work_queue: if (is_wasm) void else zigar.thread.WorkQueue(worker_ns) = if (is_wasm) {} else .{};

pub const startup = if (is_wasm) wasmStartupNoop else work_queue.promisify(.startup);
pub const shutdown = if (is_wasm) wasmShutdownNoop else work_queue.promisify(.shutdown);
pub const runAsyncM4LoadAudit = if (is_wasm) worker_ns.exerciseAsyncM4LoadAudit else work_queue.promisify(worker_ns.exerciseAsyncM4LoadAudit);
