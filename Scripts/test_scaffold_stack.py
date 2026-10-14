#!/usr/bin/env python3
"""Fixed stack coordinator tests: real private files/child process, modeled Docker.
No test claims a real Admin vault, signature verification or live TLS.
"""
import copy
import hashlib
import os
from pathlib import Path
import stat
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_scaffold_service as baseline
s = baseline.s
ADMIN = 'registry.example/team/admin@sha256:' + '3' * 64
NODE = 'registry.example/team/node@sha256:' + '4' * 64


def request(**changes):
    value = dict(baseline.request(), profile=s.STACK_PROFILE, admin_image=ADMIN, node_image=NODE,
        admin_public_origin='https://admin.example:8443', admin_listen_port=9098,
        catalog_publisher='p' * 43, catalog_sha256_b64url='c' * 43, catalog_id='catalog-v1', catalog_domain='catalog.example',
        resource_limits=s.RESOURCE_LIMITS)
    value.update(changes)
    return s.request_document(value)


class StackDockerModel(baseline.DockerModel):
    def __init__(self):
        super().__init__()
        self.images = {baseline.IMAGE: self.image}
        for ref, character in [(ADMIN, '5'), (NODE, '6')]:
            value = copy.deepcopy(self.image)
            value.update(Id='sha256:' + character * 64, RepoDigests=[ref])
            self.images[ref] = value
        self.admin_exit = 0
        self.audit_fault = None
        self.fail_after = None
        self.did_fail = False
        self.enrollment_count = 0
        self.admin_unknown = False
        self.verify_count = 0
        self.run_clock = 0
        self.late_log = False

    def docker(self, *args, **kwargs):
        if args[:2] == ('image', 'inspect'):
            self.calls.append(args)
            return s.canonical_json([self.images[args[2]]])
        if args[0] == 'rename':
            self.calls.append(args)
            self.containers[args[1]]['Name'] = args[2]
            if self.fail_after == 'rename' and not self.did_fail:
                self.did_fail = True
                raise s.Rejected('injected_unknown_rename')
            return b''
        if args[0] == 'create' and '--name' in args:
            def values(flag): return [args[i + 1] for i, item in enumerate(args) if item == flag]
            image_index = next(i for i, item in enumerate(args) if item in self.images)
            image = self.images[args[image_index]]
            if args[image_index] == baseline.IMAGE: return super().docker(*args, **kwargs)
            self.calls.append(args)
            self.sequence += 1
            identifier = format(self.sequence, '064x')
            publish = values('--publish')
            ports = {publish[0].split(':')[2] + '/tcp': [{'HostIp': '127.0.0.1', 'HostPort': publish[0].split(':')[1]}]} if publish else {}
            memory = args[args.index('--memory') + 1]
            self.containers[identifier] = {'Id': identifier, 'Name': values('--name')[0], 'Image': image['Id'],
                'Config': {'Image': args[image_index], 'User': values('--user')[0],
                    'Labels': dict(x.split('=', 1) for x in values('--label')),
                    'Env': image['Config']['Env'] + Path(values('--env-file')[0]).read_text().splitlines(),
                    'Entrypoint': values('--entrypoint'), 'Cmd': list(args[image_index + 1:])},
                'HostConfig': {'Privileged': False, 'ReadonlyRootfs': True, 'NetworkMode': values('--network')[0],
                    'CapDrop': ['ALL'], 'SecurityOpt': ['no-new-privileges:true'], 'Binds': values('--volume'),
                    'PortBindings': ports, 'RestartPolicy': {'Name': 'no'},
                    'Tmpfs': {'/tmp': 'rw,noexec,nosuid,size=16777216,mode=1777'},
                    'Memory': 1073741824 if memory == '1g' else 268435456,
                    'NanoCpus': int(float(values('--cpus')[0]) * 1e9), 'PidsLimit': int(values('--pids-limit')[0])},
                'State': {'Running': False, 'Status': 'created', 'ExitCode': 0}}
            return identifier.encode()
        item = self.containers.get(args[-1])
        role = item and item.get('Config', {}).get('Labels', {}).get('org.haven.sprout.phase')
        if role in ('admin-enroll', 'admin-verify') and args[0] == 'wait':
            self.calls.append(args)
            item['State'].update(Running=False, Status='exited', ExitCode=self.admin_exit,
                FinishedAt=item['State']['StartedAt'].replace('.000000000Z', '.900000000Z'))
            if self.admin_exit == 0:
                if role == 'admin-enroll': self.enrollment_count += 1
                else: self.verify_count += 1
                env = dict(x.split('=', 1) for x in item['Config']['Env'])
                base = Path(next(x.split(':')[0] for x in item['HostConfig']['Binds'] if ':/state:' in x))
                journal = b'private-model-admin-vault-proof'
                if role == 'admin-enroll':
                    s.atomic_write(base / '.admin-owner-enrollment-v1.json', journal, s.ADMIN_UID, s.ADMIN_GID)
                elif not (base / '.admin-owner-enrollment-v1.json').is_file():
                    return b'1'
                item['receipt'] = {'schemaVersion': 'haven.admin.first-owner-receipt.v1', 'status': 'verified',
                    'operation': 'verify-owner' if role == 'admin-verify' else 'enroll-first-owner', 'enrollmentID': env['ADMIN_SCAFFOLD_ENROLLMENT_ID'],
                    'appRevision': baseline.BUILD['app_revision'], 'journalSHA256': hashlib.sha256(journal).hexdigest(),
                    'owner': {'uuid': env['ADMIN_SCAFFOLD_OWNER_UUID'], 'context': env['ADMIN_SCAFFOLD_OWNER_CONTEXT'],
                              'signingKeyFingerprintDigest': 'A' * 43}}
            output = item.get('receipt') if self.admin_exit == 0 else {'schemaVersion': 'haven.admin.first-owner-error.v1', 'status': 'failed', 'reason': 'transient_verification_failure'}
            logged_at = (item['State']['FinishedAt'].replace('.900000000Z', '.950000000Z')
                         if self.late_log else item['State']['StartedAt'])
            item.setdefault('run_logs', []).append((logged_at, s.canonical_json(output)))
            if role == 'admin-enroll' and self.admin_unknown:
                self.admin_unknown = False
                raise s.Rejected('injected_unknown_admin_receipt')
            return str(self.admin_exit).encode()
        if role in ('admin-enroll', 'admin-verify') and args[0] == 'logs':
            self.calls.append(args)
            since = args[args.index('--since') + 1] if '--since' in args else ''
            until = args[args.index('--until') + 1] if '--until' in args else 'z'
            return b'\n'.join(data for started, data in item['run_logs'] if since <= started <= until)
        result = super().docker(*args, **kwargs)
        if role in ('admin-enroll', 'admin-verify') and args[0] == 'start':
            self.run_clock += 1
            item['State']['StartedAt'] = '2026-10-14T10:00:%02d.000000000Z' % self.run_clock
        if role == 'node' and args[0] in ('start', 'restart'):
            base = Path(next(x.split(':')[0] for x in item['HostConfig']['Binds'] if ':/state:' in x))
            counter = base / 'sequence'
            counter.write_bytes(str(int(counter.read_bytes()) + 1).encode() + b'\n')
        return result

    def run(self, arguments, **kwargs):
        if arguments[:2] == ['/usr/bin/openssl', 'genpkey']:
            return 0, bytes.fromhex('302e020100300506032b657004220420') + b'k' * 32, b''
        if arguments[:2] == ['/usr/bin/openssl', 'pkey']:
            return 0, bytes.fromhex('302a300506032b6570032100') + b'p' * 32, b''
        return super().run(arguments, **kwargs)

    def admin_http(self, port, path, origin, token=None):
        self.calls.append(('admin-http', path))
        owner = next(value['receipt']['owner'] for value in self.containers.values() if 'receipt' in value)
        if path == '/health/startup': return 200, {}, b'{"status":"started"}'
        if path == '/health/restore-audit':
            assert token and port == 9098 and origin == 'https://admin.example:8443'
            value = {'schemaVersion': 'haven.admin.restore-audit.v1', 'ownerUUID': owner['uuid'],
                'ownerSigningKeyFingerprint': owner['signingKeyFingerprintDigest'], 'activeTrustedAgentKeyCount': 1,
                'latestSnapshotAcceptedAt': time.time(), 'persistenceStatus': 'healthy'}
            if self.audit_fault == 'owner': value['ownerUUID'] = 'other'
            if self.audit_fault == 'stale': value['latestSnapshotAcceptedAt'] -= 301
        else:
            value = {'status': 'ready', 'trustedAgentKeyPolicy': 'required', 'freshSnapshotPolicy': 'required',
                'activeTrustedAgentKeyCount': 1, 'freshRecordCount': 1, 'publicOriginReady': True, 'bridgeReady': True}
            if self.audit_fault == 'optional': value['freshSnapshotPolicy'] = 'optional'
        return 200, {}, s.canonical_json(value)

    def https(self, origin, path):
        if self.audit_fault == 'tls': raise OSError('certificate verification failed')
        if path == '/health/build': return 200, {}, s.canonical_json(dict(baseline.BUILD, environment='production'))
        return self.admin_http(9098, path, origin)


