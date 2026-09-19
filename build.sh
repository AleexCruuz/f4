#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Builds F4, assembles the .app bundle, signs it and (with --install)
# installs it into /Applications.
#
# The bundle is staged in a temporary directory outside ~/Documents: folders synced
# by File Provider gain xattrs (com.apple.provenance etc.) that invalidate codesign.
set -euo pipefail
cd "$(dirname "$0")"

# The icon catalog and the bundle are staged in temp dirs; sweep both however
# the script ends.
ICON_TMP=""
STAGE_TMP=""

cleanup() {
    [[ -n "$ICON_TMP" ]] && rm -rf "$ICON_TMP"
    [[ -n "$STAGE_TMP" ]] && rm -rf "$STAGE_TMP"
    return 0
}
trap cleanup EXIT
# zsh runs the EXIT trap when the script is hung up, but not when it is
# interrupted or terminated; route those through exit so a Ctrl-C partway
# into the build sweeps like any other ending.
trap 'exit 1' INT TERM HUP

# Flags: --dev builds the local-only "F4 (Developer)" variant (its own
# bundle id, so it coexists with the official app); --install puts it in /Applications.
DEV=0
INSTALL=0
TEST=0
TEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dev)     DEV=1 ;;
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
        --test-suite=*) TEST=1; TEST_ARGS+=("--suite=${arg#*=}") ;;
        --list-tests) TEST=1; TEST_ARGS+=(--list) ;;
    esac
done

if (( DEV )); then
    APP_NAME="F4 (Developer)"
    EXECUTABLE="F4Developer"
    APP_BUNDLE_ID="com.f4.utils.dev"
    BUILD_VARIANT_FLAGS=(-D F4_DEVELOPMENT)
    APP_OPTIMIZATION_FLAGS=(-Onone)
    BUILD_CONFIGURATION="debug"
else
    APP_NAME="F4"
    EXECUTABLE="F4"
    APP_BUNDLE_ID="com.f4.utils"
    BUILD_VARIANT_FLAGS=()
    APP_OPTIMIZATION_FLAGS=(-O)
    BUILD_CONFIGURATION="release"
fi
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"
# Now Playing is read through /usr/bin/perl loading this library; see
# Sources/NowPlayingAdapter. Staged under Contents/Frameworks, signed on its own.
NOW_PLAYING_ADAPTER_ID="$APP_BUNDLE_ID.now-playing"
NOW_PLAYING_ADAPTER="libF4NowPlaying.dylib"
TARGET="arm64-apple-macosx14.0"
ENTITLEMENTS="Resources/F4.entitlements"
LEGACY_IDENTITY="F4 Utils Signing"

developer_id_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true
}

# A find-identity listing also names certificates codesign then rejects (an
# expired one fails the build with errSecInternalComponent), and -v excludes
# every self-signed one; ask codesign itself with a throwaway copy of /bin/echo.
legacy_identity_installed() {
    local probe signed=1
    # A locked keychain still lists its identities but cannot sign with them,
    # and this one is locked after every reboot; unlock it before asking.
    security unlock-keychain -p f4-signing \
        "$HOME/Library/Keychains/f4-signing.keychain-db" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$probe" \
        >/dev/null 2>&1 && signed=0
    rm -f "$probe"
    return $signed
}

# Any build that lands in /Applications needs a stable signature, not just the
# Developer one: macOS ties Accessibility and Screen Recording grants to the
# exact binary hash, so an ad-hoc rebuild orphans them while System Settings
# keeps showing them as granted, and no new prompt ever appears. A plain
# --install strands them under the released bundle id, on the app the user
# actually relies on. When no identity is installed, create the stable local one
# up front instead of falling through to ad-hoc — setup-signing.sh is free,
# offline and idempotent. Gating on the install rather than the variant keeps
# this off CI, where neither ci.yml nor release.yml passes --install.
if (( DEV || INSTALL )) && [[ -z "$(developer_id_identity)" ]] \
    && ! legacy_identity_installed; then
    echo "▸ No signing identity installed; creating the stable local one…"
    if ! ./Tools/setup-signing.sh; then
        echo "  ⚠ Tools/setup-signing.sh failed; signing ad-hoc instead." >&2
        echo "    Accessibility and Screen Recording grants will not survive rebuilds:" >&2
        echo "    System Settings will show them as granted while the app is not trusted." >&2
        echo "    After fixing the identity, clear the stale grant once with:" >&2
        echo "      tccutil reset Accessibility $APP_BUNDLE_ID" >&2
    fi
fi

codesign_with_timestamp_retry() {
    local attempt
    for attempt in 1 2 3; do
        if /usr/bin/codesign "$@"; then
            return 0
        fi
        if (( attempt < 3 )); then
            echo "  Developer ID signing failed; retrying ($((attempt + 1))/3)"
            sleep "$attempt"
        fi
    done
    return 1
}

