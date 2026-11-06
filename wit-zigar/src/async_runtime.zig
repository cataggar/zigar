//! WASI Preview 3 (0.3.0) Stackful Async Coroutine & Host Concurrency Runtime
//! for `wit-zigar`.
//!
//! Provides:
//! 1. Dual-stack shadow-stack pool (`ShadowStack`, `ShadowStackPool`,
//!    `StackPointerBinding`, `TaskContext`) with `0xDEADBEEF_CAFEBABE` base
//!    canary verification and `noinline` frame activation trampolines.
//! 2. WASI 0.3 concurrency wire primitives (`SubtaskState`, `EventCode`,
//!    `WaitEvent`, `CallbackCode`, `StreamStatus` / `StreamResult`).
//! 3. `AsyncScheduler` integrated with Zig 0.17 `std.Io`, managing 1-based
//!    handle tables for `WaitableSet`, `Subtask`, `StreamChannel`, and
//!    `FutureChannel`, guest callback-code execution (`driveGuestAsyncTask`),
//!    and `canon.MemoryContext` subtask/task completion hooks.

const std = @import("std");
const builtin = @import("builtin");
const canon = @import("canon.zig");

// ── Constants & Errors ─────────────────────────────────────────────────────

pub const DEFAULT_SHADOW_STACK_SIZE: usize = 64 * 1024;
pub const SHADOW_STACK_ALIGNMENT: std.mem.Alignment = .@"16";
pub const STACK_CANARY: u64 = 0xDEADBEEF_CAFEBABE;
pub const stack_canary: u64 = STACK_CANARY;
pub const BLOCKED: u32 = 0xffff_ffff;

pub const Error = error{
    StackOverflow,
    InvalidHandle,
    InvalidWaitableSet,
    InvalidSubtaskState,
    InvalidContextSlot,
    InvalidCallbackCode,
    DeadlockDetected,
    StreamClosed,
    FutureAlreadyResolved,
    FutureDropped,
    TaskDidNotExit,
} || canon.Error;

// ── Wasm / Host Stack Pointer Access ───────────────────────────────────────

threadlocal var simulated_wasm_sp: usize = 0;
threadlocal var active_task_tls: ?*TaskContext = null;

/// Reads the WebAssembly linear-memory shadow stack pointer (`__stack_pointer`,
/// `global[0]`). On non-Wasm host targets, reads a thread-local simulated
/// stack pointer.
pub inline fn getWasmStackPointer() usize {
    return switch (builtin.cpu.arch) {
        .wasm32 => asm volatile (
            \\.globaltype __stack_pointer, i32
            \\global.get __stack_pointer
            \\local.set %[out]
            : [out] "=r" (-> usize),
        ),
        .wasm64 => asm volatile (
            \\.globaltype __stack_pointer, i64
            \\global.get __stack_pointer
            \\local.set %[out]
            : [out] "=r" (-> usize),
        ),
        else => simulated_wasm_sp,
    };
}

/// Writes the WebAssembly linear-memory shadow stack pointer (`__stack_pointer`,
/// `global[0]`). On non-Wasm host targets, updates the thread-local simulated
/// stack pointer.
pub inline fn setWasmStackPointer(sp: usize) void {
    switch (builtin.cpu.arch) {
        .wasm32 => asm volatile (
            \\.globaltype __stack_pointer, i32
            \\local.get %[sp]
            \\global.set __stack_pointer
            :
            : [sp] "r" (sp),
        ),
        .wasm64 => asm volatile (
            \\.globaltype __stack_pointer, i64
            \\local.get %[sp]
            \\global.set __stack_pointer
            :
            : [sp] "r" (sp),
        ),
        else => {
            simulated_wasm_sp = sp;
        },
    }
}

pub const getStackPointer = getWasmStackPointer;
pub const setStackPointer = setWasmStackPointer;

/// Returns the currently active `TaskContext` on the calling thread, if any.
pub inline fn getActiveTask() ?*TaskContext {
    return active_task_tls;
}

/// Sets the currently active `TaskContext` on the calling thread.
pub inline fn setActiveTask(task: ?*TaskContext) void {
    active_task_tls = task;
}

/// Abstracts access to the active `__stack_pointer` (`global[0]`) across:
/// 1. A host-side pointer to a guest stack-pointer slot (`host_slot`),
/// 2. A pair of getter/setter callbacks (`callbacks`), or
/// 3. Direct Wasm `global[0]` assembly / TLS simulation (`wasm_global`).
pub const StackPointerBinding = union(enum) {
    host_slot: *usize,
    callbacks: struct {
        get_fn: *const fn (?*anyopaque) usize,
        set_fn: *const fn (?*anyopaque, usize) void,
        ctx: ?*anyopaque = null,
    },
    wasm_global: void,

    pub const default: StackPointerBinding = .{ .wasm_global = {} };

    pub inline fn fromHostSlot(slot: *usize) StackPointerBinding {
        return .{ .host_slot = slot };
    }

    pub inline fn fromCallbacks(
        get_fn: *const fn (?*anyopaque) usize,
        set_fn: *const fn (?*anyopaque, usize) void,
        ctx: ?*anyopaque,
    ) StackPointerBinding {
        return .{
            .callbacks = .{
                .get_fn = get_fn,
                .set_fn = set_fn,
                .ctx = ctx,
            },
        };
    }

    pub inline fn get(self: StackPointerBinding) usize {
        return switch (self) {
            .host_slot => |slot| slot.*,
            .callbacks => |cb| cb.get_fn(cb.ctx),
            .wasm_global => getWasmStackPointer(),
        };
    }

    pub inline fn set(self: StackPointerBinding, sp: usize) void {
        switch (self) {
            .host_slot => |slot| slot.* = sp,
            .callbacks => |cb| cb.set_fn(cb.ctx, sp),
            .wasm_global => setWasmStackPointer(sp),
        }
    }
};

// ── Dual-Stack Shadow-Stack & Pool ─────────────────────────────────────────

/// Per-task 16-byte-aligned linear-memory shadow stack region with a 64-bit
/// `STACK_CANARY` at base `bytes[0..8]` to detect downward stack overflow.
pub const ShadowStack = struct {
    pub const CANARY_SIZE: usize = 8;

    bytes: []align(16) u8,
    from_scratch: bool = false,

    pub inline fn init(bytes: []align(16) u8) ShadowStack {
        std.debug.assert(bytes.len >= 16);
        const self: ShadowStack = .{
            .bytes = bytes,
            .from_scratch = false,
        };
        self.writeCanary();
        return self;
    }

    pub inline fn writeCanary(self: ShadowStack) void {
        if (self.bytes.len >= CANARY_SIZE) {
            std.mem.writeInt(u64, self.bytes[0..8], STACK_CANARY, .little);
        }
    }

    pub inline fn checkCanary(self: ShadowStack) bool {
        if (self.bytes.len < CANARY_SIZE) return false;
        return std.mem.readInt(u64, self.bytes[0..8], .little) == STACK_CANARY;
    }

    pub inline fn initialTop(self: ShadowStack) usize {
        return (@intFromPtr(self.bytes.ptr) + self.bytes.len) & ~@as(usize, 15);
    }

    pub inline fn usableBase(self: ShadowStack) usize {
        return @intFromPtr(self.bytes.ptr) + 16;
    }

    /// Computes the 16-byte-aligned top offset for a shadow stack carved out
    /// of a guest linear memory slice whose base address in host memory is
    /// `base_addr` (i.e. `guest_offset = host_addr - base_addr`).
    pub inline fn relativeInitialTop(self: ShadowStack, base_addr: usize) usize {
        const host_end = @intFromPtr(self.bytes.ptr) + self.bytes.len;
        std.debug.assert(host_end >= base_addr);
        return (host_end - base_addr) & ~@as(usize, 15);
    }

    pub inline fn checkCanaryAndBounds(self: ShadowStack, sp: usize) bool {
        if (!self.checkCanary()) return false;
        const base = @intFromPtr(self.bytes.ptr) + CANARY_SIZE;
        const top = self.initialTop();
        return sp >= base and sp <= top;
    }
};

/// Pool of up to `MAX_POOLED_STACKS` reusable 16-byte-aligned shadow stacks.
/// Supports both `std.mem.Allocator` allocation and carving stacks from a
/// pre-allocated guest linear-memory scratch slice.
pub const ShadowStackPool = struct {
    pub const MAX_POOLED_STACKS: usize = 16;

    pooled: [MAX_POOLED_STACKS]ShadowStack = undefined,
    pooled_count: usize = 0,
    stack_size: usize = DEFAULT_SHADOW_STACK_SIZE,
    scratch_region: ?[]align(16) u8 = null,
    scratch_cursor: usize = 0,

    pub fn init(stack_size: usize) ShadowStackPool {
        return .{
            .stack_size = std.mem.alignForward(usize, @max(stack_size, 32), 16),
        };
    }

    pub fn initWithScratch(scratch: []align(16) u8, stack_size: usize) ShadowStackPool {
        return .{
            .stack_size = std.mem.alignForward(usize, @max(stack_size, 32), 16),
            .scratch_region = scratch,
            .scratch_cursor = 0,
        };
    }

    pub fn acquire(self: *ShadowStackPool, allocator: std.mem.Allocator) std.mem.Allocator.Error!ShadowStack {
        if (self.pooled_count > 0) {
            self.pooled_count -= 1;
            const stack = self.pooled[self.pooled_count];
            stack.writeCanary();
            return stack;
        }

        const aligned_size = std.mem.alignForward(usize, @max(self.stack_size, 32), 16);
        if (self.scratch_region) |scratch| {
            const aligned_cursor = std.mem.alignForward(usize, self.scratch_cursor, 16);
            if (aligned_cursor + aligned_size <= scratch.len) {
                const slice: []align(16) u8 = @alignCast(scratch[aligned_cursor .. aligned_cursor + aligned_size]);
                self.scratch_cursor = aligned_cursor + aligned_size;
                var stack = ShadowStack.init(slice);
                stack.from_scratch = true;
                return stack;
            }
        }

        const buf = try allocator.alignedAlloc(u8, SHADOW_STACK_ALIGNMENT, aligned_size);
        return ShadowStack.init(buf);
    }

    pub fn release(
        self: *ShadowStackPool,
        allocator: std.mem.Allocator,
        stack: ShadowStack,
    ) error{StackOverflow}!void {
        if (!stack.checkCanary()) {
            if (!stack.from_scratch) {
                allocator.free(stack.bytes);
            }
            return error.StackOverflow;
        }

        if (self.pooled_count < MAX_POOLED_STACKS) {
            stack.writeCanary();
            self.pooled[self.pooled_count] = stack;
            self.pooled_count += 1;
        } else if (!stack.from_scratch) {
            allocator.free(stack.bytes);
        }
    }

    pub fn deinit(self: *ShadowStackPool, allocator: std.mem.Allocator) void {
        for (self.pooled[0..self.pooled_count]) |stack| {
            if (!stack.from_scratch) {
                allocator.free(stack.bytes);
            }
        }
        self.pooled_count = 0;
        self.scratch_cursor = 0;
    }
};

// ── TaskContext ────────────────────────────────────────────────────────────

