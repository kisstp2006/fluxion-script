// SPDX-License-Identifier: BSD-2-Clause

//! What a compile tells an editor. Each name is recorded where the compiler
//! resolves it: what it names, of what type, declared where. Each
//! declaration is recorded with the text a hover shows for it, and each call
//! with the signature its arguments were checked against. Where the service
//! has written `placeholder` in place of the word at the cursor, the
//! compiler records what could be written there, instead of a mistake.
//!
//! None of it happens unless a recorder is set on the compile session:
//! `service/` sets one, and turns what it holds into highlighting, hovers,
//! completions and the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const types = @import("types.zig");
const Type = types.Type;
const Compiler = @import("Compiler.zig");
const Func = @import("Func.zig");
const names = @import("names.zig");

const Recorder = @This();

/// Written by the service where the cursor is, for the compiler to find.
pub const placeholder = "__flux_complete__";

pub const Kind = enum {
    variable,
    constant,
    parameter,
    function,
    method,
    field,
    signal,
    @"struct",
    @"enum",
    enum_member,
    module,
    builtin_function,
    builtin_type,
    builtin_method,
    /// What a builtin value has: a vector's `x`, a string's `len`.
    property,
    @"test",
};

/// A name where it is written, and what it names.
pub const Use = struct {
    span: diag.Span,
    kind: Kind,
    type: Type,
    /// Where what it names is declared; null for what is built in.
    decl: ?diag.Location = null,
    /// What a member belongs to: its struct, enum or module, or the type a
    /// builtin method is called on.
    owner: Type = .unknown,
    /// The name is the declaration itself.
    is_decl: bool = false,
    mutable: bool = false,
    /// What the host said of what it gives: a host member, a host global.
    doc: ?[]const u8 = null,
};

/// A declaration at the top of a module, or a member of one.
pub const Decl = struct {
    /// Its name, where it is declared.
    at: diag.Location,
    /// All of it, from its first keyword to its end.
    whole: diag.Span,
    kind: Kind,
    name: []const u8,
    type: Type,
    /// How it is declared, types resolved: `fn heal(amount: int) bool`.
    detail: []const u8,
    doc: ?[]const u8,
    /// The declaration it is a member of, as an index into `decls`.
    parent: ?u32 = null,
};

/// A name that could be written somewhere.
pub const Item = struct {
    name: []const u8,
    kind: Kind,
    type: Type,
    decl: ?diag.Location = null,
    mutable: bool = false,
    /// A local of the function, or of one around it.
    local: bool = false,
};

/// What could be written where the placeholder is.
pub const Completion = union(enum) {
    /// A name on its own: what is in scope there, innermost first.
    scope: []const Item,
    /// After `value.`: the fields and methods of its type.
    members: Type,
    /// After `Type.` or `module.`: what the type or the module declares.
    statics: Type,
    /// `.name` where a member of this enum is wanted.
    enum_members: Type,
    /// `Type{ .name = ... }`: the fields not given yet.
    fields: struct { of: Type, given: []const []const u8 },
    /// Where a type is written: the module's types and imports.
    types: []const Item,
    /// `module.Name` where a type is written.
    module_types: Type,
};

/// A call, with what its arguments were checked against.
pub const Call = struct {
    /// Where the callee ends: the `(` follows.
    callee_end: u32,
    /// The callee's name, to find among the uses what it names.
    name: diag.Span,
    sig: ?*const types.Signature,
    /// A method called on a value: its first parameter is given already.
    skip_self: bool,
};

gpa: Allocator,
arena_state: std.heap.ArenaAllocator,
/// The file asked about: the first one compiled. The names in the modules
/// it imports are not recorded; their declarations are, for their docs.
file: diag.FileId = .none,
/// Whether the source holds the placeholder.
completing: bool,
uses: std.ArrayList(Use) = .empty,
decls: std.ArrayList(Decl) = .empty,
calls: std.ArrayList(Call) = .empty,
completion: ?Completion = null,

