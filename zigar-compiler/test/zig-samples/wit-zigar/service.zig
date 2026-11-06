const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// 1. wit-zigar Generated Blittable C-ABI Types & WASI 0.3 Handles
// ============================================================================

pub const Point = extern struct {
    x: f32,
    y: f32,
};

pub const Rect = extern struct {
    origin: Point,
    size: Point,
};

pub const Flags32 = extern struct {
    bits: u32 = 0,

    pub fn has(self: Flags32, bit: u5) bool {
        return (self.bits & (@as(u32, 1) << bit)) != 0;
    }

    pub fn set(self: *Flags32, bit: u5) void {
        self.bits |= (@as(u32, 1) << bit);
    }

    pub fn clear(self: *Flags32, bit: u5) void {
        self.bits &= ~(@as(u32, 1) << bit);
    }
};

pub fn Result(comptime Ok: type, comptime Err: type) type {
    return union(enum) {
        ok: Ok,
        err: Err,

        pub fn isOk(self: @This()) bool {
            return self == .ok;
        }
    };
}

pub const RectResult = Result(Rect, u32);

pub fn Own(comptime T: type) type {
    _ = T;
    return extern struct {
        handle: i32,
    };
}

pub fn Borrow(comptime T: type) type {
    _ = T;
    return extern struct {
        handle: i32,
    };
}

pub fn Stream(comptime T: type) type {
    _ = T;
    return extern struct {
        handle: i32,
    };
}

pub fn Future(comptime T: type) type {
    _ = T;
    return extern struct {
        handle: i32,
    };
}

pub const PointStream = Stream(Point);
pub const RectFuture = Future(Rect);
pub const PointSlice = []Point;
pub const RectSlice = []const Rect;

pub const AsyncComputeReport = extern struct {
    rect: Rect,
    host_value: u32,
    sp_before: u32,
    sp_after: u32,
    frame_addr: u32,
    concurrent_active: u32,
    peak_concurrent: u32,
    suspension_count: u32,
};

// ============================================================================
// 2. wit-zigar Zero-Copy Fast ABI (FastLower / FastLift / MemoryContext)
// ============================================================================

const FastAbiVerify = struct {
    pub fn isZeroCopyStruct(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .@"struct" => |s| s.layout == .@"extern",
            else => false,
        };
    }

    pub fn isZeroCopySlice(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .pointer => |p| p.size == .slice and (isZeroCopyStruct(p.child) or switch (@typeInfo(p.child)) {
                .int, .float, .bool => true,
                else => false,
            }),
            else => false,
        };
    }
};

const MemoryContext = struct {
    base: [*]u8,
    len: usize,
    offset: usize = 0,

    pub fn init(buf: []u8) MemoryContext {
        return .{
            .base = buf.ptr,
            .len = buf.len,
            .offset = 0,
        };
    }

    pub fn realloc(self: *MemoryContext, new_align: usize, new_size: usize) ?[*]u8 {
        const align_mask = new_align - 1;
        const aligned_offset = (self.offset + align_mask) & ~align_mask;
        if (aligned_offset + new_size > self.len) return null;
        self.offset = aligned_offset + new_size;
        return self.base + aligned_offset;
    }
};

const FastLower = struct {
    pub fn lowerExtern(comptime T: type, value: T) T {
        comptime {
            if (!FastAbiVerify.isZeroCopyStruct(T)) {
                @compileError("FastLower.lowerExtern requires extern struct");
            }
        }
        return value;
    }

    pub fn lowerIntoScratch(comptime T: type, ctx: *MemoryContext, value: T) !*T {
        const raw = ctx.realloc(@alignOf(T), @sizeOf(T)) orelse return error.OutOfScratchMemory;
        const ptr: *T = @ptrCast(@alignCast(raw));
        ptr.* = lowerExtern(T, value);
        return ptr;
    }
};

