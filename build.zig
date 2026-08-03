const std = @import("std");

// Vendored from kngn/build_helpers/. Keep these files byte-identical with the
// adjacent kngn checkout; the helper is the external-consumer linking surface.
const helpers = @import("build_helpers/consumer.zig");
const macos = @import("build_helpers/macos.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = helpers.resolveBackend(b, target);

    const dep = b.dependency("kngn", .{
        .target = target,
        .optimize = optimize,
        .platform = backend,
    });
    const sdk_paths: ?macos.MacOSSDKPaths = if (target.result.os.tag == .macos)
        macos.resolveMacOSSDKPaths(b, null, null)
    else
        null;

    const features: helpers.PlatformFeatures = .{ .enable_audio = true };
    const cli = addConsumerExe(b, dep, target, optimize, "tuner-cli", "src/cli.zig", backend, sdk_paths, features);
    b.installArtifact(cli);
    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli.addArgs(args);
    const run_cli_step = b.step("run-tuner-cli", "Run the tuner command-line prototype");
    run_cli_step.dependOn(&run_cli.step);

    const app = addConsumerExe(b, dep, target, optimize, "tuner", "src/main.zig", backend, sdk_paths, features);
    b.installArtifact(app);
    const run_app = b.addRunArtifact(app);
    run_app.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_app.addArgs(args);
    const run_app_step = b.step("run-tuner", "Run the chromatic tuner GUI");
    run_app_step.dependOn(&run_app.step);

    const pitch_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pitch.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_pitch_test = b.addRunArtifact(pitch_test);
    const test_pitch = b.step("test-pitch", "Run pitch detection unit tests");
    test_pitch.dependOn(&run_pitch_test.step);

    const ring_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audio_ring.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ring_test = b.addRunArtifact(ring_test);
    test_pitch.dependOn(&run_ring_test.step);

    const test_all = b.step("test", "Run tuner unit tests");
    test_all.dependOn(test_pitch);

    const input_types_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/input_types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_input_types_test = b.addRunArtifact(input_types_test);
    test_all.dependOn(&run_input_types_test.step);

    const input_web_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/input_web.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_input_web_test = b.addRunArtifact(input_web_test);
    test_all.dependOn(&run_input_web_test.step);

    // ----- wasm web package -----
    // The wasm app is reactor-style: kngn_init/kngn_frame are driven by browser rAF.
    // Microphone capture remains an experimental tuner-side host boundary for now; the
    // shipping package uses the tone source and keeps the capture exports available.
    const wasm_optimize: std.builtin.OptimizeMode = if (b.user_input_options.contains("optimize") or b.release_mode != .off)
        optimize
    else
        .ReleaseSmall;
    const wasi_target_query = std.Target.Query{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    };
    const wasm_dep = b.dependency("kngn", .{
        .target = b.resolveTargetQuery(wasi_target_query),
        .optimize = wasm_optimize,
    });

    var wasm_specs = [_]helpers.WasmAppSpec{
        .{
            .name = "tuner",
            .target_query = wasi_target_query,
            .app_source = b.path("src/main.zig"),
            .wasm_root_source = b.path("src/wasm_root.zig"),
            .wasm_root_import_name = "tuner_app",
            .imports = &.{.{ .name = "kit", .module = wasm_dep.module("kit") }},
            .audio = .none,
            .html_source = b.path("web/tuner.html"),
            .html_install_path = "web/tuner.html",
            .single_html = true,
            .single_html_basename = "tuner",
        },
    };

    _ = helpers.addWasmWebPackage(b, .{
        .apps = &wasm_specs,
        .assets = .{
            .js = dep.path("web/kngn.js"),
            .worklet = dep.path("web/kngn-worklet.js"),
            .headers = b.path("web/_headers"),
            .netlify = dep.path("web/deploy/netlify.toml"),
            .serve_script = dep.path("web/deploy/serve-coop-coep.py"),
            .packer = dep.path("cli/pack-single-html.zig"),
            .export_check = dep.path("cli/check-wasm-exports.zig"),
        },
        .optimize = wasm_optimize,
        .default_install = false,
        .create_package_step = true,
        .package_step_name = "package-web",
        .package_step_description = "Package tuner wasm multi-file web bundle to zig-out/web/",
        .create_single_package_step = true,
        .single_package_step_name = "package-web-single",
        .single_package_step_description = "Package tuner single-file HTML to zig-out/web/",
    });

    const gate_web_step = b.step("gate-web", "Web gate: package tuner wasm bundles");
    const package_web = b.top_level_steps.get("package-web") orelse @panic("package-web step missing");
    const package_web_single = b.top_level_steps.get("package-web-single") orelse @panic("package-web-single step missing");
    gate_web_step.dependOn(&package_web.step);
    gate_web_step.dependOn(&package_web_single.step);
}

fn addConsumerExe(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source: []const u8,
    backend: helpers.PlatformType,
    sdk_paths: ?macos.MacOSSDKPaths,
    features: helpers.PlatformFeatures,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("kit", dep.module("kit"));
    helpers.setupConsumerExe(b, exe, dep, backend, sdk_paths, features);
    return exe;
}
