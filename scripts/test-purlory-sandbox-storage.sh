#!/bin/sh
# Prove the production storage resolver with a disposable, genuinely sandboxed app.
set -eu
cd "$(dirname "$0")/.."

ENTITLEMENTS=Distribution/Purlory.entitlements
PROJECT=Distribution/Purlory.xcodeproj/project.pbxproj
fail() { echo "Sandbox storage verification failed: $*" >&2; exit 1; }
for CONFIG in A17300000000000000000012 A17300000000000000000013; do
    SETTING="objects.$CONFIG.buildSettings"
    [ "$(plutil -extract "$SETTING.ENABLE_APP_SANDBOX" raw -o - "$PROJECT")" = YES ] || fail "sandbox disabled"
    [ "$(plutil -extract "$SETTING.CODE_SIGN_ENTITLEMENTS" raw -o - "$PROJECT")" = Purlory.entitlements ] || fail "unexpected entitlements"
done
for KEY in app-sandbox files.user-selected.read-write network.client; do
    [ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.$KEY" "$ENTITLEMENTS")" = true ] || fail "missing $KEY"
done

# The outside fixture must be in the real home, not the sandbox-writable temp directory.
PROBE_ROOT=$(mktemp -d "$HOME/.purlory-sandbox-storage.XXXXXX")
PROBE_ID="app.purlory.storage-probe.$(uuidgen | tr '[:upper:]' '[:lower:]')"
PROBE_CONTAINER="$HOME/Library/Containers/$PROBE_ID"
[ ! -e "$PROBE_CONTAINER" ] || fail "container collision"
mkdir "$PROBE_CONTAINER"
cleanup() {
    rm -rf "$PROBE_ROOT" "$PROBE_CONTAINER/Data"
    # macOS protects its container-manager record; never require broader disk access.
    METADATA="$PROBE_CONTAINER/.com.apple.containermanagerd.metadata.plist"
    rm -f "$METADATA" 2>/dev/null || true
    if ! rmdir "$PROBE_CONTAINER" 2>/dev/null; then
        [ -f "$METADATA" ] && [ -z "$(find "$PROBE_CONTAINER" -mindepth 1 ! -name .com.apple.containermanagerd.metadata.plist -print -quit)" ] \
            || fail "test data remains after cleanup"
        echo "Removed all probe data; macOS retained its protected container record: $PROBE_ID"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$PROBE_CONTAINER/Data/Documents/Purlory"
PROBE_APP="$PROBE_ROOT/SandboxStorageProbe.app"
mkdir -p "$PROBE_APP/Contents/MacOS"
cat > "$PROBE_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$PROBE_ID</string>
<key>CFBundleExecutable</key><string>SandboxStorageProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
cat > "$PROBE_ROOT/main.swift" <<'SWIFT'
import Foundation
import Darwin

let files = FileManager.default
let environment = ProcessInfo.processInfo.environment
let expected = URL(fileURLWithPath: environment["PURLORY_PROBE_CONTAINER"]!, isDirectory: true)
    .resolvingSymlinksInPath()
let result = expected.appendingPathComponent("Documents/Purlory/probe-result.txt")
let outside = URL(fileURLWithPath: environment["PURLORY_PROBE_OUTSIDE"]!)
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "SandboxStorageProbe", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: message]) }
}
func isDenied(_ error: NSError) -> Bool {
    if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError { return true }
    if error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
    return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isDenied) ?? false
}
do {
    let storage = PurloryStorageLocation.standard.rootDirectory.resolvingSymlinksInPath()
    try require(storage.path.hasPrefix(expected.path + "/"), "standard storage escaped the owned container: \(storage.path)")
    try files.createDirectory(at: storage, withIntermediateDirectories: true)
    let fixture = storage.appendingPathComponent("manuscript.txt")
    let manuscript = Data("한글 원고\r\nLocal writing without a model.".utf8)
    try manuscript.write(to: fixture, options: .atomic)
    try require(Data(contentsOf: fixture) == manuscript, "container manuscript did not reopen")
    do {
        try Data("unexpected overwrite".utf8).write(to: outside, options: .atomic)
        throw NSError(domain: "SandboxStorageProbe", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "ungranted external write succeeded"])
    } catch {
        try require(isDenied(error as NSError), "external write was not denied by sandbox: \(error)")
    }
    try Data("PASS\n\(storage.path)\n".utf8).write(to: result, options: .atomic)
} catch {
    try? Data("FAIL\n\(error)\n".utf8).write(to: result, options: .atomic)
    exit(1)
}
SWIFT
xcrun swiftc -package-name Purlory -target arm64-apple-macos14.0 Sources/PurloryFoundation/PurloryStorageLocation.swift \
    "$PROBE_ROOT/main.swift" -o "$PROBE_APP/Contents/MacOS/SandboxStorageProbe"
RESULT="$PROBE_CONTAINER/Data/Documents/Purlory/probe-result.txt"
run_probe() {
    rm -f "$RESULT"
    echo "preserved outside fixture" > "$PROBE_ROOT/outside.txt"
    open -n --env "CFFIXED_USER_HOME=$PROBE_CONTAINER/Data" \
        --env "PURLORY_PROBE_CONTAINER=$PROBE_CONTAINER/Data" \
        --env "PURLORY_PROBE_OUTSIDE=$PROBE_ROOT/outside.txt" "$PROBE_APP"
    ATTEMPT=0
    while [ ! -f "$RESULT" ] && [ "$ATTEMPT" -lt 30 ]; do
        sleep 1
        ATTEMPT=$((ATTEMPT + 1))
    done
    [ -f "$RESULT" ] || fail "probe produced no result"
}
# A redirected home alone must fail: the unsandboxed control can overwrite outside.
codesign --force --sign - "$PROBE_APP"
run_probe
[ "$(head -n 1 "$RESULT")" = FAIL ] || fail "unsandboxed control passed"
[ "$(cat "$PROBE_ROOT/outside.txt")" = "unexpected overwrite" ] || fail "control did not exercise external write"
echo "Rejected unsandboxed control despite container-shaped storage"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$PROBE_APP"
codesign --verify --strict "$PROBE_APP"
codesign --display --entitlements :- "$PROBE_APP" > "$PROBE_ROOT/effective.plist" 2> "$PROBE_ROOT/signature.log"
for KEY in app-sandbox files.user-selected.read-write network.client; do
    [ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.$KEY" "$PROBE_ROOT/effective.plist")" = true ] || fail "ineffective $KEY"
done
run_probe
cat "$RESULT"
[ "$(head -n 1 "$RESULT")" = PASS ] || fail "runtime probe rejected storage"
[ "$(cat "$PROBE_ROOT/outside.txt")" = "preserved outside fixture" ] || fail "outside fixture changed"
echo "Sandbox storage verification passed (container write/reopen and denied external write)"