const FastLift = struct {
    pub fn liftExtern(comptime T: type, bytes: []const u8) !T {
        comptime {
            if (!FastAbiVerify.isZeroCopyStruct(T)) {
                @compileError("FastLift.liftExtern requires extern struct");
            }
        }
        if (bytes.len < @sizeOf(T)) return error.BufferTooSmall;
        var out: T = undefined;
        @memcpy(std.mem.asBytes(&out), bytes[0..@sizeOf(T)]);
        return out;
    }
};

const TransformRectArgs = extern struct {
    retval: Rect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .x = 0, .y = 0 } },
    r: Rect,
    dx: f32,
    dy: f32,
    scale: f32,
};

fn FastExportThunk(comptime func: anytype, comptime ArgsT: type) type {
    return struct {
        pub fn call(arg_ptr: *anyopaque) callconv(.c) bool {
            const args: *ArgsT = @ptrCast(@alignCast(arg_ptr));
            args.retval = func(args.r, args.dx, args.dy, args.scale);
            return true;
        }
    };
}

export fn __zigar_fast_transform_rect(arg_ptr: *anyopaque) callconv(.c) bool {
    return FastExportThunk(transformRect, TransformRectArgs).call(arg_ptr);
}

// ============================================================================
// 3. "zigar:abi" Custom Section Metadata (Magic "ZGAR" v1)
// ============================================================================

pub const zigar_abi = struct {
    pub const world: []const u8 = "wit-zigar-service";
    pub const version: u32 = 1;
    pub const zero_copy_extern: bool = true;
    pub const jspi_async: bool = true;
};

// Binary "zigar:abi" section payload:
//   [0..4]  Magic "ZGAR" (0x5A, 0x47, 0x41, 0x52)
//   [4..6]  Version 1 (u16 LE)
//   [6..8]  Flags: 0x0007 (has_async_exports | has_async_imports | zero_copy_extern)
//   [8..12] Export count: 5 (u32 LE)
//   [12..]  Descriptor tag "wit-zigar:service:v1"
const zigar_abi_section_payload = [32]u8{
    'Z', 'G', 'A', 'R',
    0x01, 0x00,
    0x07, 0x00,
    0x05, 0x00, 0x00, 0x00,
    'w', 'i', 't', '-', 'z', 'i', 'g', 'a', 'r', ':', 's', 'e', 'r', 'v', 'i', 'c', 'e', ':', 'v', '1',
};

export const __zigar_abi_bytes: [zigar_abi_section_payload.len]u8 linksection("zigar:abi") = zigar_abi_section_payload;

export fn __zigar_abi_ptr() [*]const u8 {
    return &__zigar_abi_bytes;
}

export fn __zigar_abi_len() usize {
    return __zigar_abi_bytes.len;
}

pub fn getZigarAbiMagic() u32 {
    return std.mem.readInt(u32, __zigar_abi_bytes[0..4], .little);
}

// ============================================================================
// 4. WASI 0.3 Stackful Async Coroutine Runtime (ShadowStack / TaskContext / WaitableSet)
// ============================================================================

pub const STACK_CANARY: u32 = 0xDEAD_BEEF;

pub const SubtaskState = enum(u8) {
    starting = 0,
    started = 1,
    returned = 2,
    cancelled_before_started = 3,
    cancelled_before_returned = 4,
};

pub const EventCode = enum(u8) {
    none = 0,
    subtask = 1,
    stream_read = 2,
    stream_write = 3,
    future_read = 4,
    future_write = 5,
    task_cancelled = 6,
};

pub const CallbackCode = enum(u8) {
    exit = 0,
    yield = 1,
    wait = 2,
};

pub const TaskState = enum(u8) {
    initial,
    running,
    suspended,
    completed,
    cancelled,
};

