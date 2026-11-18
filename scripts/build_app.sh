#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="NoSleep"
BUNDLE_ID="${BUNDLE_ID:-com.minglixiang.NoSleep}"
MIN_MACOS="${MIN_MACOS:-13.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCHS="${ARCHS:-arm64 x86_64}"

SRC_DIR="${ROOT_DIR}/NoSleep"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-macOS.zip"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

TMP_DIR="$(mktemp -d /tmp/nosleep-build.XXXXXX)"
cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

resolve_sdk() {
    if [[ -n "${SDK_PATH:-}" ]]; then
        echo "${SDK_PATH}"
        return
    fi

    local default_sdk sdk_version
    default_sdk="$(xcrun --show-sdk-path)"
    sdk_version="$(xcrun --show-sdk-version)"

    # 若仅安装了 CommandLineTools 且默认 SDK 为 27.x（缺少随 Xcode 附带的 SwiftUIMacros 插件），
    # 优先回退到同目录的 MacOSX26.x SDK。
    if [[ ! -d "/Applications/Xcode.app" && "${sdk_version}" == 27.* ]]; then
        for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
            if [[ -d "${candidate}" && ! -L "${candidate}" ]]; then
                echo "${candidate}"
                return
            fi
        done
    fi

    echo "${default_sdk}"
}

SDK="$(resolve_sdk)"
SWIFT_SOURCES=(
    "${SRC_DIR}/App.swift"
    "${SRC_DIR}/SleepManager.swift"
    "${SRC_DIR}/MenuBarView.swift"
)

echo "==> 使用 SDK: ${SDK}"
echo "==> 目标架构: ${ARCHS}"

ARCH_BINS=()
for ARCH in ${ARCHS}; do
    MOD_CACHE="${TMP_DIR}/swift-cache-${ARCH}"
    CLANG_CACHE="${TMP_DIR}/clang-cache-${ARCH}"
    OUT_BIN="${TMP_DIR}/${APP_NAME}-${ARCH}"

    echo "==> 编译 ${ARCH}..."
    swiftc \
        -O \
        -swift-version 6 \
        -target "${ARCH}-apple-macosx${MIN_MACOS}" \
        -sdk "${SDK}" \
        -module-cache-path "${MOD_CACHE}" \
        -Xcc "-fmodules-cache-path=${CLANG_CACHE}" \
        -framework SwiftUI \
        -framework AppKit \
        -framework IOKit \
        -framework ServiceManagement \
        "${SWIFT_SOURCES[@]}" \
        -o "${OUT_BIN}"

    ARCH_BINS+=("${OUT_BIN}")
done

rm -rf "${APP_BUNDLE}" "${ZIP_PATH}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

if [[ "${#ARCH_BINS[@]}" -eq 1 ]]; then
    cp "${ARCH_BINS[0]}" "${MACOS_DIR}/${APP_NAME}"
else
    echo "==> 合并 Universal Binary (${ARCHS})..."
    lipo -create "${ARCH_BINS[@]}" -output "${MACOS_DIR}/${APP_NAME}"
fi
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "==> 生成 AppIcon.icns..."
cat > "${TMP_DIR}/generate_icns.swift" << 'ICON_EOF'
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: generate_icns.swift <output-icns-path>")
}

let outputPath = CommandLine.arguments[1]

func renderPNG(pixelSize: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixelSize)
    let inset = size * 0.08
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2)

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.26, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.14, alpha: 1.0)
    )
    gradient?.draw(in: path, angle: -90)

    NSColor(white: 1.0, alpha: 0.14).setStroke()
    path.lineWidth = max(1.0, size * 0.015)
    path.stroke()

    if let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.22, alpha: 1.0)]))
        let configured = symbol.withSymbolConfiguration(config) ?? symbol
        let symSize = configured.size
        let drawRect = NSRect(
            x: (size - symSize.width) / 2,
            y: (size - symSize.height) / 2,
            width: symSize.width,
            height: symSize.height
        )
        configured.draw(in: drawRect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func be32(_ value: UInt32) -> Data {
    var big = value.bigEndian
    return Data(bytes: &big, count: 4)
}

let chunks: [(String, Int)] = [
    ("ic04", 16),
    ("ic11", 32),
    ("ic05", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024)
]

var body = Data()
for (ostype, size) in chunks {
    let png = renderPNG(pixelSize: size)
    body.append(contentsOf: ostype.utf8)
    body.append(be32(UInt32(png.count + 8)))
    body.append(png)
}

var icns = Data("icns".utf8)
icns.append(be32(UInt32(body.count + 8)))
icns.append(body)
try icns.write(to: URL(fileURLWithPath: outputPath))
ICON_EOF

swift \
    -sdk "${SDK}" \
    -module-cache-path "${TMP_DIR}/icon-swift-cache" \
    -Xcc "-fmodules-cache-path=${TMP_DIR}/icon-clang-cache" \
    "${TMP_DIR}/generate_icns.swift" \
    "${RESOURCES_DIR}/AppIcon.icns"

echo "==> 生成 Info.plist 与 PkgInfo..."
sed \
    -e "s/\$(DEVELOPMENT_LANGUAGE)/zh-Hans/g" \
    -e "s/\$(EXECUTABLE_NAME)/${APP_NAME}/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/${BUNDLE_ID}/g" \
    -e "s/\$(PRODUCT_NAME)/${APP_NAME}/g" \
    "${SRC_DIR}/Info.plist" > "${CONTENTS_DIR}/Info.plist"

plutil -lint "${CONTENTS_DIR}/Info.plist"
printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

echo "==> 签名应用（启用 App Sandbox Entitlements）..."
codesign \
    --force \
    --deep \
    --sign "${SIGN_IDENTITY}" \
    --entitlements "${SRC_DIR}/${APP_NAME}.entitlements" \
    "${APP_BUNDLE}"

codesign --verify --deep --strict "${APP_BUNDLE}"
touch "${APP_BUNDLE}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
    "${LSREGISTER}" -f "${APP_BUNDLE}" >/dev/null 2>&1 || true
fi

echo "==> 打包 GitHub Release 压缩包..."
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

echo "✅ 打包完成:"
echo "   App: ${APP_BUNDLE}"
echo "   Zip: ${ZIP_PATH}"
