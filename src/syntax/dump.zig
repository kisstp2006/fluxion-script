// SPDX-License-Identifier: BSD-2-Clause

//! The tree as S-expressions: what the parser's tests compare against, and
//! what `flux ast` prints.

const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("ast.zig");

pub fn module(w: *Writer, m: ast.Module) Writer.Error!void {
    for (m.stmts, 0..) |s, i| {
        if (i > 0) try w.writeByte('\n');
        try stmt(w, s);
    }
}

fn name(w: *Writer, n: ?ast.Name) Writer.Error!void {
    try w.writeAll(if (n) |x| x.text else "_");
}

fn quoted(w: *Writer, bytes: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (bytes) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

pub fn typeExpr(w: *Writer, t: *const ast.TypeExpr) Writer.Error!void {
    switch (t.kind) {
        .name => |n| try w.writeAll(n),
        .member => |m| try w.print("{s}.{s}", .{ m.module, m.name }),
        .optional => |c| {
            try w.writeByte('?');
            try typeExpr(w, c);
        },
        .error_union => |c| {
            try w.writeByte('!');
            try typeExpr(w, c);
        },
        .list => |c| {
            try w.writeByte('[');
            try typeExpr(w, c);
            try w.writeByte(']');
        },
        .map => |m| {
            try w.writeByte('[');
            try typeExpr(w, m.key);
            try w.writeAll(": ");
            try typeExpr(w, m.value);
            try w.writeByte(']');
        },
        .func => |f| {
            try w.writeAll("fn(");
            for (f.params, 0..) |param, i| {
                if (i > 0) try w.writeAll(", ");
                try typeExpr(w, param);
            }
            try w.writeByte(')');
            if (f.ret) |r| {
                try w.writeByte(' ');
                try typeExpr(w, r);
            }
        },
    }
}

fn list(w: *Writer, head: []const u8, items: []const *ast.Expr) Writer.Error!void {
    try w.print("({s}", .{head});
    for (items) |item| {
        try w.writeByte(' ');
        try expr(w, item);
    }
    try w.writeByte(')');
}

pub fn expr(w: *Writer, e: *const ast.Expr) Writer.Error!void {
    switch (e.kind) {
        .int => |v| try w.print("{d}", .{v}),
        .float => |v| try w.print("{d}", .{v}),
        .bool => |v| try w.writeAll(if (v) "true" else "false"),
        .null => try w.writeAll("null"),
        .string => |s| try quoted(w, s),
        .fstring => |parts| {
            try w.writeAll("(f");
            for (parts) |part| switch (part) {
                .literal => |s| {
                    try w.writeByte(' ');
                    try quoted(w, s);
                },
                .expr => |x| {
                    try w.writeAll(" {");
                    try expr(w, x.value);
                    if (x.spec.len > 0) try w.print(":{s}", .{x.spec});
                    try w.writeByte('}');
                },
            };
            try w.writeByte(')');
        },
        .enum_literal => |n| try w.print(".{s}", .{n.text}),
        .error_literal => |x| {
            try w.print("error.{s}", .{x.name.text});
            if (x.message) |m| {
                try w.writeByte('(');
                try expr(w, m);
                try w.writeByte(')');
            }
        },
        .ident => |n| try w.writeAll(n),
        .self => try w.writeAll("self"),
        .list => |items| try list(w, "list", items),
        .map => |entries| {
            try w.writeAll("(map");
            for (entries) |entry| {
                try w.writeAll(" (");
                try expr(w, entry.key);
                try w.writeByte(' ');
                try expr(w, entry.value);
                try w.writeByte(')');
            }
            try w.writeByte(')');
        },
        .struct_literal => |s| {
            try w.writeAll("(new ");
            try expr(w, s.type);
            for (s.fields) |f| {
                try w.print(" (.{s} ", .{f.name.text});
                try expr(w, f.value);
                try w.writeByte(')');
            }
            try w.writeByte(')');
        },
        .unary => |u| {
            try w.print("({s} ", .{switch (u.op) {
                .neg => "-",
                .not => "!",
                .bit_not => "~",
            }});
            try expr(w, u.operand);
            try w.writeByte(')');
        },
        .binary => |b| {
            try w.print("({s} ", .{b.op.symbol()});
            try expr(w, b.lhs);
            try w.writeByte(' ');
            try expr(w, b.rhs);
            try w.writeByte(')');
        },
        .is_type => |x| {
            try w.writeAll("(is ");
            try expr(w, x.value);
            try w.writeByte(' ');
            try typeExpr(w, x.type);
            try w.writeByte(')');
        },
        .@"orelse" => |x| {
            try w.writeAll("(orelse ");
            try expr(w, x.lhs);
            try w.writeByte(' ');
            try expr(w, x.rhs);
            try w.writeByte(')');
        },
        .@"catch" => |x| {
            try w.writeAll("(catch ");
            try expr(w, x.lhs);
            try w.writeAll(" |");
            try name(w, x.capture);
            try w.writeAll("| ");
            try expr(w, x.rhs);
            try w.writeByte(')');
        },
        .@"try" => |x| try list(w, "try", &.{x}),
        .@"await" => |x| try list(w, "await", &.{x}),
        .call => |c| {
            try w.writeAll("(call ");
            try expr(w, c.callee);
            for (c.args) |a| {
                try w.writeByte(' ');
                try expr(w, a);
            }
            try w.writeByte(')');
        },
        .index => |x| try list(w, "[]", &.{ x.target, x.index }),
        .slice => |x| {
            try w.writeAll("([..] ");
            try expr(w, x.target);
            try w.writeByte(' ');
            if (x.start) |s| try expr(w, s) else try w.writeByte('_');
            try w.writeByte(' ');
            if (x.end) |s| try expr(w, s) else try w.writeByte('_');
            try w.writeByte(')');
        },
        .field => |f| {
            try w.writeAll("(. ");
            try expr(w, f.target);
            try w.print(" {s})", .{f.name.text});
        },
        .unwrap => |x| try list(w, ".?", &.{x}),
        .@"if" => |x| {
            try w.writeAll("(if ");
            try expr(w, x.cond);
            if (x.capture) |c| try w.print(" |{s}|", .{c.text});
            try w.writeByte(' ');
            try expr(w, x.then);
            try w.writeByte(' ');
            try expr(w, x.@"else");
            try w.writeByte(')');
        },
        .@"switch" => |sw| try switchNode(w, sw),
        .lambda => |f| try function(w, "lambda", f),
        .builtin => |b| {
            try w.print("(@{s}", .{b.name.text});
            for (b.args) |a| {
                try w.writeByte(' ');
                try expr(w, a);
            }
            try w.writeByte(')');
        },
        .range => |r| {
            try w.writeAll(if (r.inclusive) "(..= " else "(.. ");
            try expr(w, r.start);
            try w.writeByte(' ');
            if (r.end) |x| try expr(w, x) else try w.writeByte('_');
            try w.writeByte(')');
        },
        .block => |b| try block(w, b),
        .@"return" => |v| {
            try w.writeAll("(return");
            if (v) |x| {
                try w.writeByte(' ');
                try expr(w, x);
            }
            try w.writeByte(')');
        },
        .@"break" => |l| try w.print("(break{s}{s})", .{ if (l != null) " :" else "", if (l) |x| x.text else "" }),
        .@"continue" => |l| try w.print("(continue{s}{s})", .{ if (l != null) " :" else "", if (l) |x| x.text else "" }),
        .invalid => try w.writeAll("<invalid>"),
    }
}

fn switchNode(w: *Writer, sw: *const ast.Switch) Writer.Error!void {
    try w.writeAll("(switch ");
    try expr(w, sw.subject);
    for (sw.prongs) |prong| {
        try w.writeAll(" (");
        if (prong.is_else) try w.writeAll("else");
        for (prong.cases, 0..) |c, i| {
            if (i > 0) try w.writeByte(' ');
            switch (c) {
                .value => |v| try expr(w, v),
                .range => |r| {
                    try w.writeAll("(... ");
                    try expr(w, r.from);
                    try w.writeByte(' ');
                    try expr(w, r.to);
                    try w.writeByte(')');
                },
            }
        }
        try w.writeAll(" => ");
        try expr(w, prong.body);
        try w.writeByte(')');
    }
    try w.writeByte(')');
}

fn block(w: *Writer, b: *const ast.Block) Writer.Error!void {
    try w.writeAll("{");
    for (b.stmts) |s| {
        try w.writeByte(' ');
        try stmt(w, s);
    }
    try w.writeAll(" }");
}

fn function(w: *Writer, head: []const u8, f: *const ast.Fn) Writer.Error!void {
    try w.print("({s}", .{head});
    if (f.name) |n| try w.print(" {s}", .{n.text});
    try w.writeAll(" (");
    for (f.params, 0..) |param, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(param.name.text);
        if (param.type) |t| {
            try w.writeByte(':');
            try typeExpr(w, t);
        }
        if (param.default) |d| {
            try w.writeByte('=');
            try expr(w, d);
        }
    }
    try w.writeByte(')');
    if (f.ret) |r| {
        try w.writeByte(' ');
        try typeExpr(w, r);
    }
    try w.writeByte(' ');
    switch (f.body) {
        .block => |b| try block(w, b),
        .expr => |e| try expr(w, e),
    }
    try w.writeByte(')');
}

