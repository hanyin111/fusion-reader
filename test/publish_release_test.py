"""Publication must not expose incomplete builds or delete historical files."""
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('publish_release', Path(__file__).parents[1] / 'scripts/publish_release.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        self.assets = [{'name': name, 'size': 200_000} for name in [
            'FusionReader-1.4.0-windows-x64.zip', 'FusionReader-linux-x64.tar.gz',
            'FusionReader-ios-unsigned.ipa', *[f'FusionReader-1.4.0-android-{abi}.apk'
                for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64')]]]
        self.release = {'id': 3, 'tag_name': 'v1.4.0', 'draft': True, 'assets': self.assets}

    def test_missing_or_empty_package_never_publishes_or_archives(self):
        for assets in [self.assets[:-1], [dict(a, size=0) for a in self.assets]]:
            with patch.object(publisher, 'api', return_value=dict(self.release, assets=assets)) as api:
                with self.assertRaises(ValueError):
                    publisher.publish('owner/app', 'v1.4.0', '1.4.0')
                self.assertEqual(api.call_count, 1)

    def test_stable_publish_precedes_archival_and_retains_assets(self):
        older = {'id': 1, 'tag_name': 'v1.3.2', 'draft': False, 'assets': [{'name': 'old.apk'}]}
        already_hidden = {'id': 2, 'tag_name': 'v1.3.8', 'draft': True}
        feed = io.BytesIO(json.dumps({'schemaVersion': 1, 'extensions': [{'package': 'fixture'}]}).encode())
        with patch.object(publisher, 'api', side_effect=[self.release, {}, [self.release, older, already_hidden], {}]) as api, patch.object(publisher, 'urlopen', return_value=feed):
            publisher.publish('owner/app', 'v1.4.0', '1.4.0')
        mutations = [call for call in api.call_args_list if len(call.args) > 1]
        self.assertEqual(mutations[0].args[0], 'repos/owner/app/releases/3')
        self.assertEqual(mutations[0].args[2], {'draft': False, 'prerelease': False, 'make_latest': 'true'})
        self.assertEqual(mutations[1].args, ('repos/owner/app/releases/1', 'PATCH', {'draft': True}))
        self.assertEqual(older['assets'], [{'name': 'old.apk'}])
        self.assertEqual(len(mutations), 2)

    def test_wrong_tag_or_unavailable_plugin_feed_never_changes_releases(self):
        with patch.object(publisher, 'api') as api:
            with self.assertRaises(ValueError):
                publisher.publish('owner/app', 'v1.3.8', '1.4.0')
            api.assert_not_called()
        with patch.object(publisher, 'api', return_value=self.release) as api, patch.object(publisher, 'urlopen', return_value=io.BytesIO(b'{"schemaVersion":1,"extensions":[]}')):
            with self.assertRaises(ValueError):
                publisher.publish('owner/app', 'v1.4.0', '1.4.0')
            self.assertEqual(api.call_count, 1)


if __name__ == '__main__':
    unittest.main()
