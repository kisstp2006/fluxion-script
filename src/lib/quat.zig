// SPDX-License-Identifier: BSD-2-Clause

//! `quat`: a rotation in 3D, `x`, `y`, `z` and `w`. Made with `quat()` (no
//! turn), `quat(euler)` from pitch, yaw and roll in radians, `quat(axis,
//! angle)`, or `quat(x, y, z, w)`. `a * b` turns by `b` and then by `a`;
//! `q * v` turns a `vec3`. Each method gives a new value; the one it is
//! called on stays as it is.
//!
//! Rotations are right-handed - a positive angle turns anticlockwise seen
//! from the far end of the axis - and Euler angles are applied roll first,
//! then pitch, then yaw: `yaw * pitch * roll`, the order a camera and a
//! character want.

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const native = @import("native.zig");
const Error = native.Error;

pub const Q = [4]f32;
pub const V = [3]f32;

pub const identity: Q = .{ 0, 0, 0, 1 };

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    try native.define(vm, "quat", construct, 0, 4);
    const methods = .{
        .{ "euler", euler, 1, 1 },           .{ "inverse", inverse, 1, 1 },
        .{ "normalized", normalized, 1, 1 }, .{ "length", length, 1, 1 },
        .{ "dot", dotMethod, 2, 2 },         .{ "slerp", slerpMethod, 3, 3 },
        .{ "rotate", rotateMethod, 2, 2 },   .{ "angle", angle, 1, 1 },
        .{ "axis", axis, 1, 1 },             .{ "angle_to", angleTo, 2, 2 },
    };
    inline for (methods) |m| try native.method(vm, .quat, m[0], m[1], m[2], m[3]);
}

// -- the maths, shared with the `*` operator --------------------------------

pub fn mul(a: Q, b: Q) Q {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}

