// SPDX-License-Identifier: BSD-2-Clause

//! Values as text: what `print` shows, what `str()` returns and what the
//! holes of an f-string become, with Python's format specs.

const std = @import("std");
const Writer = std.Io.Writer;

const Vm = @import("Vm.zig");
const Value = @import("value.zig").Value;
const object = @import("object.zig");
const Error = Vm.Error;

pub fn float(w: *Writer, f: f64) Writer.Error!void {
    if (std.math.isNan(f)) return w.writeAll("nan");
    if (std.math.isInf(f)) return w.writeAll(if (f > 0) "inf" else "-inf");
    var buf: [64]u8 = undefined;
    const magnitude = @abs(f);
    const scientific = magnitude >= 1e16 or (magnitude < 1e-5 and magnitude > 0);
    const text = if (scientific) std.fmt.bufPrint(&buf, "{e}", .{f}) catch unreachable else std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
    try w.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".e") == null) try w.writeAll(".0");
}

/// A vector's component at its own precision: an f32 0.6 is `0.6`, not the
/// `0.6000000238418579` it is as an f64.
fn component(w: *Writer, f: f32) Writer.Error!void {
    if (std.math.isNan(f) or std.math.isInf(f)) return float(w, f);
    var buf: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
    try w.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".e") == null) try w.writeAll(".0");
}

/// `v` as `print` shows it; `quoted` puts strings in quotes, as they are
/// shown inside a list or a map.
pub fn value(w: *Writer, v: Value, quoted: bool, depth: u32) Writer.Error!void {
    switch (v.tag) {
        .null => try w.writeAll("null"),
        .undefined => try w.writeAll("undefined"),
        .host_type => try w.writeAll(@import("../reflect.zig").nameOf(v.asHostType())),
        .bool => try w.writeAll(if (v.asBool()) "true" else "false"),
        .int => try w.print("{d}", .{v.asInt()}),
        .float => try float(w, v.asFloat()),
        .vec2 => {
            const xy = v.asVec2();
            try w.writeByte('(');
            try component(w, xy[0]);
            try w.writeAll(", ");
            try component(w, xy[1]);
            try w.writeByte(')');
        },
        .vec3 => {
            const xyz = v.asVec3();
            try w.writeByte('(');
            try component(w, xyz[0]);
            try w.writeAll(", ");
            try component(w, xyz[1]);
            try w.writeAll(", ");
            try component(w, xyz[2]);
            try w.writeByte(')');
        },
        .color => {
            const c = v.as(object.Color).rgba;
            try w.writeAll("color(");
            for (c, 0..) |x, i| {
                if (i > 0) try w.writeAll(", ");
                try component(w, x);
            }
            try w.writeByte(')');
        },
        .string => {
            const s = v.as(object.String).bytes();
            if (!quoted) return w.writeAll(s);
            try w.writeByte('"');
            for (s) |c| switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\t' => try w.writeAll("\\t"),
                '\r' => try w.writeAll("\\r"),
                else => try w.writeByte(c),
            };
            try w.writeByte('"');
        },
        .list => {
            if (depth > 16) return w.writeAll("[...]");
            try w.writeByte('[');
            for (v.as(object.List).items.items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try value(w, item, true, depth + 1);
            }
            try w.writeByte(']');
        },
        .map => {
            if (depth > 16) return w.writeAll("{...}");
            try w.writeByte('{');
            var it = v.as(object.Map).table.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeAll(", ");
                first = false;
                try value(w, e.key, true, depth + 1);
                try w.writeAll(": ");
                try value(w, e.value, true, depth + 1);
            }
            try w.writeByte('}');
        },
        .instance => {
            const inst = v.as(object.Instance);
            try w.writeAll(inst.class.name.bytes());
            if (depth > 8) return w.writeAll("{ ... }");
            try w.writeByte('{');
            var shown: usize = 0;
            for (inst.class.fields, inst.fields()) |f, x| {
                if (f.is_signal or f.host) continue;
                try w.writeAll(if (shown == 0) " ." else ", .");
                try w.writeAll(f.name.bytes());
                try w.writeAll(" = ");
                try value(w, x, true, depth + 1);
                shown += 1;
            }
            try w.writeAll(if (shown == 0) "}" else " }");
        },
        .enum_value => {
            const e = object.EnumType.from(v.obj());
            try w.print("{s}.{s}", .{ e.name.bytes(), e.members[v.extra].bytes() });
        },
        .@"error" => {
            const e = v.as(object.ErrorValue);
            try w.print("error.{s}", .{e.name.bytes()});
            if (e.message) |m| {
                try w.writeByte('(');
                try value(w, .fromObj(.string, &m.obj), true, depth + 1);
                try w.writeByte(')');
            }
        },
        .function => try w.print("fn {s}", .{v.as(object.Closure).proto.name.bytes()}),
        .native => try w.print("fn {s}", .{v.as(object.Native).name}),
        .method => try w.writeAll("fn (bound)"),
        .class => try w.print("struct {s}", .{v.as(object.Class).name.bytes()}),
        .enum_type => try w.print("enum {s}", .{v.as(object.EnumType).name.bytes()}),
        .module => try w.print("module {s}", .{v.as(object.Module).name.bytes()}),
        .task => try w.print("task ({s})", .{@tagName(v.as(object.Task).state)}),
        .signal => try w.print("signal {s}", .{v.as(object.Signal).name.bytes()}),
        .handle => try @import("../reflect.zig").format(w, v.as(object.Handle)),
        .range => try w.writeAll("range"),
        _ => try w.writeAll("?"),
    }
}

