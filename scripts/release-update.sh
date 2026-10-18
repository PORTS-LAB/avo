#!/usr/bin/env bash
# Publishes a release to Avo's update feed (Sparkle 2; docs/releasing.md).
#
#   scripts/release-update.sh <Avo.dmg|Avo.zip> [options]
#
#     --updates DIR              the folder that mirrors what is published
#                                (default: build/updates)
#     --download-url-prefix URL  where the archives are downloaded from
#                                (default: the folder of the app's SUFeedURL)
#     --notes FILE               release notes (.md or .html) for this archive
#     --channel NAME             a channel such as "beta" (default: none)
#     --sparkle-bin DIR          Sparkle's tools (default: SPARKLE_BIN, else
#                                found in Xcode's derived data)
#
# It checks the archive's Avo.app first, then:
#   1. signs the archive with sign_update, using the EdDSA private key in
#      this Mac's login Keychain (generate_keys put it there; it never leaves),
#   2. puts the archive (and its notes) in the updates folder and runs
#      generate_appcast there, which writes or updates appcast.xml, signs
#      every new archive, makes delta updates from the older ones and keeps
#      the newest few (older ones move to old_updates/),
#   3. checks that appcast.xml carries the signature sign_update made.
# Then upload the folder's contents to the place SUFeedURL points at.
#
# macOS may ask once to let sign_update and generate_appcast use the key
# ("Private key for signing Sparkle updates"): allow it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATES="$ROOT/build/updates"
PREFIX=""
NOTES=""
CHANNEL=""
BIN="${SPARKLE_BIN:-}"
ARCHIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --updates) UPDATES="$2"; shift 2 ;;
    --download-url-prefix) PREFIX="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --sparkle-bin) BIN="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) [[ -z "$ARCHIVE" ]] || { echo "one archive at a time" >&2; exit 2; }; ARCHIVE="$1"; shift ;;
  esac
done
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { echo "usage: $0 <Avo.dmg|Avo.zip> [options] (see the top of this script)" >&2; exit 2; }
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"

fail() { echo "error: $*" >&2; exit 1; }

# Sparkle's tools come with the Swift package (SourcePackages/artifacts/sparkle/Sparkle/bin).
if [[ -z "$BIN" ]]; then
  for candidate in "$ROOT"/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin \
                   "$HOME"/Library/Developer/Xcode/DerivedData/Avo-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    [[ -x "$candidate/sign_update" ]] && { BIN="$candidate"; break; }
  done
fi
[[ -x "$BIN/sign_update" && -x "$BIN/generate_appcast" && -x "$BIN/generate_keys" ]] \
  || fail "Sparkle's tools were not found: build Avo once (Xcode fetches Sparkle), or pass --sparkle-bin"

# MARK: The app in the archive

WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
  [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

case "$ARCHIVE" in
  *.dmg)
    MOUNT="$WORK/mount"
    mkdir -p "$MOUNT"
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$ARCHIVE" >/dev/null || fail "cannot open $ARCHIVE"
    APP="$MOUNT/Avo.app" ;;
  *.zip)
    ditto -x -k "$ARCHIVE" "$WORK/zip" || fail "cannot unpack $ARCHIVE"
    APP="$WORK/zip/Avo.app" ;;
  *) fail "Sparkle archives for Avo are .dmg or .zip" ;;
esac
# Sparkle replaces the installed app by its name: the archive must hold Avo.app.
[[ -d "$APP" ]] || fail "the archive has no Avo.app at its top level"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
FEED="$(plist SUFeedURL)"
APP_KEY="$(plist SUPublicEDKey)"
echo "Avo $VERSION (build $BUILD)"