const ShadowStack = struct {
    base: [*]align(16) u8,
    size: usize,
    sp: usize,
    initial_sp: usize,

    pub fn init(buf: []align(16) u8) !ShadowStack {
        if (buf.len < 64 or (buf.len & 15) != 0) return error.InvalidStackSize;
        const base_addr = @intFromPtr(buf.ptr);
        const top_addr = (base_addr + buf.len) & ~@as(usize, 15);
        std.mem.writeInt(u32, buf[0..4], STACK_CANARY, .little);
        return .{
            .base = buf.ptr,
            .size = buf.len,
            .sp = top_addr,
            .initial_sp = top_addr,
        };
    }

    pub fn checkCanary(self: *const ShadowStack) bool {
        const val = std.mem.readInt(u32, self.base[0..4], .little);
        return val == STACK_CANARY and self.sp >= @intFromPtr(self.base) + 16;
    }

    pub fn allocFrame(self: *ShadowStack, frame_size: usize, alignment: usize) !usize {
        const aligned_size = (frame_size + 15) & ~@as(usize, 15);
        const min_sp = @intFromPtr(self.base) + 16;
        if (self.sp < min_sp + aligned_size) return error.ShadowStackOverflow;
        const next_sp = (self.sp - aligned_size) & ~(alignment - 1);
        if (next_sp < min_sp) return error.ShadowStackOverflow;
        self.sp = next_sp;
        return next_sp;
    }

    pub fn restoreFrame(self: *ShadowStack, saved_sp: usize) !void {
        if ((saved_sp & 15) != 0) return error.UnalignedStackPointer;
        if (saved_sp < @intFromPtr(self.base) + 16 or saved_sp > self.initial_sp) {
            return error.StackPointerOutOfBounds;
        }
        self.sp = saved_sp;
    }
};

const WaitableEvent = extern struct {
    code: EventCode = .none,
    index: u32 = 0,
    payload: u32 = 0,
    result_value: u32 = 0,
};

const WaitableSet = struct {
    id: u32,
    joined_subtasks: [8]u32 = @splat(0),
    joined_count: usize = 0,
    pending_event: ?WaitableEvent = null,

    pub fn init(id: u32) WaitableSet {
        return .{ .id = id };
    }

    pub fn join(self: *WaitableSet, subtask_id: u32) !void {
        if (self.joined_count >= self.joined_subtasks.len) return error.WaitableSetFull;
        self.joined_subtasks[self.joined_count] = subtask_id;
        self.joined_count += 1;
    }

    pub fn notifySubtask(self: *WaitableSet, subtask_id: u32, state: SubtaskState, result_value: u32) void {
        self.pending_event = .{
            .code = .subtask,
            .index = subtask_id,
            .payload = @intFromEnum(state),
            .result_value = result_value,
        };
    }

    pub fn poll(self: *WaitableSet) ?WaitableEvent {
        const ev = self.pending_event;
        self.pending_event = null;
        return ev;
    }
};

const TaskContext = struct {
    task_id: u32,
    state: TaskState = .initial,
    stack: ShadowStack,
    saved_wasm_sp: u32 = 0,
    waiting_on_subtask: u32 = 0,
    callback_code: CallbackCode = .exit,
    result: ?u32 = null,

    pub fn start(self: *TaskContext) !void {
        if (self.state != .initial) return error.InvalidTaskTransition;
        self.state = .running;
    }

    pub fn suspendAt(self: *TaskContext, wasm_sp: u32, subtask_id: u32) !void {
        if (self.state != .running) return error.InvalidTaskTransition;
        if (!self.stack.checkCanary()) return error.ShadowStackCorrupted;
        self.saved_wasm_sp = wasm_sp;
        self.waiting_on_subtask = subtask_id;
        self.callback_code = .wait;
        self.state = .suspended;
    }

    pub fn resumeTask(self: *TaskContext) !void {
        if (self.state != .suspended) return error.InvalidTaskTransition;
        if (!self.stack.checkCanary()) return error.ShadowStackCorrupted;
        self.waiting_on_subtask = 0;
        self.state = .running;
    }

    pub fn complete(self: *TaskContext, value: u32) !void {
        if (self.state != .running) return error.InvalidTaskTransition;
        if (!self.stack.checkCanary()) return error.ShadowStackCorrupted;
        self.result = value;
        self.callback_code = .exit;
        self.state = .completed;
    }
};