pub fn init(gpa: Allocator, completing: bool) Recorder {
    return .{ .gpa = gpa, .arena_state = .init(gpa), .completing = completing };
}

pub fn deinit(r: *Recorder) void {
    r.uses.deinit(r.gpa);
    r.decls.deinit(r.gpa);
    r.calls.deinit(r.gpa);
    r.arena_state.deinit();
}

pub fn arena(r: *Recorder) Allocator {
    return r.arena_state.allocator();
}

pub fn isPlaceholder(r: *const Recorder, name: []const u8) bool {
    return r.completing and std.mem.eql(u8, name, placeholder);
}

pub fn use(r: *Recorder, u: Use) Allocator.Error!void {
    try r.uses.append(r.gpa, u);
}

pub fn globalKind(k: types.GlobalKind) Kind {
    return switch (k) {
        .variable => .variable,
        .constant => .constant,
        .function => .function,
        .@"struct" => .@"struct",
        .@"enum" => .@"enum",
        .import => .module,
    };
}

fn localKind(l: Func.Local) Kind {
    // Nothing but the parameters is declared outside every block.
    return if (l.depth == 0) .parameter else .variable;
}

/// A name resolved in a function: to a local, a variable captured from a
/// function around it, a module's declaration, or something built in.
pub fn place(r: *Recorder, f: *Func, name: []const u8, span: diag.Span, p: names.Place) Allocator.Error!void {
    const c = f.comp;
    switch (p) {
        .local => |reg| {
            const l = names.localByReg(f, reg).?.*;
            try r.use(.{ .span = span, .kind = localKind(l), .type = l.type, .decl = c.at(l.span), .mutable = !l.is_const });
        },
        .upval => |u| {
            var at = f.parent;
            while (at) |x| : (at = x.parent) if (x.findLocal(name)) |l| {
                return r.use(.{ .span = span, .kind = localKind(l.*), .type = f.upvals.items[u].type, .decl = c.at(l.span), .mutable = !l.is_const });
            };
        },
        .global => |g| try r.global(c, span, g.*),
        .builtin => |v| {
            const given = c.vm.host_docs.get(name);
            const callable = v.tag == .native or v.tag == .function;
            try r.use(.{ .span = span, .kind = if (callable or given == null) .builtin_function else .constant, .type = .any, .doc = given });
        },
        .none => {},
    }
}

pub fn global(r: *Recorder, c: *Compiler, span: diag.Span, g: Compiler.Global) Allocator.Error!void {
    try r.use(.{ .span = span, .kind = globalKind(g.kind), .type = g.type, .decl = c.at(g.span), .mutable = g.kind == .variable });
}

pub fn enumMember(r: *Recorder, span: diag.Span, en: *const types.Enum, index: u32) Allocator.Error!void {
    const decl: ?diag.Location = if (index < en.spans.len) .{ .file = en.file, .span = en.spans[index] } else null;
    try r.use(.{ .span = span, .kind = .enum_member, .type = en.self_type, .decl = decl, .owner = en.self_type });
}

/// A struct's field or signal, or a method of a struct or an enum, named on
/// a value or a type.
pub fn member(r: *Recorder, c: *Compiler, span: diag.Span, owner: Type, m: Member) Allocator.Error!void {
    switch (m) {
        .field => |fd| if (fd.host) {
            try r.use(.{ .span = span, .kind = .field, .type = fd.type, .owner = owner, .doc = fd.doc });
        } else {
            try r.use(.{ .span = span, .kind = if (fd.is_signal) .signal else .field, .type = fd.type, .decl = .{ .file = fd.file, .span = fd.span }, .owner = owner, .mutable = !fd.is_const });
        },
        .method => |md| try r.use(.{ .span = span, .kind = .method, .type = try c.pool.function(md.sig), .decl = .{ .file = md.file, .span = md.span }, .owner = owner }),
    }
}

pub const Member = union(enum) {
    field: *const types.Field,
    method: *const types.Method,
};

