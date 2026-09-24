// SPDX-License-Identifier: BSD-2-Clause

//! What could be typed at the cursor, and the signature of the call whose
//! arguments it is among. Each compiles the file again, with the word at
//! the cursor replaced by `Recorder.placeholder`: where the compiler finds
//! it, it records what could stand there - what is in scope, the members of
//! the value before the `.`, the members of the enum the place wants.
//!
//! Everything given back is copied into the arena given, since the compile
//! it came from is gone when these return.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const diag = @import("../diag.zig");
const token = @import("../syntax/token.zig");
const Compiler = @import("../compile/Compiler.zig");
const Recorder = Compiler.Recorder;
const builtins = @import("../compile/builtins.zig");
const types = @import("../compile/types.zig");
const Type = types.Type;
const service = @import("../service.zig");
const Kind = service.Kind;
const Analysis = @import("Analysis.zig");
const cursor = @import("cursor.zig");
const docs = @import("docs.zig");

pub const Item = struct {
    label: []const u8,
    kind: Kind,
    /// Its type, or how it is declared.
    detail: []const u8 = "",
    doc: ?[]const u8 = null,
    /// Offered first when lower: the locals, then what the value or the
    /// module has, then the prelude, then the keywords.
    rank: u8 = 0,
};

pub const Completions = struct {
    items: []const Item,
    /// The word at the cursor, which a completion replaces.
    start: u32,
    end: u32,
};

/// What could be typed at `offset` in `source`, the file `name`.
pub fn complete(gpa: Allocator, arena: Allocator, name: []const u8, source: []const u8, offset: u32, options: service.Options) service.Error!Completions {
    // Inside the quotes of a string a call takes: what the host says it may
    // say.
    if (options.strings) |strings| if (try cursor.stringArgument(gpa, source, offset)) |at| {
        const values = try strings.values(strings.context, arena, at);
        const items = try arena.alloc(Item, values.len);
        for (values, items) |value, *it| it.* = .{
            .label = try arena.dupe(u8, value.label),
            .kind = .enum_member,
            .detail = try arena.dupe(u8, value.detail),
            .doc = if (value.doc) |d| try arena.dupe(u8, d) else null,
        };
        return .{ .items = items, .start = at.start, .end = at.end };
    };
    const ctx = try cursor.at(gpa, source, offset);
    var list: std.ArrayList(Item) = .empty;
    var out: Completions = .{ .items = &.{}, .start = ctx.start, .end = ctx.end };
    switch (ctx.kind) {
        .none => return out,
        .builtin => {
            for (docs.annotations) |e| try list.append(arena, .{ .label = e.name, .kind = .annotation, .detail = e.sig, .doc = e.doc });
            out.items = list.items;
            return out;
        },
        else => {},
    }
    const text = try cursor.rewrite(gpa, source, ctx);
    defer gpa.free(text);
    const a = try Analysis.create(gpa, name, text, options, true);
    defer a.deinit();
    var add: Adder = .{ .a = a, .arena = arena, .list = &list };
    if (a.recorder.completion) |c| switch (c) {
        .scope => |items| {
            for (items) |it| try add.item(it, if (it.local) 0 else if (it.kind == .builtin_function) 2 else 1);
            try add.keywords();
        },
        .members => |t| try add.members(t),
        .statics => |t| try add.statics(t),
        .enum_members => |t| try add.enumMembers(t),
        .fields => |f| try add.fields(f.of, f.given),
        .types => |items| {
            for (items) |it| try add.item(it, 1);
            for (docs.types) |e| try add.push(e.name, .builtin_type, "", e.doc, 2);
        },
        .module_types => |t| try add.moduleTypes(t),
    } else if (ctx.kind == .name) {
        // The compiler never got to the cursor: the code around it does not
        // parse yet. What the file declares, and what is always there.
        try add.fallback();
    }
    out.items = list.items;
    return out;
}

