"""Publish a complete stable release and retain previous releases as drafts."""
import json
import os
import re
from urllib.request import Request, urlopen


def api(path, method='GET', data=None):
    request = Request('https://api.github.com/' + path, method=method,
        data=None if data is None else json.dumps(data).encode(),
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
            'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json',
            'X-GitHub-Api-Version': '2022-11-28'})
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def publish(repository, tag, version):
    if tag != 'v' + version or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Release tag must match the app version')
    release = api(f'repos/{repository}/releases/tags/{tag}')
    required = {f'FusionReader-{version}-windows-x64.zip',
        *(f'FusionReader-{version}-android-{abi}.apk' for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64')),
        'FusionReader-linux-x64.tar.gz', 'FusionReader-ios-unsigned.ipa'}
    present = {asset['name'] for asset in release['assets'] if asset['size'] > 100_000}
    if not required <= present:
        raise ValueError('Required release packages are missing: ' + ', '.join(sorted(required - present)))
    with urlopen('https://hanyin111.github.io/fusion-reader-extensions/index.json', timeout=30) as response:
        index = json.load(response)
    if index.get('schemaVersion') != 1 or not index.get('extensions'):
        raise ValueError('Published plugin repository is not ready')
    api(f'repos/{repository}/releases/{release["id"]}', 'PATCH',
        {'draft': False, 'prerelease': False, 'make_latest': 'true'})
    print('Published stable release ' + tag)
    # Preserve every asset and tag; only remove older releases from public lists.
    page = 1
    while True:
        previous = api(f'repos/{repository}/releases?per_page=100&page={page}')
        for old in previous:
            if old['id'] != release['id'] and not old['draft']:
                api(f'repos/{repository}/releases/{old["id"]}', 'PATCH', {'draft': True})
                print('Archived as draft: ' + old['tag_name'])
        if len(previous) < 100:
            break
        page += 1


if __name__ == '__main__':
    from pathlib import Path
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+)', Path('pubspec.yaml').read_text(), re.M)[1]
    publish(os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_REF_NAME'], version)