/// Per-task coroutine execution context managing `__stack_pointer` switching
/// and WASI Preview 3 task-local context storage (`[context-get-0]` /
/// `[context-set-0]`).
pub const TaskContext = struct {
    pub const State = enum(u8) {
        initial,
        running,
        suspended,
        completed,
    };
    pub const Status = State;

    shadow_stack: ShadowStack,
    saved_task_sp: usize,
    saved_Task_sp: usize,
    caller_sp: usize = 0,
    sp_binding: StackPointerBinding,
    state: State = .initial,
    context_slots: [2]usize = .{ 0, 0 },
    prev_task: ?*TaskContext = null,

    pub fn init(stack: ShadowStack, sp_binding: StackPointerBinding) TaskContext {
        const top = stack.initialTop();
        return .{
            .shadow_stack = stack,
            .saved_task_sp = top,
            .saved_Task_sp = top,
            .caller_sp = 0,
            .sp_binding = sp_binding,
            .state = .initial,
            .context_slots = .{ 0, 0 },
            .prev_task = null,
        };
    }

    pub fn initRelative(stack: ShadowStack, sp_binding: StackPointerBinding, base_addr: usize) TaskContext {
        const top = stack.relativeInitialTop(base_addr);
        return .{
            .shadow_stack = stack,
            .saved_task_sp = top,
            .saved_Task_sp = top,
            .caller_sp = 0,
            .sp_binding = sp_binding,
            .state = .initial,
            .context_slots = .{ 0, 0 },
            .prev_task = null,
        };
    }

    pub fn enter(self: *TaskContext) void {
        std.debug.assert(self.state == .initial);
        self.prev_task = getActiveTask();
        setActiveTask(self);
        self.caller_sp = self.sp_binding.get();
        self.state = .running;
        self.sp_binding.set(self.saved_task_sp);
    }

    pub fn suspendTask(self: *TaskContext) void {
        std.debug.assert(self.state == .running);
        const cur_sp = self.sp_binding.get();
        self.saved_task_sp = cur_sp;
        self.saved_Task_sp = cur_sp;
        self.state = .suspended;
        setActiveTask(self.prev_task);
        self.sp_binding.set(self.caller_sp);
    }

    pub fn resumeTask(self: *TaskContext) void {
        std.debug.assert(self.state == .suspended);
        self.prev_task = getActiveTask();
        setActiveTask(self);
        self.caller_sp = self.sp_binding.get();
        self.state = .running;
        self.sp_binding.set(self.saved_task_sp);
    }

    pub fn complete(self: *TaskContext) error{StackOverflow}!void {
        std.debug.assert(self.state == .running or self.state == .suspended);
        if (self.state == .running) {
            const cur_sp = self.sp_binding.get();
            self.saved_task_sp = cur_sp;
            self.saved_Task_sp = cur_sp;
            setActiveTask(self.prev_task);
            self.prev_task = null;
            self.sp_binding.set(self.caller_sp);
        }
        self.state = .completed;
        if (!self.shadow_stack.checkCanary()) {
            return error.StackOverflow;
        }
    }

    pub fn contextGet(self: *const TaskContext, slot: u32) error{InvalidContextSlot}!usize {
        if (slot >= self.context_slots.len) return error.InvalidContextSlot;
        return self.context_slots[slot];
    }

    pub fn contextSet(self: *TaskContext, slot: u32, val: usize) error{InvalidContextSlot}!void {
        if (slot >= self.context_slots.len) return error.InvalidContextSlot;
        self.context_slots[slot] = val;
    }

    /// Invokes `func` with `args` across a `noinline` trampoline boundary
    /// while `self`'s shadow stack is active as `__stack_pointer`.
    pub fn run(
        self: *TaskContext,
        comptime func: anytype,
        args: anytype,
    ) @TypeOf(@call(.auto, func, args)) {
        const entered_here = (self.state != .running);
        switch (self.state) {
            .initial => self.enter(),
            .suspended => self.resumeTask(),
            .running => {},
            .completed => unreachable,
        }
        defer {
            if (entered_here and self.state == .running) {
                self.complete() catch @panic("wasm shadow stack overflow");
            }
        }
        return runOnShadowStackTrampoline(func, args);
    }

    /// Invokes `func` with `args` on `self`'s shadow stack for a single step
    /// of a multi-step coroutine (entering if `.initial` or resuming if
    /// `.suspended`, and suspending back to the caller upon return if still
    /// `.running`).
    pub fn runStep(
        self: *TaskContext,
        comptime func: anytype,
        args: anytype,
    ) @TypeOf(@call(.auto, func, args)) {
        const entered_here = (self.state != .running);
        switch (self.state) {
            .initial => self.enter(),
            .suspended => self.resumeTask(),
            .running => {},
            .completed => unreachable,
        }
        defer {
            if (entered_here and self.state == .running) {
                self.suspendTask();
            }
        }
        return runOnShadowStackTrampoline(func, args);
    }

    noinline fn runOnShadowStackTrampoline(
        comptime func: anytype,
        args: anytype,
    ) @TypeOf(@call(.auto, func, args)) {
        return @call(.auto, func, args);
    }
};

// ── WASI 0.3 Concurrency Primitives ────────────────────────────────────────

pub const SubtaskState = enum(u4) {
    starting = 0,
    started = 1,
    returned = 2,
    cancelled_before_started = 3,
    cancelled_before_returned = 4,

    pub inline fn isTerminal(self: SubtaskState) bool {
        return switch (self) {
            .returned, .cancelled_before_started, .cancelled_before_returned => true,
            .starting, .started => false,
        };
    }

    pub inline fn pack(self: SubtaskState, handle: u28) i32 {
        const raw: u32 = (@as(u32, handle) << 4) | @as(u32, @intFromEnum(self));
        return @bitCast(raw);
    }

    pub inline fn unpack(raw: i32) struct { state: SubtaskState, handle: u28 } {
        const u: u32 = @bitCast(raw);
        const low: u4 = @truncate(u & 0xf);
        const st: SubtaskState = switch (low) {
            0 => .starting,
            1 => .started,
            2 => .returned,
            3 => .cancelled_before_started,
            4 => .cancelled_before_returned,
            else => .returned,
        };
        return .{
            .state = st,
            .handle = @truncate(u >> 4),
        };
    }
};

pub const EventCode = enum(u32) {
    none = 0,
    subtask = 1,
    stream_read = 2,
    stream_write = 3,
    future_read = 4,
    future_write = 5,
    task_cancel = 6,

    pub inline fn fromInt(raw: u32) EventCode {
        return switch (raw) {
            0 => .none,
            1 => .subtask,
            2 => .stream_read,
            3 => .stream_write,
            4 => .future_read,
            5 => .future_write,
            6 => .task_cancel,
            else => .none,
        };
    }
};

pub const WaitEvent = struct {
    code: EventCode = .none,
    index: u32 = 0,
    payload: u32 = 0,
};

pub const CallbackCode = enum(u32) {
    exit = 0,
    yield = 1,
    wait = 2,

    pub inline fn pack(code: CallbackCode, waitable_set: u32) i32 {
        const raw: u32 = (waitable_set << 4) | (@intFromEnum(code) & 0xf);
        return @bitCast(raw);
    }

    pub inline fn unpack(raw: i32) struct { code: CallbackCode, waitable_set: u32 } {
        const u: u32 = @bitCast(raw);
        const low: u32 = u & 0xf;
        const code: CallbackCode = switch (low) {
            0 => .exit,
            1 => .yield,
            2 => .wait,
            else => .exit,
        };
        return .{
            .code = code,
            .waitable_set = u >> 4,
        };
    }
};

pub const StreamStatus = enum(u2) {
    completed = 0,
    closed = 1,
    cancelled = 2,

    pub inline fn pack(status: StreamStatus, count: u30) u32 {
        return (@as(u32, count) << 2) | @as(u32, @intFromEnum(status));
    }

    pub inline fn unpack(raw: u32) struct { status: StreamStatus, count: u30 } {
        const low: u2 = @truncate(raw & 0x3);
        const status: StreamStatus = switch (low) {
            0 => .completed,
            1 => .closed,
            2 => .cancelled,
            else => .closed,
        };
        return .{
            .status = status,
            .count = @truncate(raw >> 2),
        };
    }
};

pub const StreamResult = StreamStatus;

pub const StreamPair = struct {
    readable: i32,
    writable: i32,

    pub inline fn packU64(self: StreamPair) u64 {
        const r: u32 = @bitCast(self.readable);
        const w: u32 = @bitCast(self.writable);
        return @as(u64, r) | (@as(u64, w) << 32);
    }

    pub inline fn unpackU64(raw: u64) StreamPair {
        return .{
            .readable = @bitCast(@as(u32, @truncate(raw))),
            .writable = @bitCast(@as(u32, @truncate(raw >> 32))),
        };
    }
};

pub const FuturePair = struct {
    readable: i32,
    writable: i32,

    pub inline fn packU64(self: FuturePair) u64 {
        const r: u32 = @bitCast(self.readable);
        const w: u32 = @bitCast(self.writable);
        return @as(u64, r) | (@as(u64, w) << 32);
    }

    pub inline fn unpackU64(raw: u64) FuturePair {
        return .{
            .readable = @bitCast(@as(u32, @truncate(raw))),
            .writable = @bitCast(@as(u32, @truncate(raw >> 32))),
        };
    }
};

// ── Channels & Entries ─────────────────────────────────────────────────────

pub const PendingBufferOp = struct {
    mem_ctx: ?*canon.MemoryContext = null,
    ptr: usize,
    len: usize,

    fn resolveMutSlice(self: PendingBufferOp) Error![]u8 {
        if (self.len == 0) return &[_]u8{};
        if (self.mem_ctx) |ctx| {
            const off = try ctx.addrToOffset(self.ptr, self.len);
            return ctx.memory[off..][0..self.len];
        }
        if (self.ptr == 0) return error.OutOfBounds;
        const p: [*]u8 = @ptrFromInt(self.ptr);
        return p[0..self.len];
    }

    fn resolveConstSlice(self: PendingBufferOp) Error![]const u8 {
        if (self.len == 0) return &[_]u8{};
        if (self.mem_ctx) |ctx| {
            const off = try ctx.addrToOffset(self.ptr, self.len);
            return ctx.memory[off..][0..self.len];
        }
        if (self.ptr == 0) return error.OutOfBounds;
        const p: [*]const u8 = @ptrFromInt(self.ptr);
        return p[0..self.len];
    }
};

pub const StreamChannel = struct {
    readable_handle: i32,
    writable_handle: i32,
    readable_waitable_set: i32 = 0,
    writable_waitable_set: i32 = 0,
    readable_dropped: bool = false,
    writable_dropped: bool = false,
    buffer: []u8,
    read_pos: usize = 0,
    write_pos: usize = 0,
    buffered_len: usize = 0,
    pending_read: ?PendingBufferOp = null,
    pending_write: ?PendingBufferOp = null,

    pub fn init(
        allocator: std.mem.Allocator,
        readable_handle: i32,
        writable_handle: i32,
        capacity: usize,
    ) std.mem.Allocator.Error!StreamChannel {
        const cap = @max(capacity, 1);
        const buf = try allocator.alloc(u8, cap);
        return .{
            .readable_handle = readable_handle,
            .writable_handle = writable_handle,
            .buffer = buf,
        };
    }

    pub fn deinit(self: *StreamChannel, allocator: std.mem.Allocator) void {
        if (self.buffer.len > 0) {
            allocator.free(self.buffer);
            self.buffer = &[_]u8{};
        }
    }

    fn writeRing(self: *StreamChannel, src: []const u8) usize {
        const avail = self.buffer.len - self.buffered_len;
        const count = @min(avail, src.len);
        for (0..count) |i| {
            self.buffer[self.write_pos] = src[i];
            self.write_pos = (self.write_pos + 1) % self.buffer.len;
        }
        self.buffered_len += count;
        return count;
    }

    fn readRing(self: *StreamChannel, dst: []u8) usize {
        const count = @min(self.buffered_len, dst.len);
        for (0..count) |i| {
            dst[i] = self.buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.buffer.len;
        }
        self.buffered_len -= count;
        return count;
    }
};

