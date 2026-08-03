const std = @import("std");

pub const Kind = enum {
    tone,
    microphone,
};

pub const State = enum {
    stopped,
    requesting,
    ready,
    denied,
    unsupported,
    failed,
};

pub const SampleRate = u32;

test "input states and kinds are explicit" {
    try std.testing.expectEqual(Kind.tone, .tone);
    try std.testing.expectEqual(State.requesting, .requesting);
}
