"""Publish verified platforms, retaining desktop downloads for mobile releases."""
import json
import os
import re
import subprocess
from urllib.request import Request, urlopen


def api(path, method='GET', data=None):
    request = Request('https://api.github.com/' + path, method=method,
        data=None if data is None else json.dumps(data).encode(),
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
            'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json',
            'X-GitHub-Api-Version': '2022-11-28'})
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def releases(repository):
    page = 1
    while True:
        items = api(f'repos/{repository}/releases?per_page=100&page={page}')
        yield from items
        if len(items) < 100:
            break
        page += 1


def publish(repository, tag, version, *, include_linux=True):
    if tag != 'v' + version or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Release tag must match the app version')
    # GitHub's tag endpoint can return 404 for drafts. The authenticated list
    # includes drafts and lets us select the exact tag before touching assets.
    release = next((item for item in releases(repository) if item['tag_name'] == tag), None)
    if release is None:
        raise ValueError('Release draft was not found')
    required = {*(f'FusionReader-{version}-android-{abi}.apk' for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64')),
        'FusionReader-ios-unsigned.ipa'}
    if include_linux:
        required.add('FusionReader-linux-x64.tar.gz')
    present = {asset['name'] for asset in release['assets'] if asset['size'] > 100_000}
    if not required <= present:
        raise ValueError('Required release packages are missing: ' + ', '.join(sorted(required - present)))
    api(f'repos/{repository}/releases/{release["id"]}', 'PATCH',
        {'draft': False, 'prerelease': False, 'make_latest': 'true'})
    print('Published stable release ' + tag)
    if not {f'FusionReader-{version}-windows-x64.zip', 'FusionReader-linux-x64.tar.gz'} <= present:
        print('Previous desktop release remains available until desktop packages are added.')
        return
    # Preserve every asset and tag; only remove older releases from public lists.
    for old in list(releases(repository)):
        if old['id'] != release['id'] and not old['draft']:
            api(f'repos/{repository}/releases/{old["id"]}', 'PATCH', {'draft': True})
            print('Archived as draft: ' + old['tag_name'])


def verified_build(repository, run_id):
    run = api(f'repos/{repository}/actions/runs/{run_id}')
    tag = run['head_branch']
    if run['status'] != 'completed' or not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('A completed version-tag build is required')
    jobs = api(f'repos/{repository}/actions/runs/{run_id}/jobs?per_page=100')['jobs']
    results = {job['name']: job['conclusion'] for job in jobs}
    if any(results.get(name) != 'success' for name in ('android', 'ios / ios')) or results.get('linux') not in ('success', 'skipped'):
        raise ValueError('Android and iOS must pass; Linux must pass or be intentionally skipped')
    commit = subprocess.check_output(['git', 'rev-parse', tag + '^{commit}'], text=True).strip()
    if commit != run['head_sha']:
        raise ValueError('Build commit and release tag differ')
    spec = subprocess.check_output(['git', 'show', tag + ':pubspec.yaml'], text=True)
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+)', spec, re.M)[1]
    return tag, version, results['linux'] == 'success'


if __name__ == '__main__':
    repository = os.environ['GITHUB_REPOSITORY']
    tag, version, include_linux = verified_build(repository, os.environ['FUSION_BUILD_RUN_ID'])
    publish(repository, tag, version, include_linux=include_linux)
