// SPDX-License-Identifier: BSD-2-Clause

//! The types of what is built in: the prelude's functions and the methods
//! of strings, lists, maps, vectors and signals. With these, `xs.pop()` on
//! a `[int]` is known to give a `?int`, and a lambda passed to `filter`
//! knows its parameter's type.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const Type = types.Type;
const Compiler = @import("Compiler.zig");
const Error = Compiler.Error;

pub const Shape = struct {
    /// What each argument should be; `.unknown` where anything goes.
    params: []const Type,
    ret: Type,
};

fn sig(pool: *types.Pool, params: []const Type, ret: Type) Allocator.Error!Type {
    const a = pool.allocator();
    const list = try a.alloc(types.Param, params.len);
    for (params, list) |p, *out| out.* = .{ .name = "", .type = p, .has_default = false };
    const s = try a.create(types.Signature);
    s.* = .{ .params = list, .ret = ret };
    return pool.function(s);
}

fn shape(pool: *types.Pool, params: []const Type, ret: Type) Allocator.Error!Shape {
    return .{ .params = try pool.allocator().dupe(Type, params), .ret = ret };
}

/// A method of a builtin type: parameter types (without the receiver) and
/// what it returns, or null when there is no such method.
pub fn method(c: *Compiler, receiver: Type, name: []const u8, args: []const Type) Error!?Shape {
    return methodIn(c.pool, receiver, name, args);
}

