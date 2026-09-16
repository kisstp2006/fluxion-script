// SPDX-License-Identifier: BSD-2-Clause

//! `vec2` and `vec3` methods, one body for both through the vector length.

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const native = @import("native.zig");
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    inline for (.{ 2, 3 }) |n| {
        const kind: Vm.BuiltinType = if (n == 2) .vec2 else .vec3;
        const M = Methods(n);
        const common = .{
            .{ "length", M.length, 1, 1 },                 .{ "length_squared", M.lengthSquared, 1, 1 },
            .{ "normalized", M.normalized, 1, 1 },         .{ "dot", M.dot, 2, 2 },
            .{ "distance_to", M.distanceTo, 2, 2 },        .{ "distance_squared_to", M.distanceSquaredTo, 2, 2 },
            .{ "direction_to", M.directionTo, 2, 2 },      .{ "lerp", M.lerp, 3, 3 },
            .{ "abs", M.abs, 1, 1 },                       .{ "floor", M.floor, 1, 1 },
            .{ "ceil", M.ceil, 1, 1 },                     .{ "round", M.round, 1, 1 },
            .{ "min", M.min, 2, 2 },                       .{ "max", M.max, 2, 2 },
            .{ "clamp", M.clamp, 3, 3 },                   .{ "move_toward", M.moveToward, 3, 3 },
            .{ "limit_length", M.limitLength, 2, 2 },      .{ "is_zero", M.isZero, 1, 1 },
            .{ "cross", M.cross, 2, 2 },
        };
        inline for (common) |m| try native.method(vm, kind, m[0], m[1], m[2], m[3]);
    }
    try native.method(vm, .vec2, "angle", angle, 1, 1);
    try native.method(vm, .vec2, "angle_to", angleTo, 2, 2);
    try native.method(vm, .vec2, "rotated", rotated, 2, 2);
    try native.method(vm, .vec2, "orthogonal", orthogonal, 1, 1);
}

fn Methods(comptime n: usize) type {
    return struct {
        const V = @Vector(n, f32);

        fn get(vm: *Vm, args: []const Value, i: usize) Error!V {
            if (n == 2) return try native.vec2(vm, args, i);
            return try native.vec3(vm, args, i);
        }

        fn out(v: V) Value {
            const a: [n]f32 = v;
            return if (n == 2) .vec2(a[0], a[1]) else .vec3(a[0], a[1], a[2]);
        }

        fn scalar(vm: *Vm, args: []const Value, i: usize) Error!f32 {
            return @floatCast(try native.float(vm, args, i));
        }

        fn len(v: V) f32 {
            return @sqrt(@reduce(.Add, v * v));
        }

        fn length(vm: *Vm, args: []Value) Error!Value {
            return .float(len(try get(vm, args, 0)));
        }

        fn lengthSquared(vm: *Vm, args: []Value) Error!Value {
            const v = try get(vm, args, 0);
            return .float(@reduce(.Add, v * v));
        }

        fn normal(v: V) V {
            const l = len(v);
            return if (l == 0) v else v / @as(V, @splat(l));
        }

        fn normalized(vm: *Vm, args: []Value) Error!Value {
            return out(normal(try get(vm, args, 0)));
        }

        fn dot(vm: *Vm, args: []Value) Error!Value {
            return .float(@reduce(.Add, try get(vm, args, 0) * try get(vm, args, 1)));
        }

        fn distanceTo(vm: *Vm, args: []Value) Error!Value {
            return .float(len(try get(vm, args, 1) - try get(vm, args, 0)));
        }

        fn distanceSquaredTo(vm: *Vm, args: []Value) Error!Value {
            const d = try get(vm, args, 1) - try get(vm, args, 0);
            return .float(@reduce(.Add, d * d));
        }

        fn directionTo(vm: *Vm, args: []Value) Error!Value {
            return out(normal(try get(vm, args, 1) - try get(vm, args, 0)));
        }

        fn lerp(vm: *Vm, args: []Value) Error!Value {
            const a = try get(vm, args, 0);
            const b = try get(vm, args, 1);
            const t: V = @splat(try scalar(vm, args, 2));
            return out(a + (b - a) * t);
        }

        fn abs(vm: *Vm, args: []Value) Error!Value {
            return out(@abs(try get(vm, args, 0)));
        }

        fn floor(vm: *Vm, args: []Value) Error!Value {
            return out(@floor(try get(vm, args, 0)));
        }

        fn ceil(vm: *Vm, args: []Value) Error!Value {
            return out(@ceil(try get(vm, args, 0)));
        }

        fn round(vm: *Vm, args: []Value) Error!Value {
            return out(@round(try get(vm, args, 0)));
        }

        fn min(vm: *Vm, args: []Value) Error!Value {
            return out(@min(try get(vm, args, 0), try get(vm, args, 1)));
        }

        fn max(vm: *Vm, args: []Value) Error!Value {
            return out(@max(try get(vm, args, 0), try get(vm, args, 1)));
        }

        fn clamp(vm: *Vm, args: []Value) Error!Value {
            return out(@min(@max(try get(vm, args, 0), try get(vm, args, 1)), try get(vm, args, 2)));
        }

        fn moveToward(vm: *Vm, args: []Value) Error!Value {
            const from = try get(vm, args, 0);
            const to = try get(vm, args, 1);
            const delta = try scalar(vm, args, 2);
            const d = to - from;
            const l = len(d);
            if (l <= delta or l == 0) return out(to);
            return out(from + d / @as(V, @splat(l)) * @as(V, @splat(delta)));
        }

        fn limitLength(vm: *Vm, args: []Value) Error!Value {
            const v = try get(vm, args, 0);
            const limit = try scalar(vm, args, 1);
            const l = len(v);
            if (l <= limit or l == 0) return out(v);
            return out(v * @as(V, @splat(limit / l)));
        }

        fn isZero(vm: *Vm, args: []Value) Error!Value {
            return .boolean(@reduce(.And, @abs(try get(vm, args, 0)) < @as(V, @splat(1e-6))));
        }

        fn cross(vm: *Vm, args: []Value) Error!Value {
            const a: [n]f32 = try get(vm, args, 0);
            const b: [n]f32 = try get(vm, args, 1);
            if (n == 2) return .float(a[0] * b[1] - a[1] * b[0]);
            return .vec3(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]);
        }
    };
}

fn angle(vm: *Vm, args: []Value) Error!Value {
    const v = try native.vec2(vm, args, 0);
    return .float(std.math.atan2(v[1], v[0]));
}

fn angleTo(vm: *Vm, args: []Value) Error!Value {
    const a = try native.vec2(vm, args, 0);
    const b = try native.vec2(vm, args, 1);
    return .float(std.math.atan2(a[0] * b[1] - a[1] * b[0], a[0] * b[0] + a[1] * b[1]));
}

fn rotated(vm: *Vm, args: []Value) Error!Value {
    const v = try native.vec2(vm, args, 0);
    const t = try native.float(vm, args, 1);
    const c: f32 = @floatCast(@cos(t));
    const s: f32 = @floatCast(@sin(t));
    return .vec2(v[0] * c - v[1] * s, v[0] * s + v[1] * c);
}

fn orthogonal(vm: *Vm, args: []Value) Error!Value {
    const v = try native.vec2(vm, args, 0);
    return .vec2(v[1], -v[0]);
}