pub const FutureChannel = struct {
    readable_handle: i32,
    writable_handle: i32,
    readable_waitable_set: i32 = 0,
    writable_waitable_set: i32 = 0,
    readable_dropped: bool = false,
    writable_dropped: bool = false,
    has_value: bool = false,
    read_completed: bool = false,
    value_buf: []u8,
    pending_read: ?PendingBufferOp = null,
    pending_write: ?PendingBufferOp = null,

    pub fn init(
        allocator: std.mem.Allocator,
        readable_handle: i32,
        writable_handle: i32,
        value_size: usize,
    ) std.mem.Allocator.Error!FutureChannel {
        const buf = if (value_size > 0) try allocator.alloc(u8, value_size) else @constCast(&[_]u8{});
        return .{
            .readable_handle = readable_handle,
            .writable_handle = writable_handle,
            .value_buf = buf,
        };
    }

    pub fn deinit(self: *FutureChannel, allocator: std.mem.Allocator) void {
        if (self.value_buf.len > 0) {
            allocator.free(self.value_buf);
            self.value_buf = &[_]u8{};
        }
    }
};

pub const WaitableSetEntry = struct {
    handle: i32,
    active: bool = true,
    events: std.ArrayListUnmanaged(WaitEvent) = .empty,
    joined_handles: std.ArrayListUnmanaged(i32) = .empty,

    pub fn deinit(self: *WaitableSetEntry, allocator: std.mem.Allocator) void {
        if (!self.active) return;
        self.events.deinit(allocator);
        self.events = .empty;
        self.joined_handles.deinit(allocator);
        self.joined_handles = .empty;
        self.active = false;
    }
};

pub const SubtaskStepFn = *const fn (
    ctx: ?*anyopaque,
    scheduler: *AsyncScheduler,
    subtask_handle: i32,
) anyerror!SubtaskState;

pub const SubtaskCleanupFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) void;

pub const SubtaskEntry = struct {
    handle: i32,
    active: bool = true,
    state: SubtaskState = .starting,
    waitable_set_handle: i32 = 0,
    returned_event_queued: bool = false,
    unchanged_steps: u32 = 0,
    step_ctx: ?*anyopaque = null,
    step_fn: ?SubtaskStepFn = null,
    cleanup_fn: ?SubtaskCleanupFn = null,

    pub fn deinit(self: *SubtaskEntry, allocator: std.mem.Allocator) void {
        if (self.cleanup_fn) |cleanup| {
            cleanup(self.step_ctx, allocator);
            self.cleanup_fn = null;
        }
        self.active = false;
    }
};

// ── AsyncScheduler ─────────────────────────────────────────────────────────

const HandleKind = enum {
    none,
    waitable_set,
    subtask,
    stream_readable,
    stream_writable,
    future_readable,
    future_writable,
};

const HandleRef = struct {
    kind: HandleKind = .none,
    index: usize = 0,
};

