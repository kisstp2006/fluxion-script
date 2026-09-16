// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("fluxion_text");

const diag = @import("../diag.zig");
const token = @import("token.zig");
const Token = token.Token;
const Kind = token.Kind;

const Lexer = struct {
    source: []const u8,
    cursor: text.Parser,
    file: diag.FileId,
    diags: *diag.Diagnostics,
    tokens: std.ArrayList(Token) = .empty,
    gpa: Allocator,

    fn report(lx: *Lexer, start: usize, end: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!diag.Diagnostics.Handle {
        return lx.diags.err(.{ .file = lx.file, .span = .{ .start = @intCast(start), .end = @intCast(end) } }, fmt, args);
    }

    fn push(lx: *Lexer, kind: Kind, start: usize) Allocator.Error!void {
        try lx.tokens.append(lx.gpa, .{ .kind = kind, .start = @intCast(start), .end = @intCast(lx.cursor.index) });
    }
};

/// Every token of `source`, ending in one `eof`. Mistakes are reported and
/// lexing carries on, so the parser sees the rest of the file.
pub fn tokenize(gpa: Allocator, source: []const u8, file: diag.FileId, diags: *diag.Diagnostics) Allocator.Error![]Token {
    return tokenizeRange(gpa, source, 0, source.len, file, diags);
}

/// The tokens of `source[start..end]`, with offsets into the whole of
/// `source`: what an f-string's expressions are read from.
pub fn tokenizeRange(gpa: Allocator, whole: []const u8, start_at: usize, end_at: usize, file: diag.FileId, diags: *diag.Diagnostics) Allocator.Error![]Token {
    const source = whole[0..end_at];
    var lx: Lexer = .{ .source = source, .cursor = .init(source), .file = file, .diags = diags, .gpa = gpa };
    errdefer lx.tokens.deinit(gpa);
    try lx.tokens.ensureTotalCapacity(gpa, (end_at - start_at) / 4 + 16);
    lx.cursor.advance(start_at);
    if (start_at == 0 and std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) lx.cursor.advance(3);

    while (true) {
        try skipTrivia(&lx);
        const start = lx.cursor.index;
        const c = lx.cursor.peek() orelse {
            try lx.push(.eof, start);
            return lx.tokens.toOwnedSlice(gpa);
        };
        switch (c) {
            'a'...'z', 'A'...'Z', '_' => {
                if (c == 'f' and lx.cursor.peekAt(1) == '"') {
                    lx.cursor.advance(1);
                    try fstring(&lx, start);
                    continue;
                }
                const word = lx.cursor.takeIdentifier().?.bytes;
                try lx.push(token.keywords.get(word) orelse .identifier, start);
            },
            '0'...'9' => try number(&lx, start),
            '"' => try string(&lx, start),
            '\'' => try char(&lx, start),
            '@' => {
                lx.cursor.advance(1);
                if (lx.cursor.takeIdentifier() == null) {
                    _ = try (try lx.report(start, start + 1, "`@` must be followed by a name, as in `@export` or `@import`", .{})).text("expected a name after this", .{});
                    try lx.push(.invalid, start);
                } else try lx.push(.builtin, start);
            },
            '\\' => {
                if (lx.cursor.peekAt(1) == '\\') {
                    _ = lx.cursor.takeUntilScalar('\n');
                    var end = lx.cursor.index;
                    if (end > start and source[end - 1] == '\r') end -= 1;
                    try lx.tokens.append(gpa, .{ .kind = .multiline_string, .start = @intCast(start), .end = @intCast(end) });
                } else {
                    lx.cursor.advance(1);
                    _ = try (try lx.report(start, start + 1, "a lone `\\` is not part of anything", .{})).help("a multiline string starts every line with `\\\\`", .{});
                    try lx.push(.invalid, start);
                }
            },
            else => {
                if (c >= 0x80) {
                    const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                    lx.cursor.advance(@min(len, source.len - start));
                    const bytes = source[start..lx.cursor.index];
                    _ = try (try lx.report(start, lx.cursor.index, "`{s}` cannot appear outside a string or a comment", .{bytes}))
                        .note("names are made of ASCII letters, digits and `_`", .{});
                    try lx.push(.invalid, start);
                    continue;
                }
                const kind = operator(&lx.cursor) orelse {
                    lx.cursor.advance(1);
                    if (std.ascii.isPrint(c)) {
                        _ = try lx.report(start, start + 1, "`{c}` is not part of the language", .{c});
                    } else {
                        _ = try lx.report(start, start + 1, "byte 0x{x:0>2} is not part of the language", .{c});
                    }
                    try lx.push(.invalid, start);
                    continue;
                };
                try lx.push(kind, start);
            },
        }
    }
}

fn skipTrivia(lx: *Lexer) Allocator.Error!void {
    while (true) {
        _ = lx.cursor.skipWhitespace();
        if (lx.cursor.checkSlice("//")) {
            _ = lx.cursor.takeUntilScalar('\n');
            continue;
        }
        if (lx.cursor.checkSlice("/*")) {
            const start = lx.cursor.index;
            lx.cursor.advance(2);
            if (lx.cursor.takeUntilSlice("*/") == null) {
                _ = try (try lx.report(start, start + 2, "this comment is never closed", .{})).help("end it with `*/`", .{});
                lx.cursor.advance(lx.source.len - lx.cursor.index);
                return;
            }
            lx.cursor.advance(2);
            continue;
        }
        return;
    }
}

const Op = struct { Kind, usize };

fn withEqual(next: u8, alone: Kind, assign: Kind) Op {
    return if (next == '=') .{ assign, 2 } else .{ alone, 1 };
}

fn wrapping(next: u8, third: u8, alone: Kind, assign: Kind, wrap: Kind, wrap_assign: Kind) Op {
    if (next == '%') return if (third == '=') .{ wrap_assign, 3 } else .{ wrap, 2 };
    return withEqual(next, alone, assign);
}

fn operator(p: *text.Parser) ?Kind {
    const c = p.peek() orelse return null;
    const next = p.peekAt(1) orelse 0;
    const third = p.peekAt(2) orelse 0;
    const kind, const len = switch (c) {
        '(' => Op{ .l_paren, 1 },
        ')' => Op{ .r_paren, 1 },
        '{' => Op{ .l_brace, 1 },
        '}' => Op{ .r_brace, 1 },
        '[' => Op{ .l_bracket, 1 },
        ']' => Op{ .r_bracket, 1 },
        ',' => Op{ .comma, 1 },
        ';' => Op{ .semicolon, 1 },
        ':' => Op{ .colon, 1 },
        '?' => Op{ .question, 1 },
        '~' => Op{ .tilde, 1 },
        '.' => if (next == '.')
            (if (third == '.') Op{ .ellipsis, 3 } else if (third == '=') Op{ .dot_dot_equal, 3 } else Op{ .dot_dot, 2 })
        else
            Op{ .dot, 1 },
        '!' => withEqual(next, .bang, .bang_equal),
        '=' => if (next == '>') Op{ .fat_arrow, 2 } else withEqual(next, .equal, .equal_equal),
        '+' => wrapping(next, third, .plus, .plus_equal, .plus_percent, .plus_percent_equal),
        '-' => wrapping(next, third, .minus, .minus_equal, .minus_percent, .minus_percent_equal),
        '*' => wrapping(next, third, .star, .star_equal, .star_percent, .star_percent_equal),
        '/' => withEqual(next, .slash, .slash_equal),
        '%' => withEqual(next, .percent, .percent_equal),
        '&' => withEqual(next, .ampersand, .ampersand_equal),
        '|' => withEqual(next, .pipe, .pipe_equal),
        '^' => withEqual(next, .caret, .caret_equal),
        '<' => if (next == '<') (if (third == '=') Op{ .shl_equal, 3 } else Op{ .shl, 2 }) else withEqual(next, .less, .less_equal),
        '>' => if (next == '>') (if (third == '=') Op{ .shr_equal, 3 } else Op{ .shr, 2 }) else withEqual(next, .greater, .greater_equal),
        else => return null,
    };
    p.advance(len);
    return kind;
}

fn isDigitIn(c: u8, radix: u8) bool {
    const v = text.number.digitValue(c) orelse return false;
    return v < radix;
}

fn number(lx: *Lexer, start: usize) Allocator.Error!void {
    const p = &lx.cursor;
    var kind: Kind = .int;
    var radix: u8 = 10;
    if (p.peek() == '0') {
        radix = switch (p.peekAt(1) orelse 0) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => 10,
        };
        if (radix != 10) p.advance(2);
    }
    while (p.peek()) |c| {
        if (c == '_' or isDigitIn(c, radix)) p.advance(1) else break;
    }
    if (radix == 10) {
        if (p.peek() == '.' and std.ascii.isDigit(p.peekAt(1) orelse 0)) {
            kind = .float;
            p.advance(1);
            while (p.peek()) |c| {
                if (c == '_' or std.ascii.isDigit(c)) p.advance(1) else break;
            }
        }
        if (p.peek() == 'e' or p.peek() == 'E') {
            const after = p.peekAt(1) orelse 0;
            const digit_at: usize = if (after == '+' or after == '-') 2 else 1;
            if (std.ascii.isDigit(p.peekAt(digit_at) orelse 0)) {
                kind = .float;
                p.advance(digit_at);
                while (p.peek()) |c| {
                    if (std.ascii.isDigit(c)) p.advance(1) else break;
                }
            }
        }
    }
    const tail = p.index;
    while (p.peek()) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') p.advance(1) else break;
    }
    if (p.index != tail) {
        _ = try (try lx.report(start, p.index, "`{s}` is not a number", .{lx.source[start..p.index]}))
            .text("the digits stop being digits here", .{});
    }
    try lx.push(kind, start);
}

