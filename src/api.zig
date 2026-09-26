// SPDX-License-Identifier: BSD-2-Clause

//! What a program embedding Flux calls: the methods `Vm` has for loading
//! scripts, calling into them and giving them functions of its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("diag.zig");
const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const object = @import("vm/object.zig");
const make = @import("vm/make.zig");
const call_mod = @import("vm/call.zig");
const panic_mod = @import("vm/panic.zig");
const Compiler = @import("compile/Compiler.zig");
const bind = @import("bind.zig");
const native_lib = @import("lib/native.zig");
const signal_lib = @import("lib/signal.zig");
const reload_mod = @import("reload.zig");
const types_mod = @import("vm/types.zig");
const reflect = @import("fluxion_reflect");
const bridge = @import("reflect.zig");

pub const CompileError = error{ CompileFailed, OutOfMemory };
pub const LoadError = error{ CompileFailed, Panic, OutOfMemory };

/// Compiles a module. On `error.CompileFailed` the reasons are in
/// `vm.diagnostics`, which each compile starts afresh.
pub fn compile(vm: *Vm, name: []const u8, source: []const u8) CompileError!*object.Module {
    vm.diagnostics.deinit();
    vm.diagnostics = .init(vm.gpa);
    return Compiler.compileModule(vm, name, source, &vm.diagnostics);
}

pub const ReloadError = reload_mod.Error;
pub const Reload = reload_mod.Report;

/// Puts `source` in as a running module's new code, and compiles again the
/// modules importing it. What holds the module's structs, functions and
/// instances goes on with the new code; variables declared as before keep
/// their values; see `reload.zig`. Call it between calls into scripts. On
/// `error.CompileFailed` nothing changed and `vm.diagnostics` says why;
/// its warnings say what a reload that worked could not keep.
pub fn reload(vm: *Vm, module: *object.Module, source: []const u8) ReloadError!Reload {
    return reload_mod.reload(vm, module, source);
}

/// A module compiled under `name`, as `compile` or an import was given it.
pub fn moduleNamed(vm: *Vm, name: []const u8) ?*object.Module {
    return vm.modules.get(name);
}

/// Runs a compiled module, and the modules it imports first.
pub fn run(vm: *Vm, module: *object.Module) Vm.Error!void {
    return call_mod.runModule(vm, module);
}

/// Compiles and runs a module.
pub fn load(vm: *Vm, name: []const u8, source: []const u8) LoadError!*object.Module {
    const module = try compile(vm, name, source);
    try run(vm, module);
    return module;
}

/// A module's variable, function or type by name.
pub fn get(vm: *Vm, module: *object.Module, name: []const u8) ?Value {
    const key = vm.interned.find(name, @import("vm/strings.zig").hashBytes(name)) orelse return null;
    const v = module.get(key) orelse return null;
    return if (v.tag == .undefined) null else v;
}

/// Calls a function, method or native with arguments. A coroutine starts
/// as a task, and the task is what comes back.
pub fn call(vm: *Vm, callee: Value, args: []const Value) Vm.Error!Value {
    return call_mod.call(vm, callee, args);
}

/// Calls a module's function by name.
pub fn callName(vm: *Vm, module: *object.Module, name: []const u8, args: []const Value) Vm.Error!Value {
    const f = get(vm, module, name) orelse return vm.fail("module `{s}` has no `{s}`", .{ module.name.bytes(), name });
    return call(vm, f, args);
}

/// Moves script time on by `dt` seconds, waking tasks that waited.
pub fn update(vm: *Vm, dt: f64) Vm.Error!void {
    return call_mod.update(vm, dt);
}

/// Which tasks a host keeps from moving on: asked of each waiting task's
/// owner, the number `setTaskOwner` gave it - `0` for none - as each
/// `updateHolding` begins.
pub const Held = struct {
    context: ?*anyopaque = null,
    held: *const fn (context: ?*anyopaque, owner: u64) bool,
};

/// `update`, with the tasks whose owner is held kept where they are: a
/// wait of one of them does not come nearer while it is held, and picks up
/// where it was once it is not. What a game engine pauses a paused thing's
/// `await wait(1.0)` by. A task woken by a signal or another task wakes
/// whether its owner is held or not.
pub fn updateHolding(vm: *Vm, dt: f64, held: Held) Vm.Error!void {
    return call_mod.updateHolding(vm, dt, held);
}

