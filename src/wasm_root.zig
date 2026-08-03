//! Tuner wasm root.
//!
//! The root has no main. The browser glue drives the Runtime(App) exports from rAF.

const tuner_app = @import("tuner_app");

comptime {
    tuner_app.enableWasmRuntime();
}
