//! Union, enum, literal, open-literal, and template-literal lowering helpers for Milestone 3.1b
//! (`ts-zigar` <-> `zigar.js`, Issue #47).
//!
//! Centralizes:
//! - Integer-backed TypeScript `enum` classification (`i32` / `i64`) and duplicate member value
//!   alias deduplication (`pub const <alias>: @This() = .<primary>`),
//! - Closed literal union values (`str`, `num`, `boolean`, `bigint_val`) and deterministic human-readable
//!   Zig tag naming (`utf8`, `n_200`, `neg_1`, `bool_true`, `bi_100` — never hashes),
//! - Open-literal autocomplete union classification (`"utf8" | (string & {})`, `200 | (number & {})`,
//!   `0n | (bigint & {})`),
//! - Template literal cross-product finite expansion (`<= 64` combinations) and open pattern matcher
//!   specifications (`node:${string}`, `/api/v${number}/${string}`, `http${"" | "s"}://${string}`),
//! - Discriminated object union key selection (single- and multi-literal disjoint arms, conventional
//!   key tie-breaking, and enum-member discriminants).

const std = @import("std");
const lower_types = @import("lower_types.zig");

pub const max_finite_template_combinations: usize = 64;
pub const max_template_expansion: usize = max_finite_template_combinations;
pub const max_finite_template_total_bytes: usize = 4096;
pub const max_template_pattern_spans: usize = 16;

pub fn exactIntI64(n: f64) ?i64 {
    return (ClosedLiteralValue{ .num = n }).safeIntegerValue();
}

pub fn closedLiteralEql(a: ClosedLiteralValue, b: ClosedLiteralValue) bool {
    return ClosedLiteralValue.eql(a, b);
}

/// Backing integer width for pure-integer TypeScript `enum`s and numeric literal unions.
pub const EnumBackingKind = enum {
    none,
    i32,
    i64,

    pub fn zigTypeName(self: EnumBackingKind) ?[]const u8 {
        return switch (self) {
            .none => null,
            .i32 => "i32",
            .i64 => "i64",
        };
    }
};

/// Canonical closed literal value for enum members, literal unions, and discriminant sets.
pub const ClosedLiteralValue = union(enum) {
    str: []const u8,
    num: f64,
    boolean: bool,
    bigint_val: []const u8, // normalized signed digits without '_' or trailing 'n'

    pub fn normalizeZero(n: f64) f64 {
        return if (n == 0.0) 0.0 else n;
    }

    pub fn eql(a: ClosedLiteralValue, b: ClosedLiteralValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .str => |sa| std.mem.eql(u8, sa, b.str),
            .num => |na| blk: {
                const nb = b.num;
                if (std.math.isNan(na) and std.math.isNan(nb)) break :blk true;
                break :blk normalizeZero(na) == normalizeZero(nb);
            },
            .boolean => |ba| ba == b.boolean,
            .bigint_val => |bia| std.mem.eql(u8, bia, b.bigint_val),
        };
    }

    pub fn safeIntegerValue(self: ClosedLiteralValue) ?i64 {
        switch (self) {
            .num => |n| {
                if (!std.math.isFinite(n)) return null;
                const norm = normalizeZero(n);
                if (@trunc(norm) != norm) return null;
                if (norm < -9007199254740991.0 or norm > 9007199254740991.0) return null;
                return @intFromFloat(norm);
            },
            else => return null,
        }
    }
};

/// Describes whether a known-value enum member is a primary enum tag or an alias `pub const`
/// pointing at an earlier member with the identical wire value.
pub const EnumMemberLayout = struct {
    alias_of_index: ?usize,
    int_tag_value: ?i64,
};

pub const EnumAnalysis = struct {
    backing: EnumBackingKind,
    is_pure_string: bool,
    layouts: []EnumMemberLayout,

    pub fn deinit(self: EnumAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.layouts);
    }
};

