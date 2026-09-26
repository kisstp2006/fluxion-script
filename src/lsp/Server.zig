// SPDX-License-Identifier: BSD-2-Clause

//! `flux lsp`: the language service over the Language Server Protocol, for
//! VS Code, Neovim, Helix, Zed and the rest. A document for each file the
//! editor has open, compiled again at each change and its diagnostics sent
//! then; questions answered from its latest compile, or - completions and
//! signatures - from a compile of their own.
//!
//! An import is read from the editor when the file is open there, so what
//! is typed in one file is seen in the files importing it before it is
//! saved; otherwise from disk. Scripts get `os`, as `flux run` gives it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("fluxion_json");

const diag = @import("../diag.zig");
const Vm = @import("../vm/Vm.zig");
const service = @import("../service.zig");
const Analysis = service.Analysis;
const os = @import("../lib/os.zig");
const Lines = @import("Lines.zig");
const uri = @import("uri.zig");
const rpc = @import("rpc.zig");

const Server = @This();

pub const version = "0.1.0";

gpa: Allocator,
io: std.Io,
out: *std.Io.Writer,
documents: std.ArrayList(*Document) = .empty,
encoding: Lines.Encoding = .utf16,
shut_down: bool = false,
/// Set by `exit`: what the process ends with.
exit_code: ?u8 = null,
host: os.Host,

const Document = struct {
    uri: []u8,
    path: []u8,
    text: []u8,
    version: i64,
    lines: Lines,
    analysis: ?*Analysis = null,
};

pub fn init(gpa: Allocator, io: std.Io, out: *std.Io.Writer) Server {
    return .{ .gpa = gpa, .io = io, .out = out, .host = .{ .io = io, .args = &.{}, .start = std.Io.Timestamp.now(io, .awake) } };
}

pub fn deinit(s: *Server) void {
    for (s.documents.items) |d| s.free(d);
    s.documents.deinit(s.gpa);
}

fn free(s: *Server, d: *Document) void {
    if (d.analysis) |a| a.deinit();
    d.lines.deinit(s.gpa);
    s.gpa.free(d.uri);
    s.gpa.free(d.path);
    s.gpa.free(d.text);
    s.gpa.destroy(d);
}

/// Answers messages from `in` until the client says to exit, or goes.
pub fn run(s: *Server, in: *std.Io.Reader) !u8 {
    while (s.exit_code == null) {
        const body = (try rpc.read(s.gpa, in)) orelse return if (s.shut_down) 0 else 1;
        defer s.gpa.free(body);
        s.handle(body) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => |e| std.log.err("flux lsp: {s}", .{@errorName(e)}),
        };
    }
    return s.exit_code.?;
}

pub fn handle(s: *Server, body: []const u8) !void {
    var doc = json.parse(s.gpa, body, .{}) catch return s.fail(.null, -32700, "the message is not JSON");
    defer doc.deinit();
    const root = doc.root;
    // A reply to something the server asked: it asks nothing.
    const method = root.get("method").asString() orelse return;
    const id = root.get("id");
    const params = root.get("params");
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const eql = std.mem.eql;
    if (eql(u8, method, "initialize")) return s.initialize(id, params);
    if (eql(u8, method, "shutdown")) {
        s.shut_down = true;
        return s.respond(id, @as(?u8, null));
    }
    if (eql(u8, method, "exit")) {
        s.exit_code = if (s.shut_down) 0 else 1;
        return;
    }
    if (eql(u8, method, "textDocument/didOpen")) return s.open(params);
    if (eql(u8, method, "textDocument/didChange")) return s.change(params);
    if (eql(u8, method, "textDocument/didClose")) return s.close(params);
    if (eql(u8, method, "textDocument/didSave")) return s.saved();
    const requests = .{
        .{ "textDocument/hover", hover },
        .{ "textDocument/completion", completion },
        .{ "textDocument/signatureHelp", signatureHelp },
        .{ "textDocument/definition", definition },
        .{ "textDocument/references", references },
        .{ "textDocument/documentHighlight", highlights },
        .{ "textDocument/documentSymbol", documentSymbols },
        .{ "textDocument/semanticTokens/full", semanticTokens },
    };
    inline for (requests) |r| if (eql(u8, method, r[0])) {
        const d = s.documentOf(params) orelse return s.respond(id, @as(?u8, null));
        return r[1](s, arena, id, d, params);
    };
    // Notifications nobody answers - `initialized`, `$/cancelRequest` -
    // are passed over; a request is told it is not known.
    if (id != .null) try s.fail(id, -32601, "the server does not know this method");
}

