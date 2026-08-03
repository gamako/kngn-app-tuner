//! Chromatic tuner GUI application.
//!
//! The GUI uses kngn's frame-driven Runtime(App). Audio acquisition is kept behind the
//! target-neutral input facade so the pitch analyzer sees the same mono PCM stream on native
//! and wasm. Hot path: capture callbacks only enqueue bounded samples; analysis and drawing run
//! once per frame on the application thread.

const std = @import("std");
const builtin = @import("builtin");
const kit = @import("kit");
const audio_ring = @import("audio_ring.zig");
const input = @import("input.zig");
const pitch = @import("pitch.zig");

const platform = kit.platform;
const app_runtime = kit.app_runtime;

const LaunchOptions = struct {
    input_kind: input.Kind = .microphone,
    frequency: f32 = 82.4069,
};

// Runtime(App) intentionally receives only (gpa, io). Native command-line options are parsed
// before runNative and copied into the next App instance; wasm uses the declared defaults.
var launch_options: LaunchOptions = .{};

const App = struct {
    pub const window = .{
        .w = 640,
        .h = 480,
        .title = "Chromatic Tuner",
    };

    gpa: std.mem.Allocator,
    mode: input.Kind,
    frequency: f32,
    ring: audio_ring.Ring = .{},
    input: input.Input,
    analyzer: pitch.Analyzer,
    ctx: kit.gui.Context,
    detection: pitch.Detection = .{ .status = .no_signal },
    meter_cents: f32 = 0,
    generated_samples: usize = 0,
    samples: [1024]f32 = undefined,
    running: bool = true,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        _ = io;
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        const requested_mode: input.Kind = if (comptime builtin.cpu.arch.isWasm()) .microphone else launch_options.input_kind;

        app.* = .{
            .gpa = gpa,
            .mode = requested_mode,
            .frequency = launch_options.frequency,
            .input = try input.Input.init(gpa, &app.ring, requested_mode),
            .analyzer = pitch.Analyzer.init(48000, pitch.default_a4),
            .ctx = kit.gui.Context.init(gpa, kit.gui.default_font),
        };
        input.bind(&app.input);
        app.analyzer = pitch.Analyzer.init(app.input.sampleRate(), pitch.default_a4);
        return app;
    }

    pub fn onWindowShutdown(self: *App, win: *platform.Window) void {
        _ = win;
        self.input.stop();
    }

    pub fn deinit(self: *App) void {
        self.input.deinit();
        self.ctx.deinit();
        self.gpa.destroy(self);
    }

    pub fn frame(self: *App, win: *platform.Window, now: f64) !bool {
        _ = now;
        const fb = win.lockFramebuffer() orelse return self.running;
        defer fb.unlock();

        // GUI events are frame-scoped: begin the frame before forwarding platform events.
        self.ctx.beginFrame(fb.width, fb.height);
        while (win.nextEvent()) |event| {
            switch (event) {
                .quit => self.running = false,
                .key_down => |key| {
                    if (key.key == .ESCAPE) self.running = false;
                },
                else => {},
            }
            if (kit.toGuiEvent(event)) |gui_event| self.ctx.pushEvent(gui_event);
        }

        self.consumeInput();
        kit.pixelops.fill32(fb.pixels, 0xFF_12_14_18);
        self.draw(fb.width, fb.height);
        self.ctx.endFrame();

        const target: kit.gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        kit.gui.render(target, &self.ctx.draw_list, self.ctx.font, 1.0);
        win.present();
        return self.running;
    }

    fn consumeInput(self: *App) void {
        if (self.mode == .tone) {
            const sample_rate: f64 = 48000;
            for (&self.samples, 0..) |*sample, i| {
                const sample_index = self.generated_samples + i;
                const phase = std.math.tau * @as(f64, self.frequency) * @as(f64, @floatFromInt(sample_index)) / sample_rate;
                sample.* = @floatCast(0.6 * @sin(phase));
            }
            self.generated_samples += self.samples.len;
            self.detection = self.analyzer.push(&self.samples) orelse self.detection;
            self.updateMeter();
            return;
        }

        const source_rate = self.input.sampleRate();
        if (source_rate != self.analyzer.sample_rate) {
            self.analyzer = pitch.Analyzer.init(source_rate, pitch.default_a4);
        }
        const count = self.input.pop(&self.samples);
        if (count != 0) self.detection = self.analyzer.push(self.samples[0..count]) orelse self.detection;
        self.updateMeter();
    }

    fn updateMeter(self: *App) void {
        const target = switch (self.detection.status) {
            .detected => self.detection.cents,
            .unstable, .no_signal => 0,
        };
        // The visual needle is intentionally damped so a noisy input remains readable.
        self.meter_cents += (target - self.meter_cents) * 0.22;
    }

    fn draw(self: *App, width: u32, height: u32) void {
        self.ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .{ 28, 28, 28, 28 },
            .gap = 18,
            .bg = kit.gui.Color.rgba(0x12, 0x14, 0x18, 0xFF),
        });
        self.ctx.labelEx("CHROMATIC TUNER", kit.gui.Color.rgba(0xB8, 0xC0, 0xD0, 0xFF));

        var note_buf: [64]u8 = undefined;
        const note_text = switch (self.detection.status) {
            .detected => std.fmt.bufPrint(&note_buf, "{s}{d}  {d:.2} Hz", .{
                self.detection.note_name,
                @divFloor(self.detection.midi_note, 12) - 1,
                self.detection.frequency_hz,
            }) catch "detected",
            .unstable => "Listening...",
            .no_signal => if (self.mode == .microphone and self.input.stateValue() == .requesting)
                "Waiting for microphone..."
            else
                "Play a note",
        };
        self.ctx.labelEx(note_text, kit.gui.Color.rgba(0xF0, 0xF2, 0xF7, 0xFF));

        var cents_buf: [64]u8 = undefined;
        const cents_text = switch (self.detection.status) {
            .detected => std.fmt.bufPrint(&cents_buf, "{d:.1} cents", .{self.detection.cents}) catch "cents",
            else => "-- cents",
        };
        const status_color = if (self.detection.status == .detected and @abs(self.detection.cents) <= 3.0)
            kit.gui.Color.rgba(0x62, 0xD8, 0x91, 0xFF)
        else
            kit.gui.Color.rgba(0xD0, 0xD5, 0xDF, 0xFF);
        self.ctx.labelEx(cents_text, status_color);
        self.ctx.custom(.{ .x = 584, .y = 154 }, drawMeter, @ptrCast(self));

        var source_buf: [96]u8 = undefined;
        const source = switch (self.mode) {
            .tone => std.fmt.bufPrint(&source_buf, "source: tone {d:.2} Hz", .{self.frequency}) catch "source: tone",
            .microphone => switch (self.input.stateValue()) {
                .requesting => "source: microphone (requesting)",
                .ready => "source: microphone",
                .denied => "source: microphone (denied)",
                .unsupported => "source: microphone (unsupported)",
                else => "source: microphone (stopped)",
            },
        };
        self.ctx.labelEx(source, kit.gui.Color.rgba(0x8A, 0x93, 0xA3, 0xFF));
        self.ctx.labelEx("ESC: quit", kit.gui.Color.rgba(0x70, 0x78, 0x88, 0xFF));
        self.ctx.endBox();

        _ = width;
        _ = height;
    }
};