/// Analyzes a closed slice of `ClosedLiteralValue`s to determine integer backing (`i32` / `i64`),
/// pure-string fast path eligibility, and duplicate wire-value alias indices.
pub fn analyzeClosedEnumValues(
    allocator: std.mem.Allocator,
    values: []const ClosedLiteralValue,
) error{OutOfMemory}!EnumAnalysis {
    const layouts = try allocator.alloc(EnumMemberLayout, values.len);
    errdefer allocator.free(layouts);

    var all_int = values.len > 0;
    var fits_i32 = true;
    var all_str = values.len > 0;

    for (values, 0..) |v, idx| {
        var dup_idx: ?usize = null;
        for (values[0..idx], 0..) |prev, pidx| {
            if (layouts[pidx].alias_of_index != null) continue;
            if (ClosedLiteralValue.eql(prev, v)) {
                dup_idx = pidx;
                break;
            }
        }

        const int_v = v.safeIntegerValue();
        if (int_v) |iv| {
            if (iv < std.math.minInt(i32) or iv > std.math.maxInt(i32)) {
                fits_i32 = false;
            }
        } else {
            all_int = false;
        }
        if (v != .str) {
            all_str = false;
        }

        layouts[idx] = .{
            .alias_of_index = dup_idx,
            .int_tag_value = int_v,
        };
    }

    const backing: EnumBackingKind = if (all_int)
        (if (fits_i32) .i32 else .i64)
    else
        .none;

    return .{
        .backing = backing,
        .is_pure_string = all_str,
        .layouts = layouts,
    };
}

/// Formats a clean, human-readable identifier hint for a `ClosedLiteralValue`:
/// - `"utf8"` -> `"utf8"`
/// - `200` -> `"n_200"`, `-1` -> `"neg_1"`, `0.5` -> `"n_0_5"`
/// - `true` -> `"bool_true"`, `false` -> `"bool_false"`
/// - `100n` -> `"bi_100"`, `-5n` -> `"bi_neg_5"`
pub fn formatLiteralTagHint(
    allocator: std.mem.Allocator,
    val: ClosedLiteralValue,
) error{OutOfMemory}![]u8 {
    switch (val) {
        .str => |s| return allocator.dupe(u8, s),
        .boolean => |b| return allocator.dupe(u8, if (b) "bool_true" else "bool_false"),
        .num => |n| {
            if (val.safeIntegerValue()) |iv| {
                if (iv < 0) {
                    const mag: u64 = @abs(iv);
                    return std.fmt.allocPrint(allocator, "neg_{d}", .{mag});
                }
                return std.fmt.allocPrint(allocator, "n_{d}", .{iv});
            }
            const norm = ClosedLiteralValue.normalizeZero(n);
            const raw = try std.fmt.allocPrint(allocator, "{d}", .{norm});
            defer allocator.free(raw);
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            if (std.mem.startsWith(u8, raw, "-")) {
                try out.appendSlice(allocator, "neg_");
                for (raw[1..]) |ch| {
                    try out.append(allocator, if (std.ascii.isAlphanumeric(ch)) ch else '_');
                }
            } else {
                try out.appendSlice(allocator, "n_");
                for (raw) |ch| {
                    try out.append(allocator, if (std.ascii.isAlphanumeric(ch)) ch else '_');
                }
            }
            return out.toOwnedSlice(allocator);
        },
        .bigint_val => |bi| {
            if (std.mem.startsWith(u8, bi, "-")) {
                return std.fmt.allocPrint(allocator, "bi_neg_{s}", .{bi[1..]});
            }
            return std.fmt.allocPrint(allocator, "bi_{s}", .{bi});
        },
    }
}

/// Primitive base kind for open-literal autocomplete unions (`"utf8" | (string & {})`, etc.).
pub const OpenPrimitiveKind = enum {
    str,
    num,
    bigint,
};

/// Placeholder categories inside an open TypeScript template literal pattern.
pub const TemplatePlaceholderKind = enum {
    any_string,
    number,
    bigint,
    boolean,
    literal_set,
};

pub const TemplateSpanSpec = struct {
    placeholder: TemplatePlaceholderKind,
    choices: []const []const u8 = &.{},
    literal_tail: []const u8,
};

pub const TemplatePatternSpec = struct {
    head: []const u8,
    spans: []const TemplateSpanSpec,
};