fn annotations(w: *Writer, attrs: []const ast.Annotation) Writer.Error!void {
    for (attrs) |a| {
        try w.print("@{s}", .{a.name.text});
        if (a.args.len > 0) {
            try w.writeByte('(');
            for (a.args, 0..) |arg, i| {
                if (i > 0) try w.writeByte(' ');
                try expr(w, arg);
            }
            try w.writeByte(')');
        }
        try w.writeByte(' ');
    }
}

fn varDecl(w: *Writer, v: *const ast.VarDecl) Writer.Error!void {
    try w.writeByte('(');
    try annotations(w, v.annotations);
    try w.print("{s} {s}", .{ if (v.is_const) "const" else "var", v.name.text });
    if (v.type) |t| {
        try w.writeByte(':');
        try typeExpr(w, t);
    }
    if (v.value) |x| {
        try w.writeByte(' ');
        try expr(w, x);
    }
    try w.writeByte(')');
}

pub fn stmt(w: *Writer, s: *const ast.Stmt) Writer.Error!void {
    switch (s.kind) {
        .expr => |e| try expr(w, e),
        .@"var" => |v| try varDecl(w, v),
        .assign => |a| {
            try w.print("({s}= ", .{if (ast.assignToBinary(a.op)) |op| op.symbol() else ""});
            try expr(w, a.target);
            try w.writeByte(' ');
            try expr(w, a.value);
            try w.writeByte(')');
        },
        .block => |b| try block(w, b),
        .@"if" => |x| {
            try w.writeAll("(if ");
            try expr(w, x.cond);
            if (x.capture) |c| try w.print(" |{s}|", .{c.text});
            try w.writeByte(' ');
            try stmt(w, x.then);
            if (x.@"else") |e| {
                try w.writeAll(" else ");
                if (x.else_capture) |c| try w.print("|{s}| ", .{c.text});
                try stmt(w, e);
            }
            try w.writeByte(')');
        },
        .@"while" => |x| {
            try w.writeAll("(while ");
            if (x.label) |l| try w.print(":{s} ", .{l.text});
            try expr(w, x.cond);
            if (x.capture) |c| try w.print(" |{s}|", .{c.text});
            if (x.next) |n| {
                try w.writeAll(" : ");
                try stmt(w, n);
            }
            try w.writeByte(' ');
            try stmt(w, x.body);
            try w.writeByte(')');
        },
        .@"for" => |x| {
            try w.writeAll("(for ");
            if (x.label) |l| try w.print(":{s} ", .{l.text});
            try expr(w, x.iterable);
            try w.print(" |{s}", .{x.value.text});
            if (x.index) |i| try w.print(", {s}", .{i.text});
            try w.writeAll("| ");
            try stmt(w, x.body);
            try w.writeByte(')');
        },
        .@"switch" => |sw| try switchNode(w, sw),
        .@"defer" => |d| {
            try w.writeAll(if (d.on_error) "(errdefer " else "(defer ");
            try stmt(w, d.body);
            try w.writeByte(')');
        },
        .@"fn" => |f| {
            if (f.annotations.len > 0) try annotations(w, f.annotations);
            try function(w, "fn", f);
        },
        .@"struct" => |st| {
            try w.print("(struct {s}", .{st.name.text});
            if (st.parent) |parent| {
                try w.writeAll(" extends ");
                try typeExpr(w, parent);
            }
            for (st.fields) |f| {
                try w.writeByte(' ');
                try varDecl(w, f);
            }
            for (st.consts) |c| {
                try w.writeByte(' ');
                try varDecl(w, c);
            }
            for (st.signals) |sig| try w.print(" (signal {s} {d})", .{ sig.name.text, sig.params.len });
            for (st.methods) |m| {
                try w.writeByte(' ');
                try function(w, "fn", m);
            }
            try w.writeByte(')');
        },
        .@"enum" => |e| {
            try w.print("(enum {s}", .{e.name.text});
            for (e.members) |m| {
                try w.print(" {s}", .{m.name.text});
                if (m.value) |v| {
                    try w.writeByte('=');
                    try expr(w, v);
                }
            }
            for (e.methods) |m| {
                try w.writeByte(' ');
                try function(w, "fn", m);
            }
            try w.writeByte(')');
        },
        .@"test" => |t| {
            try w.writeAll("(test ");
            try quoted(w, t.name);
            try w.writeByte(' ');
            try block(w, t.body);
            try w.writeByte(')');
        },
        .invalid => try w.writeAll("<invalid>"),
    }
}