/// Stop every task of `owner` where it waits - its time, a signal, another
/// task: none of them goes on, and a task of another owner waiting for one
/// fails at its `await`. What an engine does when the entity a task is of
/// goes. How many were stopped; nothing for owner `0`.
pub fn stopTasks(vm: *Vm, owner: u64) Vm.Error!usize {
    return call_mod.stopTasks(vm, owner);
}

/// The owner every task started from now on is given - unless it is
/// started by another task, whose owner it takes - and the one there was
/// before, to put back. The host's to count: an engine gives the entity
/// whose script it is calling, so the task belongs to it.
///
/// ```zig
/// const before = vm.setTaskOwner(entity_id);
/// defer _ = vm.setTaskOwner(before);
/// _ = try vm.call(method, args);
/// ```
pub fn setTaskOwner(vm: *Vm, owner: u64) u64 {
    const before = vm.task_owner;
    vm.task_owner = owner;
    return before;
}

// ---------------------------------------------------------------------------
// A script's structs, from the host: what an engine needs to put a script on
// an entity, call into it, and wire its signals.

/// A method or a signal a struct declares, as a host sees it.
pub const Member = struct {
    name: []const u8,
    /// Its parameters, not counting `self`.
    params: u8,
    /// The parameters as written, `by: ?Actor, damage: int`; an untyped one
    /// is its name alone.
    signature: []const u8,
    doc: ?[]const u8,
};

/// A member every struct's instances have without declaring it: what a
/// script reaches as `self.name`, an engine's `self.entity`. Scripts read it
/// and cannot assign it; `instantiate` sets it, and an instance a script
/// makes has it null. Declare it before compiling the scripts that use it,
/// on every VM that compiles them - an editor's analysis too, so completions
/// know it.
pub fn declareHostMember(vm: *Vm, name: []const u8, doc: ?[]const u8) Allocator.Error!void {
    return declareHostMemberOf(vm, name, null, doc);
}

/// `declareHostMember`, saying what the member holds: a handle of the
/// host's type `host_type`. The compiler knows its fields and methods then,
/// checks the calls of its methods, and an editor offers them.
pub fn declareHostMemberOf(vm: *Vm, name: []const u8, host_type: ?*const reflect.Type, doc: ?[]const u8) Allocator.Error!void {
    for (vm.host_members.items) |m| if (std.mem.eql(u8, m.name, name)) return;
    const owned = try vm.gpa.dupe(u8, name);
    errdefer vm.gpa.free(owned);
    const text = if (doc) |d| try vm.gpa.dupe(u8, d) else null;
    errdefer if (text) |t| vm.gpa.free(t);
    try vm.host_members.append(vm.gpa, .{ .name = owned, .doc = text, .type = host_type });
}

/// A global the host defines where the scripts run, declared where they are
/// only compiled - an editor's analysis: `name`, a value of the host's type
/// `host_type`, with nothing behind it. What `defineGlobal` gives a handle
/// is known by the handle's type without this.
pub fn declareGlobal(vm: *Vm, name: []const u8, host_type: *const reflect.Type, doc: ?[]const u8) Allocator.Error!void {
    try defineGlobal(vm, name, .null, doc);
    const gop = try vm.global_types.getOrPut(vm.gpa, name);
    if (!gop.found_existing) gop.key_ptr.* = vm.host_docs.getKey(name).?;
    gop.value_ptr.* = host_type;
}

/// One of the host's types, made a name scripts write: in a type, `fn
/// input(self, event: InputEvent)`, where a value goes, `entity.get(Sprite)`,
/// and after `is`, `if (event is KeyEvent)`. Its name is the type's own,
/// without the file it is in; a script's own declaration of the name hides
/// it. An enum's members are named through it: `Key.space`. The type is the
/// host's and lives as long as the VM.
///
/// The choices its values take and give are named with it: the enums and
/// unions of its fields and of its methods' parameters and results, what
/// those unions' arms hold, and theirs in turn - `const modes: [Fullscreen]
/// = [.windowed, .borderless]`, `KeyEvent` and its `Key` with `InputEvent`.
/// Not where a type is declared by that name, nor where two of them have one
/// name: those a script still writes as the place they go wants them,
/// `.borderless`.
pub fn declareType(vm: *Vm, t: *const reflect.Type) Allocator.Error!void {
    const name = bridge.nameOf(t);
    try vm.named_types.put(vm.gpa, name, t);
    _ = vm.reached_types.remove(name);
    try reachFrom(vm, t);
}

