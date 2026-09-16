// SPDX-License-Identifier: BSD-2-Clause

//! Fields, methods, properties and elements, found by name or index at run
//! time: what the instructions fall back on when their caches miss.

const std = @import("std");
const fuzzy = @import("fluxion_text").fuzzy;

const Vm = @import("Vm.zig");
const Value = @import("value.zig").Value;
const object = @import("object.zig");
const types = @import("types.zig");
const make = @import("make.zig");
const Error = Vm.Error;
const String = object.String;

/// The nearest of `names` to `wanted`, for "did you mean".
pub fn nearest(wanted: []const u8, names: []const []const u8) ?[]const u8 {
    const limit: usize = if (wanted.len <= 3) 1 else if (wanted.len <= 6) 2 else 3;
    const hit = (fuzzy.closest(wanted, names, limit) catch return null) orelse return null;
    return names[hit.index];
}

const NameList = struct {
    buffer: [96][]const u8 = undefined,
    len: usize = 0,

    fn add(l: *NameList, name: []const u8) void {
        if (l.len < l.buffer.len) {
            l.buffer[l.len] = name;
            l.len += 1;
        }
    }

    fn slice(l: *const NameList) []const []const u8 {
        return l.buffer[0..l.len];
    }
};

fn classNames(c: *const object.Class, list: *NameList) void {
    for (c.fields) |f| list.add(f.name.bytes());
    var at: ?*const object.Class = c;
    while (at) |x| : (at = x.parent) {
        var it = x.methods.keyIterator();
        while (it.next()) |k| list.add(k.*.bytes());
    }
    var statics = c.statics.keyIterator();
    while (statics.next()) |k| list.add(k.*.bytes());
}

fn missing(vm: *Vm, what: []const u8, name: *String, names: *const NameList) Error {
    @branchHint(.cold);
    if (nearest(name.bytes(), names.slice())) |near| {
        return vm.fail("{s} has no field or method `{s}`; did you mean `{s}`?", .{ what, name.bytes(), near });
    }
    return vm.fail("{s} has no field or method `{s}`", .{ what, name.bytes() });
}

fn builtinProperty(vm: *Vm, v: Value, name: *String) ?Value {
    const n = &vm.names;
    switch (v.tag) {
        .vec2 => {
            const xy = v.asVec2();
            if (name == n.x) return .float(xy[0]);
            if (name == n.y) return .float(xy[1]);
        },
        .vec3 => {
            const xyz = v.asVec3();
            if (name == n.x) return .float(xyz[0]);
            if (name == n.y) return .float(xyz[1]);
            if (name == n.z) return .float(xyz[2]);
        },
        .color => {
            const c = v.as(object.Color).rgba;
            if (name == n.r) return .float(c[0]);
            if (name == n.g) return .float(c[1]);
            if (name == n.b) return .float(c[2]);
            if (name == n.a) return .float(c[3]);
        },
        .string => if (name == n.len) return .int(v.as(String).chars),
        .list => if (name == n.len) return .int(@intCast(v.as(object.List).items.items.len)),
        .map => if (name == n.len) return .int(@intCast(v.as(object.Map).table.count())),
        .@"error" => {
            const e = v.as(object.ErrorValue);
            if (name == n.name) return .fromObj(.string, &e.name.obj);
            if (name == n.message) return if (e.message) |m| .fromObj(.string, &m.obj) else .null;
        },
        else => {},
    }
    return null;
}