pub const AsyncScheduler = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
    stack_pool: ShadowStackPool = .{},
    sp_binding: StackPointerBinding = .default,
    active_task: ?*TaskContext = null,
    default_context_slots: [2]usize = .{ 0, 0 },
    task_returned: bool = false,
    total_events_pushed: u64 = 0,

    handle_table: std.ArrayListUnmanaged(HandleRef) = .empty,
    waitable_sets: std.ArrayListUnmanaged(WaitableSetEntry) = .empty,
    subtasks: std.ArrayListUnmanaged(SubtaskEntry) = .empty,
    streams: std.ArrayListUnmanaged(StreamChannel) = .empty,
    futures: std.ArrayListUnmanaged(FutureChannel) = .empty,

    pub fn init(allocator: std.mem.Allocator) AsyncScheduler {
        return .{
            .allocator = allocator,
        };
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) AsyncScheduler {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *AsyncScheduler) void {
        for (self.waitable_sets.items) |*ws| {
            ws.deinit(self.allocator);
        }
        self.waitable_sets.deinit(self.allocator);

        for (self.subtasks.items) |*st| {
            st.deinit(self.allocator);
        }
        self.subtasks.deinit(self.allocator);

        for (self.streams.items) |*sc| {
            sc.deinit(self.allocator);
        }
        self.streams.deinit(self.allocator);

        for (self.futures.items) |*fc| {
            fc.deinit(self.allocator);
        }
        self.futures.deinit(self.allocator);

        self.handle_table.deinit(self.allocator);
        self.stack_pool.deinit(self.allocator);
    }

    fn allocHandle(self: *AsyncScheduler, kind: HandleKind, index: usize) std.mem.Allocator.Error!i32 {
        if (self.handle_table.items.len == 0) {
            // Reserve slot 0 as invalid / disjoin handle.
            try self.handle_table.append(self.allocator, .{ .kind = .none, .index = 0 });
        }
        const handle_idx = self.handle_table.items.len;
        try self.handle_table.append(self.allocator, .{ .kind = kind, .index = index });
        return @intCast(handle_idx);
    }

    fn lookupHandle(self: *const AsyncScheduler, handle: i32) Error!HandleRef {
        if (handle <= 0) return error.InvalidHandle;
        const idx: usize = @intCast(handle);
        if (idx >= self.handle_table.items.len) return error.InvalidHandle;
        const ref = self.handle_table.items[idx];
        if (ref.kind == .none) return error.InvalidHandle;
        return ref;
    }

    fn getWaitableSetMut(self: *AsyncScheduler, set_handle: i32) Error!*WaitableSetEntry {
        const ref = self.lookupHandle(set_handle) catch return error.InvalidWaitableSet;
        if (ref.kind != .waitable_set) return error.InvalidWaitableSet;
        const ws = &self.waitable_sets.items[ref.index];
        if (!ws.active) return error.InvalidWaitableSet;
        return ws;
    }

    pub fn pushEvent(self: *AsyncScheduler, set_handle: i32, ev: WaitEvent) Error!void {
        if (set_handle == 0) return;
        const ws = try self.getWaitableSetMut(set_handle);
        try ws.events.append(self.allocator, ev);
        self.total_events_pushed += 1;
    }

    // ── Waitable Sets ──────────────────────────────────────────────────────

    pub fn waitableSetNew(self: *AsyncScheduler) std.mem.Allocator.Error!i32 {
        const idx = self.waitable_sets.items.len;
        const handle = try self.allocHandle(.waitable_set, idx);
        errdefer self.handle_table.items[@intCast(handle)].kind = .none;
        try self.waitable_sets.append(self.allocator, .{
            .handle = handle,
            .active = true,
        });
        return handle;
    }

    pub fn waitableSetDrop(self: *AsyncScheduler, set_handle: i32) Error!void {
        const ws = try self.getWaitableSetMut(set_handle);
        for (ws.joined_handles.items) |wh| {
            const ref = self.lookupHandle(wh) catch continue;
            switch (ref.kind) {
                .subtask => self.subtasks.items[ref.index].waitable_set_handle = 0,
                .stream_readable => self.streams.items[ref.index].readable_waitable_set = 0,
                .stream_writable => self.streams.items[ref.index].writable_waitable_set = 0,
                .future_readable => self.futures.items[ref.index].readable_waitable_set = 0,
                .future_writable => self.futures.items[ref.index].writable_waitable_set = 0,
                else => {},
            }
        }
        ws.deinit(self.allocator);
        self.handle_table.items[@intCast(set_handle)].kind = .none;
    }

    fn detachFromWaitableSet(self: *AsyncScheduler, old_set_handle: i32, waitable_handle: i32) void {
        if (old_set_handle <= 0) return;
        const ws = self.getWaitableSetMut(old_set_handle) catch return;
        for (ws.joined_handles.items, 0..) |h, i| {
            if (h == waitable_handle) {
                _ = ws.joined_handles.orderedRemove(i);
                break;
            }
        }
    }

    pub fn waitableJoin(self: *AsyncScheduler, waitable_handle: i32, set_handle: i32) Error!void {
        const ref = try self.lookupHandle(waitable_handle);
        if (set_handle != 0) {
            _ = try self.getWaitableSetMut(set_handle);
        }

        switch (ref.kind) {
            .subtask => {
                var st = &self.subtasks.items[ref.index];
                if (!st.active) return error.InvalidHandle;
                self.detachFromWaitableSet(st.waitable_set_handle, waitable_handle);
                st.waitable_set_handle = set_handle;
                if (set_handle != 0) {
                    const ws = try self.getWaitableSetMut(set_handle);
                    try ws.joined_handles.append(self.allocator, waitable_handle);
                    if (st.state.isTerminal() and !st.returned_event_queued) {
                        st.returned_event_queued = true;
                        try ws.events.append(self.allocator, .{
                            .code = .subtask,
                            .index = @bitCast(waitable_handle),
                            .payload = @intFromEnum(st.state),
                        });
                        self.total_events_pushed += 1;
                    }
                }
            },
            .stream_readable => {
                var sc = &self.streams.items[ref.index];
                if (sc.readable_dropped) return error.InvalidHandle;
                self.detachFromWaitableSet(sc.readable_waitable_set, waitable_handle);
                sc.readable_waitable_set = set_handle;
                if (set_handle != 0) {
                    const ws = try self.getWaitableSetMut(set_handle);
                    try ws.joined_handles.append(self.allocator, waitable_handle);
                }
            },
            .stream_writable => {
                var sc = &self.streams.items[ref.index];
                if (sc.writable_dropped) return error.InvalidHandle;
                self.detachFromWaitableSet(sc.writable_waitable_set, waitable_handle);
                sc.writable_waitable_set = set_handle;
                if (set_handle != 0) {
                    const ws = try self.getWaitableSetMut(set_handle);
                    try ws.joined_handles.append(self.allocator, waitable_handle);
                }
            },
            .future_readable => {
                var fc = &self.futures.items[ref.index];
                if (fc.readable_dropped) return error.InvalidHandle;
                self.detachFromWaitableSet(fc.readable_waitable_set, waitable_handle);
                fc.readable_waitable_set = set_handle;
                if (set_handle != 0) {
                    const ws = try self.getWaitableSetMut(set_handle);
                    try ws.joined_handles.append(self.allocator, waitable_handle);
                }
            },
            .future_writable => {
                var fc = &self.futures.items[ref.index];
                if (fc.writable_dropped) return error.InvalidHandle;
                self.detachFromWaitableSet(fc.writable_waitable_set, waitable_handle);
                fc.writable_waitable_set = set_handle;
                if (set_handle != 0) {
                    const ws = try self.getWaitableSetMut(set_handle);
                    try ws.joined_handles.append(self.allocator, waitable_handle);
                }
            },
            else => return error.InvalidHandle,
        }
    }

    fn writePayloadToMemory(
        mem_ctx: ?*canon.MemoryContext,
        payload_ptr: usize,
        ev: WaitEvent,
    ) Error!void {
        if (mem_ctx) |ctx| {
            const off = try ctx.addrToOffset(payload_ptr, 8);
            std.mem.writeInt(u32, ctx.memory[off..][0..4], ev.index, .little);
            std.mem.writeInt(u32, ctx.memory[off + 4 ..][0..4], ev.payload, .little);
        }
    }

    /// Drives one round of pending subtasks and returns `true` if any subtask
    /// made progress.
    pub fn stepOnce(self: *AsyncScheduler) Error!bool {
        const MAX_UNCHANGED_SUBTASK_STEPS: u32 = 8;
        var progressed = false;
        const count = self.subtasks.items.len;
        for (0..count) |i| {
            const st = &self.subtasks.items[i];
            if (!st.active) continue;
            if (st.state == .starting or st.state == .started) {
                if (st.step_fn) |step| {
                    const prev_state = st.state;
                    const events_before = self.total_events_pushed;
                    const handle = st.handle;
                    const new_state = step(st.step_ctx, self, handle) catch return error.AsyncCallPending;
                    try self.resolveSubtask(handle, new_state);
                    if (new_state != prev_state or self.total_events_pushed != events_before) {
                        self.subtasks.items[i].unchanged_steps = 0;
                        progressed = true;
                    } else {
                        self.subtasks.items[i].unchanged_steps +|= 1;
                        if (self.subtasks.items[i].unchanged_steps <= MAX_UNCHANGED_SUBTASK_STEPS) {
                            progressed = true;
                        }
                    }
                }
            }
        }
        return progressed;
    }

    /// Non-blocking poll on `set_handle`: pops the next ready `WaitEvent` (or
    /// drives one round of pending subtasks first), writes `[index, payload]`
    /// as two little-endian `u32`s at `payload_ptr` in `mem_ctx` if
    /// `mem_ctx != null`, and returns `@intFromEnum(ev.code)` (or `0` if none).
    pub fn waitableSetPoll(
        self: *AsyncScheduler,
        set_handle: i32,
        mem_ctx: ?*canon.MemoryContext,
        payload_ptr: usize,
    ) Error!i32 {
        var ws = try self.getWaitableSetMut(set_handle);
        if (ws.events.items.len == 0) {
            _ = try self.stepOnce();
            ws = try self.getWaitableSetMut(set_handle);
        }
        if (ws.events.items.len == 0) {
            return @intFromEnum(EventCode.none);
        }
        const ev = ws.events.orderedRemove(0);
        try writePayloadToMemory(mem_ctx, payload_ptr, ev);
        return @intCast(@intFromEnum(ev.code));
    }

    /// Stackful blocking wait on `set_handle`: suspends the active
    /// `TaskContext` (if any), drives pending subtasks and `std.Io` work until
    /// a `WaitEvent` is ready on `set_handle`, resumes the `TaskContext`,
    /// writes `[index, payload]` to `payload_ptr` in `mem_ctx` if
    /// `mem_ctx != null`, and returns the `WaitEvent`.
    pub fn waitableSetWait(
        self: *AsyncScheduler,
        set_handle: i32,
        mem_ctx: ?*canon.MemoryContext,
        payload_ptr: usize,
    ) Error!WaitEvent {
        _ = try self.getWaitableSetMut(set_handle);

        const task_to_suspend: ?*TaskContext = blk: {
            if (self.active_task) |t| {
                if (t.state == .running) break :blk t;
            }
            if (getActiveTask()) |t| {
                if (t.state == .running) break :blk t;
            }
            break :blk null;
        };

        if (task_to_suspend) |t| {
            t.suspendTask();
        }
        defer {
            if (task_to_suspend) |t| {
                if (t.state == .suspended) {
                    t.resumeTask();
                }
            }
        }

        const MAX_WAIT_STEPS: usize = 100_000;
        var steps: usize = 0;
        while (true) {
            var ws = try self.getWaitableSetMut(set_handle);
            if (ws.events.items.len > 0) {
                const ev = ws.events.orderedRemove(0);
                try writePayloadToMemory(mem_ctx, payload_ptr, ev);
                return ev;
            }
            if (steps >= MAX_WAIT_STEPS) {
                return error.DeadlockDetected;
            }
            steps += 1;
            const progressed = try self.stepOnce();
            ws = try self.getWaitableSetMut(set_handle);
            if (ws.events.items.len > 0) {
                const ev = ws.events.orderedRemove(0);
                try writePayloadToMemory(mem_ctx, payload_ptr, ev);
                return ev;
            }
            if (!progressed) {
                return error.DeadlockDetected;
            }
        }
    }

    // ── Subtasks & `std.Io` Integration ────────────────────────────────────

    pub fn createSubtask(
        self: *AsyncScheduler,
        initial_state: SubtaskState,
        step_ctx: ?*anyopaque,
        step_fn: ?SubtaskStepFn,
    ) std.mem.Allocator.Error!i32 {
        const idx = self.subtasks.items.len;
        const handle = try self.allocHandle(.subtask, idx);
        errdefer self.handle_table.items[@intCast(handle)].kind = .none;
        try self.subtasks.append(self.allocator, .{
            .handle = handle,
            .active = true,
            .state = initial_state,
            .step_ctx = step_ctx,
            .step_fn = step_fn,
        });
        return handle;
    }

    pub fn spawnAsyncSubtask(
        self: *AsyncScheduler,
        step_ctx: ?*anyopaque,
        step_fn: SubtaskStepFn,
    ) std.mem.Allocator.Error!i32 {
        return self.createSubtask(.started, step_ctx, step_fn);
    }

    /// Spawns a host function via Zig 0.17 `std.Io.async` and tracks it as a
    /// WASI 0.3 subtask handle that transitions from `.started` to `.returned`
    /// when awaited by the scheduler.
    pub fn spawnHostSubtask(
        self: *AsyncScheduler,
        io: std.Io,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
        on_complete_ctx: ?*anyopaque,
        comptime on_complete: anytype,
    ) std.mem.Allocator.Error!i32 {
        const RetT = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const HostJob = struct {
            io: std.Io,
            future: std.Io.Future(RetT),
            on_complete_ctx: ?*anyopaque,
            awaited: bool = false,

            fn step(raw_ctx: ?*anyopaque, sched: *AsyncScheduler, subtask_handle: i32) anyerror!SubtaskState {
                const job: *@This() = @ptrCast(@alignCast(raw_ctx.?));
                if (!job.awaited) {
                    job.awaited = true;
                    const res = job.future.await(job.io);
                    if (@TypeOf(on_complete) != @TypeOf(null)) {
                        const cb_info = @typeInfo(@TypeOf(on_complete));
                        const fn_info = switch (cb_info) {
                            .@"fn" => |f| f,
                            .pointer => |p| @typeInfo(p.child).@"fn",
                            else => @compileError("on_complete must be a function or null"),
                        };
                        if (fn_info.param_types.len == 2) {
                            try @call(.auto, on_complete, .{ job.on_complete_ctx, res });
                        } else if (fn_info.param_types.len == 3) {
                            try @call(.auto, on_complete, .{ job.on_complete_ctx, sched, res });
                        } else if (fn_info.param_types.len == 4) {
                            try @call(.auto, on_complete, .{ job.on_complete_ctx, sched, subtask_handle, res });
                        } else {
                            @compileError("on_complete must take 2, 3, or 4 parameters");
                        }
                    }
                }
                return .returned;
            }

            fn cleanup(raw_ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
                const job: *@This() = @ptrCast(@alignCast(raw_ctx orelse return));
                if (!job.awaited) {
                    job.awaited = true;
                    _ = job.future.cancel(job.io);
                }
                alloc.destroy(job);
            }
        };

        const job = try self.allocator.create(HostJob);
        job.awaited = true;
        errdefer {
            if (!job.awaited) {
                job.awaited = true;
                _ = job.future.cancel(job.io);
            }
            self.allocator.destroy(job);
        }
        job.* = .{
            .io = io,
            .future = io.async(func, args),
            .on_complete_ctx = on_complete_ctx,
            .awaited = false,
        };

        const idx = self.subtasks.items.len;
        const handle = try self.allocHandle(.subtask, idx);
        errdefer self.handle_table.items[@intCast(handle)].kind = .none;
        try self.subtasks.append(self.allocator, .{
            .handle = handle,
            .active = true,
            .state = .started,
            .step_ctx = job,
            .step_fn = &HostJob.step,
            .cleanup_fn = &HostJob.cleanup,
        });
        return handle;
    }

    pub fn resolveSubtask(
        self: *AsyncScheduler,
        subtask_handle: i32,
        new_state: SubtaskState,
    ) Error!void {
        const ref = try self.lookupHandle(subtask_handle);
        if (ref.kind != .subtask) return error.InvalidHandle;
        var st = &self.subtasks.items[ref.index];
        if (!st.active) return error.InvalidHandle;
        st.state = new_state;
        if (new_state.isTerminal() and
            !st.returned_event_queued and
            st.waitable_set_handle != 0)
        {
            st.returned_event_queued = true;
            try self.pushEvent(st.waitable_set_handle, .{
                .code = .subtask,
                .index = @bitCast(subtask_handle),
                .payload = @intFromEnum(new_state),
            });
        }
    }

    pub fn subtaskState(self: *const AsyncScheduler, subtask_handle: i32) Error!SubtaskState {
        const ref = try self.lookupHandle(subtask_handle);
        if (ref.kind != .subtask) return error.InvalidHandle;
        const st = &self.subtasks.items[ref.index];
        if (!st.active) return error.InvalidHandle;
        return st.state;
    }

    pub fn subtaskDrop(self: *AsyncScheduler, subtask_handle: i32) Error!void {
        const ref = try self.lookupHandle(subtask_handle);
        if (ref.kind != .subtask) return error.InvalidHandle;
        var st = &self.subtasks.items[ref.index];
        if (!st.active) return error.InvalidHandle;
        self.detachFromWaitableSet(st.waitable_set_handle, subtask_handle);
        st.deinit(self.allocator);
        self.handle_table.items[@intCast(subtask_handle)].kind = .none;
    }

    // ── Streams ────────────────────────────────────────────────────────────

    pub fn streamNew(self: *AsyncScheduler) std.mem.Allocator.Error!StreamPair {
        return self.streamNewWithCapacity(4096);
    }

    pub fn streamNewWithCapacity(
        self: *AsyncScheduler,
        capacity: usize,
    ) std.mem.Allocator.Error!StreamPair {
        const idx = self.streams.items.len;
        const r_handle = try self.allocHandle(.stream_readable, idx);
        errdefer self.handle_table.items[@intCast(r_handle)].kind = .none;
        const w_handle = try self.allocHandle(.stream_writable, idx);
        errdefer self.handle_table.items[@intCast(w_handle)].kind = .none;
        var ch = try StreamChannel.init(self.allocator, r_handle, w_handle, capacity);
        errdefer ch.deinit(self.allocator);
        try self.streams.append(self.allocator, ch);
        return .{ .readable = r_handle, .writable = w_handle };
    }

    pub fn streamRead(
        self: *AsyncScheduler,
        readable_handle: i32,
        mem_ctx: ?*canon.MemoryContext,
        ptr: usize,
        len: usize,
    ) Error!u32 {
        const ref = try self.lookupHandle(readable_handle);
        if (ref.kind != .stream_readable) return error.InvalidHandle;
        var sc = &self.streams.items[ref.index];
        if (sc.readable_dropped) return error.InvalidHandle;

        const op = PendingBufferOp{ .mem_ctx = mem_ctx, .ptr = ptr, .len = len };
        const dst = try op.resolveMutSlice();

        if (len == 0) {
            return StreamStatus.pack(if (sc.writable_dropped) .closed else .completed, 0);
        }

        var total_read: usize = 0;
        if (sc.buffered_len > 0) {
            total_read += sc.readRing(dst);
        }

        if (sc.pending_write) |pw| {
            const src = try pw.resolveConstSlice();
            var consumed_from_writer: usize = 0;
            if (total_read < dst.len) {
                const direct = @min(dst.len - total_read, src.len);
                @memcpy(dst[total_read..][0..direct], src[0..direct]);
                total_read += direct;
                consumed_from_writer += direct;
            }
            if (consumed_from_writer < src.len and sc.buffered_len < sc.buffer.len) {
                consumed_from_writer += sc.writeRing(src[consumed_from_writer..]);
            }
            if (consumed_from_writer > 0) {
                sc.pending_write = null;
                const w_ws = sc.writable_waitable_set;
                const w_handle = sc.writable_handle;
                const clamped_written: u30 = @intCast(@min(consumed_from_writer, std.math.maxInt(u30)));
                try self.pushEvent(w_ws, .{
                    .code = .stream_write,
                    .index = @bitCast(w_handle),
                    .payload = StreamStatus.pack(.completed, clamped_written),
                });
            }
        }

        if (total_read > 0) {
            const status: StreamStatus = if (sc.writable_dropped and sc.buffered_len == 0) .closed else .completed;
            const clamped_read: u30 = @intCast(@min(total_read, std.math.maxInt(u30)));
            return StreamStatus.pack(status, clamped_read);
        }

        if (sc.writable_dropped) {
            return StreamStatus.pack(.closed, 0);
        }

        sc.pending_read = op;
        return BLOCKED;
    }

    pub fn streamReadSlice(self: *AsyncScheduler, readable_handle: i32, dst: []u8) Error!u32 {
        return self.streamRead(readable_handle, null, @intFromPtr(dst.ptr), dst.len);
    }

    pub fn streamWrite(
        self: *AsyncScheduler,
        writable_handle: i32,
        mem_ctx: ?*canon.MemoryContext,
        ptr: usize,
        len: usize,
    ) Error!u32 {
        const ref = try self.lookupHandle(writable_handle);
        if (ref.kind != .stream_writable) return error.InvalidHandle;
        var sc = &self.streams.items[ref.index];
        if (sc.writable_dropped) return error.InvalidHandle;

        if (sc.readable_dropped) {
            return StreamStatus.pack(.closed, 0);
        }

        const op = PendingBufferOp{ .mem_ctx = mem_ctx, .ptr = ptr, .len = len };
        const src = try op.resolveConstSlice();

        if (len == 0) {
            return StreamStatus.pack(.completed, 0);
        }

        var total_written: usize = 0;

        if (sc.pending_read) |pr| {
            const reader_dst = try pr.resolveMutSlice();
            const direct = @min(reader_dst.len, src.len);
            @memcpy(reader_dst[0..direct], src[0..direct]);
            total_written += direct;
            sc.pending_read = null;
            const r_ws = sc.readable_waitable_set;
            const r_handle = sc.readable_handle;
            const clamped_direct: u30 = @intCast(@min(direct, std.math.maxInt(u30)));
            try self.pushEvent(r_ws, .{
                .code = .stream_read,
                .index = @bitCast(r_handle),
                .payload = StreamStatus.pack(.completed, clamped_direct),
            });
        }

        if (total_written < src.len and sc.buffered_len < sc.buffer.len) {
            total_written += sc.writeRing(src[total_written..]);
        }

        if (total_written > 0) {
            const clamped_written: u30 = @intCast(@min(total_written, std.math.maxInt(u30)));
            return StreamStatus.pack(.completed, clamped_written);
        }

        sc.pending_write = op;
        return BLOCKED;
    }

    pub fn streamWriteSlice(self: *AsyncScheduler, writable_handle: i32, src: []const u8) Error!u32 {
        return self.streamWrite(writable_handle, null, @intFromPtr(src.ptr), src.len);
    }

    pub fn streamDropReadable(self: *AsyncScheduler, readable_handle: i32) Error!void {
        const ref = try self.lookupHandle(readable_handle);
        if (ref.kind != .stream_readable) return error.InvalidHandle;
        var sc = &self.streams.items[ref.index];
        if (sc.readable_dropped) return error.InvalidHandle;
        sc.readable_dropped = true;
        self.detachFromWaitableSet(sc.readable_waitable_set, readable_handle);
        self.handle_table.items[@intCast(readable_handle)].kind = .none;

        if (sc.pending_write != null) {
            sc.pending_write = null;
            const w_ws = sc.writable_waitable_set;
            const w_handle = sc.writable_handle;
            try self.pushEvent(w_ws, .{
                .code = .stream_write,
                .index = @bitCast(w_handle),
                .payload = StreamStatus.pack(.closed, 0),
            });
        }
        if (sc.readable_dropped and sc.writable_dropped) {
            sc.deinit(self.allocator);
        }
    }

    pub fn streamDropWritable(self: *AsyncScheduler, writable_handle: i32) Error!void {
        const ref = try self.lookupHandle(writable_handle);
        if (ref.kind != .stream_writable) return error.InvalidHandle;
        var sc = &self.streams.items[ref.index];
        if (sc.writable_dropped) return error.InvalidHandle;
        sc.writable_dropped = true;
        self.detachFromWaitableSet(sc.writable_waitable_set, writable_handle);
        self.handle_table.items[@intCast(writable_handle)].kind = .none;

        if (sc.pending_read != null) {
            sc.pending_read = null;
            const r_ws = sc.readable_waitable_set;
            const r_handle = sc.readable_handle;
            try self.pushEvent(r_ws, .{
                .code = .stream_read,
                .index = @bitCast(r_handle),
                .payload = StreamStatus.pack(.closed, 0),
            });
        }
        if (sc.readable_dropped and sc.writable_dropped) {
            sc.deinit(self.allocator);
        }
    }

    // ── Futures ────────────────────────────────────────────────────────────

    pub fn futureNew(self: *AsyncScheduler, value_size: usize) std.mem.Allocator.Error!FuturePair {
        const idx = self.futures.items.len;
        const r_handle = try self.allocHandle(.future_readable, idx);
        errdefer self.handle_table.items[@intCast(r_handle)].kind = .none;
        const w_handle = try self.allocHandle(.future_writable, idx);
        errdefer self.handle_table.items[@intCast(w_handle)].kind = .none;
        var fc = try FutureChannel.init(self.allocator, r_handle, w_handle, value_size);
        errdefer fc.deinit(self.allocator);
        try self.futures.append(self.allocator, fc);
        return .{ .readable = r_handle, .writable = w_handle };
    }

    pub fn futureRead(
        self: *AsyncScheduler,
        readable_handle: i32,
        mem_ctx: ?*canon.MemoryContext,
        ptr: usize,
        len: usize,
    ) Error!u32 {
        const ref = try self.lookupHandle(readable_handle);
        if (ref.kind != .future_readable) return error.InvalidHandle;
        var fc = &self.futures.items[ref.index];
        if (fc.readable_dropped) return error.InvalidHandle;

        const op = PendingBufferOp{ .mem_ctx = mem_ctx, .ptr = ptr, .len = len };
        const dst = try op.resolveMutSlice();

        if (fc.has_value) {
            const copy_len = @min(dst.len, fc.value_buf.len);
            if (copy_len > 0) {
                @memcpy(dst[0..copy_len], fc.value_buf[0..copy_len]);
            }
            fc.read_completed = true;
            if (fc.pending_write != null) {
                fc.pending_write = null;
                const w_ws = fc.writable_waitable_set;
                const w_handle = fc.writable_handle;
                try self.pushEvent(w_ws, .{
                    .code = .future_write,
                    .index = @bitCast(w_handle),
                    .payload = StreamStatus.pack(.completed, 1),
                });
            }
            return StreamStatus.pack(.completed, 1);
        }

        if (fc.writable_dropped) {
            return StreamStatus.pack(.closed, 0);
        }

        fc.pending_read = op;
        return BLOCKED;
    }

    pub fn futureReadSlice(self: *AsyncScheduler, readable_handle: i32, dst: []u8) Error!u32 {
        return self.futureRead(readable_handle, null, @intFromPtr(dst.ptr), dst.len);
    }

    pub fn futureWrite(
        self: *AsyncScheduler,
        writable_handle: i32,
        mem_ctx: ?*canon.MemoryContext,
        ptr: usize,
        len: usize,
    ) Error!u32 {
        const ref = try self.lookupHandle(writable_handle);
        if (ref.kind != .future_writable) return error.InvalidHandle;
        var fc = &self.futures.items[ref.index];
        if (fc.writable_dropped) return error.InvalidHandle;
        if (fc.has_value) return error.FutureAlreadyResolved;

        if (fc.readable_dropped) {
            return StreamStatus.pack(.closed, 0);
        }

        const op = PendingBufferOp{ .mem_ctx = mem_ctx, .ptr = ptr, .len = len };
        const src = try op.resolveConstSlice();
        const copy_len = @min(src.len, fc.value_buf.len);
        if (copy_len > 0) {
            @memcpy(fc.value_buf[0..copy_len], src[0..copy_len]);
        }
        fc.has_value = true;

        if (fc.pending_read) |pr| {
            const reader_dst = try pr.resolveMutSlice();
            const r_copy = @min(reader_dst.len, copy_len);
            if (r_copy > 0) {
                @memcpy(reader_dst[0..r_copy], src[0..r_copy]);
            }
            fc.pending_read = null;
            fc.read_completed = true;
            const r_ws = fc.readable_waitable_set;
            const r_handle = fc.readable_handle;
            try self.pushEvent(r_ws, .{
                .code = .future_read,
                .index = @bitCast(r_handle),
                .payload = StreamStatus.pack(.completed, 1),
            });
        }

        if (fc.writable_waitable_set != 0) {
            const w_ws = fc.writable_waitable_set;
            try self.pushEvent(w_ws, .{
                .code = .future_write,
                .index = @bitCast(writable_handle),
                .payload = StreamStatus.pack(.completed, 1),
            });
        }

        return StreamStatus.pack(.completed, 1);
    }

    pub fn futureWriteSlice(self: *AsyncScheduler, writable_handle: i32, src: []const u8) Error!u32 {
        return self.futureWrite(writable_handle, null, @intFromPtr(src.ptr), src.len);
    }

    pub fn futureDropReadable(self: *AsyncScheduler, readable_handle: i32) Error!void {
        const ref = try self.lookupHandle(readable_handle);
        if (ref.kind != .future_readable) return error.InvalidHandle;
        var fc = &self.futures.items[ref.index];
        if (fc.readable_dropped) return error.InvalidHandle;
        fc.readable_dropped = true;
        self.detachFromWaitableSet(fc.readable_waitable_set, readable_handle);
        self.handle_table.items[@intCast(readable_handle)].kind = .none;

        if (fc.pending_write != null) {
            fc.pending_write = null;
            const w_ws = fc.writable_waitable_set;
            const w_handle = fc.writable_handle;
            try self.pushEvent(w_ws, .{
                .code = .future_write,
                .index = @bitCast(w_handle),
                .payload = StreamStatus.pack(.closed, 0),
            });
        }
        if (fc.readable_dropped and fc.writable_dropped) {
            fc.deinit(self.allocator);
        }
    }

    pub fn futureDropWritable(self: *AsyncScheduler, writable_handle: i32) Error!void {
        const ref = try self.lookupHandle(writable_handle);
        if (ref.kind != .future_writable) return error.InvalidHandle;
        var fc = &self.futures.items[ref.index];
        if (fc.writable_dropped) return error.InvalidHandle;
        fc.writable_dropped = true;
        self.detachFromWaitableSet(fc.writable_waitable_set, writable_handle);
        self.handle_table.items[@intCast(writable_handle)].kind = .none;

        if (fc.pending_read != null) {
            fc.pending_read = null;
            const r_ws = fc.readable_waitable_set;
            const r_handle = fc.readable_handle;
            try self.pushEvent(r_ws, .{
                .code = .future_read,
                .index = @bitCast(r_handle),
                .payload = StreamStatus.pack(.closed, 0),
            });
        }
        if (fc.readable_dropped and fc.writable_dropped) {
            fc.deinit(self.allocator);
        }
    }

    // ── Per-Task Context Local Storage (`context-get-0` / `context-set-0`) ─

    pub fn contextGet(self: *const AsyncScheduler, slot: u32) error{InvalidContextSlot}!usize {
        if (self.active_task) |t| {
            return t.contextGet(slot);
        }
        if (getActiveTask()) |t| {
            return t.contextGet(slot);
        }
        if (slot >= self.default_context_slots.len) return error.InvalidContextSlot;
        return self.default_context_slots[slot];
    }

    pub fn contextSet(self: *AsyncScheduler, slot: u32, val: usize) error{InvalidContextSlot}!void {
        if (self.active_task) |t| {
            return t.contextSet(slot, val);
        }
        if (getActiveTask()) |t| {
            return t.contextSet(slot, val);
        }
        if (slot >= self.default_context_slots.len) return error.InvalidContextSlot;
        self.default_context_slots[slot] = val;
    }

    pub fn notifyTaskReturn(self: *AsyncScheduler) void {
        self.task_returned = true;
    }

    // ── Guest Callback-Code Driver (`driveGuestAsyncTask`) ─────────────────

    /// Implements the Component Model async callback-code ABI loop for a
    /// guest async export (`start_fn`, `callback_fn`).
    ///
    /// Acquires a `ShadowStack` from `self.stack_pool`, runs `start_fn(args)`
    /// on a `TaskContext`, and loops while the guest returns
    /// `CallbackCode.yield (1)` or `CallbackCode.wait (2) | (ws << 4)` until
    /// `CallbackCode.exit (0)` is returned.
    pub fn driveGuestAsyncTask(
        self: *AsyncScheduler,
        comptime start_fn: anytype,
        args: anytype,
        comptime callback_fn: anytype,
    ) Error!void {
        const stack = try self.stack_pool.acquire(self.allocator);
        var stack_released = false;
        errdefer if (!stack_released) {
            self.stack_pool.release(self.allocator, stack) catch {};
        };

        var task = TaskContext.init(stack, self.sp_binding);
        const prev_sched_task = self.active_task;
        self.active_task = &task;
        defer self.active_task = prev_sched_task;

        const StartRet = @TypeOf(@call(.auto, start_fn, args));
        var raw_code: i32 = blk: {
            if (StartRet == void) {
                task.runStep(start_fn, args);
                break :blk CallbackCode.pack(.exit, 0);
            } else if (StartRet == i32) {
                break :blk task.runStep(start_fn, args);
            } else if (@typeInfo(StartRet) == .error_union) {
                break :blk try task.runStep(start_fn, args);
            } else {
                @compileError("start_fn in driveGuestAsyncTask must return void, i32, or !i32");
            }
        };

        while (true) {
            const unpacked = CallbackCode.unpack(raw_code);
            switch (unpacked.code) {
                .exit => {
                    try task.complete();
                    stack_released = true;
                    try self.stack_pool.release(self.allocator, stack);
                    return;
                },
                .yield => {
                    if (@TypeOf(callback_fn) == @TypeOf(null)) {
                        return error.TaskDidNotExit;
                    }
                    _ = try self.stepOnce();
                    raw_code = invokeGuestCallback(&task, callback_fn, .none, 0, 0);
                },
                .wait => {
                    if (@TypeOf(callback_fn) == @TypeOf(null)) {
                        return error.TaskDidNotExit;
                    }
                    const ws_handle: i32 = @intCast(unpacked.waitable_set);
                    const ev = try self.waitableSetWait(ws_handle, null, 0);
                    raw_code = invokeGuestCallback(&task, callback_fn, ev.code, ev.index, ev.payload);
                },
            }
        }
    }

    fn invokeGuestCallback(
        task: *TaskContext,
        comptime callback_fn: anytype,
        code: EventCode,
        index: u32,
        payload: u32,
    ) i32 {
        const CbType = @TypeOf(callback_fn);
        const fn_info = switch (@typeInfo(CbType)) {
            .@"fn" => |f| f,
            .pointer => |p| @typeInfo(p.child).@"fn",
            else => @compileError("callback_fn must be a function or function pointer"),
        };
        const P0 = fn_info.param_types[0].?;
        const P1 = fn_info.param_types[1].?;
        const P2 = fn_info.param_types[2].?;
        const arg0: P0 = @bitCast(@as(u32, @intFromEnum(code)));
        const arg1: P1 = @bitCast(index);
        const arg2: P2 = @bitCast(payload);
        return task.runStep(callback_fn, .{ arg0, arg1, arg2 });
    }

    /// Attach this `AsyncScheduler` to `mem_ctx` so async `canon.lowerCall`
    /// and `canon.callLifted` automatically suspend/await pending subtasks
    /// and poll deferred `[task-return]` completions.
    pub fn configureMemoryContext(self: *AsyncScheduler, mem_ctx: *canon.MemoryContext) void {
        self.task_returned = false;
        mem_ctx.await_subtask_ctx = self;
        mem_ctx.await_subtask_fn = &awaitSubtaskCallback;
        mem_ctx.poll_task_ctx = self;
        mem_ctx.poll_task_fn = &pollTaskCallback;
    }
};

