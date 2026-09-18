#!/usr/bin/env python3
"""Exercise the real packaged companion without discovery, publication or network requests."""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dist', type=Path)
    parser.add_argument('suffix')
    args = parser.parse_args()
    suffix = '-' + args.suffix if args.suffix else ''
    source = json.loads((args.dist / ('nearby-source' + suffix + '.json')).read_text())
    pin = (Path(__file__).resolve().parents[1] / 'ci/cellprotocol-nearby-revision.txt').read_text().strip()
    assert source['revision'] == pin
    with tempfile.TemporaryDirectory(prefix='sprout-packaged-nearby-') as directory:
        root = Path(directory)
        for name in ('sprout', 'haven-nearby'):
            shutil.copy2(args.dist / (name + suffix), root / name)
        env = dict(os.environ)
        env.pop('SPROUT_NEARBY_HELPER', None)

        def run(*arguments):
            return subprocess.run([str(root / 'sprout'), 'nearby', *arguments],
                                  capture_output=True, text=True, timeout=10, env=env, cwd=root)

        help_result = run('--help')
        assert help_result.returncode == 0, help_result.stderr
        assert 'haven-nearby inspect --offer-file' in help_result.stdout
        assert 'Discovery does not prove ownership.' in help_result.stdout
        offer = {'schema': 'haven.nearby-link-offer.v1', 'origin': 'https://haven.digipomps.org',
                 'offerID': 'a' * 64, 'expiresAt': int(time.time()) + 120}
        offer_file = root / 'synthetic-offer.txt'

        def inspect(value, accepted):
            encoded = base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
            offer_file.write_text('haven://nearby-link?offer=' + encoded)
            result = run('inspect', '--offer-file', str(offer_file))
            if accepted:
                assert result.returncode == 0, result.stderr
                assert json.loads(result.stdout) == value
            else:
                assert result.returncode == 2
                assert not result.stdout.strip()

        inspect(offer, True)
        inspect(dict(offer, expiresAt=int(time.time()) - 1), False)
        inspect(dict(offer, origin='https://untrusted.example'), False)
        inspect(dict(offer, offerID='not-a-valid-offer'), False)
    print('PASS: actual packaged companion help, valid local inspect, expired/untrusted/malformed rejection; no network or radio')


if __name__ == '__main__':
    main()
