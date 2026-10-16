#!/bin/sh
# Signs a freshly built binary with the hypervisor entitlement, then runs it.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
codesign --force --sign - --entitlements "$here/hypervisor.entitlements" "$1" 2>/dev/null
exec "$@"
