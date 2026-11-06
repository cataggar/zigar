//! Comptime Browser/JS and Zig Host Bridge for `wit-zigar` (`zigar_bridge.zig`).
//!
//! Bridges `wit-zigar` generated bindings and WebAssembly Component instances to
//! `zigar` (`zigar-compiler` + `zigar-runtime`), enabling:
//!   1. Zero-copy linear-memory and `zigar:abi` scratch management (`BridgeMemory`)
//!      for `DataView`-backed `extern struct`s and `TypedArray`/slice views in JS.
//!   2. Idiomatic conversion between WIT `Result(Ok, Err)` tagged unions and Zig
//!      error unions (`isWitResult`, `unwrapWitResult`, `wrapWitResult`) so `zigar`
//!      automatically translates component errors into JavaScript exceptions.
//!   3. Comptime function signature preservation (`wrapWitFn`, `wrapLoweredCall`,
//!      `wrapFastCall`, `CallBridge`, `HostInstanceBridge`, `ZigarBridge`) so
//!      `zigar-compiler`'s `export.zig` reflects exact WIT parameter and return types
//!      while dispatching over the zero-copy `"zigar:abi"` fast path or falling back
//!      to the Component Model Canonical ABI (`CanonLower` / `CanonLift`).
//!   4. WebAssembly JSPI (`{ useJSPI: true }`) continuation and concurrency tracking
//!      (`JspiSuspensionTracker`) to verify stackful interleaving across separate
//!      `__stack_pointer` shadow stacks during `Promise.all([...])`.

const std = @import("std");
const builtin = @import("builtin");

pub const canon = @import("canon.zig");
pub const fast_abi = @import("fast_abi.zig");

// ── 1. Zero-Copy Linear Memory & Scratch Bridge (`BridgeMemory`) ───────────

pub const DEFAULT_BRIDGE_CAPACITY: usize = 65536;
pub const DEFAULT_FAST_SCRATCH_SIZE: usize = fast_abi.DEFAULT_FAST_SCRATCH_LEN;
pub const DEFAULT_INITIAL_BUMP_OFFSET: usize = 64;

/// Self-contained linear memory + `canon.BumpAllocator` + `canon.MemoryContext`
/// + 64 KiB `zigar:abi` fast-path scratch region that a Zig module compiled by
/// `wazig` / `zigar` can instantiate globally or per-instance.
pub fn BridgeMemory(comptime capacity: usize) type {
    comptime {
        if (capacity < DEFAULT_INITIAL_BUMP_OFFSET) {
            @compileError("BridgeMemory capacity must be at least 64 bytes");
        }
    }

    return struct {
        const Self = @This();

        pub const linear_capacity: usize = capacity;
        pub const scratch_capacity: usize = DEFAULT_FAST_SCRATCH_SIZE;
        pub const total_capacity: usize = capacity + DEFAULT_FAST_SCRATCH_SIZE;

        /// Contiguous 16-byte aligned backing store holding both the general
        /// Canonical ABI bump region (`0..capacity`) and the 64 KiB `zigar:abi`
        /// fast-path frame/scratch region (`capacity..total_capacity`).
        buffer: [total_capacity]u8 align(16) = @splat(0),

        /// Optional externally-attached guest linear memory slice. When null,
        /// `self.buffer` is used.
        external_memory: ?[]u8 = null,

        /// Base address corresponding to offset 0 of the active memory slice.
        base_addr: usize = 0,

        /// Initial offset for the Canonical ABI bump allocator (reserves offset
        /// `0..64` so non-empty allocations never return address 0).
        initial_bump_offset: usize = DEFAULT_INITIAL_BUMP_OFFSET,

        /// Bump allocator state for Canonical ABI `cabi_realloc` calls.
        bump: canon.BumpAllocator = canon.BumpAllocator.init(DEFAULT_INITIAL_BUMP_OFFSET, capacity),

        /// Start offset of the `zigar:abi` fast-path `ArgStruct` scratch region.
        fast_frame_offset: usize = capacity,

        /// Current bump cursor within the `zigar:abi` fast-path scratch region.
        fast_bump_cursor: usize = capacity,

        /// Exclusive end offset of the `zigar:abi` fast-path scratch region.
        fast_scratch_limit: usize = capacity + DEFAULT_FAST_SCRATCH_SIZE,

        /// Number of `realloc` invocations served since initialization or last reset.
        realloc_count: usize = 0,

        /// Most recent pointer delivered to `task_return_fn` (`[task-return]`).
        last_task_return_ptr: ?usize = null,
        task_return_count: usize = 0,

        /// Most recent pointer delivered to `post_return_fn` (`cabi_post_*`).
        last_post_return_ptr: ?usize = null,
        post_return_count: usize = 0,

        pub fn init() Self {
            return .{};
        }

        /// Attach an external guest linear memory slice instead of the inline buffer.
        /// Reserves the upper 64 KiB (or upper half if smaller than 128 KiB) for
        /// `zigar:abi` fast-path scratch and the lower region for `cabi_realloc`.
        pub fn initExternal(mem_slice: []u8, base_addr: usize) canon.Error!Self {
            var self = Self{};
            try self.attachMemory(mem_slice, base_addr);
            return self;
        }

        pub fn attachMemory(self: *Self, mem_slice: []u8, base_addr: usize) canon.Error!void {
            if (mem_slice.len < DEFAULT_INITIAL_BUMP_OFFSET * 2) {
                return error.OutOfBounds;
            }
            const raw_split = if (mem_slice.len > DEFAULT_FAST_SCRATCH_SIZE + DEFAULT_INITIAL_BUMP_OFFSET)
                mem_slice.len - DEFAULT_FAST_SCRATCH_SIZE
            else
                mem_slice.len / 2;
            const split = raw_split & ~@as(usize, 15);
            if (split <= DEFAULT_INITIAL_BUMP_OFFSET) {
                return error.OutOfBounds;
            }
            self.external_memory = mem_slice;
            self.base_addr = base_addr;
            self.initial_bump_offset = DEFAULT_INITIAL_BUMP_OFFSET;
            self.bump = canon.BumpAllocator.init(DEFAULT_INITIAL_BUMP_OFFSET, split);
            self.fast_frame_offset = split;
            self.fast_bump_cursor = split;
            self.fast_scratch_limit = mem_slice.len;
            self.realloc_count = 0;
            self.last_task_return_ptr = null;
            self.task_return_count = 0;
            self.last_post_return_ptr = null;
            self.post_return_count = 0;
        }

        /// Return the active linear memory slice (`external_memory` if attached,
        /// otherwise the inline `buffer`).
        pub inline fn memorySlice(self: *Self) []u8 {
            return self.external_memory orelse &self.buffer;
        }

        /// Return the `zigar:abi` fast-path scratch region sub-slice.
        pub inline fn scratchSlice(self: *Self) []u8 {
            const mem = self.memorySlice();
            return mem[self.fast_frame_offset..self.fast_scratch_limit];
        }

        /// Reset both the Canonical ABI bump allocator cursor and the `zigar:abi`
        /// fast-path scratch cursor between calls once zero-copy borrows are complete.
        pub fn resetScratch(self: *Self) void {
            self.bump.offset = self.initial_bump_offset;
            self.fast_bump_cursor = self.fast_frame_offset;
            self.last_task_return_ptr = null;
        }

        /// Reset `self` and synchronize an existing `canon.MemoryContext` instance.
        pub fn resetContextScratch(self: *Self, ctx: *canon.MemoryContext) void {
            self.resetScratch();
            ctx.fast_frame_offset = self.fast_frame_offset;
            ctx.fast_bump_cursor = self.fast_bump_cursor;
            ctx.fast_scratch_limit = self.fast_scratch_limit;
        }

        /// Copy `items` directly into the linear-memory bump region and return a
        /// zero-copy slice backed by linear memory (`self.memorySlice()`).
        pub fn copySliceInPlace(self: *Self, comptime T: type, items: []const T) canon.Error![]T {
            if (items.len == 0) return &[_]T{};
            const byte_len = std.math.mul(usize, items.len, @sizeOf(T)) catch return error.OutOfBounds;
            const addr = try Self.reallocCallback(self, 0, 0, @alignOf(T), byte_len);
            const mem = self.memorySlice();
            if (addr < self.base_addr) return error.OutOfBounds;
            const off = addr - self.base_addr;
            if (off > mem.len or mem.len - off < byte_len) return error.OutOfBounds;
            const dst_bytes = mem[off..][0..byte_len];
            @memcpy(dst_bytes, std.mem.sliceAsBytes(items));
            const typed_ptr: [*]T = @ptrCast(@alignCast(dst_bytes.ptr));
            return typed_ptr[0..items.len];
        }

        fn reallocCallback(
            raw_ctx: ?*anyopaque,
            orig_ptr: usize,
            orig_size: usize,
            alignment: usize,
            new_size: usize,
        ) canon.Error!usize {
            const self: *Self = @ptrCast(@alignCast(raw_ctx orelse return error.MissingRealloc));
            const off = try canon.BumpAllocator.realloc(&self.bump, orig_ptr, orig_size, alignment, new_size);
            self.realloc_count += 1;
            return self.base_addr + off;
        }

        fn taskReturnCallback(raw_ctx: ?*anyopaque, ret_val: usize) void {
            const self: *Self = @ptrCast(@alignCast(raw_ctx orelse return));
            self.last_task_return_ptr = ret_val;
            self.task_return_count += 1;
        }

        fn postReturnCallback(raw_ctx: ?*anyopaque, ret_val: usize) void {
            const self: *Self = @ptrCast(@alignCast(raw_ctx orelse return));
            self.last_post_return_ptr = ret_val;
            self.post_return_count += 1;
        }

        /// Build a `canon.MemoryContext` pre-configured with `realloc_fn`,
        /// `task_return_fn`, `post_return_fn`, zero-copy slice lifting, and the
        /// 64 KiB `zigar:abi` fast-path scratch region.
        pub fn memoryContext(self: *Self, allocator: ?std.mem.Allocator) canon.MemoryContext {
            return .{
                .memory = self.memorySlice(),
                .base_addr = self.base_addr,
                .realloc_ctx = self,
                .realloc_fn = &Self.reallocCallback,
                .post_return_ctx = self,
                .post_return_fn = &Self.postReturnCallback,
                .task_return_ctx = self,
                .task_return_fn = &Self.taskReturnCallback,
                .allocator = allocator,
                .zero_copy_slices = true,
                .validate_utf8 = true,
                .fast_frame_offset = self.fast_frame_offset,
                .fast_bump_cursor = self.fast_bump_cursor,
                .fast_scratch_limit = self.fast_scratch_limit,
            };
        }
    };
}

