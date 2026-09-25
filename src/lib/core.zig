// SPDX-License-Identifier: BSD-2-Clause

//! The names every module has without importing anything.

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const format = @import("../vm/format.zig");
const types = @import("../vm/types.zig");
const ops = @import("../vm/ops.zig");
const text = @import("fluxion_text");
const native = @import("native.zig");
const color_names = @import("color_names.zig");
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    try native.define(vm, "print", print, 0, null);
    try native.define(vm, "assert", assert, 1, 2);
    try native.define(vm, "panic", panicFn, 1, 1);
    try native.define(vm, "str", str, 1, 1);
    try native.define(vm, "int", int, 1, 1);
    try native.define(vm, "float", float, 1, 1);
    try native.define(vm, "typeof", typeOf, 1, 1);
    try native.define(vm, "vec2", vec2, 0, 2);
    try native.define(vm, "vec3", vec3, 0, 3);
    try native.define(vm, "color", color, 1, 4);
    try native.define(vm, "hsv", hsv, 3, 4);
    try native.define(vm, "wait", wait, 1, 1);
    try native.define(vm, "min", min, 1, null);
    try native.define(vm, "max", max, 1, null);
    try native.define(vm, "abs", abs, 1, 1);
    try native.define(vm, "clamp", clamp, 3, 3);
    try native.define(vm, "range", range, 1, 3);
    try @import("string.zig").install(vm);
    try @import("list.zig").install(vm);
    try @import("map.zig").install(vm);
    try @import("vec.zig").install(vm);
    try @import("signal.zig").install(vm);
    try @import("math.zig").install(vm);
    try @import("json.zig").install(vm);
}

fn print(vm: *Vm, args: []Value) Error!Value {
    const out = vm.output() orelse return .null;
    for (args, 0..) |v, i| {
        if (i > 0) out.writeByte(' ') catch {};
        format.value(out, v, false, 0) catch {};
    }
    out.writeByte('\n') catch {};
    return .null;
}

fn assert(vm: *Vm, args: []Value) Error!Value {
    const ok = try native.boolean(vm, args, 0);
    if (ok) return .null;
    if (native.optional(args, 1)) |m| {
        const s = try format.toString(vm, m);
        return vm.fail("assertion failed: {s}", .{s.as(object.String).bytes()});
    }
    return vm.fail("assertion failed", .{});
}

fn panicFn(vm: *Vm, args: []Value) Error!Value {
    const s = try format.toString(vm, args[0]);
    return vm.fail("{s}", .{s.as(object.String).bytes()});
}

fn str(vm: *Vm, args: []Value) Error!Value {
    return format.toString(vm, args[0]);
}

fn parseFailed(vm: *Vm, name: []const u8, s: *object.String) Error!Value {
    var buf: [128]u8 = undefined;
    const shown = s.bytes()[0..@min(s.len, 64)];
    const message = std.fmt.bufPrint(&buf, "\"{s}\" is not a number", .{shown}) catch "not a number";
    return make.errorText(vm, name, message);
}

fn int(vm: *Vm, args: []Value) Error!Value {
    const v = args[0];
    return switch (v.tag) {
        .int => v,
        .float => {
            const f = v.asFloat();
            if (std.math.isNan(f) or std.math.isInf(f) or @abs(f) >= 9.2e18) return vm.fail("{d} does not fit in an int", .{f});
            return .int(@intFromFloat(@trunc(f)));
        },
        .bool => .int(@intFromBool(v.asBool())),
        .enum_value => blk: {
            const e = object.EnumType.from(v.obj());
            break :blk .int(e.values[v.extra]);
        },
        .string => {
            const s = v.as(object.String);
            const trimmed = std.mem.trim(u8, s.bytes(), " \t\r\n");
            const n = text.number.parseInt(i64, trimmed, .{}) catch return parseFailed(vm, "InvalidInt", s);
            return .int(n);
        },
        else => vm.fail("int() cannot convert {s}", .{types.typeName(v)}),
    };
}

fn float(vm: *Vm, args: []Value) Error!Value {
    const v = args[0];
    return switch (v.tag) {
        .float => v,
        .int => .float(@floatFromInt(v.asInt())),
        .string => {
            const s = v.as(object.String);
            const trimmed = std.mem.trim(u8, s.bytes(), " \t\r\n");
            const f = text.number.parseFloat(f64, trimmed, .{}) catch return parseFailed(vm, "InvalidFloat", s);
            return .float(f);
        },
        else => vm.fail("float() cannot convert {s}", .{types.typeName(v)}),
    };
}

