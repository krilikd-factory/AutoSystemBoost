#!/usr/bin/env python3
"""Report public OTA metadata separately from the source build; never publish it."""
import json
import os
import sys
from pathlib import Path
from urllib.parse import urlparse


def main():
    repo = os.environ.get('GITHUB_REPOSITORY', '')
    try:
        data = json.loads(Path('update.json').read_text(encoding='utf-8'))
        props = dict(line.split('=', 1) for line in Path('module.prop').read_text().splitlines() if '=' in line)
        if not isinstance(data, dict) or not isinstance(data.get('version'), str) or not data['version']:
            raise ValueError('version must be a nonempty string')
        if type(data.get('versionCode')) is not int or data['versionCode'] <= 0:
            raise ValueError('versionCode must be a positive integer')
        print('Public OTA: {} / {}; source build: {} / {}. A testing version may intentionally differ.'.format(
            data['version'], data['versionCode'], props.get('version', '?'), props.get('versionCode', '?')))
        for field, host in (('zipUrl', 'github.com'), ('changelog', 'raw.githubusercontent.com')):
            url = data.get(field)
            if not isinstance(url, str):
                raise ValueError(field + ' must be an HTTPS URL')
            parsed = urlparse(url)
            if parsed.scheme != 'https' or parsed.netloc != host:
                raise ValueError(field + ' has an unexpected URL host or scheme')
            path = parsed.path.strip('/').split('/')
            if repo and '/'.join(path[:2]).lower() != repo.lower():
                print('::warning::update.json {} points to a different repository; review before publication.'.format(field))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print('::warning::Unable to validate public OTA metadata: {}'.format(exc))
    return 0


if __name__ == '__main__':
    sys.exit(main())