/// Names the choices a value of `t` takes and gives: see `declareType`.
fn reachFrom(vm: *Vm, t: *const reflect.Type) Allocator.Error!void {
    for (t.fields()) |f| {
        const held = heldBy(f.type);
        const arm = t.kind == .@"union" and held.kind == .@"struct" and bridge.vectorLength(held) == null;
        if (!arm) {
            try reach(vm, held);
        } else if (try nameReached(vm, held)) try reachFrom(vm, held);
    }
    for (t.methods.slice()) |*m| {
        const function = m.type.info.function;
        for (function.params.slice()) |p| try reach(vm, p.type);
        try reach(vm, function.return_type);
    }
}

fn reach(vm: *Vm, t: *const reflect.Type) Allocator.Error!void {
    const held = heldBy(t);
    switch (held.kind) {
        .@"enum" => _ = try nameReached(vm, held),
        .@"union" => if (try nameReached(vm, held)) try reachFrom(vm, held),
        else => {},
    }
}

/// The type a value of `t` is, past an optional, an error, a pointer or a
/// list.
fn heldBy(t: *const reflect.Type) *const reflect.Type {
    var at = t;
    while (true) switch (at.kind) {
        .optional, .error_union, .pointer, .slice, .array => at = at.child() orelse return at,
        else => return at,
    };
}

/// Names `t` for being reached, and says whether it was named just now.
fn nameReached(vm: *Vm, t: *const reflect.Type) Allocator.Error!bool {
    if (bridge.hostType(vm, t) != null) return false;
    const name = bridge.nameOf(t);
    const reached = try vm.reached_types.getOrPut(vm.gpa, name);
    if (!reached.found_existing) {
        if (vm.named_types.contains(name)) {
            // Declared, and so its own.
            _ = vm.reached_types.remove(name);
            return false;
        }
        reached.value_ptr.* = true;
        try vm.named_types.put(vm.gpa, name, t);
        return true;
    }
    if (!reached.value_ptr.* or vm.named_types.get(name).?.same(t)) return false;
    // Two choices of one name: neither is named.
    reached.value_ptr.* = false;
    _ = vm.named_types.orderedRemove(name);
    return false;
}

/// A method the host calls on scripts' instances. See `Vm.Hook`.
pub fn declareHook(vm: *Vm, hook: Vm.Hook) Allocator.Error!void {
    for (vm.hooks.items) |*h| if (std.mem.eql(u8, h.name, hook.name)) {
        h.* = hook;
        return;
    };
    try vm.hooks.append(vm.gpa, hook);
}

pub fn hookNamed(vm: *const Vm, name: []const u8) ?*const Vm.Hook {
    for (vm.hooks.items) |*h| if (std.mem.eql(u8, h.name, name)) return h;
    return null;
}

/// An annotation of a field's the host reads. See `Vm.Annotation`.
pub fn declareAnnotation(vm: *Vm, a: Vm.Annotation) Allocator.Error!void {
    for (vm.annotations.items) |*have| if (std.mem.eql(u8, have.name, a.name)) {
        have.* = a;
        return;
    };
    try vm.annotations.append(vm.gpa, a);
}

/// A member of the values of one of the host's types its type does not
/// list. See `Vm.DeclaredMember`.
pub fn declareMember(vm: *Vm, m: Vm.DeclaredMember) Allocator.Error!void {
    for (vm.members.items) |*have| if (have.of.same(m.of) and std.mem.eql(u8, have.name, m.name)) {
        have.* = m;
        return;
    };
    try vm.members.append(vm.gpa, m);
}

/// Says the values of the host's type `t` have members only the host
/// knows, found as the script runs - a material's numbers, named by its
/// shader: a name the compiler does not know on one is `any`, not a
/// mistake.
pub fn declareOpen(vm: *Vm, t: *const reflect.Type) Allocator.Error!void {
    for (vm.open_types.items) |o| if (o.same(t)) return;
    try vm.open_types.append(vm.gpa, t);
}

/// Gives the values of the host's type `of` the methods of `receiver` -
/// a handle on a value of the host's type `by` - whose first argument a
/// script gives is one of `of`: `app.childCount(e)` as `e.childCount()`, on
/// `receiver`, given `e`. A method's `Alias` names it on `of`'s values; a
/// method `of` has of the name comes first. Where the scripts are only
/// compiled, `receiver` is null and `by` says the type.
pub fn extend(vm: *Vm, of: *const reflect.Type, by: *const reflect.Type, receiver: Value) Allocator.Error!void {
    for (vm.extensions.items) |e| if (e.of.same(of) and e.by.same(by)) {
        e.receiver = receiver;
        return;
    };
    const e = try vm.gpa.create(Vm.Extension);
    errdefer vm.gpa.destroy(e);
    e.* = .{ .of = of, .by = by, .receiver = receiver };
    try vm.extensions.append(vm.gpa, e);
}

