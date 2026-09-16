// SPDX-License-Identifier: BSD-2-Clause

//! A module's new source put in while the program runs.
//!
//! The new source is compiled over the objects the old one made, and so is
//! every module importing it, so whatever holds them goes on with the new
//! code: the module itself, its structs (instances keep their identity, and
//! their fields are matched by name), its enums, its functions and methods
//! (a value holding one calls the new code). Variables declared as before
//! keep their values. Top-level statements do not run again; the
//! initializers of new variables do.
//!
//! Code from before can still be running: a task in the middle of a
//! function, a lambda made before. It reads fields by position and trusts
//! checks already made, so it may run on only if the reload kept every
//! shape it relies on (see `compile/shape.zig`). If one changed, tasks in
//! the middle of old code are stopped and old lambdas refuse to run, each
//! saying why; if none did, they finish in the code they started with.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const object = @import("vm/object.zig");
const make = @import("vm/make.zig");
const gc = @import("vm/gc.zig");
const call = @import("vm/call.zig");
const panic = @import("vm/panic.zig");
const code = @import("vm/code.zig");
const Compiler = @import("compile/Compiler.zig");
const Patch = Compiler.Patch;
const types = @import("compile/types.zig");
const migrate = @import("reload/migrate.zig");

pub const Error = error{
    /// The new source, or a module importing it, did not compile. Nothing
    /// changed; `vm.diagnostics` says why.
    CompileFailed,
    /// A script is running: reload between the host's calls into scripts.
    Busy,
    /// The new code is in, but an initializer or a field default it ran
    /// panicked; `vm.panic` says where.
    Panic,
    OutOfMemory,
};

pub const Report = struct {
    /// Modules compiled again: the one reloaded and those importing it.
    modules: u32 = 0,
    /// The first declaration whose shape changed, so that code from before
    /// could not run on; null when none did.
    changed: ?[]const u8 = null,
    /// Instances given their struct's new fields.
    instances: u32 = 0,
    /// Tasks stopped in the middle of code from before.
    stopped: u32 = 0,
};

