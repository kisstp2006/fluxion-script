// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("../diag.zig");
const value_mod = @import("value.zig");
const object = @import("object.zig");
const heap_mod = @import("heap.zig");
const strings = @import("strings.zig");
const types = @import("types.zig");
const Fiber = @import("fiber.zig").Fiber;
const gc = @import("gc.zig");
const reflect = @import("fluxion_reflect");

pub const Value = value_mod.Value;
pub const Tag = value_mod.Tag;
pub const Obj = object.Obj;

const Vm = @This();

/// To fluxion-reflect, a VM is a thing to point at, not a struct to look
/// into: a reflected method may take the `*Vm` that calls it.
pub const reflect_opaque = true;
pub const reflect_name = "flux.Vm";

pub const Error = error{ Panic, OutOfMemory };

pub const Loader = struct {
    context: ?*anyopaque = null,
    /// The source of the module `path` names, as imported from `from` (the
    /// path of the importing file, or "" for the host), and its canonical
    /// name: the same file imported twice must give the same name.
    load: *const fn (context: ?*anyopaque, gpa: Allocator, from: []const u8, path: []const u8) anyerror!Loaded,

    pub const Loaded = struct { name: []u8, source: []u8 };
};

pub const Options = struct {
    out: ?*std.Io.Writer = null,
    gc: heap_mod.Options = .{},
    max_frames: u32 = 8000,
    /// The most bytes the scripts' objects may take; past it an allocation
    /// fails with `error.OutOfMemory` rather than the host running out.
    max_bytes: ?usize = null,
    loader: ?Loader = null,
    io: ?std.Io = null,
    /// Called with every panic in a task nothing is waiting for.
    on_task_panic: ?*const fn (vm: *Vm, panic: *const Panic) void = null,
    /// Called once for every emit of an instance's signal, by a script or by
    /// `vm.emitSignal`, after the signal's own connections: how an engine
    /// hears its scripts' signals without connecting to each. An error it
    /// returns stops the script that emitted, as a native's does.
    on_emit: ?*const fn (vm: *Vm, instance: Value, signal: []const u8, args: []const Value) Error!void = null,
    /// Types of the host's that a script sees as something else: an engine's
    /// entity as the handle its scripts know entities by. See `HostType`.
    host_types: []const HostType = &.{},
    /// Asked for a member of one of the host's values - a handle - that is
    /// none of its fields: a signal an engine's component declares, as
    /// `timer.timeout`. Null when the host has nothing by that name, and the
    /// script is told so.
    host_member: ?*const fn (vm: *Vm, handle: Value, name: []const u8) Error!?Value = null,
    /// The same, for a member written: `label.text = "Hi"` on a component
    /// whose words the host keeps beside it. True when the host took it,
    /// false for the usual "has no field" panic.
    host_set_member: ?*const fn (vm: *Vm, handle: Value, name: []const u8, value: Value) Error!bool = null,
};

/// One of the host's types as a script sees it. Asked first whenever a
/// value of the type crosses between the host and a script: a field read or
/// written through a handle, a reflected method's argument or result, and
/// `valueOf`. The functions read and write the value itself, of `type`.
pub const HostType = struct {
    type: *const reflect.Type,
    /// The value as the script's. `vm.host` is the host's, to find its
    /// own things by.
    to_script: *const fn (vm: *Vm, value: reflect.Value) Error!Value,
    /// The script's value written into the host's. One that is not of this
    /// type is the host's to refuse, with `vm.fail` and a message saying
    /// what was wanted.
    from_script: *const fn (vm: *Vm, into: reflect.Value, value: Value) Error!void,
};

pub const TraceFrame = struct {
    function: []const u8,
    file: diag.FileId,
    span: diag.Span,
};

pub const Panic = struct {
    message: []const u8,
    trace: []const TraceFrame,
    /// Where it happened: the top frame's place, or none for a native.
    file: diag.FileId = .none,
    span: diag.Span = .empty,

    pub fn deinit(p: *Panic, gpa: Allocator) void {
        gpa.free(p.message);
        for (p.trace) |f| gpa.free(f.function);
        gpa.free(p.trace);
        p.* = undefined;
    }
};

pub const BuiltinType = enum { string, list, map, vec2, vec3, color, signal, task, @"error", int, float, bool };