/// `Type.NAME`, declared in the struct or one it extends.
pub fn structConstant(r: *Recorder, span: diag.Span, s: *const types.Struct, name: []const u8) Allocator.Error!void {
    var at: ?*const types.Struct = s;
    while (at) |x| : (at = x.parent) if (x.consts.getPtr(name)) |k| {
        return r.use(.{ .span = span, .kind = .constant, .type = k.type, .decl = .{ .file = x.file, .span = k.span }, .owner = s.self_type });
    };
}

/// A module's declaration named through the module, whose type is
/// `module`: `math.sqrt`, `enemies.Enemy`.
pub fn exported(r: *Recorder, span: diag.Span, module_type: Type, m: *const types.Module, name: []const u8, ex: types.Export) Allocator.Error!void {
    if (m.globals.get(name)) |g| {
        return r.use(.{ .span = span, .kind = globalKind(g.kind), .type = ex.type, .decl = .{ .file = m.object.file, .span = g.span }, .owner = module_type, .mutable = g.kind == .variable });
    }
    // A module built in, or made by the host: only its values are known.
    const kind: Kind = if (ex.value) |v| (if (v.tag == .native or v.tag == .function) .builtin_function else .constant) else .variable;
    try r.use(.{ .span = span, .kind = kind, .type = ex.type, .owner = module_type });
}

/// A local declared: a parameter, a variable, a capture.
pub fn local(r: *Recorder, f: *Func, l: Func.Local) Allocator.Error!void {
    const c = f.comp;
    // What is declared under another name's span - the `self` of a
    // struct's defaults, at the struct's name - is not the name written.
    if (l.span.end > c.source.len or !std.mem.eql(u8, c.source[l.span.start..l.span.end], l.name)) return;
    try r.use(.{ .span = l.span, .kind = localKind(l), .type = l.type, .decl = c.at(l.span), .is_decl = true, .mutable = !l.is_const });
}

/// A local function's type, known once its body is compiled.
pub fn retype(r: *Recorder, span: diag.Span, t: Type) void {
    var i = r.uses.items.len;
    while (i > 0) {
        i -= 1;
        const u = &r.uses.items[i];
        if (u.is_decl and u.span.start == span.start) {
            u.type = t;
            u.kind = .function;
            return;
        }
    }
}

/// A call about to be compiled, and the signature its arguments are
/// checked against when there is one.
pub fn call(r: *Recorder, callee: *const ast.Expr, sig: ?*const types.Signature, skip_self: bool) Allocator.Error!void {
    const name: diag.Span = switch (callee.kind) {
        .field => |fl| fl.name.span,
        else => callee.span,
    };
    try r.calls.append(r.gpa, .{ .callee_end = callee.span.end, .name = name, .sig = sig, .skip_self = skip_self });
}

// ---------------------------------------------------------------------------
// At the placeholder

fn shadowed(items: []const Item, name: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i.name, name)) return true;
    return false;
}

/// What is in scope in `f`: its locals and those of the functions around
/// it, innermost first, then the module's declarations and the prelude.
pub fn scope(r: *Recorder, f: *Func) Allocator.Error!void {
    if (r.completion != null) return;
    const c = f.comp;
    const a = r.arena();
    var items: std.ArrayList(Item) = .empty;
    var at: ?*Func = f;
    while (at) |x| : (at = x.parent) {
        var i = x.locals.items.len;
        while (i > 0) {
            i -= 1;
            const l = x.locals.items[i];
            if (l.name.len == 0 or std.mem.eql(u8, l.name, "_") or shadowed(items.items, l.name)) continue;
            try items.append(a, .{ .name = l.name, .kind = localKind(l), .type = l.type, .decl = c.at(l.span), .mutable = !l.is_const, .local = true });
        }
    }
    for (c.globals.keys(), c.globals.values()) |name, g| {
        if (shadowed(items.items, name)) continue;
        try items.append(a, .{ .name = name, .kind = globalKind(g.kind), .type = g.type, .decl = c.at(g.span), .mutable = g.kind == .variable });
    }
    var it = c.vm.prelude.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*.bytes();
        if (shadowed(items.items, name)) continue;
        const callable = e.value_ptr.tag == .native or e.value_ptr.tag == .function;
        const given = c.vm.host_docs.contains(name);
        try items.append(a, .{ .name = name, .kind = if (callable or !given) .builtin_function else .constant, .type = .any });
    }
    r.completion = .{ .scope = items.items };
}