// ---------------------------------------------------------------------------
// Replies

fn respond(s: *Server, id: json.Value, result: anytype) !void {
    var buf: std.Io.Writer.Allocating = .init(s.gpa);
    defer buf.deinit();
    var w: json.Writer = .init(&buf.writer, .{ .skip_nulls = true });
    try w.beginObject();
    try w.field("jsonrpc", "2.0");
    try w.field("id", id);
    try w.field("result", result);
    try w.endObject();
    try rpc.write(s.out, buf.written());
}

fn fail(s: *Server, id: json.Value, code: i32, message: []const u8) !void {
    var buf: std.Io.Writer.Allocating = .init(s.gpa);
    defer buf.deinit();
    var w: json.Writer = .init(&buf.writer, .{});
    try w.beginObject();
    try w.field("jsonrpc", "2.0");
    try w.field("id", id);
    try w.field("error", .{ .code = code, .message = message });
    try w.endObject();
    try rpc.write(s.out, buf.written());
}

fn notify(s: *Server, method: []const u8, params: anytype) !void {
    var buf: std.Io.Writer.Allocating = .init(s.gpa);
    defer buf.deinit();
    var w: json.Writer = .init(&buf.writer, .{ .skip_nulls = true });
    try w.beginObject();
    try w.field("jsonrpc", "2.0");
    try w.field("method", method);
    try w.field("params", params);
    try w.endObject();
    try rpc.write(s.out, buf.written());
}

// ---------------------------------------------------------------------------
// The protocol's shapes

const Range = struct { start: Lines.Position, end: Lines.Position };

/// An empty list, which JSON writes as `[]`.
const nothing = [0]u32{};

const Location = struct { uri: []const u8, range: Range };

const Markup = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

fn rangeOf(lines: *const Lines, span: diag.Span) Range {
    return .{ .start = lines.position(span.start), .end = lines.position(span.end) };
}

const token_types = blk: {
    const fields = @typeInfo(service.TokenType).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, &names) |f, *n| n.* = if (std.mem.eql(u8, f.name, "enum_member")) "enumMember" else f.name;
    break :blk names;
};
const token_modifiers = [_][]const u8{ "declaration", "readonly", "defaultLibrary", "documentation" };

const Capabilities = struct {
    position_encoding: []const u8,
    text_document_sync: struct {
        open_close: bool = true,
        /// Each change sends the whole text.
        change: u8 = 1,
        save: struct { include_text: bool = false, pub const json_case = .camel; } = .{},
        pub const json_case = .camel;
    } = .{},
    completion_provider: struct {
        trigger_characters: []const []const u8 = &.{ ".", "@" },
        pub const json_case = .camel;
    } = .{},
    hover_provider: bool = true,
    signature_help_provider: struct {
        trigger_characters: []const []const u8 = &.{ "(", "," },
        retrigger_characters: []const []const u8 = &.{")"},
        pub const json_case = .camel;
    } = .{},
    definition_provider: bool = true,
    references_provider: bool = true,
    document_highlight_provider: bool = true,
    document_symbol_provider: bool = true,
    semantic_tokens_provider: struct {
        legend: struct {
            token_types: []const []const u8 = &token_types,
            token_modifiers: []const []const u8 = &token_modifiers,
            pub const json_case = .camel;
        } = .{},
        full: bool = true,
    } = .{},

    pub const json_case = .camel;
};

