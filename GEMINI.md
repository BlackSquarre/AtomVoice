# AtomVoice — Gemini CLI 协作指南

## 项目简介

macOS 菜单栏语音输入工具。按住 Fn 键录音，松开后自动将识别文字注入到当前输入框。
纯 Swift + AppKit，目标系统 macOS 14+。

## Gemini 专属工作流与规则

1. **严格限制修改范围**：**绝对不要修改与当前任务不相关的代码。** 保持代码的纯净，不要进行无端的“代码清理”或无关重构。
2. **精准搜索与编辑**：利用 `grep_search` 和 `glob` 高效定位代码，并使用 `read_file` 或 `replace` 工具进行外科手术式的精准修改，以节约上下文并降低风险。
3. **验证驱动的开发**：在修改任何 BUG 之前，请优先在终端中尝试复现。在代码修改后，如果可以，请运行相关指令（如 `make dev`）进行验证，确保修改真正有效。
4. **行动前解释**：在执行对文件系统或代码库有重大影响的工具调用前，简短地（一句话）说明操作意图或策略。

## 构建与运行

### 开发调试
```bash
make dev        # 编译并安装到 dist/Test/AtomVoice.app（供确认后使用）
make run        # 编译并直接运行（当前机器原生架构）
```

### 发版构建
```bash
make release    # 构建三个架构：AppleSilicon / Intel / Universal，产物在 dist/
```

> 每次 `make release` 前先更新版本号（见下方发版流程）。

### 清理
```bash
make clean      # 清除 .build 和 dist
```

## 架构概览

```
AppDelegate
├── FnKeyMonitor          — 全局 Fn 键监听（CGEvent tap）
├── AudioEngineController — AVAudioEngine 录音 + 喂给识别器
├── SpeechRecognizerController — SFSpeechRecognizer 封装
├── CapsuleWindowController    — 浮动胶囊 UI（NSPanel + NSVisualEffectView / NSGlassEffectView）
├── LLMRefiner            — 可选 LLM 文字润色（OpenAI-compatible API）
├── TextInjector          — 剪贴板 + Cmd+V 注入，自动处理 CJK 输入法切换
└── MenuBarController     — NSStatusItem + 所有菜单项 + 设置窗口
```

数据流：`FnDown → startRecording()` → 识别回调实时更新胶囊文字 → `FnUp → stopRecording()` → 可选 LLM 润色 → `TextInjector.inject()` → 胶囊消失。

## 代码规范

- **注释用中文**。
- **新功能所有用户可见字符串必须走 `loc()`**，并同步更新全部 5 个 lproj 文件：
  `Resources/en.lproj/` `zh-Hans.lproj/` `zh-Hant.lproj/` `ja.lproj/` `ko.lproj/`
- 不硬编码用户界面字符串。
- 可以主动建议编写测试（目前项目无测试）。

## 发版流程

> **只在用户明确说"发版"后才执行，编译完成后等待确认。**

1. **自动建议版本号**：仅递增 patch 位（如当前 `0.9.1` → 建议 `0.9.2`）。未经用户主动提及，不更新 major / minor。
2. **用户确认版本号后**，同步修改两处：
   - `Sources/AtomVoice/Info.plist` → `CFBundleShortVersionString`
   - `Makefile` 顶部 `VERSION` 变量
3. 运行 `make release`，完成后**停下来等用户指令**。
4. 用户确认发版后，依次执行：
   ```bash
   git add -p                          # 按需暂存
   git commit -m "chore: release vX.Y.Z"
   git tag vX.Y.Z
   git push && git push --tags
   gh release create vX.Y.Z dist/AtomVoice-X.Y.Z-*.zip --title "vX.Y.Z" --generate-notes
   ```

## 权限要求

应用运行需要三项授权，缺一不可：
- **麦克风**（AVCaptureDevice）
- **语音识别**（SFSpeechRecognizer）
- **辅助功能**（Accessibility，用于 CGEvent tap 监听 Fn 键 + TextInjector 注入）

## 签名

Makefile 中已配置 Apple Development 证书（`codesign --sign "Apple Development: miaolingru@gmail.com (XJS89V9J9T)"`），构建时自动签名，无需额外操作。

## 本地化

支持 5 种语言：English / 简体中文 / 繁體中文 / 日本語 / 한국어。  
新增字符串时，所有 lproj 必须同步，缺失会导致回退到 key 名显示。