pub fn members(r: *Recorder, t: Type) void {
    if (r.completion == null) r.completion = .{ .members = t };
}

pub fn statics(r: *Recorder, t: Type) void {
    if (r.completion == null) r.completion = .{ .statics = t };
}

pub fn enumMembers(r: *Recorder, t: Type) void {
    if (r.completion == null) r.completion = .{ .enum_members = t };
}

pub fn moduleTypes(r: *Recorder, t: Type) void {
    if (r.completion == null) r.completion = .{ .module_types = t };
}

pub fn fields(r: *Recorder, of: Type, given: []const ast.FieldInit) Allocator.Error!void {
    if (r.completion != null) return;
    const list = try r.arena().alloc([]const u8, given.len);
    for (given, list) |g, *out| out.* = g.name.text;
    r.completion = .{ .fields = .{ .of = of, .given = list } };
}

/// The types a module can name: its structs and enums, and the modules it
/// imports, whose types it can name too. The builtin types are the
/// service's to add.
pub fn typeNames(r: *Recorder, c: *Compiler) Allocator.Error!void {
    if (r.completion != null) return;
    var items: std.ArrayList(Item) = .empty;
    for (c.globals.keys(), c.globals.values()) |name, g| switch (g.kind) {
        .@"struct", .@"enum", .import => try items.append(r.arena(), .{ .name = name, .kind = globalKind(g.kind), .type = g.type, .decl = c.at(g.span) }),
        else => {},
    };
    r.completion = .{ .types = items.items };
}

// ---------------------------------------------------------------------------
// Declarations

const New = struct {
    kind: Kind,
    name: ast.Name,
    whole: diag.Span,
    type: Type,
    doc: ?[]const u8,
    detail: []const u8,
    mutable: bool = false,
};

fn declare(r: *Recorder, c: *Compiler, d: New, parent: ?u32) Allocator.Error!u32 {
    try r.decls.append(r.gpa, .{
        .at = c.at(d.name.span),
        .whole = d.whole,
        .kind = d.kind,
        .name = d.name.text,
        .type = d.type,
        .detail = d.detail,
        .doc = if (d.doc) |text| try r.arena().dupe(u8, text) else null,
        .parent = parent,
    });
    if (c.file == r.file) try r.use(.{ .span = d.name.span, .kind = d.kind, .type = d.type, .decl = c.at(d.name.span), .is_decl = true, .mutable = d.mutable });
    return @intCast(r.decls.items.len - 1);
}

/// Every declaration of a module, once its bodies are compiled and so each
/// type is known.
pub fn module(r: *Recorder, c: *Compiler, tree: ast.Module) Allocator.Error!void {
    for (tree.stmts) |s| switch (s.kind) {
        .@"fn" => |node| {
            const g = c.global(node.name.?.text) orelse continue;
            if (g.node != s) continue;
            const sig = c.pool.signatureOf(g.type) orelse continue;
            _ = try r.declare(c, .{ .kind = .function, .name = node.name.?, .whole = node.span, .type = g.type, .doc = node.doc, .detail = try r.fnText(c, null, node, sig) }, null);
        },
        .@"struct" => |node| try r.structDecl(c, node),
        .@"enum" => |node| try r.enumDecl(c, node),
        .@"var" => |v| {
            const g = c.global(v.name.text) orelse continue;
            if (g.node != s) continue;
            const kind = globalKind(g.kind);
            _ = try r.declare(c, .{ .kind = kind, .name = v.name, .whole = v.span, .type = g.type, .doc = v.doc, .detail = try r.varText(c, kind, null, v, g.type), .mutable = g.kind == .variable }, null);
        },
        .@"test" => |t| {
            // The name is the text of its string, in the file's source.
            const start = @intFromPtr(t.name.ptr) -% @intFromPtr(c.source.ptr);
            if (start > c.source.len) continue;
            const name: ast.Name = .{ .text = t.name, .span = .{ .start = @intCast(start), .end = @intCast(start + t.name.len) } };
            const detail = try std.fmt.allocPrint(r.arena(), "test \"{s}\"", .{t.name});
            try r.decls.append(r.gpa, .{ .at = c.at(name.span), .whole = t.span, .kind = .@"test", .name = t.name, .type = .void, .detail = detail, .doc = null });
        },
        else => {},
    };
}

