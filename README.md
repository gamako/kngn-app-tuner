# Tuner

[日本語版](README.ja.md) · [Design guide](doc/design-guide.html)

An external chromatic guitar tuner prototype built against the neighbouring `kngn`
checkout.

Live sample: [Open the WebAssembly tuner](https://kngn-app-tuner.pages.dev/tuner.html)
(`https` is required for browser microphone access).

## Checkout layout

The tuner is an external consumer of [kngn](https://github.com/gamako/kngn).
Clone the two repositories as siblings:

```text
workspace/
├── kngn/
└── kngn-app-tuner/
```

`build.zig.zon` resolves the kngn dependency through `.path = "../kngn"`, and
`build_helpers/` contains the consumer build helpers vendored from kngn. Keep
the sibling layout and keep those helper files synchronized with the adjacent
kngn checkout.

Install Zig 0.16.0 and the platform dependencies described in the [kngn build
documentation](https://github.com/gamako/kngn/blob/main/docs/build.md) before
building. Once the development environment is ready, run the commands below
from the `kngn-app-tuner/` directory:

```sh
zig build test
zig build run-tuner
```

## Commands

```sh
zig build test-pitch
zig build run-tuner-cli -- --input tone --frequency 82.4069
zig build run-tuner-cli -- --input file path/to/input.wav
zig build run-tuner-cli -- --input mic --duration 10
zig build run-tuner
```

The GUI uses the microphone by default. Use `--input tone --frequency Hz` for a deterministic test tone.

Headless GUI verification, including a platform key event:

```sh
KNGN_HEADLESS=1 \
KNGN_HARNESS_SCRIPT=tests/gui-events.txt \
KNGN_HARNESS_OUT=/tmp/tuner-harness \
zig build run-tuner -- --input tone --frequency 82.4069
```

The pitch analyzer is platform-independent. The command-line prototype and the GUI
feed the same analyzer with mono `f32` samples, so a WAV fixture can reproduce a
problem found during microphone use.

The GUI is implemented with `kit.app_runtime.Runtime(App)`. Native microphone input
uses kngn's `kit.audio` capture facade and hands `AudioInFrame` data to the same fixed
capacity PCM ring used by the analyzer.

The wasm package includes an experimental microphone bridge. The page uses
`getUserMedia` and an `AudioWorklet` backed by a `SharedArrayBuffer`, then submits mono
`f32` chunks through `tuner_capture_buffer_ptr`, `tuner_capture_buffer_len`, and
`tuner_capture_submit` without changing the analyzer. Permission, missing APIs, and
capture failures are reported through `tuner_capture_set_state`; shutdown is observed
through `tuner_capture_get_state` so the browser stream is stopped with the app.
The bridge is intentionally implemented in the external consumer first so its async
permission and transport contract can be evaluated before it is promoted into kngn.

Web package commands:

```sh
zig build gate-web
zig build package-web
zig build package-web-single
```

Do not open `web/tuner.html` directly with `file://`. That source template does not
have the generated `kngn.js` and wasm artefacts beside it, and browsers block module
loads from a `file://` origin. Build the multi-file package and serve its output:

```sh
zig build package-web
python3 zig-out/web/serve-coop-coep.py 8080
```

Then open <http://127.0.0.1:8080/tuner.html>. The COOP/COEP headers from the supplied
server are required for the SharedArrayBuffer microphone transport. The single-file
`tuner.single.html` is useful for packaging checks, but a `file://` origin cannot run
this microphone transport.
