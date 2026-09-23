// SPDX-License-Identifier: BSD-2-Clause

//! Calls that leave the instruction loop: from the host, from a native, into
//! a new task; and what a return, an `await` and a panic undo.

const std = @import("std");

const Vm = @import("Vm.zig");
const Value = @import("value.zig").Value;
const object = @import("object.zig");
const make = @import("make.zig");
const types = @import("types.zig");
const fiber_mod = @import("fiber.zig");
const Fiber = fiber_mod.Fiber;
const exec = @import("exec.zig");
const Error = Vm.Error;

pub fn badArity(vm: *Vm, p: *const object.Proto, given: usize) Error {
    @branchHint(.cold);
    const name = p.name.bytes();
    if (p.required == p.params) {
        return vm.fail("`{s}` takes {d} argument{s}, and was given {d}", .{ name, p.params - @intFromBool(p.has_self), plural(p.params - @intFromBool(p.has_self)), given -| @intFromBool(p.has_self) });
    }
    return vm.fail("`{s}` takes {d} to {d} arguments, and was given {d}", .{ name, p.required - @intFromBool(p.has_self), p.params - @intFromBool(p.has_self), given -| @intFromBool(p.has_self) });
}

pub fn badNativeArity(vm: *Vm, n: *const object.Native, given: usize) Error {
    @branchHint(.cold);
    if (n.max) |max| {
        if (max == n.min) return vm.fail("`{s}` takes {d} argument{s}, and was given {d}", .{ n.name, max, plural(max), given });
        return vm.fail("`{s}` takes {d} to {d} arguments, and was given {d}", .{ n.name, n.min, max, given });
    }
    return vm.fail("`{s}` takes at least {d} argument{s}, and was given {d}", .{ n.name, n.min, plural(n.min), given });
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

pub fn stackOverflow(vm: *Vm) Error {
    @branchHint(.cold);
    return vm.fail("stack overflow: more than {d} calls deep", .{vm.options.max_frames});
}

pub fn notCallable(vm: *Vm, v: Value) Error {
    @branchHint(.cold);
    if (v.tag == .class) return vm.fail("a struct is made with `{s}{{ ... }}`, or by a function of its own such as `{s}.init(...)`", .{ v.as(object.Class).name.bytes(), v.as(object.Class).name.bytes() });
    if (v.tag == .null) return vm.fail("cannot call null", .{});
    return vm.fail("cannot call {s}", .{types.typeName(v)});
}

/// The captured variable for register `reg` of the top frame, made on
/// first capture and shared after.
pub fn capture(vm: *Vm, f: *Fiber, depth: u32, reg: u32, location: *Value) Error!*object.Upvalue {
    var link: *?*object.Upvalue = &f.open;
    while (link.*) |u| {
        if (u.frame < depth or (u.frame == depth and u.reg < reg)) break;
        if (u.frame == depth and u.reg == reg) return u;
        link = &u.next;
    }
    const fresh = try make.upvalue(vm, location, depth, reg);
    fresh.next = link.*;
    link.* = fresh;
    return fresh;
}

/// Closes the captured variables of frame `depth` at register `from` and up:
/// each takes its own copy of the value and stops looking at the register.
pub fn close(vm: *Vm, f: *Fiber, depth: u32, from: u32) void {
    while (f.open) |u| {
        if (u.frame < depth or (u.frame == depth and u.reg < from)) break;
        u.closed = u.location.*;
        u.location = &u.closed;
        f.open = u.next;
        u.next = null;
        vm.heap.barrier(&u.obj, u.closed);
    }
}

/// Pops frames back to the nearest boundary, closing what they captured.
pub fn unwind(vm: *Vm, f: *Fiber) void {
    while (f.frames.items.len > 0) {
        const depth: u32 = @intCast(f.frames.items.len - 1);
        close(vm, f, depth, 0);
        const boundary = f.frames.items[depth].boundary;
        f.frames.items.len -= 1;
        f.popped();
        if (boundary) break;
    }
}

/// Runs `callee` with `args` to its end, from Zig: the host, or a native
/// such as `list.sort` calling back into the script. A coroutine is started
/// as a task instead, and the task is what comes back.
pub fn call(vm: *Vm, callee: Value, args: []const Value) Error!Value {
    switch (callee.tag) {
        .function => {
            const c = callee.as(object.Closure);
            if (c.proto.coroutine) return spawn(vm, c, args);
            return callClosure(vm, vm.fiber, c, args);
        },
        .native => {
            const n = callee.as(object.Native);
            if (args.len < n.min or (n.max != null and args.len > n.max.?)) return badNativeArity(vm, n, args.len);
            const f = vm.fiber;
            const at = try f.free(vm.gpa, args.len);
            @memcpy(at[0..args.len], args);
            const saved = vm.current_native;
            vm.current_native = n;
            defer vm.current_native = saved;
            return n.func(vm, at[0..args.len]);
        },
        .method => {
            const m = callee.as(object.Method);
            const f = vm.fiber;
            const at = try f.free(vm.gpa, args.len + 1);
            at[0] = m.receiver;
            @memcpy(at[1 .. args.len + 1], args);
            const joined = at[0 .. args.len + 1];
            return call(vm, m.function, joined);
        },
        else => return notCallable(vm, callee),
    }
}

fn callClosure(vm: *Vm, f: *Fiber, c: *object.Closure, args: []const Value) Error!Value {
    const p = c.proto;
    if (args.len < p.required or args.len > p.params) return badArity(vm, p, args.len);
    if (f.frames.items.len >= vm.options.max_frames) return stackOverflow(vm);
    const at = try f.free(vm.gpa, 1 + p.regs);
    const base = at + 1;
    if (args.len > 0) {
        if (@intFromPtr(base) > @intFromPtr(args.ptr)) {
            std.mem.copyBackwards(Value, base[0..args.len], args);
        } else {
            std.mem.copyForwards(Value, base[0..args.len], args);
        }
    }
    at[0] = .null;
    for (base[args.len..p.regs]) |*r| r.* = .null;
    try checkParams(vm, p, base, args.len);
    try f.frames.append(vm.gpa, .{
        .closure = c,
        .proto = p,
        .ip = p.code.ptr,
        .base = base,
        .result = &at[0],
        .chunk = f.current,
        .args = @intCast(args.len),
        .boundary = true,
    });
    return exec.run(vm, f) catch |err| {
        unwind(vm, f);
        return switch (err) {
            error.Suspend => vm.fail("a coroutine cannot wait here: it was entered from native code", .{}),
            error.Panic => error.Panic,
            error.OutOfMemory => error.OutOfMemory,
        };
    };
}

/// The computed starting values of a new instance's fields, the parent
/// struct's first.
pub fn initDefaults(vm: *Vm, inst: Value) Error!void {
    var chain: [32]*object.Class = undefined;
    var n: usize = 0;
    var at: ?*object.Class = inst.as(object.Instance).class;
    while (at) |c| : (at = c.parent) {
        if (n == chain.len) break;
        chain[n] = c;
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        if (chain[n].defaults) |d| _ = try call(vm, .fromObj(.function, &d.obj), &.{inst});
    }
}

/// Runs a module's imports, then the module: once each.
pub fn runModule(vm: *Vm, m: *object.Module) Error!void {
    if (m.ran) return;
    m.ran = true;
    for (m.imports.items) |i| try runModule(vm, i);
    const main = m.main orelse return;
    const closure = try make.closure(vm, main);
    _ = try call(vm, .fromObj(.function, &closure.obj), &.{});
}

/// Typed parameters of a function entered from untyped code.
pub fn checkParams(vm: *Vm, p: *const object.Proto, base: [*]Value, given: usize) Error!void {
    for (p.param_checks[0..@min(given, p.param_checks.len)], 0..) |check, i| {
        if (check == .any) continue;
        base[i] = vm.checks.coerce(check, base[i]) orelse {
            const name = if (i < p.param_names.len) p.param_names[i].bytes() else "?";
            return @import("access.zig").wrongType(vm, check, base[i], name);
        };
    }
}

/// A coroutine called without `await`: a task of its own, run until it
/// first waits or ends.
pub fn spawn(vm: *Vm, c: *object.Closure, args: []const Value) Error!Value {
    const p = c.proto;
    if (args.len < p.required or args.len > p.params) return badArity(vm, p, args.len);
    const t = try make.task(vm);
    t.owner = if (vm.task) |parent| parent.owner else vm.task_owner;
    const tv: Value = .fromObj(.task, &t.obj);
    try vm.pushRoot(tv);
    defer vm.popRoot();
    const at = try t.fiber.free(vm.gpa, 1 + p.regs);
    at[0] = .null;
    const base = at + 1;
    @memcpy(base[0..args.len], args);
    for (base[args.len..p.regs]) |*r| r.* = .null;
    try checkParams(vm, p, base, args.len);
    try t.fiber.frames.append(vm.gpa, .{
        .closure = c,
        .proto = p,
        .ip = p.code.ptr,
        .base = base,
        .result = &at[0],
        .chunk = t.fiber.current,
        .args = @intCast(args.len),
        .boundary = true,
    });
    try runTask(vm, t);
    return tv;
}

/// Runs a task until it waits or ends, as the current task.
pub fn runTask(vm: *Vm, t: *object.Task) Error!void {
    const saved_fiber = vm.fiber;
    const saved_task = vm.task;
    const saved_panic_native = vm.current_native;
    if (saved_task) |outer| try vm.pushRoot(.fromObj(.task, &outer.obj));
    vm.fiber = &t.fiber;
    vm.task = t;
    vm.current_native = null;
    defer {
        vm.fiber = saved_fiber;
        vm.task = saved_task;
        vm.current_native = saved_panic_native;
        if (saved_task != null) vm.popRoot();
    }
    t.state = .running;
    const outcome = if (t.awaited_failure) |why| failAwait(vm, t, why) else exec.run(vm, &t.fiber);
    const result = outcome catch |err| switch (err) {
        error.Suspend => {
            t.state = .suspended;
            return;
        },
        error.OutOfMemory => {
            while (t.fiber.frames.items.len > 0) unwind(vm, &t.fiber);
            t.state = .failed;
            return error.OutOfMemory;
        },
        error.Panic => {
            while (t.fiber.frames.items.len > 0) unwind(vm, &t.fiber);
            t.state = .failed;
            if (vm.panic) |*p| {
                t.failure = vm.gpa.dupe(u8, p.message) catch null;
                if (t.waiters.items.len == 0) {
                    if (vm.options.on_task_panic) |report| report(vm, p);
                }
            }
            vm.clearPanic();
            try wakeWaiters(vm, t);
            return;
        },
    };
    t.state = .done;
    t.result = result;
    vm.heap.barrier(&t.obj, result);
    try wakeWaiters(vm, t);
}

/// The task this one waited for failed, and so does this one, at its
/// `await`.
fn failAwait(vm: *Vm, t: *object.Task, why: []u8) exec.RunError!Value {
    t.awaited_failure = null;
    defer vm.gpa.free(why);
    const top = &t.fiber.frames.items[t.fiber.frames.items.len - 1];
    top.ip -= 1;
    return vm.fail("the awaited task failed: {s}", .{why});
}

pub fn wakeWaiters(vm: *Vm, t: *object.Task) Error!void {
    const tv: Value = .fromObj(.task, &t.obj);
    try vm.pushRoot(tv);
    defer vm.popRoot();
    while (t.waiters.pop()) |w| {
        if (t.state == .failed and w.state == .suspended) {
            w.awaited_failure = try vm.gpa.dupe(u8, t.failure orelse "(no message)");
        }
        try resumeTask(vm, w, t.result);
    }
}

/// Gives a waiting task the value it waited for, and runs it on.
pub fn resumeTask(vm: *Vm, t: *object.Task, v: Value) Error!void {
    if (t.state != .suspended) return;
    if (t.await_reg) |r| r.* = v;
    t.await_reg = null;
    t.waiting_on = .null;
    try runTask(vm, t);
}

pub const Wait = union(enum) {
    ready: Value,
    wait,
};

/// What `await v` does in a task: a value that is not awaitable is ready
/// at once; a task, a signal or a timer makes this task wait for it.
pub fn prepareAwait(vm: *Vm, into: *Value, v: Value) Error!Wait {
    const t = vm.task orelse {
        return switch (v.tag) {
            .task, .signal => vm.fail("`await` can only wait inside a coroutine that runs as a task", .{}),
            else => .{ .ready = v },
        };
    };
    switch (v.tag) {
        .task => {
            const other = v.as(object.Task);
            switch (other.state) {
                .done => return .{ .ready = other.result },
                .failed => return vm.fail("the awaited task failed: {s}", .{other.failure orelse "(no message)"}),
                else => {
                    if (other == t) return vm.fail("a task cannot wait for itself", .{});
                    try other.waiters.append(vm.gpa, t);
                    vm.heap.barrierObj(&other.obj, &t.obj);
                },
            }
        },
        .signal => {
            const s = v.as(object.Signal);
            try s.waiters.append(vm.gpa, t);
            vm.heap.barrierObj(&s.obj, &t.obj);
        },
        .float, .int => {
            try vm.scheduler.sleep(vm.gpa, t, vm.scheduler.time + v.toFloat().?);
        },
        else => return .{ .ready = v },
    }
    t.await_reg = into;
    t.waiting_on = v;
    vm.heap.barrier(&t.obj, v);
    return .wait;
}

/// Moves time on and wakes every task whose wait is over, earliest first.
pub fn update(vm: *Vm, dt: f64) Error!void {
    return updateHolding(vm, dt, null);
}

/// `update`, with the tasks whose owner `held` says so kept where they are:
/// their waits are pushed back by `dt`, so they neither wake nor come
/// nearer to it.
pub fn updateHolding(vm: *Vm, dt: f64, held: ?@import("../api.zig").Held) Error!void {
    if (held) |asked| vm.scheduler.hold(dt, asked.context, asked.held);
    vm.scheduler.time += dt;
    while (vm.scheduler.due()) |t| {
        try vm.pushRoot(.fromObj(.task, &t.obj));
        defer vm.popRoot();
        try resumeTask(vm, t, .null);
    }
}
