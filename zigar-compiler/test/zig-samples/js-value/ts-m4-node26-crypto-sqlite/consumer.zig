const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const nc = gen.node_crypto;
const nsql = gen.node_sqlite;
const nz = gen.node_zlib;
const nah = gen.node_async_hooks;
const nos = gen.node_os;
const nvm = gen.node_vm;
const ntp = gen.node_timers_promises;
const ndc = gen.node_diagnostics_channel;
const nsea = gen.node_sea;
const nut = gen.node_util_types;

const is_wasm = switch (builtin.cpu.arch) {
    .wasm32, .wasm64 => true,
    else => false,
};

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
        zigar.mem.allocator.rawFree(buf, alignment, new_addr: {
            break :new_addr ret_addr;
        });
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

const AlsSync = struct {
    const State = struct {
        als: nah.AsyncLocalStorage([]const u8),
        matched: bool = false,
    };

    fn onRun(ctx: *State) bool {
        const val = (ctx.als.getStoreAlloc(tracked_alloc) catch return false) orelse return false;
        defer tracked_alloc.free(val);
        ctx.matched = std.mem.eql(u8, val, "ctx-sync-58");
        return ctx.matched;
    }
};

/// Exercises synchronous Node 26 `crypto`, `sqlite` (`DatabaseSync` + `Symbol.dispose`),
/// `zlib` (nested `InputType.from(Buffer)` coercion), `async_hooks` (`AsyncLocalStorage`),
/// `os`, `vm`, `diagnostics_channel`, `sea`, and `util/types` + `Float16Array`.
pub fn exerciseSyncCryptoSqliteZlibOs(out_alloc: std.mem.Allocator) ![]u8 {
    // 1. `node:crypto` (`createHash`, `createHmac`, `timingSafeEqual`, `randomUuidAlloc`, `randomBytesNumber`, `scryptSync`)
    {
        const hash = try nc.createHash("sha256", null);
        defer hash.deinit();
        const h_up = try hash.update(.{ .str = "ts-zigar-node26" }, null);
        defer h_up.deinit();
        const hex_digest = try hash.digestBufferEncodingAlloc(tracked_alloc, .hex);
        defer tracked_alloc.free(hex_digest);
        if (hex_digest.len != 64) {
            return std.fmt.allocPrint(out_alloc, "fail:sha256_len:{d}", .{hex_digest.len});
        }

        const hmac1 = try nc.createHmac("sha256", .from("zigar-secret"), null);
        defer hmac1.deinit();
        const hm1_up = try hmac1.update(.{ .str = "ts-zigar-node26" }, null);
        defer hm1_up.deinit();
        const mac1 = try hmac1.digestEmpty();
        defer mac1.deinit();
        if ((try mac1.byteLength()) != 32) {
            return out_alloc.dupe(u8, "fail:hmac_len");
        }

        const hmac2 = try nc.createHmac("sha256", .from("zigar-secret"), null);
        defer hmac2.deinit();
        const hm2_up = try hmac2.update(.{ .str = "ts-zigar-node26" }, null);
        defer hm2_up.deinit();
        const mac2 = try hmac2.digestEmpty();
        defer mac2.deinit();

        if (!(try nc.timingSafeEqual(.from(mac1), .from(mac2)))) {
            return out_alloc.dupe(u8, "fail:timing_safe_equal");
        }

        const uuid = try nc.randomUuidAlloc(tracked_alloc, null);
        defer js.freeDecoded(nc.Uuid, tracked_alloc, uuid);
        if (uuid.raw.len != 36 or !nc.Uuid.matches(uuid.raw)) {
            return std.fmt.allocPrint(out_alloc, "fail:uuid:{s}", .{uuid.raw});
        }

        const rb = try nc.randomBytesNumber(16);
        defer rb.deinit();
        if ((try rb.byteLength()) != 16) {
            return out_alloc.dupe(u8, "fail:random_bytes");
        }

        const dk = try nc.scryptSync(.{ .str = "pw" }, .{ .str = "salt" }, 32, null);
        defer dk.deinit();
        if ((try dk.byteLength()) != 32) {
            return out_alloc.dupe(u8, "fail:scrypt_sync");
        }
    }

    // 2. `node:sqlite` (`DatabaseSync` + `Symbol.dispose` + `StatementSync` + BLOB/REAL/TEXT)
    {
        const db = try nsql.DatabaseSync.init(.{ .str = ":memory:" }, null);
        defer db.dispose();

        try db.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, score REAL, raw BLOB);");

        const ins = try db.prepare("INSERT INTO items (name, score, raw) VALUES (?, ?, ?)", null);
        defer ins.deinit();

        const blob_in = try js.Uint8Array.fromSlice("zigblob");
        defer blob_in.deinit();

        const SqlInInner = @typeInfo(nsql.SqlInputValue).optional.child;
        const chg1 = try ins.runVariadicAlloc(tracked_alloc, .{
            @as(nsql.SqlInputValue, .{ .str = "alpha" }),
            @as(nsql.SqlInputValue, .{ .num = 42.5 }),
            @as(nsql.SqlInputValue, SqlInInner.from(blob_in)),
        });
        defer js.freeDecoded(nsql.StatementResultingChanges, tracked_alloc, chg1);

        const chg1_count: f64 = switch (chg1.changes) {
            .num => |n| n,
            .bigint => |b| @floatFromInt(b),
        };
        if (chg1_count != 1.0) {
            return out_alloc.dupe(u8, "fail:sqlite_changes");
        }

        const chg2 = try ins.runVariadicAlloc(tracked_alloc, .{
            @as(nsql.SqlInputValue, .{ .str = "beta" }),
            @as(nsql.SqlInputValue, .{ .num = 99.0 }),
            @as(nsql.SqlInputValue, null),
        });
        defer js.freeDecoded(nsql.StatementResultingChanges, tracked_alloc, chg2);

        const sel = try db.prepare("SELECT name, score, raw FROM items ORDER BY id", null);
        defer sel.deinit();

        const rows = try sel.allVariadicAlloc(tracked_alloc, .{});
        defer js.freeDecoded(@TypeOf(rows), tracked_alloc, rows);
        if (rows.len != 2) {
            return std.fmt.allocPrint(out_alloc, "fail:sqlite_rows:{d}", .{rows.len});
        }

        const r0_name_opt = (try rows[0].getAlloc(tracked_alloc, "name")) orelse
            return out_alloc.dupe(u8, "fail:sqlite_no_name");
        defer js.freeDecoded(nsql.SqlOutputValue, tracked_alloc, r0_name_opt);
        const r0_name = r0_name_opt orelse return out_alloc.dupe(u8, "fail:sqlite_null_name");
        switch (r0_name) {
            .str => |s| if (!std.mem.eql(u8, s, "alpha")) return out_alloc.dupe(u8, "fail:sqlite_bad_name"),
            else => return out_alloc.dupe(u8, "fail:sqlite_name_tag"),
        }

        const r0_score_opt = (try rows[0].getAlloc(tracked_alloc, "score")) orelse
            return out_alloc.dupe(u8, "fail:sqlite_no_score");
        defer js.freeDecoded(nsql.SqlOutputValue, tracked_alloc, r0_score_opt);
        const r0_score = r0_score_opt orelse return out_alloc.dupe(u8, "fail:sqlite_null_score");
        switch (r0_score) {
            .num => |n| if (n != 42.5) return out_alloc.dupe(u8, "fail:sqlite_bad_score"),
            else => return out_alloc.dupe(u8, "fail:sqlite_score_tag"),
        }

        const r0_raw_opt = (try rows[0].getAlloc(tracked_alloc, "raw")) orelse
            return out_alloc.dupe(u8, "fail:sqlite_no_raw");
        defer js.freeDecoded(nsql.SqlOutputValue, tracked_alloc, r0_raw_opt);
        const r0_raw = r0_raw_opt orelse return out_alloc.dupe(u8, "fail:sqlite_null_raw");
        switch (r0_raw) {
            .node_js_non_shared_uint8_array => |u8a| {
                const raw_bytes = try u8a.toOwnedSlice(tracked_alloc);
                defer tracked_alloc.free(raw_bytes);
                if (!std.mem.eql(u8, raw_bytes, "zigblob")) {
                    return std.fmt.allocPrint(out_alloc, "fail:sqlite_blob:{s}", .{raw_bytes});
                }
            },
            else => return out_alloc.dupe(u8, "fail:sqlite_raw_tag"),
        }
    }

    // 3. `node:zlib` (`crc32`, `gzipSync`/`gunzipSync`, `brotliCompressSync`/`brotliDecompressSync` with nested `InputType.from(Buffer)`)
    {
        const payload = "ts-zigar-m4-zlib-roundtrip-ts-zigar-m4-zlib-roundtrip";
        const c1 = try nz.crc32(.{ .str = payload }, null);
        const c2 = try nz.crc32(.{ .str = payload }, null);
        if (c1 <= 0 or c1 != c2) {
            return out_alloc.dupe(u8, "fail:zlib_crc32");
        }

        const gz = try nz.gzipSync(.{ .str = payload }, null);
        defer gz.deinit();
        const unz = try nz.gunzipSync(nz.InputType.from(gz), null);
        defer unz.deinit();
        const unz_bytes = try unz.toOwnedSlice(tracked_alloc);
        defer tracked_alloc.free(unz_bytes);
        if (!std.mem.eql(u8, unz_bytes, payload)) {
            return out_alloc.dupe(u8, "fail:zlib_gzip");
        }

        const br = try nz.brotliCompressSync(.{ .str = payload }, null);
        defer br.deinit();
        const unbr = try nz.brotliDecompressSync(nz.InputType.from(br), null);
        defer unbr.deinit();
        const unbr_bytes = try unbr.toOwnedSlice(tracked_alloc);
        defer tracked_alloc.free(unbr_bytes);
        if (!std.mem.eql(u8, unbr_bytes, payload)) {
            return out_alloc.dupe(u8, "fail:zlib_brotli");
        }
    }

    // 4. `node:async_hooks` (`AsyncLocalStorage` sync `run` + `getStore`)
    {
        const als = try nah.AsyncLocalStorage([]const u8).init(null);
        defer als.deinit();

        if (try als.getStoreAlloc(tracked_alloc)) |s| {
            tracked_alloc.free(s);
            return out_alloc.dupe(u8, "fail:als_initial_nonnull");
        }

        var state = AlsSync.State{ .als = als };
        const ok = try als.runTCallbackToRAlloc(bool, tracked_alloc, "ctx-sync-58", js.closure(&state, AlsSync.onRun));
        if (!ok or !state.matched) {
            return out_alloc.dupe(u8, "fail:als_sync_run");
        }

        if (try als.getStoreAlloc(tracked_alloc)) |s| {
            tracked_alloc.free(s);
            return out_alloc.dupe(u8, "fail:als_post_nonnull");
        }
    }

    // 5. `node:os`, `node:vm`, `node:diagnostics_channel`, `node:sea`, and `node:util/types` + `Float16Array`
    {
        _ = try nos.platform();
        _ = try nos.arch();
        const cpus = try nos.cpusAlloc(tracked_alloc);
        defer js.freeDecoded(@TypeOf(cpus), tracked_alloc, cpus);
        if (cpus.len == 0) {
            return out_alloc.dupe(u8, "fail:os_cpus");
        }
        const tmpdir = try nos.tmpdirAlloc(tracked_alloc);
        defer tracked_alloc.free(tmpdir);
        if (tmpdir.len == 0 or (try nos.totalmem()) <= 0) {
            return out_alloc.dupe(u8, "fail:os_mem");
        }

        const vm_res = try nvm.runInNewContext("21 * 2", null, null);
        defer vm_res.deinit();
        if ((try js.fromJsRef(f64, vm_res)) != 42.0) {
            return out_alloc.dupe(u8, "fail:vm_eval");
        }

        const ch = try ndc.channelDefault(.from("zigar:m4:58"));
        defer ch.deinit();
        if (try ch.hasSubscribers()) {
            return out_alloc.dupe(u8, "fail:dc_subscribers");
        }

        if (try nsea.isSea()) {
            return out_alloc.dupe(u8, "fail:sea_is_sea");
        }

        const f16_arr = try js.Float16Array.fromSlice(&[_]f16{ 1.5, -2.25, 8.0 });
        defer f16_arr.deinit();
        const f16_unk: js.Unknown = .{ .handle = f16_arr.handle };
        if (!(try nut.isFloat16Array(f16_unk))) {
            return out_alloc.dupe(u8, "fail:is_float16_array");
        }
        const narrowed = (try nut.asFloat16Array(f16_unk)) orelse
            return out_alloc.dupe(u8, "fail:as_float16_array");
        defer narrowed.deinit();
        const f16_vals = try narrowed.toOwnedSlice(tracked_alloc);
        defer tracked_alloc.free(f16_vals);
        if (f16_vals.len != 3 or f16_vals[0] != 1.5 or f16_vals[1] != -2.25 or f16_vals[2] != 8.0) {
            return out_alloc.dupe(u8, "fail:float16_roundtrip");
        }

        const plain_obj = try js.Record([]const u8, js.Any).init();
        defer plain_obj.deinit();
        if (js.fromJsRefAlloc(gen.globals.NodeJs.TypedArray(js.ArrayBuffer), tracked_alloc, plain_obj)) |bad_ta| {
            js.freeDecoded(@TypeOf(bad_ta), tracked_alloc, bad_ta);
            return out_alloc.dupe(u8, "fail:plain_obj_matched_typed_array");
        } else |err| {
            if (err != error.TypeError) return err;
        }
    }

    return out_alloc.dupe(u8, "sync-crypto-sqlite-ok");
}

