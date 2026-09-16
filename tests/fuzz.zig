// SPDX-License-Identifier: BSD-2-Clause

//! Sources the language has never seen, made by breaking ones it has: bytes
//! dropped or changed, lines doubled, tokens and whole pieces of
//! other files dropped in, brackets nested thousands deep. Each is compiled
//! and, if it compiles, run on a budget. Whatever happens must be a
//! diagnostic or a panic in the script - never a crash of the compiler or
//! the machine. An editor's questions are asked of each too, with the
//! cursor anywhere: colours, hovers, completions, signatures. The source
//! being tried is written to `zig-out/fuzz-last.flux` first, so a crash
//! leaves it behind.
//!
//!     zig build fuzz -- [rounds] [seed]

const std = @import("std");
const flux = @import("fluxion_script");

const tokens = [_][]const u8{
    "(",      ")",       "{",     "}",       "[",      "]",       ";",      ",",     ".",        ":",
    "fn ",    "struct ", "enum ", "var ",    "const ", "return ", "await ", "try ",  "catch ",   "orelse ",
    "if (",   "else ",   "for (", "while (", "switch", "|x| ",    "..",     "...",   "=>",       "?",
    "!",      "@",       "\"",    "f\"{",    "}\"",    "\\\\",    "0x",     "1e",    "9999999999999999999999", "-",
    "self",   "null",    "error.", "signal ", "extends ", "test ", "defer ", "=",    "+=",       ".?",
    "vec2(",  "[]",      "{}",    "int",     "?int",   "!int",    "any",    "_",     "\n",       "\t",
    "\u{e9}", "\xff",    "\x00",
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const rounds = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 5000;
    const seed = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 0xF1_05;

    var corpus: std.ArrayList([]u8) = .empty;
    defer {
        for (corpus.items) |c| gpa.free(c);
        corpus.deinit(gpa);
    }
    for ([_][]const u8{ "tests/scripts", "examples/scripts", "bench" }) |folder| {
        var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".flux")) continue;
            try corpus.append(gpa, try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)));
        }
    }
    if (corpus.items.len == 0) {
        std.debug.print("fuzz: no scripts found; run it from the repository's root\n", .{});
        return 1;
    }

    try std.Io.Dir.cwd().createDirPath(io, "zig-out");
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var compiled: usize = 0;
    var ran: usize = 0;
    for (0..rounds) |round| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(gpa);
        try source.appendSlice(gpa, corpus.items[random.uintLessThan(usize, corpus.items.len)]);
        for (0..1 + random.uintLessThan(usize, 4)) |_| try mutate(gpa, random, &source, corpus.items);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "zig-out/fuzz-last.flux", .data = source.items });

        if (round % 4 == 0) try ask(gpa, random, source.items);

        var sink: std.Io.Writer.Discarding = .init(&.{});
        const vm = try flux.Vm.create(gpa, .{ .out = &sink.writer, .max_bytes = 32 << 20, .max_frames = 2000 });
        defer vm.destroy();
        const module = vm.compile("fuzz.flux", source.items) catch continue;
        compiled += 1;
        vm.setBudget(100_000);
        if (vm.run(module)) |_| ran += 1 else |_| vm.clearPanic();
        for (0..4) |_| {
            vm.update(0.5) catch vm.clearPanic();
        }
        if (round % 500 == 0) std.debug.print("fuzz: {d} of {d}, {d} compiled, {d} ran to their end\n", .{ round, rounds, compiled, ran });
    }
    std.debug.print("fuzz: {d} sources, {d} compiled, {d} ran to their end, nothing crashed\n", .{ rounds, compiled, ran });
    return 0;
}

fn mutate(gpa: std.mem.Allocator, random: std.Random, source: *std.ArrayList(u8), corpus: []const []u8) !void {
    const len = source.items.len;
    const at = if (len == 0) 0 else random.uintLessThan(usize, len + 1);
    switch (random.uintLessThan(u8, 8)) {
        0 => if (len > 0) {
            const n = @min(len - @min(at, len - 1), 1 + random.uintLessThan(usize, 8));
            source.replaceRangeAssumeCapacity(@min(at, len - 1), n, &.{});
        },
        1, 2 => try source.insertSlice(gpa, at, tokens[random.uintLessThan(usize, tokens.len)]),
        3 => if (len > 0) {
            source.items[@min(at, len - 1)] = random.int(u8);
        },
        4 => {
            const other = corpus[random.uintLessThan(usize, corpus.len)];
            if (other.len == 0) return;
            const from = random.uintLessThan(usize, other.len);
            const n = @min(other.len - from, 1 + random.uintLessThan(usize, 200));
            try source.insertSlice(gpa, at, other[from .. from + n]);
        },
        5 => {
            // A line said twice.
            const a = lineAround(source.items, random.uintLessThan(usize, len + 1));
            const copy = try gpa.dupe(u8, source.items[a.start..a.end]);
            defer gpa.free(copy);
            try source.insertSlice(gpa, a.start, copy);
        },
        6 => {
            // Brackets and blocks nested deeper than any person writes them.
            const open = [_][]const u8{ "(", "[", "{", "-", "!", "[[", "f(" };
            const piece = open[random.uintLessThan(usize, open.len)];
            const depth = 1 + random.uintLessThan(usize, if (random.boolean()) 50 else 20_000);
            for (0..depth) |_| try source.insertSlice(gpa, at, piece);
        },
        else => if (len > 0) {
            const n = @min(len - @min(at, len - 1), 1 + random.uintLessThan(usize, 64));
            source.replaceRangeAssumeCapacity(@min(at, len - 1), n, "");
        },
    }
}

/// What an editor asks, with the cursor at a few places in the source.
fn ask(gpa: std.mem.Allocator, random: std.Random, source: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const service = flux.service;
    const a = try service.Analysis.init(gpa, "fuzz.flux", source, .{});
    defer a.deinit();
    _ = try service.highlight.tokens(a, arena);
    _ = try a.symbols(arena);
    for (0..3) |_| {
        const at: u32 = @intCast(random.uintAtMost(usize, source.len));
        _ = try a.hover(arena, at);
        _ = try a.references(arena, at);
        _ = try service.complete(gpa, arena, "fuzz.flux", source, at, .{});
        _ = try service.signatureHelp(gpa, arena, "fuzz.flux", source, at, .{});
    }
}

fn lineAround(text: []const u8, at: usize) struct { start: usize, end: usize } {
    var start = @min(at, text.len);
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    var end = @min(at, text.len);
    while (end < text.len and text[end] != '\n') end += 1;
    if (end < text.len) end += 1;
    return .{ .start = start, .end = end };
}
