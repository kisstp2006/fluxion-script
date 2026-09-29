// SPDX-License-Identifier: BSD-2-Clause

//! `color` methods: `c.lerp(to, 0.5)`, `c.darkened(0.2)`, `c.hex()`. Each
//! gives a new colour; the one it is called on stays as it is.

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const native = @import("native.zig");
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    const methods = .{
        .{ "lerp", lerp, 3, 3 },            .{ "darkened", darkened, 2, 2 },
        .{ "lightened", lightened, 2, 2 },  .{ "inverted", inverted, 1, 1 },
        .{ "with_alpha", withAlpha, 2, 2 }, .{ "hex", hex, 1, 2 },
    };
    inline for (methods) |m| try native.method(vm, .color, m[0], m[1], m[2], m[3]);
}

fn rgba(vm: *Vm, args: []const Value, i: usize) Error![4]f32 {
    if (args[i].tag != .color) return native.wrong(vm, i, "a color", args[i]);
    return args[i].as(object.Color).rgba;
}

fn amount(vm: *Vm, args: []const Value, i: usize) Error!f32 {
    return @floatCast(try native.float(vm, args, i));
}

fn lerp(vm: *Vm, args: []Value) Error!Value {
    const a: @Vector(4, f32) = try rgba(vm, args, 0);
    const b: @Vector(4, f32) = try rgba(vm, args, 1);
    const t: @Vector(4, f32) = @splat(try amount(vm, args, 2));
    const out: [4]f32 = a + (b - a) * t;
    return make.color(vm, out);
}

/// Each of red, green and blue `amount` of the way to black.
fn darkened(vm: *Vm, args: []Value) Error!Value {
    var c = try rgba(vm, args, 0);
    const by = try amount(vm, args, 1);
    for (c[0..3]) |*x| x.* *= 1 - by;
    return make.color(vm, c);
}

/// Each of red, green and blue `amount` of the way to white.
fn lightened(vm: *Vm, args: []Value) Error!Value {
    var c = try rgba(vm, args, 0);
    const by = try amount(vm, args, 1);
    for (c[0..3]) |*x| x.* += (1 - x.*) * by;
    return make.color(vm, c);
}

fn inverted(vm: *Vm, args: []Value) Error!Value {
    var c = try rgba(vm, args, 0);
    for (c[0..3]) |*x| x.* = 1 - x.*;
    return make.color(vm, c);
}

fn withAlpha(vm: *Vm, args: []Value) Error!Value {
    var c = try rgba(vm, args, 0);
    c[3] = try amount(vm, args, 1);
    return make.color(vm, c);
}

/// `"#rrggbbaa"`, or `"#rrggbb"` without the alpha: what `color()` reads
/// back.
fn hex(vm: *Vm, args: []Value) Error!Value {
    const c = try rgba(vm, args, 0);
    const alpha = if (args.len > 1) try native.boolean(vm, args, 1) else true;
    var buffer: [9]u8 = undefined;
    buffer[0] = '#';
    const parts: usize = if (alpha) 4 else 3;
    for (c[0..parts], 0..) |x, i| {
        const byte: u8 = @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
        _ = std.fmt.bufPrint(buffer[1 + 2 * i ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }
    return vm.string(buffer[0 .. 1 + 2 * parts]);
}
