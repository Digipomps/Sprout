#!/usr/bin/env python3
"""Coordinator boundary tests; no Docker daemon, root or network is required.

The model simulates Docker but uses real files, subprocesses, flock inheritance,
atomic writes and crash/retry checkpoints. Actual CellScaffold cryptography and
Linux namespace behavior belong to the real-image acceptance test on Linux.
"""
from __future__ import annotations
import copy
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


def native_child():
    """A real child process standing in for the image's already-tested verifier."""
    env = os.environ
    assert 'CELL_VAULT_MASTER_KEY_B64' not in env
    assert 'SPROUT_TEST_SECRET' not in env
    assert env['CELL_VAULT_ALLOW_DEV_KEYGEN'] == 'false'
    descriptor = int(env['CELL_SCAFFOLD_BOOTSTRAP_LOCK_FD'])
    assert stat.S_ISREG(os.fstat(descriptor).st_mode)
    separate = os.open(env['CELL_SCAFFOLD_BOOTSTRAP_LOCK_PATH'], os.O_RDWR)
    try:
        try:
            fcntl.flock(separate, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            pass
        else:
            raise AssertionError('parent offline lock was not inherited/held')
    finally:
        os.close(separate)
    root = Path(env['CELL_VAULT_DOCUMENT_ROOT'])
    key = Path(env['CELL_VAULT_MASTER_KEY_PATH']).read_bytes()
    assert len(key) == 32
    journal = Path(env['CELL_SCAFFOLD_BOOTSTRAP_ENROLLMENT_JOURNAL_PATH'])
    owner = {'uuid': env['CELL_SCAFFOLD_BOOTSTRAP_OWNER_UUID'], 'context': 'Scaffold',
             'signingKeyFingerprintDigest': 'o' * 43}
    intent = {'owner': owner, 'enrollment_id': env['CELL_SCAFFOLD_BOOTSTRAP_ENROLLMENT_ID'],
              'issued_at': env['CELL_SCAFFOLD_BOOTSTRAP_ENROLLMENT_ISSUED_AT']}
    if journal.exists():
        assert json.loads(journal.read_bytes()) == intent
    else:
        journal.write_text(json.dumps(intent)); journal.chmod(0o600)
    vault = root / 'OrganisationIdentities.crypt'
    encrypted_model = hashlib.sha256(key + owner['uuid'].encode()).digest()
    if vault.exists():
        assert vault.read_bytes() == encrypted_model
    else:
        vault.write_bytes(encrypted_model); vault.chmod(0o600)
    document = {'payload': {
        'schemaVersion': 'haven.cellscaffold.runtime-identity-manifest.v3',
        'canonicalization': 'json_sorted_keys_and_arrays_v1',
        'registrySchemaVersion': 'haven.cellscaffold.runtime-identity-registry.v3',
        'registryDigest': 'sha256:' + 'r' * 43, 'effectiveOwnerContext': 'Scaffold',
        'build': {'appRevision': env['APP_BUILD_REVISION'], 'cellProtocolRevision': env['CELLPROTOCOL_BUILD_REVISION'],
                  'dimyMintRevision': env['DIMYMINT_BUILD_REVISION'], 'buildTimestamp': env['APP_BUILD_TIMESTAMP'],
                  'environment': 'production'},
        'bindings': [{'registryID': 'owner.scaffold', 'state': 'present', 'identityUUID': owner['uuid'],
                      'context': 'Scaffold', 'signingKeyFingerprintDigest': owner['signingKeyFingerprintDigest']}],
        'legacyContinuityBindings': []},
        'signature': {'algorithm': 'Ed25519', 'signerIdentityUUID': owner['uuid'],
                      'signerFingerprintDigest': owner['signingKeyFingerprintDigest'], 'signatureBase64URL': 'test-model'}}
    manifest = json.dumps(document, sort_keys=True, separators=(',', ':')).encode()
    target = Path(env['CELL_SCAFFOLD_BOOTSTRAP_MANIFEST_PATH'])
    if target.exists():
        assert target.read_bytes() == manifest
    else:
        target.write_bytes(manifest); target.chmod(0o600)
    print(json.dumps({'schemaVersion': 'haven.cellscaffold.runtime-identity-verification-receipt.v1',
        'operation': 'enroll-first-owner', 'status': 'verified', 'appRevision': env['APP_BUILD_REVISION'],
        'registryDigest': 'sha256:' + 'r' * 43, 'manifestSHA256': 'sha256:' + hashlib.sha256(manifest).hexdigest(),
        'owner': owner}))


if len(sys.argv) == 2 and sys.argv[1] == '--native-child':
    native_child()
    sys.exit(0)

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / 'Packages/SproutCore/Sources/SproutCore/Resources/sprout-service.py'
spec = importlib.util.spec_from_file_location('sprout_service', SCRIPT)
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)

IMAGE = 'registry.example/team/scaffold@sha256:' + '1' * 64
IMAGE_ID = 'sha256:' + '2' * 64
BUILD = {'app_revision': 'a' * 40, 'build_timestamp': '2026-10-13T10:11:12Z'}
REVISIONS = {'cellprotocol': 'b' * 40, 'dimymicropayments': 'c' * 40, 'dimymint': 'd' * 40}