pub fn getProperty(vm: *Vm, v: Value, name: *String, cache: ?*object.Cache) Error!Value {
    switch (v.tag) {
        .instance => {
            const inst = v.as(object.Instance);
            if (inst.class.slots.get(name)) |slot| {
                if (cache) |c| c.* = .{ .class = inst.class, .slot = slot };
                return inst.fields()[slot];
            }
            if (inst.class.method(name)) |m| {
                return .fromObj(.method, &(try make.method(vm, v, m)).obj);
            }
            if (inst.class.statics.get(name)) |s| return s;
            var names: NameList = .{};
            classNames(inst.class, &names);
            return missing(vm, inst.class.name.bytes(), name, &names);
        },
        .class => {
            const c = v.as(object.Class);
            if (c.statics.get(name)) |s| return s;
            if (c.method(name)) |m| return m;
            var names: NameList = .{};
            classNames(c, &names);
            return missing(vm, c.name.bytes(), name, &names);
        },
        .enum_type => {
            const e = v.as(object.EnumType);
            if (e.index(name)) |i| return .enumValue(&e.obj, i);
            if (e.methods.get(name)) |m| return m;
            var names: NameList = .{};
            for (e.members) |m| names.add(m.bytes());
            if (nearest(name.bytes(), names.slice())) |near| {
                return vm.fail("{s} has no member `{s}`; did you mean `{s}`?", .{ e.name.bytes(), name.bytes(), near });
            }
            return vm.fail("{s} has no member `{s}`", .{ e.name.bytes(), name.bytes() });
        },
        .module => {
            const m = v.as(object.Module);
            if (m.get(name)) |g| {
                if (g.tag == .undefined) return vm.fail("`{s}.{s}` is used before its initializer has run", .{ m.name.bytes(), name.bytes() });
                return g;
            }
            var names: NameList = .{};
            for (m.names.items) |n| names.add(n.bytes());
            if (nearest(name.bytes(), names.slice())) |near| {
                return vm.fail("module `{s}` has no `{s}`; did you mean `{s}`?", .{ m.name.bytes(), name.bytes(), near });
            }
            return vm.fail("module `{s}` has no `{s}`", .{ m.name.bytes(), name.bytes() });
        },
        .handle => {
            if (try bridge.method(vm, v, name.bytes())) |m| return .fromObj(.method, &(try make.method(vm, v, m)).obj);
            return bridge.get(vm, v, name.bytes());
        },
        .null => return vm.fail("cannot read `{s}` of null", .{name.bytes()}),
        else => {
            if (builtinProperty(vm, v, name)) |p| return p;
            if (builtinMethod(vm, v, name)) |m| return .fromObj(.method, &(try make.method(vm, v, m)).obj);
            return vm.fail("{s} has no field `{s}`", .{ types.typeName(v), name.bytes() });
        },
    }
}

const bridge = @import("../reflect.zig");

pub fn builtinMethod(vm: *Vm, v: Value, name: *String) ?Value {
    const kind: Vm.BuiltinType = switch (v.tag) {
        .string => .string,
        .list => .list,
        .map => .map,
        .vec2 => .vec2,
        .vec3 => .vec3,
        .color => .color,
        .signal => .signal,
        .task => .task,
        .@"error" => .@"error",
        .int => .int,
        .float => .float,
        .bool => .bool,
        else => return null,
    };
    return vm.methods.getPtrConst(kind).get(name);
}

/// The function to call for `v.name(...)`, and whether `v` goes first.
pub const Callee = struct { function: Value, with_self: bool };

pub fn getMethod(vm: *Vm, v: Value, name: *String, cache: ?*object.Cache) Error!Callee {
    switch (v.tag) {
        .instance => {
            const inst = v.as(object.Instance);
            if (inst.class.method(name)) |m| {
                if (cache) |c| c.* = .{ .class = inst.class, .method = m, .slot = std.math.maxInt(u32) };
                return .{ .function = m, .with_self = true };
            }
            return .{ .function = try getProperty(vm, v, name, null), .with_self = false };
        },
        .class, .enum_type, .module => return .{ .function = try getProperty(vm, v, name, null), .with_self = false },
        .handle => {
            if (try bridge.method(vm, v, name.bytes())) |m| return .{ .function = m, .with_self = true };
            return .{ .function = try bridge.get(vm, v, name.bytes()), .with_self = false };
        },
        .enum_value => {
            const e = object.EnumType.from(v.obj());
            if (e.methods.get(name)) |m| return .{ .function = m, .with_self = true };
            return vm.fail("{s} has no method `{s}`", .{ e.name.bytes(), name.bytes() });
        },
        .null => return vm.fail("cannot call `{s}` on null", .{name.bytes()}),
        else => {
            if (builtinMethod(vm, v, name)) |m| return .{ .function = m, .with_self = true };
            if (builtinProperty(vm, v, name)) |p| return .{ .function = p, .with_self = false };
            return noMethod(vm, v, name);
        },
    }
}