write_swift_output_file_map() {
    local output_file="$1"
    local object_dir="$2"
    shift 2
    local source artifact

    {
        print -r -- "{"
        print -r -- "  \"\": {"
        print -r -- "    \"swift-dependencies\": \"$object_dir/master.swiftdeps\""
        print -r -- "  }"
        for source in "$@"; do
            artifact="${source//\//__}"
            artifact="${artifact%.swift}"
            print -r -- ","
            print -r -- "  \"$source\": {"
            print -r -- "    \"object\": \"$object_dir/$artifact.o\","
            print -r -- "    \"swift-dependencies\": \"$object_dir/$artifact.swiftdeps\""
            print -r -- "  }"
        done
        print -r -- "}"
    } > "$output_file"
}

finalize_installed_bundle_after_child() {
    local bundle="$1"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
    local devid
    devid="$(developer_id_identity)"

    echo "▸ Finalizing installed signature…"
    sleep 3
    if [[ -n "$devid" ]]; then
        [[ -f "$helper" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$FAN_HELPER_ID" --sign "$devid" "$helper"
        [[ -f "$adapter" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$devid" "$adapter"
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$devid" "$bundle"
    elif legacy_identity_installed; then
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign "$LEGACY_IDENTITY" "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$LEGACY_IDENTITY" "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$bundle"
    else
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign - "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign - "$bundle"
    fi
    [[ -f "$helper" ]] && /usr/bin/codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && /usr/bin/codesign --verify --strict "$adapter"
    /usr/bin/codesign --verify --deep --strict "$bundle"
    echo "✓ Signature ready: $bundle"
}

if (( INSTALL && ! TEST )) && [[ "${F4_INSTALL_CHILD:-0}" != "1" ]]; then
    F4_INSTALL_CHILD=1 "$0" "$@"
    child_status=$?
    if (( child_status != 0 )); then
        exit "$child_status"
    fi
    finalize_installed_bundle_after_child "/Applications/$APP_NAME.app"
    exit 0
fi

# Prefer the macOS 26 SDK when present: the 27 SDK turns SwiftUI property wrappers
# into macros (SwiftUIMacros plugin) that the Command Line Tools cannot load yet.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
VM_STATISTICS_COMPAT_FLAGS=(-I Sources/VMStatisticsCompat)
HID_EVENT_SYSTEM_FLAGS=(-I Sources/HIDEventSystem)
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    # Swift 6.4 can read the SDK 26 interfaces when given their compiler version.
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

# The defaults migrations under test need a real UserDefaults suite, and every
# suite leaves an empty plist in ~/Library/Preferences. The tests already clear
# the domains, but cfprefsd writes the emptied file back out around the time the
# process that owned it exits, so only a caller that outlives the run can remove
# them. `MetricsTests` keeps every suite name inside these two namespaces (a
# check in the test file holds it to that), which is what makes this sweep
# complete rather than a list to keep in step by hand.
discard_test_preferences() {
    local preferences="${1:-$HOME/Library/Preferences}" name attempt
    local survivors=0 quiet_passes=0
    # cfprefsd can recreate an emptied domain after the first removal. Require
    # two quiet checks, but keep a hard limit so persistent failures still fail CI.
    for attempt in {1..10}; do
        for name in "vorss.tests." "com.f4.tests."; do
            rm -f "$preferences"/$name*.plist(N)
        done
        rm -f "$preferences/metrics-tests.plist"
        sleep 0.2
        survivors=$(find "$preferences" -maxdepth 1 \
            \( -name "vorss.tests.*.plist" -o -name "com.f4.tests.*.plist" \
               -o -name "metrics-tests.plist" \) 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$survivors" == "0" ]]; then
            quiet_passes=$((quiet_passes + 1))
            if (( quiet_passes == 2 )); then return 0; fi
        else
            quiet_passes=0
        fi
    done
    echo "✗ test preferences did not settle in $preferences ($survivors remaining)" >&2
    return 1
}

# Standalone automated tests: pure contracts plus isolated disk, subprocess,
# keyboard-data and media fixtures. No application windows or device capture.
if (( TEST )); then
    python3 Tests/generate_sources.py
    TEST_OBJECT_DIR="build/objects/tests"
    mkdir -p "$TEST_OBJECT_DIR"
    TEST_SOURCES=(
        Sources/F4/Services/Media/MediaSupport.swift
        Sources/F4/Core/QuitProtectionSupport.swift
        Sources/F4/Core/QuitProtectionStrings.swift
        Sources/F4/Core/Defaults.swift
        Sources/F4/Core/NotchStrings.swift
        Sources/F4/Core/NotchTourStrings.swift
        Sources/F4/Core/NotchEditorStrings.swift
        Sources/F4/Core/NotchActivityStrings.swift
        Sources/F4/Services/Notch/NotchTimerSupport.swift
        Sources/F4/Services/Notch/NotchTimerAlert.swift
        Sources/F4/Services/Notch/NotchAccessorySupport.swift
        Sources/F4/Services/QuickTools/CameraPreviewSupport.swift
        Sources/F4/Core/NotchMusicExtrasStrings.swift
        Sources/F4/Services/Notch/NotchLyricsSupport.swift
        Sources/F4/Services/Notch/NotchQueueSupport.swift
        Sources/F4/Core/NotchFilesStrings.swift
        Sources/F4/Services/Notch/NotchFileToolsSupport.swift
        Sources/F4/Services/Notch/NotchDownloadSupport.swift
        Sources/F4/Services/Notch/NotchDownloadProgressObserver.swift
        Sources/F4/Core/NotchCalendarStrings.swift
        Sources/F4/Core/NotchNotificationStrings.swift
        Sources/F4/Core/NotchGestureStrings.swift
        Sources/F4/Services/Notch/NotchGestureSupport.swift
        Sources/F4/Services/Notch/NotchSliderEditing.swift
        Sources/F4/Services/Notch/NotchNotificationSupport.swift
        Sources/F4/Services/Notch/NotchNotificationReaderCore.swift
        Sources/F4/Services/Notch/NotchCalendarSupport.swift
        Sources/F4/Services/Notch/NotchSupport.swift
        Sources/F4/Services/Notch/NotchAudioLevelSupport.swift
        Sources/F4/Services/Notch/NotchVolumeKeyGate.swift
        Sources/F4/Services/Notch/NotchMusicSupport.swift
        Sources/F4/UI/Notch/NotchEqualizerBars.swift
        Sources/F4/Services/Notch/NotchMusicAutomationSupport.swift
        Sources/F4/Services/Notch/NotchMusicAutomation.swift
        Sources/F4/Services/Notch/NotchPlaybackSource.swift
        Sources/F4/Services/Notch/NotchPlaybackCommand.swift
        Sources/F4/Services/Notch/NotchMusicCommandWriter.swift
        Sources/F4/Core/FeatureCatalog.swift
        Sources/F4/Core/FeaturePresets.swift
        Sources/F4/Core/OnboardingSupport.swift
        Sources/F4/Core/OnboardingStrings.swift
        Sources/F4/Core/FeatureHubStrings.swift
        Sources/F4/Core/ShortcutSettingsStrings.swift
        Sources/F4/Core/SettingsBackupSupport.swift
        Sources/F4/Core/BackupStrings.swift
        Sources/F4/Core/SnippetStrings.swift
        Sources/F4/Core/AlertSoundStrings.swift
        Sources/F4/Core/BrightnessStrings.swift
        Sources/F4/Core/MediaImageStrings.swift
        Sources/F4/Core/QuickToggleStrings.swift
        Sources/F4/Core/ScreenshotStrings.swift
        Sources/F4/Core/RecentCaptureStrings.swift
        Sources/F4/Core/RecorderStrings.swift
        Sources/F4/Core/RecorderShareStrings.swift
        Sources/F4/Core/CameraPreviewStrings.swift
        Sources/F4/Core/ScratchpadStrings.swift
        Sources/F4/Core/FinderRenameStrings.swift
        Sources/F4/Core/CommandBarStrings.swift
        Sources/F4/Core/FeedbackStrings.swift
        Sources/F4/Core/RadialMenuStrings.swift
        Sources/F4/Core/MenuBarAppearanceStrings.swift
        Sources/F4/Core/AppAppearance.swift
        Sources/F4/Core/AppearanceStrings.swift
        Sources/F4/Core/BatteryTimeStrings.swift
        Sources/F4/Core/KeepAwakeStrings.swift
        Sources/F4/Core/BluetoothSleepStrings.swift
        Sources/F4/Core/PermissionGuideStrings.swift
        Sources/F4/Core/FanControlStrings.swift
        Sources/F4/Services/FanControl/FanControlSupport.swift
        Sources/F4/Services/Snippets/TextSnippetSupport.swift
        Sources/F4/Services/RadialMenu/RadialMenuSupport.swift
        Sources/F4/Services/QuickTools/ScratchpadSupport.swift
        Sources/F4/Services/QuickTools/ScratchpadStore.swift
        Sources/F4/Services/KillProcess/KillProcessSupport.swift
        Sources/F4/Services/Recorder/RecorderSupport.swift
        Sources/F4/Services/Recorder/RecorderSampleTiming.swift
        Sources/F4/Services/Recorder/RecorderWriter.swift
        Sources/F4/Services/Recorder/RecorderCaptureEngine.swift
        Sources/F4/Services/Recorder/RecorderComposition.swift
        Sources/F4/Services/Recorder/RecordingSharingSupport.swift
        Sources/F4/Services/PrivateFileStore.swift
        Sources/F4/Services/Recorder/RecorderTakeStore.swift
        Sources/F4/Services/Recorder/RecorderPresetImageStore.swift
        Sources/F4/Services/Recorder/RecorderMotion.swift
        Sources/F4/Services/Recorder/RecorderPointerTrack.swift
        Sources/F4/Services/Recorder/RecorderTypingTrack.swift
        Sources/F4/Services/Recorder/RecorderTimeline.swift
        Sources/F4/Services/Recorder/RecorderTextOverlay.swift
        Sources/F4/Services/Recorder/RecorderImageOverlay.swift
        Sources/F4/Services/Recorder/RecorderBlurRegion.swift
        Sources/F4/Services/Recorder/RecorderEditDocument.swift
        Sources/F4/Core/AppInfo.swift
        Sources/F4/Core/GlobalShortcut.swift
        Sources/F4/Core/SymbolicHotKeys.swift
        Sources/F4/Services/SystemShortcutTakeoverSupport.swift
        Sources/F4/Core/Localization.swift
        Sources/F4/Core/Localizations/Strings+*.swift
        Sources/F4/Core/FeatureStrings.swift
        Sources/F4/Core/KillProcessStrings.swift
        Sources/F4/Core/WhatsAppDownloadStrings.swift
        Sources/F4/Core/WhatsAppOrganizerStrings.swift
        Sources/F4/Core/ReleaseNotes.swift
        Sources/F4/Core/URLCleaning.swift
        Sources/F4/Services/GeneralPasteboardAccess.swift
        Sources/F4/Services/Clipboard/ClipboardHistoryWrite.swift
        Sources/F4/Services/Audio/MixerRoutingSupport.swift
        Sources/F4/Services/Audio/MusicLaunchSupport.swift
        Sources/F4/Services/Bluetooth/BluetoothSleepSupport.swift
        Sources/F4/UI/MenuPanel/MixerPercentNativeTextField.swift
        Sources/F4/UI/MenuPanel/MixerAppDragSource.swift
        Sources/F4/Services/Audio/BoostLimiter.swift
        Sources/F4/Services/Audio/MixerRender.swift
        Sources/F4/Services/Audio/PreciseVolumeRollerSupport.swift
        Sources/F4/Services/DockPreview/DockPreviewSupport.swift
        Sources/F4/Services/Homebrew/HomebrewSupport.swift
        Sources/F4/Services/AppUpdates/AppUpdatesSupport.swift
        Sources/F4/Services/AppUpdates/AppUpdateFeedSupport.swift
        Sources/F4/Core/AppUpdateStrings.swift
        Sources/F4/Core/DiskImageInstallerStrings.swift
        Sources/F4/Services/DiskImageInstaller/DiskImageInstallerSupport.swift
        Sources/F4/Services/Clipboard/ClipboardHistorySupport.swift
        Sources/F4/Core/ClipboardAIStrings.swift
        Sources/F4/Services/ClipboardAI/ClipboardAISupport.swift
        Sources/F4/Core/DictationStrings.swift
        Sources/F4/Services/Dictation/DictationSupport.swift
        Sources/F4/Services/Dictation/DictationHistorySupport.swift
        Sources/F4/Core/NotesStrings.swift
        Sources/F4/Core/SettingsLayoutStrings.swift
        Sources/F4/Services/Notes/NotesSupport.swift
        Sources/F4/Services/Notes/NotesStore.swift
        Sources/F4/Services/Clipboard/ClipboardAutoClearSupport.swift
        Sources/F4/Services/AutoQuit/AutoQuitSupport.swift
        Sources/F4/Services/Shelf/ShelfSupport.swift
        Sources/F4/Services/Shelf/ShelfFilePromiseTransfer.swift
        Sources/F4/Core/ShelfPromiseDeliveryStrings.swift
        Sources/F4/Services/Finder/FinderRenameSupport.swift
        Sources/F4/Services/Update/UpdateInstallerSupport.swift
        Sources/F4/Services/Update/UpdateServiceSupport.swift
        Sources/F4/Services/InstalledApps.swift
        Sources/F4/Services/LaunchAtLoginSupport.swift
        Sources/F4/UI/Settings/SettingsSearchSupport.swift
        Sources/F4/UI/Settings/FeatureVisibilitySupport.swift
        Sources/F4/App/MenuBarSpacingSupport.swift
        Sources/F4/App/StatusItemAnchorSupport.swift
        Sources/F4/Services/DockClick/DockClickSupport.swift
        Sources/F4/Services/Finder/CutPasteProgressSupport.swift
        Sources/F4/Services/Finder/CutPastePrivilegeSupport.swift
        Sources/F4/Services/Finder/FinderPasteImageSupport.swift
        Sources/F4/Services/MiddleClick/MiddleClickSupport.swift
        Sources/F4/Services/MouseNavigation/MouseNavigationSupport.swift
        Sources/F4/Services/MouseButtons/MouseButtonShortcutSupport.swift
        Sources/F4/Services/MouseButtons/MouseSpacesGestureSupport.swift
        Sources/F4/Services/MouseClickDebounce/MouseClickDebounceSupport.swift
        Sources/F4/Services/MouseExceptions/MouseAppExceptionSupport.swift
        Sources/F4/Services/MouseExceptions/MouseAppExceptions.swift
        Sources/F4/Services/WindowServerSupport.swift
        Sources/F4/Core/MouseButtonStrings.swift
        Sources/F4/Core/MouseClickDebounceStrings.swift
        Sources/F4/Core/MouseExceptionStrings.swift
        Sources/F4/Core/ClipboardIgnoredAppsStrings.swift
        Sources/F4/Core/WindowPreviewExclusionStrings.swift
        Sources/F4/Core/DiskExclusionStrings.swift
        Sources/F4/Core/SwitcherAppRulesStrings.swift
        Sources/F4/Services/QuickTools/QuickToolsSupport.swift
        Sources/F4/Services/CommandBar/CommandBarSupport.swift
        Sources/F4/Services/CommandBar/CommandBarPreferences.swift
        Sources/F4/Services/CommandBar/CommandBarMath.swift
        Sources/F4/Services/CommandBar/CommandBarUnits.swift
        Sources/F4/Services/CommandBar/CommandBarEmoji.swift
        Sources/F4/Services/CommandBar/CommandBarLinks.swift
        Sources/F4/Services/CommandBar/CommandBarDates.swift
        Sources/F4/Services/CommandBar/CommandBarRowShortcuts.swift
        Sources/F4/Services/CommandBar/CommandBarSystemSettingsSupport.swift
        Sources/F4/Services/CommandBar/CommandBarFileSearchSupport.swift
        Sources/F4/Services/CommandBar/CommandBarQueryMemory.swift
        Sources/F4/Services/SpotlightNamesSupport.swift
        Sources/F4/Services/QuickTools/MicMuteSupport.swift
        Sources/F4/Services/QuickTools/QuickTogglesSupport.swift
        Sources/F4/Services/QuickTools/ScreenshotCapturePolicy.swift
        Sources/F4/Services/QuickTools/ScreenshotSupport.swift
        Sources/F4/Services/QuickTools/ScreenshotRenderer.swift
        Sources/F4/Services/QuickTools/RecentCaptureStore.swift
        Sources/F4/Services/QuickTools/ScreenshotSharingSupport.swift
        Sources/F4/Services/QuickTools/WindowActivationPolicy.swift
        Sources/F4/Services/KeyboardDebounce/KeyboardDebounceSupport.swift
        Sources/F4/Services/SuperKey/SuperKeySupport.swift
        Sources/F4/Services/SuperKey/SuperKeyMappingGuard.swift
        Sources/F4/Core/SuperKeyStrings.swift
        Sources/F4/Services/SessionActivity.swift
        Sources/F4/Services/SessionActivitySupport.swift
        Sources/F4/Services/ScrollWheelSupport.swift
        Sources/F4/Services/SmoothScrollSupport.swift
        Sources/F4/Services/MouseAcceleration/MouseAccelerationSupport.swift
        Sources/F4/Services/FocusFollowsMouse/FocusFollowsMouseSupport.swift
        Sources/F4/Services/AssistiveKeyboard.swift
        Sources/F4/Services/Switcher/SwitcherModels.swift
        Sources/F4/Services/Switcher/SwitcherSupport.swift
        Sources/F4/Services/Switcher/SpaceHopSupport.swift
        Sources/F4/Services/Switcher/WindowUseOrder.swift
        Sources/F4/Services/Metrics/MetricFormat.swift
        Sources/F4/Services/Metrics/VMStatisticsDecoder.swift
        Sources/F4/Services/KeepAwakeAutomationSupport.swift
        Sources/F4/Services/SudoersSupport.swift
        Sources/F4/Services/Metrics/BatteryTimeSupport.swift
        Sources/F4/Services/BoundedProcessRunner.swift
        Sources/F4/Services/DetachedProcess.swift
        Sources/F4/Services/ShellSupport.swift
        Sources/F4/Services/Metrics/NetworkProcessSupport.swift
        Sources/F4/Services/Metrics/NetworkSampler.swift
        Sources/F4/Services/Metrics/SpeedTest.swift
        Sources/F4/Services/Metrics/PeripheralBatterySampler.swift
        Sources/F4/Services/Metrics/PeripheralBatterySupport.swift
        Sources/F4/Services/Metrics/DiskSupport.swift
        Sources/F4/Services/Metrics/MonitorSamplingPolicy.swift
        Sources/F4/Services/Metrics/MaxCapacityProbe.swift
        Sources/F4/Services/Metrics/TemperatureSensorSelector.swift
        Sources/F4/Services/Metrics/SustainedAlertGate.swift
        Sources/F4/Services/WindowLayout/WindowLayoutSupport.swift
        Sources/F4/Services/WindowLayout/WindowGestureSupport.swift
        Sources/F4/Core/WindowDirectionalStrings.swift
        Sources/F4/Services/CleaningMode/CleaningUnlockCounter.swift
        Sources/F4/Services/Display/ExtraBrightnessSupport.swift
        Sources/F4/Services/Display/BrightnessSupport.swift
        Sources/F4/Services/Cleaner/CleanerSupport.swift
        Sources/F4/Services/Cleaner/CleanerPolicy.swift
        Sources/F4/Services/Cleaner/CleanerSchedule.swift
        Sources/F4/Services/Uninstall/UninstallerSupport.swift
        Sources/F4/Services/ManagedDownloads/WhatsAppDownloadSupport.swift
        Sources/F4/Core/SecureInputSupport.swift
        Tests/*.swift
        build/generated-tests/*.swift
    )
    TEST_OUTPUT_FILE_MAP="$TEST_OBJECT_DIR/output-file-map.json"
    write_swift_output_file_map "$TEST_OUTPUT_FILE_MAP" "$TEST_OBJECT_DIR" "${TEST_SOURCES[@]}"
    echo "▸ Building & running tests against $(basename "$SDK")…"
    swiftc -Onone -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" \
        -module-name F4Tests -output-file-map "$TEST_OUTPUT_FILE_MAP" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
        "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${TEST_SOURCES[@]}" -o build/metrics-tests
    test_status=0
    ./build/metrics-tests "${TEST_ARGS[@]}" || test_status=$?
    if (( ${#TEST_ARGS} == 0 )); then
        ./Tests/PreferenceCleanupTests.sh || test_status=1
    fi
    discard_test_preferences || test_status=1
    exit $test_status
fi

echo "▸ Compiling ($BUILD_CONFIGURATION) against $(basename "$SDK")…"
APP_SOURCES=(Sources/F4/**/*.swift)
if (( DEV )); then
    APP_OBJECT_DIR="build/objects/$EXECUTABLE"
    mkdir -p build "$APP_OBJECT_DIR"
    APP_OUTPUT_FILE_MAP="$APP_OBJECT_DIR/output-file-map.json"
    write_swift_output_file_map "$APP_OUTPUT_FILE_MAP" "$APP_OBJECT_DIR" "${APP_SOURCES[@]}"
    swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -incremental -j "$(sysctl -n hw.logicalcpu)" \
        -output-file-map "$APP_OUTPUT_FILE_MAP" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${HID_EVENT_SYSTEM_FLAGS[@]}" \
        "${BUILD_VARIANT_FLAGS[@]}" \
        "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"
else
    rm -rf build
    mkdir -p build
    swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -target "$TARGET" -sdk "$SDK" \
        "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${HID_EVENT_SYSTEM_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
        "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"
fi

echo "▸ Compiling protected fan helper…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
    Sources/F4/Services/FanControl/FanControlSupport.swift \
    Sources/F4/Services/FanControl/FanControlXPC.swift \
    Sources/F4/Services/SystemMonitor/SMCClient.swift \
    Sources/F4/Services/Metrics/TemperatureSensorSelector.swift \
    Sources/F4/Services/FanControl/FanControlHardware.swift \
    Sources/FanControlHelper/main.swift \
    -o "build/$FAN_HELPER_ID"
"build/$FAN_HELPER_ID" --selftest

echo "▸ Compiling Now Playing adapter…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" -emit-library \
    -module-name F4NowPlaying \
    Sources/NowPlayingAdapter/NowPlayingAdapter.swift \
    Sources/NowPlayingAdapter/NowPlayingQueue.swift \
    Sources/NowPlayingAdapter/NowPlayingSelection.swift \
    Sources/F4/Services/Notch/NotchPlaybackSource.swift \
    Sources/F4/Services/Notch/NotchPlaybackCommand.swift \
    -o "build/$NOW_PLAYING_ADAPTER"

echo "▸ Generating app icon…"
swift Tools/MakeIcon.swift build/AppIcon.iconset
xattr -c -r build/AppIcon.iconset build/AppIcon.icns build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || true
ACTOOL_BIN="$(xcrun --find actool 2>/dev/null || true)"
ICON_TMP="$(mktemp -d)"
ADAPTIVE_SKIP=""
if [[ -z "$ACTOOL_BIN" ]]; then
    ADAPTIVE_SKIP="actool not found (adaptive icons need Xcode 26+)"
else
    echo "▸ Compiling adaptive icon catalog…"
    # actool crashes on File Provider-synced paths, so compile a local copy.
    ditto "Resources/Brand/AppIcon.icon" "$ICON_TMP/AppIcon.icon"
    # Xcode 27 beta actool requires the --compile target directory to already exist.
    mkdir -p "$ICON_TMP/catalog"
    if "$ACTOOL_BIN" "$ICON_TMP/AppIcon.icon" \
            --compile "$ICON_TMP/catalog" \
            --app-icon AppIcon \
            --platform macosx \
            --target-device mac \
            --minimum-deployment-target 14.0 \
            --enable-on-demand-resources NO \
            --output-partial-info-plist "$ICON_TMP/partial-info.plist" \
            >"$ICON_TMP/actool.log" 2>&1 && [[ -s "$ICON_TMP/catalog/Assets.car" ]]; then
        mv "$ICON_TMP/catalog/Assets.car" build/Assets.car
    else
        ADAPTIVE_SKIP="actool could not compile the catalog"
    fi
fi
if [[ -n "$ADAPTIVE_SKIP" ]]; then
    cp "$ICON_TMP/actool.log" build/actool-failure.log 2>/dev/null || true
    echo "  adaptive icon skipped: $ADAPTIVE_SKIP (Dock falls back to AppIcon.icns)"
fi
echo "▸ Assembling and signing bundle…"
STAGE_TMP="$(mktemp -d)"
STAGE="$STAGE_TMP/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchDaemons" "$STAGE/Contents/Library/LaunchServices"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "build/$FAN_HELPER_ID" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
mkdir -p "$STAGE/Contents/Frameworks"
cp "build/$NOW_PLAYING_ADAPTER" "$STAGE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
cp Resources/now-playing.pl "$STAGE/Contents/Resources/now-playing.pl"
cp Resources/com.f4.utils.fan-control.plist \
    "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp CHANGELOG.md "$STAGE/Contents/Resources/CHANGELOG.md"
for lproj in Resources/*.lproj(N); do
    cp -R "$lproj" "$STAGE/Contents/Resources/"
done
if (( DEV )); then
    # A distinct identity so the Developer build installs and runs next to the
    # official app, with its own permissions, preferences and login item.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"
    FAN_PLIST="$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    /usr/libexec/PlistBuddy -c "Set :Label $FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Delete :MachServices:com.f4.utils.fan-control" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Add :MachServices:$FAN_HELPER_ID bool true" "$FAN_PLIST"
    # Stamp the source commit + build time so the running dev app shows (in About)
    # exactly which code it was compiled from. Lets you verify it matches HEAD before
    # testing, instead of unknowingly running a stale build. Dev-only; never shipped.
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
    /usr/libexec/PlistBuddy -c "Add :F4BuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" "$STAGE/Contents/Info.plist"
    echo "  stamped dev build: $SHA"
fi
FAN_HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
        "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
/usr/libexec/PlistBuddy -c "Add :F4FanControlHelperVersion string '$FAN_HELPER_VERSION'" \
    "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
if [[ -f build/Assets.car ]]; then
    cp build/Assets.car "$STAGE/Contents/Resources/Assets.car"
fi
if [[ -d Resources/Gifs ]]; then
    mkdir -p "$STAGE/Contents/Resources/Gifs"
    cp Resources/Gifs/*.gif "$STAGE/Contents/Resources/Gifs/"
fi
if [[ -d Resources/Images ]]; then
    mkdir -p "$STAGE/Contents/Resources/Images"
    cp Resources/Images/* "$STAGE/Contents/Resources/Images/"
fi
xattr -c -r "$STAGE" 2>/dev/null || true

# Signing, in order of preference:
#   1. Developer ID Application — the real, Apple-issued identity used for
#      notarized releases. Signed with the hardened runtime (required for
#      notarization), the app's entitlements and a secure timestamp. Gives a
#      stable, team-based designated requirement, so permissions persist across
#      updates AND Gatekeeper shows no "unverified developer" warning.
#   2. "F4 Utils Signing" — the legacy stable self-signed identity, kept
#      as a fallback so contributors without a Developer ID still get a constant
#      designated requirement across their local builds.
#   3. Ad-hoc — fresh clone with no identity at all.
DEVID="$(developer_id_identity)"
codesign_app() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --sign - "$target"
    fi
}

codesign_fan_helper() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$FAN_HELPER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" --sign - "$target"
    fi
}

codesign_now_playing_adapter() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$target"
    fi
}

sign_bundle() {
    local bundle="$1"
    local executable="$bundle/Contents/MacOS/$EXECUTABLE"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"

    if [[ -n "$DEVID" ]]; then
        echo "  signing with Developer ID (hardened runtime): $DEVID"
    elif legacy_identity_installed; then
        echo "  signing with legacy self-signed identity: $LEGACY_IDENTITY"
    else
        echo "  signing ad-hoc (no identity installed — run Tools/setup-signing.sh)"
    fi
    [[ -f "$helper" ]] && codesign_fan_helper "$helper"
    [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
    codesign_app "$bundle"

    # If local filesystem metadata invalidates the first signature, sign once
    # more. The installed Developer bundle is signed again after the final copy.
    if ! codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        echo "  re-signing after filesystem metadata settled"
        xattr -c -r "$bundle" 2>/dev/null || true
        [[ -f "$helper" ]] && codesign_fan_helper "$helper"
        [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
        codesign_app "$bundle"
    fi
    [[ -f "$executable" ]] && codesign --verify --strict "$executable"
    [[ -f "$helper" ]] && codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && codesign --verify --strict "$adapter"
    codesign --verify --deep --strict "$bundle"
}

sign_installed_bundle() {
    local bundle="$1"
    wait_for_install_metadata "$bundle"
    sign_bundle "$bundle"
}

sign_bundle "$STAGE"

process_is_running() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pgrep -f "/Contents/MacOS/$proc" >/dev/null 2>&1
    else
        pgrep -x "$proc" >/dev/null 2>&1
    fi
}

stop_process() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pkill -f "/Contents/MacOS/$proc" 2>/dev/null || true
    else
        pkill -x "$proc" 2>/dev/null || true
    fi
    for _ in {1..50}; do
        if ! process_is_running "$proc"; then
            return 0
        fi
        sleep 0.1
    done
    echo "✗ $proc is still running — quit it and retry" >&2
    return 1
}

wait_for_install_metadata() {
    local bundle="$1"
    local missing
    for _ in {1..50}; do
        missing=0
        while IFS= read -r file; do
            if ! xattr -p com.apple.provenance "$file" >/dev/null 2>&1; then
                missing=1
                break
            fi
        done < <(find "$bundle/Contents" -type f ! -path "*/_CodeSignature/*")
        if (( missing == 0 )); then
            return 0
        fi
        sleep 0.1
    done
}

# Installed development builds only need the copy in /Applications. Retaining
# another app in each checkout pollutes application search with stale builds.
if (( DEV )); then
    for old_bundle in "build/stage/$APP_NAME.app" "build/stage.noindex/$APP_NAME.app"; do
        if [[ -d "$old_bundle" ]]; then
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
                -u "$PWD/$old_bundle" >/dev/null 2>&1 || true
            rm -rf "$old_bundle"
        fi
    done
fi

if (( !DEV || !INSTALL )); then
    STAGE_DIRECTORY="build/stage"
    (( DEV )) && STAGE_DIRECTORY="build/stage.noindex"
    mkdir -p "$STAGE_DIRECTORY"
    BUILD_STAGE="$STAGE_DIRECTORY/$APP_NAME.app"
    rm -rf "$BUILD_STAGE"
    ditto --noextattr --noqtn "$STAGE" "$BUILD_STAGE"
    xattr -c -r "$BUILD_STAGE" 2>/dev/null || true
    if ! codesign --verify --deep --strict "$BUILD_STAGE" >/dev/null 2>&1; then
        if xattr -lr "$BUILD_STAGE" 2>/dev/null | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork|provenance|fileprovider)'; then
            echo "  staging copy has local filesystem metadata; temp bundle was verified"
        else
            codesign --verify --deep --strict "$BUILD_STAGE"
        fi
    fi
    echo "✓ Bundle ready: $BUILD_STAGE"
fi

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    stop_process "$EXECUTABLE"
    # Remove the pre-rename apps so two menu bar items never coexist. Same bundle
    # id, so macOS keeps the granted permissions for the new bundle.
    for legacy in "Vorss:Vorss" "F4 Utils:F4Utils"; do
        name="${legacy%%:*}"; proc="${legacy##*:}"
        if [[ -d "/Applications/$name.app" ]]; then
            stop_process "$proc"
            rm -rf "/Applications/$name.app"
            echo "  (legacy $name.app removed)"
        fi
    done
    INSTALL_DEST="/Applications/$APP_NAME.app"
    rm -rf "$INSTALL_DEST"
    ditto --noextattr --noqtn "$STAGE" "$INSTALL_DEST"
    sign_installed_bundle "$INSTALL_DEST"
    echo "✓ Installed: $INSTALL_DEST"
fi
