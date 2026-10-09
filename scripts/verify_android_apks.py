"""Reject APKs with the wrong signer, package or version before publishing.

Uses Android SDK apksigner for cryptographic verification and aapt for manifest
inspection. The pinned fingerprint is public; no private key is read here.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = "app.fusionreader.fusion_reader"
ABI_OFFSETS = {"armeabi-v7a": 1000, "arm64-v8a": 2000, "x86_64": 3000}


def check_signer(output, expected):
    # SDK tools print v3.1 signers by their Android version range instead of
    # "Signer #1". A fixed key can appear in both the v3 and v3.1 ranges.
    signer_name = r"(?:#\d+|\(minSdkVersion=\d+(?: \(dev release=true\))?, maxSdkVersion=\d+\))"
    hashes = re.findall(
        rf"^Signer {signer_name} certificate SHA-256 digest:[ \t]*([a-fA-F0-9]{{64}})[ \t]*$",
        output,
        re.MULTILINE,
    )
    if not hashes:
        raise ValueError(f"Cannot read APK signer certificate from apksigner output:\n{output}")
    signer_count = re.search(r"^Number of signers:[ \t]*(\d+)[ \t]*$", output, re.MULTILINE)
    indexed_count = len(re.findall(r"^Signer #\d+ certificate SHA-256 digest:", output, re.MULTILINE))
    if indexed_count > 1 or (signer_count is not None and int(signer_count[1]) != 1):
        raise ValueError("APK must have exactly one signing identity")
    if any(digest.lower() != expected for digest in hashes):
        raise ValueError(f"APK signing certificate differs from the fixed release certificate: {hashes}; expected {expected}")
    return hashes[0].lower()


def check_manifest(output, abi, version_name, base_code):
    package = re.search(
        r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'",
        output,
        re.MULTILINE,
    )
    if package is None:
        raise ValueError("APK manifest cannot be read")
    name, code, version = package.groups()
    if name != PACKAGE:
        raise ValueError(f"Unexpected application ID: {name}")
    if version != version_name or int(code) != ABI_OFFSETS[abi] + base_code:
        raise ValueError(f"Unexpected APK version: {version} ({code}) for {abi}")
    native = re.search(r"^native-code:\s*(.*)$", output, re.MULTILINE)
    if native is None or re.findall(r"'([^']+)'", native[1]) != [abi]:
        raise ValueError(f"Unexpected native architecture for {abi}")
    return {"applicationId": name, "versionName": version, "versionCode": int(code), "abi": abi}


def verify_apk(apk, tools, expected, abi, version_name, base_code):
    signature = subprocess.run(
        [str(tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk)],
        check=True, capture_output=True, text=True,
    )
    print(f"Verifying {apk.name}:\n{signature.stdout}", flush=True)
    digest = check_signer(signature.stdout, expected)
    manifest = subprocess.run(
        [str(tools / "aapt"), "dump", "badging", str(apk)],
        check=True, capture_output=True, text=True,
    )
    metadata = check_manifest(manifest.stdout, abi, version_name, base_code)
    return {"file": apk.name, "certificateSha256": digest, **metadata}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-tools", type=Path, required=True)
    args = parser.parse_args()
    expected = (ROOT / "android/signing-certificate.sha256").read_text().strip()
    if re.fullmatch(r"[a-f0-9]{64}", expected) is None:
        raise ValueError("Pinned certificate fingerprint is invalid")
    version = re.search(
        r"^version:\s*([0-9.]+)\+(\d+)\s*$",
        (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.MULTILINE,
    )
    if version is None:
        raise ValueError("Application version is missing")
    report = []
    for abi in ABI_OFFSETS:
        apk = ROOT / f"build/app/outputs/flutter-apk/app-{abi}-release.apk"
        if not apk.is_file():
            raise FileNotFoundError(apk)
        report.append(verify_apk(apk, args.build_tools, expected, abi, version[1], int(version[2])))
    destination = ROOT / "build/verification/android-signatures.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Verified all {len(report)} APKs: fixed signer, package, version and architecture")


if __name__ == "__main__":
    main()
