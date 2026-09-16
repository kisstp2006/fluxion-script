// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

const Vm = @import("Vm.zig");
const Value = @import("value.zig").Value;
const object = @import("object.zig");
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const Obj = object.Obj;
const Fiber = @import("fiber.zig").Fiber;

const Marker = struct {
    heap: *Heap,
    pub fn value(m: Marker, v: Value) void {
        m.heap.markValue(v);
    }
};

fn markFiber(vm: *Vm, f: *Fiber) void {
    const m: Marker = .{ .heap = &vm.heap };
    f.live(m);
    for (f.frames.items) |fr| {
        vm.heap.mark(&fr.closure.obj);
        vm.heap.mark(&fr.proto.obj);
    }
    var up = f.open;
    while (up) |u| : (up = u.next) vm.heap.mark(&u.obj);
}

fn markMap(h: *Heap, map: anytype) void {
    var it = map.iterator();
    while (it.next()) |e| {
        h.mark(&e.key_ptr.*.obj);
        h.markValue(e.value_ptr.*);
    }
}

fn markRoots(vm: *Vm) void {
    const h = &vm.heap;
    markFiber(vm, &vm.main);
    for (vm.roots.items) |v| h.markValue(v);
    var held = vm.held.keyIterator();
    while (held.next()) |o| h.mark(o.*);
    var mods = vm.modules.valueIterator();
    while (mods.next()) |m| h.mark(&m.*.obj);
    var natives = vm.native_modules.valueIterator();
    while (natives.next()) |m| h.mark(&m.*.obj);
    markMap(h, vm.prelude);
    for (&vm.methods.values) |*table| markMap(h, table.*);
    for (vm.classes.items) |c| h.mark(&c.obj);
    var reflected = vm.reflect_methods.valueIterator();
    while (reflected.next()) |n| h.mark(&n.*.obj);
    vm.scheduler.mark(h);
    if (vm.task) |t| h.mark(&t.obj);
}

fn traverse(vm: *Vm, o: *Obj) usize {
    const h = &vm.heap;
    switch (o.kind) {
        .string => return @sizeOf(object.String) + object.String.from(o).len,
        .list => {
            const l = object.List.from(o);
            for (l.items.items) |v| h.markValue(v);
            return @sizeOf(object.List) + l.items.items.len * @sizeOf(Value);
        },
        .map => {
            const m = object.Map.from(o);
            for (m.table.entries.items) |e| {
                h.markValue(e.key);
                h.markValue(e.value);
            }
            return @sizeOf(object.Map) + m.table.entries.items.len * @sizeOf(@TypeOf(m.table.entries.items[0]));
        },
        .instance => {
            const i = object.Instance.from(o);
            h.mark(&i.class.obj);
            for (i.fields()) |v| h.markValue(v);
            return @sizeOf(object.Instance) + i.count * @sizeOf(Value);
        },
        .closure => {
            const c = object.Closure.from(o);
            h.mark(&c.proto.obj);
            for (c.upvals()) |u| h.mark(&u.obj);
            return @sizeOf(object.Closure) + c.count * 8;
        },
        .upvalue => {
            const u = object.Upvalue.from(o);
            h.markValue(u.location.*);
            return @sizeOf(object.Upvalue);
        },
        .proto => {
            const p = object.Proto.from(o);
            h.mark(&p.name.obj);
            for (p.constants) |v| h.markValue(v);
            for (p.protos) |child| h.mark(&child.obj);
            for (p.param_names) |n| h.mark(&n.obj);
            for (p.caches) |c| {
                if (c.class) |k| h.mark(&k.obj);
                h.markValue(c.method);
            }
            if (p.module) |m| h.mark(&m.obj);
            if (p.class) |k| h.mark(&k.obj);
            return @sizeOf(object.Proto) + p.code.len * 4 + p.constants.len * @sizeOf(Value);
        },
        .native => return @sizeOf(object.Native),
        .method => {
            const m = object.Method.from(o);
            h.markValue(m.receiver);
            h.markValue(m.function);
            return @sizeOf(object.Method);
        },
        .class => {
            const c = object.Class.from(o);
            h.mark(&c.name.obj);
            if (c.parent) |p| h.mark(&p.obj);
            if (c.module) |m| h.mark(&m.obj);
            if (c.defaults) |d| h.mark(&d.obj);
            if (c.annotations) |a| h.mark(&a.obj);
            for (c.fields) |f| {
                h.mark(&f.name.obj);
                h.markValue(f.default);
                if (f.annotations) |a| h.mark(&a.obj);
            }
            markMap(h, c.methods);
            markMap(h, c.statics);
            return @sizeOf(object.Class) + c.fields.len * @sizeOf(object.Field);
        },
        .enum_type => {
            const e = object.EnumType.from(o);
            h.mark(&e.name.obj);
            for (e.members) |m| h.mark(&m.obj);
            markMap(h, e.methods);
            if (e.module) |m| h.mark(&m.obj);
            return @sizeOf(object.EnumType);
        },
        .module => {
            const m = object.Module.from(o);
            h.mark(&m.name.obj);
            for (m.globals.items) |v| h.markValue(v);
            for (m.names.items) |n| h.mark(&n.obj);
            if (m.main) |p| h.mark(&p.obj);
            for (m.tests.items) |t| {
                h.mark(&t.name.obj);
                h.mark(&t.function.obj);
            }
            for (m.imports.items) |i| h.mark(&i.obj);
            return @sizeOf(object.Module) + m.globals.items.len * @sizeOf(Value);
        },
        .task => {
            const t = object.Task.from(o);
            markFiber(vm, &t.fiber);
            h.markValue(t.result);
            h.markValue(t.waiting_on);
            for (t.waiters.items) |w| h.mark(&w.obj);
            return @sizeOf(object.Task);
        },
        .signal => {
            const s = object.Signal.from(o);
            h.mark(&s.name.obj);
            for (s.connections.items) |c| h.markValue(c.target);
            for (s.waiters.items) |w| h.mark(&w.obj);
            return @sizeOf(object.Signal);
        },
        .error_value => {
            const e = object.ErrorValue.from(o);
            h.mark(&e.name.obj);
            if (e.message) |m| h.mark(&m.obj);
            return @sizeOf(object.ErrorValue);
        },
        .color => return @sizeOf(object.Color),
        .handle => {
            const hd = object.Handle.from(o);
            h.markValue(hd.owner);
            return @sizeOf(object.Handle);
        },
    }
}

