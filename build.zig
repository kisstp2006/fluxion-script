// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = scriptModule(b, target, optimize);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fluxion_script", .module = mod }},
    });
    const cli = b.addExecutable(.{ .name = "flux", .root_module = cli_mod });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli.addArgs(args);
    b.step("run", "Run the flux command line: zig build run -- run file.flux").dependOn(&run_cli.step);

    // The C library: `zig build` installs it with its header, for a program
    // written in C or C++ to link.
    const lib = b.addLibrary(.{
        .name = "fluxion_script",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.addWriteFiles().add("fluxion_script_c.zig",
                \\comptime {
                \\    _ = @import("fluxion_script").c;
                \\}
            ),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fluxion_script", .module = mod }},
        }),
    });
    lib.installHeadersDirectory(b.path("include"), "", .{});
    b.installArtifact(lib);

    // The embedding examples: a Zig host on the module, a C host on the
    // library and its header.
    const examples = b.step("examples", "Build the embedding examples");
    const embed = b.addExecutable(.{
        .name = "embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/embed/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fluxion_script", .module = mod }},
        }),
    });
    examples.dependOn(&b.addInstallArtifact(embed, .{}).step);
    b.step("example-embed", "Run the Zig embedding example").dependOn(&b.addRunArtifact(embed).step);

    const embed_c_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    embed_c_mod.addCSourceFile(.{ .file = b.path("examples/embed/main.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    embed_c_mod.addIncludePath(b.path("include"));
    embed_c_mod.linkLibrary(lib);
    const embed_c = b.addExecutable(.{ .name = "embed-c", .root_module = embed_c_mod });
    examples.dependOn(&b.addInstallArtifact(embed_c, .{}).step);
    b.step("example-embed-c", "Run the C embedding example").dependOn(&b.addRunArtifact(embed_c).step);

    // Broken sources by the thousand: `zig build fuzz -- [rounds] [seed]`.
    const fuzz = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fluxion_script", .module = mod }},
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz);
    run_fuzz.setCwd(b.path("."));
    if (b.args) |args| run_fuzz.addArgs(args);
    b.step("fuzz", "Compile and run broken sources until something crashes").dependOn(&run_fuzz.step);

    const test_step = b.step("test", "Run the test suite");
    // The examples compile with the tests, so they cannot fall behind.
    test_step.dependOn(&embed.step);
    test_step.dependOn(&embed_c.step);

    // The mini IDE. Only when this is the package being built - as another's
    // dependency, the packages it draws with are never asked for - and for a
    // desktop, where it has a window to open.
    const desktop = switch (target.result.os.tag) {
        .windows, .linux, .macos => true,
        else => false,
    };
    // The code editor's view on fluxion-ui, `fluxion_script_ui`: when this is
    // the package being built, or when a dependant asks for it with
    // `.ui = true`. Nobody else fetches fluxion-ui for it.
    const ui_wanted = b.option(bool, "ui", "Make fluxion_script_ui, the code editor's view on fluxion-ui") orelse (b.pkg_hash.len == 0);
    const ui_mod = if (ui_wanted) uiModule(b, target, optimize, mod) else null;
    if (b.pkg_hash.len == 0) if (ui_mod) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "fluxion-script-ui-tests", .root_module = m })).step);
    };
    if (b.pkg_hash.len == 0 and desktop) if (ui_mod) |m| ide(b, target, optimize, mod, m, examples, test_step);
    const suite = b.addTest(.{ .name = "fluxion-script-tests", .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(suite).step);

    const scripts = b.addTest(.{
        .name = "fluxion-script-script-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/scripts.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fluxion_script", .module = mod }},
        }),
    });
    const run_scripts = b.addRunArtifact(scripts);
    run_scripts.setCwd(b.path("tests"));
    test_step.dependOn(&run_scripts.step);

    const c_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "fluxion_script", .module = mod }},
    });
    c_test_mod.addIncludePath(b.path("include"));
    c_test_mod.addCSourceFiles(.{
        .root = b.path("tests/c"),
        .files = &.{"api.c"},
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "fluxion-script-c-tests", .root_module = c_test_mod })).step);
}

/// `zig build ide -- [file.flux]`: an editor for Flux on fluxion-ui, with
/// the language service under it. Its four packages are lazy, and all four
/// are asked for before any is used, so a clean checkout fetches them in one
/// go; until they are here the step is left out.
/// `fluxion_script_ui`: `flux.edit` drawn with fluxion-ui. Null until
/// fluxion-ui is fetched.
fn uiModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mod: *std.Build.Module) ?*std.Build.Module {
    const ui = b.lazyDependency("fluxion_ui", .{ .target = target, .optimize = optimize }) orelse return null;
    return b.addModule("fluxion_script_ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_script", .module = mod },
            .{ .name = "fluxion_ui", .module = ui.module("fluxion_ui") },
        },
    });
}

fn ide(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mod: *std.Build.Module, ui_mod: *std.Build.Module, examples: *std.Build.Step, test_step: *std.Build.Step) void {
    const ui = b.lazyDependency("fluxion_ui", .{ .target = target, .optimize = optimize });
    const platform = b.lazyDependency("fluxion_platform", .{ .target = target, .optimize = optimize });
    const rhi = b.lazyDependency("fluxion_rhi", .{ .target = target, .optimize = optimize });
    const font = b.lazyDependency("fluxion_font", .{ .target = target, .optimize = optimize });
    if (ui == null or platform == null or rhi == null or font == null) return;
    const text = b.dependency("fluxion_text", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "flux-ide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/ide/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluxion_script", .module = mod },
                .{ .name = "fluxion_script_ui", .module = ui_mod },
                .{ .name = "fluxion_ui", .module = ui.?.module("fluxion_ui") },
                .{ .name = "fluxion_ui_rhi", .module = ui.?.module("fluxion_ui_rhi") },
                .{ .name = "fluxion_platform", .module = platform.?.module("fluxion_platform") },
                .{ .name = "fluxion_rhi", .module = rhi.?.module("fluxion_rhi") },
                .{ .name = "fluxion_font", .module = font.?.module("fluxion_font") },
                .{ .name = "fluxion_text", .module = text.module("fluxion_text") },
            },
        }),
    });
    examples.dependOn(&b.addInstallArtifact(exe, .{}).step);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("ide", "Run the mini IDE: zig build ide -- [file.flux]").dependOn(&run.step);
    // Built with the tests, and its editing tested, without a window.
    test_step.dependOn(&exe.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "flux-ide-tests", .root_module = exe.root_module })).step);
}

fn scriptModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const text = b.dependency("fluxion_text", .{ .target = target, .optimize = optimize });
    const hash = b.dependency("fluxion_hash", .{ .target = target, .optimize = optimize });
    const json = b.dependency("fluxion_json", .{ .target = target, .optimize = optimize });
    const reflect = b.dependency("fluxion_reflect", .{ .target = target, .optimize = optimize });
    const options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_text", .module = text.module("fluxion_text") },
            .{ .name = "fluxion_hash", .module = hash.module("fluxion_hash") },
            .{ .name = "fluxion_json", .module = json.module("fluxion_json") },
            .{ .name = "fluxion_reflect", .module = reflect.module("fluxion_reflect") },
        },
    };
    if (b.modules.get("fluxion_script") == null) return b.addModule("fluxion_script", options);
    return b.createModule(options);
}