/// A value every module sees as `name` without importing anything: an
/// engine's `app`. It is compiled into the scripts that use it, so define it
/// before compiling them; `doc` is what an editor shows for it.
pub fn defineGlobal(vm: *Vm, name: []const u8, v: Value, doc: ?[]const u8) Allocator.Error!void {
    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;
    try vm.prelude.put(vm.gpa, try vm.intern(name), v);
    const text = try vm.gpa.dupe(u8, doc orelse "given by the host");
    errdefer vm.gpa.free(text);
    const gop = try vm.host_docs.getOrPut(vm.gpa, name);
    if (gop.found_existing) {
        vm.gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = vm.gpa.dupe(u8, name) catch |err| {
            vm.host_docs.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    gop.value_ptr.* = text;
}

/// A host member's value, for `instantiate`.
pub const HostValue = struct { name: []const u8, value: Value };

/// A new instance of a struct - `class` as `get` gives it - with its host
/// members set from `host`, its defaults run and its signals made, as
/// `Name{}` makes one in a script. Hold it with `vm.hold` while the host
/// keeps it.
pub fn instantiate(vm: *Vm, class: Value, host: []const HostValue) Vm.Error!Value {
    if (class.tag != .class) return vm.fail("an instance is made of a struct, and this is {s}", .{@import("vm/types.zig").typeName(class)});
    const c = class.as(object.Class);
    // The host's values live where the collector does not look, and making
    // the instance can collect.
    var rooted: usize = 0;
    defer for (0..rooted) |_| vm.popRoot();
    for (host) |h| {
        try vm.pushRoot(h.value);
        rooted += 1;
    }
    const inst = try make.instance(vm, c);
    const v: Value = .fromObj(.instance, &inst.obj);
    try vm.pushRoot(v);
    rooted += 1;
    for (host) |h| {
        const key = vm.interned.find(h.name, @import("vm/strings.zig").hashBytes(h.name));
        const slot = if (key) |k| c.slots.get(k) else null;
        if (slot == null or !c.fields[slot.?].host) return vm.fail("`{s}` is not a member the host declared", .{h.name});
        inst.fields()[slot.?] = h.value;
    }
    if (c.has_signals) try signal_lib.fill(vm, inst);
    if (c.defaults != null or c.parent != null) try call_mod.initDefaults(vm, v);
    return v;
}

/// A field of a struct's, as a host sees it: what an editor shows of an
/// `@export`, and what it sets before the instance is used.
pub const FieldInfo = struct {
    name: []const u8,
    /// Marked `@export`: shown by an editor, and saved with a scene.
    exported: bool,
    /// What it holds.
    kind: FieldKind,
    /// A `?T`: null too.
    nullable: bool,
    /// For a list, what its items are; `any` for a list of anything, and for
    /// anything but a list.
    element: FieldKind = .any,
    /// For a list, what its items are checked against: what `newList` makes
    /// one the field takes with.
    element_check: types_mod.Check = .any,
    /// An enum's member names, for `kind == .enum_member`.
    members: []const *object.String = &.{},
    /// The enum, for `kind == .enum_member`: see `enumMember`.
    enum_type: ?*object.EnumType = null,
    /// What it starts as when nothing sets it: a list or a map is made
    /// anew for each instance, and this is only its zero then.
    default: Value,
    doc: ?[]const u8,
    /// Its annotations but `@export`, by name, each with its arguments.
    /// See `annotationOf`.
    annotations: ?*object.Map,
};

pub const FieldKind = enum { any, int, float, bool, string, vec2, vec3, color, list, map, enum_member, instance, function, other };

/// The fields a struct's instances have, inherited ones first, as written:
/// neither its signals nor the host's members. As many as fit in `into`.
pub fn fieldsOf(vm: *const Vm, class: Value, into: []FieldInfo) []FieldInfo {
    if (class.tag != .class) return into[0..0];
    var n: usize = 0;
    for (class.as(object.Class).fields) |f| {
        if (f.is_signal or f.host) continue;
        if (n == into.len) break;
        const shape = shapeOf(vm, f.check);
        into[n] = .{
            .name = f.name.bytes(),
            .exported = f.exported,
            .kind = shape.kind,
            .nullable = shape.nullable,
            .element = shape.element,
            .element_check = shape.element_check,
            .members = shape.members,
            .enum_type = shape.enum_type,
            .default = f.default,
            .doc = f.doc,
            .annotations = f.annotations,
        };
        n += 1;
    }
    return into[0..n];
}

const Shape = struct {
    kind: FieldKind,
    nullable: bool = false,
    element: FieldKind = .any,
    element_check: types_mod.Check = .any,
    members: []const *object.String = &.{},
    enum_type: ?*object.EnumType = null,
};

fn shapeOf(vm: *const Vm, check: types_mod.Check) Shape {
    return switch (check) {
        .any => .{ .kind = .any },
        .int => .{ .kind = .int },
        .float => .{ .kind = .float },
        .bool => .{ .kind = .bool },
        .string => .{ .kind = .string },
        .vec2 => .{ .kind = .vec2 },
        .vec3 => .{ .kind = .vec3 },
        .color => .{ .kind = .color },
        .list => .{ .kind = .list },
        .map => .{ .kind = .map },
        .function => .{ .kind = .function },
        _ => switch (vm.checks.get(check) orelse return .{ .kind = .other }) {
            .optional => |inner| blk: {
                var shape = shapeOf(vm, inner);
                shape.nullable = true;
                break :blk shape;
            },
            .list_of => |item| .{ .kind = .list, .element = shapeOf(vm, item).kind, .element_check = item },
            .map_of => .{ .kind = .map },
            .class => .{ .kind = .instance },
            .enum_type => |e| .{ .kind = .enum_member, .members = e.members, .enum_type = e },
            .function => .{ .kind = .function },
            .error_union, .host => .{ .kind = .other },
        },
        else => .{ .kind = .other },
    };
}

/// The member at `index` of an enum, as a value: what a host sets an enum's
/// field to.
pub fn enumMember(e: *object.EnumType, index: u32) Value {
    return .{ .raw = @intFromPtr(&e.obj), .extra = index, .tag = .enum_value };
}

/// A list of `items`, for a field whose items are checked against
/// `element`: `FieldInfo.element_check`. Each item is the host's to have
/// made right.
pub fn newList(vm: *Vm, element: types_mod.Check, items: []const Value) Allocator.Error!Value {
    const l = try make.list(vm, items.len, element);
    l.items.appendSliceAssumeCapacity(items);
    const v: Value = .fromObj(.list, &l.obj);
    for (items) |item| vm.heap.barrier(&l.obj, item);
    return v;
}

/// A colour, from red, green, blue and alpha between nought and one.
pub fn newColor(vm: *Vm, rgba: [4]f32) Allocator.Error!Value {
    return make.color(vm, rgba);
}

/// The arguments of the annotation `name` on a field - `@range(0, 100)` is
/// `range` with 0 and 100 - or null when it has none.
pub fn annotationOf(field: FieldInfo, name: []const u8) ?[]const Value {
    const table = field.annotations orelse return null;
    var it = table.table.iterator();
    while (it.next()) |entry| {
        if (entry.key.tag != .string or !std.mem.eql(u8, entry.key.as(object.String).bytes(), name)) continue;
        return entry.value.as(object.List).items.items;
    }
    return null;
}

pub const SetFieldError = error{
    /// The instance's struct has no field by that name.
    NoSuchField,
    /// The value is not what the field holds.
    WrongType,
};

/// Set a field of an instance from the host: what an engine does with an
/// `@export`'s saved value before the instance is used. An int where a float
/// is wanted is widened; anything else not what the field holds is refused.
pub fn setField(vm: *Vm, instance: Value, name: []const u8, given: Value) SetFieldError!void {
    if (instance.tag != .instance) return error.NoSuchField;
    const inst = instance.as(object.Instance);
    const slot = slotOf(vm, inst.class, name) orelse return error.NoSuchField;
    const field = inst.class.fields[slot];
    if (field.is_signal or field.host or field.is_const) return error.NoSuchField;
    const kept = vm.checks.coerce(field.check, given) orelse return error.WrongType;
    inst.fields()[slot] = kept;
    vm.heap.barrier(&inst.obj, kept);
}

/// A field of an instance, as it is now; null for one it has not got.
pub fn getField(vm: *Vm, instance: Value, name: []const u8) ?Value {
    if (instance.tag != .instance) return null;
    const inst = instance.as(object.Instance);
    const slot = slotOf(vm, inst.class, name) orelse return null;
    return inst.fields()[slot];
}

fn slotOf(vm: *Vm, class: *object.Class, name: []const u8) ?u32 {
    const key = vm.interned.find(name, @import("vm/strings.zig").hashBytes(name)) orelse return null;
    return class.slots.get(key);
}

/// A signal of no instance's: one the host emits with `emitSignalValue` -
/// an engine's own, as its scripts see it - which scripts connect to and
/// `await` as they do any other. Hold it while the host keeps it.
pub fn newSignal(vm: *Vm, name: []const u8, params: u8) Vm.Error!Value {
    const interned = try vm.intern(name);
    try vm.pushRoot(.fromObj(.string, &interned.obj));
    defer vm.popRoot();
    const s = try make.signal(vm, interned, params);
    return .fromObj(.signal, &s.obj);
}

/// Emit a signal the host has: what is connected is called with `args`,
/// and what waits wakes, as an `emit` in a script does.
pub fn emitSignalValue(vm: *Vm, signal: Value, args: []const Value) Vm.Error!void {
    if (signal.tag != .signal) return vm.fail("only a signal is emitted, and this is {s}", .{types_mod.typeName(signal)});
    return signal_lib.emitOn(vm, signal.as(object.Signal), args);
}

/// The struct `instance` was made of, as `get` gives a struct.
pub fn classOf(instance: Value) ?Value {
    if (instance.tag != .instance) return null;
    return .fromObj(.class, &instance.as(object.Instance).class.obj);
}

/// The methods a struct has, the ones it declares first and then each
/// parent's, every group in the order written; an override is listed once,
/// with the struct that wrote it. As many as fit in `into`.
pub fn methodsOf(class: Value, into: []Member) []Member {
    if (class.tag != .class) return into[0..0];
    var n: usize = 0;
    var at: ?*const object.Class = class.as(object.Class);
    while (at) |c| : (at = c.parent) {
        // Picked by place in the file, so no allocation is needed to sort.
        var after: ?u32 = null;
        while (n < into.len) {
            var best: ?struct { at: u32, name: *object.String, proto: *object.Proto } = null;
            var it = c.methods.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.tag != .function) continue;
                const p = e.value_ptr.as(object.Closure).proto;
                if (after) |a| if (p.decl.start <= a) continue;
                if (best) |b| if (b.at <= p.decl.start) continue;
                if (listed(into[0..n], e.key_ptr.*.bytes())) continue;
                best = .{ .at = p.decl.start, .name = e.key_ptr.*, .proto = p };
            }
            const b = best orelse break;
            after = b.at;
            into[n] = .{ .name = b.name.bytes(), .params = b.proto.params - @intFromBool(b.proto.has_self), .signature = b.proto.signature orelse "", .doc = b.proto.doc };
            n += 1;
        }
    }
    return into[0..n];
}

