const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const ne = gen.node_events;
const nsc = gen.node_stream_consumers;
const nfs = gen.node_fs;
const nfsp = gen.node_fs_promises;
const np = gen.node_path;
const npw = gen.node_path_win32;
const npp = gen.node_path_posix;
const nu = gen.node_url;
const nq = gen.node_querystring;
const nhttp = gen.node_http;
const nhttp2 = gen.node_http2;
const nhttps = gen.node_https;
const nnet = gen.node_net;
const ntls = gen.node_tls;
const ndns = gen.node_dns;
const ndnsp = gen.node_dns_promises;
const ndgram = gen.node_dgram;

comptime {
    if (np.ParsedPath != npw.ParsedPath or np.ParsedPath != npp.ParsedPath) {
        @compileError("Expected node:path, node:path/win32, and node:path/posix to share canonical ParsedPath");
    }
}

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

/// Exercises synchronous `node:path` (`posix`/`win32` + `node:path/win32` + `node:path/posix`),
/// `node:url` (`pathToFileUrl`, `fileUrlToPath`, `URLSearchParams`), `node:querystring`,
/// `node:fs` (`mkdtempSync`, `writeFileSync`, `existsSync`, `readFileSync`, `statSync` + `js.Date`, `rmSync`),
/// `node:tls` (`getCiphers`), and `node:https` (`Agent`).
pub fn exerciseSyncFsPathUrlTls(out_alloc: std.mem.Allocator, tmp_base: []const u8) ![]u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    // 1. `node:path`, `node:path/win32`, and `node:path/posix`
    {
        const joined = try np.joinAlloc(tracked_alloc, .{ "alpha", "beta", "gamma.txt" });
        defer tracked_alloc.free(joined);
        if (!std.mem.eql(u8, joined, "alpha/beta/gamma.txt")) {
            return std.fmt.allocPrint(out_alloc, "fail:path_join:{s}", .{joined});
        }

        const sub_win = try np.win32.joinAlloc(tracked_alloc, .{ "alpha", "beta" });
        defer tracked_alloc.free(sub_win);
        if (!std.mem.eql(u8, sub_win, "alpha\\beta")) {
            return std.fmt.allocPrint(out_alloc, "fail:path_sub_win32:{s}", .{sub_win});
        }

        const mod_win = try npw.joinAlloc(tracked_alloc, .{ "win", "dir", "file.txt" });
        defer tracked_alloc.free(mod_win);
        if (!std.mem.eql(u8, mod_win, "win\\dir\\file.txt")) {
            return std.fmt.allocPrint(out_alloc, "fail:path_mod_win32:{s}", .{mod_win});
        }

        const mod_posix = try npp.joinAlloc(tracked_alloc, .{ "posix", "dir", "file.txt" });
        defer tracked_alloc.free(mod_posix);
        if (!std.mem.eql(u8, mod_posix, "posix/dir/file.txt")) {
            return std.fmt.allocPrint(out_alloc, "fail:path_mod_posix:{s}", .{mod_posix});
        }

        const parsed = try np.parseAlloc(tracked_alloc, "/d/tmp/demo.txt");
        defer js.freeDecoded(np.ParsedPath, tracked_alloc, parsed);
        if (!std.mem.eql(u8, parsed.base, "demo.txt") or !std.mem.eql(u8, parsed.ext, ".txt")) {
            return std.fmt.allocPrint(out_alloc, "fail:path_parse:{s}:{s}", .{ parsed.base, parsed.ext });
        }

        const formatted = try np.formatAlloc(tracked_alloc, .{ .dir = "/d/tmp", .base = "demo.txt" });
        defer tracked_alloc.free(formatted);
        if (!std.mem.eql(u8, formatted, "/d/tmp/demo.txt")) {
            return std.fmt.allocPrint(out_alloc, "fail:path_format:{s}", .{formatted});
        }
    }

    // 2. `node:url` & `node:querystring`
    {
        const file_url = try nu.pathToFileUrl("/d/tmp/hello world.txt", null);
        defer file_url.deinit();
        const href = try file_url.hrefAlloc(tracked_alloc);
        defer tracked_alloc.free(href);
        if (!std.mem.eql(u8, href, "file:///d/tmp/hello%20world.txt")) {
            return std.fmt.allocPrint(out_alloc, "fail:url_href:{s}", .{href});
        }

        const back_path = try nu.fileUrlToPathAlloc(tracked_alloc, .from(file_url), null);
        defer tracked_alloc.free(back_path);
        if (!std.mem.eql(u8, back_path, "/d/tmp/hello world.txt")) {
            return std.fmt.allocPrint(out_alloc, "fail:url_path:{s}", .{back_path});
        }

        const usp = try nu.UrlSearchParams.init(.{ .str = "k=1&m=two" });
        defer usp.deinit();
        try usp.append("k", "3");
        const k_vals = try usp.getAllAlloc(tracked_alloc, "k");
        defer js.freeDecoded([]const []const u8, tracked_alloc, k_vals);
        if (k_vals.len != 2 or !std.mem.eql(u8, k_vals[0], "1") or !std.mem.eql(u8, k_vals[1], "3")) {
            return out_alloc.dupe(u8, "fail:usp_getAll");
        }

        const esc = try nq.escapeAlloc(tracked_alloc, "a b+c");
        defer tracked_alloc.free(esc);
        const unesc = try nq.unescapeAlloc(tracked_alloc, esc);
        defer tracked_alloc.free(unesc);
        if (!std.mem.eql(u8, unesc, "a b+c")) {
            return std.fmt.allocPrint(out_alloc, "fail:qs_unesc:{s}", .{unesc});
        }
    }

    // 3. `node:fs` sync CRUD + `Stats.mtime()` (`js.Date`)
    {
        const prefix = try np.joinAlloc(tracked_alloc, .{ tmp_base, "sync-57-" });
        defer tracked_alloc.free(prefix);
        const dir_path = try nfs.mkdtempSyncPrefixStringOptionsEncodingOptionOptReturningStringAlloc(tracked_alloc, prefix, null);
        defer tracked_alloc.free(dir_path);

        const file_path = try np.joinAlloc(tracked_alloc, .{ dir_path, "sample.txt" });
        defer tracked_alloc.free(file_path);

        try nfs.writeFileSync(.{ .path_like = .{ .str = file_path } }, .{ .str = "sync-fs-payload-57" }, null);
        if (!try nfs.existsSync(.{ .str = file_path })) {
            return out_alloc.dupe(u8, "fail:fs_exists");
        }

        const content = try nfs.readFileSyncOptionsAlloc(tracked_alloc, .{ .path_like = .{ .str = file_path } }, .{ .buffer_encoding = .utf8 });
        defer tracked_alloc.free(content);
        if (!std.mem.eql(u8, content, "sync-fs-payload-57")) {
            return std.fmt.allocPrint(out_alloc, "fail:fs_read:{s}", .{content});
        }

        const st = try nfs.statSyncPathLikeOptionsOpt(.{ .str = file_path }, null);
        defer st.deinit();
        if (!try st.isFile()) return out_alloc.dupe(u8, "fail:fs_isFile");
        const mtime = try st.mtime();
        defer mtime.deinit();
        const ts_ms = try mtime.timestampMs();
        if (!(ts_ms > 1_600_000_000_000.0)) {
            return std.fmt.allocPrint(out_alloc, "fail:fs_mtime:{d}", .{ts_ms});
        }

        try nfs.rmSync(.{ .str = dir_path }, .{ .recursive = true, .force = true });
        if (try nfs.existsSync(.{ .str = dir_path })) {
            return out_alloc.dupe(u8, "fail:fs_rmSync");
        }
    }

    // 4. `node:tls` & `node:https`
    {
        const ciphers = try ntls.getCiphersAlloc(tracked_alloc);
        defer js.freeDecoded([]const []const u8, tracked_alloc, ciphers);
        if (ciphers.len == 0) return out_alloc.dupe(u8, "fail:tls_ciphers");

        const agent = try nhttps.Agent.init(.{ .keep_alive = false });
        defer agent.deinit();
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return out_alloc.dupe(u8, "sync-fs-net-ok");
}

