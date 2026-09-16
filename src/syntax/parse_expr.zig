// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const text = @import("fluxion_text");

const ast = @import("ast.zig");
const lex = @import("lex.zig");
const parse = @import("parse.zig");
const stmt = @import("parse_stmt.zig");
const strings = @import("strings.zig");
const Kind = @import("token.zig").Kind;

const Parser = parse.Parser;
const Error = parse.Error;
const Expr = ast.Expr;

const Prec = struct {
    const @"or" = 10;
    const @"and" = 20;
    const compare = 30;
    const bitwise = 40;
    const shift = 50;
    const add = 60;
    const mul = 70;
};

const Infix = struct { prec: u8, op: ?ast.BinaryOp };

fn infix(kind: Kind) ?Infix {
    return switch (kind) {
        .kw_or => .{ .prec = Prec.@"or", .op = .@"or" },
        .kw_and => .{ .prec = Prec.@"and", .op = .@"and" },
        .equal_equal => .{ .prec = Prec.compare, .op = .eq },
        .bang_equal => .{ .prec = Prec.compare, .op = .ne },
        .less => .{ .prec = Prec.compare, .op = .lt },
        .less_equal => .{ .prec = Prec.compare, .op = .le },
        .greater => .{ .prec = Prec.compare, .op = .gt },
        .greater_equal => .{ .prec = Prec.compare, .op = .ge },
        .kw_in => .{ .prec = Prec.compare, .op = .in },
        .kw_is => .{ .prec = Prec.compare, .op = null },
        .ampersand => .{ .prec = Prec.bitwise, .op = .bit_and },
        .pipe => .{ .prec = Prec.bitwise, .op = .bit_or },
        .caret => .{ .prec = Prec.bitwise, .op = .bit_xor },
        .kw_orelse, .kw_catch => .{ .prec = Prec.bitwise, .op = null },
        .shl => .{ .prec = Prec.shift, .op = .shl },
        .shr => .{ .prec = Prec.shift, .op = .shr },
        .plus => .{ .prec = Prec.add, .op = .add },
        .minus => .{ .prec = Prec.add, .op = .sub },
        .plus_percent => .{ .prec = Prec.add, .op = .add_wrap },
        .minus_percent => .{ .prec = Prec.add, .op = .sub_wrap },
        .star => .{ .prec = Prec.mul, .op = .mul },
        .slash => .{ .prec = Prec.mul, .op = .div },
        .percent => .{ .prec = Prec.mul, .op = .mod },
        .star_percent => .{ .prec = Prec.mul, .op = .mul_wrap },
        else => null,
    };
}

pub fn expression(p: *Parser) Error!*Expr {
    try p.enter();
    defer p.leave();
    return binary(p, 0);
}

fn binary(p: *Parser, min: u8) Error!*Expr {
    var lhs = try prefix(p);
    while (infix(p.peek())) |info| {
        if (info.prec < min) break;
        const op_token = p.advance();
        const start = lhs.span.start;
        switch (op_token.kind) {
            .kw_orelse => {
                const rhs = try binary(p, info.prec + 1);
                lhs = try p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .@"orelse" = .{ .lhs = lhs, .rhs = rhs } } });
            },
            .kw_catch => {
                const cap = try captureOpt(p);
                const rhs = try binary(p, info.prec + 1);
                lhs = try p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .@"catch" = .{ .lhs = lhs, .capture = cap, .rhs = rhs } } });
            },
            .kw_is => {
                const ty = try parse.typeExpr(p);
                lhs = try p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .is_type = .{ .value = lhs, .type = ty } } });
            },
            else => {
                const rhs = try binary(p, info.prec + 1);
                lhs = try p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .binary = .{ .op = info.op.?, .lhs = lhs, .rhs = rhs } } });
            },
        }
        if (info.prec == Prec.compare) {
            if (infix(p.peek())) |next| if (next.prec == Prec.compare) {
                _ = try (try (try p.diags.err(p.at(Parser.spanOf(p.current())), "comparisons cannot be chained", .{}))
                    .text("a second comparison", .{}))
                    .help("join them with `and`: `a < b and b < c`", .{});
                return error.Syntax;
            };
        }
    }
    return lhs;
}

