const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const g = gen.globals;
const ne = gen.node_events;
const ns = gen.node_stream;
const nsc = gen.node_stream_consumers;
const nsp = gen.node_stream_promises;
const nw = gen.node_stream_web;

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

const MyEvents = struct {
    tick: struct { []const u8, f64 },
    done: @TypeOf(.{}),
};

const AsyncEvents = struct {
    ready: struct { []const u8, f64 },
    data: struct { []const u8 },
};

const TickState = struct {
    count: usize = 0,
    sum: f64 = 0,
    prefix_ok: bool = true,
};

const TickHandlers = struct {
    fn onTick(st: *TickState, label: []const u8, val: f64) void {
        st.count += 1;
        st.sum += val;
        if (!std.mem.startsWith(u8, label, "pkt-")) st.prefix_ok = false;
    }

    fn onDone(done_count: *usize) void {
        done_count.* += 1;
    }
};

const AbortHandlers = struct {
    fn onAbort(cnt: *usize, _: g.Event) void {
        cnt.* += 1;
    }
};

/// Exercises synchronous `node:events` (`EventEmitter(MyEvents)` typed `onInfer`/`onceInfer`/
/// `emitInfer`/`offInfer`/`listenerCountInfer` with both `.enum_literal` and string literal keys,
/// plus `events.addAbortListener` `Symbol.dispose`) and synchronous `node:stream` (`PassThrough`,
/// `Readable.from`, `Readable.toWeb`, and `Readable.fromWeb`).
pub fn exerciseSyncEventsAndStreams(out_alloc: std.mem.Allocator) ![]u8 {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    // 1. Typed `EventEmitter(MyEvents)` comptime event-map lowering & runtime dispatch
    {
        const ee = try ne.EventEmitter(MyEvents).init(null);
        defer ee.deinit();

        var tick_state: TickState = .{};
        var done_count: usize = 0;

        var tick_cl = try js.Closure(*TickState, TickHandlers.onTick).tryInit(&tick_state);
        defer tick_cl.deinit();
        var done_cl = try js.Closure(*usize, TickHandlers.onDone).tryInit(&done_count);
        defer done_cl.deinit();

        {
            const r = try ee.onInfer(.tick, &tick_cl);
            defer r.deinit();
        }
        {
            const r = try ee.onceInfer(.done, &done_cl);
            defer r.deinit();
        }

        if ((try ee.listenerCountInfer(.tick, null)) != 1) return out_alloc.dupe(u8, "fail:lc_tick_1");
        if ((try ee.listenerCountInfer("tick", &tick_cl)) != 1) return out_alloc.dupe(u8, "fail:lc_tick_str");
        if ((try ne.listenerCount(.{ ee.as(ne.EventEmitter(js.Any)), "done" })) != 1) {
            return out_alloc.dupe(u8, "fail:lc_top_done");
        }

        if (!try ee.emitInfer(.tick, .{ "pkt-alpha", @as(f64, 12.5) })) return out_alloc.dupe(u8, "fail:emit_tick_1");
        if (!try ee.emitInfer("tick", .{ "pkt-beta", @as(f64, 29.5) })) return out_alloc.dupe(u8, "fail:emit_tick_2");
        if (!try ee.emitInfer(.done, .{})) return out_alloc.dupe(u8, "fail:emit_done_1");
        if (try ee.emitInfer(.done, .{})) return out_alloc.dupe(u8, "fail:emit_done_twice");

        if (tick_state.count != 2 or tick_state.sum != 42.0 or !tick_state.prefix_ok or done_count != 1) {
            return std.fmt.allocPrint(out_alloc, "fail:typed_ee:{d}:{d}:{d}", .{ tick_state.count, tick_state.sum, done_count });
        }

        {
            const r = try ee.offInfer(.tick, &tick_cl);
            defer r.deinit();
        }
        if ((try ee.listenerCountInfer(.tick, null)) != 0) return out_alloc.dupe(u8, "fail:lc_after_off");
        if (try ee.emitInfer(.tick, .{ "pkt-gamma", @as(f64, 100.0) })) return out_alloc.dupe(u8, "fail:emit_after_off");
        if (tick_state.count != 2) return out_alloc.dupe(u8, "fail:count_after_off");
    }

    // 2. `events.addAbortListener` + `Symbol.dispose` (`disp.dispose()`)
    {
        var abort_count: usize = 0;
        var abort_cl = try js.Closure(*usize, AbortHandlers.onAbort).tryInit(&abort_count);
        defer abort_cl.deinit();

        // Disposed before abort -> listener removed, count stays 0
        {
            const ac1 = try g.AbortController.init();
            defer ac1.deinit();
            const sig1 = try ac1.signal();
            defer sig1.deinit();
            const disp1 = try ne.addAbortListener(sig1, &abort_cl);
            disp1.dispose();
            try ac1.abort(null);
            if (abort_count != 0) return out_alloc.dupe(u8, "fail:abort_disposed_fired");
        }

        // Active during abort -> listener fires once, then `defer disp2.dispose()` cleans up
        {
            const ac2 = try g.AbortController.init();
            defer ac2.deinit();
            const sig2 = try ac2.signal();
            defer sig2.deinit();
            const disp2 = try ne.addAbortListener(sig2, &abort_cl);
            defer disp2.dispose();
            try ac2.abort(null);
            if (abort_count != 1) return out_alloc.dupe(u8, "fail:abort_active_not_fired");
        }
    }

    // 3. Synchronous `node:stream` (`PassThrough`, `Readable.from`, `Readable.toWeb` / `fromWeb`)
    {
        const pt = try ns.PassThrough.init(null);
        defer pt.deinit();
        {
            const r = try pt.setEncoding(.utf8);
            defer r.deinit();
        }
        const c1 = try js.toJsRef([]const u8, "sync-");
        defer c1.deinit();
        const c2 = try js.toJsRef([]const u8, "passthrough");
        defer c2.deinit();
        _ = try pt.writeCallback(c1, null);
        {
            const r = try pt.endWithChunk(c2, null);
            defer r.deinit();
        }
        const read_any = try pt.read(null);
        defer read_any.deinit();
        const read_str = try js.fromJsRefAlloc([]const u8, tracked_alloc, read_any);
        defer tracked_alloc.free(read_str);
        if (!std.mem.eql(u8, read_str, "sync-passthrough")) {
            return std.fmt.allocPrint(out_alloc, "fail:passthrough:{s}", .{read_str});
        }

        // `Readable.from` -> `Readable.toWeb` -> `Readable.fromWeb` roundtrip
        const item = try js.toJsRef([]const u8, "bridge-chunk");
        defer item.deinit();
        const node_r = try ns.Readable.from(.{ .iterable = &.{item} }, null);
        defer node_r.deinit();
        const web_rs = try ns.Readable.toWeb(node_r.as(g.NodeJs.ReadableStream), null);
        defer web_rs.deinit();
        if (!try ns.Readable.isDisturbed(.from(node_r))) {
            // `toWeb` attaches reader to `node_r`; also verify `fromWeb` produces a live `Readable`
        }
        const back_r = try ns.Readable.fromWeb(web_rs, null);
        defer back_r.deinit();
        if (!try back_r.readable()) return out_alloc.dupe(u8, "fail:fromWeb_not_readable");
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return out_alloc.dupe(u8, "sync-events-streams-ok");
}

/// Verifies that calling auto-awaited `stream/consumers.text` without JSPI / off `WorkQueue`
/// returns `error.HostUnavailable` while `textPromise` returns a raw `Promise` leak-free.
pub fn probeSyncStreamConsumersHostUnavailable() !bool {
    const handles_before = js.activeHandleCount();
    const cbs_before = js.activeCallbackCount();
    const allocs_before = live_allocs.load(.acquire);

    var got_unavail = false;
    {
        const s1 = try js.toJsRef([]const u8, "probe");
        defer s1.deinit();
        const r1 = try ns.Readable.from(.{ .iterable = &.{s1} }, null);
        defer r1.deinit();
        const prom = try nsc.textPromise(.from(r1));
        prom.deinit();

        const r2 = try ns.Readable.from(.{ .iterable = &.{s1} }, null);
        defer r2.deinit();
        got_unavail = if (nsc.textAlloc(tracked_alloc, .from(r2))) |txt| blk: {
            tracked_alloc.free(txt);
            break :blk false;
        } else |err| (err == error.HostUnavailable);
    }

    try checkInvariants(handles_before, cbs_before, allocs_before);
    return got_unavail;
}

const PipelineDestFn = struct {
    fn toUpperTextPromise(source: js.AsyncIterator(js.Any)) js.CallError!js.Promise([]const u8) {
        return nsc.textPromise(.{ .async_iterable = source });
    }
};

const WebStreamCallbacks = struct {
    const SinkState = struct {
        out: std.ArrayList(u8) = .empty,
        alloc: std.mem.Allocator,
    };

    fn startEnqueuer(ctrl: nw.ReadableStreamDefaultController([]const u8)) js.CallError!js.Any {
        try ctrl.enqueue("web-hello");
        try ctrl.enqueue("web-world");
        try ctrl.close();
        return js.Any.@"undefined";
    }

    fn startIterChunks(ctrl: nw.ReadableStreamDefaultController([]const u8)) js.CallError!js.Any {
        try ctrl.enqueue("iter-1");
        try ctrl.enqueue("iter-2");
        try ctrl.close();
        return js.Any.@"undefined";
    }

    fn upperTransform(chunk: []const u8, ctrl: nw.TransformStreamDefaultController([]const u8)) js.CallError!?js.Promise(void) {
        var buf: [64]u8 = undefined;
        if (chunk.len > buf.len) return error.Unexpected;
        for (chunk, 0..) |ch, i| {
            buf[i] = std.ascii.toUpper(ch);
        }
        try ctrl.enqueue(buf[0..chunk.len]);
        return null;
    }

    fn sinkWrite(st: *SinkState, chunk: []const u8, _: nw.WritableStreamDefaultController) js.CallError!?js.Promise(void) {
        if (st.out.items.len > 0) st.out.append(st.alloc, '|') catch return error.Unexpected;
        st.out.appendSlice(st.alloc, chunk) catch return error.Unexpected;
        return null;
    }
};

const worker_ns = struct {
    /// Exercises async `events.once`, `events.on` (`AsyncIterator` + `AbortSignal`),
    /// `node:stream` `Readable.asyncIterator`, `node:stream/consumers` (`text`, `json`, `buffer`),
    /// `node:stream/promises` (`pipeline` stream + callback `PipelineResult<B>` unwrapping + `finished`),
    /// and `node:stream/web` (`ReadableStream`, `TransformStream`, `WritableStream`, `pipeThrough`,
    /// `pipeTo`, `TextEncoderStream`, and `ReadableStream.asyncIterator`).
    pub fn exerciseAsyncEventsAndStreams(out_alloc: std.mem.Allocator) ![]u8 {
        const handles_before = js.activeHandleCount();
        const cbs_before = js.activeCallbackCount();
        const allocs_before = live_allocs.load(.acquire);

        // 1. `events.oncePromise` + `events.on` (`AsyncIterator`)
        {
            const ee = try ne.EventEmitter(AsyncEvents).init(null);
            defer ee.deinit();

            const once_prom = try ne.oncePromise(.{ ee.as(ne.EventEmitter(js.Any)), "ready", null });
            defer once_prom.deinit();
            if (!try ee.emitInfer(.ready, .{ "booted", @as(f64, 26) })) {
                return out_alloc.dupe(u8, "fail:once_emit");
            }
            const once_args = try once_prom.awaitAlloc(tracked_alloc);
            defer js.freeDecoded([]const js.Any, tracked_alloc, once_args);
            if (once_args.len != 2) return out_alloc.dupe(u8, "fail:once_argc");
            const arg0_s = try js.fromJsRefAlloc([]const u8, tracked_alloc, once_args[0]);
            defer tracked_alloc.free(arg0_s);
            const arg1_n = try js.fromJsRef(f64, once_args[1]);
            if (!std.mem.eql(u8, arg0_s, "booted") or arg1_n != 26) {
                return std.fmt.allocPrint(out_alloc, "fail:once_vals:{s}:{d}", .{ arg0_s, arg1_n });
            }

            const ac = try g.AbortController.init();
            defer ac.deinit();
            const sig = try ac.signal();
            defer sig.deinit();
            const on_it = try ne.on(.{ ee.as(ne.EventEmitter(js.Any)), "data", .{ .signal = sig } });
            defer on_it.closeAndDeinit();

            _ = try ee.emitInfer(.data, .{"ev-one"});
            _ = try ee.emitInfer(.data, .{"ev-two"});

            const batch1 = (try on_it.nextAlloc(tracked_alloc)) orelse return out_alloc.dupe(u8, "fail:on_it_1_null");
            defer js.freeDecoded([]const js.Any, tracked_alloc, batch1);
            const batch2 = (try on_it.nextAlloc(tracked_alloc)) orelse return out_alloc.dupe(u8, "fail:on_it_2_null");
            defer js.freeDecoded([]const js.Any, tracked_alloc, batch2);

            const b1_s = try js.fromJsRefAlloc([]const u8, tracked_alloc, batch1[0]);
            defer tracked_alloc.free(b1_s);
            const b2_s = try js.fromJsRefAlloc([]const u8, tracked_alloc, batch2[0]);
            defer tracked_alloc.free(b2_s);
            if (!std.mem.eql(u8, b1_s, "ev-one") or !std.mem.eql(u8, b2_s, "ev-two")) {
                return std.fmt.allocPrint(out_alloc, "fail:on_it_vals:{s}:{s}", .{ b1_s, b2_s });
            }
        }

        // 2. `node:stream` `Readable.asyncIterator` + `node:stream/consumers` (`text`, `json`, `buffer`)
        {
            const a1 = try js.toJsRef([]const u8, "alpha");
            defer a1.deinit();
            const a2 = try js.toJsRef([]const u8, "-beta");
            defer a2.deinit();

            const r_iter = try ns.Readable.from(.{ .iterable = &.{ a1, a2 } }, null);
            defer r_iter.deinit();
            const ait = try r_iter.asyncIterator();
            defer ait.deinit();
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(tracked_alloc);
            while (try ait.next()) |chunk_any| {
                defer chunk_any.deinit();
                const chunk_s = try js.fromJsRefAlloc([]const u8, tracked_alloc, chunk_any);
                defer tracked_alloc.free(chunk_s);
                try joined.appendSlice(tracked_alloc, chunk_s);
            }
            if (!std.mem.eql(u8, joined.items, "alpha-beta")) {
                return std.fmt.allocPrint(out_alloc, "fail:readable_aiter:{s}", .{joined.items});
            }

            // `consumers.text` (exercises `.from(r)` inheritance upcast `stream.Readable` -> `NodeJS.ReadableStream`)
            const r_txt = try ns.Readable.from(.{ .iterable = &.{ a1, a2 } }, null);
            defer r_txt.deinit();
            const txt = try nsc.textAlloc(tracked_alloc, .from(r_txt));
            defer tracked_alloc.free(txt);
            if (!std.mem.eql(u8, txt, "alpha-beta")) {
                return std.fmt.allocPrint(out_alloc, "fail:consumers_text:{s}", .{txt});
            }

            // `consumers.json`
            const j_part = try js.toJsRef([]const u8, "{\"runtime\":\"node26\",\"ok\":true}");
            defer j_part.deinit();
            const r_json = try ns.Readable.from(.{ .iterable = &.{j_part} }, null);
            defer r_json.deinit();
            const parsed = try nsc.json(.from(r_json));
            defer parsed.deinit();
            const rt_val = try js.getInstancePropAlloc([]const u8, tracked_alloc, .{ .handle = parsed.handle }, "runtime");
            defer tracked_alloc.free(rt_val);
            const ok_val = try js.getInstanceProp(bool, .{ .handle = parsed.handle }, "ok");
            if (!std.mem.eql(u8, rt_val, "node26") or !ok_val) {
                return std.fmt.allocPrint(out_alloc, "fail:consumers_json:{s}", .{rt_val});
            }

            // `consumers.buffer`
            const r_buf = try ns.Readable.from(.{ .iterable = &.{ a1, a2 } }, null);
            defer r_buf.deinit();
            const buf = try nsc.buffer(.from(r_buf));
            defer buf.deinit();
            const buf_bytes = try buf.toOwnedSlice(tracked_alloc);
            defer tracked_alloc.free(buf_bytes);
            if (!std.mem.eql(u8, buf_bytes, "alpha-beta")) {
                return std.fmt.allocPrint(out_alloc, "fail:consumers_buffer:{s}", .{buf_bytes});
            }
        }

        // 3. `node:stream/promises` (`pipeline` stream chain, `finished`, and callback `PipelineResult<B>`)
        {
            const p1 = try js.toJsRef([]const u8, "pipe-left:");
            defer p1.deinit();
            const p2 = try js.toJsRef([]const u8, "pipe-right");
            defer p2.deinit();

            const src1 = try ns.Readable.from(.{ .iterable = &.{ p1, p2 } }, null);
            defer src1.deinit();
            const mid = try ns.PassThrough.init(null);
            defer mid.deinit();
            const dst = try ns.PassThrough.init(null);
            defer dst.deinit();

            try nsp.pipelineAt1BPipelineOptionsOptInfer(
                src1.as(g.NodeJs.ReadableStream),
                mid.as(g.NodeJs.ReadWriteStream),
                dst.as(g.NodeJs.WritableStream),
                null,
            );
            try nsp.finished(.from(dst), .{ .readable = false, .cleanup = true });

            const dst_txt = try nsc.textAlloc(tracked_alloc, .from(dst));
            defer tracked_alloc.free(dst_txt);
            if (!std.mem.eql(u8, dst_txt, "pipe-left:pipe-right")) {
                return std.fmt.allocPrint(out_alloc, "fail:pipeline_streams:{s}", .{dst_txt});
            }
            try nsp.finished(.from(dst), .{ .cleanup = true });

            // Callback destination returning `Promise<[]const u8>` -> unwrapped by `PipelineResult<B>` to `[]const u8`!
            const src2 = try ns.Readable.from(.{ .iterable = &.{ p1, p2 } }, null);
            defer src2.deinit();
            var dest_cl = try js.Closure(void, PipelineDestFn.toUpperTextPromise).tryInit();
            defer dest_cl.deinit();

            const cb_res = try nsp.pipelineAbPipelineOptionsOptInferAlloc(
                tracked_alloc,
                src2.as(g.NodeJs.ReadableStream),
                &dest_cl,
                null,
            );
            defer tracked_alloc.free(cb_res);
            if (!std.mem.eql(u8, cb_res, "pipe-left:pipe-right")) {
                return std.fmt.allocPrint(out_alloc, "fail:pipeline_cb_result:{s}", .{cb_res});
            }
        }

        // 4. `node:stream/web` (`ReadableStream` -> `TransformStream` -> `WritableStream`, `TextEncoderStream`, `asyncIterator`)
        {
            var start_cl = try js.Closure(void, WebStreamCallbacks.startEnqueuer).tryInit();
            defer start_cl.deinit();
            var xform_cl = try js.Closure(void, WebStreamCallbacks.upperTransform).tryInit();
            defer xform_cl.deinit();
            var sink_state: WebStreamCallbacks.SinkState = .{ .alloc = tracked_alloc };
            defer sink_state.out.deinit(tracked_alloc);
            var sink_cl = try js.Closure(*WebStreamCallbacks.SinkState, WebStreamCallbacks.sinkWrite).tryInit(&sink_state);
            defer sink_cl.deinit();

            const rs = try nw.ReadableStream([]const u8).initUnderlyingDefaultSource(.{
                .start = .{ .ref = start_cl.func },
            }, null);
            defer rs.deinit();

            const ts = try nw.TransformStream([]const u8, []const u8).init(.{
                .transform = .{ .ref = xform_cl.func },
            }, null, null);
            defer ts.deinit();

            const ws = try nw.WritableStream([]const u8).init(.{
                .write = .{ .ref = sink_cl.func },
            }, null);
            defer ws.deinit();

            const ts_readable = try ts.readable();
            defer ts_readable.deinit();
            const ts_writable = try ts.writable();
            defer ts_writable.deinit();

            const piped = try rs.pipeThrough([]const u8, .{
                .readable = ts_readable,
                .writable = ts_writable,
            }, null);
            defer piped.deinit();
            try piped.pipeTo(ws, null);

            if (!std.mem.eql(u8, sink_state.out.items, "WEB-HELLO|WEB-WORLD")) {
                return std.fmt.allocPrint(out_alloc, "fail:web_pipe:{s}", .{sink_state.out.items});
            }

            // `TextEncoderStream` + `WritableStreamDefaultWriter` + `consumers.text` generic handle erasure
            const enc = try nw.TextEncoderStream.init();
            defer enc.deinit();
            const enc_w = try enc.writable();
            defer enc_w.deinit();
            const enc_r = try enc.readable();
            defer enc_r.deinit();

            // Start consuming `enc_r` before awaiting `writer.write` so backpressure drains cleanly!
            const consume_prom = try nsc.textPromise(.from(enc_r));
            defer consume_prom.deinit();

            const writer = try enc_w.getWriter();
            defer writer.deinit();
            try writer.write("zig-web-encoder");
            try writer.close();

            const decoded_txt = try consume_prom.awaitAlloc(tracked_alloc);
            defer tracked_alloc.free(decoded_txt);
            if (!std.mem.eql(u8, decoded_txt, "zig-web-encoder")) {
                return std.fmt.allocPrint(out_alloc, "fail:web_encoder:{s}", .{decoded_txt});
            }

            // `ReadableStream([]const u8).asyncIterator()`
            var iter_start_cl = try js.Closure(void, WebStreamCallbacks.startIterChunks).tryInit();
            defer iter_start_cl.deinit();
            const rs_iter = try nw.ReadableStream([]const u8).initUnderlyingDefaultSource(.{
                .start = .{ .ref = iter_start_cl.func },
            }, null);
            defer rs_iter.deinit();

            const web_it = try rs_iter.asyncIterator();
            defer web_it.deinit();
            var web_joined: std.ArrayList(u8) = .empty;
            defer web_joined.deinit(tracked_alloc);
            while (try web_it.nextAlloc(tracked_alloc)) |chunk| {
                defer tracked_alloc.free(chunk);
                if (web_joined.items.len > 0) try web_joined.append(tracked_alloc, '+');
                try web_joined.appendSlice(tracked_alloc, chunk);
            }
            if (!std.mem.eql(u8, web_joined.items, "iter-1+iter-2")) {
                return std.fmt.allocPrint(out_alloc, "fail:web_aiter:{s}", .{web_joined.items});
            }
        }

        try checkInvariants(handles_before, cbs_before, allocs_before);
        return out_alloc.dupe(u8, "async-events-streams-ok");
    }
};

fn wasmStartupNoop(_: usize) void {}
fn wasmShutdownNoop() void {}

var work_queue: if (is_wasm) void else zigar.thread.WorkQueue(worker_ns) = if (is_wasm) {} else .{};

pub const startup = if (is_wasm) wasmStartupNoop else work_queue.promisify(.startup);
pub const shutdown = if (is_wasm) wasmShutdownNoop else work_queue.promisify(.shutdown);
pub const runAsyncEventsAndStreams = if (is_wasm) worker_ns.exerciseAsyncEventsAndStreams else work_queue.promisify(worker_ns.exerciseAsyncEventsAndStreams);