fn typeOf(vm: *Vm, args: []Value) Error!Value {
    return vm.string(types.typeName(args[0]));
}

fn vec2(vm: *Vm, args: []Value) Error!Value {
    if (args.len == 0) return .vec2(0, 0);
    if (args.len == 1) {
        const s: f32 = @floatCast(try native.float(vm, args, 0));
        return .vec2(s, s);
    }
    return .vec2(@floatCast(try native.float(vm, args, 0)), @floatCast(try native.float(vm, args, 1)));
}

fn vec3(vm: *Vm, args: []Value) Error!Value {
    if (args.len == 0) return .vec3(0, 0, 0);
    if (args.len == 1) {
        if (args[0].tag == .vec2) {
            const xy = args[0].asVec2();
            return .vec3(xy[0], xy[1], 0);
        }
        const s: f32 = @floatCast(try native.float(vm, args, 0));
        return .vec3(s, s, s);
    }
    if (args.len == 2) {
        const xy = try native.vec2(vm, args, 0);
        return .vec3(xy[0], xy[1], @floatCast(try native.float(vm, args, 1)));
    }
    return .vec3(@floatCast(try native.float(vm, args, 0)), @floatCast(try native.float(vm, args, 1)), @floatCast(try native.float(vm, args, 2)));
}

fn color(vm: *Vm, args: []Value) Error!Value {
    if (args.len == 1) {
        if (args[0].tag == .string) {
            const s = args[0].as(object.String).bytes();
            const rgba = colorOf(s) orelse return vm.fail("\"{s}\" is not a colour: write it as \"#RRGGBB\", \"#RRGGBBAA\", \"#RGB\" or a name, as \"royalblue\"", .{s});
            return make.color(vm, .{
                @as(f32, @floatFromInt((rgba >> 24) & 0xFF)) / 255,
                @as(f32, @floatFromInt((rgba >> 16) & 0xFF)) / 255,
                @as(f32, @floatFromInt((rgba >> 8) & 0xFF)) / 255,
                @as(f32, @floatFromInt(rgba & 0xFF)) / 255,
            });
        }
        const g: f32 = @floatCast(try native.float(vm, args, 0));
        return make.color(vm, .{ g, g, g, 1 });
    }
    if (args.len == 2) return vm.fail("color() takes a hex string, a grey, r g b, or r g b a", .{});
    var c: [4]f32 = .{ 0, 0, 0, 1 };
    for (args, 0..) |_, i| c[i] = @floatCast(try native.float(vm, args, i));
    return make.color(vm, c);
}

/// A colour written as text, as 0xRRGGBBAA: `"#RRGGBB"`, `"#RRGGBBAA"`,
/// `"#RGB"`, `"#RGBA"`, or one of the web's names.
fn colorOf(s: []const u8) ?u32 {
    if (s.len == 0 or s[0] != '#') return (@as(u32, color_names.find(s) orelse return null) << 8) | 0xFF;
    const hex = s[1..];
    for (hex) |c| if (!std.ascii.isHex(c)) return null;
    const n = std.fmt.parseInt(u32, hex, 16) catch return null;
    return switch (hex.len) {
        3 => doubled((n << 4) | 0xF),
        4 => doubled(n),
        6 => (n << 8) | 0xFF,
        8 => n,
        else => null,
    };
}

/// `0xRGBA` as `0xRRGGBBAA`.
fn doubled(n: u32) u32 {
    var out: u32 = 0;
    var i: u5 = 0;
    while (i < 4) : (i += 1) out |= ((n >> (i * 4)) & 0xF) * 0x11 << (i * 8);
    return out;
}