fn captureOpt(p: *Parser) Error!?ast.Name {
    if (p.eat(.pipe) == null) return null;
    const name = try p.expectName("a capture name");
    _ = try p.expect(.pipe, "to close the capture");
    return name;
}

pub fn capture(p: *Parser) Error!?ast.Name {
    return captureOpt(p);
}

fn prefix(p: *Parser) Error!*Expr {
    const t = p.current();
    const op: ?ast.UnaryOp = switch (t.kind) {
        .bang => .not,
        .minus => .neg,
        .tilde => .bit_not,
        else => null,
    };
    if (op) |unary| {
        _ = p.advance();
        try p.enter();
        defer p.leave();
        const operand = try prefix(p);
        return p.new(Expr, .{ .span = p.spanFrom(t.start), .kind = .{ .unary = .{ .op = unary, .operand = operand } } });
    }
    switch (t.kind) {
        .kw_try => {
            _ = p.advance();
            try p.enter();
            defer p.leave();
            const operand = try prefix(p);
            return p.new(Expr, .{ .span = p.spanFrom(t.start), .kind = .{ .@"try" = operand } });
        },
        .kw_await => {
            _ = p.advance();
            try p.enter();
            defer p.leave();
            const operand = try prefix(p);
            return p.new(Expr, .{ .span = p.spanFrom(t.start), .kind = .{ .@"await" = operand } });
        },
        else => return postfix(p),
    }
}

fn postfix(p: *Parser) Error!*Expr {
    var e = try primary(p);
    while (true) {
        const start = e.span.start;
        switch (p.peek()) {
            .l_paren => {
                _ = p.advance();
                const args = try arguments(p);
                e = try p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .call = .{ .callee = e, .args = args } } });
            },
            .l_bracket => {
                _ = p.advance();
                if (p.eat(.dot_dot)) |_| {
                    const end = try expression(p);
                    _ = try p.expect(.r_bracket, "to close the slice");
                    const zero = try p.new(Expr, .{ .span = .at(end.span.start), .kind = .{ .int = 0 } });
                    e = try p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .slice = .{ .target = e, .start = zero, .end = end } } });
                    continue;
                }
                const index = try expression(p);
                if (p.eat(.dot_dot)) |_| {
                    const end = if (p.check(.r_bracket)) null else try expression(p);
                    _ = try p.expect(.r_bracket, "to close the slice");
                    e = try p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .slice = .{ .target = e, .start = index, .end = end } } });
                } else {
                    _ = try p.expect(.r_bracket, "to close the index");
                    e = try p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .index = .{ .target = e, .index = index } } });
                }
            },
            .dot => {
                if (p.peekAt(1) == .question) {
                    _ = p.advance();
                    _ = p.advance();
                    e = try p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .unwrap = e } });
                    continue;
                }
                _ = p.advance();
                const name = try p.expectName("a field or method name after `.`");
                e = try p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .field = .{ .target = e, .name = name } } });
            },
            .l_brace => {
                if (!isTypeName(e) or !structLiteralAhead(p)) return e;
                e = try structLiteral(p, e);
            },
            else => return e,
        }
    }
}

fn isTypeName(e: *const Expr) bool {
    return switch (e.kind) {
        .ident => true,
        .field => |f| f.target.kind == .ident,
        else => false,
    };
}

fn structLiteralAhead(p: *const Parser) bool {
    if (p.peekAt(1) == .r_brace) return true;
    return p.peekAt(1) == .dot and p.peekAt(2) == .identifier and p.peekAt(3) == .equal;
}

fn structLiteral(p: *Parser, type_expr: *Expr) Error!*Expr {
    _ = try p.expect(.l_brace, "");
    var fields: std.ArrayList(ast.FieldInit) = .empty;
    while (!p.check(.r_brace)) {
        _ = try p.expect(.dot, "before the field name, as in `.hp = 10`");
        const name = try p.expectName("a field name");
        _ = try p.expect(.equal, "after the field name");
        const value = try expression(p);
        for (fields.items) |prior| if (std.mem.eql(u8, prior.name.text, name.text)) {
            _ = try (try (try p.diags.err(p.at(name.span), "`{s}` is set twice", .{name.text}))
                .text("set again here", .{}))
                .label(p.at(prior.name.span), "first set here", .{});
        };
        try fields.append(p.arena, .{ .name = name, .value = value });
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_brace, "to close the struct literal");
    return p.new(Expr, .{ .span = p.spanFrom(type_expr.span.start), .kind = .{ .struct_literal = .{ .type = type_expr, .fields = fields.items } } });
}

