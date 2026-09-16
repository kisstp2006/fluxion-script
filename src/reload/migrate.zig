// SPDX-License-Identifier: BSD-2-Clause

//! What a reload changes in the values the program already has. Instances
//! of a struct whose fields changed get the new ones, matched by name: a
//! value that still fits its field's type is kept, the rest start again
//! from their defaults. Stored members of an enum whose members changed
//! follow their names to their new places.
//!
//! All of it is planned first, while nothing has changed and running out
//! of memory can still undo the reload, then applied in a step that
//! cannot fail.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const types = @import("../vm/types.zig");
const call = @import("../vm/call.zig");
const signal = @import("../lib/signal.zig");
const Patch = @import("../compile/Patch.zig");

/// A field reset by a reload whose value only the struct's defaults can
/// make: a list, a map, anything computed. It holds a zero of its type
/// until the new code can run and make it.
pub const Pending = struct { instance: *object.Instance, slot: u32 };

pub const Renumbered = struct {
    type: *object.EnumType,
    /// For each old member, its new place; null for one that is gone.
    to: []?u32,
    /// Values that held a member that is gone, and now hold the first.
    lost: u32 = 0,
};

/// A field whose old values did not fit its new type, and how many
/// instances lost theirs.
pub const Dropped = struct { class: *object.Class, name: *object.String, count: u32 };

pub const Plan = struct {
    moves: std.ArrayList(Move) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    enums: std.ArrayList(Renumbered) = .empty,
    dropped: std.ArrayList(Dropped) = .empty,
    applied: bool = false,

    const Move = struct { instance: *object.Instance, values: []Value };

    pub fn deinit(p: *Plan, gpa: Allocator) void {
        if (!p.applied) for (p.moves.items) |m| gpa.free(m.values);
        p.moves.deinit(gpa);
        p.pending.deinit(gpa);
        for (p.enums.items) |e| gpa.free(e.to);
        p.enums.deinit(gpa);
        p.dropped.deinit(gpa);
    }

    fn drop(p: *Plan, gpa: Allocator, class: *object.Class, name: *object.String) Allocator.Error!void {
        for (p.dropped.items) |*d| if (d.class == class and d.name == name) {
            d.count += 1;
            return;
        };
        try p.dropped.append(gpa, .{ .class = class, .name = name, .count = 1 });
    }
};

/// Works out every move, making what the new fields start from. `since` is
/// the newest object from before the reload: those after it are its own.
pub fn plan(vm: *Vm, patches: []Patch, since: ?*object.Obj, p: *Plan) Allocator.Error!void {
    const gpa = vm.gpa;
    for (patches) |*patch| for (patch.enums.items) |k| {
        if (sameMembers(k.old.members, k.object.members)) continue;
        const to = try gpa.alloc(?u32, k.old.members.len);
        for (k.old.members, to) |m, *t| t.* = k.object.index(m);
        p.enums.append(gpa, .{ .type = k.object, .to = to }) catch |err| {
            gpa.free(to);
            return err;
        };
    };
    var changed: std.AutoHashMapUnmanaged(*object.Class, []const object.Field) = .empty;
    defer changed.deinit(gpa);
    for (patches) |*patch| for (patch.classes.items) |k| {
        if (!sameFields(k.old.fields, k.object.fields)) try changed.put(gpa, k.object, k.old.fields);
    };
    if (changed.count() == 0) return;
    var o = since;
    while (o) |obj| : (o = obj.next) {
        if (obj.kind != .instance) continue;
        const inst = object.Instance.from(obj);
        const old = changed.get(inst.class) orelse continue;
        try planMove(vm, p, inst, old);
    }
}