fn structDecl(r: *Recorder, c: *Compiler, node: *const ast.Struct) Allocator.Error!void {
    const info = for (c.structs.items) |sd| {
        if (sd.node == node) break sd.info;
    } else return;
    const g = c.global(node.name.text) orelse return;
    const detail = if (info.parent) |p|
        try std.fmt.allocPrint(r.arena(), "struct {s} extends {s}", .{ node.name.text, p.name })
    else
        try std.fmt.allocPrint(r.arena(), "struct {s}", .{node.name.text});
    const self = try r.declare(c, .{ .kind = .@"struct", .name = node.name, .whole = node.span, .type = g.type, .doc = node.doc, .detail = detail }, null);
    for (node.fields) |f| {
        const fd = info.field(f.name.text) orelse continue;
        if (fd.span.start != f.name.span.start) continue;
        _ = try r.declare(c, .{ .kind = .field, .name = f.name, .whole = f.span, .type = fd.type, .doc = f.doc, .detail = try r.varText(c, .variable, node.name.text, f, fd.type), .mutable = true }, self);
    }
    for (node.signals) |sig| {
        const fd = info.field(sig.name.text) orelse continue;
        if (!fd.is_signal or fd.span.start != sig.name.span.start) continue;
        var out: Writer.Allocating = .init(r.arena());
        writeParams(c, &out.writer, "signal ", node.name.text, sig.name.text, sig.params, if (fd.signal) |s| s.params else &.{}) catch return error.OutOfMemory;
        _ = try r.declare(c, .{ .kind = .signal, .name = sig.name, .whole = sig.span, .type = .signal, .doc = sig.doc, .detail = out.written() }, self);
    }
    for (node.consts) |k| {
        const kc = info.consts.get(k.name.text) orelse continue;
        _ = try r.declare(c, .{ .kind = .constant, .name = k.name, .whole = k.span, .type = kc.type, .doc = k.doc, .detail = try r.varText(c, .constant, node.name.text, k, kc.type) }, self);
    }
    for (node.methods) |m| {
        const md = info.methods.get(m.name.?.text) orelse continue;
        if (md.span.start != m.name.?.span.start) continue;
        _ = try r.declare(c, .{ .kind = .method, .name = m.name.?, .whole = m.span, .type = try c.pool.function(md.sig), .doc = m.doc, .detail = try r.fnText(c, node.name.text, m, md.sig) }, self);
    }
}