/// After the `(`: the arguments and the `)`.
pub fn arguments(p: *Parser) Error![]const *Expr {
    var list: std.ArrayList(*Expr) = .empty;
    while (!p.check(.r_paren)) {
        try list.append(p.arena, try expression(p));
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_paren, "to close the arguments");
    return list.items;
}

fn primary(p: *Parser) Error!*Expr {
    const t = p.current();
    const span = Parser.spanOf(t);
    switch (t.kind) {
        .int => {
            _ = p.advance();
            const value = text.number.parseInt(i64, p.textOf(t), .{ .allow_sign = false }) catch |err| switch (err) {
                error.Overflow => return p.fail(span, "`{s}` does not fit in an int, which is 64 bits", .{p.textOf(t)}),
                else => return p.fail(span, "`{s}` is not a number", .{p.textOf(t)}),
            };
            return p.new(Expr, .{ .span = span, .kind = .{ .int = value } });
        },
        .float => {
            _ = p.advance();
            const value = text.number.parseFloat(f64, p.textOf(t), .{ .allow_sign = false, .allow_special = false }) catch
                return p.fail(span, "`{s}` is not a number", .{p.textOf(t)});
            return p.new(Expr, .{ .span = span, .kind = .{ .float = value } });
        },
        .char => {
            _ = p.advance();
            const raw = p.source[t.start + 1 .. @max(t.start + 1, if (t.end > t.start + 1 and p.source[t.end - 1] == '\'') t.end - 1 else t.end)];
            const value = try strings.char(ctx(p), raw, t.start + 1) orelse 0;
            return p.new(Expr, .{ .span = span, .kind = .{ .int = value } });
        },
        .string => {
            _ = p.advance();
            const closed = t.end - t.start >= 2 and p.source[t.end - 1] == '"';
            const raw = p.source[t.start + 1 .. if (closed) t.end - 1 else t.end];
            return p.new(Expr, .{ .span = span, .kind = .{ .string = try strings.decode(ctx(p), raw, t.start + 1) } });
        },
        .multiline_string => return multiline(p),
        .fstring => {
            _ = p.advance();
            return p.new(Expr, .{ .span = span, .kind = .{ .fstring = try fstringParts(p, t) } });
        },
        .kw_true, .kw_false => {
            _ = p.advance();
            return p.new(Expr, .{ .span = span, .kind = .{ .bool = t.kind == .kw_true } });
        },
        .kw_null => {
            _ = p.advance();
            return p.new(Expr, .{ .span = span, .kind = .null });
        },
        .identifier => {
            _ = p.advance();
            return p.new(Expr, .{ .span = span, .kind = .{ .ident = p.textOf(t) } });
        },
        .kw_self => {
            _ = p.advance();
            return p.new(Expr, .{ .span = span, .kind = .self });
        },
        .dot => {
            _ = p.advance();
            if (p.check(.l_brace)) return p.fail(p.spanFrom(t.start), "a struct literal needs its type: write `Name{{ .field = value }}`", .{});
            if (p.check(.int) or p.check(.float)) {
                const digits = p.textOf(p.current());
                _ = try (try p.diags.err(p.at(.{ .start = t.start, .end = p.current().end }), "a float starts with a digit", .{}))
                    .help("write `0.{s}`", .{digits});
                return error.Syntax;
            }
            const name = try p.expectName("an enum member after `.`");
            return p.new(Expr, .{ .span = p.spanFrom(t.start), .kind = .{ .enum_literal = name } });
        },
        .kw_error => {
            _ = p.advance();
            _ = try p.expect(.dot, "after `error`, as in `error.NotFound`");
            const name = try p.expectName("an error name");
            var message: ?*Expr = null;
            if (p.eat(.l_paren)) |_| {
                message = try expression(p);
                _ = try p.expect(.r_paren, "after the error message");
            }
            return p.new(Expr, .{ .span = p.spanFrom(t.start), .kind = .{ .error_literal = .{ .name = name, .message = message } } });
        },
        .l_paren => {
            _ = p.advance();
            const inner = try expression(p);
            _ = try p.expect(.r_paren, "to close the parenthesis");
            inner.span = p.spanFrom(t.start);
            return inner;
        },
        .l_bracket => {
            _ = p.advance();
            if (p.check(.colon) and p.peekAt(1) == .r_bracket) {
                _ = p.advance();
                _ = p.advance();
                const at = p.spanFrom(t.start);
                _ = try (try p.diags.err(.{ .file = p.file, .span = at }, "`[:]` is not a map", .{}))
                    .help("an empty map is `{{}}`, a map with keys `{{ \"a\": 1 }}`", .{});
                return p.new(Expr, .{ .span = at, .kind = .invalid });
            }
            var items: std.ArrayList(*Expr) = .empty;
            while (!p.check(.r_bracket)) {
                try items.append(p.arena, try expression(p));
                if (p.eat(.comma) == null) break;
            }
            _ = try p.expect(.r_bracket, "to close the list");
            return p.new(Expr, .{ .span = p.spanFrom(t.start), .kind = .{ .list = items.items } });
        },
        .l_brace => {
            if (looksLikeMap(p)) return mapLiteral(p);
            const b = try stmt.block(p);
            return p.new(Expr, .{ .span = b.span, .kind = .{ .block = b } });
        },
        .pipe => return shortLambda(p),
        .kw_fn => return fullLambda(p),
        .kw_if => return ifExpr(p),
        .kw_switch => {
            const sw = try switchBody(p);
            return p.new(Expr, .{ .span = p.spanFrom(t.start), .kind = .{ .@"switch" = sw } });
        },
        .builtin => {
            _ = p.advance();
            const name: ast.Name = .{ .text = p.textOf(t)[1..], .span = span };
            _ = try p.expect(.l_paren, "after the builtin's name");
            const args = try arguments(p);
            return p.new(Expr, .{ .span = p.spanFrom(t.start), .kind = .{ .builtin = .{ .name = name, .args = args } } });
        },
        .kw_return => {
            _ = p.advance();
            const value = if (startsExpression(p.peek())) try expression(p) else null;
            return p.new(Expr, .{ .span = p.spanFrom(t.start), .kind = .{ .@"return" = value } });
        },
        .kw_break, .kw_continue => {
            _ = p.advance();
            var label: ?ast.Name = null;
            if (p.eat(.colon)) |_| label = try p.expectName("a loop label");
            const kind: Expr.Kind = if (t.kind == .kw_break) .{ .@"break" = label } else .{ .@"continue" = label };
            return p.new(Expr, .{ .span = p.spanFrom(t.start), .kind = kind });
        },
        .equal => return p.fail(span, "`=` sets a variable, and needs a place to set on its left", .{}),
        else => return p.failHere("an expression"),
    }
}