fn initialize(s: *Server, id: json.Value, params: json.Value) !void {
    for (params.get("capabilities").get("general").get("positionEncodings").items()) |e| {
        if (std.mem.eql(u8, e.asString() orelse "", "utf-8")) s.encoding = .utf8;
    }
    try s.respond(id, .{
        .capabilities = Capabilities{ .position_encoding = if (s.encoding == .utf8) "utf-8" else "utf-16" },
        .serverInfo = .{ .name = "flux", .version = version },
    });
}

// ---------------------------------------------------------------------------
// Documents

fn find(s: *Server, doc_uri: []const u8) ?*Document {
    for (s.documents.items) |d| if (std.mem.eql(u8, d.uri, doc_uri)) return d;
    return null;
}

fn documentOf(s: *Server, params: json.Value) ?*Document {
    return s.find(params.get("textDocument").get("uri").asString() orelse return null);
}

fn offsetOf(d: *const Document, params: json.Value) u32 {
    const pos = params.get("position");
    return d.lines.offset(.{ .line = pos.get("line").asInt(u32) orelse 0, .character = pos.get("character").asInt(u32) orelse 0 });
}

fn open(s: *Server, params: json.Value) !void {
    const item = params.get("textDocument");
    const doc_uri = item.get("uri").asString() orelse return;
    if (s.find(doc_uri)) |old| {
        _ = s.documents.swapRemove(std.mem.indexOfScalar(*Document, s.documents.items, old).?);
        s.free(old);
    }
    const d = try s.gpa.create(Document);
    errdefer s.gpa.destroy(d);
    const text = try s.gpa.dupe(u8, item.get("text").asString() orelse "");
    d.* = .{
        .uri = try s.gpa.dupe(u8, doc_uri),
        .path = try uri.toPath(s.gpa, doc_uri),
        .text = text,
        .version = item.get("version").asInt(i64) orelse 0,
        .lines = try .init(s.gpa, text, s.encoding),
    };
    try s.documents.append(s.gpa, d);
    try s.analyze(d);
}

fn change(s: *Server, params: json.Value) !void {
    const d = s.documentOf(params) orelse return;
    for (params.get("contentChanges").items()) |c| {
        const new = c.get("text").asString() orelse continue;
        const text = if (c.has("range")) blk: {
            const r = c.get("range");
            const from = d.lines.offset(.{ .line = r.get("start").get("line").asInt(u32) orelse 0, .character = r.get("start").get("character").asInt(u32) orelse 0 });
            const to = d.lines.offset(.{ .line = r.get("end").get("line").asInt(u32) orelse 0, .character = r.get("end").get("character").asInt(u32) orelse 0 });
            break :blk try std.mem.concat(s.gpa, u8, &.{ d.text[0..from], new, d.text[@max(from, to)..] });
        } else try s.gpa.dupe(u8, new);
        s.gpa.free(d.text);
        d.text = text;
        d.lines.deinit(s.gpa);
        d.lines = try .init(s.gpa, d.text, s.encoding);
    }
    d.version = params.get("textDocument").get("version").asInt(i64) orelse d.version;
    try s.analyze(d);
}

fn close(s: *Server, params: json.Value) !void {
    const d = s.documentOf(params) orelse return;
    try s.notify("textDocument/publishDiagnostics", .{ .uri = d.uri, .diagnostics = &nothing });
    _ = s.documents.swapRemove(std.mem.indexOfScalar(*Document, s.documents.items, d).?);
    s.free(d);
}

/// A file saved may be one the others import: each is compiled again.
fn saved(s: *Server) !void {
    for (s.documents.items) |d| try s.analyze(d);
}

fn analyze(s: *Server, d: *Document) !void {
    if (d.analysis) |a| a.deinit();
    d.analysis = null;
    d.analysis = Analysis.init(s.gpa, d.path, d.text, s.options()) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SetupFailed => null,
    };
    try s.publish(d);
}

