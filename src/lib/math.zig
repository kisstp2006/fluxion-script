// SPDX-License-Identifier: BSD-2-Clause

//! `const math = @import("math");`

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const native = @import("native.zig");
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    const m = try make.module(vm, try vm.intern("math"));
    try vm.native_modules.put(vm.gpa, try vm.gpa.dupe(u8, "math"), m);
    m.state = .ready;
    try native.member(vm, m, "pi", .float(std.math.pi));
    try native.member(vm, m, "tau", .float(std.math.tau));
    try native.member(vm, m, "e", .float(std.math.e));
    try native.member(vm, m, "inf", .float(std.math.inf(f64)));
    try native.member(vm, m, "nan", .float(std.math.nan(f64)));
    try native.member(vm, m, "epsilon", .float(std.math.floatEps(f64)));
    try native.member(vm, m, "max_int", .int(std.math.maxInt(i64)));
    try native.member(vm, m, "min_int", .int(std.math.minInt(i64)));
    inline for (@typeInfo(UnaryOp).@"enum".fields) |field| {
        try native.function(vm, m, field.name, Unary(@enumFromInt(field.value)).call, 1, 1);
    }
    const functions = .{
        .{ "sqrt", sqrt, 1, 1 },          .{ "pow", pow, 2, 2 },
        .{ "log", log, 1, 2 },            .{ "atan2", atan2, 2, 2 },
        .{ "floor", floor, 1, 1 },        .{ "ceil", ceil, 1, 1 },
        .{ "round", round, 1, 1 },        .{ "trunc", trunc, 1, 1 },
        .{ "fract", fract, 1, 1 },        .{ "sign", sign, 1, 1 },
        .{ "lerp", lerp, 3, 3 },          .{ "inverse_lerp", inverseLerp, 3, 3 },
        .{ "remap", remap, 5, 5 },        .{ "smoothstep", smoothstep, 3, 3 },
        .{ "deg_to_rad", degToRad, 1, 1 }, .{ "rad_to_deg", radToDeg, 1, 1 },
        .{ "is_nan", isNan, 1, 1 },       .{ "is_inf", isInf, 1, 1 },
        .{ "approx_eq", approxEq, 2, 3 }, .{ "mod", mod, 2, 2 },
        .{ "wrap", wrap, 3, 3 },          .{ "move_toward", moveToward, 3, 3 },
        .{ "random", random, 0, 0 },      .{ "random_range", randomRange, 2, 2 },
        .{ "random_int", randomInt, 2, 2 }, .{ "seed", seed, 1, 1 },
    };
    inline for (functions) |f| try native.function(vm, m, f[0], f[1], f[2], f[3]);
}

const UnaryOp = enum { sin, cos, tan, asin, acos, atan, exp, log2, log10, sinh, cosh, tanh };

fn Unary(comptime op: UnaryOp) type {
    return struct {
        fn call(vm: *Vm, args: []Value) Error!Value {
            const x = try native.float(vm, args, 0);
            return .float(switch (op) {
                .sin => @sin(x),
                .cos => @cos(x),
                .tan => @tan(x),
                .asin => std.math.asin(x),
                .acos => std.math.acos(x),
                .atan => std.math.atan(x),
                .exp => @exp(x),
                .log2 => @log2(x),
                .log10 => @log10(x),
                .sinh => std.math.sinh(x),
                .cosh => std.math.cosh(x),
                .tanh => std.math.tanh(x),
            });
        }
    };
}

fn num(vm: *Vm, args: []Value, i: usize) Error!f64 {
    return native.float(vm, args, i);
}

fn sqrt(vm: *Vm, args: []Value) Error!Value {
    return .float(@sqrt(try num(vm, args, 0)));
}

fn pow(vm: *Vm, args: []Value) Error!Value {
    if (args[0].tag == .int and args[1].tag == .int) {
        const base = args[0].asInt();
        const exp = args[1].asInt();
        if (exp < 0) {
            // An int to a negative power is an int only for 1 and -1.
            if (base == 1) return .int(1);
            if (base == -1) return .int(if (@mod(exp, 2) == 0) 1 else -1);
            return vm.fail("{d} to the power {d} is not an int; for the fraction, write pow({d}.0, {d})", .{ base, exp, base, exp });
        }
        const r = std.math.powi(i64, base, exp) catch return vm.fail("{d} to the power {d} does not fit in an int", .{ base, exp });
        return .int(r);
    }
    return .float(std.math.pow(f64, try num(vm, args, 0), try num(vm, args, 1)));
}

fn log(vm: *Vm, args: []Value) Error!Value {
    const x = try num(vm, args, 0);
    if (args.len == 2) return .float(@log(x) / @log(try num(vm, args, 1)));
    return .float(@log(x));
}

fn atan2(vm: *Vm, args: []Value) Error!Value {
    return .float(std.math.atan2(try num(vm, args, 0), try num(vm, args, 1)));
}

/// A float rounded to an int; one that has no int - NaN, an infinity, or
/// past the ints' range - is a mistake, as it is for `int()`.
fn rounded(vm: *Vm, args: []Value, comptime name: []const u8, comptime f: fn (f64) f64) Error!Value {
    if (args[0].tag == .int) return args[0];
    const x = try num(vm, args, 0);
    const r = f(x);
    if (std.math.isNan(r) or std.math.isInf(r) or @abs(r) >= 9.2e18) return vm.fail("math." ++ name ++ "({d}) has no int value", .{x});
    return .int(@intFromFloat(r));
}