fn drawMeter(ctx_ptr: *anyopaque, dl: *kit.gui.DrawList, rect: kit.gui.Rect) void {
    const app: *const App = @ptrCast(@alignCast(ctx_ptr));
    const background = kit.gui.Color.rgba(0x16, 0x1A, 0x22, 0xFF);
    const border = kit.gui.Color.rgba(0x2B, 0x35, 0x46, 0xFF);
    const dim = kit.gui.Color.rgba(0x67, 0x77, 0x8F, 0xFF);
    const bright = kit.gui.Color.rgba(0xB9, 0xC8, 0xE8, 0xFF);
    const target = kit.gui.Color.rgba(0x61, 0xE6, 0xA2, 0xFF);
    const warning = kit.gui.Color.rgba(0xFF, 0xC8, 0x66, 0xFF);

    dl.rectFilled(rect, background) catch @panic("tuner meter: DrawList OOM");
    dl.rectOutline(rect, border, 1) catch @panic("tuner meter: DrawList OOM");

    const cx = rect.x + @as(i32, @intCast(rect.w / 2));
    const cy = rect.y + @as(i32, @intCast(rect.h - 24));
    const radius: i32 = @intCast(@min(rect.w / 2 - 42, rect.h - 34));
    const segment_count: usize = 24;

    var segment: usize = 0;
    while (segment < segment_count) : (segment += 1) {
        const left_cents = -50.0 + @as(f32, @floatFromInt(segment)) * 100.0 / @as(f32, segment_count);
        const right_cents = -50.0 + @as(f32, @floatFromInt(segment + 1)) * 100.0 / @as(f32, segment_count);
        const midpoint = (left_cents + right_cents) * 0.5;
        const p0 = meterPoint(cx, cy, radius, left_cents);
        const p1 = meterPoint(cx, cy, radius, right_cents);
        const color = if (@abs(midpoint) <= 6.0)
            target
        else if (@abs(midpoint) <= 16.0)
            warning
        else
            dim;
        const thickness: u32 = if (@abs(midpoint) <= 6.0) 4 else 2;
        dl.line(p0, p1, color, thickness) catch @panic("tuner meter: DrawList OOM");
    }

    const ticks = [_]f32{ -50, -25, -10, -5, 0, 5, 10, 25, 50 };
    for (ticks) |cents| {
        const outer = meterPoint(cx, cy, radius + 9, cents);
        const inner = meterPoint(cx, cy, radius - 8, cents);
        const tick_color = if (cents == 0) target else bright;
        dl.line(inner, outer, tick_color, if (cents == 0) 3 else 1) catch @panic("tuner meter: DrawList OOM");
    }

    const needle_cents = std.math.clamp(app.meter_cents, -50.0, 50.0);
    const needle_color = switch (app.detection.status) {
        .detected => if (@abs(app.detection.cents) <= 3.0) target else warning,
        .unstable => bright,
        .no_signal => kit.gui.Color.rgba(0x67, 0x77, 0x8F, 0x88),
    };
    const tip = meterPoint(cx, cy, radius - 15, needle_cents);
    dl.line(.{ .x = cx + 1, .y = cy + 1 }, .{ .x = tip.x + 1, .y = tip.y + 1 }, kit.gui.Color.rgba(0, 0, 0, 0x88), 5) catch
        @panic("tuner meter: DrawList OOM");
    dl.line(.{ .x = cx, .y = cy }, tip, needle_color, 3) catch @panic("tuner meter: DrawList OOM");
    fillDisc(dl, cx, cy, 9, kit.gui.Color.rgba(0x61, 0xE6, 0xA2, 0x30));
    fillDisc(dl, cx, cy, 5, kit.gui.Color.rgba(0x61, 0xE6, 0xA2, 0xA0));
    fillDisc(dl, cx, cy, 2, needle_color);

    dl.text(.{ .x = rect.x + 14, .y = rect.y + @as(i32, @intCast(rect.h)) - 18 }, "FLAT", dim) catch @panic("tuner meter: DrawList OOM");
    dl.text(.{ .x = cx - 4, .y = rect.y + @as(i32, @intCast(rect.h)) - 18 }, "0", target) catch @panic("tuner meter: DrawList OOM");
    dl.text(.{ .x = rect.x + @as(i32, @intCast(rect.w)) - 48, .y = rect.y + @as(i32, @intCast(rect.h)) - 18 }, "SHARP", dim) catch
        @panic("tuner meter: DrawList OOM");
}

