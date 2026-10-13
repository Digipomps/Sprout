#!/usr/bin/env python3
"""Process-level purpose selection/signature tests; no Docker or registry access."""
import argparse, base64, datetime, json, os, pathlib, platform, subprocess, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--sprout', required=True)
parser.add_argument('--output-dir', required=True)
args = parser.parse_args()
binary = str(pathlib.Path(args.sprout).resolve())
out = pathlib.Path(args.output_dir).resolve()
out.mkdir(parents=True, exist_ok=True)
checks = []

def run(name, argv, expected=0, stdin=None):
    result = subprocess.run([binary] + argv, input=stdin, text=True, capture_output=True, timeout=30)
    (out / (name + '.stdout')).write_text(result.stdout)
    (out / (name + '.stderr')).write_text(result.stderr)
    checks.append({'name': name, 'exit_code': result.returncode, 'expected': expected})
    assert result.returncode == expected, (name, result.returncode, result.stderr)
    return result.stdout

with tempfile.TemporaryDirectory(prefix='sprout-scaffold-cli-') as temporary:
    root = pathlib.Path(temporary)
    domain = 'scaffold-install-test.invalid'
    owners = str(root / 'owners')
    owner = json.loads(run('owner', ['owner', 'init', '--domain', domain, '--root', owners]))
    key = owner['identity_public_key']
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp = lambda value: value.isoformat(timespec='seconds').replace('+00:00', 'Z')
    host = ('linux' if platform.system() == 'Linux' else 'macos') + ('-arm64' if platform.machine() in ('aarch64', 'arm64') else '-x86_64')
    digest = '294aaf0c09a329bd97f32a52cab3075f3c3474be046f6d4c730bdcbf26e9f565'
    artifact = {'artifact_id': 'cellscaffold-web-test', 'name': 'CellScaffold web test', 'kind': 'cellscaffold',
                'platform': host, 'semver': '2026.10.13-test', 'channel': 'stable',
                'download_url': 'https://ghcr.io/v2/digipomps/cellscaffold-web/manifests/sha256:' + digest,
                'sha256_b64url': base64.urlsafe_b64encode(bytes.fromhex(digest)).decode().rstrip('='),
                'signing': [{'type': 'catalog-ed25519', 'identity': key}],
                'purpose_ids': ['purpose://test.scaffold.operations'], 'dependencies': [],
                'installation': {'format': 'oci-image', 'image': 'ghcr.io/digipomps/cellscaffold-web@sha256:' + digest,
                                 'container_platform': 'linux/arm64' if host == 'linux-arm64' else 'linux/amd64'}}
    catalog = {'version': '1.1', 'catalog_id': 'cli-process-test', 'scaffold_domain': domain,
               'issued_at': stamp(now - datetime.timedelta(seconds=5)), 'expires_at': stamp(now + datetime.timedelta(hours=1)),
               'issued_by': key, 'artifacts': [artifact], 'signature': {'alg': 'Ed25519', 'sig': ''}}
    unsigned = root / 'unsigned.json'
    unsigned.write_text(json.dumps(catalog))
    signed = root / 'catalog.json'
    run('sign', ['software', 'sign-catalog', '--domain', domain, '--root', owners, '--unsigned', str(unsigned), '--out', str(signed)])
    common = ['--domain', domain, '--catalog', str(signed), '--root', str(root / 'install-state'), '--trusted-publisher-key', key]
    purposes = json.loads(run('purposes', ['scaffold', 'purposes'] + common))
    assert purposes == ['purpose://test.scaffold.operations']
    plan = json.loads(run('plan', ['scaffold', 'plan'] + common + ['--purpose', purposes[0]]))
    assert [a['artifact_id'] for a in plan['artifacts']] == ['cellscaffold-web-test']
    run('unknown-purpose', ['scaffold', 'plan'] + common + ['--purpose', 'purpose://unknown'], 2)
    run('untrusted-publisher', ['scaffold', 'plan'] + common[:-4] + ['--root', str(root / 'untrusted'), '--trusted-publisher-key', base64.urlsafe_b64encode(bytes(32)).decode().rstrip('='), '--purpose', purposes[0]], 2)
    run('missing-pin', ['scaffold', 'install', '--domain', domain, '--catalog', str(signed), '--root', str(root / 'unpinned'), '--purpose', purposes[0], '--yes'], 2)
    run('declined-installation', ['scaffold', 'install'] + common + ['--purpose', purposes[0]], stdin='nei\n')
    run('scaffoldadmin-role', ['onboard', '--role', 'scaffoldadmin'] + common, stdin='1\nnei\n')
    forged = json.loads(signed.read_text())
    forged['artifacts'][0]['purpose_ids'].append('purpose://forged')
    signed.write_text(json.dumps(forged))
    run('tampered-purpose-signature', ['scaffold', 'plan'] + common + ['--purpose', 'purpose://forged'], 2)
    assert not (root / 'install-state' / 'installations').exists(), 'Plan/decline must not install or invoke Docker'
(out / 'results.json').write_text(json.dumps({'checks': checks, 'passed': len(checks), 'download_attempts': 0}, indent=2) + '\n')
print(json.dumps({'passed': len(checks), 'output': str(out), 'download_attempts': 0}))