fn enumDecl(r: *Recorder, c: *Compiler, node: *const ast.Enum) Allocator.Error!void {
    const info = for (c.enums.items) |ed| {
        if (ed.node == node) break ed.info;
    } else return;
    const g = c.global(node.name.text) orelse return;
    var out: Writer.Allocating = .init(r.arena());
    (blk: {
        const w = &out.writer;
        w.print("enum {s} {{ ", .{node.name.text}) catch |e| break :blk e;
        for (info.members, 0..) |m, i| {
            if (i == 8) {
                w.writeAll(", ...") catch |e| break :blk e;
                break;
            }
            w.print("{s}{s}", .{ if (i > 0) ", " else "", m }) catch |e| break :blk e;
        }
        w.writeAll(" }") catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    const self = try r.declare(c, .{ .kind = .@"enum", .name = node.name, .whole = node.span, .type = g.type, .doc = node.doc, .detail = out.written() }, null);
    for (node.members, 0..) |m, i| {
        if (i >= info.type_obj.values.len) break;
        const detail = try std.fmt.allocPrint(r.arena(), "{s}.{s} = {d}", .{ node.name.text, m.name.text, info.type_obj.values[i] });
        _ = try r.declare(c, .{ .kind = .enum_member, .name = m.name, .whole = m.name.span, .type = info.self_type, .doc = null, .detail = detail }, self);
    }
    for (node.methods) |m| {
        const md = info.methods.get(m.name.?.text) orelse continue;
        if (md.span.start != m.name.?.span.start) continue;
        _ = try r.declare(c, .{ .kind = .method, .name = m.name.?, .whole = m.span, .type = try c.pool.function(md.sig), .doc = m.doc, .detail = try r.fnText(c, node.name.text, m, md.sig) }, self);
    }
}

// ---------------------------------------------------------------------------
// The text of a declaration

/// A default or an initializer as written, when it is short enough to show.
fn short(text: []const u8) ?[]const u8 {
    if (text.len > 40 or std.mem.indexOfScalar(u8, text, '\n') != null) return null;
    return text;
}

fn written(c: *Compiler, e: *const ast.Expr) ?[]const u8 {
    if (e.span.end > c.source.len or e.span.start >= e.span.end) return null;
    return short(c.source[e.span.start..e.span.end]);
}

fn fnText(r: *Recorder, c: *Compiler, owner: ?[]const u8, node: *const ast.Fn, sig: *const types.Signature) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(r.arena());
    writeFn(c, &out.writer, owner, node, sig) catch return error.OutOfMemory;
    return out.written();
}

fn writeFn(c: *Compiler, w: *Writer, owner: ?[]const u8, node: *const ast.Fn, sig: *const types.Signature) Writer.Error!void {
    try writeParams(c, w, "fn ", owner, if (node.name) |n| n.text else "", node.params, sig.params);
    if (sig.ret != .void) try w.print(" {s}", .{c.typeName(sig.ret)});
}

fn writeParams(c: *Compiler, w: *Writer, keyword: []const u8, owner: ?[]const u8, name: []const u8, params: []const ast.Param, resolved: []const types.Param) Writer.Error!void {
    try w.writeAll(keyword);
    if (owner) |o| try w.print("{s}.", .{o});
    try w.print("{s}(", .{name});
    for (params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        if (p.is_self) {
            try w.writeAll("self");
            continue;
        }
        try w.writeAll(p.name.text);
        const t: Type = if (i < resolved.len) resolved[i].type else .any;
        if (p.type != null or !Compiler.dynamic(t)) try w.print(": {s}", .{c.typeName(t)});
        if (p.default) |d| if (written(c, d)) |text| try w.print(" = {s}", .{text});
    }
    try w.writeByte(')');
}

fn varText(r: *Recorder, c: *Compiler, kind: Kind, owner: ?[]const u8, v: *const ast.VarDecl, t: Type) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(r.arena());
    (blk: {
        const w = &out.writer;
        if (kind == .module) {
            w.print("const {s}", .{v.name.text}) catch |e| break :blk e;
            if (v.value) |initial| if (written(c, initial)) |text| w.print(" = {s}", .{text}) catch |e| break :blk e;
            break :blk;
        }
        w.writeAll(if (kind == .constant) "const " else "var ") catch |e| break :blk e;
        if (owner) |o| w.print("{s}.", .{o}) catch |e| break :blk e;
        w.print("{s}: {s}", .{ v.name.text, c.typeName(t) }) catch |e| break :blk e;
        if (v.value) |initial| if (written(c, initial)) |text| w.print(" = {s}", .{text}) catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return out.written();
}
