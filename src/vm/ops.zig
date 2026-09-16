// SPDX-License-Identifier: BSD-2-Clause

//! What the operators do when the instruction's fast path does not apply:
//! mixed numbers, vectors, strings, lists, and the messages for what makes
//! no sense.

const std = @import("std");

const Vm = @import("Vm.zig");
const Value = @import("value.zig").Value;
const object = @import("object.zig");
const types = @import("types.zig");
const Error = Vm.Error;

pub const Arith = enum { add, sub, mul, div, mod, add_wrap, sub_wrap, mul_wrap, bit_and, bit_or, bit_xor, shl, shr };

fn symbol(op: Arith) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .add_wrap => "+%",
        .sub_wrap => "-%",
        .mul_wrap => "*%",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shl => "<<",
        .shr => ">>",
    };
}

pub fn overflow(vm: *Vm, op: Arith, a: i64, b: i64) Error {
    @branchHint(.cold);
    return vm.fail("integer overflow: {d} {s} {d} does not fit in 64 bits", .{ a, symbol(op), b });
}

pub fn divByZero(vm: *Vm) Error {
    @branchHint(.cold);
    return vm.fail("division by zero", .{});
}

fn cannot(vm: *Vm, op: Arith, a: Value, b: Value) Error {
    @branchHint(.cold);
    return vm.fail("cannot use `{s}` on {s} and {s}", .{ symbol(op), article(types.typeName(a)), article(types.typeName(b)) });
}

pub fn article(name: []const u8) []const u8 {
    return name;
}

pub fn ints(vm: *Vm, op: Arith, x: i64, y: i64) Error!i64 {
    switch (op) {
        .add => {
            const r = @addWithOverflow(x, y);
            return if (r[1] != 0) overflow(vm, op, x, y) else r[0];
        },
        .sub => {
            const r = @subWithOverflow(x, y);
            return if (r[1] != 0) overflow(vm, op, x, y) else r[0];
        },
        .mul => {
            const r = @mulWithOverflow(x, y);
            return if (r[1] != 0) overflow(vm, op, x, y) else r[0];
        },
        .div => {
            if (y == 0) return divByZero(vm);
            if (x == std.math.minInt(i64) and y == -1) return overflow(vm, op, x, y);
            return @divTrunc(x, y);
        },
        .mod => {
            if (y == 0) return divByZero(vm);
            if (y == -1) return 0;
            return @rem(x, y);
        },
        .add_wrap => return x +% y,
        .sub_wrap => return x -% y,
        .mul_wrap => return x *% y,
        .bit_and => return x & y,
        .bit_or => return x | y,
        .bit_xor => return x ^ y,
        .shl, .shr => {
            if (y < 0 or y > 63) return vm.fail("cannot shift by {d}: a shift is 0 to 63 places", .{y});
            const n: u6 = @intCast(y);
            return if (op == .shl) x << n else x >> n;
        },
    }
}

pub fn floats(op: Arith, x: f64, y: f64) ?f64 {
    return switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .mod => @rem(x, y),
        else => null,
    };
}

fn vecOp(comptime n: usize, op: Arith, x: [n]f32, y: [n]f32) ?[n]f32 {
    const a: @Vector(n, f32) = x;
    const b: @Vector(n, f32) = y;
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
        else => null,
    };
}

fn splat(comptime n: usize, s: f32) [n]f32 {
    return @splat(s);
}

fn vector(comptime n: usize, v: [n]f32) Value {
    return if (n == 2) .vec2(v[0], v[1]) else .vec3(v[0], v[1], v[2]);
}

fn vecOf(comptime n: usize, v: Value) [n]f32 {
    return if (n == 2) v.asVec2() else v.asVec3();
}