// Reads the active Wasm linear shadow stack pointer (__stack_pointer / global[0])
// via a non-inlined 16-byte-aligned stack allocation so LLVM must emit `global.get $__stack_pointer`
// on each call (both before and after JSPI suspension).
noinline fn readStackPointer() u32 {
    var slot: [16]u8 align(16) = @splat(0x5A);
    std.mem.doNotOptimizeAway(&slot);
    return @intCast(@intFromPtr(&slot));
}

// Concurrency tracking across JSPI suspension points
var active_tasks: u32 = 0;
var peak_concurrent: u32 = 0;
var total_suspensions: u32 = 0;

pub fn resetConcurrencyStats() void {
    active_tasks = 0;
    peak_concurrent = 0;
    total_suspensions = 0;
}

pub fn getPeakConcurrent() u32 {
    return peak_concurrent;
}

// ============================================================================
// 5. Exported Functions Consumed by JS via zigar
// ============================================================================

/// 1. Zero-copy DataView-backed extern struct transformation
pub fn transformRect(r: Rect, dx: f32, dy: f32, scale: f32) Rect {
    return .{
        .origin = .{
            .x = r.origin.x + dx,
            .y = r.origin.y + dy,
        },
        .size = .{
            .x = r.size.x * scale,
            .y = r.size.y * scale,
        },
    };
}

/// 2a. Zero-copy const slice of extern structs
pub fn sumRectAreas(rects: []const Rect) f32 {
    var total: f32 = 0;
    for (rects) |r| {
        total += r.size.x * r.size.y;
    }
    return total;
}

/// 2b. Zero-copy mutable slice of extern structs (in-place scaling)
pub fn scalePointsInPlace(points: []Point, factor: f32) void {
    for (points) |*pt| {
        pt.x *= factor;
        pt.y *= factor;
    }
}

/// 3. Exercises wit-zigar FastLower -> FastExportThunk -> FastLift over an in-module MemoryContext scratch region
pub fn fastAbiRoundTrip(r: Rect, dx: f32, dy: f32, scale: f32) !Rect {
    if (!comptime (FastAbiVerify.isZeroCopyStruct(Point) and
        FastAbiVerify.isZeroCopyStruct(Rect) and
        FastAbiVerify.isZeroCopySlice([]const Rect) and
        FastAbiVerify.isZeroCopySlice([]Point)))
    {
        return error.InvalidZeroCopyAbi;
    }

    var scratch_buf: [512]u8 align(16) = undefined;
    var mem_ctx = MemoryContext.init(&scratch_buf);

    const lowered_rect_ptr = try FastLower.lowerIntoScratch(Rect, &mem_ctx, r);
    const args_raw = mem_ctx.realloc(@alignOf(TransformRectArgs), @sizeOf(TransformRectArgs)) orelse return error.OutOfScratchMemory;
    const args_ptr: *TransformRectArgs = @ptrCast(@alignCast(args_raw));
    args_ptr.* = .{
        .r = lowered_rect_ptr.*,
        .dx = dx,
        .dy = dy,
        .scale = scale,
    };

    if (!__zigar_fast_transform_rect(args_ptr)) {
        return error.FastThunkFailed;
    }

    const lifted = try FastLift.liftExtern(Rect, std.mem.asBytes(&args_ptr.retval));
    return lifted;
}