fn propagate(vm: *Vm, budget: usize) usize {
    var done: usize = 0;
    while (done < budget) {
        const o = vm.heap.gray.pop() orelse break;
        if (Heap.isBlack(o)) continue;
        o.color = heap_mod.black;
        done += traverse(vm, o);
    }
    return done;
}

fn startCycle(vm: *Vm) void {
    vm.heap.phase = .mark;
    vm.heap.gray.clearRetainingCapacity();
    markRoots(vm);
}

/// The one step that cannot be split: registers are marked again, since
/// nothing watched them, and the whites trade places.
fn atomic(vm: *Vm) void {
    const h = &vm.heap;
    markRoots(vm);
    for (vm.scheduler.all.items) |t| {
        if (!Heap.isWhite(&t.obj)) markFiber(vm, &t.fiber);
    }
    _ = propagate(vm, std.math.maxInt(usize));
    if (h.options.verify) verify(vm);
    vm.main.clearDead();
    for (vm.scheduler.all.items) |t| {
        if (!Heap.isWhite(&t.obj)) t.fiber.clearDead();
    }
    h.white = h.otherWhite();
    h.phase = .sweep;
    h.sweep_prev = &h.objects;
    h.live_after = 0;
}

fn verify(vm: *Vm) void {
    var obj = vm.heap.objects;
    const Check = struct {
        pub fn value(_: @This(), v: Value) void {
            if (v.tag.isObject() or v.tag == .enum_value) std.debug.assert(!Heap.isWhite(v.obj()));
        }
    };
    while (obj) |o| : (obj = o.next) {
        if (!Heap.isBlack(o)) continue;
        if (o.kind == .list) for (object.List.from(o).items.items) |v| Check.value(.{}, v);
        if (o.kind == .instance) for (object.Instance.from(o).fields()) |v| Check.value(.{}, v);
        if (o.kind == .module) for (object.Module.from(o).globals.items) |v| Check.value(.{}, v);
    }
}

fn sweep(vm: *Vm, budget: usize) bool {
    const h = &vm.heap;
    const dead = h.otherWhite();
    var done: usize = 0;
    var prev = h.sweep_prev.?;
    while (prev.*) |o| {
        if (done >= budget) {
            h.sweep_prev = prev;
            return false;
        }
        done += 1;
        if (o.color & dead != 0 and o.color & heap_mod.black == 0) {
            prev.* = o.next;
            free(vm, o);
        } else {
            o.color = h.white;
            h.live_after += 1;
            prev = &o.next;
        }
    }
    h.sweep_prev = null;
    return true;
}

fn finishCycle(vm: *Vm) void {
    const h = &vm.heap;
    h.phase = .idle;
    h.cycles += 1;
    const base = @max(h.bytes, 256 * 1024);
    h.threshold = base / 100 * h.options.pause;
    h.debt = @as(isize, @intCast(h.bytes)) - @as(isize, @intCast(h.threshold));
}