fn options(s: *Server) service.Options {
    return .{
        .setup = .{ .context = s, .run = setup },
        .loader = .{ .context = s, .load = load },
        .io = s.io,
    };
}

fn setup(context: ?*anyopaque, vm: *Vm) anyerror!void {
    const s: *Server = @ptrCast(@alignCast(context.?));
    try os.install(vm, &s.host);
}

fn load(context: ?*anyopaque, gpa: Allocator, from: []const u8, path: []const u8) anyerror!Vm.Loader.Loaded {
    const s: *Server = @ptrCast(@alignCast(context.?));
    const dir = std.fs.path.dirname(from) orelse ".";
    const joined = if (std.fs.path.isAbsolute(path)) try gpa.dupe(u8, path) else try std.fs.path.join(gpa, &.{ dir, path });
    errdefer gpa.free(joined);
    for (s.documents.items) |d| if (uri.samePath(d.path, joined)) {
        return .{ .name = joined, .source = try gpa.dupe(u8, d.text) };
    };
    const source = try std.Io.Dir.cwd().readFileAlloc(s.io, joined, gpa, .limited(16 << 20));
    return .{ .name = joined, .source = source };
}

const LspDiagnostic = struct {
    range: Range,
    severity: u8,
    source: []const u8 = "flux",
    message: []const u8,
    related_information: ?[]const Related = null,
    pub const json_case = .camel;
};

const Related = struct { location: Location, message: []const u8 };

fn publish(s: *Server, d: *Document) !void {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list: std.ArrayList(LspDiagnostic) = .empty;
    if (d.analysis) |a| for (a.diagnostics.items.items) |*x| {
        if (!a.isHere(x)) continue;
        const at = x.primary() orelse diag.Location{ .file = a.file, .span = .empty };
        var message: std.Io.Writer.Allocating = .init(arena);
        try message.writer.writeAll(x.message);
        for (x.notes.items) |n| try message.writer.print("\nnote: {s}", .{n});
        if (x.help) |h| try message.writer.print("\nhelp: {s}", .{h});
        var related: std.ArrayList(Related) = .empty;
        for (x.labels.items) |l| {
            if (l.primary or l.at.file != a.file) continue;
            try related.append(arena, .{ .location = .{ .uri = d.uri, .range = rangeOf(&d.lines, l.at.span) }, .message = l.message });
        }
        try list.append(arena, .{
            .range = rangeOf(&d.lines, at.span),
            .severity = switch (x.severity) {
                .@"error" => 1,
                .warning => 2,
                .note => 3,
            },
            .message = message.written(),
            .related_information = if (related.items.len > 0) related.items else null,
        });
    };
    try s.notify("textDocument/publishDiagnostics", .{ .uri = d.uri, .version = d.version, .diagnostics = list.items });
}

// ---------------------------------------------------------------------------
// Requests

fn hover(s: *Server, arena: Allocator, id: json.Value, d: *Document, params: json.Value) !void {
    const a = d.analysis orelse return s.respond(id, @as(?u8, null));
    const h = (try a.hover(arena, offsetOf(d, params))) orelse return s.respond(id, @as(?u8, null));
    const text = if (h.doc) |doc|
        try std.fmt.allocPrint(arena, "```flux\n{s}\n```\n\n{s}", .{ h.code, doc })
    else
        try std.fmt.allocPrint(arena, "```flux\n{s}\n```", .{h.code});
    try s.respond(id, .{ .contents = Markup{ .value = text }, .range = rangeOf(&d.lines, h.span) });
}

fn completionKind(k: service.Kind) u8 {
    return switch (k) {
        .variable, .parameter => 6,
        .constant => 21,
        .function, .builtin_function, .@"test" => 3,
        .method, .builtin_method => 2,
        .field => 5,
        .signal => 23,
        .@"struct" => 22,
        .@"enum" => 13,
        .enum_member => 20,
        .module => 9,
        .builtin_type => 25,
        .property => 10,
        .keyword, .annotation => 14,
    };
}

