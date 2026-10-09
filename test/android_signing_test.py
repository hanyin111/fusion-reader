import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("apk_checks", ROOT / "scripts/verify_android_apks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
PIN = (ROOT / "android/signing-certificate.sha256").read_text().strip()


class AndroidSigningTest(unittest.TestCase):
    def signature(self, certificate=PIN):
        return f"Verified\nSigner #1 certificate SHA-256 digest: {certificate}\n"

    def manifest(self, package=checks.PACKAGE, code=2009, name="1.3.5", abi="arm64-v8a"):
        return f"package: name='{package}' versionCode='{code}' versionName='{name}'\nnative-code: '{abi}'\n"

    def test_fixed_certificate_accepts_case_insensitive_sdk_output(self):
        self.assertEqual(checks.check_signer(self.signature(PIN.upper()), PIN), PIN)

    def sdk_range_signature(self, minimum, maximum, certificate=PIN):
        return f"Signer (minSdkVersion={minimum}, maxSdkVersion={maximum}) certificate SHA-256 digest: {certificate}\n"

    def test_v31_certificate_uses_sdk_ranges_in_official_tool_output(self):
        output = "Verifies\nVerified using v3.1 scheme (APK Signature Scheme v3.1): true\nNumber of signers: 1\n"
        output += self.sdk_range_signature(33, 2147483647)
        output += self.sdk_range_signature(28, 32)
        self.assertEqual(checks.check_signer(output, PIN), PIN)

    def test_different_certificate_in_either_sdk_range_is_rejected(self):
        other = "0" * 64
        for current, original in [(PIN, other), (other, PIN)]:
            output = self.sdk_range_signature(33, 2147483647, current)
            output += self.sdk_range_signature(28, 32, original)
            with self.assertRaises(ValueError):
                checks.check_signer(output, PIN)

    def test_v31_multiple_signers_are_rejected(self):
        output = "Number of signers: 2\n" + self.sdk_range_signature(33, 2147483647)
        with self.assertRaises(ValueError):
            checks.check_signer(output, PIN)

    def test_source_stamp_is_not_the_apk_signing_identity(self):
        output = self.sdk_range_signature(33, 2147483647)
        output += "Source Stamp Signer certificate SHA-256 digest: " + "0" * 64 + "\n"
        self.assertEqual(checks.check_signer(output, PIN), PIN)

    def test_v31_dev_release_label_is_supported(self):
        output = f"Signer (minSdkVersion=33 (dev release=true), maxSdkVersion=2147483647) certificate SHA-256 digest: {PIN}\n"
        self.assertEqual(checks.check_signer(output, PIN), PIN)

    def test_historical_temporary_signers_are_rejected(self):
        for certificate in [
            "667ccc106ae4437d92c6f7869d5afc9a22208cb7c334ae5dfa383534c814fcfe",
            "b2a4cee5739465332d91a1440fe0718e7b674feee47354d0fe698688b93a8932",
        ]:
            with self.assertRaises(ValueError):
                checks.check_signer(self.signature(certificate), PIN)

    def test_unsigned_or_multiple_signers_are_rejected(self):
        for output in ["DOES NOT VERIFY", self.signature() + self.signature()]:
            with self.assertRaises(ValueError):
                checks.check_signer(output, PIN)

    def test_all_architecture_version_codes_are_checked(self):
        for abi, offset in checks.ABI_OFFSETS.items():
            result = checks.check_manifest(self.manifest(code=offset + 9, abi=abi), abi, "1.3.5", 9)
            self.assertEqual(result["versionCode"], offset + 9)

    def test_wrong_package_architecture_or_downgrade_are_rejected(self):
        for output in [self.manifest(package="other.app"), self.manifest(code=2008),
                       self.manifest(name="1.3.4"), self.manifest(abi="armeabi-v7a"), "invalid"]:
            with self.assertRaises(ValueError):
                checks.check_manifest(output, "arm64-v8a", "1.3.5", 9)

    def test_unsigned_apk_tool_failure_stops_publication(self):
        with patch.object(checks.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "apksigner")):
            with self.assertRaises(subprocess.CalledProcessError):
                checks.verify_apk(Path("app.apk"), Path("tools"), PIN, "arm64-v8a", "1.3.5", 9)

    def test_verification_reports_the_actual_certificate_and_manifest(self):
        signature = subprocess.CompletedProcess([], 0, stdout=self.signature(), stderr="")
        manifest = subprocess.CompletedProcess([], 0, stdout=self.manifest(), stderr="")
        with patch.object(checks.subprocess, "run", side_effect=[signature, manifest]):
            result = checks.verify_apk(Path("app.apk"), Path("tools"), PIN, "arm64-v8a", "1.3.5", 9)
        self.assertEqual(result["certificateSha256"], PIN)
        self.assertEqual(result["applicationId"], checks.PACKAGE)
        self.assertEqual(result["versionCode"], 2009)


if __name__ == "__main__":
    unittest.main()
