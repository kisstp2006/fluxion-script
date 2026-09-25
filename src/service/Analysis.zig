// SPDX-License-Identifier: BSD-2-Clause

//! One file compiled for an editor, kept with what the compiler said about
//! each name in it: the answers to what a name is, where it is declared,
//! where else it is used, and what the file declares. Nothing in it runs.
//!
//! What it gives back points into it where it can - a declaration's text,
//! its doc - so it lives as long as the analysis; what it has to put
//! together goes in the arena it is given.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const diag = @import("../diag.zig");
const Vm = @import("../vm/Vm.zig");
const Compiler = @import("../compile/Compiler.zig");
const Recorder = Compiler.Recorder;
const types = @import("../compile/types.zig");
const Type = types.Type;
const service = @import("../service.zig");
const docs = @import("docs.zig");

const Analysis = @This();

gpa: Allocator,
vm: *Vm,
recorder: Recorder,
/// What is wrong with the file, and with those it imports.
diagnostics: diag.Diagnostics,
/// The file compiled: its id among the VM's sources, and its text.
file: diag.FileId = .none,
source: []const u8 = "",
/// Each name once, in the order of the file.
uses: []Recorder.Use = &.{},
decls: std.AutoHashMapUnmanaged(Key, u32) = .empty,

const Key = struct { file: diag.FileId, start: u32 };

/// Compiles `source` as the file `name`, to be asked about.
pub fn init(gpa: Allocator, name: []const u8, source: []const u8, options: service.Options) service.Error!*Analysis {
    return create(gpa, name, source, options, false);
}

/// `init`, for a source that holds `Recorder.placeholder` where the cursor
/// is when `completing`.
pub fn create(gpa: Allocator, name: []const u8, source: []const u8, options: service.Options, completing: bool) service.Error!*Analysis {
    const a = try gpa.create(Analysis);
    errdefer gpa.destroy(a);
    const vm = try service.newVm(gpa, options);
    a.* = .{ .gpa = gpa, .vm = vm, .recorder = .init(gpa, completing), .diagnostics = .init(gpa) };
    errdefer a.free();
    // An editor wants every mistake in the file, not the first hundred.
    a.diagnostics.max_errors = 1000;
    const session = try vm.compileSession();
    session.recorder = &a.recorder;
    defer session.recorder = null;
    _ = Compiler.compileModule(vm, name, source, &a.diagnostics) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CompileFailed => {},
    };
    a.file = a.recorder.file;
    a.source = if (vm.sources.get(a.file)) |f| f.text else "";
    try a.index();
    return a;
}

pub fn deinit(a: *Analysis) void {
    const gpa = a.gpa;
    a.free();
    gpa.destroy(a);
}

fn free(a: *Analysis) void {
    a.decls.deinit(a.gpa);
    a.recorder.deinit();
    a.diagnostics.deinit();
    a.vm.destroy();
}

fn index(a: *Analysis) Allocator.Error!void {
    const uses = a.recorder.uses.items;
    std.mem.sort(Recorder.Use, uses, {}, earlier);
    // Code compiled twice - a `defer`, at each way out of its block -
    // names the same things twice.
    var n: usize = 0;
    for (uses) |u| {
        if (n > 0 and uses[n - 1].span.start == u.span.start) continue;
        uses[n] = u;
        n += 1;
    }
    a.uses = uses[0..n];
    for (a.recorder.decls.items, 0..) |d, i| try a.decls.put(a.gpa, .{ .file = d.at.file, .start = d.at.span.start }, @intCast(i));
}

/// In the order of the file; a declaration before a use at the same place.
fn earlier(_: void, x: Recorder.Use, y: Recorder.Use) bool {
    if (x.span.start != y.span.start) return x.span.start < y.span.start;
    return @intFromBool(x.is_decl) > @intFromBool(y.is_decl);
}

pub fn pool(a: *const Analysis) *types.Pool {
    return &a.vm.session.?.pool;
}

pub fn typeName(a: *const Analysis, t: Type) []const u8 {
    return a.pool().name(t);
}

pub fn textOf(a: *const Analysis, span: diag.Span) []const u8 {
    if (span.end > a.source.len or span.start > span.end) return "";
    return a.source[span.start..span.end];
}

/// The path or name a file was compiled under.
pub fn fileName(a: *const Analysis, file: diag.FileId) []const u8 {
    return a.vm.sources.name(file);
}

