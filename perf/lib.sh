#!/bin/zsh
# Shared setup for the perf/*.sh scripts. Source this after `cd`-ing to the
# repo root; it's never run directly.

BUILD=perf/.build
mkdir -p "$BUILD"

# The CLT-only developer directory has no Xcode toolchain; point at Xcode
# itself so swiftc/xcodebuild behave like an Xcode build.
if ! xcode-select -p | grep -q Xcode.app; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# swiftc's default ad-hoc signature hashes the binary's own bytes, so TCC
# sees a new identity on every rebuild and drops the Accessibility grant.
# Sign with the app's own Team ID instead, like Xcode does for WheelClick
# itself — same identifier + team survives rebuilds, so the grant sticks.
sign_bench() { # $1 = binary path, $2 = identifier suffix
    codesign --force --sign "Apple Development: Arthur Ginzburg (MA8T6SPDN2)" \
        --identifier "art.ginzburg.WheelClick.$2" "$1"
}

# Where the Release build actually lands. The scheme's Release configuration
# is named Release-Direct (the channel split), so the obvious
# Products/Release path has never existed -- and a script that assumes it
# fails at `open` with "Launchd job spawn failed", which sounds like a code
# signing problem and is not one.
built_release_app() {
    /bin/ls -d "$BUILD"/DerivedData/Build/Products/*/WheelClick.app 2>/dev/null | head -1
}

# Rebuilds Release and relaunches the app — shared by the --fresh flag in
# run.sh and accept-magic-mouse.sh.
rebuild_and_relaunch() {
    # Signing a Release build is what makes the sandbox real, and therefore
    # what makes a measurement worth anything -- but the signing identity
    # lives in its own locked keychain, invisible to codesign until asked
    # (scripts/signing-keychain.sh, and see its header for why). The release
    # scripts already unlock it around their builds; without the same here, a
    # --fresh run stalls on a password dialog per nested bundle, or fails with
    # errSecInternalComponent when nobody answers.
    local signing_keychain=no
    if scripts/signing-keychain.sh status >/dev/null 2>&1; then
        scripts/signing-keychain.sh unlock >/dev/null && signing_keychain=yes
    fi
    relock_signing_keychain() {
        [[ "$signing_keychain" == yes ]] && scripts/signing-keychain.sh lock >/dev/null 2>&1 || true
    }
    # An explicit destination keeps xcodebuild's multi-destination warning
    # out of the log.
    # Signed with the DEVELOPMENT identity, not Developer ID, and that is
    # load-bearing rather than lazy: an Accessibility grant in TCC is bound to
    # the app's code signing requirement, so a Developer ID build is a
    # different app as far as the grant is concerned -- it launches, creates
    # no taps, and measures an app that is doing nothing. Xcode signs the
    # everyday build the same way, so this one inherits the grant already
    # given. The checked-in Developer ID profile only carries the Developer ID
    # certificate, so it is cleared here and Xcode falls back to the managed
    # development profile it already uses for the everyday build. Naming that
    # profile explicitly does not work -- it is Xcode-managed, and pinning it
    # puts the app target in manual mode while the helper target stays
    # automatic, which the build rejects. -allowProvisioningUpdates is needed
    # because the app carries an Associated Domains entitlement and Xcode will
    # not pick a profile for it otherwise -- so the profile directory is
    # counted before and after and the build shouts if anything was issued.
    # (Measured twice: three profiles before, three after.)
    local profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    local profiles_before=$(/bin/ls "$profiles_dir" 2>/dev/null | wc -l | tr -d " ")
    if ! xcodebuild -project WheelClick.xcodeproj -scheme WheelClick -configuration Release-Direct \
        -destination "platform=macOS,arch=$(uname -m)" \
        -derivedDataPath "$BUILD/DerivedData" \
        CODE_SIGN_IDENTITY="Apple Development" \
        PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates \
        -quiet build 2> >(grep -v IDERunDestination >&2); then
        relock_signing_keychain
        return 1
    fi
    relock_signing_keychain
    local profiles_after=$(/bin/ls "$profiles_dir" 2>/dev/null | wc -l | tr -d " ")
    if [[ "$profiles_after" != "$profiles_before" ]]; then
        echo "NOTE: provisioning profiles went from $profiles_before to $profiles_after — Xcode issued one." >&2
    fi
    # Verify before launching. A bundle whose nested code was signed with a
    # different identity than the outer app builds fine and then dies at
    # launch as "Launchd job spawn failed" (POSIX 163), which says nothing
    # about signatures at all -- half an hour was spent on that once.
    local app=$(built_release_app)
    if [[ -z "$app" ]]; then
        echo "No app under $BUILD/DerivedData/Build/Products — the build produced nothing." >&2
        return 1
    fi
    if ! codesign --verify --deep --strict "$app" 2>/tmp/wc-codesign-verify.txt; then
        echo "The freshly built app does not verify — refusing to launch it:" >&2
        cat /tmp/wc-codesign-verify.txt >&2
        echo "Delete $BUILD/DerivedData/Build/Products and rebuild." >&2
        return 1
    fi
    # SIGKILL on purpose: SIGTERM hangs the app when Xcode's debugger is attached.
    pkill -9 -x WheelClick 2>/dev/null || true
    open "$app"
    # Every earlier build under perf/.build is still registered with
    # LaunchServices, and a registered copy can be handed a wheelclick:// or
    # wheelclick.app activation link instead of the app the person is running
    # (see scripts/unregister-app-copies.sh — four of these were live
    # candidates before it existed). The one just launched keeps its record: it
    # IS the running app until the next relaunch, and a bundle id that resolves
    # to nothing would fail an activation just as surely.
    scripts/unregister-app-copies.sh "$BUILD" --keep "$app"
    sleep 2  # let the taps come up before measuring
}
