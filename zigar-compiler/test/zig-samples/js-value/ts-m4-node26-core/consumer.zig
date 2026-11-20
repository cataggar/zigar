const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const g = gen.globals;
const nb = gen.node_buffer;
const ne = gen.node_events;
const nfs = gen.node_fs;
const npath = gen.node_path;

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

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

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn activeCallbacks() u32 {
    return js.activeCallbackCount();
}

pub fn liveZigAllocs() usize {
    return live_allocs.load(.acquire);
}

pub fn hasPendingCapturedError() bool {
    return js.hasLastError();
}

fn checkInvariants(handles_before: u32, cbs_before: u32, allocs_before: usize) !void {
    if (js.activeHandleCount() != handles_before) return error.Unexpected;
    if (js.activeCallbackCount() != cbs_before) return error.Unexpected;
    if (live_allocs.load(.acquire) != allocs_before) return error.Unexpected;
    if (js.hasLastError()) return error.Unexpected;
}

/// Exercises synchronous Node.js 26 globals (`process`, `console`, `Buffer`, `URL`, `URLSearchParams`,
/// `TextEncoder`, `TextDecoder`, `AbortController`, `crypto`, `performance`, `structuredClone`) and
/// canonical `node:*` built-in modules (`node:buffer`, `node:fs` from bare `-m fs`, `node:path`).
pub fn exerciseSyncNode26Core(out_alloc: std.mem.Allocator, existing_file_path: []const u8) ![]u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    // 1. `globals.process`: `argv`, `version`, and `env` get/set
    {
        const proc = try g.process.get();
        defer proc.deinit();

        const argv = try proc.argvAlloc(tracked_alloc);
        defer js.freeDecoded([]const []const u8, tracked_alloc, argv);
        if (argv.len < 1 or argv[0].len == 0) return out_alloc.dupe(u8, "fail:process_argv");

        const ver = try proc.versionAlloc(tracked_alloc);
        defer tracked_alloc.free(ver);
        if (!std.mem.startsWith(u8, ver, "v26.")) {
            return std.fmt.allocPrint(out_alloc, "fail:process_version:{s}", .{ver});
        }

        const env = try proc.env();
        defer env.deinit();
        const host_val = (try env.getAlloc(tracked_alloc, "TS_ZIGAR_M4_HOST")) orelse return out_alloc.dupe(u8, "fail:env_missing");
        defer tracked_alloc.free(host_val);
        if (!std.mem.eql(u8, host_val, "node26-ok")) {
            return std.fmt.allocPrint(out_alloc, "fail:env_val:{s}", .{host_val});
        }
        try env.set("TS_ZIGAR_M4_ZIG_ENV", "written-by-zig");
    }

    // 2. `globals.console`: `console.log`
    {
        const con = try g.console.get();
        defer con.deinit();
        const msg_any = try js.toJsRef([]const u8, "zigar-m4-console-ok");
        defer msg_any.deinit();
        try con.logSlice(&.{msg_any});
    }

    // 3. `globals.buffer` & `node:buffer`: `Buffer.from`, zero-copy `subarray` mutation, `concat`, `isUtf8`, `INSPECT_MAX_BYTES`
    {
        const g_buf = try g.buffer.get();
        defer g_buf.deinit();
        const nb_buf = try nb.buffer.get();
        defer nb_buf.deinit();

        const buf = try g_buf.fromWithImplicitCoercionStringBufferEncodingOpt(nb.WithImplicitCoercion([]const u8).from("hello world"), .utf8);
        defer buf.deinit();
        if (!try js.Buffer.isBuffer(buf)) return out_alloc.dupe(u8, "fail:isBuffer");
        const base_off = try buf.byteOffset();

        const sub = try buf.subarray(6, 11);
        defer sub.deinit();
        if (!try js.Buffer.isBuffer(sub)) return out_alloc.dupe(u8, "fail:sub_isBuffer");
        if ((try sub.byteLength()) != 5) return out_alloc.dupe(u8, "fail:sub_len");
        if ((try sub.byteOffset()) != base_off + 6) return out_alloc.dupe(u8, "fail:sub_byteOffset");
        if ((try sub.get(0)) != 'w') return out_alloc.dupe(u8, "fail:sub_get0");

        // Mutate via `sub` and verify `buf` sees the mutation in place (zero-copy view!)
        try sub.set(0, 'W');
        try sub.writeFromAt("ORLD", 1);

        const mutated = try buf.toOwnedSlice(tracked_alloc);
        defer tracked_alloc.free(mutated);
        if (!std.mem.eql(u8, mutated, "hello WORLD")) {
            return std.fmt.allocPrint(out_alloc, "fail:buf_mutated:{s}", .{mutated});
        }

        const bang = try nb_buf.fromWithImplicitCoercionStringBufferEncodingOpt(nb.WithImplicitCoercion([]const u8).from("!"), .utf8);
        defer bang.deinit();
        const joined = try nb_buf.concat(&.{ .{ .handle = buf.handle }, .{ .handle = bang.handle } }, null);
        defer joined.deinit();
        const joined_bytes = try joined.toOwnedSlice(tracked_alloc);
        defer tracked_alloc.free(joined_bytes);
        if (!std.mem.eql(u8, joined_bytes, "hello WORLD!")) {
            return std.fmt.allocPrint(out_alloc, "fail:buf_concat:{s}", .{joined_bytes});
        }

        const utf8_ok = try nb.isUtf8(.{ .node_js_typed_array = .{ .uint8_array = .{ .handle = joined.handle } } });
        if (!utf8_ok) return out_alloc.dupe(u8, "fail:nb_isUtf8");
        if ((try nb.INSPECT_MAX_BYTES.get()) <= 0) return out_alloc.dupe(u8, "fail:INSPECT_MAX_BYTES");
    }

    // 4. `globals.Url` & `globals.UrlSearchParams`
    {
        const u = try g.Url.init(.{ .str = "https://zigar.example/v1/items?a=1" }, null);
        defer u.deinit();
        const pathname = try u.pathnameAlloc(tracked_alloc);
        defer tracked_alloc.free(pathname);
        if (!std.mem.eql(u8, pathname, "/v1/items")) {
            return std.fmt.allocPrint(out_alloc, "fail:url_pathname:{s}", .{pathname});
        }

        const sp = try u.searchParams();
        defer sp.deinit();
        try sp.set("b", "2");
        const b_val = (try sp.getAlloc(tracked_alloc, "b")) orelse return out_alloc.dupe(u8, "fail:sp_get_b");
        defer tracked_alloc.free(b_val);
        if (!std.mem.eql(u8, b_val, "2")) return out_alloc.dupe(u8, "fail:sp_val_b");

        const href = try u.hrefAlloc(tracked_alloc);
        defer tracked_alloc.free(href);
        if (!std.mem.eql(u8, href, "https://zigar.example/v1/items?a=1&b=2")) {
            return std.fmt.allocPrint(out_alloc, "fail:url_href:{s}", .{href});
        }
    }

    // 5. `globals.TextEncoder` & `globals.TextDecoder`
    {
        const enc = try g.TextEncoder.init();
        defer enc.deinit();
        const encoded = try enc.encodeAlloc(tracked_alloc, "zigar-🚀-26");
        defer encoded.deinit();
        if ((try encoded.byteLength()) != 13) return out_alloc.dupe(u8, "fail:enc_len");

        const dec = try g.TextDecoder.init("utf-8", null);
        defer dec.deinit();
        const decoded = try dec.decodeAlloc(
            tracked_alloc,
            .{ .array_buffer_view = .{ .typed_array = .{ .uint8_array = encoded } } },
            null,
        );
        defer tracked_alloc.free(decoded);
        if (!std.mem.eql(u8, decoded, "zigar-🚀-26")) {
            return std.fmt.allocPrint(out_alloc, "fail:dec:{s}", .{decoded});
        }
    }

    // 6. `AbortController`, `crypto.randomUUID`, `performance.now`, `structuredClone`
    {
        const ac = try g.AbortController.init();
        defer ac.deinit();
        const sig = try ac.signal();
        defer sig.deinit();
        if (try sig.aborted()) return out_alloc.dupe(u8, "fail:sig_pre_aborted");
        try ac.abort(null);
        if (!try sig.aborted()) return out_alloc.dupe(u8, "fail:sig_post_aborted");

        const cry = try g.crypto.get();
        defer cry.deinit();
        const uuid = try cry.randomUuidAlloc(tracked_alloc);
        defer js.freeDecoded(@TypeOf(uuid), tracked_alloc, uuid);
        if (uuid.raw.len != 36 or uuid.raw[8] != '-' or !@TypeOf(uuid).matches(uuid.raw)) {
            return std.fmt.allocPrint(out_alloc, "fail:uuid:{s}", .{uuid.raw});
        }

        const perf = try g.performance.get();
        defer perf.deinit();
        if ((try perf.now()) < 0) return out_alloc.dupe(u8, "fail:perf_now");

        const cloned = try g.structuredCloneAlloc([]const u8, tracked_alloc, "cloned-value", null);
        defer tracked_alloc.free(cloned);
        if (!std.mem.eql(u8, cloned, "cloned-value")) return out_alloc.dupe(u8, "fail:structuredClone");
    }

    // 7. Canonical `node:fs` (from bare `-m fs`) and `node:path`
    {
        if (!try nfs.existsSync(.{ .str = existing_file_path })) {
            return out_alloc.dupe(u8, "fail:fs_exists_true");
        }
        if (try nfs.existsSync(.{ .str = "/nonexistent-ts-zigar-m4-probe-file" })) {
            return out_alloc.dupe(u8, "fail:fs_exists_false");
        }

        const joined_path = try npath.Path.joinAlloc(tracked_alloc, .{ "dir_a", "dir_b", "file.zig" });
        defer tracked_alloc.free(joined_path);
        if (!std.mem.eql(u8, joined_path, "dir_a/dir_b/file.zig")) {
            return std.fmt.allocPrint(out_alloc, "fail:path_join:{s}", .{joined_path});
        }
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return out_alloc.dupe(u8, "sync-node26-core-ok");
}