/// A colour from its hue in degrees, any way round, and its saturation,
/// value and alpha from 0 to 1.
fn hsv(vm: *Vm, args: []Value) Error!Value {
    var n: [4]f32 = .{ 0, 0, 0, 1 };
    for (args, 0..) |_, i| n[i] = @floatCast(try native.float(vm, args, i));
    const hue = @mod(n[0], 360) / 60;
    const s = std.math.clamp(n[1], 0, 1);
    const v = std.math.clamp(n[2], 0, 1);
    const sector: u32 = @min(@as(u32, @intFromFloat(@floor(hue))), 5);
    const f = hue - @as(f32, @floatFromInt(sector));
    const p = v * (1 - s);
    const q = v * (1 - s * f);
    const t = v * (1 - s * (1 - f));
    const rgb: [3]f32 = switch (sector) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
    return make.color(vm, .{ rgb[0], rgb[1], rgb[2], std.math.clamp(n[3], 0, 1) });
}

fn wait(vm: *Vm, args: []Value) Error!Value {
    const seconds = try native.float(vm, args, 0);
    if (!(seconds >= 0)) return vm.fail("wait() needs a time of zero seconds or more", .{});
    return .float(seconds);
}

fn pick(vm: *Vm, args: []Value, comptime want_less: bool) Error!Value {
    const items: []const Value = if (args.len == 1 and args[0].tag == .list) args[0].as(object.List).items.items else args;
    if (items.len == 0) return vm.fail("{s}() of nothing", .{if (want_less) "min" else "max"});
    var best = items[0];
    var floats = best.tag == .float;
    for (items[1..]) |v| {
        const better = if (want_less) try ops.compare(vm, .lt, v, best) else try ops.compare(vm, .lt, best, v);
        if (better) best = v;
        floats = floats or v.tag == .float;
    }
    // Ints among floats give a float, as the compiler says they do.
    if (floats and best.tag == .int) return .float(@floatFromInt(best.asInt()));
    return best;
}

fn min(vm: *Vm, args: []Value) Error!Value {
    return pick(vm, args, true);
}

fn max(vm: *Vm, args: []Value) Error!Value {
    return pick(vm, args, false);
}

fn abs(vm: *Vm, args: []Value) Error!Value {
    const v = args[0];
    return switch (v.tag) {
        .int => if (v.asInt() == std.math.minInt(i64)) vm.fail("abs of the smallest int does not fit", .{}) else .int(@intCast(@abs(v.asInt()))),
        .float => .float(@abs(v.asFloat())),
        .vec2 => .vec2(@abs(v.asVec2()[0]), @abs(v.asVec2()[1])),
        .vec3 => .vec3(@abs(v.asVec3()[0]), @abs(v.asVec3()[1]), @abs(v.asVec3()[2])),
        else => native.wrong(vm, 0, "a number or a vector", v),
    };
}

fn clamp(vm: *Vm, args: []Value) Error!Value {
    if (args[0].tag == .int and args[1].tag == .int and args[2].tag == .int) {
        const lo = args[1].asInt();
        const hi = args[2].asInt();
        if (lo > hi) return vm.fail("clamp() between {d} and {d}: the low end is above the high end", .{ lo, hi });
        return .int(std.math.clamp(args[0].asInt(), lo, hi));
    }
    const x = try native.float(vm, args, 0);
    const lo = try native.float(vm, args, 1);
    const hi = try native.float(vm, args, 2);
    if (lo > hi) return vm.fail("clamp() between {d} and {d}: the low end is above the high end", .{ lo, hi });
    return .float(std.math.clamp(x, lo, hi));
}

/// `range(n)`, `range(a, b)`, `range(a, b, step)`: a list of ints, for the
/// places a loop's `a..b` does not reach.
fn range(vm: *Vm, args: []Value) Error!Value {
    var from: i64 = 0;
    var to: i64 = try native.int(vm, args, 0);
    var step: i64 = 1;
    if (args.len >= 2) {
        from = to;
        to = try native.int(vm, args, 1);
    }
    if (args.len == 3) step = try native.int(vm, args, 2);
    if (step == 0) return vm.fail("range() with a step of 0 never ends", .{});
    const span = if (step > 0) @max(0, to - from) else @max(0, from - to);
    const count: usize = @intCast(@divFloor(span + @as(i64, @intCast(@abs(step))) - 1, @as(i64, @intCast(@abs(step)))));
    if (count > 1 << 28) return vm.fail("range() of {d} items is too long", .{count});
    const l = try make.list(vm, count, .int);
    var x = from;
    for (0..count) |_| {
        l.items.appendAssumeCapacity(.int(x));
        x += step;
    }
    return .fromObj(.list, &l.obj);
}

test {
    _ = color_names;
}