fn planMove(vm: *Vm, p: *Plan, inst: *object.Instance, old: []const object.Field) Allocator.Error!void {
    const class = inst.class;
    const values = try vm.gpa.alloc(Value, class.fields.len);
    p.moves.append(vm.gpa, .{ .instance = inst, .values = values }) catch |err| {
        vm.gpa.free(values);
        return err;
    };
    const before = inst.fields();
    for (class.fields, values, 0..) |f, *out, slot| {
        if (fieldIndex(old, f.name)) |k| {
            if (vm.checks.coerce(f.check, before[k])) |v| {
                out.* = v;
                renumber(p.enums.items, out, false);
                continue;
            }
            try p.drop(vm.gpa, class, f.name);
        }
        out.* = try startValue(vm, f, 0);
        if (f.computed) try p.pending.append(vm.gpa, .{ .instance = inst, .slot = @intCast(slot) });
    }
}

/// Renumbers every stored enum member, then gives each instance its new
/// fields. Nothing here allocates.
pub fn apply(vm: *Vm, p: *Plan, since: ?*object.Obj) void {
    if (p.enums.items.len > 0) renumberAll(vm, p.enums.items, since);
    for (p.moves.items) |m| {
        const inst = m.instance;
        for (inst.class.fields, m.values) |f, v| {
            if (f.is_signal and v.tag == .signal) v.as(object.Signal).params = @intCast(f.default.asInt());
        }
        var made: u32 = @max(inst.count, 1);
        if (inst.obj.flags & object.Instance.moved != 0) {
            const was = inst.movedTo();
            made = was.made;
            vm.heap.bytes -|= inst.count * @sizeOf(Value);
            vm.gpa.free(was.values[0..inst.count]);
        }
        inst.movedTo().* = .{ .values = m.values.ptr, .made = made };
        inst.obj.flags |= object.Instance.moved;
        inst.count = @intCast(m.values.len);
        vm.heap.bytes += m.values.len * @sizeOf(Value);
    }
    p.applied = true;
}

/// Makes the values only the struct's defaults can, now that the new code
/// runs: each instance's from a fresh instance's defaults.
pub fn fillPending(vm: *Vm, pending: []const Pending) Vm.Error!void {
    if (pending.len == 0) return;
    const keep = try make.list(vm, pending.len, .any);
    try vm.pushRoot(.fromObj(.list, &keep.obj));
    defer vm.popRoot();
    for (pending) |x| keep.items.appendAssumeCapacity(.fromObj(.instance, &x.instance.obj));
    var i: usize = 0;
    while (i < pending.len) {
        const inst = pending[i].instance;
        const fresh = try make.instance(vm, inst.class);
        const value: Value = .fromObj(.instance, &fresh.obj);
        try vm.pushRoot(value);
        defer vm.popRoot();
        if (inst.class.has_signals) try signal.fill(vm, fresh);
        try call.initDefaults(vm, value);
        while (i < pending.len and pending[i].instance == inst) : (i += 1) {
            const v = fresh.fields()[pending[i].slot];
            inst.fields()[pending[i].slot] = v;
            vm.heap.barrier(&inst.obj, v);
        }
    }
}

fn sameMembers(a: []const *object.String, b: []const *object.String) bool {
    return std.mem.eql(*object.String, a, b);
}

fn sameFields(a: []const object.Field, b: []const object.Field) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.name != y.name or x.check != y.check or x.is_signal != y.is_signal) return false;
    return true;
}

fn fieldIndex(fields: []const object.Field, name: *object.String) ?usize {
    for (fields, 0..) |f, i| if (f.name == name) return i;
    return null;
}

/// What a field holds until its defaults have run: the literal it is
/// declared with, or a zero of its type that typed code can use.
fn startValue(vm: *Vm, f: object.Field, depth: u8) Allocator.Error!Value {
    if (f.is_signal) return .fromObj(.signal, &(try make.signal(vm, f.name, @intCast(f.default.asInt()))).obj);
    if (!f.computed and vm.checks.accepts(f.check, f.default)) return f.default;
    return zero(vm, f.check, depth);
}

