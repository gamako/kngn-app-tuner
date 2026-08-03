//! Platform-independent chromatic pitch detection for the tuner prototype.
//!
//! Hot path declaration: `Analyzer.push` is called for every captured sample block on
//! the main thread. It is not called from the microphone real-time callback. The
//! callback only copies samples into a fixed SPSC ring owned by the caller.

const std = @import("std");

pub const window_size = 8192;
pub const hop_size = 2048;
pub const min_frequency: f32 = 60.0;
pub const max_frequency: f32 = 500.0;
pub const default_a4: f32 = 440.0;

pub const Status = enum {
    no_signal,
    unstable,
    detected,
};

pub const Detection = struct {
    status: Status,
    frequency_hz: f32 = 0,
    midi_note: i32 = 0,
    note_name: []const u8 = "",
    cents: f32 = 0,
    confidence: f32 = 0,
    rms: f32 = 0,
};

pub const Analyzer = struct {
    sample_rate: u32,
    a4: f32,
    window: [window_size]f32 = @splat(0),
    filled: usize = 0,

    pub fn init(sample_rate: u32, a4: f32) Analyzer {
        return .{ .sample_rate = sample_rate, .a4 = a4 };
    }

    /// Push mono samples and return the newest result, if a complete analysis window finished.
    pub fn push(self: *Analyzer, samples: []const f32) ?Detection {
        var result: ?Detection = null;
        for (samples) |sample| {
            self.window[self.filled] = sample;
            self.filled += 1;
            if (self.filled < window_size) continue;

            result = self.analyze();
            var i: usize = 0;
            while (i < window_size - hop_size) : (i += 1) {
                self.window[i] = self.window[i + hop_size];
            }
            self.filled = window_size - hop_size;
        }
        return result;
    }

    fn analyze(self: *const Analyzer) Detection {
        var mean: f32 = 0;
        for (self.window) |sample| mean += sample;
        mean /= @as(f32, window_size);

        var energy: f32 = 0;
        for (self.window) |sample| {
            const centered = sample - mean;
            energy += centered * centered;
        }
        const rms = @sqrt(energy / @as(f32, window_size));
        if (rms < 0.008) return .{ .status = .no_signal, .rms = rms };

        const min_lag = @max(@as(usize, 2), @as(usize, self.sample_rate / @as(u32, @intFromFloat(max_frequency))));
        const max_lag = @min(window_size - 2, @as(usize, self.sample_rate / @as(u32, @intFromFloat(min_frequency))));
        if (min_lag >= max_lag) return .{ .status = .unstable, .rms = rms };

        var best_lag = min_lag;
        var best_corr: f32 = -std.math.inf(f32);
        var best_score: f32 = -std.math.inf(f32);
        var lag = min_lag;
        while (lag <= max_lag) : (lag += 1) {
            var corr: f32 = 0;
            var i: usize = 0;
            while (i < window_size - lag) : (i += 1) {
                corr += (self.window[i] - mean) * (self.window[i + lag] - mean);
            }
            const score = corr / @as(f32, @floatFromInt(window_size - lag));
            if (score > best_score) {
                best_score = score;
                best_corr = corr;
                best_lag = lag;
            }
        }

        const confidence = best_corr / energy;
        if (confidence < 0.18) return .{ .status = .unstable, .confidence = confidence, .rms = rms };

        const y0 = normalizedCorrelation(self, mean, best_lag - 1);
        const y1 = best_score;
        const y2 = normalizedCorrelation(self, mean, best_lag + 1);
        const denominator = y0 - 2.0 * y1 + y2;
        const correction = if (@abs(denominator) > 1e-9) 0.5 * (y0 - y2) / denominator else 0;
        const refined_lag = @as(f32, @floatFromInt(best_lag)) + std.math.clamp(correction, -0.5, 0.5);
        const frequency = @as(f32, @floatFromInt(self.sample_rate)) / refined_lag;
        if (frequency < min_frequency or frequency > max_frequency) {
            return .{ .status = .unstable, .confidence = confidence, .rms = rms };
        }

        const midi_float = 69.0 + 12.0 * std.math.log2(frequency / self.a4);
        var midi: i32 = @intFromFloat(@round(midi_float));
        if (midi < 0) midi = 0;
        if (midi > 127) midi = 127;
        const target = targetFrequency(midi, self.a4);
        return .{
            .status = .detected,
            .frequency_hz = frequency,
            .midi_note = midi,
            .note_name = noteName(midi),
            .cents = 1200.0 * std.math.log2(frequency / target),
            .confidence = confidence,
            .rms = rms,
        };
    }

    fn correlation(self: *const Analyzer, mean: f32, lag: usize) f32 {
        var corr: f32 = 0;
        var i: usize = 0;
        while (i < window_size - lag) : (i += 1) {
            corr += (self.window[i] - mean) * (self.window[i + lag] - mean);
        }
        return corr;
    }

    fn normalizedCorrelation(self: *const Analyzer, mean: f32, lag: usize) f32 {
        return self.correlation(mean, lag) / @as(f32, @floatFromInt(window_size - lag));
    }
};

const note_names = [_][]const u8{
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
};

pub fn noteName(midi: i32) []const u8 {
    const index: usize = @intCast(@mod(midi, 12));
    const octave: i32 = @divFloor(midi, 12) - 1;
    _ = octave;
    return note_names[index];
}

pub fn targetFrequency(midi: i32, a4: f32) f32 {
    const semitones = @as(f32, @floatFromInt(midi - 69)) / 12.0;
    return a4 * @exp2(semitones);
}

fn detectTone(frequency: f32) !Detection {
    var analyzer = Analyzer.init(48000, default_a4);
    var samples: [8192]f32 = undefined;
    for (&samples, 0..) |*sample, i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        sample.* = 0.6 * @sin(std.math.tau * frequency * t);
    }
    var result: ?Detection = null;
    var offset: usize = 0;
    while (offset < samples.len) : (offset += 256) {
        result = analyzer.push(samples[offset..@min(offset + 256, samples.len)]) orelse result;
    }
    return result orelse error.NoDetection;
}

test "chromatic note names and target frequencies use twelve-tone equal temperament" {
    try std.testing.expectEqualStrings("E", noteName(64));
    try std.testing.expectEqualStrings("A", noteName(69));
    try std.testing.expectApproxEqAbs(@as(f32, 82.4069), targetFrequency(40, default_a4), 0.01);
}

test "autocorrelation detects low E" {
    const detection = try detectTone(82.4069);
    try std.testing.expectEqual(Status.detected, detection.status);
    try std.testing.expectEqualStrings("E", detection.note_name);
    try std.testing.expectApproxEqAbs(@as(f32, 0), detection.cents, 4.0);
    try std.testing.expect(detection.confidence > 0.18);
}

test "autocorrelation detects a sharp A" {
    const frequency = targetFrequency(69, default_a4) * @exp2(10.0 / 1200.0);
    const detection = try detectTone(frequency);
    try std.testing.expectEqual(Status.detected, detection.status);
    try std.testing.expectEqualStrings("A", detection.note_name);
    try std.testing.expectApproxEqAbs(@as(f32, 10), detection.cents, 2.0);
}

test "silence is not reported as a note" {
    var analyzer = Analyzer.init(48000, default_a4);
    var silence: [window_size]f32 = @splat(0);
    const detection = analyzer.push(&silence).?;
    try std.testing.expectEqual(Status.no_signal, detection.status);
}
