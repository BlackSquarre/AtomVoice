[English](README.md) | **简体中文** | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | [Français](README-fr.md) | [Deutsch](README-de.md)

# AtomVoice（原子微语）

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

轻量级 macOS 菜单栏语音输入法。按住 **Fn** 键录音，松开后文字自动注入当前输入框。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

### 🔒 隐私优先
所有语音识别均通过 Apple 语音识别框架**在本地完成**，音频不会发送到任何服务器（除非主动开启 LLM 文本优化）。

### ⚡ 极致轻量
约 3 MB，空闲时 CPU 占用趋近于零，无后台进程。

---

## 功能特性

- **按住 Fn 键**录音，松开即将文字注入当前输入框
- **流式转录** — 基于 Apple 语音识别框架，默认简体中文
- **5 频段实时频谱波形** — 100–6000 Hz，左低频右高频，由 Accelerate FFT 驱动
- **本地自动标点** — 根据语气词补全句末标点，无需联网
- **LLM 文本优化** — 接入 OpenAI 兼容 API，自动纠错（如配森→Python）；内置 9 个服务商预设，列表可自由编辑
- **灵动岛风格动画** — 120Hz 真实弹簧物理积分 + 高斯模糊；"优化中"时全胶囊扫光效果
- **深色/浅色模式自适应** — macOS 26 液态玻璃，旧系统毛玻璃降级
- **7 种界面语言** — 简体中文、繁體中文、English、日本語、한국어、Español、Français、Deutsch
- **CJK 输入法兼容** — 注入前自动切换输入源，防止中文输入法拦截

## 系统要求

- macOS 13 Ventura 及以上
- 需要权限：**辅助功能**、**麦克风**、**语音识别**

## 安装

**从 Release 下载（推荐）**

前往 [Releases](https://github.com/BlackSquarre/AtomVoice/releases)，下载对应架构的 zip，解压后拖入应用程序文件夹。

**从源码构建**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make install
```

## ⚠️ 签名提示

临时签名，未经 Apple 公证。首次打开时：

1. 右键点击 `AtomVoice.app` → **打开** → 点击**打开**
2. 或前往**系统设置 → 隐私与安全性** → **仍然打开**
3. 或在终端运行：`xattr -cr /Applications/AtomVoice.app`

## 使用方法

| 操作 | 说明 |
|------|------|
| 按住 Fn | 开始录音 |
| 松开 Fn | 停止录音，文字自动注入 |
| 点击菜单栏图标 | 切换语言 / 动画 / LLM 设置 |

## LLM 优化配置

菜单栏 → **LLM 文本优化** → **设置** — 选择服务商预设或自定义添加，填入 API Key 和模型名称。

内置预设：OpenAI / DeepSeek / Moonshot (Kimi) / 阿里云百炼 (Qwen) / 智谱 AI (GLM) / 零一万物 (Yi) / Groq / Ollama（本地）

## 构建命令

```bash
make build    # 构建 .app bundle
make run      # 构建并启动
make install  # 安装到 /Applications
make release  # 构建 Universal + AppleSilicon + Intel 三个版本
make clean    # 清理构建产物
```

## License

MIT