gpa: Allocator,
options: Options,
heap: heap_mod.Heap,
interned: strings.Interned = .{},
checks: types.Table = .{},
sources: diag.Sources,
modules: std.StringHashMapUnmanaged(*object.Module) = .empty,
prelude: std.AutoHashMapUnmanaged(*object.String, Value) = .empty,
/// Members every struct's instances have without declaring them, in slot
/// order: see `declareHostMember`.
host_members: std.ArrayList(HostMember) = .empty,
/// What the host said of the globals it defined, for an editor to show.
host_docs: std.StringHashMapUnmanaged([]u8) = .empty,
native_modules: std.StringHashMapUnmanaged(*object.Module) = .empty,
methods: std.EnumArray(BuiltinType, std.AutoHashMapUnmanaged(*object.String, Value)),
main: Fiber,
fiber: *Fiber = undefined,
task: ?*object.Task = null,
/// The owner a task started from outside any task is given: see
/// `api.setTaskOwner`.
task_owner: u64 = 0,
roots: std.ArrayList(Value) = .empty,
held: std.AutoHashMapUnmanaged(*Obj, u32) = .empty,
panic: ?Panic = null,
scheduler: @import("scheduler.zig").Scheduler = .{},
object_count: usize = 0,
names: Names = undefined,
classes: std.ArrayList(*object.Class) = .empty,
current_native: ?*object.Native = null,
/// `math.random`'s numbers, seeded the same way every run unless a script
/// or the host says otherwise, so a replay replays.
rng: std.Random.DefaultPrng = .init(0x5EED),
session: ?*Session = null,
/// Why the last `compile` or `load` failed, or what it warned of.
diagnostics: diag.Diagnostics = undefined,
/// The embedding program's own state, for its natives to find.
host: ?*anyopaque = null,
/// The `os` module's, when the host gave scripts one.
os_host: ?*anyopaque = null,
/// One native for each reflected method a script has called.
reflect_methods: std.AutoHashMapUnmanaged(*const reflect.Method, *object.Native) = .empty,
/// Whether loops count their rounds: set while a budget or an interrupt
/// can stop a script, so an unguarded loop pays one test per round.
guarded: std.atomic.Value(bool) = .init(false),
steps_left: u64 = 0,
budget: ?u64 = null,
interrupted: std.atomic.Value(bool) = .init(false),

/// Stops the script after `steps` more loop rounds, as a panic with a
/// stack trace, so a runaway loop cannot freeze the host. Null lifts it.
pub fn setBudget(vm: *Vm, steps: ?u64) void {
    vm.budget = steps;
    vm.steps_left = steps orelse 0;
    vm.guarded.store(steps != null or vm.interrupted.load(.monotonic), .monotonic);
}

/// Asks the running script to stop at its next loop round. Safe to call
/// from another thread.
pub fn interrupt(vm: *Vm) void {
    vm.interrupted.store(true, .monotonic);
    vm.guarded.store(true, .monotonic);
}

/// A loop came round: charged against the budget, and stopped when the
/// host asked.
pub fn tick(vm: *Vm) Error!void {
    @branchHint(.cold);
    if (vm.interrupted.swap(false, .monotonic)) {
        vm.guarded.store(vm.budget != null, .monotonic);
        return vm.fail("the host stopped the script", .{});
    }
    if (vm.budget) |b| {
        if (vm.steps_left == 0) {
            vm.steps_left = b;
            return vm.fail("the script ran past its budget of {d} loop rounds", .{b});
        }
        vm.steps_left -= 1;
    }
}

const Session = @import("../compile/Session.zig");
const api = @import("../api.zig");

pub const compile = api.compile;
pub const reload = api.reload;
pub const moduleNamed = api.moduleNamed;
pub const run = api.run;
pub const load = api.load;
pub const get = api.get;
pub const call = api.call;
pub const callName = api.callName;
pub const update = api.update;
pub const updateHolding = api.updateHolding;
pub const Held = api.Held;
pub const setTaskOwner = api.setTaskOwner;
pub const writeDiagnostics = api.writeDiagnostics;
pub const writePanic = api.writePanic;
pub const define = api.define;
pub const defineFn = api.defineFn;
pub const defineModule = api.defineModule;
pub const value = api.value;
pub const handle = api.handle;
pub const newHandle = api.newHandle;
pub const adoptHandle = api.adoptHandle;
pub const valueOf = api.valueOf;
pub const reflectOf = api.reflectOf;
pub const HostMember = struct { name: []u8, doc: ?[]u8 };
pub const Reload = api.Reload;
pub const ReloadError = api.ReloadError;
pub const declareHostMember = api.declareHostMember;
pub const defineGlobal = api.defineGlobal;
pub const handleOf = api.handleOf;
pub const liveHandle = api.liveHandle;
pub const instantiate = api.instantiate;
pub const methodNamed = api.methodNamed;
pub const hasMethod = api.hasMethod;
pub const callMethod = api.callMethod;
pub const connectSignal = api.connectSignal;
pub const disconnectSignal = api.disconnectSignal;
pub const emitSignal = api.emitSignal;
pub const newSignal = api.newSignal;
pub const newColor = api.newColor;
pub const newList = api.newList;
pub const emitSignalValue = api.emitSignalValue;
pub const setField = api.setField;
pub const getField = api.getField;
pub const native = api.native;