/// Verifies that calling auto-awaited `dns/promises.lookup` without JSPI / off `WorkQueue`
/// returns `error.HostUnavailable` while `lookupPromiseString` returns a raw `Promise` leak-free.
pub fn probeSyncFsNetHostUnavailable() !bool {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    var got_unavail = false;
    {
        const prom = try ndnsp.lookupPromiseString("127.0.0.1");
        prom.deinit();

        got_unavail = if (ndnsp.lookupStringLookupOneOptionsAlloc(tracked_alloc, "127.0.0.1", .{ .family = .{ .num = 4 } })) |addr| blk: {
            js.freeDecoded(ndns.LookupAddress, tracked_alloc, addr);
            break :blk false;
        } else |err| (err == error.HostUnavailable);
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return got_unavail;
}

const HttpCallbacks = struct {
    const State = struct {
        hits: usize = 0,
    };

    fn onRequest(state: *State, req: nhttp.IncomingMessage, res: nhttp.ServerResponse(nhttp.IncomingMessage)) js.CallError!void {
        state.hits += 1;
        const url_opt = try req.urlAlloc(tracked_alloc);
        defer if (url_opt) |u| tracked_alloc.free(u);
        const path_str = url_opt orelse "/";

        const r1 = try res.setHeader("x-zig-hit", .{ .str = path_str });
        r1.deinit();

        var reply_buf: [128]u8 = undefined;
        const reply = std.fmt.bufPrint(&reply_buf, "http-ok:{s}", .{path_str}) catch return error.Unexpected;
        const chunk_ref = try js.toJsRef([]const u8, reply);
        defer chunk_ref.deinit();
        const r2 = try res.endWithChunk(chunk_ref, null);
        r2.deinit();
    }
};

const worker_ns = struct {
    /// Exercises async `node:fs/promises` (`mkdtemp`, `writeFile`, `readFile`, `stat`, `open` +
    /// `FileHandle.asyncDispose`, `opendir` + `Dir.asyncIterator`, `rm`), `node:dns/promises`,
    /// `node:dgram` UDP loopback, `node:net` TCP loopback, `node:http` (`createServerRequestListenerDefault` +
    /// `ConstructorOf`/`InstanceType` + `http.get`), and `node:http2` loopback (`createServer` + `connect`).
    pub fn exerciseAsyncFsAndNet(out_alloc: std.mem.Allocator, tmp_base: []const u8) ![]u8 {
        const handles_before = js.activeHandleCount();
        const cbs_before = js.activeCallbackCount();
        const allocs_before = live_allocs.load(.acquire);

        // 1. `node:fs/promises` CRUD + `FileHandle.asyncDispose()` + `Dir.asyncIterator()`
        {
            const prefix = try np.joinAlloc(tracked_alloc, .{ tmp_base, "async-57-" });
            defer tracked_alloc.free(prefix);
            const dir_path = try nfsp.mkdtempPrefixStringOptionsObjectEncodingOptionsOrBufferEncodingOptReturningStringAlloc(tracked_alloc, prefix, null);
            defer tracked_alloc.free(dir_path);

            const fpath = try np.joinAlloc(tracked_alloc, .{ dir_path, "alpha.txt" });
            defer tracked_alloc.free(fpath);
            try nfsp.writeFile(.{ .path_like = .{ .str = fpath } }, .{ .str = "async-fsp-payload-57" }, null);

            const read_back = try nfsp.readFilePathLikeOrFileHandleReadFileOptionsWithStringEncodingOrBufferEncodingAlloc(
                tracked_alloc,
                .{ .path_like = .{ .str = fpath } },
                .{ .buffer_encoding = .utf8 },
            );
            defer tracked_alloc.free(read_back);
            if (!std.mem.eql(u8, read_back, "async-fsp-payload-57")) {
                return std.fmt.allocPrint(out_alloc, "fail:fsp_read:{s}", .{read_back});
            }

            const st = try nfsp.statPathLikeOptsOpt(.{ .str = fpath }, null);
            defer st.deinit();
            const mtime = try st.mtime();
            defer mtime.deinit();
            if (!((try mtime.timestampMs()) > 1_600_000_000_000.0)) {
                return out_alloc.dupe(u8, "fail:fsp_mtime");
            }

            {
                const fh = try nfsp.open(.{ .str = fpath }, .{ .str = "r" }, null);
                defer fh.asyncDispose();
                if (!((try fh.fd()) >= 0)) return out_alloc.dupe(u8, "fail:fsp_fd");
            }

            {
                const dir = try nfsp.opendir(.{ .str = dir_path }, null);
                defer dir.deinit();
                const dit = try dir.asyncIterator();
                defer dit.deinit();
                var found_alpha = false;
                while (try dit.next()) |ent| {
                    defer ent.deinit();
                    const nm = try ent.nameAlloc(tracked_alloc);
                    defer tracked_alloc.free(nm);
                    if (std.mem.eql(u8, nm, "alpha.txt")) found_alpha = true;
                }
                if (!found_alpha) return out_alloc.dupe(u8, "fail:fsp_opendir");
            }

            try nfsp.rm(.{ .str = dir_path }, .{ .recursive = true, .force = true });
        }

        // 2. `node:dns/promises` loopback lookup
        {
            const resolved = try ndnsp.lookupStringLookupOneOptionsAlloc(tracked_alloc, "127.0.0.1", .{ .family = .{ .num = 4 } });
            defer js.freeDecoded(ndns.LookupAddress, tracked_alloc, resolved);
            if (!std.mem.eql(u8, resolved.address, "127.0.0.1") or resolved.family != 4) {
                return std.fmt.allocPrint(out_alloc, "fail:dns:{s}:{d}", .{ resolved.address, resolved.family });
            }
        }

        // 3. `node:dgram` UDP4 loopback
        {
            const sock = try ndgram.createSocketSocketType(.udp4, null);
            defer sock.deinit();

            const listen_prom = try ne.oncePromise(.{ sock.as(ne.EventEmitter(js.Any)), "listening", null });
            defer listen_prom.deinit();
            const b_self = try sock.bindWithAddress(0, "127.0.0.1", null);
            b_self.deinit();
            const listen_args = try listen_prom.awaitAlloc(tracked_alloc);
            js.freeDecoded([]const js.Any, tracked_alloc, listen_args);

            const addr = try sock.addressAlloc(tracked_alloc);
            defer js.freeDecoded(nnet.AddressInfo, tracked_alloc, addr);

            const msg_prom = try ne.oncePromise(.{ sock.as(ne.EventEmitter(js.Any)), "message", null });
            defer msg_prom.deinit();
            try sock.sendStrOrNodeJsArrayBufferViewNumberOptStringOptCallbackObjectNumberOpt(
                .{ .str = "udp-zig-57" },
                addr.port,
                "127.0.0.1",
                null,
            );

            const msg_args = try msg_prom.awaitAlloc(tracked_alloc);
            defer js.freeDecoded([]const js.Any, tracked_alloc, msg_args);
            if (msg_args.len < 1) return out_alloc.dupe(u8, "fail:dgram_argc");
            const udp_bytes = try js.Buffer.fromRef(msg_args[0]).toOwnedSlice(tracked_alloc);
            defer tracked_alloc.free(udp_bytes);
            if (!std.mem.eql(u8, udp_bytes, "udp-zig-57")) {
                return std.fmt.allocPrint(out_alloc, "fail:dgram_payload:{s}", .{udp_bytes});
            }

            const close_prom = try ne.oncePromise(.{ sock.as(ne.EventEmitter(js.Any)), "close", null });
            defer close_prom.deinit();
            const c_self = try sock.close(null);
            c_self.deinit();
            const close_args = try close_prom.awaitAlloc(tracked_alloc);
            js.freeDecoded([]const js.Any, tracked_alloc, close_args);
        }

        // 4. `node:net` TCP loopback
        {
            const srv = try nnet.createServerCallback(null);
            defer srv.deinit();

            const listen_prom = try ne.oncePromise(.{ srv.as(ne.EventEmitter(js.Any)), "listening", null });
            defer listen_prom.deinit();
            const l_self = try srv.listenWithHostname(0, "127.0.0.1", null);
            l_self.deinit();
            const listen_args = try listen_prom.awaitAlloc(tracked_alloc);
            js.freeDecoded([]const js.Any, tracked_alloc, listen_args);

            const addr_opt = try srv.addressAlloc(tracked_alloc);
            defer js.freeDecoded(@TypeOf(addr_opt), tracked_alloc, addr_opt);
            const port = switch (addr_opt orelse return out_alloc.dupe(u8, "fail:net_no_addr")) {
                .address_info => |ai| ai.port,
                .str => return out_alloc.dupe(u8, "fail:net_str_addr"),
            };

            const conn_prom = try ne.oncePromise(.{ srv.as(ne.EventEmitter(js.Any)), "connection", null });
            defer conn_prom.deinit();

            const client = try nnet.createConnectionWithHost(port, "127.0.0.1", null);
            defer client.deinit();

            const conn_args = try conn_prom.awaitAlloc(tracked_alloc);
            defer js.freeDecoded([]const js.Any, tracked_alloc, conn_args);
            const srv_sock = try nnet.Socket.fromJsRef(conn_args[0]);
            defer srv_sock.deinit();

            const client_text_prom = try nsc.textPromise(.from(client));
            defer client_text_prom.deinit();

            const end_self = try srv_sock.endWithBuffer(.{ .str = "tcp-zig-57" }, null);
            end_self.deinit();

            const tcp_payload = try client_text_prom.awaitAlloc(tracked_alloc);
            defer tracked_alloc.free(tcp_payload);
            if (!std.mem.eql(u8, tcp_payload, "tcp-zig-57")) {
                return std.fmt.allocPrint(out_alloc, "fail:net_payload:{s}", .{tcp_payload});
            }
            const client_end = try client.end(null);
            client_end.deinit();

            const close_prom = try ne.oncePromise(.{ srv.as(ne.EventEmitter(js.Any)), "close", null });
            defer close_prom.deinit();
            const c_self = try srv.close(null);
            c_self.deinit();
            const close_args = try close_prom.awaitAlloc(tracked_alloc);
            js.freeDecoded([]const js.Any, tracked_alloc, close_args);
        }

        // 5. `node:http` `createServerRequestListenerDefault` (`ConstructorOf` + `InstanceType`) + `http.request`
        {
            var state = HttpCallbacks.State{};
            var req_cl = try js.Closure(*HttpCallbacks.State, HttpCallbacks.onRequest).tryInit(&state);
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
            const port = switch (addr_opt orelse return out_alloc.dupe(u8, "fail:http_no_addr")) {
                .address_info => |ai| ai.port,
                .str => return out_alloc.dupe(u8, "fail:http_str_addr"),
            };

            const url_str = try std.fmt.allocPrint(tracked_alloc, "http://127.0.0.1:{d}/zig57", .{@as(u32, @intFromFloat(port))});
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
                return out_alloc.dupe(u8, "fail:http_status");
            }
            const body = try nsc.textAlloc(tracked_alloc, .from(incoming));
            defer tracked_alloc.free(body);
            if (!std.mem.eql(u8, body, "http-ok:/zig57") or state.hits != 1) {
                return std.fmt.allocPrint(out_alloc, "fail:http_body:{s}:{d}", .{ body, state.hits });
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

        // 6. `node:http2` loopback (`createServer` + `connect` + `request` + `respond`)
        {
            const h2_srv = try nhttp2.createServerCallback(null);
            defer h2_srv.deinit();

            const listen_prom = try ne.oncePromise(.{ h2_srv.as(ne.EventEmitter(js.Any)), "listening", null });
            defer listen_prom.deinit();
            const l_self = try h2_srv.listenWithHostname(0, "127.0.0.1", null);
            l_self.deinit();
            const listen_args = try listen_prom.awaitAlloc(tracked_alloc);
            js.freeDecoded([]const js.Any, tracked_alloc, listen_args);

            const addr_opt = try h2_srv.addressAlloc(tracked_alloc);
            defer js.freeDecoded(@TypeOf(addr_opt), tracked_alloc, addr_opt);
            const port = switch (addr_opt orelse return out_alloc.dupe(u8, "fail:h2_no_addr")) {
                .address_info => |ai| ai.port,
                .str => return out_alloc.dupe(u8, "fail:h2_str_addr"),
            };

            const authority = try std.fmt.allocPrint(tracked_alloc, "http://127.0.0.1:{d}", .{@as(u32, @intFromFloat(port))});
            defer tracked_alloc.free(authority);

            const stream_prom = try ne.oncePromise(.{ h2_srv.as(ne.EventEmitter(js.Any)), "stream", null });
            defer stream_prom.deinit();

            const sess = try nhttp2.connectWithOptions(.{ .str = authority }, null, null);
            defer sess.deinit();

            const req_stream = try sess.request(null, .{ .end_stream = true });
            defer req_stream.deinit();
            const h2_body_prom = try nsc.textPromise(.from(req_stream));
            defer h2_body_prom.deinit();

            const stream_args = try stream_prom.awaitAlloc(tracked_alloc);
            defer js.freeDecoded([]const js.Any, tracked_alloc, stream_args);
            const srv_stream = try nhttp2.ServerHttp2Stream.fromJsRef(stream_args[0]);
            defer srv_stream.deinit();

            try srv_stream.respond(null, null);
            const chunk_ref = try js.toJsRef([]const u8, "h2-zig-57");
            defer chunk_ref.deinit();
            const end_self = try srv_stream.endWithChunk(chunk_ref, null);
            end_self.deinit();

            const h2_body = try h2_body_prom.awaitAlloc(tracked_alloc);
            defer tracked_alloc.free(h2_body);
            if (!std.mem.eql(u8, h2_body, "h2-zig-57")) {
                return std.fmt.allocPrint(out_alloc, "fail:h2_body:{s}", .{h2_body});
            }

            const sess_close_prom = try ne.oncePromise(.{ sess.as(ne.EventEmitter(js.Any)), "close", null });
            defer sess_close_prom.deinit();
            try sess.close(null);
            const sess_close_args = try sess_close_prom.awaitAlloc(tracked_alloc);
            js.freeDecoded([]const js.Any, tracked_alloc, sess_close_args);

            const srv_close_prom = try ne.oncePromise(.{ h2_srv.as(ne.EventEmitter(js.Any)), "close", null });
            defer srv_close_prom.deinit();
            const c_self = try h2_srv.close(null);
            c_self.deinit();
            const srv_close_args = try srv_close_prom.awaitAlloc(tracked_alloc);
            js.freeDecoded([]const js.Any, tracked_alloc, srv_close_args);
        }

        try checkInvariants(handles_before, cbs_before, allocs_before);
        return out_alloc.dupe(u8, "async-fs-net-ok");
    }
};

fn wasmStartupNoop(_: usize) void {}
fn wasmShutdownNoop() void {}

var work_queue: if (is_wasm) void else zigar.thread.WorkQueue(worker_ns) = if (is_wasm) {} else .{};

pub const startup = if (is_wasm) wasmStartupNoop else work_queue.promisify(.startup);
pub const shutdown = if (is_wasm) wasmShutdownNoop else work_queue.promisify(.shutdown);
pub const runAsyncFsAndNet = if (is_wasm) worker_ns.exerciseAsyncFsAndNet else work_queue.promisify(worker_ns.exerciseAsyncFsAndNet);