pub fn startsExpression(kind: Kind) bool {
    return switch (kind) {
        .semicolon, .r_paren, .r_bracket, .r_brace, .comma, .eof, .kw_else, .fat_arrow, .colon => false,
        else => true,
    };
}

fn ctx(p: *Parser) strings.Context {
    return .{ .arena = p.arena, .file = p.file, .diags = p.diags };
}

fn multiline(p: *Parser) Error!*Expr {
    const start = p.current().start;
    var bytes: std.ArrayList(u8) = .empty;
    var first = true;
    while (p.check(.multiline_string)) {
        const t = p.advance();
        if (!first) try bytes.append(p.arena, '\n');
        first = false;
        try bytes.appendSlice(p.arena, p.textOf(t)[2..]);
    }
    return p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .string = bytes.items } });
}

/// `{` starts a map when a `:` comes before anything a block would hold.
fn looksLikeMap(p: *const Parser) bool {
    if (p.peekAt(1) == .r_brace) return true;
    var depth: usize = 0;
    var i: usize = 1;
    while (true) : (i += 1) {
        switch (p.peekAt(i)) {
            .l_paren, .l_bracket => depth += 1,
            .r_paren, .r_bracket => depth -|= 1,
            .colon => if (depth == 0) {
                const next = p.peekAt(i + 1);
                return next != .kw_while and next != .kw_for;
            },
            .semicolon, .l_brace, .r_brace, .eof => return false,
            else => {},
        }
    }
}