// ── 2. WIT `Result(Ok, Err)` <-> Zig Error Union / JS Conversion Helpers ───

/// Error set raised when a WIT `result<Ok, Err>` holds an `.err` payload.
pub const WitErrorSet = error{
    WitResultError,
};

/// Combined error set for bridged calls that may fail either at the Canonical/Fast
/// ABI layer (`canon.Error`) or with a WIT application error (`WitErrorSet`).
pub const BridgeError = canon.Error || WitErrorSet;

/// Returns true if `T` is a WIT `Result(Ok, Err)` tagged union generated by
/// `wit-zigar` (`canon.Result` or `bindgen.zig`'s emitted `Result`).
pub fn isWitResult(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"union" => @hasDecl(T, "wit_is_result") and T.wit_is_result,
        else => false,
    };
}

/// Thread-local storage for the most recent `.err` payload unwrapped from a
/// WIT `Result(Ok, Err)` of error payload type `Err`.
pub fn LastWitErrorStore(comptime Err: type) type {
    if (comptime (@typeInfo(Err) == .@"enum" or @typeInfo(Err) == .@"struct" or @typeInfo(Err) == .@"union") and @hasDecl(Err, "WitLastErrorSlot")) {
        return Err.WitLastErrorSlot;
    }
    return struct {
        pub threadlocal var last_err: ?Err = null;
    };
}

pub fn getLastWitError(comptime Err: type) ?Err {
    if (comptime Err == void) return {};
    return LastWitErrorStore(Err).last_err;
}

pub fn setLastWitError(comptime Err: type, err_val: Err) void {
    if (comptime Err == void) return;
    LastWitErrorStore(Err).last_err = err_val;
}

pub fn clearLastWitError(comptime Err: type) void {
    if (comptime Err == void) return;
    LastWitErrorStore(Err).last_err = null;
}

/// Convert a WIT `Result(Ok, Err)` union into a Zig error union
/// `WitErrorSet!Ok`, storing the `Err` payload in `LastWitErrorStore(Err)`
/// when `res == .err` so callers or `wrapWitResult` can inspect or round-trip it.
pub fn unwrapWitResult(res: anytype) WitErrorSet!@TypeOf(res).OkType {
    const ResT = @TypeOf(res);
    comptime {
        if (!isWitResult(ResT)) {
            @compileError("unwrapWitResult expects a WIT Result(Ok, Err) union, got " ++ @typeName(ResT));
        }
    }
    return switch (res) {
        .ok => |ok_val| {
            clearLastWitError(ResT.ErrType);
            return ok_val;
        },
        .err => |err_val| {
            setLastWitError(ResT.ErrType, err_val);
            return error.WitResultError;
        },
    };
}

fn defaultErrPayload(comptime ErrT: type, err: anyerror) ErrT {
    if (comptime ErrT == void) return {};
    if (comptime ErrT == []const u8) return @errorName(err);
    if (comptime canon.isStringWrapper(ErrT)) return .{ .bytes = @errorName(err) };
    return switch (@typeInfo(ErrT)) {
        .int, .comptime_int => 0,
        .float, .comptime_float => 0.0,
        .bool => false,
        .@"enum" => |en| @enumFromInt(en.fields[0].value),
        .optional => null,
        .error_set => |es| blk: {
            if (es.error_names) |names| {
                inline for (names) |name| {
                    if (std.mem.eql(u8, name, @errorName(err))) {
                        break :blk @field(ErrT, name);
                    }
                }
                break :blk @field(ErrT, names[0]);
            }
            break :blk err;
        },
        else => std.mem.zeroes(ErrT),
    };
}

/// Convert a Zig error union (`E!Ok`), error value, or `Ok` payload back into a
/// WIT `Result(Ok, Err)` tagged union `ResultT`.
/// When converting an error back into `.err`, uses the stored payload from
/// `getLastWitError(ResultT.ErrType)` if present, or synthesizes a default error
/// payload for `ResultT.ErrType`.
pub fn wrapWitResult(comptime ResultT: type, val_or_err: anytype) ResultT {
    comptime {
        if (!isWitResult(ResultT)) {
            @compileError("wrapWitResult expects a WIT Result(Ok, Err) target type, got " ++ @typeName(ResultT));
        }
    }
    const InT = @TypeOf(val_or_err);
    if (comptime InT == ResultT) {
        return val_or_err;
    }
    switch (@typeInfo(InT)) {
        .error_union => {
            if (val_or_err) |ok_val| {
                return .{ .ok = ok_val };
            } else |err| {
                if (comptime ResultT.ErrType == void) {
                    return .{ .err = {} };
                }
                if (err == error.WitResultError) {
                    if (getLastWitError(ResultT.ErrType)) |stored_err| {
                        clearLastWitError(ResultT.ErrType);
                        return .{ .err = stored_err };
                    }
                }
                return .{ .err = defaultErrPayload(ResultT.ErrType, err) };
            }
        },
        .error_set => {
            if (comptime ResultT.ErrType == void) {
                return .{ .err = {} };
            }
            if (val_or_err == error.WitResultError) {
                if (getLastWitError(ResultT.ErrType)) |stored_err| {
                    clearLastWitError(ResultT.ErrType);
                    return .{ .err = stored_err };
                }
            }
            return .{ .err = defaultErrPayload(ResultT.ErrType, val_or_err) };
        },
        else => {
            return .{ .ok = val_or_err };
        },
    }
}

/// Convert a Zig error union (`E!Ok`) into `ResultT`, using `fallback_err` if an
/// error occurred and no thread-local WIT error payload was recorded.
pub fn wrapWitResultWithErr(
    comptime ResultT: type,
    val_or_err: anytype,
    fallback_err: ResultT.ErrType,
) ResultT {
    comptime {
        if (!isWitResult(ResultT)) {
            @compileError("wrapWitResultWithErr expects a WIT Result(Ok, Err) target type, got " ++ @typeName(ResultT));
        }
    }
    const InT = @TypeOf(val_or_err);
    if (comptime InT == ResultT) return val_or_err;
    switch (@typeInfo(InT)) {
        .error_union => {
            if (val_or_err) |ok_val| {
                return .{ .ok = ok_val };
            } else |_| {
                return .{ .err = fallback_err };
            }
        },
        .error_set => return .{ .err = fallback_err },
        else => return .{ .ok = val_or_err },
    }
}

// ── 3. Comptime Function & Interface Wrapper for `zigar` ───────────────────

fn FnTypeOfCallable(comptime CallableT: type) type {
    return switch (@typeInfo(CallableT)) {
        .@"fn" => CallableT,
        .pointer => |pt| if (@typeInfo(pt.child) == .@"fn")
            pt.child
        else
            @compileError("Expected function or function pointer, got " ++ @typeName(CallableT)),
        else => @compileError("Expected function or function pointer, got " ++ @typeName(CallableT)),
    };
}

/// Compute the return type of a `wrapWitFn`-wrapped function:
/// - When `unwrap_result` is true and `FnT` (or `CallableT`) returns `Result(Ok, Err)`
///   or `canon.CanonResult(Result(Ok, Err))`, returns `(canon.Error || WitErrorSet)!Ok`.
/// - When `unwrap_result` is false (or `FnT` does not return a WIT `Result`),
///   preserves `CallableT`'s return type (`canon.CanonResult(R)` or `R`).
pub fn WrappedWitReturnType(
    comptime FnT: type,
    comptime CallableT: type,
    comptime unwrap_result: bool,
) type {
    const WitRet = canon.ReturnType(FnT);
    const ImplFn = FnTypeOfCallable(CallableT);
    const ImplRet = canon.ReturnType(ImplFn);

    if (!unwrap_result) {
        return ImplRet;
    }

    if (comptime isWitResult(WitRet)) {
        return BridgeError!WitRet.OkType;
    }

    if (comptime @typeInfo(WitRet) == .error_union) {
        const eu = @typeInfo(WitRet).error_union;
        if (comptime isWitResult(eu.payload)) {
            return (BridgeError || eu.error_set)!eu.payload.OkType;
        }
    }

    if (comptime @typeInfo(ImplRet) == .error_union) {
        const eu = @typeInfo(ImplRet).error_union;
        if (comptime isWitResult(eu.payload)) {
            return (BridgeError || eu.error_set)!eu.payload.OkType;
        }
    }

    return ImplRet;
}

