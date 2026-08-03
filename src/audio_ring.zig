//! Fixed-capacity mono sample handover from a microphone callback to the main thread.
//!
//! Hot path declaration: `pushFrame` is called on the microphone real-time thread.
//! It performs only bounded arithmetic, sample copies and atomic loads/stores. It does
//! not allocate, lock, perform IO or panic.

const std = @import("std");

pub const capacity = 16 * 1024;

pub const Ring = struct {
    samples: [capacity]f32 = @splat(0),
    read_index: std.atomic.Value(usize) = .init(0),
    write_index: std.atomic.Value(usize) = .init(0),
    dropped: std.atomic.Value(usize) = .init(0),

    pub fn pushFrame(self: *Ring, interleaved: []const f32, frames: u32, channels: u32) void {
        if (channels == 0) return;
        const channel_count = @as(usize, channels);
        const frame_count = @min(@as(usize, frames), interleaved.len / channel_count);
        var frame: usize = 0;
        while (frame < frame_count) : (frame += 1) {
            var mono: f32 = 0;
            var channel: usize = 0;
            while (channel < channel_count) : (channel += 1) {
                mono += interleaved[frame * channel_count + channel];
            }
            mono /= @as(f32, @floatFromInt(channel_count));
            self.pushSample(mono);
        }
    }

    pub fn pop(self: *Ring, out: []f32) usize {
        var read = self.read_index.load(.acquire);
        const write = self.write_index.load(.acquire);
        var count: usize = 0;
        while (read != write and count < out.len) : (count += 1) {
            out[count] = self.samples[read];
            read = (read + 1) & (capacity - 1);
        }
        self.read_index.store(read, .release);
        return count;
    }

    pub fn droppedCount(self: *const Ring) usize {
        return self.dropped.load(.monotonic);
    }

    fn pushSample(self: *Ring, sample: f32) void {
        const write = self.write_index.load(.monotonic);
        const next = (write + 1) & (capacity - 1);
        const read = self.read_index.load(.acquire);
        if (next == read) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.samples[write] = sample;
        self.write_index.store(next, .release);
    }
};

test "ring preserves order and drops only when full" {
    var ring: Ring = .{};
    var input: [4]f32 = .{ 1, 2, 3, 4 };
    ring.pushFrame(&input, 4, 1);
    var output: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), ring.pop(&output));
    try std.testing.expectEqualSlices(f32, &input, &output);
    try std.testing.expectEqual(@as(usize, 0), ring.droppedCount());
}
