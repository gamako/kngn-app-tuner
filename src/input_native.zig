//! Native microphone adapter for the tuner input stream.
//!
//! The kngn capture facade owns device lifecycle and the real-time callback contract.
//! This adapter only converts AudioInFrame delivery into the tuner's fixed-capacity ring.
//! Hot path: captureCallback is RT and performs only the bounded ring handoff.

const std = @import("std");
const kit = @import("kit");
const audio_ring = @import("audio_ring.zig");
const types = @import("input_types.zig");

pub const State = types.State;
pub const Kind = types.Kind;

pub const Input = struct {
    gpa: std.mem.Allocator,
    ring: *audio_ring.Ring,
    device: ?kit.audio.CaptureDevice = null,
    sample_rate: types.SampleRate = 48000,
    state: State = .stopped,

    pub fn init(gpa: std.mem.Allocator, ring: *audio_ring.Ring, kind: Kind) !Input {
        var result: Input = .{
            .gpa = gpa,
            .ring = ring,
            .state = if (kind == .tone) .ready else .requesting,
        };
        if (kind == .tone) return result;

        const permission = kit.audio.requestCapturePermission() catch |err| {
            result.state = .failed;
            return err;
        };
        if (permission != .granted) {
            result.state = if (permission == .denied or permission == .restricted) .denied else .failed;
            return error.PermissionDenied;
        }

        var device = try kit.audio.openCapture(gpa, .{
            .sample_rate = 48000,
            .channels = 1,
            .capture_callback = captureCallback,
            .userdata = ring,
        });
        errdefer device.close();
        try device.start();
        result.device = device;
        result.sample_rate = device.config().sample_rate;
        result.state = .ready;
        return result;
    }

    pub fn deinit(self: *Input) void {
        if (self.device) |device| device.close();
        self.device = null;
        self.state = .stopped;
    }

    pub fn stop(self: *Input) void {
        if (self.device) |device| device.stop();
        if (self.state == .ready) self.state = .stopped;
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

    pub fn enableWasmExports() void {}
};

fn captureCallback(frame: kit.audio.AudioInFrame, userdata: ?*anyopaque) void {
    const ring: *audio_ring.Ring = @ptrCast(@alignCast(userdata orelse return));
    ring.pushFrame(frame.samples, frame.frames, frame.channels);
}