/// `method`, for those with the types but no compiler: an editor's.
pub fn methodIn(pool: *types.Pool, receiver: Type, name: []const u8, args: []const Type) Allocator.Error!?Shape {
    const eq = std.mem.eql;
    if (pool.listOf(receiver)) |t| {
        const opt = try pool.optional(t);
        const self = receiver;
        if (eq(u8, name, "push") or eq(u8, name, "append")) return try shape(pool, &.{t}, .void);
        if (eq(u8, name, "pop") or eq(u8, name, "first") or eq(u8, name, "last")) return try shape(pool, &.{}, opt);
        if (eq(u8, name, "insert")) return try shape(pool, &.{ .int, t }, .void);
        if (eq(u8, name, "remove")) return try shape(pool, &.{.int}, t);
        if (eq(u8, name, "remove_value") or eq(u8, name, "contains")) return try shape(pool, &.{t}, .bool);
        if (eq(u8, name, "index_of")) return try shape(pool, &.{t}, try pool.optional(.int));
        if (eq(u8, name, "count")) return try shape(pool, &.{t}, .int);
        if (eq(u8, name, "clear") or eq(u8, name, "reverse") or eq(u8, name, "sort")) return try shape(pool, &.{}, .void);
        if (eq(u8, name, "reversed") or eq(u8, name, "copy")) return try shape(pool, &.{}, self);
        if (eq(u8, name, "is_empty")) return try shape(pool, &.{}, .bool);
        if (eq(u8, name, "extend")) return try shape(pool, &.{self}, .void);
        if (eq(u8, name, "join")) return try shape(pool, &.{.string}, .string);
        if (eq(u8, name, "sum")) return try shape(pool, &.{}, if (t == .int or t == .float) t else .any);
        if (eq(u8, name, "sort_by")) return try shape(pool, &.{try sig(pool, &.{ t, t }, .bool)}, .void);
        if (eq(u8, name, "filter")) return try shape(pool, &.{try sig(pool, &.{t}, .bool)}, self);
        if (eq(u8, name, "any") or eq(u8, name, "all")) return try shape(pool, &.{try sig(pool, &.{t}, .bool)}, .bool);
        if (eq(u8, name, "find")) return try shape(pool, &.{try sig(pool, &.{t}, .bool)}, opt);
        if (eq(u8, name, "map")) {
            const r = if (args.len > 0) if (pool.signatureOf(args[0])) |s| s.ret else .any else .any;
            return try shape(pool, &.{try sig(pool, &.{t}, .any)}, try pool.list(if (r == .void or r == .unknown) .any else r));
        }
        if (eq(u8, name, "reduce")) {
            const acc = if (args.len > 1) args[1] else .any;
            return try shape(pool, &.{ try sig(pool, &.{ acc, t }, acc), acc }, acc);
        }
        return null;
    }
    if (pool.mapOf(receiver)) |kv| {
        if (eq(u8, name, "get")) return try shape(pool, &.{ kv.key, try pool.optional(kv.value) }, try pool.optional(kv.value));
        if (eq(u8, name, "has") or eq(u8, name, "contains") or eq(u8, name, "remove")) return try shape(pool, &.{kv.key}, .bool);
        if (eq(u8, name, "keys")) return try shape(pool, &.{}, try pool.list(kv.key));
        if (eq(u8, name, "values")) return try shape(pool, &.{}, try pool.list(kv.value));
        if (eq(u8, name, "clear")) return try shape(pool, &.{}, .void);
        if (eq(u8, name, "is_empty")) return try shape(pool, &.{}, .bool);
        if (eq(u8, name, "copy")) return try shape(pool, &.{}, receiver);
        if (eq(u8, name, "merge")) return try shape(pool, &.{receiver}, .void);
        if (eq(u8, name, "set")) return try shape(pool, &.{ kv.key, kv.value }, .void);
        return null;
    }
    switch (receiver) {
        .string => {
            const text = &[_][]const u8{ "trim", "trim_start", "trim_end", "upper", "lower", "reversed" };
            for (text) |n| if (eq(u8, name, n)) return try shape(pool, &.{}, .string);
            const tests = &[_][]const u8{ "contains", "starts_with", "ends_with" };
            for (tests) |n| if (eq(u8, name, n)) return try shape(pool, &.{.string}, .bool);
            if (eq(u8, name, "is_empty")) return try shape(pool, &.{}, .bool);
            if (eq(u8, name, "find")) return try shape(pool, &.{.string}, try pool.optional(.int));
            if (eq(u8, name, "count")) return try shape(pool, &.{.string}, .int);
            if (eq(u8, name, "replace")) return try shape(pool, &.{ .string, .string }, .string);
            if (eq(u8, name, "split")) return try shape(pool, &.{.string}, try pool.list(.string));
            if (eq(u8, name, "lines") or eq(u8, name, "chars")) return try shape(pool, &.{}, try pool.list(.string));
            if (eq(u8, name, "bytes")) return try shape(pool, &.{}, try pool.list(.int));
            if (eq(u8, name, "repeat")) return try shape(pool, &.{.int}, .string);
            if (eq(u8, name, "pad_start") or eq(u8, name, "pad_end")) return try shape(pool, &.{ .int, .string }, .string);
            if (eq(u8, name, "code")) return try shape(pool, &.{.int}, .int);
        },
        .vec2, .vec3 => {
            const v = receiver;
            const same = &[_][]const u8{ "normalized", "abs", "floor", "ceil", "round" };
            for (same) |n| if (eq(u8, name, n)) return try shape(pool, &.{}, v);
            if (eq(u8, name, "length") or eq(u8, name, "length_squared")) return try shape(pool, &.{}, .float);
            if (eq(u8, name, "dot") or eq(u8, name, "distance_to") or eq(u8, name, "distance_squared_to")) return try shape(pool, &.{v}, .float);
            if (eq(u8, name, "direction_to") or eq(u8, name, "min") or eq(u8, name, "max")) return try shape(pool, &.{v}, v);
            if (eq(u8, name, "lerp") or eq(u8, name, "move_toward")) return try shape(pool, &.{ v, .float }, v);
            if (eq(u8, name, "clamp")) return try shape(pool, &.{ v, v }, v);
            if (eq(u8, name, "limit_length")) return try shape(pool, &.{.float}, v);
            if (eq(u8, name, "is_zero")) return try shape(pool, &.{}, .bool);
            if (eq(u8, name, "cross")) return try shape(pool, &.{v}, if (v == .vec2) .float else .vec3);
            if (v == .vec2) {
                if (eq(u8, name, "angle")) return try shape(pool, &.{}, .float);
                if (eq(u8, name, "angle_to")) return try shape(pool, &.{.vec2}, .float);
                if (eq(u8, name, "rotated")) return try shape(pool, &.{.float}, .vec2);
                if (eq(u8, name, "orthogonal")) return try shape(pool, &.{}, .vec2);
            }
        },
        .signal => {
            if (eq(u8, name, "emit")) {
                const any = try pool.allocator().alloc(Type, @max(args.len, 16));
                @memset(any, .unknown);
                return .{ .params = any, .ret = .void };
            }
            if (eq(u8, name, "connect") or eq(u8, name, "once")) return try shape(pool, &.{.unknown}, .void);
            if (eq(u8, name, "disconnect") or eq(u8, name, "is_connected")) return try shape(pool, &.{.unknown}, .bool);
            if (eq(u8, name, "connections")) return try shape(pool, &.{}, .int);
        },
        else => {},
    }
    return null;
}

