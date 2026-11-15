const std = @import("std");
const zigar = @import("zigar");

const js = zigar.js;
const Ref = js.Ref;

comptime {
    std.debug.assert(@sizeOf(Ref(js.Any)) == 4);
    std.debug.assert(@alignOf(Ref(js.Any)) == 4);
    std.debug.assert(@sizeOf(Ref(js.Object)) == 4);
    std.debug.assert(@alignOf(Ref(js.Object)) == 4);
}

pub const Pair = extern struct {
    first: Ref(js.Any),
    second: Ref(js.Any),
};

pub const TaggedValue = union(enum) {
    js: Ref(js.Any),
    code: i32,
};

pub const Error = error{
    Rejected,
};

pub const CallbackError = error{
    Rejected,
    Unexpected,
};

pub const RefWithUint = extern struct {
    ref: Ref(js.Any),
    num: u32,
};

pub const Mixed = extern struct {
    ref: Ref(js.Any),
    num: u32,
};

pub const RefSlice = []Ref(js.Any);

pub const TaggedWrapper = struct {
    t: TaggedValue = .{ .code = 0 },
    n: u32,
};

pub const OuterUnion = union(enum) {
    nested: TaggedValue,
    plain: u32,
};

pub var exported_ref: Ref(js.Any) = .@"null";
pub var exported_pair: Pair = .{
    .first = .@"null",
    .second = .@"null",
};
pub var uninit_ref: Ref(js.Any) = undefined;
pub var uninit_pair: Pair = undefined;
pub var uninit_tagged: TaggedValue = undefined;
pub var opt_tagged: ?TaggedValue = null;
pub var eu_tagged: Error!TaggedValue = .{ .code = 0 };
pub var wrapper: TaggedWrapper = .{ .t = .{ .code = 0 }, .n = 0 };
pub var outer_union: OuterUnion = .{ .plain = 0 };

var saved_ref: Ref(js.Object) = .@"null";

pub fn activeCount() usize {
    return js.activeHandleCount();
}

pub fn identity(val: Ref(js.Any)) Ref(js.Any) {
    return val;
}

pub fn identityObject(val: Ref(js.Object)) Ref(js.Object) {
    return val;
}

pub fn identitySymbol(val: Ref(js.Symbol)) Ref(js.Symbol) {
    return val;
}

pub fn identityFunction(val: Ref(js.Function)) Ref(js.Function) {
    return val;
}

pub fn getUndefined() Ref(js.Any) {
    const r = Ref(js.Any).@"undefined";
    defer r.deinit();
    return r;
}

pub fn getNull() Ref(js.Any) {
    const r = Ref(js.Any).@"null";
    defer r.deinit();
    return r;
}

pub fn getBool(flag: bool) Ref(js.Any) {
    const r = Ref(js.Any).fromBool(flag);
    defer r.deinit();
    return r;
}

pub fn getGlobalThis() Ref(js.Object) {
    const r = Ref(js.Object).globalThis;
    defer r.deinit();
    return r;
}

pub fn inspectPredicates(val: Ref(js.Any)) u8 {
    defer val.deinit();
    var mask: u8 = 0;
    if (val.isUndefined()) mask |= 1;
    if (val.isNull()) mask |= 2;
    if (val.isNullOrUndefined()) mask |= 4;
    if (val.isReserved()) mask |= 8;
    return mask;
}

pub fn inspectTypeof(val: Ref(js.Any)) js.JsType {
    defer val.deinit();
    return val.typeof();
}

pub fn checkInstanceof(val: Ref(js.Any), ctor: Ref(js.Function)) bool {
    defer val.deinit();
    defer ctor.deinit();
    return val.instanceof(ctor);
}

pub fn checkEqual(a: Ref(js.Any), b: Ref(js.Any)) bool {
    defer a.deinit();
    defer b.deinit();
    return a.eql(b);
}

pub fn castAndClone(val: Ref(js.Any)) Ref(js.Object) {
    defer val.deinit();
    const cloned = val.clone();
    return cloned.cast(js.Object);
}

