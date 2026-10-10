"""Publication must not expose incomplete builds or delete historical files."""
import importlib.util
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
            with patch.object(publisher, 'api', return_value=[dict(self.release, assets=assets)]) as api:
                with self.assertRaises(ValueError):
                    publisher.publish('owner/app', 'v1.4.0', '1.4.0')
                self.assertEqual(api.call_count, 1)

    def test_stable_publish_precedes_archival_and_retains_assets(self):
        older = {'id': 1, 'tag_name': 'v1.3.2', 'draft': False, 'assets': [{'name': 'old.apk'}]}
        already_hidden = {'id': 2, 'tag_name': 'v1.3.8', 'draft': True}
        with patch.object(publisher, 'api', side_effect=[[self.release], {}, [self.release, older, already_hidden], {}]) as api:
            publisher.publish('owner/app', 'v1.4.0', '1.4.0')
        mutations = [call for call in api.call_args_list if len(call.args) > 1]
        self.assertEqual(mutations[0].args[0], 'repos/owner/app/releases/3')
        self.assertEqual(mutations[0].args[2], {'draft': False, 'prerelease': False, 'make_latest': 'true'})
        self.assertEqual(mutations[1].args, ('repos/owner/app/releases/1', 'PATCH', {'draft': True}))
        self.assertEqual(older['assets'], [{'name': 'old.apk'}])
        self.assertEqual(len(mutations), 2)

    def test_wrong_tag_never_changes_releases(self):
        with patch.object(publisher, 'api') as api:
            with self.assertRaises(ValueError):
                publisher.publish('owner/app', 'v1.3.8', '1.4.0')
            api.assert_not_called()

    def test_mobile_release_does_not_require_desktop_or_plugin_feed_or_hide_previous_desktop_release(self):
        assets = [a for a in self.assets if a['name'].endswith(('.apk', '.ipa'))]
        release = dict(self.release, assets=assets)
        with patch.object(publisher, 'api', side_effect=[[release], {}]) as api:
            publisher.publish('owner/app', 'v1.4.0', '1.4.0', include_linux=False)
        self.assertEqual(api.call_count, 2)
        self.assertEqual(api.call_args.args[2]['draft'], False)
        with patch.object(publisher, 'api', return_value=[dict(release, assets=assets[:-1])]) as api:
            with self.assertRaises(ValueError):
                publisher.publish('owner/app', 'v1.4.0', '1.4.0', include_linux=False)
            self.assertEqual(api.call_count, 1)

    def test_only_completed_tag_builds_with_every_platform_passed_are_accepted(self):
        run = {'status': 'completed', 'head_branch': 'v1.4.0', 'head_sha': 'abc'}
        jobs = {'jobs': [{'name': n, 'conclusion': 'success'} for n in ('android', 'linux', 'ios / ios')]}
        with patch.object(publisher, 'api', side_effect=[run, jobs]), patch.object(publisher.subprocess, 'check_output', side_effect=['abc\n', 'version: 1.4.0+13\n']):
            self.assertEqual(publisher.verified_build('owner/app', 1), ('v1.4.0', '1.4.0', True))
        jobs['jobs'][1]['conclusion'] = 'skipped'
        with patch.object(publisher, 'api', side_effect=[run, jobs]), patch.object(publisher.subprocess, 'check_output', side_effect=['abc\n', 'version: 1.4.0+13\n']):
            self.assertEqual(publisher.verified_build('owner/app', 1), ('v1.4.0', '1.4.0', False))
        jobs['jobs'][1]['conclusion'] = 'failure'
        with patch.object(publisher, 'api', side_effect=[run, jobs]), self.assertRaises(ValueError):
            publisher.verified_build('owner/app', 1)
        jobs['jobs'][1]['conclusion'] = 'success'
        jobs['jobs'][2]['conclusion'] = 'failure'
        with patch.object(publisher, 'api', side_effect=[run, jobs]), self.assertRaises(ValueError):
            publisher.verified_build('owner/app', 1)
        with patch.object(publisher, 'api', return_value=dict(run, status='in_progress')), self.assertRaises(ValueError):
            publisher.verified_build('owner/app', 1)
        with patch.object(publisher, 'api', return_value=dict(run, head_branch='main')), self.assertRaises(ValueError):
            publisher.verified_build('owner/app', 1)


if __name__ == '__main__':
    unittest.main()