/// Verifies `timers/promises.setTimeoutPromise` returns a raw `js.Promise` synchronously without JSPI,
/// while auto-awaited `timers/promises.setTimeoutAlloc` returns `error.HostUnavailable` leak-free.
pub fn probeSyncCryptoTimersHostUnavailable() !bool {
    const prom = try ntp.setTimeoutPromise([]const u8, 1, "raw-prom", null);
    prom.deinit();

    if (ntp.setTimeoutAlloc([]const u8, tracked_alloc, 1, "must-fail", null)) |val| {
        tracked_alloc.free(val);
        return false;
    } else |err| {
        return err == error.HostUnavailable;
    }
}

const AlsAsync = struct {
    const State = struct {
        als: nah.AsyncLocalStorage([]const u8),
        res: ?nah.AsyncResource = null,
        matched: bool = false,
    };

    fn onCreate(ctx: *State) bool {
        ctx.res = nah.AsyncResource.init("zigar-als-58", null) catch return false;
        return true;
    }

    fn onScope(ctx: *State, _: js.Any) bool {
        const val = (ctx.als.getStoreAlloc(tracked_alloc) catch return false) orelse return false;
        defer tracked_alloc.free(val);
        ctx.matched = std.mem.eql(u8, val, "async-als-58");
        return ctx.matched;
    }
};

