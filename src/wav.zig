//! Minimal RIFF/WAV reader for deterministic CLI fixtures.

const std = @import("std");

pub const Error = error{
    InvalidRiff,
    MissingFormat,
    MissingData,
    UnsupportedFormat,
    InvalidChunk,
};

pub const Reader = struct {
    bytes: []const u8,
    data_start: usize,
    data_size: usize,
    cursor_frame: usize = 0,
    sample_rate: u32,
    channels: u16,
    format: Format,
    bytes_per_sample: usize,

    const Format = enum { pcm16, float32 };

    pub fn parse(bytes: []const u8) Error!Reader {
        if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) {
            return error.InvalidRiff;
        }

        var offset: usize = 12;
        var format: ?Format = null;
        var sample_rate: u32 = 0;
        var channels: u16 = 0;
        var bits_per_sample: u16 = 0;
        var data_start: ?usize = null;
        var data_size: usize = 0;

        while (offset + 8 <= bytes.len) {
            const chunk_id = bytes[offset .. offset + 4];
            const chunk_size = readU32(bytes[offset + 4 .. offset + 8]);
            const body_start = offset + 8;
            const body_end = body_start + @as(usize, chunk_size);
            if (body_end > bytes.len) return error.InvalidChunk;

            if (std.mem.eql(u8, chunk_id, "fmt ")) {
                if (chunk_size < 16) return error.InvalidChunk;
                const audio_format = readU16(bytes[body_start .. body_start + 2]);
                channels = readU16(bytes[body_start + 2 .. body_start + 4]);
                sample_rate = readU32(bytes[body_start + 4 .. body_start + 8]);
                bits_per_sample = readU16(bytes[body_start + 14 .. body_start + 16]);
                format = switch (audio_format) {
                    1 => if (bits_per_sample == 16) .pcm16 else return error.UnsupportedFormat,
                    3 => if (bits_per_sample == 32) .float32 else return error.UnsupportedFormat,
                    else => return error.UnsupportedFormat,
                };
            } else if (std.mem.eql(u8, chunk_id, "data")) {
                data_start = body_start;
                data_size = chunk_size;
            }

            offset = body_end + @as(usize, chunk_size & 1);
        }

        const selected_format = format orelse return error.MissingFormat;
        const start = data_start orelse return error.MissingData;
        if (channels == 0 or sample_rate == 0) return error.InvalidChunk;
        const bytes_per_sample: usize = switch (selected_format) {
            .pcm16 => 2,
            .float32 => 4,
        };
        if (data_size < bytes_per_sample * channels) return error.InvalidChunk;
        return .{
            .bytes = bytes,
            .data_start = start,
            .data_size = data_size,
            .sample_rate = sample_rate,
            .channels = channels,
            .format = selected_format,
            .bytes_per_sample = bytes_per_sample,
        };
    }

    pub fn readMono(self: *Reader, out: []f32) usize {
        const frame_size = self.bytes_per_sample * @as(usize, self.channels);
        const frame_count = self.data_size / frame_size;
        var count: usize = 0;
        while (count < out.len and self.cursor_frame < frame_count) : (count += 1) {
            const frame_offset = self.data_start + self.cursor_frame * frame_size;
            var mono: f32 = 0;
            var channel: usize = 0;
            while (channel < self.channels) : (channel += 1) {
                const sample_offset = frame_offset + channel * self.bytes_per_sample;
                mono += switch (self.format) {
                    .pcm16 => @as(f32, @floatFromInt(readI16(self.bytes[sample_offset .. sample_offset + 2]))) / 32768.0,
                    .float32 => @bitCast(readU32(self.bytes[sample_offset .. sample_offset + 4])),
                };
            }
            out[count] = mono / @as(f32, @floatFromInt(self.channels));
            self.cursor_frame += 1;
        }
        return count;
    }
};

fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readI16(bytes: []const u8) i16 {
    return @bitCast(readU16(bytes));
}

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}
