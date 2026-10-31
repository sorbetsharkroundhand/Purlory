#!/bin/sh
# 실제 사용자 앱과 원고를 건드리지 않는 project-owned editor UI 스모크 (#118).
# 먼저 scripts/build-purlory-app.sh 실행. 손쉬운 사용 권한이 필요하다.
# 한글 marked text와 Ghost 상호작용은 이 자동화가 증명하지 않는다.
set -eu
cd "$(dirname "$0")/.."

verify_project_state() {
    library=$1
    expected_body=$2
    projects="$library/Projects"
    [ -d "$projects" ] && [ ! -L "$projects" ] || {
        echo "project state invalid: unsafe projects directory" >&2
        return 1
    }
    active_marker="$projects/active-project.json"
    [ -f "$active_marker" ] && [ ! -L "$active_marker" ] || {
        echo "project state invalid: active project marker missing" >&2
        return 1
    }
    project_id=$(plutil -extract rawValue raw -o - "$active_marker" 2>/dev/null) || {
        echo "project state invalid: active project marker unreadable" >&2
        return 1
    }
    case "$project_id" in
        *[!0-9A-Fa-f-]*|'')
            echo "project state invalid: unsafe project id" >&2
            return 1
            ;;
    esac
    project_directory="$projects/$project_id"
    [ -d "$project_directory" ] && [ ! -L "$project_directory" ] || {
        echo "project state invalid: unsafe project directory" >&2
        return 1
    }
    manifest="$project_directory/project.json"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || {
        echo "project state invalid: manifest missing" >&2
        return 1
    }
    manifest_id=$(plutil -extract id.rawValue raw -o - "$manifest" 2>/dev/null) || return 1
    [ "$manifest_id" = "$project_id" ] || {
        echo "project state invalid: active id does not match manifest" >&2
        return 1
    }
    document_count=$(plutil -extract documents raw -o - "$manifest" 2>/dev/null) || return 1
    [ "$document_count" -gt 0 ] 2>/dev/null || {
        echo "project state invalid: no documents" >&2
        return 1
    }

    found=""
    document_index=0
    while [ "$document_index" -lt "$document_count" ]; do
        document_id=$(plutil -extract "documents.$document_index.id.rawValue" raw -o - "$manifest" 2>/dev/null) || return 1
        document_kind=$(plutil -extract "documents.$document_index.kind" raw -o - "$manifest" 2>/dev/null) || return 1
        relative_path=$(plutil -extract "documents.$document_index.relativePath" raw -o - "$manifest" 2>/dev/null) || return 1
        expected_hash=$(plutil -extract "documents.$document_index.contentHash" raw -o - "$manifest" 2>/dev/null) || return 1
        case "$document_kind" in
            note) document_folder=Notes ;;
            manuscript|reference) document_folder=Documents ;;
            *)
                echo "project state invalid: unknown document kind" >&2
                return 1
                ;;
        esac
        canonical_document_id=$(printf '%s' "$document_id" | tr '[:lower:]' '[:upper:]')
        canonical_relative_path="$document_folder/$canonical_document_id/$expected_hash.md"
        [ "$relative_path" = "$canonical_relative_path" ] || {
            echo "project state invalid: noncanonical document path" >&2
            return 1
        }
        case "/$relative_path/" in
            //*|*/../*|*/./*)
                echo "project state invalid: unsafe document path" >&2
                return 1
                ;;
        esac
        content="$project_directory/$relative_path"
        [ -f "$content" ] && [ ! -L "$content" ] || {
            echo "project state invalid: referenced content missing" >&2
            return 1
        }
        resolved_parent=$(cd "$(dirname "$content")" && pwd -P) || return 1
        resolved_project=$(cd "$project_directory" && pwd -P) || return 1
        case "$resolved_parent/" in
            "$resolved_project"/*) ;;
            *)
                echo "project state invalid: content escaped project" >&2
                return 1
                ;;
        esac
        actual_hash=$(shasum -a 256 "$content" | awk '{print $1}') || return 1
        [ "$actual_hash" = "$expected_hash" ] || {
            echo "project state invalid: content hash mismatch" >&2
            return 1
        }
        if printf '%s' "$expected_body" | cmp -s - "$content"; then found=1; fi
        document_index=$((document_index + 1))
    done
    [ -n "$found" ] || {
        echo "project state invalid: expected body absent" >&2
        return 1
    }
    [ ! -e "$library/entries.json" ] && [ ! -L "$library/entries.json" ] || {
        echo "project state invalid: normal mode created entries.json" >&2
        return 1
    }
    echo "project state verified"
}

if [ "${1:-}" = "--verify-project-state" ]; then
    [ "$#" -eq 3 ] || {
        echo "usage: $0 --verify-project-state LIBRARY EXPECTED_BODY" >&2
        exit 64
    }
    verify_project_state "$2" "$3"
    exit
fi

if /usr/sbin/ioreg -n Root -d1 | /usr/bin/grep -q '"CGSSessionScreenIsLocked"=Yes'; then
    echo "UI smoke requires an unlocked macOS session; no UI verification performed." >&2
    exit 1
fi

SOURCE_APP="$PWD/build/Purlory.app"
[ -x "$SOURCE_APP/Contents/MacOS/Purlory" ] || {
    echo "✗ 먼저 앱 번들을 빌드하세요" >&2
    exit 1
}

REAL_ENTRIES="$HOME/Documents/Purlory/entries.json"
REAL_ACTIVE="$HOME/Documents/Purlory/Projects/active-project.json"
file_hash() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo absent
    fi
}
REAL_ENTRIES_HASH=$(file_hash "$REAL_ENTRIES")
REAL_ACTIVE_HASH=$(file_hash "$REAL_ACTIVE")

SMOKE_ROOT=$(mktemp -d /tmp/purlory-ui-smoke.XXXXXX)
SMOKE_ROOT=$(cd "$SMOKE_ROOT" && pwd -P)
SMOKE_HOME="$SMOKE_ROOT/home"
APP="$SMOKE_ROOT/Purlory.app"
SMOKE_EXECUTABLE="PurloryUISmoke$(uuidgen | tr -d '-')"
BIN="$APP/Contents/MacOS/$SMOKE_EXECUTABLE"
PID=""
PASSED=""
SMOKE_BUNDLE_ID=""
PREFERENCES_OWNED=""
CLIPBOARD_PID=""

restore_clipboard() {
    if [ -n "$CLIPBOARD_PID" ]; then
        kill -TERM "$CLIPBOARD_PID" 2>/dev/null || true
        wait "$CLIPBOARD_PID" 2>/dev/null || true
        CLIPBOARD_PID=""
    fi
}

fail() { echo "✗ $1" >&2; exit 1; }
owned_pid() {
    [ -n "$PID" ] && [ "$(ps -p "$PID" -o comm= 2>/dev/null)" = "$BIN" ]
}
find_pid() {
    ps -axo pid=,comm= | awk -v bin="$BIN" '$2 == bin {print $1}'
}
check_original() {
    [ "$(file_hash "$REAL_ENTRIES")" = "$REAL_ENTRIES_HASH" ] \
        || fail "실제 entries.json 해시가 달라졌습니다"
    [ "$(file_hash "$REAL_ACTIVE")" = "$REAL_ACTIVE_HASH" ] \
        || fail "실제 활성 프로젝트 표식 해시가 달라졌습니다"
}
cleanup() {
    status=$?
    trap - 0
    restore_clipboard
    [ -n "$PID" ] || PID=$(find_pid)
    if owned_pid; then kill -9 "$PID" 2>/dev/null || true; fi
    if [ -n "$PREFERENCES_OWNED" ]; then
        defaults delete "$SMOKE_BUNDLE_ID" >/dev/null 2>&1 || true
    fi
    if [ "$(file_hash "$REAL_ENTRIES")" != "$REAL_ENTRIES_HASH" ] \
        || [ "$(file_hash "$REAL_ACTIVE")" != "$REAL_ACTIVE_HASH" ]; then
        echo "✗ 실제 사용자 저장소 해시가 달라졌습니다" >&2
        status=1
        PASSED=""
    fi
    if [ -n "$PASSED" ]; then
        rm -rf "$SMOKE_ROOT"
    else
        echo "▸ 실패 자료 보존: $SMOKE_ROOT" >&2
    fi
    exit "$status"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

mkdir -p "$SMOKE_HOME/Documents" "$SMOKE_HOME/Library/Logs/DiagnosticReports"
ditto "$SOURCE_APP" "$APP"
mv "$APP/Contents/MacOS/Purlory" "$BIN"
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")
SMOKE_BUNDLE_ID="$BUNDLE_ID.ui-smoke.$(uuidgen)"
if defaults read "$SMOKE_BUNDLE_ID" >/dev/null 2>&1; then
    fail "격리 설정 식별자가 이미 존재합니다"
fi
plutil -replace CFBundleIdentifier -string "$SMOKE_BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "$SMOKE_EXECUTABLE" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$SMOKE_BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string "$SMOKE_BUNDLE_ID" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"
PREFERENCES_OWNED=1
# Exercise the retired-tool fallback without preconfiguring a model or AI consent.
defaults write "$SMOKE_BUNDLE_ID" purlory.sidebarSection -string margin

TOKEN="smoke$(uuidgen | tr -d '-')"
PROJECT_ID="33333333-3333-3333-3333-333333333333"
DOCUMENT_ID="44444444-4444-4444-4444-444444444444"
PROJECT_BODY="project-$TOKEN"
EDITED_BODY="edited-$TOKEN"
NEW_BODY="new-$TOKEN final"
PERSISTED_BODY="$EDITED_BODY$PROJECT_BODY"
WRITER_GENRE="FixtureGenre-$TOKEN"
WRITER_NAME="FixtureCharacter-$TOKEN"
WRITER_NOTE="FixtureNote-$TOKEN"
PROJECT_HASH=$(printf '%s' "$PROJECT_BODY" | shasum -a 256 | awk '{print $1}')
PROJECT_ROOT="$SMOKE_HOME/Documents/Purlory/Projects"
PROJECT_DIRECTORY="$PROJECT_ROOT/$PROJECT_ID"
PROJECT_DOCUMENT_PATH="Documents/$DOCUMENT_ID/$PROJECT_HASH.md"
mkdir -p "$PROJECT_DIRECTORY/Documents/$DOCUMENT_ID"
printf '%s' "$PROJECT_BODY" > "$PROJECT_DIRECTORY/$PROJECT_DOCUMENT_PATH"
printf '%s' "{\"schemaVersion\":1,\"id\":{\"rawValue\":\"$PROJECT_ID\"},\"title\":\"Isolated Project\",\"mode\":\"fiction\",\"documents\":[{\"id\":{\"rawValue\":\"$DOCUMENT_ID\"},\"title\":\"Isolated Manuscript\",\"kind\":\"manuscript\",\"relativePath\":\"$PROJECT_DOCUMENT_PATH\",\"contentHash\":\"$PROJECT_HASH\"}],\"trashedDocumentIDs\":[],\"assets\":[]}" \
    > "$PROJECT_DIRECTORY/project.json"
printf '%s' "{\"rawValue\":\"$PROJECT_ID\"}" > "$PROJECT_ROOT/active-project.json"

cat > "$SMOKE_ROOT/ui.applescript" <<'AS'
on findElement(rootElement, attributeName, expectedValue, remainingDepth)
    tell application "System Events"
        try
            if (value of attribute attributeName of rootElement) is expectedValue then return rootElement
        end try
        if remainingDepth ≤ 0 then return missing value
        repeat with childElement in UI elements of rootElement
            set matchedElement to my findElement(childElement, attributeName, expectedValue, remainingDepth - 1)
            if matchedElement is not missing value then return matchedElement
        end repeat
    end tell
    return missing value
end findElement

on findElementContaining(rootElement, attributeName, expectedValue, remainingDepth)
    tell application "System Events"
        try
            if (value of attribute attributeName of rootElement as text) contains expectedValue then return rootElement
        end try
        if remainingDepth ≤ 0 then return missing value
        repeat with childElement in UI elements of rootElement
            set matchedElement to my findElementContaining(childElement, attributeName, expectedValue, remainingDepth - 1)
            if matchedElement is not missing value then return matchedElement
        end repeat
    end tell
    return missing value
end findElementContaining
on activateTarget(targetProcess)
    tell application "System Events"
        repeat 20 times
            set frontmost of targetProcess to true
            delay 0.1
            if frontmost of targetProcess then return
        end repeat
    end tell
    error "Isolated app could not acquire foreground focus; no typing performed"
end activateTarget
on run argv
    set targetPID to (item 1 of argv) as integer
    set operation to item 2 of argv
    set expectedValue to item 3 of argv
    tell application "System Events"
        set targetProcess to first application process whose unix id is targetPID
        if unix id of targetProcess is not targetPID then error "Accessibility process resolved to another app"
        -- System Writing Tools can put a floating window ahead of the editor.
        set rootElement to my findElement(targetProcess, "AXIdentifier", "main", 1)
        if rootElement is missing value then error "메인 창 없음"
        if operation is "recovery-preview" then
            -- NSAlert is a separate modal window, outside the main editor tree.
            set previewText to my findElement(targetProcess, "AXIdentifier", "purlory.recovery.preview-text", 30)
            if previewText is missing value then error "Recovery preview missing"
            if (value of previewText as text) does not contain expectedValue then error "Recovery preview body mismatch"
        else if operation is "recovery-press" or operation is "recovery-present" then
            set targetElement to my findElement(targetProcess, "AXIdentifier", expectedValue, 30)
            if targetElement is missing value then set targetElement to my findElement(targetProcess, "AXTitle", expectedValue, 30)
            if targetElement is missing value then set targetElement to my findElement(targetProcess, "AXValue", expectedValue, 30)
            if targetElement is missing value then error "Recovery control missing: " & expectedValue
            if operation is "recovery-press" then click targetElement
        else if operation is "field-set" or operation is "field-equals" or operation is "field-absent" then
            set targetElement to my findElementContaining(rootElement, "AXIdentifier", expectedValue, 30)
            if operation is "field-absent" then
                if targetElement is not missing value then error "Unexpected writer field: " & expectedValue
            else
                if targetElement is missing value then error "Writer field missing: " & expectedValue
                set fieldValue to item 4 of argv
                if operation is "field-set" then
                    my activateTarget(targetProcess)
                    set value of attribute "AXFocused" of targetElement to true
                    tell targetProcess
                        key code 0 using command down
                        if fieldValue is "" then
                            key code 51
                        else
                            keystroke fieldValue
                        end if
                    end tell
                    delay 0.6
                else if (value of targetElement as text) is not fieldValue then
                    error "Writer field mismatch: " & expectedValue
                end if
            end if
        else if operation is "press-containing" then
            set targetElement to my findElementContaining(rootElement, "AXIdentifier", expectedValue, 30)
            if targetElement is missing value then error "Spatial card missing"
            click targetElement
        else if operation is "press" or operation is "present" or operation is "absent" then
            set targetElement to my findElement(targetProcess, "AXIdentifier", expectedValue, 30)
            if targetElement is missing value then set targetElement to my findElement(targetProcess, "AXDescription", expectedValue, 30)
            if targetElement is missing value then set targetElement to my findElement(targetProcess, "AXTitle", expectedValue, 30)
            if targetElement is missing value then set targetElement to my findElementContaining(targetProcess, "AXHelp", expectedValue, 30)
            if operation is "absent" then
                if targetElement is not missing value then error "숨겨야 할 컨트롤이 표시됨: " & expectedValue
            else
                if targetElement is missing value then error "필요한 컨트롤 없음: " & expectedValue
                if operation is "press" then click targetElement
            end if
        else if operation is "document-title" then
            set titleText to my findElement(rootElement, "AXValue", expectedValue, 30)
            if titleText is missing value then error "Document title text missing"
        else if operation is "begin-rename" then
            my activateTarget(targetProcess)
            tell targetProcess to click menu bar item "파일" of menu bar 1
            set renameCommand to my findElement(targetProcess, "AXTitle", "문서 이름 바꾸기", 30)
            if renameCommand is missing value then error "Rename menu command missing"
            click renameCommand
        else if operation is "field-focused" then
            set targetField to my findElement(rootElement, "AXIdentifier", expectedValue, 30)
            if targetField is missing value then error "Editable field missing: " & expectedValue
            if not (value of attribute "AXFocused" of targetField) then error "Editable field focus missing"
        else if operation is "submit-field" then
            my activateTarget(targetProcess)
            tell targetProcess to key code 36
        else if operation is "project-search" then
            my activateTarget(targetProcess)
            tell targetProcess to key code 3 using {command down, shift down}
        else if operation is "search-focused" then
            set searchField to my findElement(rootElement, "AXIdentifier", "purlory.workspace.search.query", 30)
            if searchField is missing value then error "Project search field missing"
            if not (value of attribute "AXFocused" of searchField) then error "Project search focus missing"
        else if operation is "resize" then
            set size of rootElement to {expectedValue as integer, 700}
        else if operation is "escape" then
            tell targetProcess to key code 53
        else if operation is "autocomplete" then
            set autocompleteControl to my findElement(targetProcess, "AXIdentifier", "purlory.workspace.autocomplete", 30)
            if autocompleteControl is missing value then error "자동완성 컨트롤 없음"
            if (value of attribute "AXTitle" of autocompleteControl as text) is not "자동완성 꺼짐" then error "자동완성 접근성 상태 유실"
        else if operation is "navigator" then
            if my findElement(rootElement, "AXIdentifier", "purlory.navigator", 30) is missing value then error "탐색기 없음"
        else if operation is "focused" then
            set editor to my findElement(rootElement, "AXIdentifier", "purlory.editor", 30)
            if editor is missing value then error "에디터 없음"
            if not (value of attribute "AXFocused" of editor) then error "에디터 포커스 유실"

        else
            set editor to my findElement(rootElement, "AXIdentifier", "purlory.editor", 30)
            if editor is missing value then error "에디터 없음"
            if operation is "type" then
                my activateTarget(targetProcess)
                set value of attribute "AXFocused" of editor to true
                delay 0.2
                if not (frontmost of targetProcess) then error "격리 앱 포커스 없음"
                if not (value of attribute "AXFocused" of editor) then error "에디터 포커스 없음"
                tell targetProcess to keystroke expectedValue
                delay 0.6
                -- Editing can replace the SwiftUI accessibility tree.
                set rootElement to my findElement(targetProcess, "AXIdentifier", "main", 1)
                set editor to my findElement(rootElement, "AXIdentifier", "purlory.editor", 30)
                if editor is missing value then error "입력 후 에디터 없음"
                if not (value of attribute "AXFocused" of editor) then error "입력 후 에디터 포커스 유실"
            else if operation is "equals" then
                if (value of editor as text) is not expectedValue then error "에디터 본문 불일치: " & (value of editor as text) & " / 기대: " & expectedValue
            else if operation is "image-body" then
                set imageBody to value of editor as text
                if imageBody does not start with "![](images/" then error "Managed image missing"
                return imageBody & "|"
            else if operation is "paste" then
                my activateTarget(targetProcess)
                set value of attribute "AXFocused" of editor to true
                tell targetProcess to key code 9 using command down
            else if operation is "end" then
                my activateTarget(targetProcess)
                set value of attribute "AXFocused" of editor to true
                tell targetProcess to key code 125 using command down
            else if operation is "undo" or operation is "redo" then
                my activateTarget(targetProcess)
                set value of attribute "AXFocused" of editor to true
                -- Physical shortcuts also work with the active Hangul input source.
                if operation is "undo" then
                    tell targetProcess to key code 6 using command down
                else
                    tell targetProcess to key code 6 using {command down, shift down}
                end if
            else
                error "알 수 없는 UI 작업: " & operation
            end if
        end if
    end tell
end run
AS

launch() {
    check_original
    open -n --env "CFFIXED_USER_HOME=$SMOKE_HOME" \
        --env "HF_HOME=$SMOKE_HOME/ModelDownloads" "$APP"
    PID=""
    for _ in $(seq 1 15); do
        sleep 1
        PID=$(find_pid)
        [ -n "$PID" ] && break
    done
    owned_pid || fail "격리 앱 실행 실패"
    sleep 8
    check_original
}

terminate() {
    owned_pid || fail "종료 대상 PID 확인 실패"
    osascript -l JavaScript - "$PID" <<'JXA' >/dev/null
ObjC.import('AppKit');
function run(argv) {
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0]));
    if (!app.terminate) throw new Error('정상 종료 요청 거절');
}
JXA
    for _ in $(seq 1 40); do
        kill -0 "$PID" 2>/dev/null || { PID=""; return; }
        sleep 0.5
    done
    fail "정상 종료 시간 초과"
}

ui() {
    owned_pid || fail "격리 실행 파일 PID 확인 실패"
    osascript "$SMOKE_ROOT/ui.applescript" "$PID" "$1" "${2:-}" "${3:-}" >/dev/null
    case "$1" in press|resize|recovery-press) sleep 0.3 ;; esac
}

wait_ui() {
    operation=$1
    expected=$2
    for _ in $(seq 1 40); do
        if osascript "$SMOKE_ROOT/ui.applescript" "$PID" "$operation" "$expected" >/dev/null 2>&1; then
            return
        fi
        sleep 0.25
    done
    ui "$operation" "$expected"
}

open_pouch_menu() {
    if ! osascript "$SMOKE_ROOT/ui.applescript" "$PID" present "purlory.workspace.pouch.more" >/dev/null 2>&1; then
        ui press "purlory.writer-tools.compatibility"
    fi
    ui press "purlory.workspace.pouch.more"
}

new_document() {
    open_pouch_menu
    ui press "purlory.workspace.new-document"
}

open_writer_information() {
    open_pouch_menu
    ui press "purlory.workspace.more.characters"
    wait_ui present "purlory.writer.genre"
}

close_writer_information() {
    # Close the writer-information tile and return to the retained editor.
    ui press "purlory.tile.close.characters"
}

open_manuscript_versions() {
    open_pouch_menu
    ui press "purlory.workspace.object-settings"
    wait_ui present "purlory.workspace.versions"
    ui press "purlory.workspace.versions"
    wait_ui present "purlory.versions.capture-document"
}

version_record_path() {
    python3 - "$PROJECT_DIRECTORY" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
manifest = json.loads((root / 'project.json').read_text())
records = [record for key, record in manifest.get('userData', {}).items()
           if key.startswith('manuscript-version-')]
if len(records) != 1:
    raise SystemExit(1)
path = root / records[0]['relativePath']
if path.is_symlink() or not path.resolve().is_relative_to(root / 'UserData' / 'records'):
    raise SystemExit('Snapshot record outside UserData')
if not path.is_file():
    raise SystemExit(1)
print(path)
PY
}

assert_autocomplete_disabled() {
    open_pouch_menu
    wait_ui autocomplete ""
    ui escape ""
    ui press "purlory.workspace.pouch.dismiss"
}

assert_isolated_project_mode() {
    [ ! -e "$SMOKE_HOME/Documents/Purlory/entries.json" ] \
        && [ ! -L "$SMOKE_HOME/Documents/Purlory/entries.json" ] \
        || fail "정상 프로젝트 모드가 entries.json을 만들었습니다"
    [ ! -e "$SMOKE_HOME/ModelDownloads" ] \
        || fail "명시적 허가 없이 모델 다운로드 디렉터리가 생겼습니다"
}

launch
wait_ui equals "$PROJECT_BODY"
ui present "purlory.workspace.tiles"
ui present "purlory.writer-tools.compatibility"
ui type "$EDITED_BODY"
wait_ui equals "$PERSISTED_BODY"
ui undo ""
wait_ui equals "$PROJECT_BODY"
ui redo ""
wait_ui equals "$PERSISTED_BODY"
# A saved original survives editing, native undo/redo, relaunch and recovery.
open_manuscript_versions
ui press "purlory.versions.capture-document"
for _ in $(seq 1 40); do
    if VERSION_RECORD=$(version_record_path); then break; fi
    sleep 0.25
done
[ -n "$VERSION_RECORD" ] || fail "Manuscript version was not saved"
[ "$(plutil -extract text raw -o - "$VERSION_RECORD")" = "$PERSISTED_BODY" ] \
    || fail "Manuscript version did not retain the original"
VERSION_ID=$(plutil -extract id raw -o - "$VERSION_RECORD")
VERSION_HASH=$(file_hash "$VERSION_RECORD")
ui press "purlory.versions.close"
wait_ui focused ""
ui end ""
VERSION_SUFFIX=" version-$TOKEN"
ui type "$VERSION_SUFFIX"
wait_ui equals "$PERSISTED_BODY$VERSION_SUFFIX"
open_manuscript_versions
ui press "purlory.versions.compare.$VERSION_ID"
wait_ui present "purlory.versions.restore-all"
ui press "purlory.versions.restore-all"
ui press "purlory.versions.close"
wait_ui focused ""
wait_ui equals "$PERSISTED_BODY"
ui undo ""
wait_ui equals "$PERSISTED_BODY$VERSION_SUFFIX"
ui redo ""
wait_ui equals "$PERSISTED_BODY"
# Implemented Write/Map modes remain available without model setup (#302).
open_pouch_menu
ui present "purlory.workspace.mode.write"
ui present "purlory.workspace.mode.map"
ui escape ""
ui press "purlory.workspace.pouch.dismiss"
ui absent "리빙 마진"
ui absent "문서로 돌아가기"
ui absent "purlory.ghost-shortcut-hint"
ui resize 1250
assert_autocomplete_disabled
open_pouch_menu
ui press "파일 목록 숨기기"
open_pouch_menu
ui press "파일 목록 보이기"
ui navigator
ui press "purlory.navigator.close"
ui focused
ui project-search ""
wait_ui search-focused ""
ui field-set "purlory.workspace.search.query" "keyboard-$TOKEN"
wait_ui equals "$PERSISTED_BODY"
ui field-equals "purlory.workspace.search.query" "keyboard-$TOKEN"
ui field-set "purlory.workspace.search.query" ""
ui press "purlory.tile.close.search"
ui focused
open_pouch_menu
ui press "purlory.workspace.navigator-toggle"
ui focused
ui begin-rename ""
wait_ui field-focused "purlory.navigator.rename"
ui field-set "purlory.navigator.rename" "renamed-$TOKEN"
ui resize 860
ui field-equals "purlory.navigator.rename" "renamed-$TOKEN"
ui field-focused "purlory.navigator.rename"
ui resize 1250
ui field-equals "purlory.navigator.rename" "renamed-$TOKEN"
ui field-focused "purlory.navigator.rename"
ui submit-field ""
wait_ui document-title "renamed-$TOKEN"
ui field-absent "purlory.navigator.rename"
wait_ui equals "$PERSISTED_BODY"
for _ in $(seq 1 40); do
    [ "$(plutil -extract documents.0.title raw -o - "$PROJECT_DIRECTORY/project.json")" = "renamed-$TOKEN" ] && break
    sleep 0.25
done
[ "$(plutil -extract documents.0.title raw -o - "$PROJECT_DIRECTORY/project.json")" = "renamed-$TOKEN" ] \
    || fail "Renamed document title did not persist"
open_writer_information
ui field-set "purlory.writer.genre" "$WRITER_GENRE"
ui press "purlory.writer.add-character"
ui field-set "purlory.writer.character.name." "$WRITER_NAME"
ui field-set "purlory.writer.character.note." "$WRITER_NOTE"
close_writer_information
ui focused
ui resize 860
assert_autocomplete_disabled
open_writer_information
ui absent "리빙 마진"
close_writer_information
ui focused
ui navigator
new_document
wait_ui equals ""
ui type "$NEW_BODY"
wait_ui equals "$NEW_BODY"
ui undo ""
wait_ui equals "new-$TOKEN "
ui redo ""
wait_ui equals "$NEW_BODY"
open_writer_information
ui field-equals "purlory.writer.genre" ""
ui field-absent "purlory.writer.character.name."
close_writer_information
ui press "purlory.document.$DOCUMENT_ID"
wait_ui equals "$PERSISTED_BODY"
# Address the generated document by its persisted identity, not a localized AX label.
NEW_DOCUMENT_ID=$(plutil -extract documents.1.id.rawValue raw -o - "$PROJECT_DIRECTORY/project.json") \
    || fail "새 문서 식별자 저장 실패"
ui press "purlory.document.$NEW_DOCUMENT_ID"
wait_ui equals "$NEW_BODY"
terminate
verify_project_state "$SMOKE_HOME/Documents/Purlory" "$PERSISTED_BODY" >/dev/null
verify_project_state "$SMOKE_HOME/Documents/Purlory" "$NEW_BODY" >/dev/null
assert_isolated_project_mode

writer_record_path() {
    writer_key="writer-$(printf '%s' "$DOCUMENT_ID" | tr '[:upper:]' '[:lower:]')"
    relative=$(plutil -extract "userData.$writer_key.relativePath" raw -o - "$PROJECT_DIRECTORY/project.json") \
        || fail "Writer record missing from project manifest"
    case "$relative" in UserData/records/*/*.data) ;; *) fail "Writer record outside UserData" ;; esac
    printf '%s/%s' "$PROJECT_DIRECTORY" "$relative"
}
WRITER_RECORD=$(writer_record_path)
[ "$(plutil -extract genre raw -o - "$WRITER_RECORD")" = "$WRITER_GENRE" ] || fail "Writer genre was not persisted"
[ "$(plutil -extract characters.0.name raw -o - "$WRITER_RECORD")" = "$WRITER_NAME" ] || fail "Writer character was not persisted"
[ "$(plutil -extract characters.0.note raw -o - "$WRITER_RECORD")" = "$WRITER_NOTE" ] || fail "Writer note was not persisted"