fn noMethod(vm: *Vm, v: Value, name: *String) Error {
    @branchHint(.cold);
    const kind: Vm.BuiltinType = switch (v.tag) {
        .string => .string,
        .list => .list,
        .map => .map,
        .vec2 => .vec2,
        .vec3 => .vec3,
        else => return vm.fail("{s} has no method `{s}`", .{ types.typeName(v), name.bytes() }),
    };
    var names: NameList = .{};
    var it = vm.methods.getPtrConst(kind).keyIterator();
    while (it.next()) |k| names.add(k.*.bytes());
    if (nearest(name.bytes(), names.slice())) |near| {
        return vm.fail("{s} has no method `{s}`; did you mean `{s}`?", .{ types.typeName(v), name.bytes(), near });
    }
    return vm.fail("{s} has no method `{s}`", .{ types.typeName(v), name.bytes() });
}

pub fn setProperty(vm: *Vm, target: *Value, name: *String, v: Value, cache: ?*object.Cache) Error!void {
    switch (target.tag) {
        .instance => {
            const inst = target.as(object.Instance);
            const slot = inst.class.slots.get(name) orelse {
                var names: NameList = .{};
                classNames(inst.class, &names);
                return missing(vm, inst.class.name.bytes(), name, &names);
            };
            const field = &inst.class.fields[slot];
            if (field.is_const or field.is_signal) return vm.fail("`{s}.{s}` cannot be assigned to", .{ inst.class.name.bytes(), name.bytes() });
            const stored = vm.checks.coerce(field.check, v) orelse return wrongType(vm, field.check, v, name.bytes());
            if (cache) |c| c.* = .{ .class = inst.class, .slot = slot, .check = field.check };
            inst.fields()[slot] = stored;
            vm.heap.barrier(&inst.obj, stored);
        },
        .vec2, .vec3 => {
            const f: f32 = @floatCast(v.toFloat() orelse return vm.fail("a vector's `{s}` is a float, not {s}", .{ name.bytes(), types.typeName(v) }));
            const n = &vm.names;
            if (target.tag == .vec2) {
                var xy = target.asVec2();
                if (name == n.x) xy[0] = f else if (name == n.y) xy[1] = f else return vm.fail("vec2 has no field `{s}`", .{name.bytes()});
                target.* = .vec2(xy[0], xy[1]);
            } else {
                var xyz = target.asVec3();
                if (name == n.x) xyz[0] = f else if (name == n.y) xyz[1] = f else if (name == n.z) xyz[2] = f else return vm.fail("vec3 has no field `{s}`", .{name.bytes()});
                target.* = .vec3(xyz[0], xyz[1], xyz[2]);
            }
        },
        .module => return vm.fail("a module's variables are set from inside it", .{}),
        .handle => return bridge.set(vm, target.*, name.bytes(), v),
        .null => return vm.fail("cannot set `{s}` on null", .{name.bytes()}),
        else => return vm.fail("cannot set `{s}` on {s}", .{ name.bytes(), types.typeName(target.*) }),
    }
}

pub fn wrongType(vm: *Vm, check: types.Check, v: Value, what: []const u8) Error {
    @branchHint(.cold);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    vm.checks.name(check, &w) catch {};
    if (v.tag == .list and check.tableIndex() != null) {
        return vm.fail("`{s}` is {s}, and this list is not one (it was made as a different list type)", .{ what, w.buffered() });
    }
    return vm.fail("`{s}` is {s}, not {s}", .{ what, w.buffered(), types.typeName(v) });
}