const Spec = struct {
    fill: u8 = ' ',
    alignment: ?enum { left, right, center } = null,
    plus: bool = false,
    zero: bool = false,
    width: usize = 0,
    precision: ?usize = null,
    kind: u8 = 0,
};

fn parseSpec(text: []const u8) ?Spec {
    var s: Spec = .{};
    var i: usize = 0;
    const isAlign = struct {
        fn f(c: u8) bool {
            return c == '<' or c == '>' or c == '^';
        }
    }.f;
    if (text.len >= 2 and isAlign(text[1])) {
        s.fill = text[0];
        i = 1;
    }
    if (i < text.len and isAlign(text[i])) {
        s.alignment = switch (text[i]) {
            '<' => .left,
            '>' => .right,
            else => .center,
        };
        i += 1;
    }
    if (i < text.len and text[i] == '+') {
        s.plus = true;
        i += 1;
    }
    if (i < text.len and text[i] == '0') {
        s.zero = true;
        i += 1;
    }
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) s.width = s.width * 10 + (text[i] - '0');
    if (i < text.len and text[i] == '.') {
        i += 1;
        var p: usize = 0;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) p = p * 10 + (text[i] - '0');
        if (i == start) return null;
        s.precision = p;
    }
    if (i < text.len) {
        s.kind = text[i];
        i += 1;
    }
    return if (i == text.len) s else null;
}