fn listed(members: []const Member, name: []const u8) bool {
    for (members) |m| if (std.mem.eql(u8, m.name, name)) return true;
    return false;
}

/// The signals a struct has, the ones it declares first and then each
/// parent's, in the order written. As many as fit in `into`.
pub fn signalsOf(class: Value, into: []Member) []Member {
    if (class.tag != .class) return into[0..0];
    var n: usize = 0;
    var at: ?*const object.Class = class.as(object.Class);
    while (at) |c| : (at = c.parent) {
        const inherited = if (c.parent) |p| p.fields.len else 0;
        for (c.fields[inherited..]) |f| {
            if (!f.is_signal) continue;
            if (n == into.len) return into;
            into[n] = .{ .name = f.name.bytes(), .params = @intCast(f.default.asInt()), .signature = f.signature orelse "", .doc = f.doc };
            n += 1;
        }
    }
    return into[0..n];
}

/// The method `name` of a struct or one it extends; null when there is
/// none. Call it with the instance first - `vm.call(m, &.{ instance, dt })`
/// - and look it up again after a reload.
pub fn methodNamed(vm: *Vm, class: Value, name: []const u8) ?Value {
    if (class.tag != .class) return null;
    const key = vm.interned.find(name, @import("vm/strings.zig").hashBytes(name)) orelse return null;
    return class.as(object.Class).method(key);
}

