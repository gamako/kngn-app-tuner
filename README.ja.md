# Tuner

[設計ガイド（日本語）](doc/design-guide.ja.html) · [Design guide（English）](doc/design-guide.html)

隣接する `kngn` チェックアウトを利用した、クロマチック・ギターチューナーの試作です。

サンプルページ: [WebAssembly版チューナーを開く](https://kngn-app-tuner.pages.dev/tuner.html)
（ブラウザのマイク入力には `https` が必要です）。

## ディレクトリ配置

このプロジェクトはkngnを外部依存として利用するため、2つのチェックアウトを兄弟ディレクトリに配置します。

```text
video-proto/
├── kngn/
└── tuner/
```

`build.zig.zon` は `.path = "../kngn"` で隣のkngnを参照します。また、`build_helpers/` にはkngnからvendorした外部consumer用ヘルパーが含まれています。配置関係を維持し、ヘルパーは隣接するkngnのものと同期させてください。

`tuner/` ディレクトリから、kngnのZig環境を使ってビルドします。

```sh
direnv exec ../kngn zig build test
direnv exec ../kngn zig build run-tuner
```

kngnのdirenv環境がすでに有効な場合は、`direnv exec ../kngn` を省略できます。

## 概要

ピッチ判定ロジックはプラットフォームに依存せず、コマンドライン、WAVファイル、Nativeマイク入力、WebAssemblyのブラウザマイク入力で共通利用します。

GUIは、アナログ風の半円スケールとデジタル風の発光アクセントを組み合わせたメーターを表示します。

- 音名、オクターブ、周波数
- -50〜+50 centsの音程メーター
- 滑らかに動く針と中央の正確ゾーン
- 正確・ずれ・無信号の状態表示
- 音声入力の状態表示

## コマンド

`tuner` ディレクトリで実行します。

```sh
zig build test-pitch
zig build run-tuner-cli -- --input tone --frequency 82.4069
zig build run-tuner-cli -- --input file path/to/input.wav
zig build run-tuner-cli -- --input mic --duration 10
zig build run-tuner
```

GUIはデフォルトでマイク入力を使用します。決定的なテスト音を使う場合は、`--input tone --frequency Hz` を明示してください。

### Native GUIでマイクを使う

```sh
zig build run-tuner
```

macOSでは、初回起動時にターミナルまたはアプリのマイク使用を許可してください。

- システム設定
- プライバシーとセキュリティ
- マイク

Nativeのマイク入力は、kngnの `kit.audio` キャプチャ層からモノラル `f32` PCMを受け取り、固定容量のリングバッファを経由してピッチ解析へ渡します。

### CLIでマイクを確認する

```sh
zig build run-tuner-cli -- --input mic --duration 10
```

CLIは音声解析の確認と自動テスト用です。利用者向けの表示はGUIを使用します。

### GUIのヘッドレス確認

プラットフォームキーイベントを含むGUI検証は次のように実行できます。

```sh
KNGN_HEADLESS=1 \
KNGN_HARNESS_SCRIPT=tests/gui-events.txt \
KNGN_HARNESS_OUT=/tmp/tuner-harness \
zig build run-tuner -- --input tone --frequency 82.4069
```

WAVファイルで再現できる問題は、マイク入力と同じ解析器を使って確認できます。

## WebAssembly版

Web版は `getUserMedia` と `AudioWorklet` でブラウザのマイク入力を取得し、`SharedArrayBuffer` を使ってモノラル `f32` PCMをWasmへ送ります。

入力ブリッジは現在、外部アプリ側で実験的に実装しています。許可拒否、API未対応、キャプチャ失敗、終了時のストリーム停止も状態として扱います。

### Webパッケージの作成

```sh
zig build gate-web
zig build package-web
zig build package-web-single
```

`web/tuner.html` を直接 `file://` で開かないでください。生成された `kngn.js` とWasmファイルが必要であり、ブラウザのセキュリティ制約によってモジュール読み込みやマイク入力が動作しません。

マルチファイル版を作成して、付属のCOOP/COEP対応サーバーで配信します。

```sh
zig build package-web
python3 zig-out/web/serve-coop-coep.py 8080
```

ブラウザで <http://127.0.0.1:8080/tuner.html> を開き、マイク使用を許可してください。

`SharedArrayBuffer` によるマイク入力には、サーバーが付加する次のヘッダーが必要です。

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

`tuner.single.html` は単一ファイルパッケージの確認には使えますが、`file://` ではマイク入力を実行できません。