fn meterPoint(cx: i32, cy: i32, radius: i32, cents: f32) kit.gui.Vec2 {
    const angle = (50.0 - @as(f64, @floatCast(cents))) / 100.0 * std.math.pi;
    return .{
        .x = cx + @as(i32, @intFromFloat(@round(@cos(angle) * @as(f64, @floatFromInt(radius))))),
        .y = cy - @as(i32, @intFromFloat(@round(@sin(angle) * @as(f64, @floatFromInt(radius))))),
    };
}

fn fillDisc(dl: *kit.gui.DrawList, cx: i32, cy: i32, radius: i32, color: kit.gui.Color) void {
    var y: i32 = -radius;
    while (y <= radius) : (y += 1) {
        const remaining = radius * radius - y * y;
        if (remaining <= 0) continue;
        const half_width: i32 = @intFromFloat(@sqrt(@as(f32, @floatFromInt(remaining))));
        dl.rectFilled(.{
            .x = cx - half_width,
            .y = cy + y,
            .w = @intCast(half_width * 2 + 1),
            .h = 1,
        }, color) catch @panic("tuner meter: DrawList OOM");
    }
}

fn parseArgs(it: *std.process.Args.Iterator) !LaunchOptions {
    var result: LaunchOptions = .{};
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--input")) {
            const value = it.next() orelse return error.InvalidInput;
            if (std.mem.eql(u8, value, "tone")) {
                result.input_kind = .tone;
            } else if (std.mem.eql(u8, value, "mic")) {
                result.input_kind = .microphone;
            } else return error.InvalidInput;
        } else if (std.mem.eql(u8, arg, "--frequency")) {
            result.frequency = std.fmt.parseFloat(f32, it.next() orelse return error.InvalidFrequency) catch return error.InvalidFrequency;
        } else if (std.mem.eql(u8, arg, "--help")) {
            usage();
        } else return error.UnknownArgument;
    }
    if (result.frequency <= 0) return error.InvalidFrequency;
    return result;
}

fn usage() noreturn {
    std.debug.print("Usage: zig build run-tuner -- [--input tone|mic] [--frequency Hz]\n", .{});
    std.process.exit(2);
}

const Rt = app_runtime.Runtime(App);

pub fn enableWasmRuntime() void {
    Rt.enableWasmExports();
    input.enableWasmExports();
}

pub fn main(process_init: std.process.Init) !void {
    if (comptime builtin.cpu.arch.isWasm()) return;
    var it = try std.process.Args.Iterator.initAllocator(process_init.minimal.args, process_init.gpa);
    defer it.deinit();
    _ = it.next();
    launch_options = parseArgs(&it) catch usage();
    try Rt.runNative(process_init);
}