fn escape(lx: *Lexer) void {
    lx.cursor.advance(1);
    if (lx.cursor.peek()) |c| {
        if (c != '\n') lx.cursor.advance(1);
    }
}

fn string(lx: *Lexer, start: usize) Allocator.Error!void {
    const p = &lx.cursor;
    p.advance(1);
    while (p.peek()) |c| switch (c) {
        '"' => {
            p.advance(1);
            return lx.push(.string, start);
        },
        '\\' => escape(lx),
        '\n' => break,
        else => p.advance(1),
    };
    try unterminated(lx, start, "string");
    try lx.push(.string, start);
}

fn char(lx: *Lexer, start: usize) Allocator.Error!void {
    const p = &lx.cursor;
    p.advance(1);
    while (p.peek()) |c| switch (c) {
        '\'' => {
            p.advance(1);
            return lx.push(.char, start);
        },
        '\\' => escape(lx),
        '\n' => break,
        else => p.advance(1),
    };
    try unterminated(lx, start, "character");
    try lx.push(.char, start);
}

fn unterminated(lx: *Lexer, start: usize, what: []const u8) Allocator.Error!void {
    var end = lx.cursor.index;
    if (end > start and lx.source[end - 1] == '\r') end -= 1;
    _ = try (try (try lx.report(start, end, "this {s} is never closed", .{what}))
        .text("it runs to the end of the line", .{}))
        .help("a string stays on one line; for several, start each line with `\\\\`", .{});
}