/// Some collection work, in proportion to what has been allocated since
/// the last step.
pub fn step(vm: *Vm) Allocator.Error!void {
    const h = &vm.heap;
    if (h.paused > 0) return;
    if (!h.options.incremental) {
        if (h.debt > 0) try collect(vm);
        return;
    }
    const work: usize = step_size * h.options.step_multiplier / 100;
    switch (h.phase) {
        .idle => {
            startCycle(vm);
            _ = propagate(vm, work);
        },
        .mark => {
            if (propagate(vm, work) < work) atomic(vm);
        },
        .sweep => {
            if (sweep(vm, work / 64 + 64)) finishCycle(vm);
        },
    }
    if (h.phase != .idle) h.debt = -@as(isize, step_size);
}

/// Bytes allocated between two steps of a cycle.
const step_size = 64 * 1024;

/// A whole cycle now, from wherever the last one was.
pub fn collect(vm: *Vm) Allocator.Error!void {
    const h = &vm.heap;
    if (h.paused > 0) return;
    if (h.phase == .sweep) {
        _ = sweep(vm, std.math.maxInt(usize));
        finishCycle(vm);
    }
    if (h.phase == .idle) startCycle(vm);
    _ = propagate(vm, std.math.maxInt(usize));
    atomic(vm);
    _ = sweep(vm, std.math.maxInt(usize));
    finishCycle(vm);
}

pub fn free(vm: *Vm, o: *Obj) void {
    const gpa = vm.gpa;
    vm.object_count -= 1;
    switch (o.kind) {
        .string => {
            const s = object.String.from(o);
            if (o.flags == 1) vm.interned.remove(s);
            release(vm, s, s.len + 1);
        },
        .list => {
            const l = object.List.from(o);
            l.items.deinit(gpa);
            release(vm, l, 0);
        },
        .map => {
            const m = object.Map.from(o);
            m.table.deinit(gpa);
            release(vm, m, 0);
        },
        .instance => {
            const i = object.Instance.from(o);
            var made = @max(i.count, 1);
            if (o.flags & object.Instance.moved != 0) {
                const m = i.movedTo();
                vm.heap.bytes -|= i.count * @sizeOf(Value);
                gpa.free(m.values[0..i.count]);
                made = m.made;
            }
            release(vm, i, made * @sizeOf(Value));
        },
        .closure => {
            const c = object.Closure.from(o);
            release(vm, c, c.count * @sizeOf(*object.Upvalue));
        },
        .upvalue => release(vm, object.Upvalue.from(o), 0),
        .proto => {
            const p = object.Proto.from(o);
            gpa.free(p.code);
            gpa.free(p.spans);
            gpa.free(p.constants);
            gpa.free(p.protos);
            gpa.free(p.upvals);
            gpa.free(p.caches);
            gpa.free(p.param_checks);
            gpa.free(p.param_names);
            release(vm, p, 0);
        },
        .native => release(vm, object.Native.from(o), 0),
        .method => release(vm, object.Method.from(o), 0),
        .class => {
            const c = object.Class.from(o);
            for (c.fields) |f| if (f.doc) |d| gpa.free(d);
            gpa.free(c.fields);
            c.slots.deinit(gpa);
            c.methods.deinit(gpa);
            c.statics.deinit(gpa);
            if (c.doc) |d| gpa.free(d);
            release(vm, c, 0);
        },
        .enum_type => {
            const e = object.EnumType.from(o);
            gpa.free(e.members);
            gpa.free(e.values);
            e.methods.deinit(gpa);
            release(vm, e, 0);
        },
        .module => {
            const m = object.Module.from(o);
            m.globals.deinit(gpa);
            m.names.deinit(gpa);
            m.lookup.deinit(gpa);
            m.tests.deinit(gpa);
            m.imports.deinit(gpa);
            gpa.free(m.path);
            release(vm, m, 0);
        },
        .task => {
            const t = object.Task.from(o);
            vm.scheduler.forget(t);
            t.fiber.deinit(gpa);
            t.waiters.deinit(gpa);
            if (t.failure) |f| gpa.free(f);
            if (t.awaited_failure) |f| gpa.free(f);
            release(vm, t, 0);
        },
        .signal => {
            const s = object.Signal.from(o);
            s.connections.deinit(gpa);
            s.waiters.deinit(gpa);
            release(vm, s, 0);
        },
        .error_value => release(vm, object.ErrorValue.from(o), 0),
        .color => release(vm, object.Color.from(o), 0),
        .handle => {
            const h = object.Handle.from(o);
            if (h.owned) h.value.destroy(gpa);
            release(vm, h, 0);
        },
    }
}

fn release(vm: *Vm, ptr: anytype, extra: usize) void {
    const T = @TypeOf(ptr.*);
    const size = @sizeOf(T) + extra;
    vm.heap.bytes -|= size;
    const bytes: [*]align(@alignOf(T)) u8 = @ptrCast(ptr);
    vm.gpa.free(bytes[0..size]);
}

pub fn freeAll(vm: *Vm) void {
    var obj = vm.heap.objects;
    while (obj) |o| {
        obj = o.next;
        free(vm, o);
    }
    vm.heap.objects = null;
}