/// Compute the exact Zig `fn (...) ReturnType` signature produced by `wrapWitFn`.
/// Preserves the exact parameter types of `FnT` (`extern struct` records,
/// `[]const T` slices, `[]const u8` strings, `Own`/`Borrow`/`Stream`/`Future` handles)
/// so `zigar-compiler` generates zero-copy `DataView` and `TypedArray` bindings.
pub fn WrappedWitFnType(
    comptime FnT: type,
    comptime CallableT: type,
    comptime unwrap_result: bool,
) type {
    const f = @typeInfo(FnT).@"fn";
    var param_types: [f.param_types.len]type = undefined;
    var param_attrs: [f.param_types.len]std.lang.Type.Fn.ParamAttributes = undefined;
    for (f.param_types, 0..) |maybe_pt, i| {
        param_types[i] = maybe_pt.?;
        param_attrs[i] = f.param_attrs[i];
    }
    const OutRet = WrappedWitReturnType(FnT, CallableT, unwrap_result);
    return @Fn(&param_types, &param_attrs, OutRet, .{});
}

fn TupleElemType(comptime TupleT: type, comptime idx: usize) type {
    const fields = @typeInfo(TupleT).@"struct".field_types;
    return if (idx < fields.len) fields[idx] else void;
}

fn getWitSpreadPyramid(
    comptime ArgsT: type,
    comptime OutRet: type,
    comptime invokeTuple: anytype,
) type {
    return struct {
        pub fn call0() OutRet {
            return invokeTuple(.{});
        }
        pub fn call1(a0: TupleElemType(ArgsT, 0)) OutRet {
            return invokeTuple(.{a0});
        }
        pub fn call2(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1)) OutRet {
            return invokeTuple(.{ a0, a1 });
        }
        pub fn call3(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2)) OutRet {
            return invokeTuple(.{ a0, a1, a2 });
        }
        pub fn call4(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3 });
        }
        pub fn call5(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4 });
        }
        pub fn call6(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5 });
        }
        pub fn call7(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6 });
        }
        pub fn call8(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6), a7: TupleElemType(ArgsT, 7)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6, a7 });
        }
        pub fn call9(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6), a7: TupleElemType(ArgsT, 7), a8: TupleElemType(ArgsT, 8)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8 });
        }
        pub fn call10(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6), a7: TupleElemType(ArgsT, 7), a8: TupleElemType(ArgsT, 8), a9: TupleElemType(ArgsT, 9)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 });
        }
        pub fn call11(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6), a7: TupleElemType(ArgsT, 7), a8: TupleElemType(ArgsT, 8), a9: TupleElemType(ArgsT, 9), a10: TupleElemType(ArgsT, 10)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 });
        }
        pub fn call12(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6), a7: TupleElemType(ArgsT, 7), a8: TupleElemType(ArgsT, 8), a9: TupleElemType(ArgsT, 9), a10: TupleElemType(ArgsT, 10), a11: TupleElemType(ArgsT, 11)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11 });
        }
        pub fn call13(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6), a7: TupleElemType(ArgsT, 7), a8: TupleElemType(ArgsT, 8), a9: TupleElemType(ArgsT, 9), a10: TupleElemType(ArgsT, 10), a11: TupleElemType(ArgsT, 11), a12: TupleElemType(ArgsT, 12)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12 });
        }
        pub fn call14(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6), a7: TupleElemType(ArgsT, 7), a8: TupleElemType(ArgsT, 8), a9: TupleElemType(ArgsT, 9), a10: TupleElemType(ArgsT, 10), a11: TupleElemType(ArgsT, 11), a12: TupleElemType(ArgsT, 12), a13: TupleElemType(ArgsT, 13)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13 });
        }
        pub fn call15(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6), a7: TupleElemType(ArgsT, 7), a8: TupleElemType(ArgsT, 8), a9: TupleElemType(ArgsT, 9), a10: TupleElemType(ArgsT, 10), a11: TupleElemType(ArgsT, 11), a12: TupleElemType(ArgsT, 12), a13: TupleElemType(ArgsT, 13), a14: TupleElemType(ArgsT, 14)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14 });
        }
        pub fn call16(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6), a7: TupleElemType(ArgsT, 7), a8: TupleElemType(ArgsT, 8), a9: TupleElemType(ArgsT, 9), a10: TupleElemType(ArgsT, 10), a11: TupleElemType(ArgsT, 11), a12: TupleElemType(ArgsT, 12), a13: TupleElemType(ArgsT, 13), a14: TupleElemType(ArgsT, 14), a15: TupleElemType(ArgsT, 15)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 });
        }
        pub fn call17(a0: TupleElemType(ArgsT, 0), a1: TupleElemType(ArgsT, 1), a2: TupleElemType(ArgsT, 2), a3: TupleElemType(ArgsT, 3), a4: TupleElemType(ArgsT, 4), a5: TupleElemType(ArgsT, 5), a6: TupleElemType(ArgsT, 6), a7: TupleElemType(ArgsT, 7), a8: TupleElemType(ArgsT, 8), a9: TupleElemType(ArgsT, 9), a10: TupleElemType(ArgsT, 10), a11: TupleElemType(ArgsT, 11), a12: TupleElemType(ArgsT, 12), a13: TupleElemType(ArgsT, 13), a14: TupleElemType(ArgsT, 14), a15: TupleElemType(ArgsT, 15), a16: TupleElemType(ArgsT, 16)) OutRet {
            return invokeTuple(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16 });
        }
    };
}

/// Produce a comptime-generated Zig function with the exact parameter types of
/// `FnT` (`extern struct` records, slices `[]const T`, strings `[]const u8`,
/// handles `Own`/`Borrow`/`Stream`/`Future`) so `zigar-compiler` reflects the
/// exact parameter types and generates zero-copy `DataView`/`TypedArray` views.
///
/// `func` may be either:
///   - A function (or function pointer) with the parameter list of `FnT`, or
///   - A tuple-accepting function `fn (std.meta.ArgsTuple(FnT)) ...`.
///
/// When `unwrap_result` is true and the return type is `Result(Ok, Err)` (or
/// `canon.CanonResult(Result(Ok, Err))`), the returned function has return type
/// `(canon.Error || WitErrorSet)!Ok` so `zigar` automatically translates WIT
/// errors into JS exceptions.
pub fn wrapWitFn(
    comptime FnT: type,
    comptime func: anytype,
    comptime unwrap_result: bool,
) WrappedWitFnType(FnT, @TypeOf(func), unwrap_result) {
    const f = @typeInfo(FnT).@"fn";
    const ArgsT = std.meta.ArgsTuple(FnT);
    const FuncT = @TypeOf(func);
    const ImplFn = FnTypeOfCallable(FuncT);
    const impl_f = @typeInfo(ImplFn).@"fn";
    const ImplRet = canon.ReturnType(ImplFn);
    const OutRet = WrappedWitReturnType(FnT, FuncT, unwrap_result);

    const accepts_tuple = comptime (impl_f.param_types.len == 1 and
        impl_f.param_types[0].? == ArgsT and
        !(f.param_types.len == 1 and f.param_types[0].? == ArgsT));

    const invoker = struct {
        inline fn callRaw(args: ArgsT) ImplRet {
            if (comptime accepts_tuple) {
                return @call(.auto, func, .{args});
            } else {
                return @call(.auto, func, args);
            }
        }

        inline fn invokeTuple(args: ArgsT) OutRet {
            const raw_ret = callRaw(args);
            if (comptime !unwrap_result) {
                return raw_ret;
            }
            if (comptime isWitResult(ImplRet)) {
                return try unwrapWitResult(raw_ret);
            }
            if (comptime @typeInfo(ImplRet) == .error_union) {
                const payload = try raw_ret;
                if (comptime isWitResult(@TypeOf(payload))) {
                    return try unwrapWitResult(payload);
                }
                return payload;
            }
            return raw_ret;
        }
    };

    const pyramid = getWitSpreadPyramid(ArgsT, OutRet, invoker.invokeTuple);
    const caller_name = std.fmt.comptimePrint("call{d}", .{f.param_types.len});
    return @field(pyramid, caller_name);
}

/// Wrap a Canonical ABI lowered call (`canon.CanonLower(FnT, opts).call`) into a
/// first-class Zig function with the exact parameter types of `FnT`.
pub fn wrapLoweredCall(
    comptime FnT: type,
    comptime opts: anytype,
    comptime mem_ctx_ptr: *canon.MemoryContext,
    comptime core_fn: canon.CanonLower(FnT, opts).CoreFnPtr,
    comptime unwrap_result: bool,
) WrappedWitFnType(FnT, fn (std.meta.ArgsTuple(FnT)) canon.CanonResult(canon.ReturnType(FnT)), unwrap_result) {
    const Lower = canon.CanonLower(FnT, opts);
    const TupleRunner = struct {
        fn run(args: std.meta.ArgsTuple(FnT)) canon.CanonResult(canon.ReturnType(FnT)) {
            return Lower.call(mem_ctx_ptr, core_fn, args);
        }
    };
    return wrapWitFn(FnT, TupleRunner.run, unwrap_result);
}