/// Verifies `globals.fetchPromise` vs auto-awaited `globals.fetch` without JSPI / off WorkQueue.
pub fn probeSyncFetchHostUnavailable() !bool {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    var got_unavail = false;
    {
        const proc = try g.process.get();
        defer proc.deinit();
        const env = try proc.env();
        defer env.deinit();
        const http_url = (try env.getAlloc(tracked_alloc, "TS_ZIGAR_M4_HTTP_URL")) orelse return false;
        defer tracked_alloc.free(http_url);

        const p = try g.fetchPromise(.{ .str = http_url }, null);
        p.deinit();

        got_unavail = if (g.fetch(.{ .str = http_url }, null)) |r| blk: {
            r.deinit();
            break :blk false;
        } else |err| (err == error.HostUnavailable);
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return got_unavail;
}

const worker_ns = struct {
    /// Exercises live `globals.fetch` (`Response.ok`, `status`, `headers`, promoted `BodyMixin`
    /// `textAlloc` & `bytes`) and `globals.WebSocket` (`init`, `send`, `close`, `node:events` `once`)
    /// against a local Node.js 26 HTTP + RFC 6455 WebSocket upgrade server.
    pub fn exerciseAsyncFetchAndWebSocket(out_alloc: std.mem.Allocator) ![]u8 {
        const handles_before = js.activeHandleCount();
        const cbs_before = js.activeCallbackCount();
        const allocs_before = live_allocs.load(.acquire);

        {
            const urls = blk: {
                const proc = try g.process.get();
                defer proc.deinit();
                const env = try proc.env();
                defer env.deinit();
                const http_u = (try env.getAlloc(tracked_alloc, "TS_ZIGAR_M4_HTTP_URL")) orelse return out_alloc.dupe(u8, "fail:missing_http_url");
                errdefer tracked_alloc.free(http_u);
                const ws_u = (try env.getAlloc(tracked_alloc, "TS_ZIGAR_M4_WS_URL")) orelse {
                    tracked_alloc.free(http_u);
                    return out_alloc.dupe(u8, "fail:missing_ws_url");
                };
                break :blk .{ .http = http_u, .ws = ws_u };
            };
            defer {
                tracked_alloc.free(urls.http);
                tracked_alloc.free(urls.ws);
            }

            // 1. `globals.fetch` + `Response.textAlloc` + `Headers.getAlloc`
            {
                const res = try g.fetch(.{ .str = urls.http }, null);
                defer res.deinit();
                if (!try res.ok()) return out_alloc.dupe(u8, "fail:fetch_not_ok");
                if ((try res.status()) != 200) return out_alloc.dupe(u8, "fail:fetch_status");

                const hdrs = try res.headers();
                defer hdrs.deinit();
                const hdr_val = (try hdrs.getAlloc(tracked_alloc, "x-zigar-m4")) orelse return out_alloc.dupe(u8, "fail:fetch_hdr_missing");
                defer tracked_alloc.free(hdr_val);
                if (!std.mem.eql(u8, hdr_val, "node26-http")) {
                    return std.fmt.allocPrint(out_alloc, "fail:fetch_hdr:{s}", .{hdr_val});
                }

                const body_txt = try res.textAlloc(tracked_alloc);
                defer tracked_alloc.free(body_txt);
                if (!std.mem.eql(u8, body_txt, "hello-from-node26-fetch:/ping?from=zig")) {
                    return std.fmt.allocPrint(out_alloc, "fail:fetch_text:{s}", .{body_txt});
                }
            }

            // 2. `globals.fetchPromise` + `Response.bytes` (second promoted `BodyMixin` method)
            {
                const f_prom = try g.fetchPromise(.{ .str = urls.http }, null);
                defer f_prom.deinit();
                const res2 = try f_prom.await();
                defer res2.deinit();
                const raw_u8 = try res2.bytes();
                defer raw_u8.deinit();
                const owned_bytes = try raw_u8.toOwnedSlice(tracked_alloc);
                defer tracked_alloc.free(owned_bytes);
                if (!std.mem.eql(u8, owned_bytes, "hello-from-node26-fetch:/ping?from=zig")) {
                    return std.fmt.allocPrint(out_alloc, "fail:fetch_bytes:{s}", .{owned_bytes});
                }
            }

            // 3. `globals.WebSocket` + `node:events` `oncePromiseEventTarget` round-trip
            // Gate the loopback HTTP 101 Upgrade until after `oncePromiseEventTarget(et, "open")`
            // has registered on the JS thread (preventing a cross-thread `WorkQueue` race where
            // loopback `open` fires before `events.once` attaches).
            {
                const prep_url = try std.fmt.allocPrint(tracked_alloc, "{s}&ws_gate=prepare", .{urls.http});
                defer tracked_alloc.free(prep_url);
                const prep_res = try g.fetch(.{ .str = prep_url }, null);
                prep_res.deinit();

                const ws = try g.WebSocket.init(.{ .str = urls.ws }, null);
                defer ws.deinit();
                const et = ws.as(g.EventTarget);

                const open_prom = try ne.oncePromiseEventTarget(et, "open", null);
                defer open_prom.deinit();

                const rel_url = try std.fmt.allocPrint(tracked_alloc, "{s}&ws_gate=release", .{urls.http});
                defer tracked_alloc.free(rel_url);
                const rel_res = try g.fetch(.{ .str = rel_url }, null);
                rel_res.deinit();

                const open_args = try open_prom.awaitAlloc(tracked_alloc);
                js.freeDecoded([]const js.Any, tracked_alloc, open_args);

                const open_state = try g.WebSocket.OPEN.get();
                if ((try ws.readyState()) != open_state) return out_alloc.dupe(u8, "fail:ws_readyState");

                const msg_prom = try ne.oncePromiseEventTarget(et, "message", null);
                defer msg_prom.deinit();
                try ws.send(.{ .str = "zig-ws-hello" });
                const msg_args = try msg_prom.awaitAlloc(tracked_alloc);
                defer js.freeDecoded([]const js.Any, tracked_alloc, msg_args);
                if (msg_args.len < 1) return out_alloc.dupe(u8, "fail:ws_msg_empty");

                const msg_data = try js.getInstancePropAlloc([]const u8, tracked_alloc, .{ .handle = msg_args[0].handle }, "data");
                defer tracked_alloc.free(msg_data);
                if (!std.mem.eql(u8, msg_data, "echo:zig-ws-hello")) {
                    return std.fmt.allocPrint(out_alloc, "fail:ws_msg:{s}", .{msg_data});
                }

                const close_prom = try ne.oncePromiseEventTarget(et, "close", null);
                defer close_prom.deinit();
                try ws.close(1000, "done");
                const close_args = try close_prom.awaitAlloc(tracked_alloc);
                js.freeDecoded([]const js.Any, tracked_alloc, close_args);
            }
        }

        try checkInvariants(handles_before, cbs_before, allocs_before);
        return out_alloc.dupe(u8, "async-fetch-ws-ok");
    }
};

fn wasmStartupNoop(_: usize) void {}
fn wasmShutdownNoop() void {}

var work_queue: if (is_wasm) void else zigar.thread.WorkQueue(worker_ns) = if (is_wasm) {} else .{};

pub const startup = if (is_wasm) wasmStartupNoop else work_queue.promisify(.startup);
pub const shutdown = if (is_wasm) wasmShutdownNoop else work_queue.promisify(.shutdown);
pub const runAsyncFetchAndWebSocket = if (is_wasm) worker_ns.exerciseAsyncFetchAndWebSocket else work_queue.promisify(worker_ns.exerciseAsyncFetchAndWebSocket);
