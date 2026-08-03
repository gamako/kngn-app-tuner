//! Target-neutral PCM input facade for the tuner.
//!
//! Native and wasm adapters intentionally share only this consumer-facing contract. The
//! native adapter delegates device control to kit.audio; the wasm adapter exposes the same
//! PCM handoff boundary without duplicating kngn's native capture implementation.

const builtin = @import("builtin");
const types = @import("input_types.zig");

const backend = if (builtin.cpu.arch.isWasm())
    @import("input_web.zig")
else
    @import("input_native.zig");

pub const Kind = types.Kind;
pub const State = types.State;
pub const SampleRate = types.SampleRate;
pub const Input = backend.Input;

pub fn bind(input: *Input) void {
    if (comptime builtin.cpu.arch.isWasm()) backend.bind(input);
}

pub fn enableWasmExports() void {
    backend.Input.enableWasmExports();
}
