// SPDX-License-Identifier: BSD-2-Clause

//! One module, source to bytecode: parsed, its declarations collected and
//! resolved, then every function checked and compiled in a single pass.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const parse = @import("../syntax/parse.zig");
const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const types = @import("types.zig");
const Type = types.Type;
const Session = @import("Session.zig");
const Func = @import("Func.zig");
const decl = @import("decl.zig");
const stmt = @import("stmt.zig");
const shape = @import("shape.zig");
pub const Patch = @import("Patch.zig");
pub const Recorder = @import("Recorder.zig");

const Compiler = @This();

pub const Error = error{ OutOfMemory, CompileFailed };

pub const Global = struct {
    index: u32,
    type: Type,
    kind: Kind,
    span: diag.Span,
    value: ?Value = null,
    node: ?*const ast.Stmt = null,

    pub const Kind = types.GlobalKind;
};

vm: *Vm,
gpa: Allocator,
arena: Allocator,
session: *Session,
pool: *types.Pool,
diags: *diag.Diagnostics,
file: diag.FileId,
source: []const u8,
name: []const u8,
module: *object.Module,
info: *types.Module,
globals: std.StringArrayHashMapUnmanaged(Global) = .empty,
structs: std.ArrayList(decl.StructDecl) = .empty,
enums: std.ArrayList(decl.EnumDecl) = .empty,
functions: std.ArrayList(decl.FnDecl) = .empty,
tests: std.ArrayList(*const ast.Test) = .empty,
/// Set when the module is compiled again for a reload.
patch: ?*Patch = null,
/// Set when an editor asked about the code: see `Recorder.zig`.
recorder: ?*Recorder = null,

/// The recorder, when this is the file the editor asked about.
pub fn recording(c: *const Compiler) ?*Recorder {
    const r = c.recorder orelse return null;
    return if (r.file == c.file) r else null;
}

pub fn at(c: *const Compiler, span: diag.Span) diag.Location {
    return .{ .file = c.file, .span = span };
}

pub fn err(c: *Compiler, span: diag.Span, comptime fmt: []const u8, args: anytype) Allocator.Error!diag.Diagnostics.Handle {
    return c.diags.err(c.at(span), fmt, args);
}

pub fn warn(c: *Compiler, span: diag.Span, comptime fmt: []const u8, args: anytype) Allocator.Error!diag.Diagnostics.Handle {
    return c.diags.warn(c.at(span), fmt, args);
}

pub fn typeName(c: *Compiler, t: Type) []const u8 {
    return c.pool.name(t);
}

/// Known only at run time: `any`, or a mistake already reported.
pub fn dynamic(t: Type) bool {
    return t == .any or t == .unknown;
}

pub fn global(c: *Compiler, name: []const u8) ?*Global {
    return c.globals.getPtr(name);
}

/// A new module variable, `undefined` until its initializer runs.
pub fn addGlobal(c: *Compiler, name: []const u8, g: Global) Error!*Global {
    const gop = try c.globals.getOrPut(c.gpa, name);
    if (gop.found_existing) {
        const h = try c.err(g.span, "`{s}` is already declared in this file", .{name});
        _ = try h.label(c.at(gop.value_ptr.span), "first declared here", .{});
        return gop.value_ptr;
    }
    var entry = g;
    const key = try c.vm.intern(name);
    // A reload keeps each name where it was: code from before reads it there.
    const kept = if (c.patch) |p| p.oldIndex(key) else null;
    entry.index = kept orelse @intCast(c.module.globals.items.len);
    gop.value_ptr.* = entry;
    if (kept == null) {
        try c.module.globals.append(c.vm.gpa, .undef);
        try c.module.names.append(c.vm.gpa, key);
    }
    try c.module.lookup.put(c.vm.gpa, key, entry.index);
    return gop.value_ptr;
}

pub const Options = struct {
    /// Code outside functions is allowed; a script run by `flux run` is
    /// mostly that.
    name: []const u8,
};

/// Compiles `source` into a module ready to run, or reports why not.
pub fn compileModule(vm: *Vm, name: []const u8, source: []const u8, diags: *diag.Diagnostics) Error!*object.Module {
    return compileInto(vm, name, source, diags, null);
}

