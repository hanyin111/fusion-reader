import base64
from contextlib import redirect_stdout
import hashlib
import io
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
PEM = (ROOT / "test/fixtures/android_signing_certificate.pem").read_text()
CI_OUTPUT = (ROOT / "test/fixtures/apksigner_v1.3.6_stdout.txt").read_text()


def foreign_certificate():
    # Change the public certificate bytes; its displayed fingerprint must
    # never make the altered certificate pass the pinned identity check.
    der = bytearray(base64.b64decode("".join(PEM.splitlines()[1:-1])))
    der[-1] ^= 1
    return "-----BEGIN CERTIFICATE-----\n" + base64.b64encode(der).decode() + "\n-----END CERTIFICATE-----\n"


class AndroidSigningTest(unittest.TestCase):
    def signature(self, certificate=PEM, label="V2 Signer:"):
        return f"Verifies\nNumber of signers: 1\n{label} certificate SHA-256 digest: {PIN}\n{certificate}"

    def manifest(self, package=checks.PACKAGE, code=2011, name="1.3.7", abi="arm64-v8a"):
        return f"package: name='{package}' versionCode='{code}' versionName='{name}'\nnative-code: '{abi}'\n"

    def test_real_public_certificate_matches_pinned_fingerprint(self):
        der = base64.b64decode("".join(PEM.splitlines()[1:-1]))
        self.assertEqual(hashlib.sha256(der).hexdigest(), PIN)

    def test_actual_failed_ci_output_with_pem_is_accepted(self):
        # CI captured --print-certs output. The documented new flag appends
        # this same certificate as PEM, so labels no longer affect parsing.
        self.assertEqual(checks.check_signer(CI_OUTPUT + PEM, PIN), PIN)

    def test_display_labels_do_not_affect_certificate_verification(self):
        for label in ["Signer #1", "V2 Signer:", "V3.2 Signer:",
                      "Signer (minSdkVersion=33, maxSdkVersion=2147483647)", "Future tool label:"]:
            with self.subTest(label=label):
                self.assertEqual(checks.check_signer(self.signature(label=label), PIN), PIN)

    def test_displayed_digest_cannot_override_certificate_bytes(self):
        with self.assertRaises(ValueError):
            checks.check_signer(self.signature(foreign_certificate()), PIN)

    def test_same_fixed_certificate_across_sdk_ranges_is_accepted(self):
        output = self.signature() + "Another SDK range\n" + PEM
        self.assertEqual(checks.check_signer(output, PIN), PIN)

    def test_foreign_certificate_in_either_sdk_range_is_rejected(self):
        for first, second in [(PEM, foreign_certificate()), (foreign_certificate(), PEM)]:
            with self.assertRaises(ValueError):
                checks.check_signer(self.signature(first) + second, PIN)

    def test_multiple_signing_identities_are_rejected(self):
        output = self.signature().replace("Number of signers: 1", "Number of signers: 2")
        for text in [output, output.replace("\n", "\r\n")]:
            with self.assertRaises(ValueError):
                checks.check_signer(text, PIN)

    def test_missing_truncated_or_malformed_pem_is_rejected(self):
        for output in [CI_OUTPUT, "DOES NOT VERIFY", "-----BEGIN CERTIFICATE-----\n",
                       "-----BEGIN CERTIFICATE-----!-----END CERTIFICATE-----",
                       "-----BEGIN CERTIFICATE-----a-----END CERTIFICATE-----"]:
            with self.assertRaises(ValueError):
                checks.check_signer(output, PIN)

    def test_certificate_text_with_crlf_is_accepted(self):
        self.assertEqual(checks.check_signer(self.signature().replace("\n", "\r\n"), PIN), PIN)

    def test_historical_temporary_signers_are_not_accepted(self):
        for certificate in [
            "667ccc106ae4437d92c6f7869d5afc9a22208cb7c334ae5dfa383534c814fcfe",
            "b2a4cee5739465332d91a1440fe0718e7b674feee47354d0fe698688b93a8932",
        ]:
            with self.assertRaises(ValueError):
                checks.check_signer(self.signature(), certificate)

    def test_all_architecture_version_codes_are_checked(self):
        # Independent values from Flutter's ABI_VERSION mapping and CI APKs.
        # Do not derive expectations from the implementation under test.
        for abi, code in [("armeabi-v7a", 1011), ("arm64-v8a", 2011), ("x86_64", 4011)]:
            result = checks.check_manifest(self.manifest(code=code, abi=abi), abi, "1.3.7", 11)
            self.assertEqual(result["versionCode"], code)

    def test_reserved_x86_offset_is_not_used_for_x86_64(self):
        with self.assertRaises(ValueError):
            checks.check_manifest(self.manifest(code=3011, abi="x86_64"), "x86_64", "1.3.7", 11)

    def test_wrong_package_architecture_or_downgrade_are_rejected(self):
        for output in [self.manifest(package="other.app"), self.manifest(code=2010),
                       self.manifest(name="1.3.6"), self.manifest(abi="armeabi-v7a"), "invalid"]:
            with self.assertRaises(ValueError):
                checks.check_manifest(output, "arm64-v8a", "1.3.7", 11)

    def test_unsigned_apk_tool_failure_stops_publication(self):
        with patch.object(checks.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "apksigner")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                checks.verify_apk(Path("app.apk"), Path("tools"), PIN, "arm64-v8a", "1.3.7", 11)
        self.assertEqual(run.call_count, 1)

    def test_verification_requests_pem_and_reports_actual_metadata(self):
        signature = subprocess.CompletedProcess([], 0, stdout=self.signature(), stderr="")
        manifest = subprocess.CompletedProcess([], 0, stdout=self.manifest(), stderr="")
        with patch.object(checks.subprocess, "run", side_effect=[signature, manifest]) as run, redirect_stdout(io.StringIO()):
            result = checks.verify_apk(Path("app.apk"), Path("tools"), PIN, "arm64-v8a", "1.3.7", 11)
        self.assertIn("--print-certs-pem", run.call_args_list[0].args[0])
        self.assertEqual(result["certificateSha256"], PIN)
        self.assertEqual(result["applicationId"], checks.PACKAGE)
        self.assertEqual(result["versionCode"], 2011)


if __name__ == "__main__":
    unittest.main()