const worker_ns = struct {
    pub fn exerciseAsyncCryptoTimersAls(out_alloc: std.mem.Allocator) ![]u8 {
        // 1. WebCrypto `crypto.subtle.digest("SHA-256", ...)` matches sync `crypto.createHash("sha256")`
        {
            const subtle = try nc.subtle.get();
            defer subtle.deinit();

            const u8_in = try js.Uint8Array.fromSlice("ts-zigar-node26");
            defer u8_in.deinit();

            const wc_ab = try subtle.digest(.from("SHA-256"), .from(u8_in));
            defer wc_ab.deinit();
            const wc_bytes = try wc_ab.toOwnedSlice(tracked_alloc);
            defer tracked_alloc.free(wc_bytes);

            const hash = try nc.createHash("sha256", null);
            defer hash.deinit();
            const h_up = try hash.update(.{ .str = "ts-zigar-node26" }, null);
            defer h_up.deinit();
            const sync_buf = try hash.digestEmpty();
            defer sync_buf.deinit();
            const sync_bytes = try sync_buf.toOwnedSlice(tracked_alloc);
            defer tracked_alloc.free(sync_bytes);

            if (wc_bytes.len != 32 or !std.mem.eql(u8, wc_bytes, sync_bytes)) {
                return out_alloc.dupe(u8, "fail:webcrypto_sha256_mismatch");
            }
        }

        // 2. `node:timers/promises` `setTimeoutAlloc`
        {
            const res = try ntp.setTimeoutAlloc([]const u8, tracked_alloc, 5, "timer-58-ok", null);
            defer tracked_alloc.free(res);
            if (!std.mem.eql(u8, res, "timer-58-ok")) {
                return std.fmt.allocPrint(out_alloc, "fail:timers_promises:{s}", .{res});
            }
        }

        // 3. `node:async_hooks` (`AsyncLocalStorage` + `AsyncResource`) context preservation across async `timers/promises` await
        {
            const als = try nah.AsyncLocalStorage([]const u8).init(null);
            defer als.deinit();

            var state = AlsAsync.State{ .als = als };
            const created = try als.runTCallbackToRAlloc(bool, tracked_alloc, "async-als-58", js.closure(&state, AlsAsync.onCreate));
            const async_res = state.res orelse return out_alloc.dupe(u8, "fail:als_res_init");
            defer async_res.deinit();
            if (!created or (try async_res.asyncId()) <= 0) {
                return out_alloc.dupe(u8, "fail:als_res_create");
            }

            try ntp.setTimeoutDefault(5, null, null);

            const scope_ok = try async_res.runInAsyncScope(js.Any, bool, js.closure(&state, AlsAsync.onScope), null, .{});
            const destroyed = try async_res.emitDestroy();
            destroyed.deinit();
            if (!scope_ok or !state.matched) {
                return out_alloc.dupe(u8, "fail:als_async_scope");
            }

            // On WASM JSPI, execution stays on the JS main thread's async context directly across suspension.
            if (is_wasm) {
                try als.enterWith("wasm-jspi-als-58");
                try ntp.setTimeoutDefault(5, null, null);
                const store_after = (try als.getStoreAlloc(tracked_alloc)) orelse {
                    try als.disable();
                    return out_alloc.dupe(u8, "fail:als_jspi_lost");
                };
                defer tracked_alloc.free(store_after);
                try als.disable();
                if (!std.mem.eql(u8, store_after, "wasm-jspi-als-58")) {
                    return std.fmt.allocPrint(out_alloc, "fail:als_jspi_val:{s}", .{store_after});
                }
            }
        }

        return out_alloc.dupe(u8, "async-crypto-timers-als-ok");
    }
};

var work_queue: zigar.thread.WorkQueue(worker_ns) = .{};

fn wasmStartupNoop(_: usize) void {}
fn wasmShutdownNoop() void {}

pub const startup = if (is_wasm) wasmStartupNoop else work_queue.promisify(.startup);
pub const shutdown = if (is_wasm) wasmShutdownNoop else work_queue.promisify(.shutdown);
pub const runAsyncCryptoTimersAls = if (is_wasm) worker_ns.exerciseAsyncCryptoTimersAls else work_queue.promisify(worker_ns.exerciseAsyncCryptoTimersAls);
