// SPDX-License-Identifier: BSD-2-Clause

//! A module compiled again over the objects it made before, for a reload:
//! the module, its structs, enums and functions are taken up again, so
//! whatever holds them - the host, instances, lists, signal connections -
//! goes on with the new code. What each held before is kept here until the
//! whole reload has compiled, and put back if any of it did not.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("../diag.zig");
const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const types = @import("types.zig");

const Patch = @This();

module: *object.Module,
/// The module as it was, its lists and tables still its own.
old: object.Module,
/// What the compiler knew of it: the shapes code compiled against it
/// relied on.
old_info: ?*types.Module = null,
classes: std.ArrayList(Kept(object.Class)) = .empty,
enums: std.ArrayList(Kept(object.EnumType)) = .empty,
closures: std.ArrayList(Repointed) = .empty,
begun: bool = false,

pub fn Kept(comptime T: type) type {
    return struct { object: *T, old: T };
}

const Repointed = struct { closure: *object.Closure, proto: *object.Proto };

pub fn init(module: *object.Module) Patch {
    return .{ .module = module, .old = module.* };
}

/// The module ready for the compile: every variable where it was, with
/// its value, and nothing else yet.
pub fn begin(p: *Patch, vm: *Vm, file: diag.FileId) Allocator.Error!void {
    const m = p.module;
    p.old = m.*;
    var globals = try p.old.globals.clone(vm.gpa);
    errdefer globals.deinit(vm.gpa);
    const names = try p.old.names.clone(vm.gpa);
    m.globals = globals;
    m.names = names;
    m.lookup = .empty;
    m.imports = .empty;
    m.tests = .empty;
    m.main = null;
    m.file = file;
    m.state = .loading;
    p.begun = true;
}

/// Where the module kept `name` before, so it stays there.
pub fn oldIndex(p: *const Patch, name: *object.String) ?u32 {
    return p.old.lookup.get(name);
}

fn oldValue(p: *const Patch, name: *object.String) ?Value {
    const i = p.oldIndex(name) orelse return null;
    return p.old.globals.items[i];
}

/// The struct this module declared as `name` before, emptied for the
/// compile to fill again.
pub fn reuseClass(p: *Patch, gpa: Allocator, name: *object.String) Allocator.Error!?*object.Class {
    const v = p.oldValue(name) orelse return null;
    if (v.tag != .class) return null;
    const class = v.as(object.Class);
    if (class.module != p.module or p.keptClass(class) != null) return null;
    try p.classes.append(gpa, .{ .object = class, .old = class.* });
    class.* = .{ .obj = class.obj, .name = class.name, .module = class.module };
    return class;
}

pub fn reuseEnum(p: *Patch, gpa: Allocator, name: *object.String) Allocator.Error!?*object.EnumType {
    const v = p.oldValue(name) orelse return null;
    if (v.tag != .enum_type) return null;
    const e = v.as(object.EnumType);
    if (e.module != p.module or p.keptEnum(e) != null) return null;
    try p.enums.append(gpa, .{ .object = e, .old = e.* });
    e.* = .{ .obj = e.obj, .name = e.name, .module = e.module };
    return e;
}

pub fn keptClass(p: *const Patch, class: *const object.Class) ?*const Kept(object.Class) {
    for (p.classes.items) |*k| if (k.object == class) return k;
    return null;
}

pub fn keptEnum(p: *const Patch, e: *const object.EnumType) ?*const Kept(object.EnumType) {
    for (p.enums.items) |*k| if (k.object == e) return k;
    return null;
}

/// The value this module had for the function `name`, now running
/// `proto`.
pub fn reuseFunction(p: *Patch, gpa: Allocator, name: *object.String, proto: *object.Proto) Allocator.Error!?*object.Closure {
    const v = p.oldValue(name) orelse return null;
    return p.repoint(gpa, v, name, null, proto);
}

/// The method, or the struct's own function, `class` had as `name`.
pub fn reuseMethod(p: *Patch, gpa: Allocator, class: *object.Class, name: *object.String, has_self: bool, proto: *object.Proto) Allocator.Error!?*object.Closure {
    const kept = p.keptClass(class) orelse return null;
    const v = (if (has_self) kept.old.methods.get(name) else kept.old.statics.get(name)) orelse return null;
    return p.repoint(gpa, v, name, class, proto);
}

pub fn reuseEnumMethod(p: *Patch, gpa: Allocator, e: *object.EnumType, name: *object.String, proto: *object.Proto) Allocator.Error!?*object.Closure {
    const kept = p.keptEnum(e) orelse return null;
    const v = kept.old.methods.get(name) orelse return null;
    return p.repoint(gpa, v, name, null, proto);
}

/// Only the closure the declaration itself made: not a lambda kept in a
/// constant, nor another module's function given the same name.
fn repoint(p: *Patch, gpa: Allocator, v: Value, name: *object.String, class: ?*object.Class, proto: *object.Proto) Allocator.Error!?*object.Closure {
    if (v.tag != .function) return null;
    const c = v.as(object.Closure);
    if (c.proto.module != p.module or c.proto.name != name or c.proto.class != class) return null;
    for (p.closures.items) |r| if (r.closure == c) return null;
    try p.closures.append(gpa, .{ .closure = c, .proto = c.proto });
    c.proto = proto;
    return c;
}

/// Everything as it was before `begin`: the reload did not compile.
pub fn rollback(p: *Patch, gpa: Allocator) void {
    for (p.closures.items) |r| r.closure.proto = r.proto;
    for (p.classes.items) |k| {
        freeClass(gpa, k.object.*);
        const header = k.object.obj;
        k.object.* = k.old;
        k.object.obj = header;
    }
    for (p.enums.items) |k| {
        freeEnum(gpa, k.object.*);
        const header = k.object.obj;
        k.object.* = k.old;
        k.object.obj = header;
    }
    if (p.begun) {
        freeModule(gpa, p.module.*);
        const header = p.module.obj;
        p.module.* = p.old;
        p.module.obj = header;
    }
    p.deinit(gpa);
}

/// Frees what the objects held before: the new code is in.
pub fn commit(p: *Patch, gpa: Allocator) void {
    for (p.classes.items) |k| freeClass(gpa, k.old);
    for (p.enums.items) |k| freeEnum(gpa, k.old);
    if (p.begun) freeModule(gpa, p.old);
    p.deinit(gpa);
}

fn deinit(p: *Patch, gpa: Allocator) void {
    p.classes.deinit(gpa);
    p.enums.deinit(gpa);
    p.closures.deinit(gpa);
}

fn freeClass(gpa: Allocator, class: object.Class) void {
    var c = class;
    for (c.fields) |f| if (f.doc) |d| gpa.free(d);
    gpa.free(c.fields);
    c.slots.deinit(gpa);
    c.methods.deinit(gpa);
    c.statics.deinit(gpa);
    if (c.doc) |d| gpa.free(d);
}

fn freeEnum(gpa: Allocator, e: object.EnumType) void {
    var copy = e;
    gpa.free(copy.members);
    gpa.free(copy.values);
    copy.methods.deinit(gpa);
}

/// Its lists and tables; the path stays, shared by both.
fn freeModule(gpa: Allocator, m: object.Module) void {
    var copy = m;
    copy.globals.deinit(gpa);
    copy.names.deinit(gpa);
    copy.lookup.deinit(gpa);
    copy.tests.deinit(gpa);
    copy.imports.deinit(gpa);
}