const Adder = struct {
    a: *Analysis,
    arena: Allocator,
    list: *std.ArrayList(Item),

    fn has(ad: *const Adder, label: []const u8) bool {
        for (ad.list.items) |i| if (std.mem.eql(u8, i.label, label)) return true;
        return false;
    }

    fn push(ad: *Adder, label: []const u8, kind: Kind, detail: []const u8, doc: ?[]const u8, rank: u8) Allocator.Error!void {
        if (std.mem.eql(u8, label, Recorder.placeholder) or ad.has(label)) return;
        try ad.list.append(ad.arena, .{
            .label = try ad.arena.dupe(u8, label),
            .kind = kind,
            .detail = try ad.arena.dupe(u8, detail),
            .doc = if (doc) |d| try ad.arena.dupe(u8, d) else null,
            .rank = rank,
        });
    }

    /// A name with a declaration: its text and doc from the declaration,
    /// or its type when the declaration is a local's.
    fn declared(ad: *Adder, label: []const u8, kind: Kind, t: Type, at: ?diag.Location, rank: u8) Allocator.Error!void {
        if (at) |loc| if (ad.a.declAt(loc)) |d| return ad.push(label, kind, d.detail, d.doc, rank);
        const detail = if (ad.a.pool().signatureOf(t)) |sig| blk: {
            var out: Writer.Allocating = .init(ad.arena);
            ad.a.writeSignature(&out.writer, label, sig, false) catch return error.OutOfMemory;
            break :blk out.written();
        } else ad.a.typeName(t);
        try ad.push(label, kind, detail, null, rank);
    }

    fn item(ad: *Adder, it: Recorder.Item, rank: u8) Allocator.Error!void {
        if (it.decl == null) if (ad.a.vm.host_docs.get(it.name)) |doc| return ad.push(it.name, .of(it.kind), "given by the host", doc, rank);
        if (it.kind == .builtin_function) {
            if (docs.find(&docs.prelude, it.name)) |e| return ad.push(it.name, .builtin_function, e.sig, e.doc, rank);
            return ad.push(it.name, .builtin_function, "given by the host", null, rank);
        }
        try ad.declared(it.name, .of(it.kind), it.type, it.decl, rank);
    }

    fn keywords(ad: *Adder) Allocator.Error!void {
        for (token.keywords.keys()) |k| try ad.push(k, .keyword, "", null, 3);
    }

    fn builtinEntry(ad: *Adder, kind: Kind, receiver: Type, e: docs.Entry) Allocator.Error!void {
        var out: Writer.Allocating = .init(ad.arena);
        ad.a.writeBuiltinSig(&out.writer, receiver, e.sig) catch return error.OutOfMemory;
        try ad.push(e.name, kind, out.written(), e.doc, 0);
    }

    /// What a value of type `t` has, after its `.`.
    fn members(ad: *Adder, t0: Type) Allocator.Error!void {
        const p = ad.a.pool();
        const t = p.isOptional(t0) orelse t0;
        if (p.structOf(t)) |s| {
            for (s.fields.items) |fd| {
                if (fd.host) {
                    try ad.push(fd.name, .field, "given by the host", fd.doc, 0);
                } else {
                    try ad.declared(fd.name, if (fd.is_signal) .signal else .field, fd.type, .{ .file = fd.file, .span = fd.span }, 0);
                }
            }
            var at: ?*types.Struct = s;
            while (at) |x| : (at = x.parent) for (x.methods.values()) |m| {
                if (m.sig.has_self) try ad.declared(m.name, .method, try p.function(m.sig), .{ .file = m.file, .span = m.span }, 0);
            };
            return;
        }
        if (p.enumOf(t)) |e| {
            for (e.methods.values()) |m| if (m.sig.has_self) try ad.declared(m.name, .method, try p.function(m.sig), .{ .file = m.file, .span = m.span }, 0);
            return;
        }
        const props: []const []const u8 = switch (t) {
            .string => &.{"len"},
            .vec2 => &.{ "x", "y" },
            .vec3 => &.{ "x", "y", "z" },
            .color => &.{ "r", "g", "b", "a" },
            .@"error" => &.{ "name", "message" },
            else => if (p.listOf(t) != null or p.mapOf(t) != null) &.{"len"} else &.{},
        };
        for (props) |n| if (docs.find(&docs.property, n)) |e| try ad.builtinEntry(.property, t, e);
        for (Analysis.methodTable(p, t)) |e| {
            if (try builtins.methodIn(p, t, e.name, &.{}) != null) try ad.builtinEntry(.builtin_method, t, e);
        }
    }

    /// What a struct, an enum or a module declares, after its name and `.`.
    fn statics(ad: *Adder, t: Type) Allocator.Error!void {
        const p = ad.a.pool();
        if (p.metaOf(t)) |inner| {
            if (p.structOf(inner)) |s| {
                var at: ?*types.Struct = s;
                while (at) |x| : (at = x.parent) {
                    for (x.consts.values()) |k| try ad.declared(k.name, .constant, k.type, .{ .file = x.file, .span = k.span }, 0);
                    for (x.methods.values()) |m| try ad.declared(m.name, .method, try p.function(m.sig), .{ .file = m.file, .span = m.span }, if (m.sig.has_self) 1 else 0);
                }
            } else if (p.enumOf(inner)) |e| {
                try ad.enumMembers(inner);
                for (e.methods.values()) |m| try ad.declared(m.name, .method, try p.function(m.sig), .{ .file = m.file, .span = m.span }, 1);
            }
            return;
        }
        const m = p.moduleOf(t) orelse return;
        for (m.exports.keys(), m.exports.values()) |n, ex| {
            if (m.globals.get(n)) |g| {
                try ad.declared(n, .of(Recorder.globalKind(g.kind)), ex.type, .{ .file = m.object.file, .span = g.span }, 0);
                continue;
            }
            // A module built in, or the host's: its table says what it is.
            const is_fn = if (ex.value) |v| v.tag == .native or v.tag == .function else false;
            const kind: Kind = if (is_fn) .builtin_function else .constant;
            if (docs.find(docs.module(m.name), n)) |e| try ad.push(n, kind, e.sig, e.doc, 0) else try ad.push(n, kind, ad.a.typeName(ex.type), null, 0);
        }
    }

    fn enumMembers(ad: *Adder, t: Type) Allocator.Error!void {
        const e = ad.a.pool().enumOf(t) orelse return;
        for (e.members, 0..) |n, i| {
            const at: ?diag.Location = if (i < e.spans.len) .{ .file = e.file, .span = e.spans[i] } else null;
            try ad.declared(n, .enum_member, e.self_type, at, 0);
        }
    }

    fn fields(ad: *Adder, t: Type, given: []const []const u8) Allocator.Error!void {
        const s = ad.a.pool().structOf(t) orelse return;
        for (s.fields.items) |fd| {
            if (fd.is_signal) continue;
            const set = for (given) |g| {
                if (std.mem.eql(u8, g, fd.name)) break true;
            } else false;
            if (!set) try ad.declared(fd.name, .field, fd.type, .{ .file = fd.file, .span = fd.span }, 0);
        }
    }

    fn moduleTypes(ad: *Adder, t: Type) Allocator.Error!void {
        const p = ad.a.pool();
        const m = p.moduleOf(t) orelse return;
        for (m.exports.keys(), m.exports.values()) |n, ex| {
            const inner = p.metaOf(ex.type) orelse continue;
            const kind: Kind = if (p.enumOf(inner) != null) .@"enum" else .@"struct";
            const at: ?diag.Location = if (m.globals.get(n)) |g| .{ .file = m.object.file, .span = g.span } else null;
            try ad.declared(n, kind, ex.type, at, 0);
        }
    }

    fn fallback(ad: *Adder) Allocator.Error!void {
        for (ad.a.recorder.decls.items) |d| {
            if (d.at.file == ad.a.file and d.parent == null and d.kind != .@"test") try ad.push(d.name, .of(d.kind), d.detail, d.doc, 1);
        }
        for (docs.prelude) |e| try ad.push(e.name, .builtin_function, e.sig, e.doc, 2);
        try ad.keywords();
    }
};

