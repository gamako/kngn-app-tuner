//! WebAssembly input boundary for the tuner's browser capture experiment.
//!
//! Browser permission and AudioWorklet setup are asynchronous, so this adapter does not
//! pretend that kngn's native blocking permission call exists on wasm. The tuner web page
//! writes chunks into the exported fixed buffer and calls tuner_capture_submit().
//! Hot path: submit copies bounded PCM into the ring; it does not allocate, lock, or perform IO.

const std = @import("std");
const audio_ring = @import("audio_ring.zig");
const types = @import("input_types.zig");

pub const State = types.State;
pub const Kind = types.Kind;

const capture_buffer_capacity = 4096;
var capture_buffer: [capture_buffer_capacity]f32 = undefined;
var active_input: ?*Input = null;

pub const Input = struct {
    ring: *audio_ring.Ring,
    sample_rate: types.SampleRate = 48000,
    state: State = .stopped,

    pub fn init(_: std.mem.Allocator, ring: *audio_ring.Ring, kind: Kind) !Input {
        return .{
            .ring = ring,
            .state = if (kind == .microphone) .requesting else .ready,
        };
    }

    pub fn bind(self: *Input) void {
        active_input = self;
    }

    pub fn deinit(self: *Input) void {
        if (active_input == self) active_input = null;
        self.state = .stopped;
    }

    pub fn stop(self: *Input) void {
        self.state = .stopped;
    }

    pub fn pop(self: *Input, output: []f32) usize {
        return self.ring.pop(output);
    }

    pub fn sampleRate(self: *const Input) types.SampleRate {
        return self.sample_rate;
    }

    pub fn stateValue(self: *const Input) State {
        return self.state;
    }

    pub fn enableWasmExports() void {
        _ = &tuner_capture_buffer_ptr;
        _ = &tuner_capture_buffer_len;
        _ = &tuner_capture_get_state;
        _ = &tuner_capture_set_state;
        _ = &tuner_capture_submit;
    }
};

pub fn bind(input: *Input) void {
    input.bind();
}

export fn tuner_capture_buffer_ptr() u32 {
    return @intCast(@intFromPtr(&capture_buffer));
}

export fn tuner_capture_buffer_len() u32 {
    return capture_buffer.len;
}

export fn tuner_capture_get_state() u32 {
    const input = active_input orelse return 0;
    return switch (input.state) {
        .stopped => 0,
        .requesting => 1,
        .ready => 2,
        .denied => 3,
        .unsupported => 4,
        .failed => 5,
    };
}

export fn tuner_capture_set_state(code: u32) void {
    const input = active_input orelse return;
    input.state = switch (code) {
        0 => .stopped,
        1 => .requesting,
        2 => .ready,
        3 => .denied,
        4 => .unsupported,
        else => .failed,
    };
}

export fn tuner_capture_submit(frames: u32, channels: u32, sample_rate: u32) u32 {
    const input = active_input orelse return 0;
    if (channels == 0 or frames == 0) return 0;
    const total_u64 = @as(u64, frames) * @as(u64, channels);
    if (total_u64 > capture_buffer.len) return 0;
    const total: usize = @intCast(total_u64);
    input.ring.pushFrame(capture_buffer[0..total], frames, channels);
    input.sample_rate = sample_rate;
    input.state = .ready;
    return frames;
}

test "wasm capture submit forwards PCM through the common ring" {
    var ring: audio_ring.Ring = .{};
    var input = try Input.init(std.testing.allocator, &ring, .microphone);
    defer input.deinit();
    input.bind();

    capture_buffer[0..4].* = .{ 0.1, -0.2, 0.3, -0.4 };
    try std.testing.expectEqual(@as(u32, 4), tuner_capture_submit(4, 1, 44100));
    try std.testing.expectEqual(State.ready, input.stateValue());
    try std.testing.expectEqual(@as(u32, 44100), input.sampleRate());

    var output: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), input.pop(&output));
    try std.testing.expectEqualSlices(f32, capture_buffer[0..4], &output);
    try std.testing.expectEqual(@as(u32, 0), tuner_capture_submit(std.math.maxInt(u32), 2, 48000));
}