pub fn hasMethod(vm: *Vm, class: Value, name: []const u8) bool {
    return methodNamed(vm, class, name) != null;
}

/// Calls the method `name` on `instance`.
pub fn callMethod(vm: *Vm, instance: Value, name: []const u8, args: []const Value) Vm.Error!Value {
    const class = classOf(instance) orelse return vm.fail("a method is called on an instance, and this is {s}", .{@import("vm/types.zig").typeName(instance)});
    const m = methodNamed(vm, class, name) orelse return vm.fail("`{s}` has no method `{s}`", .{ instance.as(object.Instance).class.name.bytes(), name });
    const at = try vm.fiber.free(vm.gpa, args.len + 1);
    at[0] = instance;
    @memcpy(at[1 .. args.len + 1], args);
    return call(vm, m, at[0 .. args.len + 1]);
}

fn signalNamed(vm: *Vm, instance: Value, name: []const u8) Vm.Error!*object.Signal {
    if (instance.tag != .instance) return vm.fail("a signal belongs to an instance, and this is {s}", .{@import("vm/types.zig").typeName(instance)});
    const inst = instance.as(object.Instance);
    const key = vm.interned.find(name, @import("vm/strings.zig").hashBytes(name));
    if (key) |k| if (inst.class.slots.get(k)) |slot| if (inst.class.fields[slot].is_signal) {
        const v = inst.fields()[slot];
        if (v.tag == .signal) return v.as(object.Signal);
    };
    return vm.fail("`{s}` has no signal `{s}`", .{ inst.class.name.bytes(), name });
}