const CompletionItem = struct {
    label: []const u8,
    kind: u8,
    detail: ?[]const u8,
    documentation: ?Markup,
    sort_text: []const u8,
    filter_text: []const u8,
    /// 2 for a snippet: `$0` where the cursor goes.
    insert_text_format: u8 = 1,
    text_edit: struct { range: Range, new_text: []const u8, pub const json_case = .camel; },
    pub const json_case = .camel;
};

/// What a completion puts in, as a snippet when it says where the cursor
/// goes: the text with `$`, `}` and `\` escaped, and `$0` there.
fn snippet(arena: Allocator, text: []const u8, caret: u32) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text, 0..) |ch, i| {
        if (i == caret) try out.appendSlice(arena, "$0");
        if (ch == '$' or ch == '}' or ch == '\\') try out.append(arena, '\\');
        try out.append(arena, ch);
    }
    if (caret >= text.len) try out.appendSlice(arena, "$0");
    return out.items;
}

fn completion(s: *Server, arena: Allocator, id: json.Value, d: *Document, params: json.Value) !void {
    const at = offsetOf(d, params);
    const found = service.complete(s.gpa, arena, d.path, d.text, at, s.options()) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SetupFailed => return s.respond(id, .{ .isIncomplete = false, .items = &nothing }),
    };
    const items = try arena.alloc(CompletionItem, found.items.len);
    const replace = rangeOf(&d.lines, .{ .start = found.start, .end = @max(found.end, at) });
    for (found.items, items) |i, *out| out.* = .{
        .label = i.label,
        .kind = completionKind(i.kind),
        .detail = if (i.detail.len > 0) i.detail else null,
        .documentation = if (i.doc) |doc| .{ .value = doc } else null,
        .sort_text = try std.fmt.allocPrint(arena, "{d}{s}", .{ i.rank, i.label }),
        // A whole method is found by its header, `fn input`, whether the
        // word replaced is `inp` or `fn inp`.
        .filter_text = if (i.insert) |text| text[0 .. std.mem.indexOfScalar(u8, text, '(') orelse text.len] else i.label,
        .insert_text_format = if (i.caret != null) 2 else 1,
        .text_edit = .{ .range = replace, .new_text = if (i.insert) |text| (if (i.caret) |caret| try snippet(arena, text, caret) else text) else i.label },
    };
    try s.respond(id, .{ .isIncomplete = false, .items = items });
}

fn signatureHelp(s: *Server, arena: Allocator, id: json.Value, d: *Document, params: json.Value) !void {
    const sig = (service.signatureHelp(s.gpa, arena, d.path, d.text, offsetOf(d, params), s.options()) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SetupFailed => null,
    }) orelse return s.respond(id, @as(?u8, null));
    const Parameter = struct { label: []const u8 };
    const list = try arena.alloc(Parameter, sig.params.len);
    for (sig.params, list) |p, *out| out.* = .{ .label = sig.label[p[0]..p[1]] };
    try s.respond(id, .{
        .signatures = &[_]struct { label: []const u8, documentation: ?Markup, parameters: []const Parameter }{.{
            .label = sig.label,
            .documentation = if (sig.doc) |doc| .{ .value = doc } else null,
            .parameters = list,
        }},
        .activeSignature = 0,
        .activeParameter = sig.active,
    });
}

/// Where a declaration is, in whichever file it is in.
fn locationOf(s: *Server, arena: Allocator, d: *Document, a: *const Analysis, at: diag.Location) !Location {
    if (at.file == a.file) return .{ .uri = d.uri, .range = rangeOf(&d.lines, at.span) };
    const file = a.vm.sources.get(at.file) orelse return .{ .uri = d.uri, .range = rangeOf(&d.lines, .empty) };
    var lines: Lines = try .init(s.gpa, file.text, s.encoding);
    defer lines.deinit(s.gpa);
    return .{ .uri = try uri.fromPath(arena, file.name), .range = rangeOf(&lines, at.span) };
}

