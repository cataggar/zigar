const std = @import("std");
const zigar = @import("zigar");

const js = zigar.js;
const Ref = js.Ref;

pub const HostError = error{
    ValidationFailed,
    JsException,
    OutOfMemory,
    OffJsThread,
    Unsupported,
};

const VirtualToolkit = js.Module("virtual:toolkit");

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn activeCallbacks() u32 {
    return js.activeCallbackCount();
}

pub fn callVirtualModuleStaticAndDynamic(alloc: std.mem.Allocator, a: i32, b: i32) ![]const u8 {
    // 1. Static comptime module descriptor (`js.Module`)
    const has_combine = try VirtualToolkit.has("combine");
    if (!has_combine) return error.JsException;
    const label = try VirtualToolkit.getAlloc(alloc, []const u8, "label");
    defer alloc.free(label);
    const sum = try VirtualToolkit.call(fn (i32, i32) i32, "combine", .{ a, b });

    // 2. Dynamic `importModuleDynamic` hitting cached module map
    const dyn_mod = try js.importModuleDynamic("virtual:toolkit");
    defer dyn_mod.deinit();
    const version = dyn_mod.get(i32, "version");

    return std.fmt.allocPrint(alloc, "{s}:{d}@v{d}", .{ label, sum, version });
}

pub fn testGlobalAndPropOps(target: Ref(js.Object), sym: Ref(js.Symbol), rounds: u32) i32 {
    defer target.deinit();
    defer sym.deinit();
    const math = js.getGlobal(Ref(js.Object), "Math");
    defer math.deinit();
    const abs_val = math.call(fn (i32) i32, "abs", .{-15});

    var acc: i32 = abs_val;
    var i: u32 = 0;
    while (i < rounds) : (i += 1) {
        target.set("counter", @as(i32, @intCast(i)) + 10);
        if (target.has("counter")) {
            acc += target.get(i32, "counter");
        }
    }

    // Dynamic string key ops
    js.setPropDynamic(target, "dynKey", @as(i32, 42));
    if (js.hasPropDynamic(target, "dynKey")) {
        acc += js.getPropDynamic(i32, target, "dynKey");
    }
    _ = js.deletePropDynamic(target, "dynKey");
    if (js.hasPropDynamic(target, "dynKey")) {
        acc -= 9999;
    }

    // Static delete_prop
    _ = target.delete("counter");
    if (target.has("counter")) {
        acc -= 9999;
    }

    // Symbol-keyed property & method ops
    target.setSym(sym, @as(i32, 77));
    acc += target.getSym(i32, sym);

    return acc;
}

pub fn testCallFnMethodAndConstruct(
    alloc: std.mem.Allocator,
    standalone_fn: Ref(js.Function),
    ctor: Ref(js.Function),
    initial: i32,
) ![]const u8 {
    defer standalone_fn.deinit();
    defer ctor.deinit();
    // Standalone function call
    const base = standalone_fn.invoke(fn (i32, i32) i32, .{ initial, 5 });

    // Construct (`new Ctor(base)`) + instanceof check + `this`-bound method call
    const inst = ctor.new(fn (i32) Ref(js.Object), .{base});
    defer inst.deinit();

    if (!inst.instanceof(ctor)) {
        return error.JsException;
    }

    const after_add = inst.call(fn (i32) i32, "increment", .{7});
    const summary = try inst.call(fn (std.mem.Allocator, []const u8) HostError![]const u8, "describe", .{ alloc, "ok" });
    defer alloc.free(summary);

    // Optional return: missing property -> null (`undefined` normalized to `null`)
    const maybe_missing = inst.get(?i32, "nonExistentProp");
    if (maybe_missing != null) {
        return error.JsException;
    }

    return std.fmt.allocPrint(alloc, "{s}:{d}", .{ summary, after_add });
}

pub fn testFallibleHostOps(target: Ref(js.Object), bad_ctor: Ref(js.Function), bad_fn: Ref(js.Function)) u32 {
    defer target.deinit();
    defer bad_ctor.deinit();
    defer bad_fn.deinit();
    var mask: u32 = 0;

    // 1. Named error mapped to HostError.ValidationFailed inside call_method
    if (target.call(fn (i32) HostError!Ref(js.Object), "validate", .{-1})) |r| {
        r.deinit();
    } else |err| {
        if (err == error.ValidationFailed) mask |= 1 << 0;
    }

    // 2. Arbitrary JS Error mapped to HostError.JsException inside call_fn
    if (bad_fn.invoke(fn (i32) HostError!Ref(js.Object), .{1})) |r| {
        r.deinit();
    } else |err| {
        if (err == error.JsException) mask |= 1 << 1;
    }

    // 3. Calling a non-function property via call_method cleanly returns error.JsException
    if (target.call(fn () HostError!i32, "notAFunction", .{})) |_| {} else |err| {
        if (err == error.JsException) mask |= 1 << 2;
    }

    // 4. Throwing constructor on E!Ref(Object) returns error without leaking handles
    if (bad_ctor.new(fn (i32) HostError!Ref(js.Object), .{99})) |r| {
        r.deinit();
    } else |err| {
        if (err == error.JsException) mask |= 1 << 3;
    }

    // 5. Throwing getter on E!i32
    if (target.get(HostError!i32, "throwingProp")) |_| {} else |err| {
        if (err == error.JsException) mask |= 1 << 4;
    }

    // 6. Throwing setter via trySetProp (maps JS TypeError -> error.TypeError in CallError)
    if (js.trySetProp(target, "readOnlyProp", @as(i32, 123))) |_| {} else |err| {
        if (err == error.TypeError) mask |= 1 << 5;
    }

    return mask;
}