/// Wrap a zero-copy `"zigar:abi"` fast-path call (`fast_abi.FastLower(FnT, is_memory64).call`)
/// into a first-class Zig function with the exact parameter types of `FnT`.
pub fn wrapFastCall(
    comptime FnT: type,
    comptime is_memory64: bool,
    comptime mem_ctx_ptr: *canon.MemoryContext,
    comptime fast_fn: fast_abi.FastCoreFnPtr(is_memory64),
    comptime unwrap_result: bool,
) WrappedWitFnType(FnT, fn (std.meta.ArgsTuple(FnT)) canon.CanonResult(canon.ReturnType(FnT)), unwrap_result) {
    const Fast = fast_abi.FastLower(FnT, is_memory64);
    const TupleRunner = struct {
        fn run(args: std.meta.ArgsTuple(FnT)) canon.CanonResult(canon.ReturnType(FnT)) {
            return Fast.call(mem_ctx_ptr, fast_fn, args);
        }
    };
    return wrapWitFn(FnT, TupleRunner.run, unwrap_result);
}

// ── Dual-ABI Dispatch Bridge (`CallBridge`) ────────────────────────────────

pub const DispatchPath = enum {
    none,
    fast_abi,
    canonical_abi,
};

fn resolveMetaIsMemory64(comptime meta: anytype) bool {
    const T = @TypeOf(meta);
    if (T == bool) return meta;
    if (T == canon.Arch) return meta == .wasm64;
    if (@typeInfo(T) == .enum_literal) return @as(canon.Arch, meta) == .wasm64;
    if (@typeInfo(T) == .@"struct") {
        if (@hasField(T, "is_memory64")) return meta.is_memory64;
        if (@hasField(T, "is_wasm64")) return meta.is_wasm64;
        if (@hasField(T, "arch")) return meta.arch == .wasm64;
    }
    return false;
}

fn resolveMetaCallOptions(comptime meta: anytype) canon.CallOptions {
    const T = @TypeOf(meta);
    if (T == canon.CallOptions) return meta;
    const is_mem64 = resolveMetaIsMemory64(meta);
    var opts = canon.CallOptions{
        .arch = if (is_mem64) .wasm64 else .wasm32,
    };
    if (@typeInfo(T) == .@"struct") {
        if (@hasField(T, "is_async")) opts.is_async = meta.is_async;
        if (@hasField(T, "direction")) opts.direction = meta.direction;
        if (@hasField(T, "string_encoding_utf8")) opts.string_encoding_utf8 = meta.string_encoding_utf8;
    }
    return opts;
}

fn resolveMetaInterfaceName(comptime meta: anytype) []const u8 {
    const T = @TypeOf(meta);
    if (@typeInfo(T) == .@"struct" and @hasField(T, "interface_name")) {
        return meta.interface_name;
    }
    return "";
}

fn resolveMetaFuncName(comptime meta: anytype) []const u8 {
    const T = @TypeOf(meta);
    if (@typeInfo(T) == .@"struct") {
        if (@hasField(T, "wit_name")) return meta.wit_name;
        if (@hasField(T, "func_name")) return meta.func_name;
    }
    return "";
}

/// Dual-ABI call bridge from a Zig host/bridge module into a linked or bound
/// guest export:
///   1. **Fast ABI path (`zigar:abi`)**: when `fast_fn` (`FastCoreFnPtr`) is bound
///      and the target is compatible, invokes `fast_abi.FastLower(FnT, is_memory64)`
///      for single-pointer zero-copy `ArgStruct` transfer (0 `cabi_realloc` calls).
///   2. **Canonical ABI path (`canon.lowerCall`)**: transparently falls back to
///      `canon.CanonLower(FnT, opts).call` (including async subtask suspension
///      when `ctx.await_subtask_fn` is set).
pub fn CallBridge(comptime FnT: type, comptime meta: anytype) type {
    const is_mem64 = comptime resolveMetaIsMemory64(meta);
    const call_opts = comptime resolveMetaCallOptions(meta);
    const iface_name = comptime resolveMetaInterfaceName(meta);
    const fn_name = comptime resolveMetaFuncName(meta);

    return struct {
        const Self = @This();

        pub const FnType = FnT;
        pub const is_memory64: bool = is_mem64;
        pub const options: canon.CallOptions = call_opts;
        pub const interface_name: []const u8 = iface_name;
        pub const func_name: []const u8 = fn_name;

        pub const Lower = canon.CanonLower(FnT, call_opts);
        pub const Lift = canon.CanonLift(FnT, call_opts);
        pub const Fast = fast_abi.FastLower(FnT, is_mem64);

        pub const CoreFnPtr = Lower.CoreFnPtr;
        pub const FastFnPtr = fast_abi.FastCoreFnPtr(is_mem64);
        pub const ArgsTuple = std.meta.ArgsTuple(FnT);
        pub const ReturnT = canon.ReturnType(FnT);
        pub const abi_hash: u64 = Fast.abi_hash;

        canon_fn: ?CoreFnPtr = null,
        fast_fn: ?FastFnPtr = null,
        guest_abi: ?fast_abi.ZigarAbiMetadata = null,
        last_dispatch: DispatchPath = .none,
        fast_call_count: usize = 0,
        canon_call_count: usize = 0,

        pub fn init(canon_fn: ?CoreFnPtr, fast_fn: ?FastFnPtr) Self {
            return .{
                .canon_fn = canon_fn,
                .fast_fn = fast_fn,
            };
        }

        pub fn initWithAbi(
            canon_fn: ?CoreFnPtr,
            fast_fn: ?FastFnPtr,
            guest_abi: ?fast_abi.ZigarAbiMetadata,
        ) Self {
            return .{
                .canon_fn = canon_fn,
                .fast_fn = fast_fn,
                .guest_abi = guest_abi,
            };
        }

        pub fn isFastCompatible(self: Self) bool {
            if (self.fast_fn == null) return false;
            if (self.guest_abi) |abi_meta| {
                if (fn_name.len > 0) {
                    const expected_size: u32 = @intCast(Fast.frame_layout.frame_size);
                    const expected_align: u32 = @intCast(Fast.frame_layout.frame_align);
                    return abi_meta.findCompatibleFuncWithLayout(
                        iface_name,
                        fn_name,
                        abi_hash,
                        expected_size,
                        expected_align,
                        is_mem64,
                    ) != null;
                }
                return abi_meta.isTargetCompatible(is_mem64);
            }
            return (fast_abi.ZigarAbiMetadata{
                .flags = .{ .is_memory64 = is_mem64 },
            }).isTargetCompatible(is_mem64);
        }

        /// Invoke the bridged function on `self`, recording which ABI path
        /// (`.fast_abi` vs `.canonical_abi`) executed the call.
        pub fn invoke(
            self: *Self,
            ctx: *canon.MemoryContext,
            args: ArgsTuple,
        ) canon.CanonResult(ReturnT) {
            if (self.isFastCompatible()) {
                const f_fn = self.fast_fn.?;
                if (self.canon_fn != null) {
                    switch (Fast.tryCallOrFallback(ctx, f_fn, args)) {
                        .completed => |res| {
                            self.last_dispatch = .fast_abi;
                            self.fast_call_count += 1;
                            return res;
                        },
                        .fallback_needed => {},
                    }
                } else {
                    self.last_dispatch = .fast_abi;
                    self.fast_call_count += 1;
                    return Fast.call(ctx, f_fn, args);
                }
            }

            if (self.canon_fn) |c_fn| {
                self.last_dispatch = .canonical_abi;
                self.canon_call_count += 1;
                return Lower.call(ctx, c_fn, args);
            }

            return error.MissingRealloc;
        }

        /// Invoke the bridged function and unwrap any WIT `Result(Ok, Err)` into
        /// a Zig error union `(canon.Error || WitErrorSet)!Ok`.
        pub fn invokeUnwrapped(
            self: *Self,
            ctx: *canon.MemoryContext,
            args: ArgsTuple,
        ) WrappedWitReturnType(FnT, fn (ArgsTuple) canon.CanonResult(ReturnT), true) {
            const res = try self.invoke(ctx, args);
            if (comptime isWitResult(ReturnT)) {
                return try unwrapWitResult(res);
            }
            return res;
        }

        /// Stateless Dual-ABI dispatch helper: uses `fast_fn` when provided and
        /// target-compatible, otherwise falls back to `canon_fn`.
        pub fn call(
            ctx: *canon.MemoryContext,
            fast_fn: ?FastFnPtr,
            canon_fn: CoreFnPtr,
            args: ArgsTuple,
        ) canon.CanonResult(ReturnT) {
            var bridge = Self.init(canon_fn, fast_fn);
            return bridge.invoke(ctx, args);
        }

        /// Stateless Dual-ABI dispatch helper with optional `ZigarAbiMetadata`
        /// verification.
        pub fn callWithAbi(
            ctx: *canon.MemoryContext,
            guest_abi: ?fast_abi.ZigarAbiMetadata,
            fast_fn: ?FastFnPtr,
            canon_fn: CoreFnPtr,
            args: ArgsTuple,
        ) canon.CanonResult(ReturnT) {
            var bridge = Self.initWithAbi(canon_fn, fast_fn, guest_abi);
            return bridge.invoke(ctx, args);
        }

        /// Return a comptime-wrapped Zig function with the exact parameter types
        /// of `FnT` that dispatches via `CallBridge.call(mem_ctx_ptr, fast_fn, canon_fn, args)`.
        pub fn wrap(
            comptime mem_ctx_ptr: *canon.MemoryContext,
            comptime fast_fn: ?FastFnPtr,
            comptime canon_fn: CoreFnPtr,
            comptime unwrap_result: bool,
        ) WrappedWitFnType(FnT, fn (ArgsTuple) canon.CanonResult(ReturnT), unwrap_result) {
            const Runner = struct {
                fn run(args: ArgsTuple) canon.CanonResult(ReturnT) {
                    return Self.call(mem_ctx_ptr, fast_fn, canon_fn, args);
                }
            };
            return wrapWitFn(FnT, Runner.run, unwrap_result);
        }
    };
}

