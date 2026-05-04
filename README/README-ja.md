[English](README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | **日本語** | [한국어](README-ko.md) | [Español](README-es.md) | [Français](README-fr.md) | [Deutsch](README-de.md)

# AtomVoice（原子微語）

<p align="center"><img src="../AppIcon-1024.png" width="128"></p>

軽量 macOS メニューバー音声入力アプリ。**Fn** キーを押して録音し、離すと文字が現在の入力欄に自動挿入されます。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

### 🔒 プライバシー優先
すべての音声認識は Apple の音声認識フレームワークを使用し**デバイス上で完結**します。LLM 最適化を明示的に有効にしない限り、音声データがサーバーに送信されることはありません。

### ⚡ 軽量
アプリバンドル約 3 MB。アイドル時の CPU 使用率はほぼゼロ。バックグラウンドデーモンなし。

---

## 機能

- **Fn キーを押して**録音、離すとテキストが入力欄に自動挿入
- **ストリーミング転写** — Apple 音声認識、デフォルトは中国語（簡体字）
- **5 バンド FFT スペクトル波形** — 100–6000 Hz、左が低音右が高音、Accelerate フレームワーク駆動
- **自動句読点** — ローカルルールエンジンが文末句読点を追加、インターネット不要
- **LLM 最適化** — OpenAI 互換 API で転写ミスを自動修正（例：配森→Python）；9 つのプロバイダープリセット + カスタムリスト
- **ダイナミックアイランドアニメーション** — 120Hz のスプリング物理シミュレーション + ガウスブラー
- **ダーク/ライトモード自動切替** — macOS 26 では Liquid Glass、旧システムでは Visual Effect ブラー
- **7 つの UI 言語** — 簡体中文、繁體中文、English、日本語、한국어、Español、Français、Deutsch
- **CJK IME 対応** — ペースト前に自動で ASCII 入力ソースに切替

## システム要件

- macOS 13 Ventura 以降
- 必要な権限：**アシスト機能**、**マイク**、**音声認識**

## インストール

**Release からダウンロード（推奨）**

[Releases](https://github.com/BlackSquarre/AtomVoice/releases) からダウンロードし、zip を解凍して Applications にドラッグ。

**ソースからビルド**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make install
```

## ⚠️ Gatekeeper 警告

アドホック署名（ノータリゼーション未実施）。初回起動時：

1. `AtomVoice.app` を右クリック → **開く** → **開く** をクリック
2. または**システム設定 → プライバシーとセキュリティ** → **无论如何都打开**
3. ターミナルで実行：`xattr -cr /Applications/AtomVoice.app`

## 使い方

| 操作 | 結果 |
|------|------|
| Fn キーを押す | 録音開始 |
| Fn キーを離す | 録音停止、テキストを挿入 |
| メニューバーアイコン | 言語 / アニメーション / LLM 設定の切替 |

## LLM 最適化設定

メニューバー → **LLM 最適化** → **設定** — プロバイダープリセットを選択するかカスタムを追加し、API キーとモデル名を入力。

プリセット：OpenAI / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / Ollama（ローカル）

## ビルドコマンド

```bash
make build    # .app バンドルをビルド
make run      # ビルドして起動
make install  # /Applications にインストール
make release  # Universal + AppleSilicon + Intel の 3 パッケージをビルド
make clean    # ビルド成果物を削除
```

## License

MIT