// ── Adapter Callbacks for `canon.MemoryContext` ────────────────────────────

/// Adapter callback for `canon.MemoryContext`: unpacks `(state, handle)` from
/// `packed_status`, creates a temporary `waitable_set`, joins `handle` to it,
/// calls `waitableSetWait` until `SubtaskState.returned`, drops both the
/// `subtask` and `waitable_set`, and returns.
pub fn awaitSubtaskCallback(
    raw_sched: ?*anyopaque,
    mem_ctx: *canon.MemoryContext,
    packed_status: i32,
) canon.Error!void {
    _ = mem_ctx;
    const unpacked = SubtaskState.unpack(packed_status);
    const subtask_handle: i32 = @intCast(unpacked.handle);
    if (unpacked.state == .returned) {
        if (raw_sched) |ptr| {
            const sched: *AsyncScheduler = @ptrCast(@alignCast(ptr));
            if (subtask_handle > 0) {
                sched.subtaskDrop(subtask_handle) catch {};
            }
        }
        return;
    }
    if (unpacked.state == .cancelled_before_started or unpacked.state == .cancelled_before_returned) {
        if (raw_sched) |ptr| {
            const sched: *AsyncScheduler = @ptrCast(@alignCast(ptr));
            if (subtask_handle > 0) {
                sched.subtaskDrop(subtask_handle) catch {};
            }
        }
        return error.AsyncTaskDidNotReturn;
    }

    const sched: *AsyncScheduler = @ptrCast(@alignCast(raw_sched orelse return error.AsyncCallPending));
    const ws = sched.waitableSetNew() catch return error.OutOfMemory;
    defer sched.waitableSetDrop(ws) catch {};

    sched.waitableJoin(subtask_handle, ws) catch return error.AsyncCallPending;
    while (true) {
        const ev = sched.waitableSetWait(ws, null, 0) catch return error.AsyncCallPending;
        if (ev.code == .subtask and ev.index == @as(u32, @bitCast(subtask_handle))) {
            const st_code = ev.payload & 0xf;
            if (st_code == @intFromEnum(SubtaskState.returned)) {
                break;
            }
            if (st_code == @intFromEnum(SubtaskState.cancelled_before_started) or
                st_code == @intFromEnum(SubtaskState.cancelled_before_returned))
            {
                sched.subtaskDrop(subtask_handle) catch {};
                return error.AsyncTaskDidNotReturn;
            }
        }
    }
    sched.subtaskDrop(subtask_handle) catch {};
}