fn DistinctPayload(comptime idx: usize) type {
    return extern struct {
        tag: u32 = @intCast(idx),
        value: i32,
    };
}

// Stress >64 (80) distinct generated ArgStruct host-op signatures in a single module!
pub fn stress80DistinctHostSignatures(
    standalone_fn: Ref(js.Function),
    helper_obj: Ref(js.Object),
    box_ctor: Ref(js.Function),
) !i64 {
    defer standalone_fn.deinit();
    defer helper_obj.deinit();
    defer box_ctor.deinit();
    var total: i64 = 0;
    inline for (0..80) |i| {
        const P = DistinctPayload(i);
        const input: P = .{ .tag = @intCast(i), .value = @intCast(i * 3 + 1) };
        switch (i % 5) {
            0 => {
                // Distinct call_fn signature
                const v = js.callFn(fn (P) i32, standalone_fn, .{input});
                total += v;
            },
            1 => {
                // Distinct call_method signature
                const v = helper_obj.call(fn (P, i32) i32, "evalPayload", .{ input, @as(i32, @intCast(i)) });
                total += v;
            },
            2 => {
                // Distinct set_prop + get_prop signatures
                const prop_name = std.fmt.comptimePrint("slot_{d}", .{i});
                helper_obj.set(prop_name, input);
                const roundtrip = helper_obj.get(P, prop_name);
                _ = helper_obj.delete(prop_name);
                total += @as(i64, roundtrip.value) + @as(i64, roundtrip.tag);
            },
            3 => {
                // Distinct construct signature
                const boxed = box_ctor.new(fn (P) Ref(js.Object), .{input});
                defer boxed.deinit();
                total += boxed.get(i32, "computed");
            },
            4 => {
                // Distinct fallible method returning HostError!P
                const out = try helper_obj.call(fn (u32, i32) HostError!P, "makePayload", .{
                    @as(u32, @intCast(i)),
                    @as(i32, @intCast(i + 10)),
                });
                total += @as(i64, out.value) + @as(i64, out.tag);
            },
            else => unreachable,
        }
    }
    return total;
}

const ListenerState = struct {
    id: u32,
    multiplier: i32,
    calls: u32 = 0,
    accum: i64 = 0,

    fn handle(self: *ListenerState, x: i32) i32 {
        self.calls += 1;
        const delta = @as(i32, @intCast(self.id)) * 100 + x * self.multiplier;
        self.accum += delta;
        return delta;
    }
};

const ListenerCallback = js.Callback(fn (i32) i32);
const callback_count = 64;

var states: [callback_count]ListenerState = undefined;
var callbacks: [callback_count]ListenerCallback = @splat(.{});

pub fn register64StatefulCallbacks(bus: Ref(js.Object)) void {
    defer bus.deinit();
    for (0..callback_count) |i| {
        states[i] = .{
            .id = @intCast(i + 1),
            .multiplier = @intCast(i + 2),
        };
        callbacks[i] = ListenerCallback.init(&states[i], ListenerState.handle);
        bus.call(fn (u32, Ref(js.Function)) void, "register", .{
            @as(u32, @intCast(i)),
            callbacks[i].toRef(),
        });
    }
}

pub fn triggerBusFromZig(bus: Ref(js.Object), input: i32) i64 {
    defer bus.deinit();
    return bus.call(fn (i32) i64, "emitAll", .{input});
}

pub fn inspectCallbackTotalCalls() u32 {
    var sum: u32 = 0;
    for (&states) |*s| {
        sum += s.calls;
    }
    return sum;
}

pub fn inspectCallbackTotalAccum() i64 {
    var sum: i64 = 0;
    for (&states) |*s| {
        sum += s.accum;
    }
    return sum;
}

pub fn release64StatefulCallbacks() void {
    for (&callbacks) |*cb| {
        cb.deinit();
    }
}
