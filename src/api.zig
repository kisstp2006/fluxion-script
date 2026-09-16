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
const native = @import("lib/native.zig");
const reload_mod = @import("reload.zig");

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
    return native.define(vm, name, func, min, max);
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
            try native.function(vm, m, field.name, bind.wrap(x), n, n);
        } else {
            try native.member(vm, m, field.name, bind.toValue(vm, x) catch return error.OutOfMemory);
        }
    }
    const key = try vm.gpa.dupe(u8, name);
    const old = try vm.native_modules.fetchPut(vm.gpa, key, m);
    if (old) |o| vm.gpa.free(o.key);
    return m;
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

/// A new `T`, owned by the script that gets it.
pub fn newHandle(vm: *Vm, comptime T: type) Vm.Error!Value {
    return @import("reflect.zig").create(vm, T);
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