/// Whether a diagnostic is about the file asked about, rather than one it
/// imports.
pub fn isHere(a: *const Analysis, d: *const diag.Diagnostic) bool {
    const at = d.primary() orelse return true;
    return at.file == a.file or at.file == .none;
}

/// The name the offset is in, or just after.
pub fn useAt(a: *const Analysis, offset: u32) ?*const Recorder.Use {
    var lo: usize = 0;
    var hi = a.uses.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (a.uses[mid].span.start <= offset) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const u = &a.uses[lo - 1];
    return if (offset <= u.span.end) u else null;
}

/// The name that starts exactly at `start`.
pub fn useStarting(a: *const Analysis, start: u32) ?*const Recorder.Use {
    const u = a.useAt(start) orelse return null;
    return if (u.span.start == start) u else null;
}

pub fn declAt(a: *const Analysis, at: diag.Location) ?*const Recorder.Decl {
    const i = a.decls.get(.{ .file = at.file, .start = at.span.start }) orelse return null;
    return &a.recorder.decls.items[i];
}

pub fn declOf(a: *const Analysis, u: Recorder.Use) ?*const Recorder.Decl {
    return a.declAt(u.decl orelse return null);
}

// ---------------------------------------------------------------------------
// Hover

pub const Hover = struct {
    /// The name hovered.
    span: diag.Span,
    /// Its declaration, or the signature of what is built in, as code.
    code: []const u8,
    doc: ?[]const u8 = null,
};

/// What the name at `offset` is.
pub fn hover(a: *const Analysis, arena: Allocator, offset: u32) Allocator.Error!?Hover {
    const u = a.useAt(offset) orelse return null;
    const name = a.textOf(u.span);
    if (u.detail) |d| return .{ .span = u.span, .code = try arena.dupe(u8, d), .doc = u.doc };
    if (a.declOf(u.*)) |d| {
        var doc = d.doc;
        if (a.pool().signatureOf(d.type)) |sig| if (sig.coroutine) {
            const note = "A coroutine: `await` it for its result, or call it without `await` to start a task.";
            doc = if (doc) |text| try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ text, note }) else note;
        };
        return .{ .span = u.span, .code = d.detail, .doc = doc };
    }
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    var doc: ?[]const u8 = u.doc;
    (blk: {
        switch (u.kind) {
            .variable, .constant, .parameter, .function => {
                if (u.kind != .parameter) if (a.pool().signatureOf(u.type)) |sig| {
                    a.writeSignature(w, name, sig, false) catch |e| break :blk e;
                    break :blk;
                };
                if (u.kind == .parameter) {
                    w.print("{s}: {s}", .{ name, a.typeName(u.type) }) catch |e| break :blk e;
                } else {
                    w.print("{s} {s}: {s}", .{ if (u.mutable) "var" else "const", name, a.typeName(u.type) }) catch |e| break :blk e;
                }
            },
            .builtin_function, .builtin_method, .property => {
                const entry = a.builtin(u.*) orelse {
                    w.print("{s}: {s}", .{ name, a.typeName(u.type) }) catch |e| break :blk e;
                    break :blk;
                };
                doc = entry.doc;
                if (u.kind != .property) w.writeAll("fn ") catch |e| break :blk e;
                if (u.owner != .unknown) {
                    const owner = if (a.pool().moduleOf(u.owner)) |m| m.name else a.typeName(u.owner);
                    w.print("{s}.", .{owner}) catch |e| break :blk e;
                }
                a.writeBuiltinSig(w, u.owner, entry.sig) catch |e| break :blk e;
            },
            .builtin_type => {
                const entry = docs.find(&docs.types, name);
                doc = if (entry) |e| e.doc else null;
                w.print("type {s}", .{name}) catch |e| break :blk e;
            },
            else => w.print("{s}: {s}", .{ name, a.typeName(u.type) }) catch |e| break :blk e,
        }
    }) catch return error.OutOfMemory;
    return .{ .span = u.span, .code = out.written(), .doc = doc };
}

/// What is built in that the use names, from the table of its kind.
pub fn builtin(a: *const Analysis, u: Recorder.Use) ?docs.Entry {
    const name = a.textOf(u.span);
    return switch (u.kind) {
        .builtin_function => if (a.pool().moduleOf(u.owner)) |m| docs.find(docs.module(m.name), name) else docs.find(&docs.prelude, name),
        .builtin_method => docs.find(methodTable(a.pool(), u.owner), name),
        .property => docs.find(&docs.property, name),
        else => null,
    };
}