// ── Host / Component Instance Bridge for `zigar` (`HostInstanceBridge`) ────

pub const BridgeOptions = struct {
    unwrap_results: bool = true,
    scratch_capacity: usize = DEFAULT_BRIDGE_CAPACITY,
    is_memory64: bool = false,
    prefer_fast_abi: bool = true,
};

/// Comptime bridge wrapping a `wit-zigar` generated interface/world and a Zig
/// implementation `Impl` into a self-contained namespace for `zigar`.
pub fn HostInstanceBridge(
    comptime InterfaceNamespace: type,
    comptime Impl: type,
    comptime opts: BridgeOptions,
) type {
    return struct {
        const Self = @This();

        pub const Interface = InterfaceNamespace;
        pub const Implementation = Impl;
        pub const options = opts;
        pub const Memory = BridgeMemory(opts.scratch_capacity);

        pub const Exported = if (InterfaceNamespace != void and @hasDecl(InterfaceNamespace, "exportBindings"))
            InterfaceNamespace.exportBindings(Impl)
        else
            void;

        bridge_memory: Memory = Memory.init(),
        allocator: ?std.mem.Allocator = null,
        prefer_fast_abi: bool = opts.prefer_fast_abi,
        last_dispatch: DispatchPath = .none,
        fast_call_count: usize = 0,
        canon_call_count: usize = 0,

        pub fn init(allocator: ?std.mem.Allocator) Self {
            return .{
                .bridge_memory = Memory.init(),
                .allocator = allocator,
                .prefer_fast_abi = opts.prefer_fast_abi,
            };
        }

        pub fn memoryContext(self: *Self) canon.MemoryContext {
            return self.bridge_memory.memoryContext(self.allocator);
        }

        pub fn resetScratch(self: *Self) void {
            self.bridge_memory.resetScratch();
        }

        pub fn FnTypeFor(comptime func_name: []const u8) type {
            const fn_decl_name = func_name ++ "_Fn";
            if (InterfaceNamespace != void and @hasDecl(InterfaceNamespace, fn_decl_name)) {
                return @field(InterfaceNamespace, fn_decl_name);
            }
            return FnTypeOfCallable(@TypeOf(@field(Impl, func_name)));
        }

        pub fn MetaFor(comptime func_name: []const u8) @TypeOf(blk: {
            const meta_decl_name = func_name ++ "_meta";
            if (InterfaceNamespace != void and @hasDecl(InterfaceNamespace, meta_decl_name)) {
                break :blk @field(InterfaceNamespace, meta_decl_name);
            }
            break :blk .{ .is_memory64 = opts.is_memory64 };
        }) {
            const meta_decl_name = func_name ++ "_meta";
            if (InterfaceNamespace != void and @hasDecl(InterfaceNamespace, meta_decl_name)) {
                return @field(InterfaceNamespace, meta_decl_name);
            }
            return .{ .is_memory64 = opts.is_memory64 };
        }

        /// Invoke `func_name` on `Impl` through the Dual-ABI `CallBridge`
        /// (using `FastLower` -> `FastLift` when `self.prefer_fast_abi` is true,
        /// or `CanonLower` -> `CanonLift` when false) and return the raw
        /// `canon.CanonResult(ReturnT)`.
        pub fn callRaw(
            self: *Self,
            comptime func_name: []const u8,
            args: std.meta.ArgsTuple(FnTypeFor(func_name)),
        ) canon.CanonResult(canon.ReturnType(FnTypeFor(func_name))) {
            const FnT = FnTypeFor(func_name);
            const meta = comptime MetaFor(func_name);
            const Bridge = CallBridge(FnT, meta);
            const impl_fn = @field(Impl, func_name);

            var ctx = self.memoryContext();
            const prev_active = canon.getActiveMemoryContext();
            canon.setActiveMemoryContext(ctx);
            defer canon.setActiveMemoryContext(prev_active);

            const canon_thunk = Bridge.Lift.thunk(&impl_fn);
            const fast_thunk: ?Bridge.FastFnPtr = if (self.prefer_fast_abi)
                fast_abi.FastLift(FnT, impl_fn, Bridge.is_memory64).thunk()
            else
                null;

            var cb = Bridge.init(canon_thunk, fast_thunk);
            const res = try cb.invoke(&ctx, args);
            self.bridge_memory.fast_bump_cursor = ctx.fast_bump_cursor;
            self.last_dispatch = cb.last_dispatch;
            self.fast_call_count += cb.fast_call_count;
            self.canon_call_count += cb.canon_call_count;
            return res;
        }

        /// Invoke `func_name` through the Dual-ABI `CallBridge` and unwrap
        /// `Result(Ok, Err)` when `opts.unwrap_results` is true.
        pub fn call(
            self: *Self,
            comptime func_name: []const u8,
            args: std.meta.ArgsTuple(FnTypeFor(func_name)),
        ) WrappedWitReturnType(
            FnTypeFor(func_name),
            fn (std.meta.ArgsTuple(FnTypeFor(func_name))) canon.CanonResult(canon.ReturnType(FnTypeFor(func_name))),
            opts.unwrap_results,
        ) {
            const raw_res = try self.callRaw(func_name, args);
            const RetT = canon.ReturnType(FnTypeFor(func_name));
            if (comptime opts.unwrap_results and isWitResult(RetT)) {
                return try unwrapWitResult(raw_res);
            }
            return raw_res;
        }

        /// Return a comptime-generated Zig function with the exact parameter types
        /// of `FnTypeFor(func_name)` for direct reflection by `zigar-compiler`.
        pub fn wrapFn(
            comptime func_name: []const u8,
        ) WrappedWitFnType(FnTypeFor(func_name), @TypeOf(@field(Impl, func_name)), opts.unwrap_results) {
            const FnT = FnTypeFor(func_name);
            const impl_fn = @field(Impl, func_name);
            return wrapWitFn(FnT, impl_fn, opts.unwrap_results);
        }
    };
}

pub const ZigarBridge = HostInstanceBridge;
pub const exportZigarBindings = HostInstanceBridge;

// ── 4. JSPI / Async Host Import & Promise Helpers (`JspiSuspensionTracker`) ─