fn vecArith(comptime n: usize, vm: *Vm, op: Arith, a: Value, b: Value) Error!Value {
    const tag: @import("value.zig").Tag = if (n == 2) .vec2 else .vec3;
    if (a.tag == tag and b.tag == tag) {
        if (vecOp(n, op, vecOf(n, a), vecOf(n, b))) |r| return vector(n, r);
    } else if (a.tag == tag and b.isNumber()) {
        if (op == .mul or op == .div) return vector(n, vecOp(n, op, vecOf(n, a), splat(n, @floatCast(b.toFloat().?))).?);
    } else if (b.tag == tag and a.isNumber()) {
        if (op == .mul) return vector(n, vecOp(n, op, splat(n, @floatCast(a.toFloat().?)), vecOf(n, b)).?);
    }
    return cannot(vm, op, a, b);
}

pub fn arith(vm: *Vm, op: Arith, a: Value, b: Value) Error!Value {
    if (a.tag == .int and b.tag == .int) return .int(try ints(vm, op, a.asInt(), b.asInt()));
    if (a.isNumber() and b.isNumber()) {
        if (floats(op, a.toFloat().?, b.toFloat().?)) |r| return .float(r);
        return cannot(vm, op, a, b);
    }
    if (a.tag == .vec2 or b.tag == .vec2) return vecArith(2, vm, op, a, b);
    if (a.tag == .vec3 or b.tag == .vec3) return vecArith(3, vm, op, a, b);
    if (op == .add and a.tag == .string and b.tag == .string) return concat(vm, a.as(object.String).bytes(), b.as(object.String).bytes());
    if (op == .mul and a.tag == .string and b.tag == .int) return repeat(vm, a.as(object.String), b.asInt());
    if (op == .add and a.tag == .list and b.tag == .list) return joinLists(vm, a.as(object.List), b.as(object.List));
    if (op == .add and (a.tag == .string or b.tag == .string)) {
        const other = if (a.tag == .string) b else a;
        return vm.fail("cannot add {s} to a string; format it with f\"{{...}}\" or convert it with str()", .{types.typeName(other)});
    }
    return cannot(vm, op, a, b);
}

pub fn concat(vm: *Vm, x: []const u8, y: []const u8) Error!Value {
    const total = x.len + y.len;
    if (total <= 256) {
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..x.len], x);
        @memcpy(buf[x.len..total], y);
        return vm.string(buf[0..total]);
    }
    const joined = try vm.gpa.alloc(u8, total);
    defer vm.gpa.free(joined);
    @memcpy(joined[0..x.len], x);
    @memcpy(joined[x.len..], y);
    return vm.string(joined);
}

fn repeat(vm: *Vm, s: *object.String, times: i64) Error!Value {
    if (times < 0) return vm.fail("cannot repeat a string {d} times", .{times});
    const n: usize = @intCast(times);
    const len = std.math.mul(usize, s.len, n) catch return vm.fail("the repeated string would be too long", .{});
    if (len > 1 << 30) return vm.fail("the repeated string would be too long", .{});
    const out = try vm.gpa.alloc(u8, len);
    defer vm.gpa.free(out);
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s.bytes());
    return vm.string(out);
}

fn joinLists(vm: *Vm, x: *object.List, y: *object.List) Error!Value {
    const list = try @import("make.zig").list(vm, x.items.items.len + y.items.items.len, if (x.elem == y.elem) x.elem else .any);
    list.items.appendSliceAssumeCapacity(x.items.items);
    list.items.appendSliceAssumeCapacity(y.items.items);
    return .fromObj(.list, &list.obj);
}

pub fn negate(vm: *Vm, v: Value) Error!Value {
    return switch (v.tag) {
        .int => if (v.asInt() == std.math.minInt(i64)) overflow(vm, .sub, 0, v.asInt()) else .int(-v.asInt()),
        .float => .float(-v.asFloat()),
        .vec2 => .vec2(-v.asVec2()[0], -v.asVec2()[1]),
        .vec3 => .vec3(-v.asVec3()[0], -v.asVec3()[1], -v.asVec3()[2]),
        else => vm.fail("cannot negate {s}", .{types.typeName(v)}),
    };
}

pub fn not(vm: *Vm, v: Value) Error!Value {
    if (v.tag != .bool) return vm.fail("`!` needs a bool, not {s}", .{types.typeName(v)});
    return .boolean(!v.asBool());
}

