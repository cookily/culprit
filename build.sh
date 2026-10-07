#!/bin/bash
# 构建 Culprit 菜单栏监控应用，输出到 ~/Applications/Culprit.app
# 环境：仅 Command Line Tools 即可（无需 Xcode 工程）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Culprit"
APP_DIR="$HOME/Applications/$APP_NAME.app"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp Info.plist "$APP_DIR/Contents/Info.plist"

# 通用二进制（universal）：同一产物同时支持 Intel 与 Apple Silicon
# swiftc 不支持 clang 式 -arch，按 target 各编一次再 lipo 合并
swiftc -swift-version 5 -O -target x86_64-apple-macos12.0 -o "$APP_DIR/Contents/MacOS/$APP_NAME.x86_64" main.swift sampler.swift
swiftc -swift-version 5 -O -target arm64-apple-macos12.0 -o "$APP_DIR/Contents/MacOS/$APP_NAME.arm64" main.swift sampler.swift
lipo -create "$APP_DIR/Contents/MacOS/$APP_NAME.x86_64" "$APP_DIR/Contents/MacOS/$APP_NAME.arm64" -output "$APP_DIR/Contents/MacOS/$APP_NAME"
rm -f "$APP_DIR/Contents/MacOS/$APP_NAME.x86_64" "$APP_DIR/Contents/MacOS/$APP_NAME.arm64"

# ad-hoc 签名：未签名应用在 macOS 上会行为异常（如通知被无视、Gatekeeper 拦截）
codesign --force --sign - "$APP_DIR"
echo "已构建: $APP_DIR"