pub fn storeGlobal(val: Ref(js.Object)) void {
    if (!saved_ref.isNullOrUndefined()) {
        saved_ref.deinit();
    }
    saved_ref = val;
}

pub fn loadGlobalClone() Ref(js.Object) {
    return saved_ref.clone();
}

pub fn clearGlobal() void {
    if (!saved_ref.isNullOrUndefined()) {
        saved_ref.deinit();
    }
    saved_ref = .@"null";
    if (!exported_ref.isReserved()) {
        exported_ref.deinit();
    }
    exported_ref = .@"null";
    if (!exported_pair.first.isReserved()) {
        exported_pair.first.deinit();
    }
    if (!exported_pair.second.isReserved()) {
        exported_pair.second.deinit();
    }
    exported_pair = .{ .first = .@"null", .second = .@"null" };
}

pub fn swapPair(pair: Pair) Pair {
    return .{
        .first = pair.second,
        .second = pair.first,
    };
}

pub fn maybePass(keep: bool, val: Ref(js.Any)) ?Ref(js.Any) {
    if (keep) {
        return val;
    }
    val.deinit();
    return null;
}

pub fn tryPass(fail: bool, val: Ref(js.Any)) Error!Ref(js.Any) {
    errdefer val.deinit();
    if (fail) {
        return error.Rejected;
    }
    return val;
}

pub fn reversePairArray(items: [2]Ref(js.Any)) [2]Ref(js.Any) {
    return .{ items[1], items[0] };
}

pub fn wrapTagged(use_js: bool, val: Ref(js.Any), fallback: i32) TaggedValue {
    if (use_js) {
        return .{ .js = val };
    }
    val.deinit();
    return .{ .code = fallback };
}

pub fn callWithBorrowedRef(
    val: Ref(js.Object),
    cb: *const fn (Ref(js.Object)) Ref(js.Any),
) Ref(js.Any) {
    defer val.deinit();
    const out = cb(val);
    // Verify `val` was only borrowed by `cb` and remains valid until `defer val.deinit()`!
    if (val.typeof() != .object) unreachable;
    return out;
}

pub fn callWithBorrowedComposites(
    first: Ref(js.Any),
    second: Ref(js.Any),
    cb: *const fn (Pair, [2]Ref(js.Any), TaggedValue) void,
) void {
    defer first.deinit();
    defer second.deinit();
    const pair: Pair = .{ .first = first, .second = second };
    const arr: [2]Ref(js.Any) = .{ first, second };
    const tagged: TaggedValue = .{ .js = first };
    cb(pair, arr, tagged);
}

pub fn callFallibleCallback(
    val: Ref(js.Object),
    cb: *const fn (Ref(js.Object)) CallbackError!Ref(js.Any),
) CallbackError!Ref(js.Any) {
    defer val.deinit();
    return try cb(val);
}

pub fn callStrictFallibleCallback(
    cb: *const fn () Error!Ref(js.Any),
) anyerror!Ref(js.Any) {
    return try cb();
}

pub fn callFallibleCompositeCallback(
    val: Ref(js.Object),
    cb: *const fn (Ref(js.Object)) CallbackError!RefWithUint,
) CallbackError!RefWithUint {
    defer val.deinit();
    return try cb(val);
}

pub fn takeRefAndUint(val: Ref(js.Any), num: u32) u32 {
    defer val.deinit();
    return num;
}

pub fn inspectRawHandle(val: Ref(js.Any)) u32 {
    defer val.deinit();
    return val.handle;
}

pub fn triggerDoubleDeinit(val: Ref(js.Object)) void {
    val.deinit();
    val.deinit();
}

pub fn triggerAbaStaleUse(first: Ref(js.Object), replacement: Ref(js.Object)) js.JsType {
    const stale = first;
    first.deinit();
    if (!saved_ref.isNullOrUndefined()) {
        saved_ref.deinit();
    }
    // `replacement` was allocated while `first` was still live, so clone a fresh handle
    // into `first`'s just-freed slot (with generation + 1) and release `replacement`.
    saved_ref = replacement.clone();
    replacement.deinit();
    // `saved_ref` is now live in the SAME slot index as `stale` with incremented generation!
    return stale.typeof();
}