/// Adapter callback for `canon.MemoryContext`: steps the `AsyncScheduler`
/// once to drive deferred subtasks toward `[task-return]` completion.
pub fn pollTaskCallback(
    raw_sched: ?*anyopaque,
    mem_ctx: *canon.MemoryContext,
) canon.Error!void {
    const sched: *AsyncScheduler = @ptrCast(@alignCast(raw_sched orelse return error.AsyncTaskDidNotReturn));
    const progressed = sched.stepOnce() catch return error.AsyncTaskDidNotReturn;
    if (sched.task_returned) {
        sched.task_returned = false;
        if (canon.getLastAsyncTaskReturnPtr() == null) {
            if (mem_ctx.task_return_fn) |tr_fn| {
                tr_fn(mem_ctx.task_return_ctx, 0);
            }
        }
        return;
    }
    if (!progressed) return error.AsyncTaskDidNotReturn;
}

// ── Unit Tests ─────────────────────────────────────────────────────────────

test "ShadowStack canary initialization, overflow detection, and ShadowStackPool reuse & capacity" {
    const allocator = std.testing.allocator;
    var pool = ShadowStackPool.init(4096);
    defer pool.deinit(allocator);

    // 1. Acquire stack, verify canary and 16-byte aligned top.
    const s1 = try pool.acquire(allocator);
    try std.testing.expect(s1.checkCanary());
    try std.testing.expectEqual(@as(usize, 0), s1.initialTop() & 0xf);
    const base_addr = @intFromPtr(s1.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 4096), s1.relativeInitialTop(base_addr));

    // 2. Release back into pool and verify reuse returns the same underlying buffer.
    const s1_ptr = s1.bytes.ptr;
    try pool.release(allocator, s1);
    try std.testing.expectEqual(@as(usize, 1), pool.pooled_count);

    const s2 = try pool.acquire(allocator);
    try std.testing.expectEqual(s1_ptr, s2.bytes.ptr);
    try pool.release(allocator, s2);

    // 3. Corrupt canary and verify release detects StackOverflow without leaking.
    const corrupted = try pool.acquire(allocator);
    corrupted.bytes[0] ^= 0xff;
    try std.testing.expect(!corrupted.checkCanary());
    try std.testing.expectError(error.StackOverflow, pool.release(allocator, corrupted));

    // 4. Exceed MAX_POOLED_STACKS capacity and ensure excess stacks are freed cleanly.
    var stacks: [ShadowStackPool.MAX_POOLED_STACKS + 4]ShadowStack = undefined;
    for (&stacks) |*st| {
        st.* = try pool.acquire(allocator);
    }
    for (stacks) |st| {
        try pool.release(allocator, st);
    }
    try std.testing.expectEqual(ShadowStackPool.MAX_POOLED_STACKS, pool.pooled_count);
}

