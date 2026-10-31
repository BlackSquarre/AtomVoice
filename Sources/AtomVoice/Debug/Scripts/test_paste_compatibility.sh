#!/bin/zsh

# 编译并运行 Accessibility 原生 Paste 批量探针。
# 探针会保存并恢复完整剪贴板内容，只输入临时标记，不发送消息。

set -euo pipefail

typeset -r script_dir="${0:A:h}"
typeset -r source_file="$script_dir/../Tools/PasteCompatibilityProbe.swift"
typeset -r binary_file="${TMPDIR:-/tmp}/AtomVoicePasteCompatibilityProbe.$$"

cleanup() {
    rm -f "$binary_file"
}
trap cleanup EXIT INT TERM

swiftc -framework Cocoa -framework ApplicationServices "$source_file" -o "$binary_file"
exec "$binary_file" "$@"