pub fn compileSession(vm: *Vm) Allocator.Error!*Session {
    if (vm.session) |s| return s;
    vm.session = try Session.create(vm.gpa);
    return vm.session.?;
}

pub const Names = struct {
    init: *object.String,
    len: *object.String,
    x: *object.String,
    y: *object.String,
    z: *object.String,
    r: *object.String,
    g: *object.String,
    b: *object.String,
    a: *object.String,
    name: *object.String,
    message: *object.String,
    main: *object.String,
    anonymous: *object.String,
    format: *object.String,
};

pub fn create(gpa: Allocator, options: Options) Allocator.Error!*Vm {
    const vm = try gpa.create(Vm);
    errdefer gpa.destroy(vm);
    vm.* = .{
        .gpa = gpa,
        .options = options,
        .heap = .{ .gpa = gpa, .options = options.gc },
        .sources = .init(gpa),
        .main = .init(Fiber.default_chunk),
        .methods = .initFill(.empty),
        .diagnostics = .init(gpa),
    };
    vm.fiber = &vm.main;
    vm.heap.paused += 1;
    errdefer vm.destroy();
    inline for (@typeInfo(Names).@"struct".fields) |f| {
        const text = if (comptime std.mem.eql(u8, f.name, "anonymous")) "<fn>" else f.name;
        @field(vm.names, f.name) = try vm.intern(text);
        try vm.hold(.fromObj(.string, &@field(vm.names, f.name).obj));
    }
    try @import("../lib/core.zig").install(vm);
    vm.heap.paused -= 1;
    return vm;
}

pub fn destroy(vm: *Vm) void {
    const gpa = vm.gpa;
    gc.freeAll(vm);
    vm.interned.deinit(gpa);
    vm.checks.deinit(gpa);
    vm.sources.deinit();
    vm.modules.deinit(gpa);
    var native_names = vm.native_modules.keyIterator();
    while (native_names.next()) |k| gpa.free(k.*);
    vm.native_modules.deinit(gpa);
    vm.prelude.deinit(gpa);
    for (vm.host_members.items) |m| {
        gpa.free(m.name);
        if (m.doc) |d| gpa.free(d);
    }
    vm.host_members.deinit(gpa);
    var docs = vm.host_docs.iterator();
    while (docs.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.*);
    }
    vm.host_docs.deinit(gpa);
    for (&vm.methods.values) |*m| m.deinit(gpa);
    vm.main.deinit(gpa);
    vm.roots.deinit(gpa);
    vm.held.deinit(gpa);
    vm.heap.gray.deinit(gpa);
    vm.scheduler.deinit(gpa);
    vm.classes.deinit(gpa);
    if (vm.panic) |*p| p.deinit(gpa);
    if (vm.session) |s| s.destroy(gpa);
    vm.diagnostics.deinit();
    vm.reflect_methods.deinit(gpa);
    gpa.destroy(vm);
}

/// Makes a heap object of type `T` with `extra` bytes after it.
pub fn alloc(vm: *Vm, comptime T: type, kind: object.Kind, extra: usize) Allocator.Error!*T {
    const size = @sizeOf(T) + extra;
    if (vm.options.max_bytes) |limit| if (vm.heap.bytes + size > limit) {
        if (vm.heap.paused == 0) try gc.collect(vm);
        if (vm.heap.bytes + size > limit) return error.OutOfMemory;
    };
    vm.heap.bytes += size;
    vm.heap.debt += @intCast(size);
    if (vm.heap.paused == 0) {
        if (vm.heap.options.stress) {
            try gc.collect(vm);
        } else if (vm.heap.debt > 0) {
            try gc.step(vm);
        }
    }
    try vm.heap.reserveGray(vm.object_count + 1);
    const bytes = vm.gpa.alignedAlloc(u8, .of(T), size) catch |err| {
        vm.heap.bytes -= size;
        return err;
    };
    const ptr: *T = @ptrCast(bytes.ptr);
    vm.heap.link(&ptr.obj, kind);
    vm.object_count += 1;
    return ptr;
}

