// SPDX-License-Identifier: BSD-2-Clause

//! The code at the cursor, read as tokens: the word a completion replaces,
//! what comes before it, the call whose arguments the cursor is among. And
//! the source rewritten for the compiler, with `Recorder.placeholder` where
//! the word is and the brackets the line leaves open closed after it, so
//! that code still being typed compiles far enough to be asked about.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("../diag.zig");
const lex = @import("../syntax/lex.zig");
const strings = @import("../syntax/strings.zig");
const token = @import("../syntax/token.zig");
const Token = token.Token;
const Recorder = @import("../compile/Recorder.zig");

pub const Kind = enum {
    /// Nothing to offer: in a comment, a string or a number, or where a
    /// name is being declared.
    none,
    /// A name on its own.
    name,
    /// After `value.`.
    member,
    /// A `.name` with nothing before the dot: an enum's member, or a field
    /// in a struct literal.
    dot,
    /// `@name`, or a `@` alone.
    builtin,
    /// A method's name being written in a struct's body, after `fn`.
    method_name,
    /// A word where a struct's member starts: `fn`, `var`, a method the
    /// host calls.
    struct_member,
};

pub const Context = struct {
    kind: Kind,
    /// The word at the cursor, which a completion replaces.
    start: u32,
    end: u32,
    /// A `.name` inside `Type{ ... }`.
    struct_field: bool = false,
    /// For `method_name`, where its `fn` starts: what a whole method written
    /// in its place replaces from.
    decl_start: u32 = 0,
};

fn tokenize(gpa: Allocator, source: []const u8, start: usize, end: usize) Allocator.Error![]Token {
    var sink: diag.Diagnostics = .init(gpa);
    defer sink.deinit();
    return lex.tokenizeRange(gpa, source, start, end, .none, &sink);
}

fn isWord(kind: token.Kind) bool {
    return kind == .identifier or kind.isKeyword();
}

/// Whether a token can end a value, so that a `.` after it reads a member.
fn endsValue(kind: token.Kind) bool {
    return switch (kind) {
        .identifier, .r_paren, .r_bracket, .r_brace, .kw_self, .string, .fstring, .multiline_string, .char, .int, .float, .question => true,
        else => false,
    };
}

/// Whether `source[from..to]` ends inside a comment.
fn inComment(source: []const u8, from: usize, to: usize) bool {
    var i = from;
    var line = false;
    var block = false;
    while (i < to) : (i += 1) {
        if (line) {
            if (source[i] == '\n') line = false;
        } else if (block) {
            if (source[i] == '*' and i + 1 < source.len and source[i + 1] == '/') {
                block = false;
                i += 1;
            }
        } else if (source[i] == '/' and i + 1 < to) {
            if (source[i + 1] == '/') line = true else if (source[i + 1] == '*') block = true;
            if (line or block) i += 1;
        }
    }
    return line or block;
}

fn closed(source: []const u8, t: Token) bool {
    const quote = source[t.start];
    return t.end - t.start >= 2 and source[t.end - 1] == (if (quote == 'f') '"' else quote);
}

/// What the cursor is in.
pub fn at(gpa: Allocator, source: []const u8, offset: u32) Allocator.Error!Context {
    const cursor: u32 = @min(offset, @as(u32, @intCast(source.len)));
    const tokens = try tokenize(gpa, source, 0, source.len);
    defer gpa.free(tokens);
    // The expressions in an f-string's braces are code of their own.
    for (tokens) |t| {
        if (t.start >= cursor) break;
        if (t.kind != .fstring or (cursor >= t.end and closed(source, t))) continue;
        const hole = holeAt(source, t, cursor) orelse return .{ .kind = .none, .start = cursor, .end = cursor };
        const inner = try tokenize(gpa, source, hole.start, hole.end);
        defer gpa.free(inner);
        return within(source, inner, cursor);
    }
    return within(source, tokens, cursor);
}

const Range = struct { start: usize, end: usize };