pub fn setFirst(p: *Pair, v: Ref(js.Any)) void {
    p.first.deinit();
    p.first = v;
}

pub fn swapInPlace(p: *Pair) void {
    const tmp = p.first;
    p.first = p.second;
    p.second = tmp;
}

pub fn takeFirstAndSet(p: *Pair, v: Ref(js.Any)) Ref(js.Any) {
    const old = p.first;
    p.first = v;
    return old;
}

pub fn setNum(p: *Mixed, n: u32) void {
    p.num = n;
}

pub fn setMixedBoth(p: *Mixed, v: Ref(js.Any), n: u32) void {
    p.ref.deinit();
    p.ref = v;
    p.num = n;
}

pub fn ptrFirstType(p: *const Pair) js.JsType {
    return p.first.typeof();
}

pub fn sliceLen(items: []const Ref(js.Any)) usize {
    for (items) |item| {
        _ = item.typeof();
    }
    return items.len;
}

pub fn sliceReplaceElem(items: []Ref(js.Any), idx: usize, v: Ref(js.Any)) void {
    items[idx].deinit();
    items[idx] = v;
}

pub fn switchTaggedToCode(t: *TaggedValue, code: i32) void {
    switch (t.*) {
        .js => |r| r.deinit(),
        .code => {},
    }
    t.* = .{ .code = code };
}

pub fn callAsyncMutatePair(
    p: *Pair,
    v: Ref(js.Any),
    cb: *const fn (Ref(js.Any)) Ref(js.Any),
) void {
    const next = cb(p.first);
    p.first.deinit();
    p.second.deinit();
    p.first = next;
    p.second = v;
}

pub fn poisonUninitVarsWith0xAA() void {
    @memset(std.mem.asBytes(&uninit_ref), 0xaa);
    @memset(std.mem.asBytes(&uninit_pair), 0xaa);
    @memset(std.mem.asBytes(&uninit_tagged), 0xaa);
}

pub fn zigSetExportedRef(v: Ref(js.Any)) void {
    if (!exported_ref.isReserved()) {
        exported_ref.deinit();
    }
    exported_ref = v;
}

pub fn zigSetUninitTaggedJs(v: Ref(js.Any)) void {
    uninit_tagged = .{ .js = v };
}

pub fn zigSetOptTaggedJs(v: Ref(js.Any)) void {
    if (opt_tagged) |prev| {
        switch (prev) {
            .js => |r| r.deinit(),
            .code => {},
        }
    }
    opt_tagged = .{ .js = v };
}

pub fn zigSetEuTaggedJs(v: Ref(js.Any)) void {
    if (eu_tagged) |prev| {
        switch (prev) {
            .js => |r| r.deinit(),
            .code => {},
        }
    } else |_| {}
    eu_tagged = .{ .js = v };
}

pub fn zigSetWrapperJs(v: Ref(js.Any), n: u32) void {
    switch (wrapper.t) {
        .js => |r| r.deinit(),
        .code => {},
    }
    wrapper = .{ .t = .{ .js = v }, .n = n };
}

pub fn zigSetOuterNestedJs(v: Ref(js.Any)) void {
    switch (outer_union) {
        .nested => |prev| switch (prev) {
            .js => |r| r.deinit(),
            .code => {},
        },
        .plain => {},
    }
    outer_union = .{ .nested = .{ .js = v } };
}

pub fn leaveStaleDeinitInUninitRefAndReuseSlot(
    temp: Ref(js.Any),
    keeper: Ref(js.Object),
) void {
    uninit_ref = temp;
    uninit_ref.deinit(); // leaves stale `temp.handle` in `uninit_ref`!
    if (!saved_ref.isNullOrUndefined()) {
        saved_ref.deinit();
    }
    // `keeper` was allocated while `temp` was live; cloning `keeper` allocates into `temp`'s
    // just-freed slot index with generation + 1!
    saved_ref = keeper.clone();
    keeper.deinit();
}

