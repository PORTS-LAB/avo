#!/usr/bin/env python3
"""Packages an Avo Android image for the macOS host.

Writes manifest.json (SHA-256 and size of every file) next to the image files
and signs it with Ed25519 (manifest.json.sig). The daemon refuses images whose
signature or hashes do not match (spec: "Image Android diverifikasi dengan
checksum dan tanda tangan sebelum dipasang"); see AndroidImage in AvoDaemonCore.

    python3 -I scripts/make-image-manifest.py IMAGE_DIR --version 16.0.0 \\
        --key release-ed25519.pem

IMAGE_DIR must contain: kernel, initrd.img, system.img, vendor.img,
overlay_stock.img and overlay_rooted.img. Create a signing key with
`openssl genpkey -algorithm ed25519 -out release-ed25519.pem`; put the base64
raw public key (`--print-public-key`) in AvoDaemon's Info.plist as
AvoImagePublicKey. Requires OpenSSL 3.
"""

import argparse
import base64
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

PARTITIONS = ["system.img", "vendor.img"]
REQUIRED = ["kernel", "initrd.img", *PARTITIONS, "overlay_stock.img", "overlay_rooted.img"]


def openssl() -> str:
    for candidate in ("/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl", "openssl"):
        path = shutil.which(candidate) or (candidate if pathlib.Path(candidate).exists() else None)
        if path:
            version = subprocess.run([path, "version"], capture_output=True, text=True).stdout
            if version.startswith("OpenSSL 3"):
                return path
    sys.exit("OpenSSL 3 is required (brew install openssl@3)")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(4 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def public_key(key: pathlib.Path) -> str:
    der = subprocess.run([openssl(), "pkey", "-in", str(key), "-pubout", "-outform", "DER"],
                         capture_output=True, check=True).stdout
    return base64.b64encode(der[-32:]).decode()  # raw 32-byte Ed25519 key


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image_dir", type=pathlib.Path)
    parser.add_argument("--version", required=False)
    parser.add_argument("--sdk", type=int, default=36)
    parser.add_argument("--key", type=pathlib.Path, required=True)
    parser.add_argument("--print-public-key", action="store_true")
    args = parser.parse_args()

    if args.print_public_key:
        print(public_key(args.key))
        return 0
    if not args.version:
        parser.error("--version is required")

    missing = [name for name in REQUIRED if not (args.image_dir / name).is_file()]
    if missing:
        sys.exit(f"missing image files: {', '.join(missing)}")

    files = [{"name": name, "sha256": sha256(args.image_dir / name), "size": (args.image_dir / name).stat().st_size}
             for name in REQUIRED]
    manifest = {
        "schema": 1,
        "version": args.version,
        "sdk": args.sdk,
        "kernel": "kernel",
        "initrd": "initrd.img",
        "partitions": PARTITIONS,
        "overlay_stock": "overlay_stock.img",
        "overlay_rooted": "overlay_rooted.img",
        "files": files,
    }
    manifest_path = args.image_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    signature_path = args.image_dir / "manifest.json.sig"
    subprocess.run([openssl(), "pkeyutl", "-sign", "-rawin", "-inkey", str(args.key),
                    "-in", str(manifest_path), "-out", str(signature_path)], check=True)
    print(f"wrote {manifest_path} and {signature_path.name}; public key {public_key(args.key)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
