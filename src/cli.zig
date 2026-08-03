//! Command-line tuner prototype.
//!
//! The three input modes deliberately converge on the same `pitch.Analyzer`:
//! deterministic tone generation, WAV fixtures and live microphone capture.

const std = @import("std");
const kit = @import("kit");
const audio_ring = @import("audio_ring.zig");
const pitch = @import("pitch.zig");
const wav = @import("wav.zig");

const Input = enum { tone, file, mic };
const Output = enum { text, json };

const Args = struct {
    input: Input = .tone,
    output: Output = .text,
    file_path: ?[]const u8 = null,
    frequency: f32 = 82.4069,
    duration: f32 = 2.0,
    a4: f32 = pitch.default_a4,
    expect_note: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next();

    const args = parseArgs(&it) catch |err| {
        usage(@errorName(err));
    };

    var matched = false;
    switch (args.input) {
        .tone => try runTone(args, &matched),
        .file => try runFile(init, args, &matched),
        .mic => try runMic(init, args, &matched),
    }
    if (args.expect_note != null and !matched) {
        std.log.err("expected note was not detected: {s}", .{args.expect_note.?});
        return error.ExpectationFailed;
    }
}

fn parseArgs(it: *std.process.Args.Iterator) !Args {
    var result: Args = .{};
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--input")) {
            const value = it.next() orelse return error.MissingInput;
            if (std.mem.eql(u8, value, "tone")) {
                result.input = .tone;
            } else if (std.mem.eql(u8, value, "file")) {
                result.input = .file;
                result.file_path = it.next() orelse return error.MissingFile;
            } else if (std.mem.eql(u8, value, "mic")) {
                result.input = .mic;
            } else {
                return error.InvalidInput;
            }
        } else if (std.mem.eql(u8, arg, "--frequency")) {
            result.frequency = std.fmt.parseFloat(f32, it.next() orelse return error.MissingFrequency) catch return error.InvalidFrequency;
        } else if (std.mem.eql(u8, arg, "--duration")) {
            result.duration = std.fmt.parseFloat(f32, it.next() orelse return error.MissingDuration) catch return error.InvalidDuration;
        } else if (std.mem.eql(u8, arg, "--a4")) {
            result.a4 = std.fmt.parseFloat(f32, it.next() orelse return error.MissingA4) catch return error.InvalidA4;
        } else if (std.mem.eql(u8, arg, "--expect-note")) {
            result.expect_note = it.next() orelse return error.MissingExpectedNote;
        } else if (std.mem.eql(u8, arg, "--json")) {
            result.output = .json;
        } else if (std.mem.eql(u8, arg, "--help")) {
            usage(null);
        } else {
            return error.UnknownArgument;
        }
    }
    if (result.duration <= 0 or result.duration > 3600) return error.InvalidDuration;
    if (result.frequency <= 0) return error.InvalidFrequency;
    if (result.a4 <= 0) return error.InvalidA4;
    if (result.input == .file and result.file_path == null) return error.MissingFile;
    return result;
}

fn runTone(args: Args, matched: *bool) !void {
    const sample_rate: u32 = 48000;
    var analyzer = pitch.Analyzer.init(sample_rate, args.a4);
    const sample_count: usize = @intFromFloat(args.duration * @as(f32, @floatFromInt(sample_rate)));
    var processed: usize = 0;
    var samples: [512]f32 = undefined;
    while (processed < sample_count) {
        const count = @min(samples.len, sample_count - processed);
        for (samples[0..count], 0..) |*sample, i| {
            const sample_index = processed + i;
            const phase = std.math.tau * @as(f64, args.frequency) * @as(f64, @floatFromInt(sample_index)) /
                @as(f64, @floatFromInt(sample_rate));
            sample.* = @floatCast(0.6 * @sin(phase));
        }
        if (analyzer.push(samples[0..count])) |detection| emit(detection, args, matched);
        processed += count;
    }
}