test "TaskContext dual-stack __stack_pointer switching and interleaved context_slots" {
    const allocator = std.testing.allocator;
    var pool = ShadowStackPool.init(8192);
    defer pool.deinit(allocator);

    var host_sp: usize = 0x9000_0000;
    const binding = StackPointerBinding.fromHostSlot(&host_sp);

    const stack_a = try pool.acquire(allocator);
    defer pool.release(allocator, stack_a) catch unreachable;
    const stack_b = try pool.acquire(allocator);
    defer pool.release(allocator, stack_b) catch unreachable;

    var task_a = TaskContext.init(stack_a, binding);
    var task_b = TaskContext.init(stack_b, binding);

    // Enter task_a
    task_a.enter();
    try std.testing.expectEqual(TaskContext.State.running, task_a.state);
    try std.testing.expectEqual(stack_a.initialTop(), host_sp);
    try task_a.contextSet(0, 0xAAAA_1111);
    try task_a.contextSet(1, 0xAAAA_2222);

    // Simulate task_a pushing 64 bytes on its shadow stack, then suspending
    host_sp -= 64;
    const task_a_mid_sp = host_sp;
    task_a.suspendTask();
    try std.testing.expectEqual(TaskContext.State.suspended, task_a.state);
    try std.testing.expectEqual(@as(usize, 0x9000_0000), host_sp);
    try std.testing.expectEqual(task_a_mid_sp, task_a.saved_task_sp);
    try std.testing.expectEqual(task_a_mid_sp, task_a.saved_Task_sp);

    // Enter task_b while task_a is suspended
    task_b.enter();
    try std.testing.expectEqual(TaskContext.State.running, task_b.state);
    try std.testing.expectEqual(stack_b.initialTop(), host_sp);
    try task_b.contextSet(0, 0xBBBB_1111);
    host_sp -= 128;
    const task_b_mid_sp = host_sp;
    task_b.suspendTask();
    try std.testing.expectEqual(@as(usize, 0x9000_0000), host_sp);

    // Resume task_a and verify its stack pointer and context slots
    task_a.resumeTask();
    try std.testing.expectEqual(task_a_mid_sp, host_sp);
    try std.testing.expectEqual(@as(usize, 0xAAAA_1111), try task_a.contextGet(0));
    try std.testing.expectEqual(@as(usize, 0xAAAA_2222), try task_a.contextGet(1));
    try task_a.complete();
    try std.testing.expectEqual(TaskContext.State.completed, task_a.state);
    try std.testing.expectEqual(@as(usize, 0x9000_0000), host_sp);

    // Resume task_b and complete it
    task_b.resumeTask();
    try std.testing.expectEqual(task_b_mid_sp, host_sp);
    try std.testing.expectEqual(@as(usize, 0xBBBB_1111), try task_b.contextGet(0));
    try task_b.complete();
    try std.testing.expectEqual(TaskContext.State.completed, task_b.state);
    try std.testing.expectEqual(@as(usize, 0x9000_0000), host_sp);
}

test "AsyncScheduler subtask lifecycle, std.Io integration, waitableSetWait, and waitableSetPoll" {
    const allocator = std.testing.allocator;
    var sched = AsyncScheduler.initWithIo(allocator, std.testing.io);
    defer sched.deinit();

    var mem_buf: [256]u8 align(16) = @splat(0);
    var bump = canon.BumpAllocator.init(64, mem_buf.len);
    var mem_ctx = bump.memoryContext(&mem_buf);

    const ws = try sched.waitableSetNew();
    defer sched.waitableSetDrop(ws) catch unreachable;

    // 1. Poll empty waitable set -> EventCode.none (0).
    const empty_code = try sched.waitableSetPoll(ws, &mem_ctx, 16);
    try std.testing.expectEqual(@as(i32, 0), empty_code);

    // 2. Spawn a host subtask via std.Io that computes a value and writes to a slot.
    var computed_value: u32 = 0;
    const Work = struct {
        fn compute(x: u32, y: u32) u32 {
            return x * y + 7;
        }
        fn onDone(raw_ptr: ?*anyopaque, result: u32) !void {
            const out: *u32 = @ptrCast(@alignCast(raw_ptr.?));
            out.* = result;
        }
    };

    const subtask_handle = try sched.spawnHostSubtask(
        std.testing.io,
        Work.compute,
        .{ @as(u32, 6), @as(u32, 7) },
        &computed_value,
        Work.onDone,
    );
    try std.testing.expectEqual(SubtaskState.started, try sched.subtaskState(subtask_handle));
    try sched.waitableJoin(subtask_handle, ws);

    // 3. Wait on ws -> drives std.Io subtask to .returned and writes [index, payload] to mem_ctx.
    const ev = try sched.waitableSetWait(ws, &mem_ctx, 32);
    try std.testing.expectEqual(EventCode.subtask, ev.code);
    try std.testing.expectEqual(@as(u32, @bitCast(subtask_handle)), ev.index);
    try std.testing.expectEqual(@as(u32, @intFromEnum(SubtaskState.returned)), ev.payload);
    try std.testing.expectEqual(@as(u32, 49), computed_value);

    const written_index = std.mem.readInt(u32, mem_buf[32..36], .little);
    const written_payload = std.mem.readInt(u32, mem_buf[36..40], .little);
    try std.testing.expectEqual(@as(u32, @bitCast(subtask_handle)), written_index);
    try std.testing.expectEqual(@as(u32, @intFromEnum(SubtaskState.returned)), written_payload);

    try sched.subtaskDrop(subtask_handle);
}

test "StreamChannel and FutureChannel async read/write waking waitableSetWait" {
    const allocator = std.testing.allocator;
    var sched = AsyncScheduler.init(allocator);
    defer sched.deinit();

    var mem_buf: [512]u8 align(16) = @splat(0);
    var bump = canon.BumpAllocator.init(64, mem_buf.len);
    var mem_ctx = bump.memoryContext(&mem_buf);

    const ws = try sched.waitableSetNew();
    defer sched.waitableSetDrop(ws) catch unreachable;

    // ── StreamChannel blocked read woken by peer write ──
    const stream = try sched.streamNewWithCapacity(16);
    try sched.waitableJoin(stream.readable, ws);

    // Reader attempts to read 5 bytes into guest address 128 -> returns BLOCKED.
    const read_rc = try sched.streamRead(stream.readable, &mem_ctx, 128, 5);
    try std.testing.expectEqual(BLOCKED, read_rc);

    // Spawn a subtask that writes "hello" into stream.writable when stepped.
    const StreamWriterCtx = struct {
        writable: i32,
        fn step(raw_ctx: ?*anyopaque, s: *AsyncScheduler, _: i32) !SubtaskState {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            const status = try s.streamWriteSlice(self.writable, "hello");
            const unpacked = StreamStatus.unpack(status);
            try std.testing.expectEqual(StreamStatus.completed, unpacked.status);
            try std.testing.expectEqual(@as(u30, 5), unpacked.count);
            return .returned;
        }
    };
    var writer_ctx = StreamWriterCtx{ .writable = stream.writable };
    const writer_subtask = try sched.spawnAsyncSubtask(&writer_ctx, StreamWriterCtx.step);
    defer sched.subtaskDrop(writer_subtask) catch unreachable;

    const stream_ev = try sched.waitableSetWait(ws, &mem_ctx, 64);
    try std.testing.expectEqual(EventCode.stream_read, stream_ev.code);
    try std.testing.expectEqual(@as(u32, @bitCast(stream.readable)), stream_ev.index);
    const stream_res = StreamStatus.unpack(stream_ev.payload);
    try std.testing.expectEqual(StreamStatus.completed, stream_res.status);
    try std.testing.expectEqual(@as(u30, 5), stream_res.count);
    try std.testing.expectEqualStrings("hello", mem_buf[128..133]);

    try sched.streamDropReadable(stream.readable);
    try sched.streamDropWritable(stream.writable);

    // ── FutureChannel blocked read woken by peer write ──
    const fut = try sched.futureNew(4);
    try sched.waitableJoin(fut.readable, ws);

    const fut_read_rc = try sched.futureRead(fut.readable, &mem_ctx, 200, 4);
    try std.testing.expectEqual(BLOCKED, fut_read_rc);

    const FutureWriterCtx = struct {
        writable: i32,
        fn step(raw_ctx: ?*anyopaque, s: *AsyncScheduler, _: i32) !SubtaskState {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            var val_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &val_bytes, 0xCAFE_1234, .little);
            const status = try s.futureWriteSlice(self.writable, &val_bytes);
            const unpacked = StreamStatus.unpack(status);
            try std.testing.expectEqual(StreamStatus.completed, unpacked.status);
            return .returned;
        }
    };
    var fut_writer_ctx = FutureWriterCtx{ .writable = fut.writable };
    const fut_writer_subtask = try sched.spawnAsyncSubtask(&fut_writer_ctx, FutureWriterCtx.step);
    defer sched.subtaskDrop(fut_writer_subtask) catch unreachable;

    const fut_ev = try sched.waitableSetWait(ws, &mem_ctx, 72);
    try std.testing.expectEqual(EventCode.future_read, fut_ev.code);
    try std.testing.expectEqual(@as(u32, @bitCast(fut.readable)), fut_ev.index);
    try std.testing.expectEqual(@as(u32, 0xCAFE_1234), std.mem.readInt(u32, mem_buf[200..204], .little));

    try sched.futureDropReadable(fut.readable);
    try sched.futureDropWritable(fut.writable);
}

test "driveGuestAsyncTask with simulated guest async export yielding and waiting before task-return" {
    const allocator = std.testing.allocator;
    var sched = AsyncScheduler.init(allocator);
    defer sched.deinit();

    var host_sp: usize = 0x7000_0000;
    sched.sp_binding = StackPointerBinding.fromHostSlot(&host_sp);

    const GuestSim = struct {
        var sched_ptr: *AsyncScheduler = undefined;
        var ws_handle: i32 = 0;
        var subtask_handle: i32 = 0;
        var host_result: u32 = 0;
        var task_return_value: u32 = 0;
        var step_counter: u32 = 0;

        fn hostSubtaskStep(_: ?*anyopaque, _: *AsyncScheduler, _: i32) !SubtaskState {
            step_counter += 1;
            if (step_counter < 2) {
                return .started;
            }
            host_result = 100;
            return .returned;
        }

        fn guestExportStart(input: u32) !i32 {
            // Store input in task-local context slot 0
            try sched_ptr.contextSet(0, input);
            // First yield cooperatively
            return CallbackCode.pack(.yield, 0);
        }

        fn guestExportCallback(event_code: u32, index: u32, payload: u32) i32 {
            const ev = EventCode.fromInt(event_code);
            if (ev == .none) {
                // Resumed from yield: spawn async host subtask, join to waitable set, and returnWAIT
                ws_handle = sched_ptr.waitableSetNew() catch unreachable;
                subtask_handle = sched_ptr.spawnAsyncSubtask(null, hostSubtaskStep) catch unreachable;
                sched_ptr.waitableJoin(subtask_handle, ws_handle) catch unreachable;
                return CallbackCode.pack(.wait, @intCast(ws_handle));
            }
            if (ev == .subtask and index == @as(u32, @bitCast(subtask_handle)) and payload == @intFromEnum(SubtaskState.returned)) {
                const saved_input: u32 = @intCast(sched_ptr.contextGet(0) catch unreachable);
                task_return_value = saved_input + host_result;
                sched_ptr.notifyTaskReturn();
                sched_ptr.subtaskDrop(subtask_handle) catch unreachable;
                sched_ptr.waitableSetDrop(ws_handle) catch unreachable;
                return CallbackCode.pack(.exit, 0);
            }
            unreachable;
        }
    };

    GuestSim.sched_ptr = &sched;
    GuestSim.ws_handle = 0;
    GuestSim.subtask_handle = 0;
    GuestSim.host_result = 0;
    GuestSim.task_return_value = 0;
    GuestSim.step_counter = 0;

    try sched.driveGuestAsyncTask(
        GuestSim.guestExportStart,
        .{@as(u32, 42)},
        GuestSim.guestExportCallback,
    );

    try std.testing.expect(sched.task_returned);
    try std.testing.expectEqual(@as(u32, 142), GuestSim.task_return_value);
    try std.testing.expectEqual(@as(usize, 0x7000_0000), host_sp);
}