fn formatted(vm: *Vm, w: *Writer, v: Value, spec_text: []const u8) Error!void {
    if (spec_text.len == 0) return value(w, v, false, 0) catch error.OutOfMemory;
    const s = parseSpec(spec_text) orelse return vm.fail("`{s}` is not a format spec; it is written like `>8`, `.2`, `05`, `x` or `+.3e`", .{spec_text});
    var buf: [512]u8 = undefined;
    var inner: Writer = .fixed(&buf);
    const numeric = v.tag == .int or v.tag == .float;
    (switch (s.kind) {
        'x', 'X', 'b', 'o', 'd' => blk: {
            if (v.tag != .int) return vm.fail("format `{c}` is for ints, not {s}", .{ s.kind, @import("types.zig").typeName(v) });
            const n = v.asInt();
            if (s.plus and n >= 0) inner.writeByte('+') catch {};
            break :blk switch (s.kind) {
                'x' => inner.print("{x}", .{n}),
                'X' => inner.print("{X}", .{n}),
                'b' => inner.print("{b}", .{n}),
                'o' => inner.print("{o}", .{n}),
                else => inner.print("{d}", .{n}),
            };
        },
        'e', 'f', '%' => blk: {
            const f = v.toFloat() orelse return vm.fail("format `{c}` is for numbers, not {s}", .{ s.kind, @import("types.zig").typeName(v) });
            const scaled = if (s.kind == '%') f * 100 else f;
            if (s.plus and scaled >= 0) inner.writeByte('+') catch {};
            const p = s.precision orelse 6;
            const r = if (s.kind != 'e')
                inner.print("{d:.[1]}", .{ scaled, p })
            else if (s.precision) |digits|
                inner.print("{e:.[1]}", .{ scaled, digits })
            else
                inner.print("{e}", .{scaled});
            if (s.kind == '%') inner.writeByte('%') catch {};
            break :blk r;
        },
        0, 's' => blk: {
            if (s.precision) |p| if (v.tag == .float) {
                if (s.plus and v.asFloat() >= 0) inner.writeByte('+') catch {};
                break :blk inner.print("{d:.[1]}", .{ v.asFloat(), p });
            };
            if (s.plus and numeric and (v.toFloat() orelse 0) >= 0) inner.writeByte('+') catch {};
            break :blk value(&inner, v, false, 0);
        },
        else => return vm.fail("`{c}` is not a format type; the types are d x X b o e f % s", .{s.kind}),
    }) catch {};
    const body = inner.buffered();
    const len = std.unicode.utf8CountCodepoints(body) catch body.len;
    const pad = s.width -| len;
    const alignment = s.alignment orelse if (numeric) @as(@TypeOf(s.alignment.?), .right) else .left;
    const fill: u8 = if (s.zero and s.alignment == null) '0' else s.fill;
    const before: usize = switch (alignment) {
        .left => 0,
        .right => pad,
        .center => pad / 2,
    };
    if (fill == '0' and body.len > 0 and (body[0] == '-' or body[0] == '+')) {
        w.writeByte(body[0]) catch return error.OutOfMemory;
        w.splatByteAll('0', before) catch return error.OutOfMemory;
        w.writeAll(body[1..]) catch return error.OutOfMemory;
    } else {
        w.splatByteAll(fill, before) catch return error.OutOfMemory;
        w.writeAll(body) catch return error.OutOfMemory;
    }
    w.splatByteAll(fill, pad - before) catch return error.OutOfMemory;
}

/// An f-string: each value formatted by its spec, in one string.
pub fn parts(vm: *Vm, values: []const Value, specs: [*]const Value) Error!Value {
    var out: Writer.Allocating = .init(vm.gpa);
    defer out.deinit();
    for (values, 0..) |v, i| {
        const spec = specs[i];
        const text = if (spec.tag == .string) spec.as(object.String).bytes() else "";
        try formatted(vm, &out.writer, v, text);
    }
    return vm.string(out.written());
}

pub fn toString(vm: *Vm, v: Value) Error!Value {
    if (v.tag == .string) return v;
    var buf: [256]u8 = undefined;
    var fixed: Writer = .fixed(&buf);
    if (value(&fixed, v, false, 0)) |_| return vm.string(fixed.buffered()) else |_| {}
    var out: Writer.Allocating = .init(vm.gpa);
    defer out.deinit();
    value(&out.writer, v, false, 0) catch return error.OutOfMemory;
    return vm.string(out.written());
}

pub fn withSpec(vm: *Vm, v: Value, spec: []const u8) Error!Value {
    var out: Writer.Allocating = .init(vm.gpa);
    defer out.deinit();
    try formatted(vm, &out.writer, v, spec);
    return vm.string(out.written());
}

test "floats keep their point, and specs pad and round" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try float(&w, 1.0);
    try w.writeByte(' ');
    try float(&w, 0.1);
    try w.writeByte(' ');
    try float(&w, 1e21);
    try std.testing.expectEqualStrings("1.0 0.1 1e21", w.buffered());
    const s = parseSpec(">8.2f").?;
    try std.testing.expectEqual(@as(usize, 8), s.width);
    try std.testing.expectEqual(@as(?usize, 2), s.precision);
    try std.testing.expectEqual(@as(u8, 'f'), s.kind);
    try std.testing.expect(parseSpec(".x") == null);
}