fn runFile(init: std.process.Init, args: Args, matched: *bool) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args.file_path.?, init.gpa, .limited(256 * 1024 * 1024));
    defer init.gpa.free(bytes);
    var reader = try wav.Reader.parse(bytes);
    var analyzer = pitch.Analyzer.init(reader.sample_rate, args.a4);
    var samples: [512]f32 = undefined;
    while (true) {
        const count = reader.readMono(&samples);
        if (count == 0) break;
        if (analyzer.push(samples[0..count])) |detection| emit(detection, args, matched);
    }
}

fn runMic(init: std.process.Init, args: Args, matched: *bool) !void {
    try kit.platform.init();
    defer kit.platform.shutdown();

    const permission = try kit.audio.requestCapturePermission();
    if (permission != .granted) {
        std.log.err("microphone permission is {s}", .{@tagName(permission)});
        return error.PermissionDenied;
    }

    var ring: audio_ring.Ring = .{};
    var device = try kit.audio.openCapture(init.gpa, .{
        .sample_rate = 48000,
        .channels = 1,
        .capture_callback = captureCallback,
        .userdata = &ring,
    });
    defer device.close();
    try device.start();

    const effective = device.config();
    var analyzer = pitch.Analyzer.init(effective.sample_rate, args.a4);
    var samples: [1024]f32 = undefined;
    const ticks: usize = @intFromFloat(args.duration * 100.0);
    var tick: usize = 0;
    while (tick < ticks) : (tick += 1) {
        const count = ring.pop(&samples);
        if (count != 0) {
            if (analyzer.push(samples[0..count])) |detection| emit(detection, args, matched);
        }
        kit.platform.sleep(10 * std.time.ns_per_ms);
    }
    std.debug.print("captured samples dropped={d}\n", .{ring.droppedCount()});
}

fn captureCallback(frame: kit.audio.AudioInFrame, userdata: ?*anyopaque) void {
    const ring: *audio_ring.Ring = @ptrCast(@alignCast(userdata.?));
    ring.pushFrame(frame.samples, frame.frames, frame.channels);
}

fn emit(detection: pitch.Detection, args: Args, matched: *bool) void {
    if (detection.status != .detected) return;
    var note_buf: [16]u8 = undefined;
    const octave = @divFloor(detection.midi_note, 12) - 1;
    const full_note = std.fmt.bufPrint(&note_buf, "{s}{d}", .{ detection.note_name, octave }) catch detection.note_name;
    if (args.expect_note) |expected| {
        if (std.mem.eql(u8, expected, detection.note_name) or std.mem.eql(u8, expected, full_note)) matched.* = true;
    }
    switch (args.output) {
        .text => std.debug.print(
            "note={s} frequency={d:.3}Hz cents={d:.2} confidence={d:.3} rms={d:.4}\n",
            .{ full_note, detection.frequency_hz, detection.cents, detection.confidence, detection.rms },
        ),
        .json => std.debug.print(
            "{{\"note\":\"{s}\",\"frequency_hz\":{d:.3},\"cents\":{d:.2},\"confidence\":{d:.3},\"rms\":{d:.4}}}\n",
            .{ full_note, detection.frequency_hz, detection.cents, detection.confidence, detection.rms },
        ),
    }
}

fn usage(reason: ?[]const u8) noreturn {
    if (reason) |message| std.debug.print("tuner-cli: {s}\n\n", .{message});
    std.debug.print(
        "Usage: zig build run-tuner-cli -- [options]\\n\\n" ++
            "  --input tone [--frequency Hz]\\n" ++
            "  --input file PATH\\n" ++
            "  --input mic\\n" ++
            "  --duration SECONDS\\n" ++
            "  --a4 Hz\\n" ++
            "  --expect-note NAME\\n" ++
            "  --json\\n",
        .{},
    );
    std.process.exit(2);
}