/// Tracks concurrent in-flight async calls and continuation stack pointers
/// across WebAssembly JSPI (`WebAssembly.Suspending` / `WebAssembly.promising`)
/// suspensions so Zig modules running under `zigar-runtime` `{ useJSPI: true }`
/// can verify that `Promise.all([...])` calls genuinely interleave on isolated
/// `__stack_pointer` shadow stacks.
pub const JspiSuspensionTracker = struct {
    pub const MAX_SLOTS: usize = 64;

    pub const Error = error{
        TooManyConcurrentCalls,
        InvalidContinuationSlot,
        InvalidSlotState,
        StackCollisionDetected,
    };

    pub const SlotState = enum(u8) {
        free = 0,
        running = 1,
        suspended = 2,
        completed = 3,
    };

    pub const ContinuationSlot = struct {
        id: u32 = 0,
        state: SlotState = .free,
        stack_ptr: usize = 0,
        suspend_count: u32 = 0,
        resume_count: u32 = 0,
        sequence_num: u64 = 0,
    };

    active_count: u32 = 0,
    suspended_count: u32 = 0,
    peak_concurrent_count: u32 = 0,
    total_started_count: u64 = 0,
    total_completed_count: u64 = 0,
    total_suspension_count: u64 = 0,
    total_resumption_count: u64 = 0,
    next_sequence: u64 = 1,
    slots: [MAX_SLOTS]ContinuationSlot = @splat(.{}),

    pub fn init() JspiSuspensionTracker {
        return .{};
    }

    pub fn reset(self: *JspiSuspensionTracker) void {
        self.* = .{};
    }

    /// Begin tracking a new async call using the current frame address as its
    /// stack pointer sample, returning its 1-based continuation slot ID.
    pub noinline fn beginCall(self: *JspiSuspensionTracker) Error!u32 {
        var frame_anchor: usize = 0;
        frame_anchor = @intFromPtr(&frame_anchor);
        return self.beginCallWithStack(frame_anchor);
    }

    /// Begin tracking a new async call with an explicit `__stack_pointer` value,
    /// returning its 1-based continuation slot ID.
    pub fn beginCallWithStack(self: *JspiSuspensionTracker, stack_ptr: usize) Error!u32 {
        for (&self.slots, 0..) |*slot, idx| {
            if (slot.state == .free or slot.state == .completed) {
                const slot_id: u32 = @intCast(idx + 1);
                const seq = self.next_sequence;
                self.next_sequence += 1;
                slot.* = .{
                    .id = slot_id,
                    .state = .running,
                    .stack_ptr = stack_ptr,
                    .suspend_count = 0,
                    .resume_count = 0,
                    .sequence_num = seq,
                };
                self.active_count += 1;
                self.total_started_count += 1;
                if (self.active_count > self.peak_concurrent_count) {
                    self.peak_concurrent_count = self.active_count;
                }
                return slot_id;
            }
        }
        return error.TooManyConcurrentCalls;
    }

    /// Mark continuation `slot_id` as suspended prior to yielding across a
    /// JSPI `WebAssembly.Suspending` host import.
    pub fn suspendCall(self: *JspiSuspensionTracker, slot_id: u32) Error!void {
        const slot = try self.slotMut(slot_id);
        if (slot.state != .running) return error.InvalidSlotState;
        slot.state = .suspended;
        slot.suspend_count += 1;
        self.suspended_count += 1;
        self.total_suspension_count += 1;
    }

    /// Mark continuation `slot_id` as resumed after returning from a JSPI
    /// `WebAssembly.Suspending` host import.
    pub fn resumeCall(self: *JspiSuspensionTracker, slot_id: u32) Error!void {
        const slot = try self.slotMut(slot_id);
        if (slot.state != .suspended) return error.InvalidSlotState;
        slot.state = .running;
        slot.resume_count += 1;
        self.suspended_count -= 1;
        self.total_resumption_count += 1;
    }

    /// Complete continuation `slot_id` when the async export returns.
    pub fn endCall(self: *JspiSuspensionTracker, slot_id: u32) Error!void {
        const slot = try self.slotMut(slot_id);
        switch (slot.state) {
            .running => {},
            .suspended => {
                self.suspended_count -= 1;
            },
            else => return error.InvalidSlotState,
        }
        slot.state = .completed;
        self.active_count -= 1;
        self.total_completed_count += 1;
    }

    /// Inspect a continuation slot by its 1-based `slot_id`.
    pub fn getSlot(self: *const JspiSuspensionTracker, slot_id: u32) ?ContinuationSlot {
        if (slot_id == 0 or slot_id > MAX_SLOTS) return null;
        const slot = self.slots[slot_id - 1];
        if (slot.state == .free) return null;
        return slot;
    }

    /// Returns true if at least two async calls were simultaneously active on
    /// overlapping lifespans (proving concurrent JSPI continuation interleaving).
    pub fn hasInterleavedExecution(self: *const JspiSuspensionTracker) bool {
        return self.peak_concurrent_count > 1;
    }

    /// Verify that all currently active (`running` or `suspended`) continuation
    /// slots with non-zero stack pointers are separated by at least
    /// `min_separation` bytes, confirming isolated shadow stacks.
    pub fn verifyDistinctStacks(self: *const JspiSuspensionTracker, min_separation: usize) bool {
        for (self.slots, 0..) |a, i| {
            if (a.state != .running and a.state != .suspended) continue;
            if (a.stack_ptr == 0) continue;
            for (self.slots[i + 1 ..]) |b| {
                if (b.state != .running and b.state != .suspended) continue;
                if (b.stack_ptr == 0) continue;
                const dist = if (a.stack_ptr >= b.stack_ptr)
                    a.stack_ptr - b.stack_ptr
                else
                    b.stack_ptr - a.stack_ptr;
                if (dist < min_separation) return false;
            }
        }
        return true;
    }

    fn slotMut(self: *JspiSuspensionTracker, slot_id: u32) Error!*ContinuationSlot {
        if (slot_id == 0 or slot_id > MAX_SLOTS) return error.InvalidContinuationSlot;
        const slot = &self.slots[slot_id - 1];
        if (slot.state == .free) return error.InvalidContinuationSlot;
        return slot;
    }
};

// ── Unit Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

const TestPoint = extern struct {
    x: i32,
    y: i32,
};

const TestRect = extern struct {
    origin: TestPoint,
    extent: TestPoint,
    id: u32,
};

const TestErrorKind = enum(u8) {
    invalid_input = 0,
    not_found = 1,
    overflow = 2,
};

test "BridgeMemory: initialization, MemoryContext configuration, realloc, copySliceInPlace, and resetScratch" {
    var bm = BridgeMemory(16384).init();
    try testing.expectEqual(@as(usize, 16384), @TypeOf(bm).linear_capacity);
    try testing.expectEqual(@as(usize, 65536), @TypeOf(bm).scratch_capacity);
    try testing.expectEqual(@as(usize, 16384 + 65536), bm.memorySlice().len);
    try testing.expectEqual(@as(usize, 65536), bm.scratchSlice().len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(bm.memorySlice().ptr) % 16);

    var ctx = bm.memoryContext(testing.allocator);
    try testing.expect(ctx.realloc_fn != null);
    try testing.expect(ctx.task_return_fn != null);
    try testing.expect(ctx.post_return_fn != null);
    try testing.expect(ctx.zero_copy_slices);
    try testing.expectEqual(@as(usize, 16384), ctx.fast_frame_offset);
    try testing.expectEqual(@as(?usize, 16384 + 65536), ctx.fast_scratch_limit);

    // Allocate aligned chunks through `ctx.realloc`
    const ptr1 = try ctx.realloc(8, 128);
    const ptr2 = try ctx.realloc(16, 256);
    try testing.expectEqual(@as(usize, 64), ptr1);
    try testing.expectEqual(@as(usize, 192), ptr2);
    try testing.expectEqual(@as(usize, 2), bm.realloc_count);
    try testing.expect(bm.bump.offset >= 448);

    // Zero-copy in-place slice allocation inside linear memory
    const points_in = [_]TestPoint{
        .{ .x = 15, .y = 25 },
        .{ .x = -30, .y = 40 },
    };
    const in_place_pts = try bm.copySliceInPlace(TestPoint, &points_in);
    try testing.expectEqual(@as(usize, 2), in_place_pts.len);
    try testing.expectEqual(points_in[0], in_place_pts[0]);
    try testing.expectEqual(points_in[1], in_place_pts[1]);
    // Verify `in_place_pts` points directly inside `bm.memorySlice()`
    const mem_start = @intFromPtr(bm.memorySlice().ptr);
    const mem_end = mem_start + bm.memorySlice().len;
    try testing.expect(@intFromPtr(in_place_pts.ptr) >= mem_start and @intFromPtr(in_place_pts.ptr) < mem_end);

    // Exercise `task_return_fn` and `post_return_fn`
    ctx.task_return_fn.?(ctx.task_return_ctx, 320);
    ctx.post_return_fn.?(ctx.post_return_ctx, 512);
    try testing.expectEqual(@as(?usize, 320), bm.last_task_return_ptr);
    try testing.expectEqual(@as(usize, 1), bm.task_return_count);
    try testing.expectEqual(@as(?usize, 512), bm.last_post_return_ptr);
    try testing.expectEqual(@as(usize, 1), bm.post_return_count);

    // Simulate advancing fast_bump_cursor and then resetScratch
    bm.fast_bump_cursor = bm.fast_frame_offset + 1024;
    ctx.fast_bump_cursor = bm.fast_bump_cursor;
    bm.resetContextScratch(&ctx);
    try testing.expectEqual(@as(usize, 64), bm.bump.offset);
    try testing.expectEqual(bm.fast_frame_offset, bm.fast_bump_cursor);
    try testing.expectEqual(bm.fast_frame_offset, ctx.fast_bump_cursor);
    try testing.expectEqual(@as(?usize, null), bm.last_task_return_ptr);

    // Verify attaching an external memory slice
    var ext_buf: [8192]u8 align(16) = @splat(0);
    var ext_bm = try BridgeMemory(4096).initExternal(&ext_buf, 0x1000);
    var ext_ctx = ext_bm.memoryContext(null);
    const ext_ptr = try ext_ctx.realloc(8, 64);
    try testing.expectEqual(@as(usize, 0x1000 + 64), ext_ptr);
}

