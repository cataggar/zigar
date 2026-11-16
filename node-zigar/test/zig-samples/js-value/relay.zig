const zigar = @import("zigar");
const js = zigar.js;
const Ref = js.Ref;

pub fn relay(cb: *const fn () void) void {
    cb();
}

pub fn relayWithRef(val: Ref(js.Any), cb: *const fn (Ref(js.Any)) Ref(js.Any)) Ref(js.Any) {
    defer val.deinit();
    const out = cb(val);
    _ = val.typeof();
    return out;
}

pub fn activeCount() usize {
    return js.activeHandleCount();
}