/// Calls `target` - a function, a method, or what `native` makes - each
/// time `instance`'s signal `name` is emitted.
pub fn connectSignal(vm: *Vm, instance: Value, name: []const u8, target: Value) Vm.Error!void {
    switch (target.tag) {
        .function, .native, .method => {},
        else => return vm.fail("a signal is connected to a function, and this is {s}", .{@import("vm/types.zig").typeName(target)}),
    }
    try signal_lib.connectTo(vm, try signalNamed(vm, instance, name), target, false);
}

/// Whether `target` was connected to the signal, and is not any more.
pub fn disconnectSignal(vm: *Vm, instance: Value, name: []const u8, target: Value) Vm.Error!bool {
    return signal_lib.disconnectFrom(try signalNamed(vm, instance, name), target);
}

/// Emits `instance`'s signal `name` with `args`, as `self.name.emit(...)`
/// does in the script.
pub fn emitSignal(vm: *Vm, instance: Value, name: []const u8, args: []const Value) Vm.Error!void {
    const s = try signalNamed(vm, instance, name);
    if (args.len != s.params) return vm.fail("signal `{s}` takes {d} argument{s}, and was given {d}", .{ name, s.params, if (s.params == 1) "" else "s", args.len });
    // The instance and the arguments live where the collector does not look.
    var rooted: usize = 0;
    defer for (0..rooted) |_| vm.popRoot();
    try vm.pushRoot(instance);
    rooted += 1;
    for (args) |a| {
        try vm.pushRoot(a);
        rooted += 1;
    }
    try signal_lib.emitOn(vm, s, args);
}

/// A Zig function as a value: something a signal can be connected to, or a
/// script handed. The native finds `user` again in `vm.current_native.?.user`.
/// `name` is not copied.
pub fn native(vm: *Vm, name: []const u8, func: object.NativeFn, min: u8, max: ?u8, user: ?*anyopaque) Allocator.Error!Value {
    const n = try make.native(vm, name, func, min, max);
    n.user = user;
    return .fromObj(.native, &n.obj);
}

pub fn writeDiagnostics(vm: *Vm, w: *std.Io.Writer, options: diag.render.Options) std.Io.Writer.Error!void {
    return diag.render.all(w, &vm.sources, &vm.diagnostics, options);
}

/// The last panic, with its stack trace; nothing when there is none.
pub fn writePanic(vm: *Vm, w: *std.Io.Writer, options: diag.render.Options) std.Io.Writer.Error!void {
    const p = if (vm.panic) |*p| p else return;
    return panic_mod.render(w, vm, p, options);
}

/// A function every module can call without importing anything.
pub fn define(vm: *Vm, name: []const u8, func: object.NativeFn, min: u8, max: ?u8) Allocator.Error!void {
    return native_lib.define(vm, name, func, min, max);
}

/// Any Zig function as one every module can call: `vm.defineFn("hp", hp)`.
pub fn defineFn(vm: *Vm, name: []const u8, comptime f: anytype) Allocator.Error!void {
    const n = bind.arity(f);
    return define(vm, name, bind.wrap(f), n, n);
}