/// The expression of the f-string `t` that the cursor is in, if it is in one.
fn holeAt(source: []const u8, t: Token, cursor: u32) ?Range {
    const base: usize = t.start + 2;
    const raw = source[base..if (closed(source, t)) t.end - 1 else t.end];
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '\\' => i += 1,
            '{' => {
                if (i + 1 < raw.len and raw[i + 1] == '{') {
                    i += 1;
                    continue;
                }
                const found = strings.hole(raw, i + 1);
                const end = if (found) |h| h.colon orelse h.close else raw.len;
                if (cursor >= base + i + 1 and cursor <= base + end) return .{ .start = base + i + 1, .end = base + end };
                i = if (found) |h| h.close else raw.len;
            },
            else => {},
        }
    }
    return null;
}

fn within(source: []const u8, tokens: []const Token, cursor: u32) Context {
    const none: Context = .{ .kind = .none, .start = cursor, .end = cursor };
    // The first token that does not end before the cursor.
    var k: usize = 0;
    while (k + 1 < tokens.len and tokens[k].end < cursor) k += 1;
    const t = tokens[k];
    const inside = t.start < cursor and cursor <= t.end;
    // A `@` with nothing after it yet.
    if (t.kind == .invalid and t.end == cursor and t.end == t.start + 1 and source[t.start] == '@') return .{ .kind = .builtin, .start = cursor, .end = cursor };
    if (inside) switch (t.kind) {
        .string, .char, .multiline_string, .fstring => if (cursor < t.end or t.kind == .multiline_string or !closed(source, t)) return none,
        .int, .float => return none,
        .builtin => return .{ .kind = .builtin, .start = t.start + 1, .end = t.end },
        else => {},
    };
    var word: ?usize = null;
    if (inside and isWord(t.kind)) {
        word = k;
    } else if (t.start == cursor and isWord(t.kind)) {
        word = k;
    } else if (t.end == cursor and k + 1 < tokens.len and tokens[k + 1].start == cursor and isWord(tokens[k + 1].kind)) {
        word = k + 1;
    }
    var ctx: Context = if (word) |w| .{ .kind = .name, .start = tokens[w].start, .end = tokens[w].end } else .{ .kind = .name, .start = cursor, .end = cursor };
    // The last token before the word, or before the cursor.
    const before: ?usize = if (word) |w| (if (w > 0) w - 1 else null) else blk: {
        var i = k + 1;
        while (i > 0) {
            i -= 1;
            if (tokens[i].end <= cursor and tokens[i].kind != .eof) break :blk i;
        }
        break :blk null;
    };
    const gap_from: usize = if (before) |b| tokens[b].end else 0;
    if (word == null and !inside and inComment(source, gap_from, cursor)) return none;
    const b = before orelse return ctx;
    const kind_before = tokens[b].kind;
    switch (kind_before) {
        .dot => {
            if (b > 0 and endsValue(tokens[b - 1].kind)) {
                ctx.kind = .member;
            } else if (b > 0 and tokens[b - 1].kind == .kw_error) {
                return none;
            } else {
                ctx.kind = .dot;
                ctx.struct_field = structField(tokens, b);
            }
        },
        .kw_fn => {
            if (!inStructBody(tokens, b)) return none;
            ctx.kind = .method_name;
            ctx.decl_start = tokens[b].start;
        },
        .kw_var, .kw_const, .kw_struct, .kw_enum, .kw_signal, .kw_test => return none,
        .l_brace, .r_brace, .semicolon => if (inStructBody(tokens, b + 1)) {
            ctx.kind = .struct_member;
        },
        .pipe => if (b == 0 or !endsValue(tokens[b - 1].kind) or tokens[b - 1].kind == .r_paren) return none,
        .comma, .l_paren => {
            if (kind_before == .comma and b >= 2 and tokens[b - 1].kind == .identifier and tokens[b - 2].kind == .pipe) return none;
            if (inParameters(tokens, b)) return none;
        },
        else => {},
    }
    return ctx;
}

