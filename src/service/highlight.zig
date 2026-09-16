// SPDX-License-Identifier: BSD-2-Clause

//! How to colour a file: its tokens, read again, each name coloured by
//! what the compiler found it to name - a field, a parameter, a signal -
//! and what the compiler never reached, such as a line that does not
//! parse, by its look. Comments come from between the tokens, and an
//! f-string's expressions are coloured as the code they are.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("../diag.zig");
const lex = @import("../syntax/lex.zig");
const strings = @import("../syntax/strings.zig");
const token = @import("../syntax/token.zig");
const Recorder = @import("../compile/Recorder.zig");
const Analysis = @import("Analysis.zig");

/// In the order of the Language Server Protocol's legend, which `flux
/// lsp` sends as it is.
pub const TokenType = enum(u8) {
    namespace,
    type,
    @"struct",
    @"enum",
    parameter,
    variable,
    property,
    enum_member,
    event,
    function,
    method,
    keyword,
    comment,
    string,
    number,
    operator,
    decorator,
};

pub const Modifiers = packed struct(u8) {
    declaration: bool = false,
    readonly: bool = false,
    default_library: bool = false,
    documentation: bool = false,
    _: u4 = 0,
};

pub const Token = struct {
    start: u32,
    len: u32,
    type: TokenType,
    modifiers: Modifiers = .{},
};

const builtin_types = [_][]const u8{ "int", "float", "bool", "string", "void", "any", "vec2", "vec3", "color", "task", "signal" };

/// Every token of the file worth a colour, in order; none crosses a line.
pub fn tokens(a: *const Analysis, arena: Allocator) Allocator.Error![]const Token {
    var out: std.ArrayList(Token) = .empty;
    try run(a, arena, &out, 0, a.source.len);
    return out.items;
}

fn run(a: *const Analysis, arena: Allocator, out: *std.ArrayList(Token), start: usize, end: usize) Allocator.Error!void {
    const source = a.source;
    var sink: diag.Diagnostics = .init(a.gpa);
    defer sink.deinit();
    const list = try lex.tokenizeRange(a.gpa, source, start, end, .none, &sink);
    defer a.gpa.free(list);
    var gap: usize = start;
    for (list, 0..) |t, i| {
        try comments(arena, out, source, gap, t.start);
        gap = t.end;
        const kind: ?TokenType = switch (t.kind) {
            .eof => break,
            .identifier => {
                try out.append(arena, name(a, list, i));
                continue;
            },
            .int, .float => .number,
            .string, .char, .multiline_string => .string,
            .fstring => {
                try fstring(a, arena, out, t);
                continue;
            },
            .builtin => .decorator,
            .invalid, .l_paren, .r_paren, .l_brace, .r_brace, .l_bracket, .r_bracket, .comma, .semicolon, .colon, .dot => null,
            else => if (t.kind.isKeyword()) .keyword else .operator,
        };
        if (kind) |k| try out.append(arena, .{ .start = t.start, .len = t.end - t.start, .type = k });
    }
}

/// A name, by what it names, or failing that by its look.
fn name(a: *const Analysis, list: []const token.Token, i: usize) Token {
    const t = list[i];
    var result: Token = .{ .start = t.start, .len = t.end - t.start, .type = .variable };
    if (a.useStarting(t.start)) |u| {
        result.modifiers.declaration = u.is_decl;
        result.type = switch (u.kind) {
            .variable, .constant => blk: {
                result.modifiers.readonly = !u.mutable;
                break :blk if (a.pool().signatureOf(u.type) != null) .function else .variable;
            },
            .parameter => .parameter,
            .function, .@"test" => .function,
            .method => .method,
            .field => .property,
            .signal => .event,
            .@"struct" => .@"struct",
            .@"enum" => .@"enum",
            .enum_member => .enum_member,
            .module => .namespace,
            .builtin_function => .function,
            .builtin_type => .type,
            .builtin_method => .method,
            .property => .property,
        };
        result.modifiers.default_library = switch (u.kind) {
            .builtin_function, .builtin_type, .builtin_method, .property => true,
            else => false,
        };
        return result;
    }
    const text = a.source[t.start..t.end];
    const prev: token.Kind = if (i > 0) list[i - 1].kind else .eof;
    const next: token.Kind = if (i + 1 < list.len) list[i + 1].kind else .eof;
    if (prev == .dot and i >= 2 and list[i - 2].kind == .kw_error) {
        result.type = .enum_member;
    } else if (next == .l_paren) {
        result.type = if (prev == .dot) .method else .function;
    } else if (prev == .dot) {
        result.type = .property;
    } else if (for (builtin_types) |b| {
        if (std.mem.eql(u8, b, text)) break true;
    } else false) {
        result.type = .type;
        result.modifiers.default_library = true;
    } else if (std.ascii.isUpper(text[0])) {
        result.type = .@"struct";
    }
    return result;
}

/// An f-string: its text as a string, its expressions as code.
fn fstring(a: *const Analysis, arena: Allocator, out: *std.ArrayList(Token), t: token.Token) Allocator.Error!void {
    const source = a.source;
    const quote_closed = t.end - t.start >= 3 and source[t.end - 1] == '"';
    const base: usize = t.start + 2;
    const raw = source[base..if (quote_closed) t.end - 1 else t.end];
    var text_from: usize = t.start;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '\\' => i += 1,
            '{' => {
                if (i + 1 < raw.len and raw[i + 1] == '{') {
                    i += 1;
                    continue;
                }
                const hole = strings.hole(raw, i + 1) orelse break;
                const expr_end = base + (hole.colon orelse hole.close);
                try out.append(arena, .{ .start = @intCast(text_from), .len = @intCast(base + i + 1 - text_from), .type = .string });
                try run(a, arena, out, base + i + 1, expr_end);
                text_from = expr_end;
                i = hole.close;
            },
            else => {},
        }
    }
    if (t.end > text_from) try out.append(arena, .{ .start = @intCast(text_from), .len = @intCast(t.end - text_from), .type = .string });
}

/// The comments between two tokens, each line of them a token of its own.
fn comments(arena: Allocator, out: *std.ArrayList(Token), source: []const u8, from: usize, to: usize) Allocator.Error!void {
    var i = from;
    while (i + 1 < to) {
        if (source[i] == '/' and source[i + 1] == '/') {
            const start = i;
            while (i < to and source[i] != '\n') i += 1;
            var end = i;
            if (end > start and source[end - 1] == '\r') end -= 1;
            const doc = end - start >= 3 and source[start + 2] == '/';
            try out.append(arena, .{ .start = @intCast(start), .len = @intCast(end - start), .type = .comment, .modifiers = .{ .documentation = doc } });
        } else if (source[i] == '/' and source[i + 1] == '*') {
            // To its `*/`, or to the end of the gap when it is never closed.
            const end = if (std.mem.indexOfPos(u8, source[0..to], i + 2, "*/")) |close| close + 2 else to;
            var line_start = i;
            for (i..end) |j| if (source[j] == '\n') {
                var e = j;
                if (e > line_start and source[e - 1] == '\r') e -= 1;
                if (e > line_start) try out.append(arena, .{ .start = @intCast(line_start), .len = @intCast(e - line_start), .type = .comment });
                line_start = j + 1;
            };
            if (end > line_start) try out.append(arena, .{ .start = @intCast(line_start), .len = @intCast(end - line_start), .type = .comment });
            i = end;
        } else i += 1;
    }
}
