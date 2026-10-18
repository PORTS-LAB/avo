#!/usr/bin/env bash
# Tests src/frag_outputs.c on the Mac, against the MoltenVK the Android
# emulator ships (what gfxstream runs guest Vulkan on). For each shader in
# shaders/:
# - "unsplit fails": as it is, the shader makes no pipeline with one colour
#   attachment (the MoltenVK bug the layer works around);
# - "unchanged": the layer leaves the module alone;
# - "expect N: ...": once split, it draws these pixels (two per attachment,
#   RRGGBBAA) with N attachments, and spirv-val accepts the split module.
# "target <env>" picks the glslc/spirv-val environment (default vulkan1.0).
#
#   ANDROID_HOME=~/Library/Android/sdk ./run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -1)}"
TOOLS="$NDK/shader-tools/$(ls "$NDK/shader-tools" | head -1)"
SYSROOT="$NDK/toolchains/llvm/prebuilt/$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)/sysroot"
MOLTENVK="$SDK/emulator/lib64/vulkan/libMoltenVK.dylib"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# The NDK's Vulkan headers, after the Mac's own (its libc headers are Android's).
clang -std=c11 -O1 -Wall -Wextra -Werror -idirafter "$SYSROOT/usr/include" \
    -o "$OUT/moltenvk_test" "$HERE/moltenvk_test.c" "$HERE/../src/frag_outputs.c"
"$TOOLS/glslc" -o "$OUT/vert.spv" "$HERE/shaders/fullscreen.vert"

failures=0
fail() {
    echo "FAIL $1: $2"
    failures=$((failures + 1))
}

for shader in "$HERE"/shaders/*.frag; do
    name="$(basename "$shader" .frag)"
    before=$failures
    target="$(sed -n 's|^// target \(.*\)|\1|p' "$shader")"
    target="${target:-vulkan1.0}"
    "$TOOLS/glslc" --target-env="$target" -o "$OUT/$name.spv" "$shader"

    if grep -q '^// unsplit fails' "$shader"; then
        if "$OUT/moltenvk_test" "$MOLTENVK" "$OUT/vert.spv" "$OUT/$name.spv" 1 >/dev/null 2>"$OUT/$name.log"; then
            fail "$name" "made a pipeline without the split (the bug is gone?)"
        elif ! grep -q "must be made explicit" "$OUT/$name.log"; then
            fail "$name" "failed without the split, but not with the MoltenVK bug: $(tail -3 "$OUT/$name.log")"
        fi
    fi
    if grep -q '^// unchanged' "$shader"; then
        "$OUT/moltenvk_test" "$MOLTENVK" "$OUT/vert.spv" "$OUT/$name.spv" 1 --split >/dev/null 2>"$OUT/$name.log" || true
        grep -q "split: unchanged" "$OUT/$name.log" || fail "$name" "the layer rewrote it"
    fi

    validated=false
    while read -r attachments expected; do
        actual="$("$OUT/moltenvk_test" "$MOLTENVK" "$OUT/vert.spv" "$OUT/$name.spv" "$attachments" --split \
            --write "$OUT/$name.split.spv" 2>"$OUT/$name.log")" || {
            fail "$name" "$attachments attachments: $(tail -5 "$OUT/$name.log")"
            continue
        }
        [ "$actual" = "$expected" ] || fail "$name" "$attachments attachments: drew $actual, expected $expected"
        if ! $validated; then
            "$TOOLS/spirv-val" --target-env "$target" "$OUT/$name.split.spv" || fail "$name" "spirv-val refused the split module"
            validated=true
        fi
    done < <(sed -n 's|^// expect \([0-9]*\): \(.*\)|\1 \2|p' "$shader")
    [ "$failures" -eq "$before" ] && echo "ok   $name"
done

if [ "$failures" -gt 0 ]; then
    echo "$failures failed"
    exit 1
fi
echo "all passed"