fn cross(a: V, b: V) V {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub fn rotate(q: Q, v: V) V {
    const u: V = .{ q[0], q[1], q[2] };
    const c = cross(u, v);
    const t: V = .{ c[0] * 2, c[1] * 2, c[2] * 2 };
    const ut = cross(u, t);
    return .{ v[0] + t[0] * q[3] + ut[0], v[1] + t[1] * q[3] + ut[1], v[2] + t[2] * q[3] + ut[2] };
}

fn dot(a: Q, b: Q) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

fn norm(q: Q) Q {
    const l = @sqrt(dot(q, q));
    if (l == 0) return identity;
    return .{ q[0] / l, q[1] / l, q[2] / l, q[3] / l };
}

pub fn fromAxisAngle(along: V, radians: f32) Q {
    const l = @sqrt(along[0] * along[0] + along[1] * along[1] + along[2] * along[2]);
    if (l == 0) return identity;
    const s = @sin(radians * 0.5) / l;
    return .{ along[0] * s, along[1] * s, along[2] * s, @cos(radians * 0.5) };
}

/// Pitch about +x, yaw about +y, roll about +z: `yaw * pitch * roll`.
pub fn fromEuler(e: V) Q {
    return mul(mul(fromAxisAngle(.{ 0, 1, 0 }, e[1]), fromAxisAngle(.{ 1, 0, 0 }, e[0])), fromAxisAngle(.{ 0, 0, 1 }, e[2]));
}

/// `fromEuler` undone: pitch, yaw and roll. Looking straight up or down,
/// yaw and roll turn about the same axis, and the roll is taken as nought.
pub fn toEuler(q: Q) V {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    const m12 = 2 * (y * z - w * x);
    const sin_pitch = std.math.clamp(-m12, -1, 1);
    const pitch = std.math.asin(sin_pitch);
    if (@abs(sin_pitch) > 0.99999) {
        const m20 = 2 * (x * z - w * y);
        const m00 = 1 - 2 * (y * y + z * z);
        return .{ pitch, std.math.atan2(-m20, m00), 0 };
    }
    const m02 = 2 * (x * z + w * y);
    const m22 = 1 - 2 * (x * x + y * y);
    const m10 = 2 * (x * y + w * z);
    const m11 = 1 - 2 * (x * x + z * z);
    return .{ pitch, std.math.atan2(m02, m22), std.math.atan2(m10, m11) };
}

pub fn slerp(a: Q, b_in: Q, t: f32) Q {
    var b = b_in;
    var cosine = dot(a, b);
    if (cosine < 0) {
        b = .{ -b[0], -b[1], -b[2], -b[3] };
        cosine = -cosine;
    }
    if (cosine > 0.9995) {
        return norm(.{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t });
    }
    const theta = std.math.acos(std.math.clamp(cosine, -1, 1));
    const s = @sin(theta);
    const wa = @sin((1 - t) * theta) / s;
    const wb = @sin(t * theta) / s;
    return norm(.{ a[0] * wa + b[0] * wb, a[1] * wa + b[1] * wb, a[2] * wa + b[2] * wb, a[3] * wa + b[3] * wb });
}

// -- the script's calls ------------------------------------------------------

pub fn of(vm: *Vm, args: []const Value, i: usize) Error!Q {
    if (args[i].tag != .quat) return native.wrong(vm, i, "a quat", args[i]);
    return args[i].as(object.Quat).xyzw;
}

fn number(vm: *Vm, args: []const Value, i: usize) Error!f32 {
    return @floatCast(try native.float(vm, args, i));
}

/// `quat()`, `quat(euler)`, `quat(axis, angle)` or `quat(x, y, z, w)`.
fn construct(vm: *Vm, args: []Value) Error!Value {
    return switch (args.len) {
        0 => make.quat(vm, identity),
        1 => make.quat(vm, fromEuler(try native.vec3(vm, args, 0))),
        2 => make.quat(vm, fromAxisAngle(try native.vec3(vm, args, 0), try number(vm, args, 1))),
        4 => make.quat(vm, .{ try number(vm, args, 0), try number(vm, args, 1), try number(vm, args, 2), try number(vm, args, 3) }),
        else => vm.fail("quat() takes nothing, an euler vec3, an axis and an angle, or x y z w", .{}),
    };
}

fn euler(vm: *Vm, args: []Value) Error!Value {
    const e = toEuler(try of(vm, args, 0));
    return .vec3(e[0], e[1], e[2]);
}

fn inverse(vm: *Vm, args: []Value) Error!Value {
    const q = try of(vm, args, 0);
    const d = dot(q, q);
    if (d == 0) return make.quat(vm, identity);
    return make.quat(vm, .{ -q[0] / d, -q[1] / d, -q[2] / d, q[3] / d });
}

fn normalized(vm: *Vm, args: []Value) Error!Value {
    return make.quat(vm, norm(try of(vm, args, 0)));
}

fn length(vm: *Vm, args: []Value) Error!Value {
    const q = try of(vm, args, 0);
    return .float(@sqrt(dot(q, q)));
}

fn dotMethod(vm: *Vm, args: []Value) Error!Value {
    return .float(dot(try of(vm, args, 0), try of(vm, args, 1)));
}

fn slerpMethod(vm: *Vm, args: []Value) Error!Value {
    return make.quat(vm, slerp(try of(vm, args, 0), try of(vm, args, 1), try number(vm, args, 2)));
}

fn rotateMethod(vm: *Vm, args: []Value) Error!Value {
    const v = rotate(try of(vm, args, 0), try native.vec3(vm, args, 1));
    return .vec3(v[0], v[1], v[2]);
}

/// How far it turns, in radians, from 0 to a whole turn.
fn angle(vm: *Vm, args: []Value) Error!Value {
    const q = norm(try of(vm, args, 0));
    return .float(2 * std.math.acos(std.math.clamp(q[3], -1, 1)));
}

/// What it turns about; +x for no turn at all.
fn axis(vm: *Vm, args: []Value) Error!Value {
    const q = norm(try of(vm, args, 0));
    const s = @sqrt(@max(0, 1 - q[3] * q[3]));
    if (s < 1e-6) return .vec3(1, 0, 0);
    return .vec3(q[0] / s, q[1] / s, q[2] / s);
}

/// The smallest angle between two orientations, in radians.
fn angleTo(vm: *Vm, args: []Value) Error!Value {
    const d = @abs(dot(norm(try of(vm, args, 0)), norm(try of(vm, args, 1))));
    return .float(2 * std.math.acos(std.math.clamp(d, -1, 1)));
}

const testing = std.testing;

test "a quarter turn about +y takes -z to -x, and the euler angles come back" {
    const q = fromAxisAngle(.{ 0, 1, 0 }, std.math.pi / 2.0);
    const v = rotate(q, .{ 0, 0, -1 });
    try testing.expectApproxEqAbs(@as(f32, -1), v[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), v[2], 1e-5);
    const e = toEuler(fromEuler(.{ 0.3, -1.2, 0.5 }));
    try testing.expectApproxEqAbs(@as(f32, 0.3), e[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -1.2), e[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), e[2], 1e-4);
}