/// A module a script imports with `@import(name)`, filled from a struct of
/// Zig functions and values: `vm.defineModule("game", .{ .spawn = spawn,
/// .version = 3 })`.
pub fn defineModule(vm: *Vm, name: []const u8, comptime members: anytype) Allocator.Error!*object.Module {
    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;
    const m = try make.module(vm, try vm.intern(name));
    m.state = .ready;
    m.ran = true;
    inline for (@typeInfo(@TypeOf(members)).@"struct".fields) |field| {
        const x = @field(members, field.name);
        if (@typeInfo(@TypeOf(x)) == .@"fn") {
            const n = bind.arity(x);
            try native_lib.function(vm, m, field.name, bind.wrap(x), n, n);
        } else {
            try native_lib.member(vm, m, field.name, bind.toValue(vm, x) catch return error.OutOfMemory);
        }
    }
    const key = try vm.gpa.dupe(u8, name);
    const old = try vm.native_modules.fetchPut(vm.gpa, key, m);
    if (old) |o| vm.gpa.free(o.key);
    return m;
}

/// A handle on a value only known at run time as a `fluxion_reflect.Value`
/// - a component found by name. The host keeps what it points at alive.
pub fn handleOf(vm: *Vm, v: @import("fluxion_reflect").Value) Vm.Error!Value {
    return @import("reflect.zig").handleOf(vm, v, .null);
}

/// A handle on a value the host finds again at each use - a component that
/// moves with its storage. `resolver` says where it is now, by `key` and
/// type; it outlives the handle. When it is gone, a script using the handle
/// stops with a panic saying `resolver.why`.
pub fn liveHandle(vm: *Vm, resolver: *const object.Resolver, key: u64, t: *const @import("fluxion_reflect").Type) Vm.Error!Value {
    return @import("reflect.zig").liveHandle(vm, resolver, key, t);
}

/// A Zig value as a Flux value, the way natives' results are converted.
pub fn value(vm: *Vm, x: anytype) Vm.Error!Value {
    return bind.toValue(vm, x);
}

/// The Zig value `pointer` points at, for scripts to read, write and call
/// methods on through fluxion-reflect. It must outlive the scripts' use.
pub fn handle(vm: *Vm, pointer: anytype) Vm.Error!Value {
    return @import("reflect.zig").handle(vm, pointer);
}

/// A value the host has only as a `fluxion_reflect.Value` - an argument of
/// an engine's signal - as a script's own: converted as a native's result
/// is, and what is not a number, a string or a vector copied into a handle
/// the collector owns, so the host's memory can go right after.
pub fn valueOf(vm: *Vm, v: @import("fluxion_reflect").Value) Vm.Error!Value {
    return @import("reflect.zig").valueOf(vm, v);
}

/// What a handle stands for now, for the host - the reverse of `valueOf`: a
/// live handle looked up again, one reached through another through its
/// owner. Null for a value that is not a handle, and for one whose value is
/// gone.
pub fn reflectOf(_: *Vm, v: Value) ?@import("fluxion_reflect").Value {
    if (v.tag != .handle) return null;
    return @import("reflect.zig").current(v.as(object.Handle));
}

/// A new `T`, owned by the script that gets it.
pub fn newHandle(vm: *Vm, comptime T: type) Vm.Error!Value {
    return @import("reflect.zig").create(vm, T);
}

/// A handle on memory the host made with `vm.gpa` - `vm.gpa.create(T)` -
/// that the collector frees with the handle, once no script can reach it:
/// for a value a script may keep after the host is done with it. On an
/// error the memory is still the host's.
pub fn adoptHandle(vm: *Vm, pointer: anytype) Vm.Error!Value {
    const T = @typeInfo(@TypeOf(pointer)).pointer.child;
    if (@sizeOf(T) == 0) @compileError("adoptHandle: a " ++ @typeName(T) ++ " has no memory to free");
    const v = try handle(vm, pointer);
    v.as(object.Handle).owned = true;
    return v;
}

/// Loads imports from files: `@import("enemy.flux")` next to the file
/// that imports it.
pub const FileLoader = struct {
    io: std.Io,

    pub fn loader(self: *FileLoader) Vm.Loader {
        return .{ .context = self, .load = load_file };
    }

    fn load_file(context: ?*anyopaque, gpa: Allocator, from: []const u8, path: []const u8) anyerror!Vm.Loader.Loaded {
        const self: *FileLoader = @ptrCast(@alignCast(context.?));
        const dir = std.fs.path.dirname(from) orelse ".";
        const joined = if (std.fs.path.isAbsolute(path)) try gpa.dupe(u8, path) else try std.fs.path.join(gpa, &.{ dir, path });
        errdefer gpa.free(joined);
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, joined, gpa, .limited(16 << 20));
        return .{ .name = joined, .source = source };
    }
};
