// SPDX-License-Identifier: BSD-2-Clause

//! Zig functions as natives, and Zig values as Flux values, converted by
//! their types at compile time: `vm.defineFn("clamp01", clamp01)` for any
//! `fn clamp01(x: f64) f64`, a Zig error becoming a Flux `error.Name`.

const std = @import("std");

const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const object = @import("vm/object.zig");
const make = @import("vm/make.zig");
const types = @import("vm/types.zig");
const Error = Vm.Error;

fn argName(vm: *Vm) []const u8 {
    return if (vm.current_native) |n| n.name else "the native";
}

fn wrong(vm: *Vm, index: usize, wanted: []const u8, got: Value) Error {
    @branchHint(.cold);
    return vm.fail("argument {d} of `{s}` must be {s}, not {s}", .{ index + 1, argName(vm), wanted, types.typeName(got) });
}

/// A Flux value as a `T`, for argument `index` of a native.
pub fn fromValue(comptime T: type, vm: *Vm, v: Value, index: usize) Error!T {
    if (T == Value) return v;
    if (T == []const u8) {
        if (v.tag != .string) return wrong(vm, index, "a string", v);
        return v.as(object.String).bytes();
    }
    switch (@typeInfo(T)) {
        .int => |info| {
            if (v.tag != .int) return wrong(vm, index, "an int", v);
            return std.math.cast(T, v.asInt()) orelse
                vm.fail("argument {d} of `{s}` is {d}, which does not fit in {s}{d}", .{ index + 1, argName(vm), v.asInt(), if (info.signedness == .signed) "i" else "u", info.bits });
        },
        .float => return @floatCast(v.toFloat() orelse return wrong(vm, index, "a number", v)),
        .bool => {
            if (v.tag != .bool) return wrong(vm, index, "a bool", v);
            return v.asBool();
        },
        .optional => |o| return if (v.tag == .null) null else try fromValue(o.child, vm, v, index),
        .@"enum" => |e| {
            if (v.tag == .string) {
                inline for (e.fields) |field| if (std.mem.eql(u8, field.name, v.as(object.String).bytes())) return @enumFromInt(field.value);
                return vm.fail("argument {d} of `{s}` is \"{s}\", which is not one of {s}", .{ index + 1, argName(vm), v.as(object.String).bytes(), @typeName(T) });
            }
            if (v.tag == .int) {
                inline for (e.fields) |field| if (field.value == v.asInt()) return @enumFromInt(field.value);
                return vm.fail("argument {d} of `{s}` is not a {s}", .{ index + 1, argName(vm), @typeName(T) });
            }
            return wrong(vm, index, "a string naming a member", v);
        },
        .array => |a| {
            if (a.child == f32 and a.len == 2) {
                if (v.tag != .vec2) return wrong(vm, index, "a vec2", v);
                return v.asVec2();
            }
            if (a.child == f32 and a.len == 3) {
                if (v.tag != .vec3) return wrong(vm, index, "a vec3", v);
                return v.asVec3();
            }
        },
        else => {},
    }
    @compileError("a native cannot take a " ++ @typeName(T) ++ " from a script");
}

/// A Zig value as a Flux value.
pub fn toValue(vm: *Vm, x: anytype) Error!Value {
    const T = @TypeOf(x);
    if (T == Value) return x;
    if (T == void) return .null;
    switch (@typeInfo(T)) {
        .comptime_int => return .int(x),
        .comptime_float => return .float(x),
        .int => return .int(std.math.cast(i64, x) orelse return vm.fail("{d} does not fit in an int", .{x})),
        .float => return .float(@floatCast(x)),
        .bool => return .boolean(x),
        .null => return .null,
        .optional => return if (x) |inner| toValue(vm, inner) else .null,
        .error_union => {
            const payload = x catch |err| return make.errorText(vm, @errorName(err), null);
            return toValue(vm, payload);
        },
        .error_set => return make.errorText(vm, @errorName(x), null),
        .@"enum" => return vm.string(@tagName(x)),
        .array => |a| {
            if (a.child == f32 and a.len == 2) return .vec2(x[0], x[1]);
            if (a.child == f32 and a.len == 3) return .vec3(x[0], x[1], x[2]);
            if (a.child == u8) return vm.string(&x);
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return vm.string(x);
            if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return vm.string(x);
            if (p.size == .one and @typeInfo(p.child) == .@"struct") return @import("reflect.zig").handle(vm, x);
            if (p.size == .slice) {
                const l = try make.list(vm, x.len, .any);
                const lv: Value = .fromObj(.list, &l.obj);
                try vm.pushRoot(lv);
                defer vm.popRoot();
                for (x) |item| {
                    const v = try toValue(vm, item);
                    l.items.appendAssumeCapacity(v);
                    vm.heap.barrier(&l.obj, v);
                }
                return lv;
            }
        },
        else => {},
    }
    @compileError("a script cannot be given a " ++ @typeName(T));
}

fn scriptParams(comptime F: type) usize {
    return comptime blk: {
        var n: usize = 0;
        for (@typeInfo(F).@"fn".params) |p| {
            if (p.type.? != *Vm) n += 1;
        }
        break :blk n;
    };
}

/// `f` as a native: its arguments converted from Flux values by their Zig
/// types, a `*Vm` parameter given the VM, and what it returns converted back.
pub fn wrap(comptime f: anytype) object.NativeFn {
    const F = @TypeOf(f);
    const info = @typeInfo(F).@"fn";
    return struct {
        fn call(vm: *Vm, args: []Value) Error!Value {
            var tuple: std.meta.ArgsTuple(F) = undefined;
            comptime var at: usize = 0;
            inline for (info.params, 0..) |p, i| {
                if (p.type.? == *Vm) {
                    tuple[i] = vm;
                } else {
                    tuple[i] = try fromValue(p.type.?, vm, args[at], at);
                    at += 1;
                }
            }
            return toValue(vm, @call(.auto, f, tuple));
        }
    }.call;
}

pub fn arity(comptime f: anytype) u8 {
    return @intCast(scriptParams(@TypeOf(f)));
}

const testing = std.testing;

fn clampTo(x: f64, lo: f64, hi: f64) f64 {
    return std.math.clamp(x, lo, hi);
}

const Mode = enum { easy, hard };

fn parsePositive(text: []const u8) !u32 {
    const n = std.fmt.parseInt(u32, text, 10) catch return error.NotANumber;
    if (n == 0) return error.Zero;
    return n;
}

fn modeName(m: Mode) []const u8 {
    return @tagName(m);
}

test "Zig functions called with Flux values" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const clamp = wrap(clampTo);
    var args = [_]Value{ .float(5), .int(0), .float(2.5) };
    try testing.expectEqual(@as(f64, 2.5), (try clamp(vm, &args)).asFloat());
    const parse = wrap(parsePositive);
    var good = [_]Value{try vm.string("42")};
    try testing.expectEqual(@as(i64, 42), (try parse(vm, &good)).asInt());
    var bad = [_]Value{try vm.string("x")};
    const e = try parse(vm, &bad);
    try testing.expectEqualStrings("NotANumber", e.as(object.ErrorValue).name.bytes());
    const mode = wrap(modeName);
    var m = [_]Value{try vm.string("hard")};
    try testing.expectEqualStrings("hard", (try mode(vm, &m)).as(object.String).bytes());
    var wrong_type = [_]Value{.int(1)};
    try testing.expectError(error.Panic, parse(vm, &wrong_type));
    try testing.expectEqualStrings("argument 1 of `the native` must be a string, not int", vm.panic.?.message);
    try testing.expectEqual(@as(u8, 3), arity(clampTo));
}