/// What a prelude function returns for these argument types.
pub fn preludeReturn(c: *Compiler, name: []const u8, args: []const Type) Error!Type {
    const eq = std.mem.eql;
    if (eq(u8, name, "print") or eq(u8, name, "assert")) return .void;
    if (eq(u8, name, "panic")) return .never;
    if (eq(u8, name, "str") or eq(u8, name, "typeof")) return .string;
    if (eq(u8, name, "int")) return if (args.len > 0 and mayBeText(c, args[0])) c.pool.errorUnion(.int) else .int;
    if (eq(u8, name, "float")) return if (args.len > 0 and mayBeText(c, args[0])) c.pool.errorUnion(.float) else .float;
    if (eq(u8, name, "vec2")) return .vec2;
    if (eq(u8, name, "vec3")) return .vec3;
    if (eq(u8, name, "color")) return .color;
    if (eq(u8, name, "wait")) return .float;
    if (eq(u8, name, "range")) return c.pool.list(.int);
    if (eq(u8, name, "abs")) return if (args.len > 0 and !Compiler.dynamic(args[0])) args[0] else .any;
    if (eq(u8, name, "min") or eq(u8, name, "max") or eq(u8, name, "clamp")) {
        if (args.len == 1) if (c.pool.listOf(args[0])) |elem| return if (elem == .int or elem == .float) elem else .any;
        return numeric(args);
    }
    return .any;
}

/// A conversion from text can fail, and gives an error value then: from a
/// string, or from what may be one.
fn mayBeText(c: *Compiler, t: Type) bool {
    return t == .string or t == .any or c.pool.isOptional(t) == .string;
}

/// The result of a function that gives an int for ints and a float once a
/// float is among its arguments: known only when every argument's type is.
fn numeric(args: []const Type) Type {
    if (args.len == 0) return .any;
    var all_int = true;
    for (args) |a| {
        if (a != .int and a != .float) return .any;
        all_int = all_int and a == .int;
    }
    return if (all_int) .int else .float;
}

/// What a `math` function returns: floats for floats, and for `floor` and
/// its kind an int from a float.
pub fn mathReturn(name: []const u8, args: []const Type) Type {
    const eq = std.mem.eql;
    const to_int = &[_][]const u8{ "floor", "ceil", "round", "trunc" };
    for (to_int) |n| if (eq(u8, name, n)) return if (args.len > 0 and (args[0] == .int or args[0] == .float)) .int else .any;
    const bools = &[_][]const u8{ "is_nan", "is_inf", "approx_eq" };
    for (bools) |n| if (eq(u8, name, n)) return .bool;
    if (eq(u8, name, "random_int")) return .int;
    if (eq(u8, name, "seed")) return .void;
    const either = &[_][]const u8{ "pow", "mod", "wrap", "sign" };
    for (either) |n| if (eq(u8, name, n)) return numeric(args);
    return .float;
}
