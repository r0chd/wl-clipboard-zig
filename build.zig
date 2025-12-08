const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mime = b.dependency("mime", .{
        .target = target,
        .optimize = optimize,
    });

    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    scanner.addSystemProtocol("staging/ext-data-control/ext-data-control-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-data-control-unstable-v1.xml"));
    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_seat", 8);
    scanner.generate("ext_data_control_manager_v1", 1);
    scanner.generate("zwlr_data_control_manager_v1", 2);

    const mod = b.addModule("wl_clipboard", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.linkSystemLibrary("magic", .{});
    mod.link_libc = true;
    mod.addImport("mime", mime.module("mime"));
    mod.addImport("wayland", wayland);

    const wl_copy = b.addExecutable(.{
        .name = "wl-copy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wl-copy.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wl_clipboard", .module = mod },
            },
        }),
    });
    wl_copy.linkSystemLibrary("magic");
    wl_copy.linkLibC();
    wl_copy.linkSystemLibrary("wayland-client");
    b.installArtifact(wl_copy);

    const wl_paste = b.addExecutable(.{
        .name = "wl-paste",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wl-paste.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wl_clipboard", .module = mod },
            },
        }),
    });
    wl_paste.linkSystemLibrary("magic");
    wl_paste.linkLibC();
    wl_paste.linkSystemLibrary("wayland-client");
    b.installArtifact(wl_paste);

    const copy_step = b.step("copy", "Run wl-copy binary");
    const copy_cmd = b.addRunArtifact(wl_copy);
    copy_step.dependOn(&copy_cmd.step);
    copy_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        copy_cmd.addArgs(args);
    }

    const paste_step = b.step("paste", "Run wl-paste binary");
    const paste_cmd = b.addRunArtifact(wl_paste);
    paste_step.dependOn(&paste_cmd.step);
    paste_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        paste_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.root_module.linkSystemLibrary("wayland-client", .{});
    mod_tests.root_module.link_libc = true;

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const copy_tests = b.addTest(.{
        .root_module = wl_copy.root_module,
    });
    const run_copy_tests = b.addRunArtifact(copy_tests);

    const paste_tests = b.addTest(.{
        .root_module = wl_paste.root_module,
    });
    const run_paste_tests = b.addRunArtifact(paste_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_copy_tests.step);
    test_step.dependOn(&run_paste_tests.step);
}