class StackTests(unittest.TestCase):
    setUp = baseline.ServiceTests.setUp
    tearDown = baseline.ServiceTests.tearDown
    safe_test_preflight = baseline.ServiceTests.safe_test_preflight
    safe_test_ancestors = baseline.ServiceTests.safe_test_ancestors

    def setUp(self):
        baseline.ServiceTests.setUp(self)
        for name, value in [('ADMIN_UID', self.uid), ('ADMIN_GID', self.gid), ('NODE_UID', self.uid), ('NODE_GID', self.gid)]:
            item = patch.object(s, name, value)
            item.start()
            self.patches.append(item)
        self.system = StackDockerModel()

    def execute(self, value=None): return s.StackCoordinator(self.system).execute(value or request())
    def state(self): return s.decode(s.read_file(s.ROOT / 'test' / 'state.json'))
    def immutable(self):
        base = s.ROOT / 'test'
        return {str(p.relative_to(base)): p.read_bytes() for p in base.rglob('*')
                if p.is_file() and (p.parent.name in ('runtime-secrets', 'ceremony', 'admin-secrets', 'node-secrets') or p.name == 'auth.json')}

    def legacy_failure(self):
        self.system.canonical_exit = 132
        with self.assertRaisesRegex(s.Rejected, 'canonical_provisioning_failed'):
            s.Coordinator(self.system).execute(baseline.request())
        self.system.canonical_exit = 0
        self.assertEqual(self.state()['phase'], 'enrolled')
        return self.state(), self.immutable()

    def test_stack_preflight_is_read_only_and_refuses_incomplete_roles(self):
        self.assertEqual(self.execute(request(operation='preflight'))['writes'], False)
        self.assertFalse(s.ROOT.exists())
        self.assertFalse(any(call[:2] == ('image', 'inspect') for call in self.system.calls))
        for field in s.STACK_FIELDS:
            value = request(); del value[field]
            with self.assertRaises(s.Rejected): s.request_document(value)
        for changes in [dict(admin_image=baseline.IMAGE), dict(admin_listen_port=9089),
                        dict(admin_public_origin='http://admin.example'), dict(resource_limits={'admin': 'unlimited'})]:
            with self.assertRaises(s.Rejected): request(**changes)

    def test_complete_stack_preserves_isolation_and_source_bound_environments(self):
        receipt = self.execute()
        self.assertEqual(receipt['status'], 'ready')
        self.assertEqual(receipt['admin']['image'], ADMIN)
        self.assertEqual(receipt['node']['image'], NODE)
        self.assertEqual(self.system.native_calls, 1)
        for item in self.system.containers.values():
            role = item.get('Config', {}).get('Labels', {}).get('org.haven.sprout.phase')
            mounts = item.get('HostConfig', {}).get('Binds', [])
            self.assertFalse(any('docker.sock' in mount for mount in mounts))
            if role in ('canonical', 'service'):
                env = dict(x.split('=', 1) for x in item['Config']['Env'])
                self.assertEqual(env['DEVICE_CALLBACK_PUBLIC_ORIGIN'], request()['public_origin'])
                self.assertEqual(env['ADMIN_CONTROL_PLANE_MODE'], 'remote_admin_scaffold')
                self.assertFalse(any('admin-data' in mount or 'node-secrets' in mount for mount in mounts))
            if role == 'admin': self.assertFalse(any('node-secrets' in mount for mount in mounts))

    def test_repeat_status_and_stopped_dependency_resume_keep_all_keys(self):
        first = self.execute(); before = self.immutable()
        self.assertEqual(self.execute()['generation'], first['generation'])
        self.assertEqual(self.execute(s.request_document({'schema': s.SCHEMA, 'operation': 'status', 'instance': 'test'}))['status'], 'ready')
        node = self.system.container('sprout-test-node')
        self.system.docker('stop', node['Id'])
        self.assertGreater(self.execute()['admin']['observed_sequence'], first['admin']['observed_sequence'])
        self.assertEqual(before, self.immutable())
        self.assertEqual(self.system.native_calls, 1)
        self.assertEqual(self.system.enrollment_count, 1)

    def test_exact_enrolled_upgrade_archives_old_container_and_preserves_web_identity(self):
        old, files = self.legacy_failure()
        old_container = self.system.container('sprout-test-provision')['Id']
        result = self.execute()
        after = self.state()
        for key in ('generation', 'owner_uuid', 'enrollment_id', 'issued_at', 'build', 'image_id', 'enrollment'):
            self.assertEqual(after[key], old[key], key)
        for path, data in files.items(): self.assertEqual((s.ROOT / 'test' / path).read_bytes(), data, path)
        self.assertEqual(result['generation'], old['generation'])
        self.assertIn('-legacy-', self.system.container(old_container)['Name'])
        journal = s.decode(s.read_file(s.ROOT / 'test' / 'stack-upgrade.json'))
        self.assertEqual(journal['old_state'], old)
        self.assertEqual(journal['historical_publisher_continuity'], 'not-recorded-by-legacy-client')
        self.assertEqual(self.system.native_calls, 1)

    def test_unknown_rename_retry_preserves_exact_generation_and_key(self):
        old, files = self.legacy_failure()
        self.system.fail_after = 'rename'
        with self.assertRaisesRegex(s.Rejected, 'injected_unknown_rename'): self.execute()
        self.assertEqual(self.state(), old)
        self.assertTrue((s.ROOT / 'test' / 'stack-upgrade.json').is_file())
        self.assertEqual(self.execute()['generation'], old['generation'])
        for path, data in files.items(): self.assertEqual((s.ROOT / 'test' / path).read_bytes(), data)

    def test_upgrade_rejects_changed_web_bindings_and_non_enrolled_phases(self):
        old, _ = self.legacy_failure()
        for changes in [dict(image='registry.example/team/new@sha256:' + '7' * 64), dict(public_origin='https://new.example'),
                        dict(purposes=['purpose://other']), dict(listen_port=9099)]:
            with self.assertRaisesRegex(s.Rejected, 'upgrade_web_binding_conflict'): self.execute(request(**changes))
            self.assertEqual(self.state(), old)
        for phase in ('ready', 'canonical-ready', 'secrets-ready', 'unknown'):
            changed = dict(old, phase=phase)
            s.atomic_write(s.ROOT / 'test' / 'state.json', s.canonical_json(changed), replace=True)
            with self.assertRaisesRegex(s.Rejected, 'upgrade_requires_enrolled'): self.execute()
        self.assertFalse((s.ROOT / 'test' / 'stack-upgrade.json').exists())

    def test_dependency_failure_stops_only_owned_members_and_keeps_enrollments(self):
        self.system.audit_fault = 'stale'
        with self.assertRaisesRegex(s.Rejected, 'admin_functional'): self.execute()
        state = self.state(); before = self.immutable()
        self.assertEqual(state['phase'], 'enrolled')
        self.assertIn('enrollment', state['stack'])
        self.assertIsNone(self.system.container('sprout-test'))
        for role in ('admin', 'node'): self.assertFalse(self.system.container('sprout-test-' + role)['State']['Running'])
        self.system.audit_fault = None
        self.assertEqual(self.execute()['generation'], state['generation'])
        self.assertEqual(before, self.immutable())

    def test_counter_missing_corrupt_or_key_changed_never_rotates_or_reenrolls(self):
        self.execute()
        counter = s.ROOT / 'test' / 'node-state' / 'sequence'
        original = counter.read_bytes(); before = self.immutable()
        for value in (b'', b'bad\n', b'00\n', b'-1\n', b'900000000000000000\n'):
            counter.write_bytes(value)
            with self.assertRaises(s.Rejected): self.execute()
            self.assertEqual(counter.read_bytes(), value)
            self.assertEqual(before, self.immutable())
        counter.unlink()
        with self.assertRaises(FileNotFoundError): self.execute()
        self.assertFalse(counter.exists())
        counter.write_bytes(original); counter.chmod(0o600)
        seed = s.ROOT / 'test' / 'node-secrets' / 'signing-key'
        seed.chmod(0o600); seed.write_bytes(b'Z' * 43); seed.chmod(0o400)
        with self.assertRaisesRegex(s.Rejected, 'invalid_node_signing_key'): self.execute()
        self.assertEqual(self.system.native_calls, 1)

    def test_unknown_admin_receipt_recovers_only_by_read_only_verify(self):
        self.system.admin_unknown = True
        with self.assertRaisesRegex(s.Rejected, 'injected_unknown_admin_receipt'): self.execute()
        before = self.immutable()
        state = self.state()
        self.assertTrue(state['stack']['ceremony_started'])
        self.assertNotIn('enrollment', state['stack'])
        result = self.execute()
        self.assertEqual(result['status'], 'ready')
        self.assertEqual(self.system.enrollment_count, 1)
        self.assertEqual(self.system.verify_count, 1)
        self.assertEqual(self.state()['stack']['enrollment']['operation'], 'verify-owner')
        self.assertEqual(before, self.immutable())

    def test_failed_admin_enrollment_never_automatically_creates_again(self):
        self.system.admin_exit = 1
        with self.assertRaisesRegex(s.Rejected, 'admin_enrollment_unknown'): self.execute()
        self.system.admin_exit = 0
        with self.assertRaisesRegex(s.Rejected, 'admin_enrollment_unknown'): self.execute()
        self.assertEqual(self.system.enrollment_count, 0)
        self.assertNotIn('enrollment', self.state()['stack'])

    def test_dependency_resource_privilege_environment_and_mount_drift_are_refused(self):
        self.execute()
        item = self.system.containers[self.system.container('sprout-test-node')['Id']]
        original = copy.deepcopy(item)
        mutations = [lambda x: x['HostConfig'].update(CapAdd=['SYS_ADMIN']),
            lambda x: x['HostConfig'].update(Memory=0),
            lambda x: x['HostConfig']['Binds'].append('/var/run/docker.sock:/docker.sock:rw'),
            lambda x: x['Config']['Env'].append('NODE_ADMIN_AGENT_SEQUENCE=1'),
            lambda x: x['Config'].update(User='0:0'),
            lambda x: x['Config']['Cmd'].remove('--require-existing-sequence-file')]
        for mutate in mutations:
            item.clear(); item.update(copy.deepcopy(original)); mutate(item)
            before = copy.deepcopy(item)
            with self.assertRaises(s.Rejected): self.execute()
            self.assertEqual(item, before, 'Foreign/drifted container must not be stopped or adopted')
        item.clear(); item.update(original)

    def test_upgrade_checkpoint_env_archive_and_state_commit_crashes_recover(self):
        old, files = self.legacy_failure()
        real_write = s.atomic_write
        failed = False
        def fail_state(path, data, *args, **kwargs):
            nonlocal failed
            if path.name == 'state.json' and not failed and s.decode(data).get('request', {}).get('profile') == s.STACK_PROFILE:
                failed = True
                raise s.Rejected('injected_state_commit_unknown')
            return real_write(path, data, *args, **kwargs)
        with patch.object(s, 'atomic_write', fail_state):
            with self.assertRaisesRegex(s.Rejected, 'injected_state_commit_unknown'): self.execute()
        self.assertEqual(self.state(), old)
        self.assertFalse((s.ROOT / 'test' / 'provision.env').exists())
        self.assertTrue((s.ROOT / 'test' / 'legacy-provision.env').is_file())
        self.assertEqual(self.execute()['generation'], old['generation'])
        for path, data in files.items(): self.assertEqual((s.ROOT / 'test' / path).read_bytes(), data)

    def test_upgrade_checkpoint_precedes_any_archive_side_effect(self):
        old, _ = self.legacy_failure()
        original = self.system.container('sprout-test-provision')
        write = s.atomic_write
        def fail_journal(path, *args, **kwargs):
            if path.name == 'stack-upgrade.json': raise s.Rejected('journal_not_durable')
            return write(path, *args, **kwargs)
        with patch.object(s, 'atomic_write', fail_journal):
            with self.assertRaisesRegex(s.Rejected, 'journal_not_durable'): self.execute()
        self.assertEqual(self.system.container(original['Id']), original)
        self.assertEqual(self.state(), old)
        self.assertFalse((s.ROOT / 'test' / 'stack-upgrade.json').exists())

    def test_upgrade_retries_after_unknown_successful_state_commit(self):
        old, files = self.legacy_failure()
        write = s.atomic_write
        did_fail = False
        def lose_receipt(path, data, *args, **kwargs):
            nonlocal did_fail
            result = write(path, data, *args, **kwargs)
            if path.name == 'state.json' and not did_fail and s.decode(data).get('request', {}).get('profile') == s.STACK_PROFILE:
                did_fail = True
                raise s.Rejected('lost_state_commit_receipt')
            return result
        with patch.object(s, 'atomic_write', lose_receipt):
            with self.assertRaisesRegex(s.Rejected, 'lost_state_commit_receipt'): self.execute()
        self.assertEqual(self.state()['request']['profile'], s.STACK_PROFILE)
        self.assertEqual(self.execute()['generation'], old['generation'])
        for path, data in files.items(): self.assertEqual((s.ROOT / 'test' / path).read_bytes(), data)

    def test_upgrade_refuses_running_foreign_or_changed_preserved_generation(self):
        old, _ = self.legacy_failure()
        item = self.system.containers[self.system.container('sprout-test-provision')['Id']]
        original = copy.deepcopy(item)
        for mutate in [lambda x: x['State'].update(Running=True),
                       lambda x: x['Config']['Labels'].update({'org.haven.sprout.generation': 'foreign'}),
                       lambda x: x['Config']['Env'].append('CELL_VAULT_MASTER_KEY_B64=foreign')]:
            item.clear(); item.update(copy.deepcopy(original)); mutate(item)
            before = copy.deepcopy(item)
            with self.assertRaises(s.Rejected): self.execute()
            self.assertEqual(before, item)
            self.assertEqual(self.state(), old)
        item.clear(); item.update(original)
        self.system.fail_after = 'rename'
        with self.assertRaises(s.Rejected): self.execute()
        auth = s.ROOT / 'test' / 'auth.json'
        auth.write_bytes(b'{}')
        with self.assertRaisesRegex(s.Rejected, 'upgrade_preserved_state_changed'): self.execute()
        self.assertEqual(auth.read_bytes(), b'{}')
        self.assertEqual(self.state(), old)

    @unittest.skipUnless(sys.platform == 'linux', 'Actual OpenSSL3 Ed25519 generation is a Linux host prerequisite')
    def test_linux_real_openssl_generation_keeps_seed_private_and_paired(self):
        model_run = self.system.run
        def real_openssl(arguments, **kwargs):
            if arguments[0] == '/usr/bin/openssl': return s.System.run(self.system, arguments, **kwargs)
            return model_run(arguments, **kwargs)
        self.system.run = real_openssl
        result = self.execute()
        key = s.ROOT / 'test' / 'node-secrets' / 'signing-key'
        self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o400)
        self.assertEqual(len(s.base64.urlsafe_b64decode(key.read_bytes() + b'=')), 32)
        self.assertEqual(result['node']['agent']['publicKeyBase64URL'], self.state()['stack']['agent_public_key'])
        self.assertNotIn(key.read_bytes().decode(), s.canonical_json(result).decode())

    def test_status_rejects_disabled_dependency_restart_and_install_repairs_it(self):
        first = self.execute()
        for role in ('admin', 'node'):
            item = self.system.containers[self.system.container('sprout-test-' + role)['Id']]
            item['HostConfig']['RestartPolicy']['Name'] = 'no'
            before = self.immutable()
            calls = len(self.system.calls)
            with self.assertRaisesRegex(s.Rejected, 'dependency_restart_conflict'):
                self.execute(s.request_document({'schema': s.SCHEMA, 'operation': 'status', 'instance': 'test'}))
            self.assertFalse(any(c[0] in ('start', 'stop', 'update', 'create') for c in self.system.calls[calls:]))
            self.assertEqual(item['HostConfig']['RestartPolicy']['Name'], 'no')
            self.assertEqual(self.execute()['generation'], first['generation'])
            self.assertEqual(item['HostConfig']['RestartPolicy']['Name'], 'unless-stopped')
            self.assertEqual(before, self.immutable())

    def test_verify_retry_reads_only_current_run_from_accumulated_docker_logs(self):
        self.system.admin_unknown = True
        with self.assertRaisesRegex(s.Rejected, 'injected_unknown_admin_receipt'): self.execute()
        self.system.admin_exit = 1
        with self.assertRaisesRegex(s.Rejected, 'admin_enrollment_unknown'): self.execute()
        verifier = self.system.container('sprout-test-admin-verify')['Id']
        before = self.immutable()
        self.system.admin_exit = 0
        self.assertEqual(self.execute()['status'], 'ready')
        self.assertEqual(self.system.container('sprout-test-admin-verify')['Id'], verifier)
        self.assertEqual(len(self.system.containers[verifier]['run_logs']), 2)
        self.assertEqual(self.system.enrollment_count, 1)
        self.assertEqual(before, self.immutable())

    def test_renewed_verified_catalog_preserves_original_request_and_container_labels(self):
        first = self.execute()
        state = self.state()
        original_receipt = (s.ROOT / 'test' / 'receipt.json').read_bytes()
        labels = {key: copy.deepcopy(value['Config']['Labels']) for key, value in self.system.containers.items() if 'Config' in value}
        before = self.immutable()
        refreshed = request(catalog_sha256_b64url='d' * 43)
        self.assertEqual(self.execute(dict(refreshed, operation='preflight'))['writes'], False)
        result = self.execute(refreshed)
        self.assertEqual(result['generation'], first['generation'])
        self.assertEqual(result['catalog_sha256_b64url'], 'd' * 43)
        self.assertEqual(result['initial_catalog_sha256_b64url'], 'c' * 43)
        self.assertEqual(self.state()['request'], state['request'])
        self.assertEqual(self.state()['request_hash'], state['request_hash'])
        self.assertEqual((s.ROOT / 'test' / 'receipt.json').read_bytes(), original_receipt)
        self.assertEqual(before, self.immutable())
        self.assertEqual(labels, {key: value['Config']['Labels'] for key, value in self.system.containers.items() if 'Config' in value})
        evidence = s.decode(s.read_file(s.ROOT / 'test' / 'catalog-verification.json'))
        self.assertEqual(evidence['sha256_b64url'], 'd' * 43)

    def test_catalog_refresh_rejects_any_authority_or_operative_binding_change(self):
        self.execute()
        state = self.state()
        evidence = (s.ROOT / 'test' / 'catalog-verification.json').read_bytes()
        for changes in [dict(catalog_publisher='x' * 43), dict(catalog_domain='other.example'),
                        dict(catalog_id='other-catalog'), dict(admin_image='registry.example/new/admin@sha256:' + '7' * 64),
                        dict(node_image='registry.example/new/node@sha256:' + '8' * 64),
                        dict(admin_public_origin='https://other-admin.example'), dict(admin_listen_port=9198),
                        dict(image='registry.example/new/web@sha256:' + '9' * 64),
                        dict(public_origin='https://other-web.example'), dict(purposes=['purpose://other'])]:
            with self.subTest(changes=changes):
                calls = len(self.system.calls)
                with self.assertRaises(s.Rejected): self.execute(request(catalog_sha256_b64url='d' * 43, **changes))
                self.assertFalse(any(c[0] in ('create', 'start', 'stop', 'update', 'rename') for c in self.system.calls[calls:]))
                self.assertEqual(self.state(), state)
                self.assertEqual((s.ROOT / 'test' / 'catalog-verification.json').read_bytes(), evidence)

    def test_upgrade_unknown_rename_accepts_renewed_catalog_without_rebinding_journal(self):
        old, files = self.legacy_failure()
        self.system.fail_after = 'rename'
        with self.assertRaisesRegex(s.Rejected, 'injected_unknown_rename'): self.execute()
        journal = (s.ROOT / 'test' / 'stack-upgrade.json').read_bytes()
        result = self.execute(request(catalog_sha256_b64url='d' * 43))
        self.assertEqual(result['generation'], old['generation'])
        self.assertEqual(result['catalog_sha256_b64url'], 'd' * 43)
        self.assertEqual(result['initial_catalog_sha256_b64url'], 'c' * 43)
        self.assertEqual((s.ROOT / 'test' / 'stack-upgrade.json').read_bytes(), journal)
        for path, data in files.items(): self.assertEqual((s.ROOT / 'test' / path).read_bytes(), data)

    def test_admin_receipt_rejects_changed_run_after_log_capture(self):
        docker = self.system.docker
        def change_run(*args, **kwargs):
            result = docker(*args, **kwargs)
            if args[0] == 'logs' and '--since' in args:
                self.system.containers[args[-1]]['State']['StartedAt'] = '2026-10-14T11:00:00.000000000Z'
            return result
        self.system.docker = change_run
        with self.assertRaisesRegex(s.Rejected, 'admin_run_changed'): self.execute()
        self.assertNotIn('enrollment', self.state()['stack'])
        self.assertEqual(self.system.enrollment_count, 1)

    def test_receipt_log_timestamp_after_process_exit_is_not_discarded(self):
        self.system.late_log = True
        self.assertEqual(self.execute()['status'], 'ready')
        item = self.system.container('sprout-test-admin-enroll')
        self.assertGreater(item['run_logs'][0][0], item['State']['FinishedAt'])

    def test_wrong_owner_tls_or_relaxed_freshness_never_becomes_ready(self):
        for fault in ('owner', 'optional', 'tls'):
            with self.subTest(fault=fault):
                self.system.audit_fault = fault
                with self.assertRaisesRegex(s.Rejected, 'admin_functional'): self.execute()
                self.assertNotEqual(self.state()['phase'], 'ready')
                self.assertFalse((s.ROOT / 'test' / 'receipt.json').exists())


if __name__ == '__main__': unittest.main()