fn floor(vm: *Vm, args: []Value) Error!Value {
    return rounded(vm, args, "floor", struct {
        fn f(x: f64) f64 {
            return @floor(x);
        }
    }.f);
}

fn ceil(vm: *Vm, args: []Value) Error!Value {
    return rounded(vm, args, "ceil", struct {
        fn f(x: f64) f64 {
            return @ceil(x);
        }
    }.f);
}

fn round(vm: *Vm, args: []Value) Error!Value {
    return rounded(vm, args, "round", struct {
        fn f(x: f64) f64 {
            return @round(x);
        }
    }.f);
}

fn trunc(vm: *Vm, args: []Value) Error!Value {
    return rounded(vm, args, "trunc", struct {
        fn f(x: f64) f64 {
            return @trunc(x);
        }
    }.f);
}

fn fract(vm: *Vm, args: []Value) Error!Value {
    const x = try num(vm, args, 0);
    return .float(x - @floor(x));
}

fn sign(vm: *Vm, args: []Value) Error!Value {
    if (args[0].tag == .int) return .int(std.math.sign(args[0].asInt()));
    return .float(std.math.sign(try num(vm, args, 0)));
}

fn lerp(vm: *Vm, args: []Value) Error!Value {
    const a = try num(vm, args, 0);
    const b = try num(vm, args, 1);
    return .float(a + (b - a) * try num(vm, args, 2));
}

fn inverseLerp(vm: *Vm, args: []Value) Error!Value {
    const a = try num(vm, args, 0);
    const b = try num(vm, args, 1);
    if (a == b) return .float(0);
    return .float((try num(vm, args, 2) - a) / (b - a));
}

fn remap(vm: *Vm, args: []Value) Error!Value {
    const x = try num(vm, args, 0);
    const a = try num(vm, args, 1);
    const b = try num(vm, args, 2);
    const c = try num(vm, args, 3);
    const d = try num(vm, args, 4);
    if (a == b) return .float(c);
    return .float(c + (x - a) / (b - a) * (d - c));
}

fn smoothstep(vm: *Vm, args: []Value) Error!Value {
    const a = try num(vm, args, 0);
    const b = try num(vm, args, 1);
    const x = try num(vm, args, 2);
    if (a == b) return .float(if (x < a) 0 else 1);
    const t = std.math.clamp((x - a) / (b - a), 0, 1);
    return .float(t * t * (3 - 2 * t));
}

fn degToRad(vm: *Vm, args: []Value) Error!Value {
    return .float(std.math.degreesToRadians(try num(vm, args, 0)));
}

fn radToDeg(vm: *Vm, args: []Value) Error!Value {
    return .float(std.math.radiansToDegrees(try num(vm, args, 0)));
}

fn isNan(vm: *Vm, args: []Value) Error!Value {
    return .boolean(std.math.isNan(try num(vm, args, 0)));
}

fn isInf(vm: *Vm, args: []Value) Error!Value {
    return .boolean(std.math.isInf(try num(vm, args, 0)));
}

fn approxEq(vm: *Vm, args: []Value) Error!Value {
    const tolerance = if (args.len > 2) try num(vm, args, 2) else 1e-6;
    return .boolean(std.math.approxEqAbs(f64, try num(vm, args, 0), try num(vm, args, 1), tolerance));
}

/// The remainder that keeps the sign of the divisor: `mod(-1, 5) == 4`.
fn mod(vm: *Vm, args: []Value) Error!Value {
    if (args[0].tag == .int and args[1].tag == .int) {
        const b = args[1].asInt();
        if (b == 0) return vm.fail("division by zero", .{});
        return .int(@mod(args[0].asInt(), b));
    }
    const b = try num(vm, args, 1);
    return .float(@mod(try num(vm, args, 0), b));
}

fn wrap(vm: *Vm, args: []Value) Error!Value {
    if (args[0].tag == .int and args[1].tag == .int and args[2].tag == .int) {
        const lo = args[1].asInt();
        const span = args[2].asInt() - lo;
        if (span <= 0) return vm.fail("wrap() needs a range that is not empty", .{});
        return .int(lo + @mod(args[0].asInt() - lo, span));
    }
    const lo = try num(vm, args, 1);
    const span = try num(vm, args, 2) - lo;
    if (!(span > 0)) return vm.fail("wrap() needs a range that is not empty", .{});
    return .float(lo + @mod(try num(vm, args, 0) - lo, span));
}

fn moveToward(vm: *Vm, args: []Value) Error!Value {
    const from = try num(vm, args, 0);
    const to = try num(vm, args, 1);
    const delta = try num(vm, args, 2);
    if (@abs(to - from) <= delta) return .float(to);
    return .float(from + std.math.sign(to - from) * delta);
}

fn random(vm: *Vm, _: []Value) Error!Value {
    return .float(vm.rng.random().float(f64));
}

fn randomRange(vm: *Vm, args: []Value) Error!Value {
    const a = try num(vm, args, 0);
    const b = try num(vm, args, 1);
    return .float(a + (b - a) * vm.rng.random().float(f64));
}

fn randomInt(vm: *Vm, args: []Value) Error!Value {
    const a = try native.int(vm, args, 0);
    const b = try native.int(vm, args, 1);
    if (a > b) return vm.fail("random_int({d}, {d}): the low end is above the high end", .{ a, b });
    return .int(vm.rng.random().intRangeAtMost(i64, a, b));
}

fn seed(vm: *Vm, args: []Value) Error!Value {
    vm.rng = .init(@bitCast(try native.int(vm, args, 0)));
    return .null;
}