fn zero(vm: *Vm, check: types.Check, depth: u8) Allocator.Error!Value {
    return switch (check) {
        .any, .null, .type => .null,
        .int => .int(0),
        .float => .float(0),
        .bool => .false,
        .string => vm.string(""),
        .vec2 => .vec2(0, 0),
        .vec3 => .vec3(0, 0, 0),
        .color => make.color(vm, .{ 0, 0, 0, 1 }),
        .list => .fromObj(.list, &(try make.list(vm, 0, .any)).obj),
        .map => .fromObj(.map, &(try make.map(vm, .any, .any)).obj),
        .function => unset(vm),
        .task => doneTask(vm),
        .signal => .fromObj(.signal, &(try make.signal(vm, try vm.intern("signal"), 0)).obj),
        .@"error" => make.errorText(vm, "Unset", null),
        _ => switch (vm.checks.get(check).?) {
            .optional => .null,
            .error_union => |inner| zero(vm, inner, depth),
            .list_of => |elem| .fromObj(.list, &(try make.list(vm, 0, elem)).obj),
            .map_of => |kv| .fromObj(.map, &(try make.map(vm, kv.key, kv.value)).obj),
            .enum_type => |e| .enumValue(&e.obj, 0),
            .function => unset(vm),
            .class => |c| if (depth < 8) instanceOf(vm, c, depth + 1) else .null,
        },
    };
}

fn instanceOf(vm: *Vm, class: *object.Class, depth: u8) Allocator.Error!Value {
    const inst = try make.instance(vm, class);
    for (class.fields, inst.fields()) |f, *slot| {
        if (f.is_signal or f.computed or !vm.checks.accepts(f.check, slot.*)) slot.* = try startValue(vm, f, depth);
    }
    return .fromObj(.instance, &inst.obj);
}

fn unset(vm: *Vm) Allocator.Error!Value {
    const n = try make.native(vm, "<field default>", failUnset, 0, null);
    return .fromObj(.native, &n.obj);
}

fn failUnset(vm: *Vm, _: []Value) Vm.Error!Value {
    return vm.fail("this field was added by a reload, and its default could not be made", .{});
}

fn doneTask(vm: *Vm) Allocator.Error!Value {
    const t = try make.task(vm);
    t.state = .done;
    return .fromObj(.task, &t.obj);
}

/// Every place a value from before the reload can be: objects older than
/// `since`, the registers of the main line and every task, and the roots.
fn renumberAll(vm: *Vm, list: []Renumbered, since: ?*object.Obj) void {
    renumberFiber(list, &vm.main);
    for (vm.roots.items) |*v| renumber(list, v, true);
    var o = since;
    while (o) |obj| : (o = obj.next) switch (obj.kind) {
        .list => for (object.List.from(obj).items.items) |*v| renumber(list, v, true),
        .map => {
            const t = &object.Map.from(obj).table;
            var keys = false;
            for (t.entries.items) |*e| {
                if (e.key.tag == .undefined) continue;
                const before = e.key.extra;
                renumber(list, &e.key, true);
                keys = keys or e.key.extra != before;
                renumber(list, &e.value, true);
            }
            if (keys) t.rehash();
        },
        .instance => for (object.Instance.from(obj).fields()) |*v| renumber(list, v, true),
        .upvalue => {
            const u = object.Upvalue.from(obj);
            if (u.location == &u.closed) renumber(list, &u.closed, true);
        },
        .module => for (object.Module.from(obj).globals.items) |*v| renumber(list, v, true),
        .task => {
            const t = object.Task.from(obj);
            renumber(list, &t.result, true);
            renumber(list, &t.waiting_on, true);
            renumberFiber(list, &t.fiber);
        },
        .method => renumber(list, &object.Method.from(obj).receiver, true),
        .handle => renumber(list, &object.Handle.from(obj).owner, true),
        else => {},
    };
}

fn renumberFiber(list: []Renumbered, f: *const @import("../vm/fiber.zig").Fiber) void {
    var it = f.used();
    while (it.next()) |values| for (values) |*v| renumber(list, v, true);
}

fn renumber(list: []Renumbered, v: *Value, count: bool) void {
    if (v.tag != .enum_value) return;
    for (list) |*r| if (v.obj() == &r.type.obj) {
        const to = if (v.extra < r.to.len) r.to[v.extra] else null;
        if (to == null and count) r.lost += 1;
        v.extra = to orelse 0;
        return;
    };
}