[[ -n "$BUILD" ]] || fail "Avo.app has no CFBundleVersion"
[[ "$FEED" == https://* ]] || fail "SUFeedURL must be an https URL (it is \"$FEED\")"
case "$FEED" in
  *.invalid/*|*://invalid/*) fail "SUFeedURL is still the placeholder ($FEED): set the real feed in host/Avo/Info.plist and build again" ;;
esac
KEYCHAIN_KEY="$("$BIN/generate_keys" -p 2>/dev/null || true)"
[[ -n "$KEYCHAIN_KEY" ]] || fail "no Sparkle signing key in this Mac's Keychain (docs/releasing.md: import the backup with generate_keys -f)"
[[ "$APP_KEY" == "$KEYCHAIN_KEY" ]] \
  || fail "the app's SUPublicEDKey ($APP_KEY) is not this Keychain's key ($KEYCHAIN_KEY): installed copies would reject the update"
# Sparkle checks the new bundle's own signature, ad hoc included.
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "Avo.app's code signature is not valid (codesign --verify --deep --strict)"

# The build must be newer than every build the feed already has (Sparkle
# compares CFBundleVersion, and never installs an older or equal one).
mkdir -p "$UPDATES"
if [[ -f "$UPDATES/appcast.xml" ]]; then
  NEWEST="$(/usr/bin/python3 -I - "$UPDATES/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
def key(v):
    return [int(p) if p.isdigit() else p for p in v.replace('-', '.').split('.')]
versions = []
for item in ET.parse(sys.argv[1]).getroot().iter('item'):
    v = item.find('sparkle:version', ns)
    if v is None:
        enclosure = item.find('enclosure')
        v_text = enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}version') if enclosure is not None else None
    else:
        v_text = v.text
    if v_text: versions.append(v_text.strip())
print(max(versions, key=key) if versions else '')
PY
)"
  if [[ -n "$NEWEST" ]]; then
    LATER="$(printf '%s\n%s\n' "$NEWEST" "$BUILD" | sort -V | tail -1)"
    [[ "$BUILD" != "$NEWEST" && "$LATER" == "$BUILD" ]] \
      || fail "build $BUILD is not newer than build $NEWEST in the feed: raise CURRENT_PROJECT_VERSION (host/Config/Base.xcconfig) or pass it to xcodebuild"
  fi
fi
if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" -quiet; MOUNT=""; fi

# MARK: Sign and publish

echo "== sign_update"
SIGNATURE_LINE="$("$BIN/sign_update" "$ARCHIVE")"
echo "$SIGNATURE_LINE"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNATURE_LINE")"
[[ -n "$SIGNATURE" ]] || fail "sign_update gave no signature"
"$BIN/sign_update" --verify "$ARCHIVE" "$SIGNATURE" >/dev/null || fail "the signature does not verify"

NAME="$(basename "$ARCHIVE")"
if [[ "$ARCHIVE" != "$UPDATES/$NAME" ]]; then cp -f "$ARCHIVE" "$UPDATES/$NAME"; fi
if [[ -n "$NOTES" ]]; then
  case "$NOTES" in
    *.md|*.html) cp -f "$NOTES" "$UPDATES/${NAME%.*}.${NOTES##*.}" ;;
    *) fail "release notes are .md or .html" ;;
  esac
fi

[[ -n "$PREFIX" ]] || PREFIX="${FEED%/*}/"
[[ "$PREFIX" == */ ]] || PREFIX="$PREFIX/"
echo "== generate_appcast (downloads from $PREFIX)"
ARGS=(--download-url-prefix "$PREFIX" -o "$UPDATES/appcast.xml")
[[ -n "$CHANNEL" ]] && ARGS+=(--channel "$CHANNEL")
# An ad hoc build always differs in code signing identity from the last one:
# generate_appcast says so for its deltas, which is expected (the EdDSA
# signature is what installed copies check).
"$BIN/generate_appcast" "${ARGS[@]}" "$UPDATES"

grep -q "$SIGNATURE" "$UPDATES/appcast.xml" || fail "appcast.xml does not carry this archive's signature"
echo "== ready to upload: the contents of $UPDATES"
ls -1 "$UPDATES"
echo "SUFeedURL: $FEED"
