// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const object = @import("object.zig");
const Obj = object.Obj;

pub const Tag = enum(u32) {
    null,
    bool,
    int,
    float,
    vec2,
    vec3,
    enum_value,
    /// A module variable whose initializer has not run yet.
    undefined,
    string,
    list,
    map,
    instance,
    function,
    native,
    method,
    class,
    enum_type,
    module,
    task,
    signal,
    @"error",
    color,
    handle,
    range,
    _,

    pub fn isObject(tag: Tag) bool {
        return @intFromEnum(tag) >= @intFromEnum(Tag.string);
    }
};

/// Sixteen bytes: a payload of up to twelve and a tag. Ints, floats, bools,
/// `vec2`, `vec3` and enum members never touch the heap.
pub const Value = extern struct {
    raw: u64,
    extra: u32,
    tag: Tag,

    pub const @"null": Value = .{ .raw = 0, .extra = 0, .tag = .null };
    pub const @"true": Value = .{ .raw = 1, .extra = 0, .tag = .bool };
    pub const @"false": Value = .{ .raw = 0, .extra = 0, .tag = .bool };
    pub const undef: Value = .{ .raw = 0, .extra = 0, .tag = .undefined };

    pub inline fn int(x: i64) Value {
        return .{ .raw = @bitCast(x), .extra = 0, .tag = .int };
    }

    pub inline fn float(x: f64) Value {
        return .{ .raw = @bitCast(x), .extra = 0, .tag = .float };
    }

    pub inline fn boolean(x: bool) Value {
        return .{ .raw = @intFromBool(x), .extra = 0, .tag = .bool };
    }

    pub inline fn vec2(x: f32, y: f32) Value {
        return .{ .raw = @bitCast([2]f32{ x, y }), .extra = 0, .tag = .vec2 };
    }

    pub inline fn vec3(x: f32, y: f32, z: f32) Value {
        return .{ .raw = @bitCast([2]f32{ x, y }), .extra = @bitCast(z), .tag = .vec3 };
    }

    pub inline fn fromObj(tag: Tag, o: *Obj) Value {
        return .{ .raw = @intFromPtr(o), .extra = 0, .tag = tag };
    }

    pub inline fn enumValue(type_obj: *Obj, index: u32) Value {
        return .{ .raw = @intFromPtr(type_obj), .extra = index, .tag = .enum_value };
    }

    pub inline fn is(v: Value, tag: Tag) bool {
        return v.tag == tag;
    }

    pub inline fn isNull(v: Value) bool {
        return v.tag == .null;
    }

    pub inline fn isObject(v: Value) bool {
        return v.tag.isObject();
    }

    /// The accessors assert the tag in safe builds: a typed instruction that
    /// meets a value of another type is a compiler bug, and this finds it.
    pub inline fn asInt(v: Value) i64 {
        std.debug.assert(v.tag == .int);
        return @bitCast(v.raw);
    }

    pub inline fn asFloat(v: Value) f64 {
        std.debug.assert(v.tag == .float);
        return @bitCast(v.raw);
    }

    pub inline fn asBool(v: Value) bool {
        std.debug.assert(v.tag == .bool);
        return v.raw != 0;
    }

    pub inline fn asVec2(v: Value) [2]f32 {
        return @bitCast(v.raw);
    }

    pub inline fn asVec3(v: Value) [3]f32 {
        const xy: [2]f32 = @bitCast(v.raw);
        return .{ xy[0], xy[1], @bitCast(v.extra) };
    }

    pub inline fn obj(v: Value) *Obj {
        std.debug.assert(v.tag.isObject() or v.tag == .enum_value);
        return @ptrFromInt(@as(usize, @intCast(v.raw)));
    }

    pub inline fn as(v: Value, comptime T: type) *T {
        return T.from(v.obj());
    }

    /// Numbers as a float, ints widened.
    pub inline fn toFloat(v: Value) ?f64 {
        return switch (v.tag) {
            .float => v.asFloat(),
            .int => @floatFromInt(v.asInt()),
            else => null,
        };
    }

    pub inline fn isNumber(v: Value) bool {
        return v.tag == .int or v.tag == .float;
    }

    /// The same value: identity for objects, bits for the rest, except that
    /// floats compare as numbers so `0.0 == -0.0` and NaN is not itself.
    pub fn identical(a: Value, b: Value) bool {
        if (a.tag != b.tag) return false;
        return switch (a.tag) {
            .float => a.asFloat() == b.asFloat(),
            .vec2 => std.meta.eql(a.asVec2(), b.asVec2()),
            .vec3 => std.meta.eql(a.asVec3(), b.asVec3()),
            .enum_value => a.raw == b.raw and a.extra == b.extra,
            else => a.raw == b.raw,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(Value) == 16);
}

test "values keep what they hold" {
    const testing = std.testing;
    try testing.expectEqual(@as(i64, -42), Value.int(-42).asInt());
    try testing.expectEqual(@as(f64, 1.5), Value.float(1.5).asFloat());
    try testing.expectEqual([2]f32{ 1, 2 }, Value.vec2(1, 2).asVec2());
    try testing.expectEqual([3]f32{ 1, 2, 3 }, Value.vec3(1, 2, 3).asVec3());
    try testing.expect(Value.boolean(true).asBool());
    try testing.expect(Value.float(0.0).identical(Value.float(-0.0)));
    try testing.expect(!Value.float(std.math.nan(f64)).identical(Value.float(std.math.nan(f64))));
    try testing.expect(!Value.int(1).identical(Value.float(1)));
}
