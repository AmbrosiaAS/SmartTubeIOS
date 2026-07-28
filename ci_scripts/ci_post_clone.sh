#!/bin/sh
#
# Xcode Cloud runs this immediately after cloning the repository, before it
# resolves Swift packages or invokes xcodebuild. A non-zero exit fails the build.
#
# Its job is to reconstitute the files that are deliberately not in git, and to
# fail loudly (rather than 40 minutes later, inside a linker error) when the
# build environment is not set up correctly.
#
# See docs/xcode-cloud.md for the environment variables this expects.

set -eu

# Xcode Cloud sets CI_PRIMARY_REPOSITORY_PATH; CI_WORKSPACE is the older name.
# The last fallback lets the script be run by hand from a local checkout.
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}}"

IOS_PLIST="$REPO_ROOT/SmartTubeApp/SmartTubeApp/GoogleService-Info.plist"
TV_PLIST="$REPO_ROOT/SmartTubeApp/Smart Tube/GoogleService-Info.plist"

log()  { printf '[ci_post_clone] %s\n' "$1"; }
fail() { printf '[ci_post_clone] ERROR: %s\n' "$1" >&2; exit 1; }

# BSD base64 (macOS) accepts -D; GNU coreutils accepts --decode. Newer macOS
# accepts both, older ones do not, so probe rather than assume.
decode_base64() {
    if base64 --decode </dev/null >/dev/null 2>&1; then
        base64 --decode
    else
        base64 -D
    fi
}

# --------------------------------------------------------------------------
# 1. GoogleService-Info.plist for the iOS/macOS `SmartTube` target.
#
# This file is a member of the target's Resources build phase and is the -gsp
# argument to the Crashlytics run script, but it is gitignored, so a clean
# Xcode Cloud checkout does not have it and the build cannot succeed without it.
# --------------------------------------------------------------------------
if [ -f "$IOS_PLIST" ]; then
    log "GoogleService-Info.plist already present, leaving it alone."
elif [ -n "${GOOGLE_SERVICE_INFO_PLIST_BASE64:-}" ]; then
    log "Writing GoogleService-Info.plist from GOOGLE_SERVICE_INFO_PLIST_BASE64."
    mkdir -p "$(dirname "$IOS_PLIST")"
    printf '%s' "$GOOGLE_SERVICE_INFO_PLIST_BASE64" | decode_base64 > "$IOS_PLIST"
elif [ -f "$TV_PLIST" ]; then
    # The tvOS target ships its own copy, and both apps use the same bundle id
    # (com.void.smarttube.app), so it is a valid stand-in. Warn, because relying
    # on it silently couples the two targets to one Firebase app registration.
    log "WARNING: GOOGLE_SERVICE_INFO_PLIST_BASE64 is not set."
    log "WARNING: falling back to the committed tvOS GoogleService-Info.plist."
    mkdir -p "$(dirname "$IOS_PLIST")"
    cp "$TV_PLIST" "$IOS_PLIST"
else
    fail "No Firebase config available. Set the GOOGLE_SERVICE_INFO_PLIST_BASE64
       environment variable on the Xcode Cloud workflow to the base64 of your
       GoogleService-Info.plist:

           base64 -i GoogleService-Info.plist | pbcopy"
fi

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$IOS_PLIST" >/dev/null \
        || fail "$IOS_PLIST is not a valid property list (bad base64?)."
fi

# --------------------------------------------------------------------------
# 2. Package.resolved sanity check.
#
# Xcode Cloud disables automatic package resolution and resolves strictly from
# the committed lockfile. Without one the build either fails outright or, worse,
# silently floats to a different Firebase 12.x than the one tested locally.
# --------------------------------------------------------------------------
found_lockfile=0
for candidate in \
    "$REPO_ROOT/SmartTube.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "$REPO_ROOT/SmartTubeApp/SmartTubeApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
do
    if [ -f "$candidate" ]; then
        log "Found lockfile: ${candidate#"$REPO_ROOT"/}"
        found_lockfile=1
    fi
done

if [ "$found_lockfile" -eq 0 ]; then
    log "WARNING: no Package.resolved found in this checkout."
    log "WARNING: dependency versions are not pinned; see docs/xcode-cloud.md."
fi

log "Done."
