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