/// Expands a finite template literal (`head` + per-span finite string choices + `tail`s) into
/// its deduplicated cross-product string slice, or returns `null` if the combination count
/// exceeds `max_finite_template_combinations` or total byte size exceeds `max_finite_template_total_bytes`.
/// Note: if any span has `0` choices (e.g. `${never}`), returns an empty slice (`len == 0`).
pub fn expandTemplateCrossProduct(
    allocator: std.mem.Allocator,
    head: []const u8,
    span_choices: []const []const []const u8,
    span_tails: []const []const u8,
) error{OutOfMemory}!?[][]u8 {
    std.debug.assert(span_choices.len == span_tails.len);
    for (span_choices) |choices| {
        if (choices.len == 0) {
            return try allocator.alloc([]u8, 0);
        }
    }

    var total_combos: usize = 1;
    for (span_choices) |choices| {
        const mul = @mulWithOverflow(total_combos, choices.len);
        if (mul[1] != 0 or mul[0] > max_finite_template_combinations) return null;
        total_combos = mul[0];
    }

    var current = try allocator.alloc([]u8, 1);
    var current_len: usize = 1;
    current[0] = try allocator.dupe(u8, head);
    errdefer {
        for (current[0..current_len]) |s| allocator.free(s);
        allocator.free(current);
    }

    var total_bytes: usize = head.len;
    for (span_choices, span_tails) |choices, tail| {
        const next_cap = current_len * choices.len;
        var next = try allocator.alloc([]u8, next_cap);
        var next_len: usize = 0;
        errdefer {
            for (next[0..next_len]) |s| allocator.free(s);
            allocator.free(next);
        }

        total_bytes = 0;
        for (current[0..current_len]) |prefix| {
            for (choices) |ch_str| {
                const new_len = prefix.len + ch_str.len + tail.len;
                total_bytes += new_len;
                if (total_bytes > max_finite_template_total_bytes) {
                    for (next[0..next_len]) |s| allocator.free(s);
                    allocator.free(next);
                    for (current[0..current_len]) |s| allocator.free(s);
                    allocator.free(current);
                    return null;
                }
                const combined = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, ch_str, tail });
                next[next_len] = combined;
                next_len += 1;
            }
        }

        for (current[0..current_len]) |s| allocator.free(s);
        allocator.free(current);
        current = next;
        current_len = next_len;
    }

    // Deduplicate while preserving declaration order (e.g. `` `${"a" | "ab"}${"bc" | "c"}` `` -> `"abc"`).
    var dedup: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dedup.items) |s| allocator.free(s);
        dedup.deinit(allocator);
    }
    for (current[0..current_len]) |cand| {
        var exists = false;
        for (dedup.items) |prev| {
            if (std.mem.eql(u8, prev, cand)) {
                exists = true;
                break;
            }
        }
        if (exists) {
            allocator.free(cand);
        } else {
            try dedup.append(allocator, cand);
        }
    }
    allocator.free(current);
    return try dedup.toOwnedSlice(allocator);
}

pub fn matchesJsNumberSegment(seg: []const u8) bool {
    if (seg.len == 0) return false;
    if (std.mem.eql(u8, seg, "NaN") or
        std.mem.eql(u8, seg, "Infinity") or
        std.mem.eql(u8, seg, "-Infinity") or
        std.mem.eql(u8, seg, "+Infinity"))
    {
        return true;
    }
    for (seg) |ch| {
        if (std.ascii.isWhitespace(ch) or ch == '_') return false;
    }
    if (std.mem.startsWith(u8, seg, "0x") or std.mem.startsWith(u8, seg, "0X") or
        std.mem.startsWith(u8, seg, "0o") or std.mem.startsWith(u8, seg, "0O") or
        std.mem.startsWith(u8, seg, "0b") or std.mem.startsWith(u8, seg, "0B"))
    {
        _ = std.fmt.parseInt(u64, seg, 0) catch return false;
        return true;
    }
    // Reject Zig-only float infinities like "inf" / "nan" lowercase.
    for (seg) |ch| {
        if (std.ascii.isAlphabetic(ch) and ch != 'e' and ch != 'E') return false;
    }
    _ = std.fmt.parseFloat(f64, seg) catch return false;
    return true;
}

