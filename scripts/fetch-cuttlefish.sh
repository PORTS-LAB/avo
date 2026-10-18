#!/usr/bin/env bash
# Downloads a prebuilt Cuttlefish build (AOSP's virtual device) from
# ci.android.com. Avo's Android image is built from it instead of a full AOSP
# checkout and build (see docs/image.md).
#
#   scripts/fetch-cuttlefish.sh [--build ID] [--branch NAME] [--target NAME]
#                               [--host-package] [DEST]
#
# Defaults: the latest successful aosp_cf_arm64_only_phone-userdebug build of
# aosp-android-latest-release, into ~/Library/Caches/Avo/cuttlefish/<build>.
#
# It talks to the public Android Build API v4 with the API key that the
# Cuttlefish `cvd` tool ships for public AOSP builds
# (google/android-cuttlefish, android_build_api_key.cc). Set
# AVO_BUILD_API_KEY to use your own.
set -euo pipefail

API="https://androidbuild-pa.googleapis.com/v4"
KEY="${AVO_BUILD_API_KEY:-AIzaSyBIelMvbjtNkpa5O96eqbm_IuSUA5WsO14}"
BRANCH="aosp-android-latest-release"
TARGET="aosp_cf_arm64_only_phone-userdebug"
BUILD=""
HOST_PACKAGE=0
DEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --host-package) HOST_PACKAGE=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) DEST="$1"; shift ;;
  esac
done

api() { curl -fsS --retry 3 -H "X-goog-api-key: $KEY" "$API/$1"; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

if [[ -z "$BUILD" ]]; then
  BUILD=$(api "builds?buildAttemptStatus=complete&buildType=submitted&pageSize=1&successful=true&branches=$BRANCH&targets=$TARGET" \
    | json "d['builds'][0]['buildId']")
fi
DEST="${DEST:-$HOME/Library/Caches/Avo/cuttlefish/$BUILD}"
mkdir -p "$DEST"
echo "build $BUILD ($BRANCH, $TARGET) -> $DEST"

# fetch <artifact name>: resumable download, checked against the API's MD5.
fetch() {
  local name="$1" file="$DEST/$1" meta url md5
  meta=$(api "builds/$BUILD/$TARGET/attempts/latest/artifacts?pageSize=1&nameRegexp=%5E${name//./%5C.}%24")
  md5=$(echo "$meta" | json "d['artifacts'][0]['md5']")
  if [[ -f "$file" && "$(md5 -q "$file")" == "$md5" ]]; then
    echo "have $name"
    return
  fi
  url=$(api "builds/$BUILD/$TARGET/attempts/latest/artifacts/$name/url" | json "d['signedUrl']")
  echo "downloading $name"
  curl -fL --retry 3 -C - -o "$file" "$url"
  [[ "$(md5 -q "$file")" == "$md5" ]] || { echo "$name: checksum mismatch" >&2; exit 1; }
}

fetch "${TARGET%%-*}-img-$BUILD.zip"
fetch "android-info.txt"
[[ $HOST_PACKAGE == 1 ]] && fetch "cvd-host_package.tar.gz"
echo "$BUILD" > "$DEST/BUILD_ID"
echo "done: $DEST"