/// The methods of a builtin type, from the table.
pub fn methodTable(p: *types.Pool, t: Type) []const docs.Entry {
    const base = p.isOptional(t) orelse t;
    if (p.listOf(base) != null) return &docs.list;
    if (p.mapOf(base) != null) return &docs.map;
    return switch (base) {
        .string => &docs.string,
        .vec2, .vec3 => &docs.vector,
        .signal => &docs.signal,
        else => &.{},
    };
}

/// A builtin's signature, the receiver's types in place of `T`, `K`, `V`.
pub fn writeBuiltinSig(a: *const Analysis, w: *Writer, receiver: Type, sig: []const u8) Writer.Error!void {
    const p = a.pool();
    const base = p.isOptional(receiver) orelse receiver;
    var t: []const u8 = "T";
    var k: []const u8 = "K";
    var v: []const u8 = "V";
    if (p.listOf(base)) |elem| t = a.typeName(elem);
    if (p.mapOf(base)) |kv| {
        k = a.typeName(kv.key);
        v = a.typeName(kv.value);
    }
    if (base == .vec2 or base == .vec3) v = a.typeName(base);
    try docs.substitute(w, sig, t, k, v);
}

/// `fn name(a: int, b: float) bool` for a function known by its type only.
pub fn writeSignature(a: *const Analysis, w: *Writer, name: []const u8, sig: *const types.Signature, skip_self: bool) Writer.Error!void {
    try w.print("fn {s}(", .{name});
    var first = true;
    for (sig.params, 0..) |p, i| {
        if (i == 0 and sig.has_self) {
            if (skip_self) continue;
            try w.writeAll("self");
            first = false;
            continue;
        }
        if (!first) try w.writeAll(", ");
        first = false;
        if (p.name.len > 0) try w.print("{s}: ", .{p.name});
        try w.writeAll(p.type_text orelse a.typeName(p.type));
        if (p.has_default) try w.print(" = {s}", .{p.default_text orelse "..."});
    }
    try w.writeByte(')');
    if (sig.ret_text) |r| {
        if (r.len > 0) try w.print(" {s}", .{r});
    } else if (sig.ret != .void) try w.print(" {s}", .{a.typeName(sig.ret)});
}

// ---------------------------------------------------------------------------
// Where things are

/// Where the name at `offset` is declared, when it is not built in.
pub fn definition(a: *const Analysis, offset: u32) ?diag.Location {
    const u = a.useAt(offset) orelse return null;
    return u.decl;
}

/// Every place in the file naming what the name at `offset` names, its
/// declaration among them when it is in this file.
pub fn references(a: *const Analysis, arena: Allocator, offset: u32) Allocator.Error![]const diag.Span {
    const u = a.useAt(offset) orelse return &.{};
    const decl = u.decl orelse return &.{};
    var list: std.ArrayList(diag.Span) = .empty;
    for (a.uses) |x| {
        const d = x.decl orelse continue;
        if (d.file == decl.file and d.span.start == decl.span.start) try list.append(arena, x.span);
    }
    return list.items;
}

pub const Symbol = struct {
    name: []const u8,
    kind: service.Kind,
    detail: []const u8,
    /// Its name, and the whole of it.
    span: diag.Span,
    whole: diag.Span,
    children: []const Symbol = &.{},
};

/// What the file declares, members under their struct or enum: an outline.
pub fn symbols(a: *const Analysis, arena: Allocator) Allocator.Error![]const Symbol {
    const decls = a.recorder.decls.items;
    var top: std.ArrayList(Symbol) = .empty;
    for (decls, 0..) |d, i| {
        if (d.at.file != a.file or d.parent != null) continue;
        // A declaration's members are recorded straight after it.
        var end = i + 1;
        while (end < decls.len and decls[end].parent == @as(?u32, @intCast(i))) end += 1;
        const children = try arena.alloc(Symbol, end - i - 1);
        for (decls[i + 1 .. end], children) |m, *out| out.* = symbolOf(m, &.{});
        try top.append(arena, symbolOf(d, children));
    }
    return top.items;
}

fn symbolOf(d: Recorder.Decl, children: []const Symbol) Symbol {
    return .{ .name = d.name, .kind = .of(d.kind), .detail = d.detail, .span = d.at.span, .whole = d.whole, .children = children };
}