/// `f"hp {self.hp:.1}"`: the braces hold expressions, which may hold strings
/// and braces of their own, so the end is found by counting.
fn fstring(lx: *Lexer, start: usize) Allocator.Error!void {
    const p = &lx.cursor;
    p.advance(1);
    var depth: usize = 0;
    while (p.peek()) |c| {
        if (c == '\n') break;
        if (depth == 0) switch (c) {
            '"' => {
                p.advance(1);
                return lx.push(.fstring, start);
            },
            '\\' => escape(lx),
            '{' => {
                if (p.peekAt(1) == '{') p.advance(2) else {
                    depth = 1;
                    p.advance(1);
                }
            },
            '}' => p.advance(if (p.peekAt(1) == '}') 2 else 1),
            else => p.advance(1),
        } else switch (c) {
            '{' => {
                depth += 1;
                p.advance(1);
            },
            '}' => {
                depth -= 1;
                p.advance(1);
            },
            '"' => {
                p.advance(1);
                while (p.peek()) |d| {
                    if (d == '\n') break;
                    if (d == '\\') {
                        escape(lx);
                        continue;
                    }
                    p.advance(1);
                    if (d == '"') break;
                }
            },
            else => p.advance(1),
        }
    }
    try unterminated(lx, start, "f-string");
    try lx.push(.fstring, start);
}