// ---------------------------------------------------------------------------
// Keeping values alive from Zig

/// Keeps `v` alive until `popRoot`: for a value a native has made and not
/// yet stored anywhere the collector looks.
pub fn pushRoot(vm: *Vm, v: Value) Allocator.Error!void {
    try vm.roots.append(vm.gpa, v);
}

pub fn popRoot(vm: *Vm) void {
    _ = vm.roots.pop();
}

/// Keeps an object alive until `release`, for as many holds as there were.
pub fn hold(vm: *Vm, v: Value) Allocator.Error!void {
    if (!v.isObject()) return;
    const gop = try vm.held.getOrPut(vm.gpa, v.obj());
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
}

pub fn release(vm: *Vm, v: Value) void {
    if (!v.isObject()) return;
    const entry = vm.held.getPtr(v.obj()) orelse return;
    entry.* -= 1;
    if (entry.* == 0) _ = vm.held.remove(v.obj());
}

// ---------------------------------------------------------------------------
// Strings

pub fn newString(vm: *Vm, bytes: []const u8) Allocator.Error!*object.String {
    return vm.makeString(bytes, bytes.len <= strings.intern_limit);
}

/// The one string with these bytes, however long: names are found by
/// pointer, in a module's variables and a struct's fields.
pub fn intern(vm: *Vm, bytes: []const u8) Allocator.Error!*object.String {
    return vm.makeString(bytes, true);
}

fn makeString(vm: *Vm, bytes: []const u8, shared: bool) Allocator.Error!*object.String {
    const hash = strings.hashBytes(bytes);
    if (shared) {
        if (vm.interned.find(bytes, hash)) |s| {
            if (vm.heap.phase == .sweep and s.obj.color == vm.heap.otherWhite()) s.obj.color = vm.heap.white;
            return s;
        }
    }
    const s = try vm.alloc(object.String, .string, bytes.len + 1);
    s.len = @intCast(bytes.len);
    s.hash = hash;
    s.chars = strings.countChars(bytes);
    const out = s.mutableBytes();
    @memcpy(out[0..bytes.len], bytes);
    out[bytes.len] = 0;
    if (shared) {
        s.obj.flags = 1;
        try vm.pushRoot(.fromObj(.string, &s.obj));
        defer vm.popRoot();
        try vm.interned.add(vm.gpa, s);
    }
    return s;
}

pub fn string(vm: *Vm, bytes: []const u8) Allocator.Error!Value {
    return .fromObj(.string, &(try vm.newString(bytes)).obj);
}

/// A string made from a format, without a buffer of its own.
pub fn print(vm: *Vm, comptime fmt: []const u8, args: anytype) Allocator.Error!Value {
    var stack: [256]u8 = undefined;
    if (std.fmt.bufPrint(&stack, fmt, args)) |text| return vm.string(text) else |_| {}
    const text = try std.fmt.allocPrint(vm.gpa, fmt, args);
    defer vm.gpa.free(text);
    return vm.string(text);
}

// ---------------------------------------------------------------------------
// Panics

/// Records why the script stops; returns the error that unwinds it. Never
/// inlined: it is cold, and the formatting would swell the frame of the
/// instruction loop, which every call into a script pays for.
pub noinline fn fail(vm: *Vm, comptime fmt: []const u8, args: anytype) Error {
    @branchHint(.cold);
    const message = std.fmt.allocPrint(vm.gpa, fmt, args) catch return error.OutOfMemory;
    @import("panic.zig").raise(vm, message) catch return error.OutOfMemory;
    return error.Panic;
}

pub fn takePanic(vm: *Vm) ?Panic {
    const p = vm.panic;
    vm.panic = null;
    return p;
}

pub fn clearPanic(vm: *Vm) void {
    if (vm.panic) |*p| p.deinit(vm.gpa);
    vm.panic = null;
}

pub fn output(vm: *Vm) ?*std.Io.Writer {
    return vm.options.out;
}

test {
    _ = strings;
}