fn mapLiteral(p: *Parser) Error!*Expr {
    const start = (try p.expect(.l_brace, "")).start;
    var entries: std.ArrayList(ast.MapEntry) = .empty;
    while (!p.check(.r_brace)) {
        const key = try expression(p);
        _ = try p.expect(.colon, "between the key and the value");
        const value = try expression(p);
        try entries.append(p.arena, .{ .key = key, .value = value });
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_brace, "to close the map");
    return p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .map = entries.items } });
}

fn shortLambda(p: *Parser) Error!*Expr {
    const start = p.current().start;
    var params: std.ArrayList(ast.Param) = .empty;
    _ = try p.expect(.pipe, "");
    while (!p.check(.pipe)) {
        const name = try p.expectName("a parameter name");
        const ty = if (p.eat(.colon)) |_| try parse.typeExpr(p) else null;
        try params.append(p.arena, .{ .name = name, .type = ty, .default = null, .is_self = false });
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.pipe, "to close the lambda's parameters");
    const body: ast.Fn.Body = if (p.check(.l_brace)) .{ .block = try stmt.block(p) } else .{ .expr = try expression(p) };
    if (body == .expr and stmt.assignOp(p.peek()) != null) {
        _ = try (try p.diags.err(p.at(Parser.spanOf(p.current())), "a lambda without braces gives back a value, and an assignment gives none", .{}))
            .help("put the assignment in a block: `|...| {{ x += 1; }}`", .{});
        return error.Syntax;
    }
    const f = try p.new(ast.Fn, .{
        .span = p.spanFrom(start),
        .name = null,
        .params = params.items,
        .ret = null,
        .body = body,
        .annotations = &.{},
        .doc = null,
    });
    return p.new(Expr, .{ .span = f.span, .kind = .{ .lambda = f } });
}

fn fullLambda(p: *Parser) Error!*Expr {
    const start = (try p.expect(.kw_fn, "")).start;
    if (p.check(.identifier)) return p.fail(Parser.spanOf(p.current()), "a named function is a declaration; in an expression write `fn (x) {{ ... }}`", .{});
    _ = try p.expect(.l_paren, "after `fn`");
    const params = try parse.params(p, false);
    const ret = if (!p.check(.l_brace)) try parse.typeExpr(p) else null;
    const body = try stmt.block(p);
    const f = try p.new(ast.Fn, .{
        .span = p.spanFrom(start),
        .name = null,
        .params = params,
        .ret = ret,
        .body = .{ .block = body },
        .annotations = &.{},
        .doc = null,
    });
    return p.new(Expr, .{ .span = f.span, .kind = .{ .lambda = f } });
}

fn ifExpr(p: *Parser) Error!*Expr {
    const start = (try p.expect(.kw_if, "")).start;
    const cond = try stmt.condition(p);
    const cap = try captureOpt(p);
    const then = try expression(p);
    if (p.eat(.kw_else) == null) {
        _ = try (try p.diags.err(p.at(p.spanFrom(start)), "an `if` that gives a value needs an `else`", .{}))
            .help("add `else` and the value to use otherwise", .{});
        return error.Syntax;
    }
    const otherwise = try expression(p);
    return p.new(Expr, .{ .span = p.spanFrom(start), .kind = .{ .@"if" = .{ .cond = cond, .capture = cap, .then = then, .@"else" = otherwise } } });
}