test "WIT Result(Ok, Err) conversion: isWitResult, unwrapWitResult, and wrapWitResult" {
    const ResU32Str = canon.Result(u32, []const u8);
    const ResVoidU32 = canon.Result(void, u32);
    const ResPointVoid = canon.Result(TestPoint, void);

    try testing.expect(isWitResult(ResU32Str));
    try testing.expect(isWitResult(ResVoidU32));
    try testing.expect(isWitResult(ResPointVoid));
    try testing.expect(!isWitResult(TestPoint));
    try testing.expect(!isWitResult(u32));
    try testing.expect(!isWitResult(union(enum) { a: u32, b: f32 }));

    // 1. Result(u32, []const u8)
    {
        clearLastWitError([]const u8);
        const ok_res = ResU32Str{ .ok = 42 };
        const val = try unwrapWitResult(ok_res);
        try testing.expectEqual(@as(u32, 42), val);
        const rewrapped_ok = wrapWitResult(ResU32Str, unwrapWitResult(ok_res));
        try testing.expect(rewrapped_ok == .ok);
        try testing.expectEqual(@as(u32, 42), rewrapped_ok.ok);

        const err_res = ResU32Str{ .err = "permission denied" };
        const unwrapped_err = unwrapWitResult(err_res);
        try testing.expectError(error.WitResultError, unwrapped_err);
        try testing.expectEqualStrings("permission denied", getLastWitError([]const u8).?);

        const rewrapped_err = wrapWitResult(ResU32Str, unwrapped_err);
        try testing.expect(rewrapped_err == .err);
        try testing.expectEqualStrings("permission denied", rewrapped_err.err);
        // Stored error was cleared upon consumption by wrapWitResult
        try testing.expectEqual(@as(?[]const u8, null), getLastWitError([]const u8));

        // Stale stored error is cleared on unwrapWitResult(.ok) and ignored on non-WitResultError ABI errors
        setLastWitError([]const u8, "stale error");
        _ = try unwrapWitResult(ok_res);
        try testing.expectEqual(@as(?[]const u8, null), getLastWitError([]const u8));

        setLastWitError([]const u8, "stale error 2");
        const abi_err: BridgeError!u32 = error.OutOfBounds;
        const wrapped_abi_err = wrapWitResult(ResU32Str, abi_err);
        try testing.expect(wrapped_abi_err == .err);
        try testing.expectEqualStrings("OutOfBounds", wrapped_abi_err.err);
        clearLastWitError([]const u8);
    }

    // 2. Result(void, u32)
    {
        clearLastWitError(u32);
        const ok_void = ResVoidU32{ .ok = {} };
        try unwrapWitResult(ok_void);
        const rewrapped_ok = wrapWitResult(ResVoidU32, unwrapWitResult(ok_void));
        try testing.expect(rewrapped_ok == .ok);

        const err_u32 = ResVoidU32{ .err = 503 };
        const unwrapped_err = unwrapWitResult(err_u32);
        try testing.expectError(error.WitResultError, unwrapped_err);
        try testing.expectEqual(@as(?u32, 503), getLastWitError(u32));

        const rewrapped_err = wrapWitResult(ResVoidU32, unwrapped_err);
        try testing.expect(rewrapped_err == .err);
        try testing.expectEqual(@as(u32, 503), rewrapped_err.err);
    }

    // 3. Result(Point, void)
    {
        const pt = TestPoint{ .x = 95, .y = -125 };
        const ok_pt = ResPointVoid{ .ok = pt };
        const unwrapped_pt = try unwrapWitResult(ok_pt);
        try testing.expectEqual(pt, unwrapped_pt);

        const rewrapped_pt = wrapWitResult(ResPointVoid, unwrapped_pt);
        try testing.expect(rewrapped_pt == .ok);
        try testing.expectEqual(pt, rewrapped_pt.ok);

        const err_void = ResPointVoid{ .err = {} };
        const unwrapped_err = unwrapWitResult(err_void);
        try testing.expectError(error.WitResultError, unwrapped_err);

        const rewrapped_err = wrapWitResult(ResPointVoid, unwrapped_err);
        try testing.expect(rewrapped_err == .err);
    }
}

test "wrapWitFn, CallBridge, and HostInstanceBridge dual-ABI dispatch (zigar:abi fast path vs Canonical ABI fallback)" {
    const alloc = testing.allocator;

    const TransformRectFn = fn (TestRect, i32) TestRect;
    const SummarizeRectsFn = fn ([]const u8, []const TestRect) canon.Result(TestPoint, TestErrorKind);
    const HandleTransferFn = fn (canon.Own(u32), canon.Borrow(u32), canon.Stream(u8), canon.Future(u32)) canon.Own(u32);

    const MockInterface = struct {
        pub const transform_rect_Fn = TransformRectFn;
        pub const transform_rect_meta = .{
            .wit_name = "transform-rect",
            .interface_name = "zigar:test/geometry@0.1.0",
            .is_async = false,
            .string_encoding_utf8 = false,
        };

        pub const summarize_rects_Fn = SummarizeRectsFn;
        pub const summarize_rects_meta = .{
            .wit_name = "summarize-rects",
            .interface_name = "zigar:test/geometry@0.1.0",
            .is_async = false,
            .string_encoding_utf8 = true,
        };

        pub const transfer_handles_Fn = HandleTransferFn;
        pub const transfer_handles_meta = .{
            .wit_name = "transfer-handles",
            .interface_name = "zigar:test/geometry@0.1.0",
            .is_async = false,
            .string_encoding_utf8 = false,
        };
    };

    const GuestImpl = struct {
        pub fn transform_rect(r: TestRect, scale: i32) TestRect {
            return .{
                .origin = .{ .x = r.origin.x * scale, .y = r.origin.y * scale },
                .extent = .{ .x = r.extent.x * scale, .y = r.extent.y * scale },
                .id = r.id + 1,
            };
        }

        pub fn summarize_rects(tag: []const u8, rects: []const TestRect) canon.Result(TestPoint, TestErrorKind) {
            if (rects.len == 0 or tag.len == 0) {
                return .{ .err = .invalid_input };
            }
            var sum_x: i32 = 0;
            var sum_y: i32 = 0;
            for (rects) |r| {
                sum_x += r.origin.x + r.extent.x;
                sum_y += r.origin.y + r.extent.y;
            }
            return .{
                .ok = .{
                    .x = sum_x + @as(i32, @intCast(tag.len)),
                    .y = sum_y,
                },
            };
        }

        pub fn transfer_handles(
            own_h: canon.Own(u32),
            bor_h: canon.Borrow(u32),
            stream_h: canon.Stream(u8),
            fut_h: canon.Future(u32),
        ) canon.Own(u32) {
            return .{ .handle = own_h.handle + bor_h.handle + stream_h.handle + fut_h.handle };
        }
    };

    // 1. Verify `wrapWitFn` preserves exact parameter types for `zigar-compiler` reflection
    const wrapped_summarize = comptime wrapWitFn(SummarizeRectsFn, GuestImpl.summarize_rects, true);
    const WrappedFnT = @TypeOf(wrapped_summarize);
    const fn_info = @typeInfo(WrappedFnT).@"fn";
    try testing.expectEqual(@as(usize, 2), fn_info.param_types.len);
    try testing.expectEqual([]const u8, fn_info.param_types[0].?);
    try testing.expectEqual([]const TestRect, fn_info.param_types[1].?);
    try testing.expectEqual(BridgeError!TestPoint, fn_info.return_type.?);

    const wrapped_handles = comptime wrapWitFn(HandleTransferFn, GuestImpl.transfer_handles, true);
    const h_res = wrapped_handles(.{ .handle = 1 }, .{ .handle = 2 }, .{ .handle = 3 }, .{ .handle = 4 });
    try testing.expectEqual(@as(i32, 10), h_res.handle);

    // 2. Verify `CallBridge` dual-ABI dispatch on `SummarizeRectsFn` (blittable `extern struct` slices + strings + Result)
    var bm = BridgeMemory(16384).init();
    var ctx = bm.memoryContext(alloc);
    canon.setActiveMemoryContext(ctx);
    defer canon.setActiveMemoryContext(null);

    const rects_data = [_]TestRect{
        .{
            .origin = .{ .x = 1, .y = 2 },
            .extent = .{ .x = 3, .y = 4 },
            .id = 10,
        },
        .{
            .origin = .{ .x = 5, .y = 6 },
            .extent = .{ .x = 7, .y = 8 },
            .id = 20,
        },
    };
    // Place `rects_data` directly into `BridgeMemory` to exercise in-place zero-copy slice passing
    const zero_copy_rects = try bm.copySliceInPlace(TestRect, &rects_data);
    const reallocs_after_setup = bm.realloc_count;

    const SummarizeBridge = CallBridge(SummarizeRectsFn, MockInterface.summarize_rects_meta);
    const canon_thunk = SummarizeBridge.Lift.thunk(&GuestImpl.summarize_rects);
    const fast_thunk = fast_abi.FastLift(SummarizeRectsFn, GuestImpl.summarize_rects, false).thunk();

    // (a) Fast ABI path (`fast_fn` provided): 0 `cabi_realloc` calls!
    var fast_bridge = SummarizeBridge.init(canon_thunk, fast_thunk);
    const fast_pt = try fast_bridge.invokeUnwrapped(&ctx, .{ " tag ", zero_copy_rects });
    try testing.expectEqual(DispatchPath.fast_abi, fast_bridge.last_dispatch);
    try testing.expectEqual(@as(usize, 1), fast_bridge.fast_call_count);
    try testing.expectEqual(@as(usize, 0), fast_bridge.canon_call_count);
    try testing.expectEqual(reallocs_after_setup, bm.realloc_count);
    try testing.expectEqual(TestPoint{ .x = 21, .y = 20 }, fast_pt);

    // (b) Canonical ABI fallback path (`fast_fn == null`): identical result!
    var canon_bridge = SummarizeBridge.init(canon_thunk, null);
    const canon_pt = try canon_bridge.invokeUnwrapped(&ctx, .{ " tag ", zero_copy_rects });
    try testing.expectEqual(DispatchPath.canonical_abi, canon_bridge.last_dispatch);
    try testing.expectEqual(@as(usize, 0), canon_bridge.fast_call_count);
    try testing.expectEqual(@as(usize, 1), canon_bridge.canon_call_count);
    try testing.expect(bm.realloc_count > reallocs_after_setup);
    try testing.expectEqual(fast_pt, canon_pt);

    // (c) Error result through both Fast ABI and Canonical ABI translates to `error.WitResultError`
    try testing.expectError(
        error.WitResultError,
        fast_bridge.invokeUnwrapped(&ctx, .{ "", zero_copy_rects }),
    );
    try testing.expectEqual(TestErrorKind.invalid_input, getLastWitError(TestErrorKind).?);

    try testing.expectError(
        error.WitResultError,
        canon_bridge.invokeUnwrapped(&ctx, .{ "", zero_copy_rects }),
    );
    try testing.expectEqual(TestErrorKind.invalid_input, getLastWitError(TestErrorKind).?);

    // 3. Verify `HostInstanceBridge` (`ZigarBridge`) with fast vs canonical toggle
    const InstanceBridge = HostInstanceBridge(MockInterface, GuestImpl, .{
        .unwrap_results = true,
        .scratch_capacity = 16384,
        .prefer_fast_abi = true,
    });
    var inst = InstanceBridge.init(alloc);

    const r_in = TestRect{
        .origin = .{ .x = 2, .y = 3 },
        .extent = .{ .x = 4, .y = 5 },
        .id = 77,
    };
    const r_fast = try inst.call("transform_rect", .{ r_in, 3 });
    try testing.expectEqual(DispatchPath.fast_abi, inst.last_dispatch);
    try testing.expectEqual(@as(usize, 1), inst.fast_call_count);

    inst.prefer_fast_abi = false;
    const r_canon = try inst.call("transform_rect", .{ r_in, 3 });
    try testing.expectEqual(DispatchPath.canonical_abi, inst.last_dispatch);
    try testing.expectEqual(@as(usize, 1), inst.canon_call_count);
    try testing.expectEqual(r_fast, r_canon);
    try testing.expectEqual(@as(i32, 6), r_canon.origin.x);
    try testing.expectEqual(@as(u32, 78), r_canon.id);
}