/// The innermost bracket still open before `tokens[end]`.
fn opener(tokens: []const Token, end: usize) ?usize {
    var depth: usize = 0;
    var i = end;
    while (i > 0) {
        i -= 1;
        switch (tokens[i].kind) {
            .r_paren, .r_bracket, .r_brace => depth += 1,
            .l_paren, .l_bracket, .l_brace => {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

/// Whether `tokens[index]` is directly in a struct's body, where its members
/// are declared.
fn inStructBody(tokens: []const Token, index: usize) bool {
    const o = opener(tokens, index) orelse return false;
    return tokens[o].kind == .l_brace and structHeader(tokens, o);
}

/// Whether the `{` at `o` opens a struct: `struct Name {`, `struct Name
/// extends Base {`.
fn structHeader(tokens: []const Token, o: usize) bool {
    if (o >= 2 and tokens[o - 1].kind == .identifier and tokens[o - 2].kind == .kw_struct) return true;
    return o >= 4 and tokens[o - 1].kind == .identifier and tokens[o - 2].kind == .kw_extends and
        tokens[o - 3].kind == .identifier and tokens[o - 4].kind == .kw_struct;
}

/// The names of the methods of the struct whose body `offset` is in,
/// made in `arena`.
pub fn structMethods(gpa: Allocator, arena: Allocator, source: []const u8, offset: u32) Allocator.Error![]const []const u8 {
    const tokens = try tokenize(gpa, source, 0, source.len);
    defer gpa.free(tokens);
    var k: usize = 0;
    while (k + 1 < tokens.len and tokens[k].end < offset) k += 1;
    var names: std.ArrayList([]const u8) = .empty;
    const o = opener(tokens, k) orelse return names.items;
    if (tokens[o].kind != .l_brace or !structHeader(tokens, o)) return names.items;
    var depth: usize = 0;
    var i = o + 1;
    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].kind) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => {
                if (depth == 0) break;
                depth -= 1;
            },
            .kw_fn => if (depth == 0 and i + 1 < tokens.len and tokens[i + 1].kind == .identifier) {
                try names.append(arena, source[tokens[i + 1].start..tokens[i + 1].end]);
            },
            .eof => break,
            else => {},
        }
    }
    return names.items;
}

/// Whether the `.` at `dot` starts a field of a struct literal:
/// `Player{ .hp = 1, .name = "x" }`.
fn structField(tokens: []const Token, dot: usize) bool {
    if (dot == 0 or (tokens[dot - 1].kind != .l_brace and tokens[dot - 1].kind != .comma)) return false;
    const o = opener(tokens, dot) orelse return false;
    return tokens[o].kind == .l_brace and o > 0 and tokens[o - 1].kind == .identifier;
}

/// Whether `tokens[b]`, a `(` or a `,`, is in a function's parameters,
/// where what follows is a name being declared.
fn inParameters(tokens: []const Token, b: usize) bool {
    const o = if (tokens[b].kind == .l_paren) b else opener(tokens, b) orelse return false;
    if (tokens[o].kind != .l_paren or o == 0) return false;
    if (tokens[o - 1].kind == .kw_fn) return true;
    return o >= 2 and tokens[o - 1].kind == .identifier and tokens[o - 2].kind == .kw_fn;
}

// ---------------------------------------------------------------------------
// Calls

pub const Call = struct {
    /// Where the callee ends: `(` follows.
    callee_end: u32,
    /// The argument the cursor is in, counted from 0.
    arg: u32,
};