pub fn switchBody(p: *Parser) Error!*ast.Switch {
    _ = try p.expect(.kw_switch, "");
    const subject = try stmt.condition(p);
    _ = try p.expect(.l_brace, "to open the switch");
    var prongs: std.ArrayList(ast.SwitchProng) = .empty;
    while (!p.check(.r_brace) and !p.check(.eof)) {
        const prong_start = p.current().start;
        var cases: std.ArrayList(ast.SwitchProng.Case) = .empty;
        var is_else = false;
        if (p.eat(.kw_else)) |_| {
            is_else = true;
        } else while (true) {
            const from = try expression(p);
            if (p.eat(.ellipsis)) |_| {
                const to = try expression(p);
                try cases.append(p.arena, .{ .range = .{ .from = from, .to = to } });
            } else try cases.append(p.arena, .{ .value = from });
            if (p.eat(.comma) == null or p.check(.fat_arrow)) break;
        }
        _ = try p.expect(.fat_arrow, "after the case");
        const cap = try captureOpt(p);
        const body_start = p.current().start;
        var body = try expression(p);
        if (stmt.assignOp(p.peek()) != null) {
            // A prong may set something, as in Zig, when nothing wants its value.
            const set = try stmt.finishSimple(p, body_start, body);
            const b = try p.new(ast.Block, .{ .span = set.span, .stmts = try p.arena.dupe(*ast.Stmt, &.{set}) });
            body = try p.new(Expr, .{ .span = set.span, .kind = .{ .block = b } });
        }
        try prongs.append(p.arena, .{ .span = p.spanFrom(prong_start), .cases = cases.items, .is_else = is_else, .capture = cap, .body = body });
        if (p.eat(.comma) == null and body.kind != .block) break;
    }
    _ = try p.expect(.r_brace, "to close the switch");
    return p.new(ast.Switch, .{ .subject = subject, .prongs = prongs.items });
}

fn fstringParts(p: *Parser, t: @import("token.zig").Token) Error![]const ast.FPart {
    const closed = t.end - t.start >= 3 and p.source[t.end - 1] == '"';
    const base: usize = t.start + 2;
    const raw = p.source[base .. if (closed) t.end - 1 else t.end];
    var parts: std.ArrayList(ast.FPart) = .empty;
    var literal: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '{' and i + 1 < raw.len and raw[i + 1] == '{') {
            try literal.append(p.arena, '{');
            i += 2;
        } else if (c == '}' and i + 1 < raw.len and raw[i + 1] == '}') {
            try literal.append(p.arena, '}');
            i += 2;
        } else if (c == '}') {
            _ = try (try p.diags.err(p.at(.{ .start = @intCast(base + i), .end = @intCast(base + i + 1) }), "a `}}` in an f-string is written `}}}}`", .{}))
                .text("this closes nothing", .{});
            i += 1;
        } else if (c == '\\') {
            i += 1;
            i += try strings.escape(ctx(p), raw, i, base, &literal);
        } else if (c == '{') {
            const found_hole = strings.hole(raw, i + 1) orelse {
                return p.fail(.{ .start = @intCast(base + i), .end = @intCast(base + raw.len) }, "this `{{` in the f-string is never closed", .{});
            };
            if (literal.items.len > 0) {
                try parts.append(p.arena, .{ .literal = literal.items });
                literal = .empty;
            }
            const expr_end = found_hole.colon orelse found_hole.close;
            const value = try holeExpression(p, base + i + 1, base + expr_end);
            const spec = if (found_hole.colon) |colon| raw[colon + 1 .. found_hole.close] else "";
            try parts.append(p.arena, .{ .expr = .{ .value = value, .spec = spec } });
            i = found_hole.close + 1;
        } else {
            try literal.append(p.arena, c);
            i += 1;
        }
    }
    if (literal.items.len > 0 or parts.items.len == 0) try parts.append(p.arena, .{ .literal = literal.items });
    return parts.items;
}

fn holeExpression(p: *Parser, start: usize, end: usize) Error!*Expr {
    if (std.mem.trim(u8, p.source[start..end], " \t").len == 0) {
        return p.fail(.{ .start = @intCast(start - 1), .end = @intCast(end + 1) }, "an empty `{{}}` in an f-string; write `{{{{}}}}` for the braces themselves", .{});
    }
    const tokens = try lex.tokenizeRange(p.gpa, p.source, start, end, p.file, p.diags);
    defer p.gpa.free(tokens);
    var sub: Parser = .{ .arena = p.arena, .gpa = p.gpa, .source = p.source, .tokens = tokens, .file = p.file, .diags = p.diags, .depth = p.depth };
    const value = try expression(&sub);
    if (!sub.check(.eof)) return sub.failHere("the end of the f-string expression");
    return value;
}
