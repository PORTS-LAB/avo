#!/usr/bin/env bash
# Regenerates protocol bindings from proto/avo/v1/*.proto.
#
#   Swift (committed): host/AvoKit/Sources/AvoProtocol/Generated/
#   Java lite (build output, not committed): guest/bridge-agent/build/gen/
#
# The AOSP build compiles the .proto files itself (see guest/bridge-agent/Android.bp).
# Requires `protoc`; protoc-gen-swift is built from the swift-protobuf checkout
# that SwiftPM resolves for host/AvoKit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/host/AvoKit"
SWIFT_OUT="$PKG/Sources/AvoProtocol/Generated"
JAVA_OUT="$ROOT/guest/bridge-agent/build/gen"

command -v protoc >/dev/null || { echo "protoc not found (brew install protobuf)" >&2; exit 1; }

mode="${1:-all}"   # all | --swift-only | --java-only

if [[ "$mode" != "--java-only" ]]; then
  PLUGIN="$PKG/.build/checkouts/swift-protobuf/.build/release/protoc-gen-swift"
  if [[ ! -x "$PLUGIN" ]]; then
    (cd "$PKG" && swift package resolve)
    (cd "$PKG/.build/checkouts/swift-protobuf" && swift build -c release --product protoc-gen-swift)
  fi
  mkdir -p "$SWIFT_OUT"
  protoc --proto_path="$ROOT/proto" \
    --plugin=protoc-gen-swift="$PLUGIN" \
    --swift_opt=Visibility=Public \
    --swift_opt=FileNaming=PathToUnderscores \
    --swift_out="$SWIFT_OUT" \
    "$ROOT"/proto/avo/v1/*.proto
  echo "generated Swift: $SWIFT_OUT"
fi

if [[ "$mode" != "--swift-only" ]]; then
  mkdir -p "$JAVA_OUT"
  protoc --proto_path="$ROOT/proto" --java_out=lite:"$JAVA_OUT" "$ROOT"/proto/avo/v1/*.proto
  echo "generated Java: $JAVA_OUT"
fi