fn listIndex(vm: *Vm, len: usize, index: Value) Error!usize {
    if (index.tag != .int) return vm.fail("a list index is an int, not {s}", .{types.typeName(index)});
    const i = index.asInt();
    const at: i64 = if (i < 0) i + @as(i64, @intCast(len)) else i;
    if (at < 0 or at >= len) return vm.fail("index {d} is out of bounds for a list of length {d}", .{ i, len });
    return @intCast(at);
}

pub fn getIndex(vm: *Vm, target: Value, index: Value) Error!Value {
    switch (target.tag) {
        .list => {
            const l = target.as(object.List);
            return l.items.items[try listIndex(vm, l.items.items.len, index)];
        },
        .map => {
            const m = target.as(object.Map);
            if (m.table.get(index)) |v| return v;
            if (index.tag == .string) return vm.fail("the map has no key \"{s}\"; use `.get(key)` when a key may be missing", .{index.as(String).bytes()});
            return vm.fail("the map has no such key; use `.get(key)` when a key may be missing", .{});
        },
        .string => return @import("../lib/string.zig").charAt(vm, target.as(String), index),
        .handle => return bridge.index(vm, target, index),
        .null => return vm.fail("cannot index null", .{}),
        else => return vm.fail("cannot index {s}", .{types.typeName(target)}),
    }
}

pub fn setIndex(vm: *Vm, target: Value, index: Value, v: Value) Error!void {
    switch (target.tag) {
        .list => {
            const l = target.as(object.List);
            const i = try listIndex(vm, l.items.items.len, index);
            const stored = vm.checks.coerce(l.elem, v) orelse return wrongType(vm, l.elem, v, "the list's element");
            l.items.items[i] = stored;
            vm.heap.barrier(&l.obj, stored);
        },
        .map => {
            const m = target.as(object.Map);
            const key = vm.checks.coerce(m.key, index) orelse return wrongType(vm, m.key, index, "the map's key");
            const stored = vm.checks.coerce(m.value, v) orelse return wrongType(vm, m.value, v, "the map's value");
            m.table.put(vm.gpa, key, stored) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NanKey => return vm.fail("NaN cannot be a map key", .{}),
            };
            vm.heap.barrier(&m.obj, key);
            vm.heap.barrier(&m.obj, stored);
        },
        .string => return vm.fail("strings cannot be changed; build a new one", .{}),
        .null => return vm.fail("cannot index null", .{}),
        else => return vm.fail("cannot index {s}", .{types.typeName(target)}),
    }
}

pub fn length(vm: *Vm, v: Value) Error!Value {
    return switch (v.tag) {
        .string => .int(v.as(String).chars),
        .list => .int(@intCast(v.as(object.List).items.items.len)),
        .map => .int(@intCast(v.as(object.Map).table.count())),
        else => vm.fail("{s} has no length", .{types.typeName(v)}),
    };
}

pub fn slice(vm: *Vm, target: Value, from: Value, to: Value) Error!Value {
    const len: usize = switch (target.tag) {
        .list => target.as(object.List).items.items.len,
        .string => target.as(String).chars,
        else => return vm.fail("cannot slice {s}", .{types.typeName(target)}),
    };
    if (from.tag != .int or (to.tag != .int and to.tag != .null)) return vm.fail("slice bounds are ints", .{});
    const start = from.asInt();
    const end: i64 = if (to.tag == .null) @intCast(len) else to.asInt();
    if (start < 0 or end < start or end > len) return vm.fail("slice [{d}..{d}] is out of bounds for length {d}", .{ start, end, len });
    const a: usize = @intCast(start);
    const b: usize = @intCast(end);
    if (target.tag == .list) {
        const src = target.as(object.List);
        const l = try make.list(vm, b - a, src.elem);
        l.items.appendSliceAssumeCapacity(src.items.items[a..b]);
        return .fromObj(.list, &l.obj);
    }
    return @import("../lib/string.zig").sliceChars(vm, target.as(String), a, b);
}