/// Compiles `source` again over the module `patch` holds, for a reload:
/// what its objects held before stays in the patch, to be put back if the
/// reload fails. Its `<main>` runs only the initializers of variables whose
/// values are not kept; the top-level statements ran when it first loaded.
pub fn recompile(vm: *Vm, patch: *Patch, source: []const u8, diags: *diag.Diagnostics) Error!void {
    _ = try compileInto(vm, patch.module.path, source, diags, patch);
}

fn compileInto(vm: *Vm, name: []const u8, source: []const u8, diags: *diag.Diagnostics, patch: ?*Patch) Error!*object.Module {
    const session = try vm.compileSession();
    const file = try vm.sources.add(name, source);
    const text = vm.sources.get(file).?.text;

    if (!std.unicode.utf8ValidateSlice(text)) {
        var i: usize = 0;
        while (i < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
            if (i + len > text.len or !std.unicode.utf8ValidateSlice(text[i .. i + len])) break;
            i += len;
        }
        _ = try diags.err(.{ .file = file, .span = .{ .start = @intCast(i), .end = @intCast(i + 1) } }, "the file is not UTF-8: byte 0x{x:0>2} is not part of any character", .{text[@min(i, text.len - 1)]});
        return error.CompileFailed;
    }

    if (session.loading.contains(name)) {
        _ = try diags.err(.{ .file = file, .span = .empty }, "`{s}` imports itself, through the modules it imports", .{name});
        return error.CompileFailed;
    }
    const key = try session.pool.allocator().dupe(u8, name);
    try session.loading.put(vm.gpa, key, {});
    defer _ = session.loading.remove(key);

    var arena_state: std.heap.ArenaAllocator = .init(vm.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;

    // The list may already hold the errors of the file importing this one.
    const errors_before = diags.errors;
    const tree = try parse.parse(arena, vm.gpa, text, file, diags);

    const module = if (patch) |p| p.module else try make.module(vm, try vm.intern(name));
    if (patch) |p| try p.begin(vm, file) else {
        module.file = file;
        module.path = try vm.gpa.dupe(u8, name);
    }
    const info = try session.pool.allocator().create(types.Module);
    info.* = .{ .name = key, .object = module };
    if (session.recorder) |r| if (r.file == .none) {
        r.file = file;
    };

    var c: Compiler = .{
        .vm = vm,
        .gpa = vm.gpa,
        .arena = arena,
        .session = session,
        .pool = &session.pool,
        .diags = diags,
        .file = file,
        .source = text,
        .name = key,
        .module = module,
        .info = info,
        .patch = patch,
        .recorder = session.recorder,
    };
    defer c.deinit();

    try decl.collect(&c, tree);
    try decl.resolve(&c);

    const main_proto = try make.proto(vm, try vm.intern("<main>"));
    var main: Func = .init(&c, null, "<main>");
    defer main.deinit();
    // On a reload the other top-level statements are still checked, here,
    // but do not run again.
    var unused: Func = .init(&c, null, "<main>");
    defer unused.deinit();
    for (tree.stmts) |s| {
        switch (s.kind) {
            .@"fn", .@"struct", .@"enum", .@"test" => continue,
            else => {},
        }
        if (diags.full()) break;
        const compiled = if (patch == null) stmt.topLevel(&main, s) else if (s.kind == .@"var") stmt.reinit(&main, s) else stmt.topLevel(&unused, s);
        compiled catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CompileFailed => {},
        };
    }
    main.span = .at(@intCast(text.len));
    try main.abc(.retnull, 0, 0, 0);
    try main.finish(main_proto);

    try decl.compileBodies(&c);
    if (c.recorder) |r| try r.module(&c, tree);

    if (diags.errors > errors_before) return error.CompileFailed;

    module.main = main_proto;
    try decl.publish(&c);
    try shape.record(&c);
    module.state = .ready;
    if (patch) |p| p.old_info = session.modules.get(key);
    try session.modules.put(vm.gpa, key, info);
    try vm.modules.put(vm.gpa, key, module);
    return module;
}

fn deinit(c: *Compiler) void {
    c.globals.deinit(c.gpa);
    c.structs.deinit(c.gpa);
    c.enums.deinit(c.gpa);
    c.functions.deinit(c.gpa);
    c.tests.deinit(c.gpa);
}