launch
wait_ui equals "$NEW_BODY"
ui press "purlory.document.$DOCUMENT_ID"
wait_ui equals "$PERSISTED_BODY"
open_writer_information
ui field-equals "purlory.writer.genre" "$WRITER_GENRE"
ui field-equals "purlory.writer.character.name." "$WRITER_NAME"
ui field-equals "purlory.writer.character.note." "$WRITER_NOTE"
ui press "인물 삭제"
ui field-absent "purlory.writer.character.name."
ui field-set "purlory.writer.genre" ""
close_writer_information
ui focused
terminate
verify_project_state "$SMOKE_HOME/Documents/Purlory" "$PERSISTED_BODY" >/dev/null
verify_project_state "$SMOKE_HOME/Documents/Purlory" "$NEW_BODY" >/dev/null
assert_isolated_project_mode
check_original
WRITER_RECORD=$(writer_record_path)
if plutil -extract characters.0 json -o - "$WRITER_RECORD" >/dev/null 2>&1; then fail "Deleted character survived"; fi
if plutil -extract genre raw -o - "$WRITER_RECORD" >/dev/null 2>&1; then fail "Cleared genre survived"; fi

# A PNG-only system clipboard must enable the standard Paste command. No image
# file URL or text flavor is offered, and the original clipboard stays in memory.
launch
new_document
wait_ui equals ""
swift scripts/fixtures/clipboard-image.swift "$SMOKE_ROOT/clipboard-ready" > "$SMOKE_ROOT/clipboard.log" 2>&1 &
CLIPBOARD_PID=$!
for attempt in $(seq 1 30); do
    [ -f "$SMOKE_ROOT/clipboard-ready" ] && break
    kill -0 "$CLIPBOARD_PID" 2>/dev/null || fail "Clipboard fixture failed"
    sleep 0.5
