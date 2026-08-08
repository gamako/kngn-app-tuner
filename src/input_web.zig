//! WebAssembly input boundary for the tuner's browser capture.
//!
//! Microphone capture goes through kngn's own wasm capture backend (`kit.audio`) rather
//! than a tuner-specific bridge: kngn's `requestCapturePermission()` is an idempotent
//! poll on wasm (it starts the async browser permission request and returns
//! `not_determined` until it settles), so `Input.poll()` is called once per frame until
//! the device opens. Once open, delivery mirrors the native adapter exactly (same
//! `kit.audio.CaptureDevice`, same `AudioInFrame` callback contract).
//! Hot path: `captureCallback` only enqueues bounded samples onto the tuner's ring; it
//! does not allocate, lock, perform IO or panic.

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
    open_attempted: bool = false,

    pub fn init(gpa: std.mem.Allocator, ring: *audio_ring.Ring, kind: Kind) !Input {
        var result: Input = .{
            .gpa = gpa,
            .ring = ring,
            .state = if (kind == .tone) .ready else .requesting,
        };
        if (kind == .tone) return result;
        result.poll();
        return result;
    }

    /// Advance the permission/open state machine. A no-op once `.ready`, `.denied`,
    /// `.unsupported` or `.failed`. Call once per frame while `.requesting`.
    pub fn poll(self: *Input) void {
        if (self.state != .requesting) return;

        const permission = kit.audio.requestCapturePermission() catch |err| {
            self.state = switch (err) {
                error.PermissionDenied => .denied,
                error.Unsupported => .unsupported,
                else => .failed,
            };
            return;
        };

        switch (permission) {
            .not_determined => {},
            .denied, .restricted => self.state = .denied,
            .granted => self.openAndStart(),
        }
    }

    fn openAndStart(self: *Input) void {
        if (self.open_attempted) return;
        self.open_attempted = true;

        var device = kit.audio.openCapture(self.gpa, .{
            .sample_rate = 48000,
            .channels = 1,
            .capture_callback = captureCallback,
            .userdata = self.ring,
        }) catch |err| {
            self.state = switch (err) {
                error.Unsupported => .unsupported,
                error.PermissionDenied => .denied,
                else => .failed,
            };
            return;
        };
        device.start() catch {
            device.close();
            self.state = .failed;
            return;
        };
        self.device = device;
        self.sample_rate = device.config().sample_rate;
        self.state = .ready;
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

    /// Keeps kngn's wasm audio *and* capture exports alive against DCE. Every
    /// `audio=worklet_shared` package needs the audio-side sentinel exports even when it
    /// never opens the render path (see kngn's docs/wasm-deploy.md), because the shared
    /// second Instance boot checks for them unconditionally.
    pub fn enableWasmExports() void {
        kit.audio.enableWebAudioExports();
        kit.audio.enableWebCaptureExports();
    }
};

pub fn bind(_: *Input) void {}

fn captureCallback(frame: kit.audio.AudioInFrame, userdata: ?*anyopaque) void {
    const ring: *audio_ring.Ring = @ptrCast(@alignCast(userdata orelse return));
    ring.pushFrame(frame.samples, frame.frames, frame.channels);
}