// ---------------------------------------------------------------------------
// Signature help

pub const Signature = struct {
    /// The signature as shown: `heal(amount: int, crit: bool = false) bool`.
    label: []const u8,
    /// Where each parameter is in `label`, as byte offsets.
    params: []const [2]u32,
    /// The parameter the cursor is at.
    active: u32,
    doc: ?[]const u8 = null,
};

/// The signature of the call whose arguments `offset` is among.
pub fn signatureHelp(gpa: Allocator, arena: Allocator, name: []const u8, source: []const u8, offset: u32, options: service.Options) service.Error!?Signature {
    const site = (try cursor.call(gpa, source, offset)) orelse return null;
    const text = try cursor.rewriteForCall(gpa, source, offset);
    defer gpa.free(text);
    const a = try Analysis.create(gpa, name, text, options, true);
    defer a.deinit();
    const call = for (a.recorder.calls.items) |c| {
        if (c.callee_end == site.callee_end) break c;
    } else return null;

    var label: Writer.Allocating = .init(arena);
    var doc: ?[]const u8 = null;
    const use = a.useStarting(call.name.start);
    (blk: {
        const w = &label.writer;
        if (use) |u| if (a.declOf(u.*)) |d| {
            doc = d.doc;
            break :blk writeWithoutSelf(w, d.detail, call.skip_self);
        };
        if (use) |u| if (a.builtin(u.*)) |e| {
            doc = e.doc;
            break :blk a.writeBuiltinSig(w, u.owner, e.sig);
        };
        const sig = call.sig orelse break :blk;
        const callee = a.textOf(call.name);
        var out: Writer.Allocating = .init(arena);
        a.writeSignature(&out.writer, callee, sig, call.skip_self) catch |e| break :blk e;
        break :blk w.writeAll(out.written()["fn ".len..]);
    }) catch return error.OutOfMemory;
    if (label.written().len == 0) return null;
    const params = try paramsOf(arena, label.written());
    const variadic = std.mem.indexOf(u8, label.written(), "...)") != null;
    const last: u32 = @intCast(@max(params.len, 1) - 1);
    return .{
        .label = label.written(),
        .params = params,
        .active = if (variadic) @min(site.arg, last) else if (site.arg > last and params.len > 0) last + 1 else site.arg,
        .doc = if (doc) |d| try arena.dupe(u8, d) else null,
    };
}