def request(**changes):
    value = {'schema': s.SCHEMA, 'operation': 'install', 'instance': 'test', 'root': str(s.ROOT),
             'image': IMAGE, 'platform': 'linux/amd64', 'profile': s.PROFILE, 'listen_port': 9089,
             'purposes': ['purpose://haven/communicate'], 'public_origin': 'https://scaffold.example:8443'}
    value.update(changes)
    return s.request_document(value)


class DockerModel(s.System):
    def __init__(self):
        self.calls = []
        self.containers = {}
        self.sequence = 0
        self.busy_port = False
        self.native_calls = 0
        self.native_fail = False
        self.native_unknown = False
        self.canonical_exit = 0
        self.canonical_interrupted = False
        self.bad_health = None
        self.bad_after_restart = False
        self.bridge_fault = None
        self.bridge_queries = []
        self.did_restart = False
        self.image = {'Id': IMAGE_ID, 'RepoDigests': [IMAGE], 'Os': 'linux', 'Architecture': 'amd64',
                      'Config': {'Labels': {'org.opencontainers.image.revision': BUILD['app_revision'],
                                'org.opencontainers.image.created': BUILD['build_timestamp'],
                                'org.opencontainers.image.source': 'https://github.com/Digipomps/CellScaffold'},
                                 'Env': ['APP_BUILD_REVISION=' + BUILD['app_revision'],
                                         'APP_BUILD_TIMESTAMP=' + BUILD['build_timestamp']]}}

    def container(self, name):
        self.calls.append(('inspect-container', name))
        for identifier, value in self.containers.items():
            if name in (identifier, value['Name']):
                return copy.deepcopy(value)
        return None

    def port_free(self, port):
        self.calls.append(('port-free', port))
        s.require(not self.busy_port, 'listen_port_busy')

    def docker(self, *args, timeout=180, allow_missing=False):
        self.calls.append(args)
        if args[:2] == ('image', 'inspect'):
            return s.canonical_json([self.image])
        if args[0] == 'create':
            self.sequence += 1
            identifier = format(self.sequence, '064x')
            if '--name' not in args:  # Non-running extraction container.
                self.containers[identifier] = {'Id': identifier, 'Name': 'extract'}
                return identifier.encode()
            name = args[args.index('--name') + 1]
            def all_values(flag):
                return [args[i + 1] for i, value in enumerate(args) if value == flag]
            environment = self.image['Config']['Env'] + Path(args[args.index('--env-file') + 1]).read_text().splitlines()
            labels = dict(value.split('=', 1) for value in all_values('--label'))
            publish = all_values('--publish')
            ports = {'8080/tcp': [{'HostIp': '127.0.0.1', 'HostPort': publish[0].split(':')[1]}]} if publish else {}
            self.containers[identifier] = {'Id': identifier, 'Name': name, 'Image': IMAGE_ID,
                'Config': {'Image': IMAGE, 'User': '995:995', 'Labels': labels, 'Env': environment,
                           'Entrypoint': ['/usr/local/bin/cellscaffold-entrypoint'],
                           'Cmd': ['serve', '--env', 'production', '--hostname', '0.0.0.0', '--port', '8080']},
                'HostConfig': {'Privileged': False, 'NetworkMode': args[args.index('--network') + 1],
                               'CapDrop': ['ALL'], 'SecurityOpt': ['no-new-privileges:true'],
                               'Binds': all_values('--volume'), 'PortBindings': ports,
                               'RestartPolicy': {'Name': 'no'}},
                'State': {'Running': False, 'Status': 'created', 'ExitCode': 0}}
            return identifier.encode()
        if args[0] == 'cp':
            source = args[1].split(':', 1)[1]
            if source.endswith('CellScaffoldIdentityBootstrap'):
                data = b'\x7fELF' + b'bounded-test-native'
            elif source.endswith('Package.resolved'):
                data = s.canonical_json({'pins': [{'identity': name, 'state': {'revision': revision}} for name, revision in REVISIONS.items()]})
            else:
                data = s.canonical_json(BUILD)
            Path(args[2]).write_bytes(data)
            return b''
        if args[0] == 'rm':
            del self.containers[args[1]]
            return b''
        item = self.containers[args[-1]]
        if args[0] in ('start', 'restart'):
            item['State'] = {'Running': True, 'Status': 'running', 'ExitCode': 0}
            if args[0] == 'restart':
                self.did_restart = True
            return b''
        if args[0] == 'wait':
            if self.canonical_interrupted:
                # Exercise real timeout/process-group cleanup while the model's
                # Docker container remains alive until coordinator rollback.
                s.System().run([sys.executable, '-I', '-c', 'import time; time.sleep(5)'], timeout=0.02)
            item['State'] = {'Running': False, 'Status': 'exited', 'ExitCode': self.canonical_exit}
            return str(self.canonical_exit).encode()
        if args[0] == 'logs':
            return b'status=eager_bootstrap_provisioning_complete'
        if args[0] == 'stop':
            if item['State']['Running']:
                item['State']['ExitCode'] = 143
            item['State']['Running'] = False
            item['State']['Status'] = 'exited'
            return b''
        if args[0] == 'update':
            item['HostConfig']['RestartPolicy']['Name'] = args[args.index('--restart') + 1]
            return b''
        raise AssertionError(args)

    def run(self, arguments, *, environment=None, pass_fds=(), timeout=180, limit=s.MAX_JSON):
        assert arguments[:7] == ['/usr/bin/unshare', '--net', '--', '/usr/bin/setpriv', '--reuid=995', '--regid=995', '--clear-groups']
        assert arguments[7:11] == ['--no-new-privs', '--bounding-set=-all', '--inh-caps=-all', '--ambient-caps=-all']
        assert len(pass_fds) == 1
        self.native_calls += 1
        if self.native_fail:
            return 2, b'', b'private native diagnostic must never escape'
        result = super().run([sys.executable, '-I', str(Path(__file__).resolve()), '--native-child'],
                             environment=environment, pass_fds=pass_fds, timeout=timeout, limit=limit)
        assert result[0] == 0, result[2].decode()
        if self.native_unknown:
            self.native_unknown = False
            raise s.Rejected('command_interrupted')
        return result

    def pause(self):
        pass

    def http(self, port, path, *, json_body=None):
        self.calls.append(('http', path))
        if self.bad_health == path or (self.did_restart and self.bad_after_restart):
            return 503, {}, b'{}'
        if path == '/health/ready':
            return 200, {}, b'{"acceptsNewTraffic":true}'
        if path == '/health/build':
            return 200, {}, s.canonical_json(dict(BUILD, environment='production', **{key + '_revision': value for key, value in REVISIONS.items()}))
        if path == '/login':
            return 200, {}, b'<html>Passkey<script src="/webauthn.js"></script></html>'
        if path == '/porthole':
            return 303, {'Location': '/login?next=porthole'}, b''
        if path == '/v1/bridges/query':
            self.bridge_queries.append(copy.deepcopy(json_body))
            assert isinstance(json_body, dict) and json_body.get('interests')
            service = next(value for value in self.containers.values()
                           if value.get('Config', {}).get('Labels', {}).get('org.haven.sprout.phase') == 'service')
            env = dict(value.split('=', 1) for value in service['Config']['Env'])
            purpose = json_body['purpose']
            if (purpose not in env.get('SPROUT_BRIDGE_ALLOWED_PURPOSES', 'bootstrap.join_scaffold').split(',')
                    or json_body['scaffold_domain'] != env.get('SPROUT_SCAFFOLD_DOMAIN') or self.bridge_fault == 'forbidden'):
                return 403, {}, b'{"error":true}'
            route = ('/v1/resolver/native-porthole/Porthole' if purpose == 'purpose://operate-local-haven-agent'
                     else '/bridgehead/Porthole/CloudBridge')
            bridge = {'scaffold_domain': env['SPROUT_SCAFFOLD_DOMAIN'], 'purpose_constraints': [purpose],
                      'bridge_endpoint': 'wss://' + env['CELL_SCAFFOLD_BRIDGE_ORIGIN'][len('https://'):] + route}
            if self.bridge_fault == 'domain': bridge['scaffold_domain'] = 'other.example'
            if self.bridge_fault == 'purpose': bridge['purpose_constraints'] = ['bootstrap.join_scaffold']
            if self.bridge_fault == 'origin': bridge['bridge_endpoint'] = 'wss://other.example:8443' + route
            if self.bridge_fault == 'port': bridge['bridge_endpoint'] = 'wss://scaffold.example' + route
            if self.bridge_fault == 'insecure': bridge['bridge_endpoint'] = 'ws://scaffold.example:8443' + route
            if self.bridge_fault == 'path': bridge['bridge_endpoint'] += '/unexpected'
            return 200, {}, s.canonical_json({'bridges': [] if self.bridge_fault == 'empty' else [bridge]})
        raise AssertionError(path)


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sprout-service-tests-')
        self.base = Path(self.temporary.name).resolve()
        self.uid, self.gid = os.getuid(), os.getgid()
        self.patches = [patch.object(s, 'ROOT', self.base / s.ROOT.relative_to('/var/lib')),
                        patch.object(s, 'LEGACY_ROOT', self.base / 'haven' / 'sprout', create=True),
                        patch.object(s, 'verify_ancestors', self.safe_test_ancestors),
                        patch.object(s, 'ROOT_UID', self.uid), patch.object(s, 'ROOT_GID', self.gid),
                        patch.object(s, 'RUNTIME_UID', self.uid), patch.object(s, 'RUNTIME_GID', self.gid),
                        patch.object(s, 'host_preflight', self.safe_test_preflight)]
        for item in self.patches:
            item.start()
        self.system = DockerModel()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temporary.cleanup()

    def safe_test_preflight(self, value):
        # Test only substitutes machine ownership and tools; all generated paths
        # and file metadata still use production validation on a private tree.
        for path in (self.base, self.base / 'haven', s.ROOT):
            if path.exists() or path.is_symlink():
                s.validate_directory(path)

    def safe_test_ancestors(self, path, runtime_access=False):
        # The portable fixture substitutes only trusted system ancestors outside
        # its private root. Production directory/permission checks run inside it.
        cursor = self.base
        for part in (None, *path.relative_to(self.base).parts):
            if part is not None:
                cursor /= part
            if not cursor.exists() and not cursor.is_symlink():
                break
            if runtime_access:
                s.validate_runtime_ancestor(cursor)
            else:
                s.validate_directory(cursor)

    def test_private_shared_haven_parent_is_unchanged_during_install_retry_and_status(self):
        shared = self.base / 'haven'
        shared.mkdir(mode=0o700)
        marker = shared / 'unrelated-private-state'
        marker.write_bytes(b'preserve unrelated state')
        marker.chmod(0o600)
        before = shared.stat()
        first = self.execute()
        state = (s.ROOT / 'test/state.json').read_bytes()
        key = (s.ROOT / 'test/runtime-secrets/cell-vault-master-key').read_bytes()
        repeated = self.execute()
        status = self.execute(s.request_document({'schema': s.SCHEMA, 'operation': 'status', 'instance': 'test'}))
        self.assertEqual(first['container_id'], repeated['container_id'])
        self.assertEqual(first['container_id'], status['container_id'])
        self.assertEqual((s.ROOT / 'test/state.json').read_bytes(), state)
        self.assertEqual((s.ROOT / 'test/runtime-secrets/cell-vault-master-key').read_bytes(), key)
        self.assertEqual(self.system.native_calls, 1)
        after = shared.stat()
        self.assertEqual((before.st_ino, before.st_uid, before.st_gid, before.st_mode),
                         (after.st_ino, after.st_uid, after.st_gid, after.st_mode))
        self.assertEqual(marker.read_bytes(), b'preserve unrelated state')
        self.assertFalse((shared / 'sprout').exists())

    def test_legacy_instance_partial_state_and_symlink_are_never_adopted(self):
        s.LEGACY_ROOT.mkdir(parents=True, mode=0o755)
        legacy = s.LEGACY_ROOT / 'test'
        for kind in ('empty-directory', 'state-file', 'dangling-symlink'):
            with self.subTest(kind=kind):
                if kind == 'dangling-symlink':
                    legacy.symlink_to(self.base / 'missing')
                else:
                    legacy.mkdir()
                    if kind == 'state-file':
                        (legacy / 'state.json').write_bytes(b'private legacy state')
                for operation in ('preflight', 'install', 'status'):
                    with self.subTest(operation=operation):
                        value = (s.request_document({'schema': s.SCHEMA, 'operation': 'status', 'instance': 'test'})
                                 if operation == 'status' else request(operation=operation))
                        calls = list(self.system.calls)
                        self.rejected('legacy_instance_requires_explicit_recovery', lambda: self.execute(value))
                        self.assertEqual(self.system.calls, calls)
                        self.assertFalse(s.ROOT.exists())
                        self.assertEqual(self.system.native_calls, 0)
                if kind == 'dangling-symlink':
                    legacy.unlink()
                else:
                    if kind == 'state-file':
                        self.assertEqual((legacy / 'state.json').read_bytes(), b'private legacy state')
                        (legacy / 'state.json').unlink()
                    legacy.rmdir()

    def test_both_roots_fail_closed_without_replacing_current_identity(self):
        self.execute()
        before = self.files()
        s.LEGACY_ROOT.mkdir(parents=True, mode=0o755)
        (s.LEGACY_ROOT / 'test').mkdir()
        self.rejected('legacy_instance_requires_explicit_recovery', lambda: self.execute())
        self.assertEqual(self.files(), before)
        self.assertEqual(self.system.native_calls, 1)

    def test_runtime_ancestor_uses_actual_uid_and_primary_group_access_class(self):
        from types import SimpleNamespace
        for mode, uid, gid, allowed in [(0o755, 0, 0, True), (0o711, 0, 0, False),
                                       (0o700, 0, 0, False), (0o705, 0, 995, False),
                                       (0o750, 0, 995, True), (0o700, 995, 995, True)]:
            with self.subTest(mode=oct(mode), uid=uid, gid=gid):
                info = SimpleNamespace(st_mode=stat.S_IFDIR | mode, st_uid=uid, st_gid=gid)
                with patch.object(s, 'validate_directory', return_value=info), patch.object(s, 'RUNTIME_UID', 995), patch.object(s, 'RUNTIME_GID', 995):
                    if allowed:
                        s.validate_runtime_ancestor(Path('/fixed-parent'))
                    else:
                        self.rejected('runtime_ancestor_inaccessible', lambda: s.validate_runtime_ancestor(Path('/fixed-parent')))

    def test_existing_service_root_and_instance_modes_fail_before_pull(self):
        for suffix in ('', 'test'):
            with self.subTest(suffix=suffix):
                s.ROOT.mkdir(exist_ok=True)
                s.ROOT.chmod(0o755)
                target = s.ROOT / suffix if suffix else s.ROOT
                if suffix:
                    target.mkdir()
                target.chmod(0o700)
                calls = list(self.system.calls)
                self.rejected('unsafe_directory_mode', lambda: self.execute(request(operation='preflight')))
                self.assertEqual(self.system.calls, calls)
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o700)
                if suffix:
                    target.rmdir()
                s.ROOT.rmdir()

    def execute(self, value=None):
        return s.Coordinator(self.system).execute(value or request())

    def rejected(self, reason, call):
        with self.assertRaises(s.Rejected) as raised:
            call()
        self.assertEqual(raised.exception.reason, reason)

    def files(self):
        return {str(p.relative_to(self.base)): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}

    def test_explicit_https_port_and_root_status_contract(self):
        self.assertEqual(request()['public_origin'], 'https://scaffold.example:8443')
        self.assertEqual(s.request_document({'schema': s.SCHEMA, 'operation': 'status', 'instance': 'test'})['root'], str(s.ROOT))

    def test_input_rejects_shell_paths_unknown_keys_and_noncanonical_images(self):
        cases = [({'instance': '../escape'}, 'invalid_instance'), ({'root': '/tmp/elsewhere'}, 'unsupported_root'),
                 ({'command': 'id'}, 'unknown_request_field'), ({'image': 'team/image@sha256:' + '1' * 64}, 'invalid_image'),
                 ({'image': 'docker.io/image@sha256:' + '1' * 64}, 'invalid_image'),
                 ({'image': IMAGE + ';id'}, 'invalid_image'), ({'profile': 'shell'}, 'unsupported_profile'),
                 ({'listen_port': True}, 'invalid_port'), ({'listen_port': 80}, 'invalid_port'),
                 ({'purposes': ['purpose://x\nEVIL=1']}, 'invalid_purposes')]
        for changes, reason in cases:
            with self.subTest(changes=changes):
                self.rejected(reason, lambda: request(**changes))

    def test_origin_rejects_insecure_ip_credentials_paths_and_invalid_ports(self):
        for value in ('http://example.com', 'https://127.0.0.1', 'https://[::1]', 'https://user@example.com',
                      'https://example.com/a', 'https://example.com?x=y', 'https://example.com#x',
                      'https://example.com/', 'https://example.com-', 'https://localhost', 'https://example.com:0', 'https://example.com:443', 'https://example.com:65536', 'https://EXAMPLE.com'):
            with self.subTest(value=value), self.assertRaises(s.Rejected):
                request(public_origin=value)

    def test_duplicate_json_keys_and_size_fail_closed(self):
        self.rejected('duplicate_json_key', lambda: s.decode(b'{"operation":"status","operation":"install"}'))
        self.rejected('document_too_large', lambda: s.decode(b' ' * (s.MAX_JSON + 1)))

    def test_preflight_before_pull_has_no_writes_or_image_inspection(self):
        result = self.execute(request(operation='preflight'))
        self.assertEqual(result['status'], 'preflight-ready')
        self.assertFalse(result['writes'])
        self.assertEqual(self.files(), {})
        self.assertFalse(any(call[:2] == ('image', 'inspect') for call in self.system.calls))

    def test_busy_port_fails_before_any_write(self):
        self.system.busy_port = True
        self.rejected('listen_port_busy', lambda: self.execute(request(operation='preflight')))
        self.assertFalse(s.ROOT.exists())

    def test_unsafe_base_symlink_or_world_writable_parent_rejected(self):
        parent = self.base / 'haven'
        parent.symlink_to(self.base, target_is_directory=True)
        self.rejected('unsafe_directory', lambda: self.execute(request(operation='preflight')))
        parent.unlink(); parent.mkdir(); parent.chmod(0o777)
        self.rejected('unsafe_directory', lambda: self.execute(request(operation='preflight')))

    def test_file_symlinks_hardlinks_permissions_and_conflicts_rejected(self):
        target = self.base / 'target'
        s.atomic_write(target, b'sensitive')
        link = self.base / 'symlink'; link.symlink_to(target)
        with self.assertRaises(OSError):
            s.read_file(link)
        hard = self.base / 'hard'; os.link(target, hard)
        self.rejected('unsafe_file', lambda: s.read_file(target)); hard.unlink()
        target.chmod(0o644)
        self.rejected('unsafe_file', lambda: s.read_file(target)); target.chmod(0o600)
        self.rejected('existing_file_conflict', lambda: s.atomic_write(target, b'replacement'))
        self.assertEqual(target.read_bytes(), b'sensitive')

    def test_digest_architecture_and_build_mismatch_before_install_writes(self):
        for key, value, reason in [('RepoDigests', ['registry.other/x@sha256:' + '1' * 64], 'image_digest_or_platform_mismatch'),
                                   ('Architecture', 'arm64', 'image_digest_or_platform_mismatch')]:
            with self.subTest(key=key):
                original = self.system.image[key]; self.system.image[key] = value
                self.rejected(reason, self.execute); self.system.image[key] = original
                self.assertFalse(s.ROOT.exists())
        self.system.image['Config']['Env'].append('CELL_VAULT_MASTER_KEY_B64=forbidden')
        self.rejected('image_inline_vault_key_forbidden', self.execute)
        self.assertFalse(s.ROOT.exists())

    def test_full_install_uses_offline_owner_then_canonical_then_restart(self):
        with patch.dict(os.environ, {'CELL_VAULT_MASTER_KEY_B64': 'poison', 'SPROUT_TEST_SECRET': 'secret'}):
            result = self.execute()
        self.assertEqual(result['status'], 'ready')
        self.assertFalse(result['public_tls_verified'])
        self.assertTrue(result['checks']['restart_verified'])
        self.assertEqual(self.system.native_calls, 1)
        service = self.system.container('sprout-test')
        self.assertTrue(service['State']['Running'])
        self.assertEqual(service['HostConfig']['RestartPolicy']['Name'], 'unless-stopped')
        canonical = self.system.container('sprout-test-provision')
        self.assertFalse(canonical['State']['Running'])
        self.assertEqual(canonical['HostConfig']['NetworkMode'], 'none')
        self.assertFalse(canonical['HostConfig']['PortBindings'])
        env = dict(x.split('=', 1) for x in service['Config']['Env'])
        self.assertEqual(env['RP_ID'], 'scaffold.example')
        self.assertEqual(env['RP_ORIGIN'], 'https://scaffold.example:8443')
        self.assertEqual(env['PUBLIC_BASE_URL'], 'https://scaffold.example:8443')
        self.assertEqual(env['CELL_SCAFFOLD_PUBLIC_BASE_URL'], 'https://scaffold.example:8443')
        self.assertEqual(env['SPROUT_SCAFFOLD_DOMAIN'], 'scaffold.example')
        self.assertEqual(env['SPROUT_BRIDGE_ALLOWED_PURPOSES'], 'purpose://haven/communicate')
        self.assertTrue(result['checks']['selected_purpose_discovery'])
        self.assertEqual(env['CELL_SCAFFOLD_OWNER_SIGNING_KEY_FINGERPRINT'], 'o' * 43)
        self.assertEqual(env['CELL_SCAFFOLD_EAGER_BOOTSTRAP_MODE'], 'require-existing')
        key = s.ROOT / 'test/runtime-secrets/cell-vault-master-key'
        self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o400)
        self.assertEqual(len(key.read_bytes()), 32)
        self.assertNotIn('JWT_AUTH_SECRET', json.dumps(result))
        self.assertEqual(json.loads((s.ROOT / 'test/receipt.json').read_bytes()), result)

    def test_selected_purposes_are_sorted_exact_and_queried_before_and_after_restart(self):
        purposes = ['purpose://operate-local-haven-agent', 'purpose://haven/communicate']
        result = self.execute(request(purposes=purposes))
        self.assertTrue(result['checks']['selected_purpose_discovery'])
        self.assertNotIn('signature_verified', result['checks'])
        env = dict(value.split('=', 1) for value in self.system.container('sprout-test')['Config']['Env'])
        self.assertEqual(env['SPROUT_BRIDGE_ALLOWED_PURPOSES'], ','.join(sorted(purposes)))
        self.assertNotIn('bootstrap.join_scaffold', env['SPROUT_BRIDGE_ALLOWED_PURPOSES'])
        self.assertEqual([query['purpose'] for query in self.system.bridge_queries], sorted(purposes) * 2)
        self.assertTrue(all(query['scaffold_domain'] == 'scaffold.example' and query['interests']
                            for query in self.system.bridge_queries))

    def test_discovery_403_prevents_ready_and_stops_provisional_service(self):
        self.system.bridge_fault = 'forbidden'
        self.rejected('local_functional_acceptance_failed', self.execute)
        service = self.system.container('sprout-test')
        self.assertFalse(service['State']['Running'])
        self.assertEqual(service['HostConfig']['RestartPolicy']['Name'], 'no')
        self.assertFalse((s.ROOT / 'test/receipt.json').exists())

    def test_discovery_wrong_domain_purpose_origin_port_scheme_path_or_empty_fails(self):
        self.execute(request(purposes=['purpose://operate-local-haven-agent']))
        coordinator = s.Coordinator(self.system)
        coordinator.preflight(request(purposes=['purpose://operate-local-haven-agent']))
        for fault in ('domain', 'purpose', 'origin', 'port', 'insecure', 'path', 'empty'):
            with self.subTest(fault=fault):
                self.system.bridge_fault = fault
                self.rejected('local_functional_acceptance_failed', lambda: coordinator.health(attempts=1))

    def test_http_transport_posts_bounded_json_without_proxy_origin_overrides(self):
        query = {'scaffold_domain': 'scaffold.example', 'purpose': 'purpose://operate-local-haven-agent',
                 'interests': ['haven.core.bridge']}
        with patch.object(s.http.client, 'HTTPConnection') as connection_type:
            connection = connection_type.return_value
            response = connection.getresponse.return_value
            response.status = 200
            response.getheaders.return_value = [('Content-Type', 'application/json')]
            response.read.return_value = b'{"bridges":[]}'
            self.assertEqual(s.System().http(9089, '/v1/bridges/query', json_body=query)[0], 200)
            connection_type.assert_called_once_with('127.0.0.1', 9089, timeout=5)
            connection.request.assert_called_once_with('POST', '/v1/bridges/query', body=s.canonical_json(query),
                headers={'Content-Type': 'application/json', 'Accept': 'application/json'})
            response.read.assert_called_once_with(s.MAX_JSON + 1)
            connection.close.assert_called_once()

    def test_idempotent_retry_and_minimal_status_do_not_write_or_reenroll(self):
        self.execute(); before = self.files(); calls = len(self.system.calls)
        self.execute()
        result = self.execute(s.request_document({'schema': s.SCHEMA, 'operation': 'status', 'instance': 'test'}))
        self.assertEqual(result['status'], 'ready')
        self.assertEqual(self.files(), before)
        self.assertEqual(self.system.native_calls, 1)
        self.assertFalse(any(call[0] in ('start', 'restart', 'update', 'create') for call in self.system.calls[calls:]))

    def test_stopped_ready_service_is_restarted_without_new_owner_or_keys(self):
        self.execute()
        key = (s.ROOT / 'test/runtime-secrets/cell-vault-master-key').read_bytes()
        journal = (s.ROOT / 'test/ceremony/enrollment.json').read_bytes()
        identifier = self.system.container('sprout-test')['Id']
        self.system.docker('stop', '--time', '30', identifier)
        self.assertEqual(self.execute()['status'], 'ready')
        self.assertTrue(self.system.container(identifier)['State']['Running'])
        self.assertEqual(self.system.native_calls, 1)
        self.assertEqual((s.ROOT / 'test/runtime-secrets/cell-vault-master-key').read_bytes(), key)
        self.assertEqual((s.ROOT / 'test/ceremony/enrollment.json').read_bytes(), journal)

    def test_status_rejects_disabled_restart_policy_and_install_repairs_owned_service(self):
        self.execute()
        identifier = self.system.container('sprout-test')['Id']
        self.system.docker('update', '--restart', 'no', identifier)
        self.rejected('container_restart_policy_conflict', lambda: self.execute(s.request_document(
            {'schema': s.SCHEMA, 'operation': 'status', 'instance': 'test'})))
        self.assertEqual(self.execute()['status'], 'ready')
        self.assertEqual(self.system.container(identifier)['HostConfig']['RestartPolicy']['Name'], 'unless-stopped')
        self.system.containers[identifier]['HostConfig']['RestartPolicy']['Name'] = 'always'
        self.rejected('container_restart_policy_conflict', self.execute)

    def test_retry_canonical_partial_failure_reuses_same_manifest_and_owner(self):
        self.system.canonical_exit = 1
        self.rejected('canonical_provisioning_failed_preserve_generation', self.execute)
        manifest = (s.ROOT / 'test/ceremony/manifest.json').read_bytes()
        self.system.canonical_exit = 0
        self.assertEqual(self.execute()['status'], 'ready')
        self.assertEqual(self.system.native_calls, 1)
        self.assertEqual((s.ROOT / 'test/ceremony/manifest.json').read_bytes(), manifest)

    def test_unknown_native_write_keeps_generation_key_and_recovers(self):
        self.system.native_unknown = True
        self.rejected('command_interrupted', self.execute)
        key = (s.ROOT / 'test/runtime-secrets/cell-vault-master-key').read_bytes()
        journal = (s.ROOT / 'test/ceremony/enrollment.json').read_bytes()
        self.assertFalse(any(value.get('State', {}).get('Running') for value in self.system.containers.values()))
        result = self.execute()
        self.assertEqual(result['status'], 'ready')
        self.assertEqual((s.ROOT / 'test/runtime-secrets/cell-vault-master-key').read_bytes(), key)
        self.assertEqual((s.ROOT / 'test/ceremony/enrollment.json').read_bytes(), journal)
        self.assertEqual(self.system.native_calls, 2)

    def test_missing_key_after_checkpoint_never_regenerates(self):
        self.system.native_fail = True
        self.rejected('first_owner_enrollment_failed_preserve_generation', self.execute)
        key = s.ROOT / 'test/runtime-secrets/cell-vault-master-key'; key.unlink()
        with self.assertRaises(FileNotFoundError):
            self.execute()
        self.assertFalse(key.exists())
        self.assertEqual(self.system.native_calls, 1)

    def test_changed_extracted_binary_not_executed_on_retry(self):
        self.system.native_fail = True
        self.rejected('first_owner_enrollment_failed_preserve_generation', self.execute)
        binary = s.ROOT / 'test/native/CellScaffoldIdentityBootstrap'
        binary.write_bytes(b'\x7fELFchanged')
        self.rejected('bootstrap_binary_changed', self.execute)
        self.assertEqual(self.system.native_calls, 1)

    def test_canonical_provision_failure_preserves_keys_without_starting_listener(self):
        self.system.canonical_exit = 1
        self.rejected('canonical_provisioning_failed_preserve_generation', self.execute)
        self.assertIsNone(self.system.container('sprout-test'))
        self.assertTrue((s.ROOT / 'test/runtime-secrets/cell-vault-master-key').exists())
        self.assertFalse((s.ROOT / 'test/receipt.json').exists())

    def test_canonical_timeout_stops_only_its_generation(self):
        self.system.canonical_interrupted = True
        self.rejected('command_interrupted', self.execute)
        canonical = self.system.container('sprout-test-provision')
        self.assertFalse(canonical['State']['Running'])
        self.assertEqual(canonical['State']['ExitCode'], 143)
        self.assertIsNone(self.system.container('sprout-test'))
        self.system.canonical_interrupted = False
        self.assertEqual(self.execute()['status'], 'ready')
        self.assertEqual(self.system.container('sprout-test-provision')['Id'], canonical['Id'])
        self.assertEqual(self.system.native_calls, 1)
        starts = [call for call in self.system.calls if call == ('start', canonical['Id'])]
        self.assertEqual(len(starts), 2)

    def test_failed_postrestart_acceptance_stops_service_preserves_evidence(self):
        self.system.bad_after_restart = True
        self.rejected('local_functional_acceptance_failed', self.execute)
        service = self.system.container('sprout-test')
        self.assertFalse(service['State']['Running'])
        self.assertEqual(service['HostConfig']['RestartPolicy']['Name'], 'no')
        self.assertFalse((s.ROOT / 'test/receipt.json').exists())
        self.assertTrue((s.ROOT / 'test/ceremony/manifest.json').exists())
        self.system.bad_after_restart = False
        self.assertEqual(self.execute()['status'], 'ready')
        self.assertEqual(self.system.native_calls, 1)

    def test_retry_validation_failure_stops_provisional_container_left_by_killed_coordinator(self):
        self.system.bad_after_restart = True
        self.rejected('local_functional_acceptance_failed', self.execute)
        identifier = self.system.container('sprout-test')['Id']
        self.system.docker('start', identifier)  # Model a previous killed coordinator.
        (s.ROOT / 'test/native/CellScaffoldIdentityBootstrap').write_bytes(b'\x7fELFchanged')
        self.rejected('bootstrap_binary_changed', self.execute)
        self.assertFalse(self.system.container(identifier)['State']['Running'])
        self.assertEqual(self.system.container(identifier)['HostConfig']['RestartPolicy']['Name'], 'no')

    def test_changed_request_rejected_without_mutation(self):
        self.execute(); before = self.files()
        self.rejected('instance_configuration_conflict', lambda: self.execute(request(listen_port=9090)))
        self.assertEqual(self.files(), before)

    def test_unrelated_container_is_never_adopted_or_stopped(self):
        self.system.containers['f' * 64] = {'Id': 'f' * 64, 'Name': 'sprout-test', 'State': {'Running': True}}
        self.rejected('container_name_in_use', self.execute)
        self.assertFalse(s.ROOT.exists())
        self.assertTrue(self.system.containers['f' * 64]['State']['Running'])

    def test_status_detects_changed_port_mount_env_image_and_privileges(self):
        self.execute()
        identifier = self.system.container('sprout-test')['Id']
        original = copy.deepcopy(self.system.containers[identifier])
        changes = [lambda x: x['HostConfig'].update(Privileged=True),
                   lambda x: x['HostConfig'].update(Binds=['/:/host:rw']),
                   lambda x: x['HostConfig'].update(PortBindings={}),
                   lambda x: x['HostConfig'].update(NetworkMode='host'),
                   lambda x: x['Config']['Env'].append('CELL_VAULT_MASTER_KEY_B64=bad'),
                   lambda x: x.update(Image='sha256:' + 'f' * 64)]
        for mutate in changes:
            self.system.containers[identifier] = copy.deepcopy(original)
            mutate(self.system.containers[identifier])
            with self.assertRaises(s.Rejected):
                self.execute(s.request_document({'schema': s.SCHEMA, 'operation': 'status', 'instance': 'test'}))
        self.system.containers[identifier] = original

    def test_manifest_receipt_digest_owner_registry_build_must_match(self):
        self.execute()
        coordinator = s.Coordinator(self.system); coordinator.preflight(request())
        receipt = copy.deepcopy(coordinator.state['enrollment'])
        raw = (s.ROOT / 'test/ceremony/manifest.json').read_bytes()
        self.rejected('invalid_enrollment_receipt', lambda: coordinator.validate_enrollment(receipt, raw + b' '))
        for mutate, reason in [(lambda d: d['signature'].update(signerIdentityUUID='wrong'), 'manifest_owner_mismatch'),
                               (lambda d: d['payload'].update(registryDigest='sha256:' + 'x' * 43), 'manifest_profile_mismatch'),
                               (lambda d: d['payload']['build'].update(appRevision='f' * 40), 'manifest_build_mismatch'),
                               (lambda d: d['payload']['bindings'][0].update(signingKeyFingerprintDigest='x' * 43), 'manifest_owner_mismatch')]:
            document = json.loads(raw); mutate(document); changed = s.canonical_json(document)
            updated = dict(receipt, manifestSHA256=s.digest(changed))
            self.rejected(reason, lambda: coordinator.validate_enrollment(updated, changed))

    def test_global_writer_lock_blocks_without_generating_new_instance(self):
        self.execute()
        lock = os.open(s.ROOT / '.installation.lock', os.O_RDWR)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.rejected('installation_busy', lambda: self.execute(request(instance='other', listen_port=9090)))
            self.assertFalse((s.ROOT / 'other').exists())
        finally:
            os.close(lock)

    def test_failed_cli_input_produces_safe_json_and_no_traceback(self):
        process = subprocess.run([sys.executable, '-I', str(SCRIPT)], input=b'{"evil":"SECRET_SENTINEL"}', capture_output=True)
        self.assertEqual(process.returncode, 2)
        result = json.loads(process.stdout)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], 'invalid_request')
        self.assertNotIn(b'SECRET_SENTINEL', process.stdout + process.stderr)
        self.assertNotIn(b'Traceback', process.stdout + process.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