test "JspiSuspensionTracker: simulated concurrent Promise.all interleaving on separate continuation stacks" {
    var tracker = JspiSuspensionTracker.init();
    try testing.expect(!tracker.hasInterleavedExecution());

    // Simulate 3 concurrent JSPI calls (`Promise.all([callA, callB, callC])`)
    // each running on its own 64 KiB shadow stack (`__stack_pointer`).
    const stack_base_a: usize = 0x10_0000;
    const stack_base_b: usize = 0x11_0000;
    const stack_base_c: usize = 0x12_0000;

    // Call A starts on stack A and suspends at an async JS host import
    const slot_a = try tracker.beginCallWithStack(stack_base_a - 128);
    try testing.expectEqual(@as(u32, 1), slot_a);
    try testing.expectEqual(@as(u32, 1), tracker.active_count);
    try tracker.suspendCall(slot_a);
    try testing.expectEqual(@as(u32, 1), tracker.suspended_count);

    // While A is suspended, Call B starts on stack B and also suspends
    const slot_b = try tracker.beginCallWithStack(stack_base_b - 256);
    try testing.expectEqual(@as(u32, 2), slot_b);
    try testing.expectEqual(@as(u32, 2), tracker.active_count);
    try testing.expect(tracker.hasInterleavedExecution());
    try tracker.suspendCall(slot_b);
    try testing.expectEqual(@as(u32, 2), tracker.suspended_count);

    // While A and B are suspended, Call C starts on stack C and suspends
    const slot_c = try tracker.beginCallWithStack(stack_base_c - 64);
    try testing.expectEqual(@as(u32, 3), slot_c);
    try testing.expectEqual(@as(u32, 3), tracker.active_count);
    try testing.expectEqual(@as(u32, 3), tracker.peak_concurrent_count);
    try tracker.suspendCall(slot_c);

    // Verify all 3 active continuations occupy distinct 64 KiB shadow stacks
    try testing.expect(tracker.verifyDistinctStacks(32768));
    try testing.expect(!tracker.verifyDistinctStacks(256 * 1024));

    // Out-of-order resumption: B resolves first, resumes, and completes
    try tracker.resumeCall(slot_b);
    try testing.expectEqual(@as(u32, 2), tracker.suspended_count);
    try tracker.endCall(slot_b);
    try testing.expectEqual(@as(u32, 2), tracker.active_count);
    try testing.expectEqual(@as(u64, 1), tracker.total_completed_count);

    // Next A resolves, resumes, suspends a second time, resumes, and completes
    try tracker.resumeCall(slot_a);
    try tracker.suspendCall(slot_a);
    try tracker.resumeCall(slot_a);
    const info_a = tracker.getSlot(slot_a).?;
    try testing.expectEqual(@as(u32, 2), info_a.suspend_count);
    try testing.expectEqual(@as(u32, 2), info_a.resume_count);
    try tracker.endCall(slot_a);

    // Finally C resolves, resumes, and completes
    try tracker.resumeCall(slot_c);
    try tracker.endCall(slot_c);

    try testing.expectEqual(@as(u32, 0), tracker.active_count);
    try testing.expectEqual(@as(u32, 0), tracker.suspended_count);
    try testing.expectEqual(@as(u32, 3), tracker.peak_concurrent_count);
    try testing.expectEqual(@as(u64, 3), tracker.total_started_count);
    try testing.expectEqual(@as(u64, 3), tracker.total_completed_count);
    try testing.expectEqual(@as(u64, 4), tracker.total_suspension_count);
    try testing.expectEqual(@as(u64, 4), tracker.total_resumption_count);
    try testing.expect(tracker.hasInterleavedExecution());
}

test "wrapLoweredCall, wrapFastCall, and CallBridge ZigarAbiMetadata verification" {
    const ComputeFn = fn ([]const u8, i32) canon.Result(i32, TestErrorKind);
    const compute_meta = .{
        .wit_name = "compute",
        .interface_name = "zigar:test/math@0.1.0",
        .is_async = false,
        .string_encoding_utf8 = true,
    };

    const Handlers = struct {
        var static_bm: BridgeMemory(8192) = BridgeMemory(8192).init();
        var static_ctx: canon.MemoryContext = undefined;

        fn compute(prefix: []const u8, delta: i32) canon.Result(i32, TestErrorKind) {
            if (prefix.len == 0) return .{ .err = .invalid_input };
            return .{ .ok = @as(i32, @intCast(prefix.len)) * 10 + delta };
        }
    };

    Handlers.static_ctx = Handlers.static_bm.memoryContext(testing.allocator);
    canon.setActiveMemoryContext(Handlers.static_ctx);
    defer canon.setActiveMemoryContext(null);

    const Bridge = CallBridge(ComputeFn, compute_meta);
    const canon_thunk = comptime Bridge.Lift.thunk(&Handlers.compute);
    const fast_thunk = comptime fast_abi.FastLift(ComputeFn, Handlers.compute, false).thunk();

    // 1. `wrapFastCall` and `wrapLoweredCall` produce first-class Zig functions
    const fast_fn = comptime wrapFastCall(ComputeFn, false, &Handlers.static_ctx, fast_thunk, true);
    const lowered_fn = comptime wrapLoweredCall(ComputeFn, compute_meta, &Handlers.static_ctx, canon_thunk, true);

    const reallocs_before = Handlers.static_bm.realloc_count;
    try testing.expectEqual(@as(i32, 47), try fast_fn("abcd", 7));
    try testing.expectEqual(reallocs_before, Handlers.static_bm.realloc_count);

    try testing.expectEqual(@as(i32, 47), try lowered_fn("abcd", 7));
    try testing.expect(Handlers.static_bm.realloc_count > reallocs_before);

    // 2. `CallBridge.initWithAbi`: matching `ZigarAbiMetadata` uses `.fast_abi`,
    //    mismatched `abi_hash` transparently falls back to `.canonical_abi`.
    const valid_entries = [_]fast_abi.ZigarFuncEntry{.{
        .interface_name = "zigar:test/math@0.1.0",
        .func_name = "compute",
        .fast_export_name = "__zigar_fast_zigar:test/math@0.1.0#compute",
        .abi_hash = Bridge.abi_hash,
        .arg_struct_size = @intCast(Bridge.Fast.frame_layout.frame_size),
        .arg_struct_align = @intCast(Bridge.Fast.frame_layout.frame_align),
        .flags = Bridge.Fast.frame_layout.flags,
    }};
    const valid_abi = fast_abi.ZigarAbiMetadata{ .entries = &valid_entries };
    var verified_bridge = Bridge.initWithAbi(canon_thunk, fast_thunk, valid_abi);
    const v_ok = try verified_bridge.invokeUnwrapped(&Handlers.static_ctx, .{ "xyz", 5 });
    try testing.expectEqual(@as(i32, 35), v_ok);
    try testing.expectEqual(DispatchPath.fast_abi, verified_bridge.last_dispatch);

    const mismatch_entries = [_]fast_abi.ZigarFuncEntry{.{
        .interface_name = "zigar:test/math@0.1.0",
        .func_name = "compute",
        .fast_export_name = "__zigar_fast_zigar:test/math@0.1.0#compute",
        .abi_hash = Bridge.abi_hash ^ 0xff,
        .arg_struct_size = @intCast(Bridge.Fast.frame_layout.frame_size),
        .arg_struct_align = @intCast(Bridge.Fast.frame_layout.frame_align),
        .flags = Bridge.Fast.frame_layout.flags,
    }};
    const mismatch_abi = fast_abi.ZigarAbiMetadata{ .entries = &mismatch_entries };
    var fallback_bridge = Bridge.initWithAbi(canon_thunk, fast_thunk, mismatch_abi);
    const fb_ok = try fallback_bridge.invokeUnwrapped(&Handlers.static_ctx, .{ "xyz", 5 });
    try testing.expectEqual(@as(i32, 35), fb_ok);
    try testing.expectEqual(DispatchPath.canonical_abi, fallback_bridge.last_dispatch);
}