/// A declaration's text as a call's signature: without its `fn `, and
/// without the `self` a method called on a value is given already.
fn writeWithoutSelf(w: *Writer, detail: []const u8, skip_self: bool) Writer.Error!void {
    const text = if (std.mem.startsWith(u8, detail, "fn ")) detail[3..] else detail;
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return w.writeAll(text);
    try w.writeAll(text[0 .. open + 1]);
    var rest = text[open + 1 ..];
    if (skip_self and std.mem.startsWith(u8, rest, "self")) {
        rest = rest["self".len..];
        if (std.mem.startsWith(u8, rest, ", ")) rest = rest[2..];
    }
    try w.writeAll(rest);
}

/// Where each parameter is in a signature: between its parentheses, split
/// at the commas not inside brackets or strings.
fn paramsOf(arena: Allocator, label: []const u8) Allocator.Error![]const [2]u32 {
    var list: std.ArrayList([2]u32) = .empty;
    const open = std.mem.indexOfScalar(u8, label, '(') orelse return list.items;
    var depth: usize = 0;
    var start = open + 1;
    var i = start;
    while (i < label.len) : (i += 1) {
        switch (label[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth == 0) {
                    try addParam(arena, &list, label, start, i);
                    break;
                }
                depth -= 1;
            },
            '"' => {
                i += 1;
                while (i < label.len and label[i] != '"') : (i += 1) {}
            },
            ',' => if (depth == 0) {
                try addParam(arena, &list, label, start, i);
                start = i + 1;
            },
            else => {},
        }
    }
    return list.items;
}

fn addParam(arena: Allocator, list: *std.ArrayList([2]u32), label: []const u8, from: usize, to: usize) Allocator.Error!void {
    var s = from;
    var e = to;
    while (s < e and label[s] == ' ') s += 1;
    while (e > s and label[e - 1] == ' ') e -= 1;
    if (e > s) try list.append(arena, .{ @intCast(s), @intCast(e) });
}

test "a signature's parameters are found in its text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const label = "pad_start(width: int, fill: string = \", \") string";
    const params = try paramsOf(arena.allocator(), label);
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("width: int", label[params[0][0]..params[0][1]]);
    try std.testing.expectEqualStrings("fill: string = \", \"", label[params[1][0]..params[1][1]]);
    try std.testing.expectEqual(@as(usize, 0), (try paramsOf(arena.allocator(), "pop() ?T")).len);
}