pub fn reload(vm: *Vm, module: *object.Module, source: []const u8) Error!Report {
    if (vm.main.frames.items.len > 0 or vm.task != null or vm.current_native != null) return error.Busy;
    vm.diagnostics.deinit();
    vm.diagnostics = .init(vm.gpa);
    if (module.file == .none) {
        _ = try vm.diagnostics.err(.{ .file = .none, .span = .empty }, "`{s}` is made by the host: it has no source to reload", .{module.name.bytes()});
        return error.CompileFailed;
    }
    // No collection is left half done while objects change under it.
    try gc.collect(vm);
    vm.heap.paused += 1;
    var paused = true;
    defer if (paused) {
        vm.heap.paused -= 1;
    };

    const order = try recompileOrder(vm, module);
    defer vm.gpa.free(order);
    const since = vm.heap.objects;
    var old_code = try oldCode(vm, order);
    defer old_code.deinit(vm.gpa);
    const checks_len = vm.checks.items.items.len;
    const classes_len = vm.classes.items.len;

    const patches = try vm.gpa.alloc(Patch, order.len);
    defer vm.gpa.free(patches);
    for (order, 0..) |m, i| {
        patches[i] = .init(m);
        const text = if (m == module) source else vm.sources.get(m.file).?.text;
        Compiler.recompile(vm, &patches[i], text, &vm.diagnostics) catch |err| {
            undo(vm, patches[0 .. i + 1], checks_len, classes_len);
            return err;
        };
    }

    const session = vm.session.?;
    var report: Report = .{ .modules = @intCast(order.len) };
    for (patches) |*p| {
        const now = session.modules.get(p.module.path).?;
        if (report.changed == null) report.changed = changedShape(p.old_info.?, now);
    }

    // Everything that may run out of memory, before anything changes.
    var plan: migrate.Plan = .{};
    defer plan.deinit(vm.gpa);
    var stubs: std.ArrayList([]u32) = .empty;
    defer {
        for (stubs.items) |s| vm.gpa.free(s);
        stubs.deinit(vm.gpa);
    }
    var stopped: std.ArrayList(*object.Task) = .empty;
    defer stopped.deinit(vm.gpa);
    if (report.changed != null) prepare(vm, patches, since, &old_code, &plan, &stubs, &stopped) catch |err| {
        undo(vm, patches, checks_len, classes_len);
        return err;
    };

    // From here nothing fails, until the new code runs.
    for (patches) |*p| keepVariables(p, session.modules.get(p.module.path).?);
    resetCaches(since);
    if (report.changed != null) {
        stopTasks(vm, &old_code, report.changed.?, &stopped);
        dropConnections(vm, &old_code, since);
        stubCode(vm, &old_code, &stubs);
        migrate.apply(vm, &plan, since);
        report.instances = @intCast(plan.moves.items.len);
    }
    report.stopped = @intCast(stopped.items.len);
    for (patches) |*p| p.commit(vm.gpa);
    vm.heap.paused -= 1;
    paused = false;

    const keep = try make.list(vm, stopped.items.len, .any);
    for (stopped.items) |t| keep.items.appendAssumeCapacity(.fromObj(.task, &t.obj));
    try vm.pushRoot(.fromObj(.list, &keep.obj));
    defer vm.popRoot();
    try warn(vm, &plan);

    // The new code runs: the initializers of variables not kept, then the
    // defaults of fields the reload reset, then whatever waited on a task
    // it stopped.
    var failed = false;
    for (order) |m| {
        const main = m.main orelse continue;
        const closure = try make.closure(vm, main);
        _ = call.call(vm, .fromObj(.function, &closure.obj), &.{}) catch |err| switch (err) {
            error.Panic => failed = true,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (failed) break;
    }
    if (!failed) migrate.fillPending(vm, plan.pending.items) catch |err| switch (err) {
        error.Panic => failed = true,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const saved = vm.panic;
    vm.panic = null;
    for (stopped.items) |t| call.wakeWaiters(vm, t) catch {};
    if (vm.panic) |*p| p.deinit(vm.gpa);
    vm.panic = saved;
    if (failed) return error.Panic;
    return report;
}

/// The module and every module importing it, directly or not, each after
/// the modules it imports.
fn recompileOrder(vm: *Vm, target: *object.Module) Allocator.Error![]*object.Module {
    const gpa = vm.gpa;
    var set: std.AutoArrayHashMapUnmanaged(*object.Module, void) = .empty;
    defer set.deinit(gpa);
    try set.put(gpa, target, {});
    var grew = true;
    while (grew) {
        grew = false;
        var it = vm.modules.valueIterator();
        while (it.next()) |m| {
            if (set.contains(m.*)) continue;
            for (m.*.imports.items) |i| if (set.contains(i)) {
                try set.put(gpa, m.*, {});
                grew = true;
                break;
            };
        }
    }
    var order: std.ArrayList(*object.Module) = .empty;
    errdefer order.deinit(gpa);
    var placed: std.AutoHashMapUnmanaged(*object.Module, void) = .empty;
    defer placed.deinit(gpa);
    for (set.keys()) |m| try place(gpa, m, &set, &placed, &order);
    return order.toOwnedSlice(gpa);
}

fn place(gpa: Allocator, m: *object.Module, set: anytype, placed: anytype, order: *std.ArrayList(*object.Module)) Allocator.Error!void {
    if ((try placed.getOrPut(gpa, m)).found_existing) return;
    for (m.imports.items) |i| if (set.contains(i)) try place(gpa, i, set, placed, order);
    try order.append(gpa, m);
}

const ProtoSet = std.AutoHashMapUnmanaged(*object.Proto, void);

/// The code the modules have now, which the reload replaces.
fn oldCode(vm: *Vm, modules: []const *object.Module) Allocator.Error!ProtoSet {
    var set: ProtoSet = .empty;
    errdefer set.deinit(vm.gpa);
    var o = vm.heap.objects;
    while (o) |obj| : (o = obj.next) {
        if (obj.kind != .proto) continue;
        const p = object.Proto.from(obj);
        const m = p.module orelse continue;
        if (std.mem.indexOfScalar(*object.Module, modules, m) != null) try set.put(vm.gpa, p, {});
    }
    return set;
}

fn undo(vm: *Vm, patches: []Patch, checks_len: usize, classes_len: usize) void {
    const session = vm.session.?;
    var i = patches.len;
    while (i > 0) {
        i -= 1;
        const p = &patches[i];
        if (p.old_info) |info| if (session.modules.getPtr(p.module.path)) |slot| {
            slot.* = info;
        };
        p.rollback(vm.gpa);
    }
    vm.checks.items.shrinkRetainingCapacity(checks_len);
    vm.classes.shrinkRetainingCapacity(classes_len);
}

/// The first declaration code from before relies on that the new code
/// declares differently. One the new code drops is no matter: the old
/// code keeps what it had.
fn changedShape(old: *const types.Module, now: *const types.Module) ?[]const u8 {
    for (old.globals.keys(), old.globals.values()) |name, g| {
        const n = now.globals.get(name) orelse continue;
        if (n.kind != g.kind or !std.mem.eql(u8, n.shape, g.shape)) return name;
    }
    for (old.members.keys(), old.members.values()) |name, shape| {
        const n = now.members.get(name) orelse continue;
        if (!std.mem.eql(u8, n, shape)) return name;
    }
    return null;
}

fn prepare(vm: *Vm, patches: []Patch, since: ?*object.Obj, old_code: *const ProtoSet, plan: *migrate.Plan, stubs: *std.ArrayList([]u32), stopped: *std.ArrayList(*object.Task)) Allocator.Error!void {
    try migrate.plan(vm, patches, since, plan);
    try stubs.ensureTotalCapacity(vm.gpa, old_code.count());
    var it = old_code.keyIterator();
    while (it.next()) |_| {
        const stub = try vm.gpa.alloc(u32, 1);
        stub[0] = code.Instr.abc(.stale, 0, 0, 0).word();
        stubs.appendAssumeCapacity(stub);
    }
    try stopped.ensureTotalCapacity(vm.gpa, vm.scheduler.all.items.len);
}

/// Each variable keeps its value if it is declared as before - the same
/// kind, the same type - and the value was ever set. The rest are left
/// for `<main>` to initialize.
fn keepVariables(p: *Patch, now: *const types.Module) void {
    const old = p.old_info.?;
    for (now.globals.keys(), now.globals.values()) |name, g| {
        if (g.kind != .variable and g.kind != .constant) continue;
        const was = old.globals.get(name);
        const same = if (was) |w| w.kind == g.kind and !w.folded and std.mem.eql(u8, w.shape, g.shape) else false;
        if (g.folded or !same) p.module.globals.items[g.index] = .undef;
    }
}

/// What every call site learned about the old structs and methods is
/// forgotten: the next call looks again.
fn resetCaches(since: ?*object.Obj) void {
    var o = since;
    while (o) |obj| : (o = obj.next) {
        if (obj.kind == .proto) for (object.Proto.from(obj).caches) |*c| {
            c.* = .{};
        };
    }
}

fn stopTasks(vm: *Vm, old_code: *const ProtoSet, changed: []const u8, stopped: *std.ArrayList(*object.Task)) void {
    for (vm.scheduler.all.items) |t| {
        if (t.state == .done or t.state == .failed) continue;
        const frame = for (t.fiber.frames.items) |*fr| {
            if (old_code.contains(fr.proto)) break fr;
        } else continue;
        _ = vm.diagnostics.warn(.{ .file = frame.proto.file, .span = panic.spanOf(frame, false) }, "a task running this code was stopped: the reload changed `{s}`, which the code relies on", .{changed}) catch {};
        while (t.fiber.frames.items.len > 0) call.unwind(vm, &t.fiber);
        vm.scheduler.cancelTimer(t);
        t.state = .failed;
        t.failure = std.fmt.allocPrint(vm.gpa, "stopped by a reload that changed `{s}`", .{changed}) catch null;
        stopped.appendAssumeCapacity(t);
    }
}

/// Signal connections to lambdas the old code made: they can never run
/// again, so they go, each with a warning where the lambda was written.
fn dropConnections(vm: *Vm, old_code: *const ProtoSet, since: ?*object.Obj) void {
    var o = since;
    while (o) |obj| : (o = obj.next) {
        if (obj.kind != .signal) continue;
        const sig = object.Signal.from(obj);
        var i: usize = 0;
        while (i < sig.connections.items.len) {
            const target = sig.connections.items[i].target;
            const function = if (target.tag == .method) target.as(object.Method).function else target;
            if (function.tag != .function or !old_code.contains(function.as(object.Closure).proto)) {
                i += 1;
                continue;
            }
            const p = function.as(object.Closure).proto;
            _ = vm.diagnostics.warn(.{ .file = p.file, .span = p.decl }, "this was connected to `{s}`, and the reload replaced the code it comes from: the connection is dropped; connect it again", .{sig.name.bytes()}) catch {};
            _ = sig.connections.orderedRemove(i);
        }
    }
}

/// Code from before that nothing may run any more: every call to it
/// panics, saying why.
fn stubCode(vm: *Vm, old_code: *const ProtoSet, stubs: *std.ArrayList([]u32)) void {
    var it = old_code.keyIterator();
    while (it.next()) |p| {
        vm.gpa.free(p.*.code);
        p.*.code = stubs.pop().?;
        p.*.fast_entry = 0;
    }
}

/// What the reload could not keep: values of enum members that are gone,
/// and fields whose values no longer fit their types.
fn warn(vm: *Vm, plan: *const migrate.Plan) Allocator.Error!void {
    for (plan.enums.items) |r| if (r.lost > 0) {
        const m = r.type.module.?;
        const at = declaredAt(vm, m, r.type.name);
        _ = try vm.diagnostics.warn(at, "{d} stored value{s} of `{s}` held a member that is gone, and now hold{s} `.{s}`", .{ r.lost, plural(r.lost), r.type.name.bytes(), if (r.lost == 1) "s" else "", r.type.members[0].bytes() });
    };
    for (plan.dropped.items) |d| {
        const at = declaredAt(vm, d.class.module.?, d.class.name);
        _ = try vm.diagnostics.warn(at, "`{s}.{s}` is declared as another type now: {d} instance{s} start{s} it again from its default", .{ d.class.name.bytes(), d.name.bytes(), d.count, plural(d.count), if (d.count == 1) "s" else "" });
    }
}

fn declaredAt(vm: *Vm, m: *object.Module, name: *object.String) @import("diag.zig").Location {
    const info = vm.session.?.modules.get(m.path) orelse return .{ .file = m.file, .span = .empty };
    const g = info.globals.get(name.bytes()) orelse return .{ .file = m.file, .span = .empty };
    return .{ .file = m.file, .span = g.span };
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
