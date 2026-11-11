const std = @import("std");
const builtin = @import("builtin");

var threaded_io = std.Io.Threaded.init_single_threaded;

const use_async_futex = builtin.target.cpu.arch.isWasm() and !builtin.single_threaded;

const wasm_mt_io = struct {
    extern "env" fn _futexWaitAsync(ptr: *const u32, expected: u32, timeout_ns: i64) std.os.wasi.errno_t;

    const base_vtable = init: {
        var tmp = std.Io.Threaded.init_single_threaded;
        break :init tmp.io().vtable.*;
    };

    const vtable: std.Io.VTable = init: {
        var vt = base_vtable;
        vt.futexWait = futexWait;
        vt.futexWaitUncancelable = futexWaitUncancelable;
        break :init vt;
    };

    fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        if (std.Thread.getCurrentId() == 0) {
            const t: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
            const base_io = t.io();
            try base_io.vtable.checkCancel(userdata);
            if (@atomicLoad(u32, ptr, .acquire) != expected) return;
            const timeout_ns: i64 = ns: {
                const d = timeout.toDurationFromNow(base_io) orelse break :ns -1;
                break :ns std.math.lossyCast(i64, @max(0, d.raw.toNanoseconds()));
            };
            switch (_futexWaitAsync(ptr, expected, timeout_ns)) {
                .SUCCESS, .TIMEDOUT => {
                    try base_io.vtable.checkCancel(userdata);
                    return;
                },
                else => {},
            }
        }
        return base_vtable.futexWait(userdata, ptr, expected, timeout);
    }

    fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
        if (std.Thread.getCurrentId() == 0) {
            if (@atomicLoad(u32, ptr, .acquire) != expected) return;
            switch (_futexWaitAsync(ptr, expected, -1)) {
                .SUCCESS, .TIMEDOUT => return,
                else => {},
            }
        }
        base_vtable.futexWaitUncancelable(userdata, ptr, expected);
    }
};

pub const io: std.Io = if (use_async_futex) .{
    .userdata = &threaded_io,
    .vtable = &wasm_mt_io.vtable,
} else threaded_io.io();
