#!/bin/sh
# 打包前只读验证真实链接元信息；不改写 Mach-O，也不修改任何构建产物。
set -eu

binary_path=${1:?Usage: check_build_sdk.sh binary [minimum-macos-version]}
minimum_macos=${2:-14.0}
expected_sdk=$(xcrun --sdk macosx --show-sdk-version)
build_info=$(xcrun vtool -show-build "$binary_path")

printf '%s\n' "$build_info" | awk -v sdk="$expected_sdk" -v minimum="$minimum_macos" '
function same_version(a, b, aa, bb, i) {
    split(a, aa, ".")
    split(b, bb, ".")
    for (i = 1; i <= 3; i++) if ((aa[i] + 0) != (bb[i] + 0)) return 0
    return 1
}
$1 == "platform" {
    platforms++
    if ($2 != "MACOS") { print "Unexpected Mach-O platform: " $2 > "/dev/stderr"; failed = 1 }
}
$1 == "minos" {
    minimums++
    if (!same_version($2, minimum)) {
        print "Unexpected minimum macOS: " $2 "; expected " minimum > "/dev/stderr"
        failed = 1
    }
}
$1 == "sdk" {
    sdks++
    if (!same_version($2, sdk)) {
        print "Unexpected linked SDK: " $2 "; active SDK is " sdk > "/dev/stderr"
        failed = 1
    }
}
END {
    if (!platforms || platforms != minimums || platforms != sdks) {
        print "Missing or incomplete LC_BUILD_VERSION metadata" > "/dev/stderr"
        failed = 1
    }
    if (failed) exit 1
    print "Verified " sdks " Mach-O slice(s): macOS " minimum "+, SDK " sdk
}'