/// The call whose arguments the cursor is among: the innermost `(` still
/// open before it, after a name or a bracket closed.
pub fn call(gpa: Allocator, source: []const u8, offset: u32) Allocator.Error!?Call {
    const cursor: u32 = @min(offset, @as(u32, @intCast(source.len)));
    const tokens = try tokenize(gpa, source, 0, source.len);
    defer gpa.free(tokens);
    var i: usize = 0;
    while (i < tokens.len and tokens[i].kind != .eof and tokens[i].end <= cursor) i += 1;
    if (i < tokens.len and tokens[i].start < cursor and (tokens[i].kind == .string or tokens[i].kind == .fstring)) return null;
    var depth: usize = 0;
    var commas: u32 = 0;
    while (i > 0) {
        i -= 1;
        switch (tokens[i].kind) {
            .r_paren, .r_bracket, .r_brace => depth += 1,
            .l_bracket => if (depth == 0) {
                // Inside a list among the arguments: its commas are its own.
                commas = 0;
            } else {
                depth -= 1;
            },
            .l_brace => if (depth == 0) {
                // A struct literal among the arguments is part of one; a
                // block is code of its own.
                if (i == 0 or tokens[i - 1].kind != .identifier) return null;
                commas = 0;
            } else {
                depth -= 1;
            },
            .l_paren => if (depth == 0) {
                if (i == 0) return null;
                const callee = tokens[i - 1];
                switch (callee.kind) {
                    .identifier, .r_paren, .r_bracket => {},
                    else => return null,
                }
                if (callee.kind == .identifier and i >= 2 and tokens[i - 2].kind == .kw_fn) return null;
                return .{ .callee_end = callee.end, .arg = commas };
            } else {
                depth -= 1;
            },
            .comma => if (depth == 0) {
                commas += 1;
            },
            .semicolon => if (depth == 0) return null,
            else => {},
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Strings a host knows the values of

/// A string being typed as a whole argument of a call - `app.actionDown("ju`
/// - and the call: what a host offers the names of its own things for.
pub const StringArgument = struct {
    /// The name called: `actionDown`.
    callee: []const u8,
    /// The name before its `.`, when there is one: `app`.
    receiver: ?[]const u8,
    /// Which argument, counted from 0.
    arg: u32,
    /// The text inside the quotes, which a completion replaces.
    start: u32,
    end: u32,
};

/// The string argument the cursor is inside the quotes of, if it is in one:
/// a `"..."` on its own between a call's `(` or `,` and its `,` or `)`, the
/// closing quote typed or not yet. What it holds points into `source`.
pub fn stringArgument(gpa: Allocator, source: []const u8, offset: u32) Allocator.Error!?StringArgument {
    const cursor: u32 = @min(offset, @as(u32, @intCast(source.len)));
    const tokens = try tokenize(gpa, source, 0, source.len);
    defer gpa.free(tokens);
    var k: usize = 0;
    while (k + 1 < tokens.len and tokens[k].kind != .eof and tokens[k].end < cursor) k += 1;
    const t = tokens[k];
    if (t.kind != .string or source[t.start] != '"' or k == 0) return null;
    const is_closed = closed(source, t);
    if (cursor <= t.start or (is_closed and cursor >= t.end)) return null;
    switch (tokens[k - 1].kind) {
        .l_paren, .comma => {},
        else => return null,
    }
    // After it, the call goes on or ends - or the line does, where the rest
    // of the call is not typed yet.
    if (is_closed and k + 1 < tokens.len) switch (tokens[k + 1].kind) {
        .r_paren, .comma, .eof => {},
        else => if (std.mem.indexOfScalar(u8, source[t.end..tokens[k + 1].start], '\n') == null) return null,
    };
    const site = (try call(gpa, source, t.start)) orelse return null;
    var c = k;
    while (c > 0 and tokens[c].end != site.callee_end) c -= 1;
    if (tokens[c].end != site.callee_end or tokens[c].kind != .identifier) return null;
    const receiver: ?[]const u8 = if (c >= 2 and tokens[c - 1].kind == .dot and tokens[c - 2].kind == .identifier)
        source[tokens[c - 2].start..tokens[c - 2].end]
    else
        null;
    return .{
        .callee = source[tokens[c].start..tokens[c].end],
        .receiver = receiver,
        .arg = site.arg,
        .start = t.start + 1,
        .end = if (is_closed) t.end - 1 else t.end,
    };
}

test "a string typed as a whole argument says whose call it is, and which argument" {
    const gpa = std.testing.allocator;
    const Case = struct { source: []const u8, callee: ?[]const u8 = null, receiver: ?[]const u8 = null, arg: u32 = 0 };
    for ([_]Case{
        .{ .source = "app.actionDown(\"ju$\")", .callee = "actionDown", .receiver = "app" },
        .{ .source = "app.actionAxis(\"left\", \"ri$", .callee = "actionAxis", .receiver = "app", .arg = 1 },
        .{ .source = "look(\"$\")", .callee = "look" },
        // Part of a longer expression, or no call's at all, it is nobody's.
        .{ .source = "app.actionDown(\"a\" + \"$\")" },
        .{ .source = "var name = \"ju$\";" },
        // Outside the quotes.
        .{ .source = "app.actionDown(\"jump\"$)" },
    }) |case| {
        const where = std.mem.indexOfScalar(u8, case.source, '$').?;
        const source = try std.mem.concat(gpa, u8, &.{ case.source[0..where], case.source[where + 1 ..] });
        defer gpa.free(source);
        const found = try stringArgument(gpa, source, @intCast(where));
        if (case.callee) |callee| {
            try std.testing.expectEqualStrings(callee, found.?.callee);
            if (case.receiver) |receiver| try std.testing.expectEqualStrings(receiver, found.?.receiver.?) else try std.testing.expect(found.?.receiver == null);
            try std.testing.expectEqual(case.arg, found.?.arg);
        } else try std.testing.expect(found == null);
    }
}

// ---------------------------------------------------------------------------
// The source for the compiler

/// The source with the placeholder where the word at the cursor is, and
/// what the line leaves open closed after it.
pub fn rewrite(gpa: Allocator, source: []const u8, ctx: Context) Allocator.Error![]u8 {
    return rewriteWith(gpa, source, ctx.start, ctx.end, true, ctx.struct_field);
}

/// The source for asking about the call at `offset`: what the line leaves
/// open closed, and the placeholder only where, without one, the argument
/// being typed would not parse - after a `.` or an operator.
pub fn rewriteForCall(gpa: Allocator, source: []const u8, offset: u32) Allocator.Error![]u8 {
    const ctx = try at(gpa, source, offset);
    const cursor: u32 = @min(offset, @as(u32, @intCast(source.len)));
    const tokens = try tokenize(gpa, source, 0, cursor);
    defer gpa.free(tokens);
    var needs = false;
    if (ctx.start == ctx.end) {
        // The last token before the cursor, the `eof` aside.
        const last: ?Token = if (tokens.len >= 2) tokens[tokens.len - 2] else null;
        if (last) |t| needs = !(t.kind == .l_paren or t.kind == .comma or endsValue(t.kind));
    }
    return rewriteWith(gpa, source, if (needs) cursor else ctx.start, if (needs) cursor else ctx.end, needs, false);
}

fn rewriteWith(gpa: Allocator, source: []const u8, start: u32, end: u32, placeholder: bool, struct_field: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, source.len + Recorder.placeholder.len + 16);
    out.appendSliceAssumeCapacity(source[0..start]);
    if (placeholder) {
        out.appendSliceAssumeCapacity(Recorder.placeholder);
        if (struct_field and !followedByAssign(source, end)) try out.appendSlice(gpa, " = 0");
    }
    try closers(gpa, source, start, end, &out);
    try out.appendSlice(gpa, source[end..]);
    return out.toOwnedSlice(gpa);
}

fn followedByAssign(source: []const u8, from: usize) bool {
    var i = from;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
    return i < source.len and source[i] == '=' and (i + 1 == source.len or source[i + 1] != '=');
}

/// The `)` and `]` the statement leaves open before the word, when nothing
/// follows it on its line and nothing after closes them: `foo(a, b` typed
/// so far, with the line not yet finished.
fn closers(gpa: Allocator, source: []const u8, start: u32, end: u32, out: *std.ArrayList(u8)) Allocator.Error!void {
    var i: usize = end;
    while (i < source.len and source[i] != '\n') : (i += 1) {
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '/') break;
        if (source[i] != ' ' and source[i] != '\t' and source[i] != '\r') return;
    }
    const tokens = try tokenize(gpa, source, 0, source.len);
    defer gpa.free(tokens);
    // The brackets open before the word, back to its statement's start.
    var open: [32]u8 = undefined;
    var count: usize = 0;
    var k: usize = 0;
    while (k < tokens.len and tokens[k].end <= start and tokens[k].kind != .eof) k += 1;
    var depth: usize = 0;
    var j = k;
    back: while (j > 0) {
        j -= 1;
        switch (tokens[j].kind) {
            .r_paren, .r_bracket => depth += 1,
            .l_paren, .l_bracket => if (depth == 0) {
                if (count == open.len) break :back;
                open[count] = if (tokens[j].kind == .l_paren) ')' else ']';
                count += 1;
            } else {
                depth -= 1;
            },
            .semicolon, .l_brace, .r_brace => if (depth == 0) break :back,
            else => {},
        }
    }
    if (count == 0) return;
    // Those closed after the word, before its statement ends, need nothing.
    var f = k;
    while (f < tokens.len and tokens[f].start < end) f += 1;
    depth = 0;
    var pending = count;
    forward: while (f < tokens.len and pending > 0) : (f += 1) {
        const t = tokens[f];
        switch (t.kind) {
            .eof, .semicolon, .l_brace, .r_brace => if (depth == 0) break :forward,
            .l_paren, .l_bracket => depth += 1,
            .r_paren, .r_bracket => if (depth > 0) {
                depth -= 1;
            } else {
                pending -= 1;
            },
            .kw_var, .kw_const, .kw_fn, .kw_if, .kw_while, .kw_for, .kw_return, .kw_struct, .kw_enum => if (depth == 0 and lineStart(source, t.start)) break :forward,
            else => {},
        }
    }
    // `open` runs innermost first, which is the order they close in.
    for (open[0..pending]) |closer| try out.append(gpa, closer);
}

fn lineStart(source: []const u8, at_offset: u32) bool {
    var i: usize = at_offset;
    while (i > 0) {
        i -= 1;
        switch (source[i]) {
            '\n' => return true,
            ' ', '\t', '\r' => {},
            else => return false,
        }
    }
    return true;
}

const testing = std.testing;

/// `$` marks the cursor.
fn expectContext(source_with_cursor: []const u8, kind: Kind, word: []const u8) !void {
    const cursor = std.mem.indexOfScalar(u8, source_with_cursor, '$').?;
    var buf: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(&buf, "{s}{s}", .{ source_with_cursor[0..cursor], source_with_cursor[cursor + 1 ..] });
    const ctx = try at(testing.allocator, source, @intCast(cursor));
    testing.expectEqual(kind, ctx.kind) catch |e| {
        std.debug.print("in `{s}`\n", .{source_with_cursor});
        return e;
    };
    try testing.expectEqualStrings(word, source[ctx.start..ctx.end]);
}

test "what the cursor is in" {
    try expectContext("player.he$", .member, "he");
    try expectContext("player.$", .member, "");
    try expectContext("foo(bar).$x", .member, "x");
    try expectContext("var s: State = .$", .dot, "");
    try expectContext("var p = Player{ .h$ }", .dot, "h");
    try expectContext("pri$", .name, "pri");
    try expectContext("x = $", .name, "");
    try expectContext("// a comment pl$", .none, "");
    try expectContext("var s = \"text $\";", .none, "");
    try expectContext("print(f\"hp {pla$}\");", .name, "pla");
    try expectContext("print(f\"hp {x} $\");", .none, "");
    try expectContext("var na$", .none, "");
    try expectContext("fn heal(amo$", .none, "");
    try expectContext("fn heal(a: in$", .name, "in");
    try expectContext("for (xs) |it$|", .none, "");
    try expectContext("x = a | b$", .name, "b");
    try expectContext("@imp$", .builtin, "imp");
    try expectContext("x = 12$", .none, "");
    try expectContext("return err$or.NotFound;", .name, "error");
    try expectContext("return error.$", .none, "");
}

test "the call the cursor is among" {
    const Case = struct { []const u8, ?u32 };
    const cases = [_]Case{
        .{ "heal(1, $", 1 },
        .{ "heal($)", 0 },
        .{ "heal(a, [1, 2$])", 1 },
        .{ "if ($", null },
        .{ "fn heal(a, $", null },
        .{ "xs.map(|x| { x.$ })", null },
        .{ "heal(Point{ .x = 1, .y = $", 0 },
    };
    for (cases) |case| {
        const cursor = std.mem.indexOfScalar(u8, case[0], '$').?;
        var buf: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(&buf, "{s}{s}", .{ case[0][0..cursor], case[0][cursor + 1 ..] });
        const found = try call(testing.allocator, source, @intCast(cursor));
        testing.expectEqual(case[1], if (found) |c| c.arg else null) catch |e| {
            std.debug.print("in `{s}`\n", .{case[0]});
            return e;
        };
    }
}

test "the line being typed is closed for the compiler" {
    const source = "fn f() {\n    heal(a, pla\n    var x = 1;\n}\n";
    const start: u32 = @intCast(std.mem.indexOf(u8, source, "pla").?);
    const out = try rewrite(testing.allocator, source, .{ .kind = .name, .start = start, .end = start + 3 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("fn f() {\n    heal(a, " ++ Recorder.placeholder ++ ")\n    var x = 1;\n}\n", out);

    const closed_later = "heal(a,\n    pla\n);\n";
    const s2: u32 = @intCast(std.mem.indexOf(u8, closed_later, "pla").?);
    const out2 = try rewrite(testing.allocator, closed_later, .{ .kind = .name, .start = s2, .end = s2 + 3 });
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("heal(a,\n    " ++ Recorder.placeholder ++ "\n);\n", out2);
}
