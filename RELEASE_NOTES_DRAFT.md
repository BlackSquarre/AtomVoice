## What's New
- **Sherpa Runtime Updates:** Added a dedicated button to check for and install Sherpa-ONNX runtime updates, with local version tracking and automatic latest-version checks from GitHub.
- **Sherpa Download Progress:** Sherpa model and runtime downloads now show a dedicated progress capsule with downloaded and total size, so large downloads are easier to monitor.

## Improvements
- **More Reliable Sherpa Setup:** Improved model extraction, validation, and runtime-only update handling, including support for model packages with nested directory layouts.
- **Model List Accuracy:** Updated displayed Sherpa model sizes to better match actual installed sizes.
- **Smoother Recording Start:** When a Sherpa model is already loaded, recording now starts without briefly showing a loading state.

## Bug Fixes
- **Sherpa Download State:** Saving an undownloaded model, updating the runtime, or triggering a download while another one is running now keeps the selected model and UI state consistent.

---

## 新功能
- **Sherpa 运行时更新：** 新增独立更新 Sherpa-ONNX 运行时的功能，支持本地版本追踪，并可从 GitHub 自动检查最新版本。
- **Sherpa 下载进度：** Sherpa 模型与运行时下载现在会显示专用进度胶囊，并展示已下载大小和总大小，方便跟踪大型下载。

## 优化
- **Sherpa 设置更可靠：** 改进模型解压、校验和仅更新运行时的处理逻辑，并支持带有多层目录结构的模型包。
- **模型列表更准确：** 更新 Sherpa 模型列表中显示的大小，使其更接近实际安装占用。
- **录音启动更顺滑：** 当 Sherpa 模型已加载时，开始录音不再短暂显示加载状态。

## Bug 修复
- **Sherpa 下载状态：** 保存未下载模型、更新运行时或在已有下载进行时再次触发下载，现在都会保持所选模型和界面状态一致。