pub fn bitNot(vm: *Vm, v: Value) Error!Value {
    if (v.tag != .int) return vm.fail("`~` needs an int, not {s}", .{types.typeName(v)});
    return .int(~v.asInt());
}

/// `==`: numbers by value across int and float, strings by their text,
/// lists and maps by what they hold, everything else by identity.
pub fn equal(a: Value, b: Value) bool {
    return equalDepth(a, b, 0);
}

/// How far `==` looks into lists and maps inside each other. A list can
/// hold itself; past this depth two such are called unequal rather than
/// compared forever.
const max_compare_depth = 256;

fn equalDepth(a: Value, b: Value, depth: u32) bool {
    if (a.tag != b.tag) {
        if (a.isNumber() and b.isNumber()) return a.toFloat().? == b.toFloat().?;
        return false;
    }
    return switch (a.tag) {
        .null, .undefined => true,
        .bool, .int => a.raw == b.raw,
        .float => a.asFloat() == b.asFloat(),
        .vec2 => @reduce(.And, @as(@Vector(2, f32), a.asVec2()) == @as(@Vector(2, f32), b.asVec2())),
        .vec3 => @reduce(.And, @as(@Vector(3, f32), a.asVec3()) == @as(@Vector(3, f32), b.asVec3())),
        .enum_value => a.raw == b.raw and a.extra == b.extra,
        .string => a.as(object.String).eql(b.as(object.String)),
        .@"error" => a.raw == b.raw or a.as(object.ErrorValue).name == b.as(object.ErrorValue).name,
        .color => std.mem.eql(f32, &a.as(object.Color).rgba, &b.as(object.Color).rgba),
        .list => {
            if (a.raw == b.raw) return true;
            if (depth > max_compare_depth) return false;
            const x = a.as(object.List).items.items;
            const y = b.as(object.List).items.items;
            if (x.len != y.len) return false;
            for (x, y) |p, q| if (!equalDepth(p, q, depth + 1)) return false;
            return true;
        },
        .map => {
            if (a.raw == b.raw) return true;
            if (depth > max_compare_depth) return false;
            const x = &a.as(object.Map).table;
            const y = &b.as(object.Map).table;
            if (x.count() != y.count()) return false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = y.get(e.key) orelse return false;
                if (!equalDepth(e.value, other, depth + 1)) return false;
            }
            return true;
        },
        else => a.raw == b.raw,
    };
}

pub const Order = enum { lt, le };

/// `<` and `<=`: numbers, and strings in byte order.
pub fn compare(vm: *Vm, order: Order, a: Value, b: Value) Error!bool {
    if (a.isNumber() and b.isNumber()) {
        if (a.tag == .int and b.tag == .int) return if (order == .lt) a.asInt() < b.asInt() else a.asInt() <= b.asInt();
        const x = a.toFloat().?;
        const y = b.toFloat().?;
        return if (order == .lt) x < y else x <= y;
    }
    if (a.tag == .string and b.tag == .string) {
        const o = std.mem.order(u8, a.as(object.String).bytes(), b.as(object.String).bytes());
        return if (order == .lt) o == .lt else o != .gt;
    }
    return vm.fail("cannot compare {s} with {s}", .{ types.typeName(a), types.typeName(b) });
}

pub fn contains(vm: *Vm, item: Value, container: Value) Error!bool {
    switch (container.tag) {
        .list => {
            for (container.as(object.List).items.items) |v| if (equal(v, item)) return true;
            return false;
        },
        .map => return container.as(object.Map).table.indexOf(item) != null,
        .string => {
            if (item.tag != .string) return vm.fail("`in` a string needs a string to look for, not {s}", .{types.typeName(item)});
            return std.mem.indexOf(u8, container.as(object.String).bytes(), item.as(object.String).bytes()) != null;
        },
        else => return vm.fail("`in` needs a list, a map or a string, not {s}", .{types.typeName(container)}),
    }
}