done
[ -f "$SMOKE_ROOT/clipboard-ready" ] || fail "Clipboard fixture did not start"
ui paste ""
wait_ui image-body "" >/dev/null
restore_clipboard
IMAGE_BODY=$(osascript "$SMOKE_ROOT/ui.applescript" "$PID" image-body "")
IMAGE_BODY=${IMAGE_BODY%|}
ui undo ""
wait_ui equals ""
ui redo ""
wait_ui equals "$IMAGE_BODY"
terminate
verify_project_state "$SMOKE_HOME/Documents/Purlory" "$IMAGE_BODY" >/dev/null
ASSET_PATH=$(plutil -extract assets.0.file.relativePath raw -o - "$PROJECT_DIRECTORY/project.json")
ASSET_HASH=$(plutil -extract assets.0.file.contentHash raw -o - "$PROJECT_DIRECTORY/project.json")
case "$ASSET_PATH" in Assets/*) ;; *) fail "Image was not stored as a managed asset" ;; esac
[ "$(file_hash "$PROJECT_DIRECTORY/$ASSET_PATH")" = "$ASSET_HASH" ] || fail "Pasted image hash mismatch"
launch
wait_ui equals "$IMAGE_BODY"
terminate
verify_project_state "$SMOKE_HOME/Documents/Purlory" "$IMAGE_BODY" >/dev/null
check_original

# Load an existing math document, then exercise native editing and persistence.
# Add this fixture only while the isolated app is closed; parsing delimiters
# under a real input source is a separate typing contract (#241).
MATH_DOCUMENT_ID=$(python3 - "$PROJECT_DIRECTORY" <<'PY'
import hashlib, json, pathlib, sys, uuid
project = pathlib.Path(sys.argv[1])
manifest = project / "project.json"
data = json.loads(manifest.read_text())
document_id = str(uuid.uuid4()).upper()
body = b"$$E=mc^2$$"
digest = hashlib.sha256(body).hexdigest()
relative = f"Documents/{document_id}/{digest}.md"
content = project / relative
content.parent.mkdir()
content.write_bytes(body)
data["documents"].append({"id": {"rawValue": document_id}, "title": "Math Fixture",
    "kind": "manuscript", "contentHash": digest, "relativePath": relative})
manifest.write_text(json.dumps(data))
print(document_id)
PY
)
launch
ui press "purlory.document.$MATH_DOCUMENT_ID"
wait_ui equals 'E=mc^2'
ui press "purlory.document.$DOCUMENT_ID"
wait_ui equals "$PERSISTED_BODY"
ui press "purlory.document.$MATH_DOCUMENT_ID"
wait_ui equals 'E=mc^2'
ui end ""
ui type "x"
wait_ui equals 'E=mc^2x'
ui undo ""
wait_ui equals 'E=mc^2'
ui redo ""
wait_ui equals 'E=mc^2x'
terminate
verify_project_state "$SMOKE_HOME/Documents/Purlory" '$$E=mc^2x$$' >/dev/null
launch
wait_ui equals 'E=mc^2x'
terminate
verify_project_state "$SMOKE_HOME/Documents/Purlory" '$$E=mc^2x$$' >/dev/null
check_original

# Verify the complete double-dollar typing path, independently of the loaded
# math fixture. Begin from prose so typing attributes belong to a plain block.
launch
ui press "purlory.document.$DOCUMENT_ID"
wait_ui equals "$PERSISTED_BODY"
new_document
wait_ui equals ""
ui type '$$E=mc^2$$'
wait_ui equals 'E=mc^2'
terminate
verify_project_state "$SMOKE_HOME/Documents/Purlory" '$$E=mc^2$$' >/dev/null
launch
wait_ui equals 'E=mc^2'
terminate
verify_project_state "$SMOKE_HOME/Documents/Purlory" '$$E=mc^2$$' >/dev/null
check_original

# Exercise recovery through the actual startup error screen and native modal.
# Only the closed, synthetic project is damaged; keep a byte-exact source snapshot.
cp "$PROJECT_DIRECTORY/project.json" "$SMOKE_ROOT/recovery-backup.json"
printf '%s' 'corrupt current fixture' > "$PROJECT_DIRECTORY/project.json"
printf '%s' 'corrupt backup fixture' > "$PROJECT_DIRECTORY/previous-project.json"
RECOVERY_MARKER_HASH=$(file_hash "$PROJECT_ROOT/active-project.json")
snapshot_recovery_source() {
    python3 - "$PROJECT_DIRECTORY" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
snapshot = {}
for path in sorted(root.rglob('*')):
    if path.is_symlink():
        raise SystemExit('Unexpected symlink in isolated recovery fixture')
    if path.is_file():
        snapshot[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
print(json.dumps(snapshot, sort_keys=True))
PY
}
assert_recovery_source() {
    snapshot_recovery_source > "$SMOKE_ROOT/recovery-observed.json"
    cmp -s "$SMOKE_ROOT/recovery-source.json" "$SMOKE_ROOT/recovery-observed.json" \
        || fail "Recovery changed the damaged source"
}
snapshot_recovery_source > "$SMOKE_ROOT/recovery-source.json"
launch
wait_ui present "purlory.recovery.preview"
ui press "purlory.recovery.preview"
wait_ui recovery-present "이전 저장본을 복구하지 못했습니다"
ui recovery-press "확인"
wait_ui present "purlory.recovery.preview"
[ "$(file_hash "$PROJECT_ROOT/active-project.json")" = "$RECOVERY_MARKER_HASH" ] \
    || fail "Invalid backup changed the active project"
assert_recovery_source
terminate

# Make the previous revision valid while retaining the damaged current manifest.
cp "$SMOKE_ROOT/recovery-backup.json" "$PROJECT_DIRECTORY/previous-project.json"
snapshot_recovery_source > "$SMOKE_ROOT/recovery-source.json"
launch
wait_ui present "purlory.recovery.preview"
ui press "purlory.recovery.preview"
wait_ui recovery-preview "$PERSISTED_BODY"
ui recovery-press "purlory.recovery.cancel"
wait_ui present "purlory.recovery.preview"
[ "$(file_hash "$PROJECT_ROOT/active-project.json")" = "$RECOVERY_MARKER_HASH" ] \
    || fail "Cancel changed the active project"
assert_recovery_source
ui press "purlory.recovery.preview"
wait_ui recovery-preview "$PERSISTED_BODY"
ui recovery-press "purlory.recovery.open-copy"
wait_ui equals "$PERSISTED_BODY"
ui focused
RECOVERED_ID=$(plutil -extract rawValue raw -o - "$PROJECT_ROOT/active-project.json")
[ "$RECOVERED_ID" != "$PROJECT_ID" ] || fail "Recovery reused the damaged project identity"
ui press "purlory.document.$MATH_DOCUMENT_ID"
wait_ui equals 'E=mc^2x'
ui focused
terminate
assert_recovery_source
verify_project_state "$SMOKE_HOME/Documents/Purlory" "$PERSISTED_BODY" >/dev/null
verify_project_state "$SMOKE_HOME/Documents/Purlory" "$NEW_BODY" >/dev/null
verify_project_state "$SMOKE_HOME/Documents/Purlory" "$IMAGE_BODY" >/dev/null
verify_project_state "$SMOKE_HOME/Documents/Purlory" '$$E=mc^2x$$' >/dev/null
RECOVERED_DIRECTORY="$PROJECT_ROOT/$RECOVERED_ID"
[ "$(file_hash "$RECOVERED_DIRECTORY/$ASSET_PATH")" = "$ASSET_HASH" ] \
    || fail "Recovery lost the managed image"
[ "$(file_hash "$RECOVERED_DIRECTORY/${WRITER_RECORD#"$PROJECT_DIRECTORY/"}")" = "$(file_hash "$WRITER_RECORD")" ] \
    || fail "Recovery changed durable writer data"
[ "$(file_hash "$VERSION_RECORD")" = "$VERSION_HASH" ] \
    || fail "Editing or recovery changed the saved original"
[ "$(file_hash "$RECOVERED_DIRECTORY/${VERSION_RECORD#"$PROJECT_DIRECTORY/"}")" = "$VERSION_HASH" ] \
    || fail "Recovery lost the manuscript version"
assert_isolated_project_mode
launch
wait_ui equals 'E=mc^2x'
terminate
assert_recovery_source
check_original

PASSED=1
echo "✓ UI 스모크 통과 — 원고 기록 저장·비교·복원 · 문서 전환 · 작가 설정 · 이미지·수식 편집·Undo·Redo·재실행 · 포커스 · 복구 실패·취소·사본 열기 · manifest 검증"