pub fn matchesJsBigIntSegment(seg: []const u8) bool {
    if (seg.len == 0) return false;
    const digits = if (seg[0] == '-') seg[1..] else seg;
    if (digits.len == 0) return false;
    for (digits) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

pub fn matchesPlaceholderSegment(
    kind: TemplatePlaceholderKind,
    choices: []const []const u8,
    seg: []const u8,
) bool {
    return switch (kind) {
        .any_string => true,
        .boolean => std.mem.eql(u8, seg, "true") or std.mem.eql(u8, seg, "false"),
        .bigint => matchesJsBigIntSegment(seg),
        .number => matchesJsNumberSegment(seg),
        .literal_set => blk: {
            for (choices) |c| {
                if (std.mem.eql(u8, seg, c)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn matchTemplateSpansAt(
    input: []const u8,
    pos: usize,
    spans: []const TemplateSpanSpec,
    span_idx: usize,
) bool {
    if (span_idx >= spans.len) {
        return pos == input.len;
    }
    const sp = spans[span_idx];
    const tail = sp.literal_tail;

    // Fast path: last span with empty tail consumes the rest of `input`.
    if (span_idx + 1 == spans.len and tail.len == 0) {
        return matchesPlaceholderSegment(sp.placeholder, sp.choices, input[pos..]);
    }

    if (tail.len == 0) {
        // Adjacent placeholders with empty separator (`${"a" | "b"}${number}`): try all split points.
        var split: usize = pos;
        while (split <= input.len) : (split += 1) {
            if (matchesPlaceholderSegment(sp.placeholder, sp.choices, input[pos..split]) and
                matchTemplateSpansAt(input, split, spans, span_idx + 1))
            {
                return true;
            }
        }
        return false;
    }

    // Non-empty `tail`: search occurrences of `tail` at or after `pos`.
    var search_from: usize = pos;
    while (search_from + tail.len <= input.len) {
        const rel = std.mem.indexOfPos(u8, input, search_from, tail) orelse return false;
        const seg = input[pos..rel];
        if (matchesPlaceholderSegment(sp.placeholder, sp.choices, seg) and
            matchTemplateSpansAt(input, rel + tail.len, spans, span_idx + 1))
        {
            return true;
        }
        search_from = rel + 1;
    }
    return false;
}

/// Matches `input` against a `TemplatePatternSpec` (usable at both comptime and runtime).
pub fn matchTemplatePatternSpec(input: []const u8, pat: TemplatePatternSpec) bool {
    if (!std.mem.startsWith(u8, input, pat.head)) return false;
    return matchTemplateSpansAt(input, pat.head.len, pat.spans, 0);
}

/// Per-arm candidate property entry for discriminated object union analysis.
pub const CandidateDiscProp = struct {
    wire_name: []const u8,
    values: []const ClosedLiteralValue,
    /// Optional enum member logical tag hint (e.g. `"circle"` from `ShapeKind.Circle`) when
    /// `values.len == 1` came from an enum member reference rather than a raw numeric literal.
    enum_member_hint: ?[]const u8 = null,
};

pub const SelectedDiscriminant = struct {
    wire_name: []const u8,
    arm_values: []const []const ClosedLiteralValue,
    arm_hints: []const ?[]const u8,

    pub fn deinit(self: SelectedDiscriminant, allocator: std.mem.Allocator) void {
        allocator.free(self.wire_name);
        for (self.arm_values) |vals| {
            for (vals) |v| {
                switch (v) {
                    .str => |s| allocator.free(s),
                    .bigint_val => |bi| allocator.free(bi),
                    .num, .boolean => {},
                }
            }
            allocator.free(vals);
        }
        allocator.free(self.arm_values);
        for (self.arm_hints) |h_opt| {
            if (h_opt) |h| allocator.free(h);
        }
        allocator.free(self.arm_hints);
    }
};

fn preferredDiscriminantRank(wire_name: []const u8) u8 {
    const preferred = [_][]const u8{
        "kind",
        "type",
        "tag",
        "_tag",
        "status",
        "ok",
        "success",
        "action",
        "event",
        "op",
        "mode",
        "version",
    };
    for (preferred, 0..) |p, idx| {
        if (std.mem.eql(u8, wire_name, p)) return @intCast(idx);
    }
    return 100;
}

/// Selects the best shared required discriminant property across `arms.len >= 2` object arms
/// whose per-arm `ClosedLiteralValue` sets are non-empty and pairwise disjoint.
pub fn selectDiscriminantProperty(
    allocator: std.mem.Allocator,
    arms: []const []const CandidateDiscProp,
) error{OutOfMemory}!?SelectedDiscriminant {
    if (arms.len < 2 or arms[0].len == 0) return null;

    var best_wire: ?[]const u8 = null;
    var best_pref_rank: u8 = 255;
    var best_all_singleton: bool = false;

    for (arms[0]) |cand0| {
        if (cand0.values.len == 0) continue;
        // Verify `cand0` itself has no duplicate values unnecessary, check across all arms:
        var present_in_all = true;
        var all_singleton = (cand0.values.len == 1);

        for (arms[1..]) |other_arm| {
            var found: ?CandidateDiscProp = null;
            for (other_arm) |oc| {
                if (std.mem.eql(u8, oc.wire_name, cand0.wire_name)) {
                    found = oc;
                    break;
                }
            }
            if (found == null or found.?.values.len == 0) {
                present_in_all = false;
                break;
            }
            if (found.?.values.len > 1) all_singleton = false;
        }
        if (!present_in_all) continue;

        // Verify pairwise disjointness of `values` across every pair of arms `(i, j)`.
        var disjoint = true;
        outer: for (0..arms.len) |i| {
            const vi = findArmProp(arms[i], cand0.wire_name).?.values;
            for (i + 1..arms.len) |j| {
                const vj = findArmProp(arms[j], cand0.wire_name).?.values;
                for (vi) |a| {
                    for (vj) |b| {
                        if (ClosedLiteralValue.eql(a, b)) {
                            disjoint = false;
                            break :outer;
                        }
                    }
                }
            }
        }
        if (!disjoint) continue;

        const rank = preferredDiscriminantRank(cand0.wire_name);
        const take = if (best_wire == null)
            true
        else if (rank != best_pref_rank)
            rank < best_pref_rank
        else if (all_singleton != best_all_singleton)
            all_singleton
        else
            false;

        if (take) {
            best_wire = cand0.wire_name;
            best_pref_rank = rank;
            best_all_singleton = all_singleton;
        }
    }

    const chosen = best_wire orelse return null;
    const owned_wire = try allocator.dupe(u8, chosen);
    errdefer allocator.free(owned_wire);

    const arm_values = try allocator.alloc([]const ClosedLiteralValue, arms.len);
    var arm_values_init: usize = 0;
    errdefer {
        for (arm_values[0..arm_values_init]) |vals| {
            for (vals) |v| {
                switch (v) {
                    .str => |s| allocator.free(s),
                    .bigint_val => |bi| allocator.free(bi),
                    .num, .boolean => {},
                }
            }
            allocator.free(vals);
        }
        allocator.free(arm_values);
    }

    const arm_hints = try allocator.alloc(?[]const u8, arms.len);
    var arm_hints_init: usize = 0;
    errdefer {
        for (arm_hints[0..arm_hints_init]) |h_opt| {
            if (h_opt) |h| allocator.free(h);
        }
        allocator.free(arm_hints);
    }

    for (arms, 0..) |arm, idx| {
        const p = findArmProp(arm, chosen).?;
        const vals_copy = try allocator.alloc(ClosedLiteralValue, p.values.len);
        var vals_copy_init: usize = 0;
        errdefer {
            for (vals_copy[0..vals_copy_init]) |v| {
                switch (v) {
                    .str => |s| allocator.free(s),
                    .bigint_val => |bi| allocator.free(bi),
                    .num, .boolean => {},
                }
            }
            allocator.free(vals_copy);
        }
        for (p.values, 0..) |v, vi| {
            vals_copy[vi] = switch (v) {
                .str => |s| .{ .str = try allocator.dupe(u8, s) },
                .bigint_val => |bi| .{ .bigint_val = try allocator.dupe(u8, bi) },
                .num => |n| .{ .num = n },
                .boolean => |b| .{ .boolean = b },
            };
            vals_copy_init += 1;
        }
        arm_values[idx] = vals_copy;
        arm_values_init += 1;

        arm_hints[idx] = if (p.enum_member_hint) |eh| try allocator.dupe(u8, eh) else null;
        arm_hints_init += 1;
    }

    return .{
        .wire_name = owned_wire,
        .arm_values = arm_values,
        .arm_hints = arm_hints,
    };
}

fn findArmProp(props: []const CandidateDiscProp, wire_name: []const u8) ?CandidateDiscProp {
    for (props) |p| {
        if (std.mem.eql(u8, p.wire_name, wire_name)) return p;
    }
    return null;
}

/// Formats a readable snake_case variant tag hint for a discriminated union arm:
/// - Enum member hint (`ShapeKind.Circle`) -> `"circle"`
/// - Single string literal (`kind: "circle"`) -> `"circle"`
/// - Single boolean literal (`ok: true`) -> `"ok_true"`
/// - Single numeric literal (`status: 200`) -> `"status_200"`
/// - Multi-literal arm (`status: 200 | 201`) -> `"status_200_or_201"` (capped cleanly at 3 items)
pub fn formatDiscriminantVariantHint(
    allocator: std.mem.Allocator,
    disc_wire_name: []const u8,
    values: []const ClosedLiteralValue,
    enum_member_hint: ?[]const u8,
) error{OutOfMemory}![]u8 {
    if (enum_member_hint) |eh| {
        return allocator.dupe(u8, eh);
    }
    if (values.len == 1) {
        return switch (values[0]) {
            .str => |s| if (s.len > 0) allocator.dupe(u8, s) else std.fmt.allocPrint(allocator, "{s}_empty", .{disc_wire_name}),
            .boolean => |b| std.fmt.allocPrint(allocator, "{s}_{s}", .{ disc_wire_name, if (b) "true" else "false" }),
            .num => blk: {
                const num_hint = try formatLiteralTagHint(allocator, values[0]);
                defer allocator.free(num_hint);
                const stripped = if (std.mem.startsWith(u8, num_hint, "n_")) num_hint[2..] else num_hint;
                break :blk std.fmt.allocPrint(allocator, "{s}_{s}", .{ disc_wire_name, stripped });
            },
            .bigint_val => |bi| std.fmt.allocPrint(allocator, "{s}_{s}", .{ disc_wire_name, bi }),
        };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const max_parts = @min(values.len, 3);
    var all_non_str = true;
    for (values[0..max_parts]) |v| {
        if (v == .str) all_non_str = false;
    }
    if (all_non_str) {
        try out.appendSlice(allocator, disc_wire_name);
        try out.append(allocator, '_');
    }
    for (values[0..max_parts], 0..) |v, idx| {
        if (idx > 0) try out.appendSlice(allocator, "_or_");
        switch (v) {
            .str => |s| try out.appendSlice(allocator, if (s.len > 0) s else "empty"),
            .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
            else => {
                const lh = try formatLiteralTagHint(allocator, v);
                defer allocator.free(lh);
                const stripped = if (std.mem.startsWith(u8, lh, "n_")) lh[2..] else lh;
                try out.appendSlice(allocator, stripped);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

test "analyzeClosedEnumValues classifies i32/i64 backing and deduplicates alias members" {
    const alloc = std.testing.allocator;

    {
        const vals = [_]ClosedLiteralValue{
            .{ .num = 200 },
            .{ .num = 404 },
            .{ .num = 200 },
            .{ .num = -0.0 },
            .{ .num = 0.0 },
        };
        const res = try analyzeClosedEnumValues(alloc, &vals);
        defer res.deinit(alloc);
        try std.testing.expectEqual(EnumBackingKind.i32, res.backing);
        try std.testing.expect(!res.is_pure_string);
        try std.testing.expectEqual(@as(?usize, null), res.layouts[0].alias_of_index);
        try std.testing.expectEqual(@as(?usize, 0), res.layouts[2].alias_of_index);
        try std.testing.expectEqual(@as(?usize, null), res.layouts[3].alias_of_index);
        try std.testing.expectEqual(@as(?usize, 3), res.layouts[4].alias_of_index);
    }

    {
        const big_vals = [_]ClosedLiteralValue{
            .{ .num = 0 },
            .{ .num = 2147483648 },
        };
        const res = try analyzeClosedEnumValues(alloc, &big_vals);
        defer res.deinit(alloc);
        try std.testing.expectEqual(EnumBackingKind.i64, res.backing);
    }

    {
        const str_vals = [_]ClosedLiteralValue{
            .{ .str = "utf8" },
            .{ .str = "hex" },
            .{ .str = "utf8" },
        };
        const res = try analyzeClosedEnumValues(alloc, &str_vals);
        defer res.deinit(alloc);
        try std.testing.expectEqual(EnumBackingKind.none, res.backing);
        try std.testing.expect(res.is_pure_string);
        try std.testing.expectEqual(@as(?usize, 0), res.layouts[2].alias_of_index);
    }
}

test "expandTemplateCrossProduct and matchTemplatePatternSpec cover finite and open patterns" {
    const alloc = std.testing.allocator;

    const c0 = [_][]const u8{ "1", "2" };
    const c1 = [_][]const u8{ "a", "b" };
    const choices = [_][]const []const u8{ &c0, &c1 };
    const tails = [_][]const u8{ ".", "" };
    const expanded = (try expandTemplateCrossProduct(alloc, "v", &choices, &tails)).?;
    defer {
        for (expanded) |s| alloc.free(s);
        alloc.free(expanded);
    }
    try std.testing.expectEqual(@as(usize, 4), expanded.len);
    try std.testing.expectEqualStrings("v1.a", expanded[0]);
    try std.testing.expectEqualStrings("v1.b", expanded[1]);
    try std.testing.expectEqualStrings("v2.a", expanded[2]);
    try std.testing.expectEqualStrings("v2.b", expanded[3]);

    const route_spans = [_]TemplateSpanSpec{
        .{ .placeholder = .number, .literal_tail = "/" },
        .{ .placeholder = .any_string, .literal_tail = "" },
    };
    const route_pat = TemplatePatternSpec{ .head = "/api/v", .spans = &route_spans };
    try std.testing.expect(matchTemplatePatternSpec("/api/v2/users/42", route_pat));
    try std.testing.expect(matchTemplatePatternSpec("/api/v1.5/", route_pat));
    try std.testing.expect(!matchTemplatePatternSpec("/api/vX/users", route_pat));
    try std.testing.expect(!matchTemplatePatternSpec("/v2/users", route_pat));

    const scheme_choices = [_][]const u8{ "", "s" };
    const url_spans = [_]TemplateSpanSpec{
        .{ .placeholder = .literal_set, .choices = &scheme_choices, .literal_tail = "://" },
        .{ .placeholder = .any_string, .literal_tail = ":" },
        .{ .placeholder = .bigint, .literal_tail = "" },
    };
    const url_pat = TemplatePatternSpec{ .head = "http", .spans = &url_spans };
    try std.testing.expect(matchTemplatePatternSpec("https://localhost:8080", url_pat));
    try std.testing.expect(matchTemplatePatternSpec("http://example.com:80", url_pat));
    try std.testing.expect(!matchTemplatePatternSpec("http://example.com:abc", url_pat));
}

test "selectDiscriminantProperty prefers conventional keys and supports multi-literal arms" {
    const alloc = std.testing.allocator;

    const ok_200_201 = [_]ClosedLiteralValue{ .{ .num = 200 }, .{ .num = 201 } };
    const err_404 = [_]ClosedLiteralValue{.{ .num = 404 }};
    const tag_ok = [_]ClosedLiteralValue{.{ .str = "ok" }};
    const tag_err = [_]ClosedLiteralValue{.{ .str = "err" }};

    const arm0 = [_]CandidateDiscProp{
        .{ .wire_name = "code", .values = &ok_200_201 },
        .{ .wire_name = "kind", .values = &tag_ok },
    };
    const arm1 = [_]CandidateDiscProp{
        .{ .wire_name = "code", .values = &err_404 },
        .{ .wire_name = "kind", .values = &tag_err },
    };
    const arms = [_][]const CandidateDiscProp{ &arm0, &arm1 };

    const sel = (try selectDiscriminantProperty(alloc, &arms)).?;
    defer sel.deinit(alloc);
    try std.testing.expectEqualStrings("kind", sel.wire_name);

    const status_arms = [_][]const CandidateDiscProp{
        &[_]CandidateDiscProp{.{ .wire_name = "status", .values = &ok_200_201 }},
        &[_]CandidateDiscProp{.{ .wire_name = "status", .values = &err_404 }},
    };
    const sel2 = (try selectDiscriminantProperty(alloc, &status_arms)).?;
    defer sel2.deinit(alloc);
    try std.testing.expectEqualStrings("status", sel2.wire_name);

    const hint0 = try formatDiscriminantVariantHint(alloc, sel2.wire_name, sel2.arm_values[0], sel2.arm_hints[0]);
    defer alloc.free(hint0);
    try std.testing.expectEqualStrings("status_200_or_201", hint0);
}