fn definition(s: *Server, arena: Allocator, id: json.Value, d: *Document, params: json.Value) !void {
    const a = d.analysis orelse return s.respond(id, @as(?u8, null));
    const at = a.definition(offsetOf(d, params)) orelse return s.respond(id, @as(?u8, null));
    try s.respond(id, try s.locationOf(arena, d, a, at));
}

fn references(s: *Server, arena: Allocator, id: json.Value, d: *Document, params: json.Value) !void {
    const a = d.analysis orelse return s.respond(id, &nothing);
    const spans = try a.references(arena, offsetOf(d, params));
    const list = try arena.alloc(Location, spans.len);
    for (spans, list) |span, *out| out.* = .{ .uri = d.uri, .range = rangeOf(&d.lines, span) };
    try s.respond(id, list);
}

fn highlights(s: *Server, arena: Allocator, id: json.Value, d: *Document, params: json.Value) !void {
    const a = d.analysis orelse return s.respond(id, &nothing);
    const spans = try a.references(arena, offsetOf(d, params));
    const Highlight = struct { range: Range, kind: u8 = 1 };
    const list = try arena.alloc(Highlight, spans.len);
    for (spans, list) |span, *out| out.* = .{ .range = rangeOf(&d.lines, span) };
    try s.respond(id, list);
}

fn symbolKind(k: service.Kind) u8 {
    return switch (k) {
        .variable, .parameter => 13,
        .constant => 14,
        .function, .builtin_function, .@"test" => 12,
        .method, .builtin_method => 6,
        .field, .property => 8,
        .signal => 24,
        .@"struct" => 23,
        .@"enum" => 10,
        .enum_member => 22,
        .module => 2,
        .builtin_type => 26,
        .keyword, .annotation => 13,
    };
}

const DocumentSymbol = struct {
    name: []const u8,
    detail: []const u8,
    kind: u8,
    range: Range,
    selection_range: Range,
    children: []const DocumentSymbol,
    pub const json_case = .camel;
};

fn documentSymbols(s: *Server, arena: Allocator, id: json.Value, d: *Document, params: json.Value) !void {
    _ = params;
    const a = d.analysis orelse return s.respond(id, &nothing);
    try s.respond(id, try convertSymbols(arena, &d.lines, try a.symbols(arena)));
}

fn convertSymbols(arena: Allocator, lines: *const Lines, list: []const service.Symbol) Allocator.Error![]const DocumentSymbol {
    const out = try arena.alloc(DocumentSymbol, list.len);
    for (list, out) |x, *o| o.* = .{
        .name = x.name,
        .detail = x.detail,
        .kind = symbolKind(x.kind),
        .range = rangeOf(lines, x.whole.to(x.span)),
        .selection_range = rangeOf(lines, x.span),
        .children = try convertSymbols(arena, lines, x.children),
    };
    return out;
}

fn semanticTokens(s: *Server, arena: Allocator, id: json.Value, d: *Document, params: json.Value) !void {
    _ = params;
    const a = d.analysis orelse return s.respond(id, .{ .data = &[_]u32{} });
    const tokens = try service.highlight.tokens(a, arena);
    const data = try arena.alloc(u32, tokens.len * 5);
    var line: u32 = 0;
    var column: u32 = 0;
    for (tokens, 0..) |t, i| {
        const pos = d.lines.position(t.start);
        const delta_line = pos.line - line;
        data[i * 5 ..][0..5].* = .{
            delta_line,
            if (delta_line == 0) pos.character - column else pos.character,
            d.lines.units(t.start, t.start + t.len),
            @intFromEnum(t.type),
            @as(u8, @bitCast(t.modifiers)),
        };
        line = pos.line;
        column = pos.character;
    }
    try s.respond(id, .{ .data = data });
}