test "awaitSubtaskCallback drives pending subtask to returned" {
    const allocator = std.testing.allocator;
    var sched = AsyncScheduler.init(allocator);
    defer sched.deinit();

    var mem_buf: [128]u8 align(16) = @splat(0);
    var bump = canon.BumpAllocator.init(32, mem_buf.len);
    var mem_ctx = bump.memoryContext(&mem_buf);

    var steps: u32 = 0;
    const PendingWork = struct {
        fn step(raw_ctx: ?*anyopaque, _: *AsyncScheduler, _: i32) !SubtaskState {
            const count_ptr: *u32 = @ptrCast(@alignCast(raw_ctx.?));
            count_ptr.* += 1;
            return if (count_ptr.* >= 2) .returned else .started;
        }
    };

    const handle = try sched.spawnAsyncSubtask(&steps, PendingWork.step);
    const packed_status = SubtaskState.started.pack(@intCast(handle));

    try awaitSubtaskCallback(&sched, &mem_ctx, packed_status);
    try std.testing.expectEqual(@as(u32, 2), steps);
}

test "AsyncScheduler.configureMemoryContext end-to-end with canon.lowerCall and canon.callLifted" {
    const allocator = std.testing.allocator;
    var sched = AsyncScheduler.init(allocator);
    defer sched.deinit();

    var mem_buf: [1024]u8 align(16) = @splat(0);
    var bump = canon.BumpAllocator.init(64, mem_buf.len);
    var mem_ctx = bump.memoryContext(&mem_buf);
    sched.configureMemoryContext(&mem_ctx);

    const AsyncImportEnv = struct {
        sched_ptr: *AsyncScheduler,
        mem_ctx_ptr: *canon.MemoryContext,
        arg_val: u32 = 0,
        ret_ptr: usize = 0,
        step_count: u32 = 0,

        var current: ?*@This() = null;

        fn step(raw_ctx: ?*anyopaque, _: *AsyncScheduler, _: i32) !SubtaskState {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            self.step_count += 1;
            if (self.step_count < 2) return .started;
            try canon.storeToMemory(u32, .wasm32, self.mem_ctx_ptr.*, self.ret_ptr, self.arg_val * 10 + 7);
            return .returned;
        }

        fn coreImport(x: i32, ret_ptr: i32) i32 {
            const self = current.?;
            self.arg_val = @bitCast(x);
            self.ret_ptr = @intCast(@as(u32, @bitCast(ret_ptr)));
            const handle = self.sched_ptr.spawnAsyncSubtask(self, step) catch unreachable;
            return SubtaskState.started.pack(@intCast(handle));
        }
    };

    var import_env = AsyncImportEnv{
        .sched_ptr = &sched,
        .mem_ctx_ptr = &mem_ctx,
    };
    AsyncImportEnv.current = &import_env;
    defer AsyncImportEnv.current = null;

    const ComputeFn = fn (x: u32) u32;
    const lower_opts = canon.CallOptions{
        .arch = .wasm32,
        .is_async = true,
        .direction = .lower,
    };

    const result = try canon.lowerCall(ComputeFn, lower_opts, mem_ctx, &AsyncImportEnv.coreImport, .{9});
    try std.testing.expectEqual(@as(u32, 97), result);
    try std.testing.expectEqual(@as(u32, 2), import_env.step_count);

    // Also test deferred [task-return] with canon.callLifted and pollTaskCallback
    const DeferredExportEnv = struct {
        sched_ptr: *AsyncScheduler,
        pending_val: u32 = 0,
        steps: u32 = 0,

        var current: ?*@This() = null;

        fn step(raw_ctx: ?*anyopaque, _: *AsyncScheduler, _: i32) !SubtaskState {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            self.steps += 1;
            if (self.steps < 2) return .started;
            if (canon.getActiveMemoryContext()) |active_ctx| {
                var mctx = active_ctx;
                const ret_ptr = try mctx.realloc(4, 4);
                try canon.storeToMemory(u32, .wasm32, mctx, ret_ptr, self.pending_val + 1000);
                if (mctx.task_return_fn) |tr_fn| {
                    tr_fn(mctx.task_return_ctx, ret_ptr);
                }
            }
            return .returned;
        }

        fn coreExport(x: i32) void {
            const self = current.?;
            self.pending_val = @bitCast(x);
            _ = self.sched_ptr.spawnAsyncSubtask(self, step) catch unreachable;
        }
    };

    var export_env = DeferredExportEnv{ .sched_ptr = &sched };
    DeferredExportEnv.current = &export_env;
    defer DeferredExportEnv.current = null;

    const lifted_res = try canon.callLifted(
        ComputeFn,
        .{ .arch = .wasm32, .is_async = true },
        mem_ctx,
        &DeferredExportEnv.coreExport,
        .{23},
    );
    try std.testing.expectEqual(@as(u32, 1023), lifted_res);
    try std.testing.expectEqual(@as(u32, 2), export_env.steps);
}

test "Adversarial edge cases: deadlock detection, waitableSetDrop cleanup, cancelled subtasks, void async exports, and re-entrant TaskContext" {
    const allocator = std.testing.allocator;

    // 1. stepOnce / waitableSetWait deadlock detection when a subtask stays in .started without pushing events
    {
        var sched = AsyncScheduler.init(allocator);
        defer sched.deinit();

        const StagnantWork = struct {
            fn step(_: ?*anyopaque, _: *AsyncScheduler, _: i32) !SubtaskState {
                return .started;
            }
        };

        const ws = try sched.waitableSetNew();
        defer sched.waitableSetDrop(ws) catch unreachable;
        const st = try sched.spawnAsyncSubtask(null, StagnantWork.step);
        defer sched.subtaskDrop(st) catch unreachable;
        try sched.waitableJoin(st, ws);

        try std.testing.expectError(error.DeadlockDetected, sched.waitableSetWait(ws, null, 0));
        try std.testing.expectEqual(false, try sched.stepOnce());
    }

    // 2. waitableSetDrop clears joined waitables' waitable_set fields so later events do not fail with InvalidWaitableSet
    {
        var sched = AsyncScheduler.init(allocator);
        defer sched.deinit();

        const ws = try sched.waitableSetNew();
        const stream = try sched.streamNewWithCapacity(16);
        const fut = try sched.futureNew(4);
        const st = try sched.createSubtask(.started, null, null);
        defer sched.subtaskDrop(st) catch unreachable;

        try sched.waitableJoin(stream.readable, ws);
        try sched.waitableJoin(stream.writable, ws);
        try sched.waitableJoin(fut.readable, ws);
        try sched.waitableJoin(fut.writable, ws);
        try sched.waitableJoin(st, ws);

        // Drop the waitable set while handles are still joined
        try sched.waitableSetDrop(ws);

        // Subsequent operations that would have pushed events to the dropped waitable set must succeed
        var read_buf: [4]u8 = @splat(0);
        try std.testing.expectEqual(BLOCKED, try sched.streamReadSlice(stream.readable, &read_buf));
        const write_res = try sched.streamWriteSlice(stream.writable, "ok");
        try std.testing.expectEqual(StreamStatus.completed, StreamStatus.unpack(write_res).status);

        var fut_val: [4]u8 = .{ 1, 2, 3, 4 };
        _ = try sched.futureWriteSlice(fut.writable, &fut_val);
        try sched.resolveSubtask(st, .returned);

        try sched.streamDropReadable(stream.readable);
        try sched.streamDropWritable(stream.writable);
        try sched.futureDropReadable(fut.readable);
        try sched.futureDropWritable(fut.writable);
    }

    // 3. Cancelled subtasks in waitableJoin and awaitSubtaskCallback
    {
        var sched = AsyncScheduler.init(allocator);
        defer sched.deinit();

        var mem_buf: [128]u8 align(16) = @splat(0);
        var bump = canon.BumpAllocator.init(32, mem_buf.len);
        var mem_ctx = bump.memoryContext(&mem_buf);

        // Already-cancelled subtask joined to waitableSet queues immediate terminal event
        const ws = try sched.waitableSetNew();
        defer sched.waitableSetDrop(ws) catch unreachable;
        const st_cancelled = try sched.createSubtask(.cancelled_before_started, null, null);
        try sched.waitableJoin(st_cancelled, ws);
        const ev = try sched.waitableSetWait(ws, null, 0);
        try std.testing.expectEqual(EventCode.subtask, ev.code);
        try std.testing.expectEqual(@as(u32, @intFromEnum(SubtaskState.cancelled_before_started)), ev.payload);
        try sched.subtaskDrop(st_cancelled);

        // Subtask that transitions to .cancelled_before_returned during awaitSubtaskCallback returns error.AsyncTaskDidNotReturn
        const CancelWork = struct {
            fn step(_: ?*anyopaque, _: *AsyncScheduler, _: i32) !SubtaskState {
                return .cancelled_before_returned;
            }
        };
        const st_pending_cancel = try sched.spawnAsyncSubtask(null, CancelWork.step);
        const packed_pending = SubtaskState.started.pack(@intCast(st_pending_cancel));
        try std.testing.expectError(
            error.AsyncTaskDidNotReturn,
            awaitSubtaskCallback(&sched, &mem_ctx, packed_pending),
        );
        // Handle was dropped by awaitSubtaskCallback
        try std.testing.expectError(error.InvalidHandle, sched.subtaskState(st_pending_cancel));
    }

    // 4. RetT == void async exports with notifyTaskReturn vs missing task-return
    {
        var sched = AsyncScheduler.init(allocator);
        defer sched.deinit();

        var mem_buf: [256]u8 align(16) = @splat(0);
        var bump = canon.BumpAllocator.init(32, mem_buf.len);
        var mem_ctx = bump.memoryContext(&mem_buf);
        sched.configureMemoryContext(&mem_ctx);

        const VoidAsyncExport = struct {
            var sched_ptr: *AsyncScheduler = undefined;
            var should_return: bool = true;

            fn step(_: ?*anyopaque, s: *AsyncScheduler, _: i32) !SubtaskState {
                if (should_return) {
                    s.notifyTaskReturn();
                }
                return .returned;
            }

            fn coreExport(_: i32) void {
                _ = sched_ptr.spawnAsyncSubtask(null, step) catch unreachable;
            }
        };
        VoidAsyncExport.sched_ptr = &sched;

        const VoidFn = fn (u32) void;
        VoidAsyncExport.should_return = true;
        try canon.callLifted(VoidFn, .{ .arch = .wasm32, .is_async = true }, mem_ctx, &VoidAsyncExport.coreExport, .{7});

        sched.configureMemoryContext(&mem_ctx);
        VoidAsyncExport.should_return = false;
        try std.testing.expectError(
            error.AsyncTaskDidNotReturn,
            canon.callLifted(VoidFn, .{ .arch = .wasm32, .is_async = true }, mem_ctx, &VoidAsyncExport.coreExport, .{7}),
        );
    }

    // 5. Re-entrant TaskContext.run and TaskContext.runStep preserve .running state on inner call
    {
        var pool = ShadowStackPool.init(4096);
        defer pool.deinit(allocator);
        var host_sp: usize = 0x8000_0000;
        const binding = StackPointerBinding.fromHostSlot(&host_sp);
        const stack = try pool.acquire(allocator);
        defer pool.release(allocator, stack) catch unreachable;

        var task = TaskContext.init(stack, binding);
        const Reentrant = struct {
            fn inner(t: *TaskContext, x: u32) u32 {
                std.debug.assert(t.state == .running);
                return x + 10;
            }
            fn outer(t: *TaskContext, x: u32) u32 {
                const y = t.run(inner, .{ t, x });
                // Must still be .running after nested t.run returns!
                std.debug.assert(t.state == .running);
                const z = t.runStep(inner, .{ t, y });
                std.debug.assert(t.state == .running);
                return z + 5;
            }
        };

        const res = task.run(Reentrant.outer, .{ &task, @as(u32, 1) });
        try std.testing.expectEqual(@as(u32, 26), res);
        try std.testing.expectEqual(TaskContext.State.completed, task.state);
        try std.testing.expectEqual(@as(usize, 0x8000_0000), host_sp);
    }
}


