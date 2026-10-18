#!/usr/bin/env bash
# Builds build/AvoHello.apk with the Android SDK (no Gradle). keymap/ holds a
# key mapping profile for its Arena game (import it in the key mapping editor).
#
#   ANDROID_HOME=~/Library/Android/sdk ./build.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
API=36
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
JAR="$SDK/platforms/android-$API/android.jar"
OUT="$HERE/build"
rm -rf "$OUT"
mkdir -p "$OUT"/{res,classes,dex}

"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res/compiled.zip"
"$BT/aapt2" link -I "$JAR" --manifest "$HERE/AndroidManifest.xml" -o "$OUT/unsigned.apk" "$OUT/res/compiled.zip"
javac --release 17 -nowarn -cp "$JAR" -d "$OUT/classes" $(find "$HERE/src" -name '*.java')
"$BT/d8" --release --min-api 34 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
(cd "$OUT/dex" && zip -q -j "$OUT/unsigned.apk" classes.dex)
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# Kept outside build/ (and out of git, *.keystore) so a new build installs over the old one.
KEY="$HERE/debug.keystore"
if [[ ! -f "$KEY" ]]; then
  keytool -genkeypair -keystore "$KEY" -storepass android -keypass android -alias debug -keyalg RSA -keysize 2048 \
    -validity 10000 -dname "CN=Avo Debug" >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KEY" --ks-pass pass:android --key-pass pass:android --out "$OUT/AvoHello.apk" "$OUT/aligned.apk"
echo "built $OUT/AvoHello.apk"
