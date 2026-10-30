#!/bin/sh
# Purlory.app 최소 번들 빌드 (이슈 #65 Gate 0).
#
# SwiftPM CLI 산출물은 그대로 실행하면 "Failed to load the default metallib"로
# 죽는다(AGENTS §0). prepare-metallib.sh가 실행 파일 옆에 mlx.metallib을 놓아주므로,
# 앱 번들도 같은 배치(Contents/MacOS/Purlory + 같은 디렉터리의 mlx.metallib)면
# 추가 코드 없이 동작한다. xcodeproj 없이 Gate 0의 "앱 번들 스모크"를 가능하게
# The developer bundle includes the app icon; Store signing and sandbox proof use the archive path.
#
# 사용법:  scripts/build-purlory-app.sh   → build/Purlory.app
set -eu
cd "$(dirname "$0")/.."
scripts/prepare-korean-backend.sh

# metallib은 mlx-swift 리비전에 묶여 있다 — 낡은 캐시 복사를 막으려면 항상 경유.
scripts/prepare-metallib.sh

echo "▸ 릴리즈 빌드…"
# 앱 번들에는 Purlory 실행 파일만 필요하다. PurloryBench는 CI에서 별도 product로
# 컴파일해 앱 패키징 실패와 벤치 도구 실패가 서로 가려지지 않게 한다.
swift build -c release --product Purlory --disable-automatic-resolution

REL=".build/arm64-apple-macosx/release"
APP="build/Purlory.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$REL/Purlory" "$APP/Contents/MacOS/Purlory"
cp "$REL/mlx.metallib" "$APP/Contents/MacOS/mlx.metallib"
cp Distribution/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Distribution/Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
python3 scripts/validate-purlory-privacy.py "$APP"
# Copy the distributed SwiftPM resources; test and benchmark bundles stay outside the app.
for BUNDLE in Purlory_PurloryWorkspaceUI Purlory_PurloryDocumentEngine Purlory_PurloryKoreanBackend SwiftMath_SwiftMath swift-transformers_Hub swift-crypto_Crypto; do
    cp -R "$REL/$BUNDLE.bundle" "$APP/Contents/Resources/"
done
python3 scripts/purlory-notices.py --checkouts .build/checkouts \
    --output "$APP/Contents/Resources" --validate-app "$APP"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleExecutable</key>
    <string>Purlory</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>app.purlory.Purlory</string>
    <key>CFBundleName</key>
    <string>Purlory</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Stamp this build's source identity; binary hashes distinguish rebuilt artifacts.
python3 scripts/validate-purlory-icon.py "$APP"

PURLORY_SOURCE_REVISION=$(git rev-parse HEAD)
PURLORY_SOURCE_DIRTY=false
[ -z "$(git status --porcelain --untracked-files=normal)" ] || PURLORY_SOURCE_DIRTY=true
plutil -insert PurlorySourceRevision -string "$PURLORY_SOURCE_REVISION" "$APP/Contents/Info.plist"
plutil -insert PurlorySourceDirty -bool "$PURLORY_SOURCE_DIRTY" "$APP/Contents/Info.plist"

# 로컬 실행용 애드혹 서명 — `open` 실행과 TCC 권한 대화의 엉킴을 줄인다.
# --deep 필요: Contents/MacOS/mlx.metallib은 무서명 코드 객체라 번들 단독
# 서명이 거절된다 (서브컴포넌트 먼저 서명).
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || echo "⚠ 애드혹 서명 실패 — 직접 실행에는 지장 없음" >&2

echo "✓ $APP"