/// 4. Exercises stackful WASI 0.3 WaitableSet + SubtaskState.started -> SubtaskState.returned + TaskContext shadow-stack switching
pub fn canonAbiAsyncSubtask(a: u32, b: u32) !u32 {
    var shadow_buf: [4096]u8 align(16) = undefined;
    const shadow_stack = try ShadowStack.init(&shadow_buf);

    var task_ctx = TaskContext{
        .task_id = 1,
        .stack = shadow_stack,
    };
    try task_ctx.start();

    // Allocate a 16-byte-aligned subtask frame on the WASI 0.3 shadow stack
    const saved_sp = task_ctx.stack.sp;
    const frame_addr = try task_ctx.stack.allocFrame(32, 16);
    if ((frame_addr & 15) != 0) return error.UnalignedShadowFrame;

    // Write subtask operands into the shadow stack frame
    const frame_words: *[2]u32 = @ptrFromInt(frame_addr);
    frame_words[0] = a;
    frame_words[1] = b;

    var waitable_set = WaitableSet.init(100);
    const subtask_id: u32 = 42;
    try waitable_set.join(subtask_id);

    // Transition subtask to `started` and suspend the current task context
    const wasm_sp_before = readStackPointer();
    try task_ctx.suspendAt(wasm_sp_before, subtask_id);
    if (task_ctx.state != .suspended or task_ctx.callback_code != .wait) {
        return error.SubtaskDidNotSuspend;
    }

    // Complete subtask on the shadow frame (`SubtaskState.started` -> `SubtaskState.returned`)
    const partial = frame_words[0] +% frame_words[1];
    waitable_set.notifySubtask(subtask_id, .returned, partial);

    // Poll WaitableSet and resume TaskContext
    const event = waitable_set.poll() orelse return error.MissingWaitableEvent;
    if (event.code != .subtask or event.index != subtask_id) {
        return error.UnexpectedWaitableEvent;
    }
    const subtask_state: SubtaskState = @enumFromInt(event.payload);
    if (subtask_state != .returned) {
        return error.SubtaskNotReturned;
    }

    try task_ctx.resumeTask();
    const wasm_sp_after = readStackPointer();
    if (wasm_sp_before != wasm_sp_after or (wasm_sp_before & 15) != 0) {
        return error.StackPointerMismatch;
    }

    try task_ctx.stack.restoreFrame(saved_sp);
    try task_ctx.complete(event.result_value);

    return task_ctx.result orelse error.MissingTaskResult;
}

/// 5. Calls an imported JS async host function across WebAssembly JSPI (`WebAssembly.Suspending` + `WebAssembly.promising`),
///    recording `__stack_pointer` (`sp_before`, `sp_after`) and concurrent task interleaving (`concurrent_active`, `peak_concurrent`).
pub fn asyncComputeWithHost(
    input: Rect,
    delay_ms: u32,
    host_fn: *const fn (u32, u32) u32,
) AsyncComputeReport {
    active_tasks += 1;
    if (active_tasks > peak_concurrent) {
        peak_concurrent = active_tasks;
    }
    total_suspensions += 1;
    const task_seq = total_suspensions;
    const concurrent_at_entry = active_tasks;

    const frame_addr: u32 = @intCast(@frameAddress());
    const sp_before = readStackPointer();

    // Calling `host_fn` invokes `env._handleJscall` wrapped in `WebAssembly.Suspending`.
    // When the JS function returns a Promise, V8 JSPI suspends this Wasm stack and switches
    // `__stack_pointer` (`global[0]`) to the next continuation stack.
    const host_val = host_fn(task_seq, delay_ms);

    const sp_after = readStackPointer();
    const concurrent_at_resume = active_tasks;
    const observed_concurrent = @max(concurrent_at_entry, concurrent_at_resume);
    const observed_peak = peak_concurrent;

    active_tasks -= 1;

    const delta = @as(f32, @floatFromInt(host_val & 0xFFFF));
    const scale_factor: f32 = 1.0 + (@as(f32, @floatFromInt((host_val >> 16) & 0xFF)) / 10.0);

    return .{
        .rect = transformRect(input, delta, delta * 0.5, scale_factor),
        .host_value = host_val,
        .sp_before = sp_before,
        .sp_after = sp_after,
        .frame_addr = frame_addr,
        .concurrent_active = observed_concurrent,
        .peak_concurrent = observed_peak,
        .suspension_count = task_seq,
    };
}
