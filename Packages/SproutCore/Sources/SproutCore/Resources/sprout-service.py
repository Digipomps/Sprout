#!/usr/bin/python3
"""Root-only, fixed-profile CellScaffold installation coordinator.

Input is one bounded JSON document. The invoking root administrator authorizes
execution of the exact image digest; the Sprout client verifies its publisher's
catalog first. No caller-supplied command, environment or host mount is accepted.
This installs a new generation, never upgrades or adopts an unrelated service.

Request schema: haven.sprout.service-request.v1. All operations take instance
and optional fixed root /var/lib/haven/sprout. Install and read-only preflight
also require image (canonical repository@sha256), platform, profile, listen_port,
purposes and public_origin (HTTPS DNS origin, optional explicit TCP port).
Status takes only schema/operation/instance/root. Preflight does not inspect the
image, because the client calls it before pulling the authorized digest.

Durable phases: prepared -> secrets-ready -> enrolled -> canonical-ready ->
ready. The network-isolated EAGER_BOOTSTRAP provisioning container uses the
runtime's owner/resolver-gated provision-if-missing mode and must exit zero with
its completion marker. The serving container uses require-existing. Neither
phase permits developer key generation or staging-manifest bypass. A ready
receipt proves local health/build/login/auth-boundary and selected-purpose
discovery checks across restart; it does not verify bridge-descriptor signatures;
public TLS and an authenticated end-user purpose journey are separate evidence.
"""
from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid

ROOT = Path('/var/lib/haven/sprout')
ROOT_UID = 0
ROOT_GID = 0
RUNTIME_UID = 995
RUNTIME_GID = 995
PROFILE = 'cellscaffold-web-v1'
SCHEMA = 'haven.sprout.service-request.v1'
RECEIPT_SCHEMA = 'haven.sprout.service-receipt.v1'
DOCKER = '/usr/bin/docker'
CLEAN_ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root', 'LANG': 'C.UTF-8'}
IMAGE = re.compile(r'[a-z0-9]+(?:[.-][a-z0-9]+)*(?::[0-9]+)?/[a-z0-9]+(?:[._/-][a-z0-9]+)*@sha256:[0-9a-f]{64}\Z')
HEX40 = re.compile(r'[0-9a-f]{40}\Z')
DIGEST = re.compile(r'sha256:[0-9a-f]{64}\Z')
TOKEN = re.compile(r'[A-Za-z0-9_-]{43}\Z')
MAX_JSON = 1 << 20


class Rejected(Exception):
    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


def require(condition, reason):
    if not condition:
        raise Rejected(reason)


def stamp():
    return dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def decode(data):
    require(len(data) <= MAX_JSON, 'document_too_large')
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate_json_key')
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs)
    except (ValueError, UnicodeError):
        raise Rejected('invalid_json') from None


def valid_timestamp(value):
    try:
        return isinstance(value, str) and dt.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').strftime('%Y-%m-%dT%H:%M:%SZ') == value
    except ValueError:
        return False


def normalize_image(value):
    if '/' not in value:
        return 'docker.io/library/' + value
    host, rest = value.split('/', 1)
    if host in ('docker.io', 'index.docker.io'):
        return 'docker.io/' + ('' if '/' in rest else 'library/') + rest
    if '.' not in host and ':' not in host and host != 'localhost':
        return 'docker.io/' + value
    return value


def request_document(value):
    require(isinstance(value, dict), 'invalid_request')
    minimal = {'schema', 'operation', 'instance', 'root'}
    install = {'image', 'platform', 'profile', 'listen_port', 'purposes', 'public_origin'}
    require(value.get('schema') == SCHEMA and value.get('operation') in ('preflight', 'install', 'status'), 'invalid_request')
    require(set(value) <= minimal | install, 'unknown_request_field')
    require(isinstance(value.get('instance'), str) and re.fullmatch(r'[a-z][a-z0-9-]{0,39}', value['instance']), 'invalid_instance')
    require(value.get('root', str(ROOT)) == str(ROOT), 'unsupported_root')
    result = dict(value, root=str(ROOT))
    if value['operation'] == 'status':
        require(set(value) <= minimal, 'invalid_status_request')
        return result
    require(install <= set(value), 'incomplete_request')
    image = value['image']
    require(isinstance(image, str) and len(image) <= 512 and IMAGE.fullmatch(image) and normalize_image(image) == image, 'invalid_image')
    host = image.split('/', 1)[0]
    require('.' in host or ':' in host or host == 'localhost', 'registry_not_explicit')
    require(value['platform'] in ('linux/amd64', 'linux/arm64') and value['profile'] == PROFILE, 'unsupported_profile')
    require(type(value['listen_port']) is int and 1024 <= value['listen_port'] <= 65535, 'invalid_port')
    purposes = value['purposes']
    require(isinstance(purposes, list) and 0 < len(purposes) <= 16 and all(isinstance(p, str) and re.fullmatch(r'[A-Za-z0-9:/._-]{1,256}', p) for p in purposes), 'invalid_purposes')
    require(len(set(purposes)) == len(purposes), 'duplicate_purpose')
    origin = value['public_origin']
    require(isinstance(origin, str) and len(origin) <= 253, 'invalid_origin')
    try:
        url = urllib.parse.urlsplit(origin)
        port = url.port
        host = url.hostname
        require(url.scheme == 'https' and host and url.username is None and url.password is None and url.path == '' and not url.query and not url.fragment, 'invalid_origin')
        require('.' in host and re.fullmatch(r'[a-z0-9]+(?:[.-][a-z0-9]+)*', host) and (port is None or (1 <= port <= 65535 and port != 443)), 'invalid_origin')
        # BridgeChannelAuthentication requires the default TLS port to be
        # implicit; its canonical wss endpoint rejects an explicit :443.
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            raise Rejected('origin_requires_dns_name')
        require(origin == 'https://' + host + (':' + str(port) if port is not None else '') + url.path, 'noncanonical_origin')
    except ValueError:
        raise Rejected('invalid_origin') from None
    result['public_origin'] = origin.rstrip('/')
    result['purposes'] = sorted(purposes)
    return result


def identity_request(request):
    return {key: value for key, value in request.items() if key not in ('operation', 'schema')}


def validate_directory(path, uid=None, mode=None):
    uid = ROOT_UID if uid is None else uid
    info = os.lstat(path)
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == uid and not (info.st_mode & 0o022), 'unsafe_directory')
    if mode is not None:
        require(stat.S_IMODE(info.st_mode) == mode, 'unsafe_directory_mode')
    return info


def verify_ancestors(path):
    require(path.is_absolute() and '..' not in path.parts and '.' not in path.parts, 'unsafe_path')
    cursor = Path('/')
    for part in path.parts[1:]:
        cursor /= part
        if not cursor.exists() and not cursor.is_symlink():
            break
        validate_directory(cursor)


def mkdir(path, uid=None, gid=None, mode=0o755):
    uid = ROOT_UID if uid is None else uid
    gid = ROOT_GID if gid is None else gid
    if not path.exists() and not path.is_symlink():
        os.mkdir(path, mode)
        os.chown(path, uid, gid)
        os.chmod(path, mode)
    validate_directory(path, uid, mode)
    require(os.lstat(path).st_gid == gid, 'unsafe_directory_group')


def read_file(path, uid=None, modes=(0o600,), limit=MAX_JSON):
    uid = ROOT_UID if uid is None else uid
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == uid and stat.S_IMODE(info.st_mode) in modes and info.st_nlink == 1 and 0 <= info.st_size <= limit, 'unsafe_file')
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        require(len(data) <= limit, 'document_too_large')
        after = os.fstat(fd)
        require((info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) == (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'file_changed')
        return bytes(data)
    finally:
        os.close(fd)


def atomic_write(path, data, uid=None, gid=None, mode=0o600, replace=False):
    uid = ROOT_UID if uid is None else uid
    gid = ROOT_GID if gid is None else gid
    if path.exists() or path.is_symlink():
        existing = read_file(path, uid=uid, modes=(mode,), limit=max(MAX_JSON, len(data)))
        if not replace:
            require(existing == data, 'existing_file_conflict')
            return
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        os.fchown(fd, uid, gid)
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb', closefd=True) as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


class System:
    """Subprocess boundary. Tests inject a model here, never a CLI bypass flag."""
    def run(self, arguments, *, environment=None, pass_fds=(), timeout=180, limit=MAX_JSON):
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
            process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                       env=environment or CLEAN_ENV, pass_fds=pass_fds, start_new_session=True)
            try:
                process.wait(timeout=timeout)
            except BaseException:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise Rejected('command_interrupted') from None
            require(out.tell() <= limit and err.tell() <= limit, 'command_output_too_large')
            out.seek(0)
            err.seek(0)
            return process.returncode, out.read(), err.read()

    def docker(self, *arguments, timeout=180, allow_missing=False):
        code, out, error = self.run([DOCKER, '--host', 'unix:///var/run/docker.sock', *arguments], timeout=timeout)
        if allow_missing and code == 1 and (b'No such container:' in error or b'No such object:' in error):
            return None
        require(code == 0, 'docker_command_failed')
        return out

    def container(self, name):
        result = self.docker('container', 'inspect', name, allow_missing=True)
        if result is None:
            return None
        data = decode(result)
        require(isinstance(data, list) and len(data) == 1 and isinstance(data[0], dict), 'invalid_container_report')
        return data[0]

    def http(self, port, path, *, json_body=None):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        try:
            if json_body is None:
                connection.request('GET', path)
            else:
                connection.request('POST', path, body=canonical_json(json_body),
                                   headers={'Content-Type': 'application/json', 'Accept': 'application/json'})
            response = connection.getresponse()
            body = response.read(MAX_JSON + 1)
            require(len(body) <= MAX_JSON, 'http_response_too_large')
            return response.status, dict(response.getheaders()), body
        finally:
            connection.close()

    def port_free(self, port):
        with socket.socket() as probe:
            try:
                probe.bind(('127.0.0.1', port))
            except OSError:
                raise Rejected('listen_port_busy') from None

    def pause(self):
        time.sleep(1)


def host_preflight(request):
    require(sys.platform == 'linux' and os.geteuid() == 0, 'linux_root_required')
    architecture = {'x86_64': 'linux/amd64', 'aarch64': 'linux/arm64'}.get(platform.machine())
    require(architecture is not None and request.get('platform', architecture) == architecture, 'unsupported_host_platform')
    verify_ancestors(ROOT)
    for tool in (DOCKER, '/usr/bin/unshare', '/usr/bin/setpriv'):
        require(os.path.isfile(tool) and os.access(tool, os.X_OK), 'host_tool_missing')
        require(os.stat(tool).st_uid == 0 and not (os.stat(tool).st_mode & 0o022), 'unsafe_host_tool')
    require(os.path.exists('/var/run/docker.sock') and stat.S_ISSOCK(os.stat('/var/run/docker.sock').st_mode), 'local_docker_socket_missing')
    library_arch = 'x86_64-linux-gnu' if architecture == 'linux/amd64' else 'aarch64-linux-gnu'
    require(any(Path(prefix, library_arch, 'libjemalloc.so.2').is_file() for prefix in ('/lib', '/usr/lib')), 'host_jemalloc_missing')


class Coordinator:
    def __init__(self, system=None):
        self.system = system or System()
        self.state = None
        self.instance = None
        self.request = None

    def save(self):
        atomic_write(self.instance / 'state.json', canonical_json(self.state), replace=True)

    def load(self, instance):
        state_file = instance / 'state.json'
        if state_file.exists() or state_file.is_symlink():
            validate_directory(instance)
            state = decode(read_file(state_file))
            require(isinstance(state, dict) and state.get('schema') == 'haven.sprout.service-state.v1', 'invalid_local_state')
            return state
        require(not instance.exists(), 'unrecorded_instance_directory')
        return None

    def preflight(self, request):
        host_preflight(request)
        self.instance = ROOT / request['instance']
        self.state = self.load(self.instance)
        if request['operation'] == 'status':
            require(self.state is not None, 'instance_not_installed')
            self.request = request_document(dict(self.state['request'], schema=SCHEMA, operation='install'))
        else:
            self.request = request
            if self.state:
                require(self.state.get('request') == identity_request(request), 'instance_configuration_conflict')
        serving = self.system.container('sprout-' + request['instance'])
        if serving:
            require(self.state is not None, 'container_name_in_use')
            self.verify_container(serving, 'service')
        if request['operation'] != 'status' and (not serving or serving.get('State', {}).get('Running') is not True):
            self.system.port_free(self.request['listen_port'])
        return serving

    def verify_container(self, container, phase):
        require(self.state is not None, 'unowned_container')
        config = container.get('Config', {})
        labels = config.get('Labels') or {}
        host = container.get('HostConfig', {})
        require(labels.get('org.haven.sprout.generation') == self.state['generation']
                and labels.get('org.haven.sprout.request') == self.state['request_hash']
                and labels.get('org.haven.sprout.phase') == phase
                and config.get('Image') == self.request['image']
                and config.get('User') == '995:995'
                and host.get('Privileged') is False, 'container_configuration_conflict')
        require(config.get('Entrypoint') == ['/usr/local/bin/cellscaffold-entrypoint']
                and config.get('Cmd') == ['serve', '--env', 'production', '--hostname', '0.0.0.0', '--port', '8080']
                and host.get('NetworkMode') == ('none' if phase == 'canonical' else 'bridge')
                and host.get('CapDrop') == ['ALL']
                and 'no-new-privileges:true' in (host.get('SecurityOpt') or []), 'container_security_conflict')
        policy = host.get('RestartPolicy', {})
        require(policy.get('Name') in (('no',) if phase == 'canonical' else ('no', 'unless-stopped'))
                and policy.get('MaximumRetryCount', 0) == 0, 'container_restart_policy_conflict')
        expected = self.environment_values(phase == 'canonical')
        environment = dict(x.split('=', 1) for x in config.get('Env', []) if '=' in x)
        require(all(environment.get(key) == value for key, value in expected.items())
                and 'CELL_VAULT_MASTER_KEY_B64' not in environment, 'container_environment_conflict')
        if phase == 'service':
            require(host.get('PortBindings') == {'8080/tcp': [{'HostIp': '127.0.0.1', 'HostPort': str(self.request['listen_port'])}]}, 'container_port_conflict')
        else:
            require(not host.get('PortBindings'), 'container_port_conflict')
        require(container.get('Image') == self.state.get('image_id'), 'container_image_conflict')
        require(sorted(host.get('Binds') or []) == sorted(self.mounts()), 'container_mount_conflict')
        return container

    def image_metadata(self):
        report = decode(self.system.docker('image', 'inspect', self.request['image']))
        require(isinstance(report, list) and len(report) == 1, 'invalid_image_report')
        item = report[0]
        require(self.request['image'] in [normalize_image(x) for x in item.get('RepoDigests', [])]
                and item.get('Os') + '/' + item.get('Architecture') == self.request['platform'], 'image_digest_or_platform_mismatch')
        require(DIGEST.fullmatch(item.get('Id', '')), 'invalid_image_id')
        config = item.get('Config') or {}
        labels = config.get('Labels') or {}
        revision = labels.get('org.opencontainers.image.revision')
        created = labels.get('org.opencontainers.image.created')
        require(isinstance(revision, str) and HEX40.fullmatch(revision) and valid_timestamp(created), 'image_build_metadata_missing')
        require(labels.get('org.opencontainers.image.source') == 'https://github.com/Digipomps/CellScaffold', 'unsupported_image_source')
        environment = dict(x.split('=', 1) for x in config.get('Env', []) if '=' in x)
        require('CELL_VAULT_MASTER_KEY_B64' not in environment, 'image_inline_vault_key_forbidden')
        require(environment.get('APP_BUILD_REVISION') == revision and environment.get('APP_BUILD_TIMESTAMP') == created, 'image_build_metadata_conflict')
        return item['Id'], {'app_revision': revision, 'build_timestamp': created}

    def prepare(self, image_id, build):
        # All caller-selected paths end at the fixed, root-owned base.
        for path in (ROOT.parent, ROOT):
            mkdir(path)
        mkdir(self.instance)
        if self.state is None:
            self.state = {'schema': 'haven.sprout.service-state.v1', 'request': identity_request(self.request),
                          'request_hash': hashlib.sha256(canonical_json(identity_request(self.request))).hexdigest(),
                          'generation': str(uuid.uuid4()), 'owner_uuid': str(uuid.uuid4()),
                          'enrollment_id': str(uuid.uuid4()), 'issued_at': stamp(),
                          'image_id': image_id, 'build': build, 'phase': 'prepared'}
            self.save()
        require(self.state['image_id'] == image_id and self.state['build']['app_revision'] == build['app_revision'], 'image_changed')
        for name in ('native',):
            mkdir(self.instance / name)
        for name in ('data', 'ceremony', 'runtime-secrets'):
            mkdir(self.instance / name, RUNTIME_UID, RUNTIME_GID, 0o700)
        mkdir(self.instance / 'data' / 'vault', RUNTIME_UID, RUNTIME_GID, 0o700)
        mkdir(self.instance / 'migration-state', mode=0o711)
        # No secret is regenerated after the initialization checkpoint.
        key = self.instance / 'runtime-secrets' / 'cell-vault-master-key'
        auth = self.instance / 'auth.json'
        if self.state['phase'] == 'prepared':
            require(not (self.instance / 'data' / 'vault' / 'OrganisationIdentities.crypt').exists()
                    and not (self.instance / 'ceremony' / 'enrollment.json').exists(), 'uncheckpointed_initialization')
            if not key.exists() and not key.is_symlink():
                atomic_write(key, secrets.token_bytes(32), RUNTIME_UID, RUNTIME_GID, 0o400)
            if not auth.exists() and not auth.is_symlink():
                atomic_write(auth, canonical_json({'chat': secrets.token_urlsafe(48), 'jwt': secrets.token_urlsafe(48)}))
            self.state['phase'] = 'secrets-ready'
            self.save()
        require(len(read_file(key, RUNTIME_UID, (0o400,), 4096)) == 32, 'invalid_master_key')
        auth_values = decode(read_file(auth))
        require(set(auth_values) == {'chat', 'jwt'} and all(isinstance(v, str) and re.fullmatch(r'[A-Za-z0-9_-]{64}', v) for v in auth_values.values()), 'invalid_auth_secrets')

    def lock(self):
        path = self.instance / 'maintenance.lock'
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o660)
        info = os.fstat(fd)
        if info.st_uid == ROOT_UID and stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size == 0:
            os.fchown(fd, ROOT_UID, RUNTIME_GID)
            os.fchmod(fd, 0o660)
        require(info.st_uid == ROOT_UID and stat.S_ISREG(info.st_mode) and info.st_nlink == 1, 'unsafe_lock')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            raise Rejected('instance_busy') from None
        return fd

    def extract(self):
        native = self.instance / 'native'
        binary = native / 'CellScaffoldIdentityBootstrap'
        metadata = native / 'Package.resolved'
        app_info = native / 'build-info.json'
        if self.state.get('native_sha256'):
            require(digest(read_file(binary, modes=(0o755,), limit=512 << 20)) == self.state['native_sha256'], 'bootstrap_binary_changed')
            require(digest(read_file(metadata, modes=(0o644,))) == self.state['package_sha256'], 'package_metadata_changed')
            return binary
        # Extraction uses a non-running container. No image code runs as root.
        container = self.system.docker('create', '--network', 'none', '--entrypoint', '/bin/true', self.request['image']).decode().strip()
        require(re.fullmatch(r'[0-9a-f]{64}', container), 'invalid_extraction_container')
        try:
            for source, target, mode, maximum in [('/app/CellScaffoldIdentityBootstrap', binary, 0o755, 512 << 20),
                                                 ('/app/BuildMetadata/Package.resolved', metadata, 0o644, MAX_JSON),
                                                 ('/app/BuildMetadata/build-info.json', app_info, 0o644, MAX_JSON)]:
                if target.exists() or target.is_symlink():
                    read_file(target, modes=(mode,), limit=maximum)
                    target.unlink()  # Only root-owned extracted tools, never vault/key state.
                self.system.docker('cp', container + ':' + source, str(target))
                info = os.lstat(target)
                require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= maximum, 'unsafe_extracted_file')
                os.chown(target, ROOT_UID, ROOT_GID)
                os.chmod(target, mode)
            blob = read_file(binary, modes=(0o755,), limit=512 << 20)
            require(blob[:4] == b'\x7fELF', 'bootstrap_not_linux_executable')
            package = decode(read_file(metadata, modes=(0o644,)))
            pins = {p['identity'].lower(): p['state']['revision'] for p in package.get('pins', [])}
            require(all(isinstance(pins.get(key), str) and HEX40.fullmatch(pins[key]) for key in ('cellprotocol', 'dimymicropayments', 'dimymint')), 'package_revisions_missing')
            actual = decode(read_file(app_info, modes=(0o644,)))
            require(actual == self.state['build'], 'packaged_build_metadata_conflict')
            self.state['build'].update({key + '_revision': pins[key] for key in ('cellprotocol', 'dimymicropayments', 'dimymint')})
            self.state['native_sha256'] = digest(blob)
            self.state['package_sha256'] = digest(read_file(metadata, modes=(0o644,)))
            self.save()
        finally:
            self.system.docker('rm', container)
        return binary

    def enroll(self, binary, lock_fd):
        ceremony = self.instance / 'ceremony'
        manifest = ceremony / 'manifest.json'
        if 'enrollment' not in self.state:
            # No first-owner ceremony may overlap a service or provisioning process.
            for suffix, phase in (('', 'service'), ('-provision', 'canonical')):
                running = self.system.container('sprout-' + self.request['instance'] + suffix)
                if running:
                    self.verify_container(running, phase)
                    require(running.get('State', {}).get('Running') is not True, 'offline_enrollment_required')
            build = self.state['build']
            environment = dict(CLEAN_ENV, CELL_SCAFFOLD_BOOTSTRAP_OPERATION='enroll-first-owner',
                CELL_SCAFFOLD_BOOTSTRAP_LOCK_FD=str(lock_fd), CELL_SCAFFOLD_BOOTSTRAP_LOCK_PATH=str(self.instance / 'maintenance.lock'),
                CELL_SCAFFOLD_BOOTSTRAP_LOCK_GID=str(RUNTIME_GID), CELL_SCAFFOLD_BOOTSTRAP_MANIFEST_PATH=str(manifest),
                CELL_SCAFFOLD_BOOTSTRAP_ENVIRONMENT='production', CELL_SCAFFOLD_OWNER_CONTEXT='Scaffold',
                CELL_SCAFFOLD_BOOTSTRAP_OWNER_UUID=self.state['owner_uuid'], CELL_SCAFFOLD_BOOTSTRAP_ENROLLMENT_ID=self.state['enrollment_id'],
                CELL_SCAFFOLD_BOOTSTRAP_ENROLLMENT_ISSUED_AT=self.state['issued_at'],
                CELL_SCAFFOLD_BOOTSTRAP_ENROLLMENT_JOURNAL_PATH=str(ceremony / 'enrollment.json'),
                CELL_VAULT_DOCUMENT_ROOT=str(self.instance / 'data' / 'vault'),
                CELL_VAULT_MASTER_KEY_PATH=str(self.instance / 'runtime-secrets' / 'cell-vault-master-key'),
                CELL_VAULT_ALLOW_DEV_KEYGEN='false', VAPOR_ENV='production',
                APP_BUILD_REVISION=build['app_revision'], APP_BUILD_TIMESTAMP=build['build_timestamp'],
                CELLPROTOCOL_BUILD_REVISION=build['cellprotocol_revision'], DIMYMINT_BUILD_REVISION=build['dimymint_revision'])
            code, out, _ = self.system.run(['/usr/bin/unshare', '--net', '--', '/usr/bin/setpriv', '--reuid=995', '--regid=995', '--clear-groups', '--no-new-privs', '--bounding-set=-all', '--inh-caps=-all', '--ambient-caps=-all', str(binary)], environment=environment, pass_fds=(lock_fd,), timeout=240)
            require(code == 0, 'first_owner_enrollment_failed_preserve_generation')
            receipt = decode(out)
            self.validate_enrollment(receipt, read_file(manifest, RUNTIME_UID))
            self.state['enrollment'] = receipt
            self.state['phase'] = 'enrolled'
            self.save()
        manifest_bytes = read_file(manifest, RUNTIME_UID)
        self.validate_enrollment(self.state['enrollment'], manifest_bytes)
        atomic_write(self.instance / 'runtime-secrets' / 'runtime-identity-manifest.v2.json', manifest_bytes, RUNTIME_UID, RUNTIME_GID, 0o400)

    def validate_enrollment(self, receipt, manifest):
        require(isinstance(receipt, dict) and receipt.get('schemaVersion') == 'haven.cellscaffold.runtime-identity-verification-receipt.v1'
                and receipt.get('operation') == 'enroll-first-owner' and receipt.get('status') == 'verified'
                and receipt.get('appRevision') == self.state['build']['app_revision']
                and receipt.get('manifestSHA256') == digest(manifest), 'invalid_enrollment_receipt')
        owner = receipt.get('owner', {})
        require(set(owner) == {'uuid', 'context', 'signingKeyFingerprintDigest'} and owner.get('uuid') == self.state['owner_uuid']
                and owner.get('context') == 'Scaffold' and TOKEN.fullmatch(owner.get('signingKeyFingerprintDigest', '')), 'invalid_owner_pin')
        document = decode(manifest)
        payload = document.get('payload', {})
        signature = document.get('signature', {})
        require(payload.get('schemaVersion') == 'haven.cellscaffold.runtime-identity-manifest.v3'
                and payload.get('canonicalization') == 'json_sorted_keys_and_arrays_v1'
                and payload.get('registrySchemaVersion') == 'haven.cellscaffold.runtime-identity-registry.v3'
                and payload.get('effectiveOwnerContext') == 'Scaffold'
                and isinstance(receipt.get('registryDigest'), str)
                and re.fullmatch(r'sha256:[A-Za-z0-9_-]{43}', receipt['registryDigest'])
                and payload.get('registryDigest') == receipt['registryDigest'], 'manifest_profile_mismatch')
        build = self.state['build']
        expected_build = {'appRevision': build['app_revision'], 'cellProtocolRevision': build['cellprotocol_revision'],
                          'dimyMintRevision': build['dimymint_revision'], 'buildTimestamp': build['build_timestamp'],
                          'environment': 'production'}
        require(payload.get('build') == expected_build, 'manifest_build_mismatch')
        require(signature.get('algorithm') == 'Ed25519' and signature.get('signerIdentityUUID') == owner['uuid']
                and signature.get('signerFingerprintDigest') == owner['signingKeyFingerprintDigest'], 'manifest_owner_mismatch')
        bindings = payload.get('bindings', [])
        owners = [b for b in bindings if isinstance(b, dict) and b.get('registryID') == 'owner.scaffold']
        require(len(owners) == 1 and owners[0].get('state') == 'present'
                and owners[0].get('identityUUID') == owner['uuid'] and owners[0].get('context') == 'Scaffold'
                and owners[0].get('signingKeyFingerprintDigest') == owner['signingKeyFingerprintDigest'], 'manifest_owner_mismatch')
        # The pinned image's offline verifier checked the actual Ed25519 signature,
        # complete vault and compiled registry. Runtime verifies them again before listening.

    def mounts(self):
        return [str(self.instance / 'data') + ':/app/CellsContainer:rw',
                str(self.instance / 'runtime-secrets') + ':/etc/haven/cellscaffold-runtime-secrets:ro',
                str(self.instance / 'migration-state') + ':/run/cellscaffold-key-continuity:ro']

    def environment_values(self, one_shot):
        auth = decode(read_file(self.instance / 'auth.json'))
        owner = self.state['enrollment']['owner']
        values = {'VAPOR_ENV': 'production', 'CELL_SCAFFOLD_RUN_EXECUTABLE': '/app/Run', 'RP_ID': urllib.parse.urlsplit(self.request['public_origin']).hostname,
            'RP_ORIGIN': self.request['public_origin'], 'CELL_SCAFFOLD_BRIDGE_ORIGIN': self.request['public_origin'],
            'PUBLIC_BASE_URL': self.request['public_origin'], 'CELL_SCAFFOLD_PUBLIC_BASE_URL': self.request['public_origin'],
            'SPROUT_SCAFFOLD_DOMAIN': urllib.parse.urlsplit(self.request['public_origin']).hostname,
            'SPROUT_BRIDGE_ALLOWED_PURPOSES': ','.join(self.request['purposes']),
            'CHAT_MVP_TOKEN_SECRET': auth['chat'], 'JWT_AUTH_SECRET': auth['jwt'],
            'SQLITE_DATABASE_PATH': '/app/CellsContainer/service.sqlite',
            'CELL_VAULT_DOCUMENT_ROOT': '/app/CellsContainer/vault',
            'CELL_VAULT_MASTER_KEY_PATH': '/etc/haven/cellscaffold-runtime-secrets/cell-vault-master-key',
            'CELL_VAULT_ALLOW_DEV_KEYGEN': 'false', 'CELL_SCAFFOLD_OWNER_CREATE_IF_MISSING': 'false',
            'CELL_SCAFFOLD_OWNER_CONTEXT': owner['context'], 'CELL_SCAFFOLD_OWNER_UUID': owner['uuid'],
            'CELL_SCAFFOLD_OWNER_SIGNING_KEY_FINGERPRINT': owner['signingKeyFingerprintDigest'],
            'CELL_SCAFFOLD_STAGING_MANIFEST_BYPASS': 'false', 'CELL_SCAFFOLD_ALLOW_ROOT_ENTRYPOINT': 'false',
            'CELL_SCAFFOLD_REQUIRE_MIGRATION_INTERLOCK': 'true',
            'CELL_VAULT_MIGRATION_STATE_DIRECTORY': '/run/cellscaffold-key-continuity',
            'CELL_VAULT_MIGRATION_STATE_EXPECTED_UID': '0', 'CELL_VAULT_MIGRATION_STATE_EXPECTED_GID': '0',
            'CELL_SCAFFOLD_EAGER_BOOTSTRAP_MODE': 'provision-if-missing' if one_shot else 'require-existing',
            'CELL_SCAFFOLD_EAGER_BOOTSTRAP_PROVISION_ONLY': 'true' if one_shot else 'false',
            'CELL_SCAFFOLD_ADMIN_PROVISION_ONLY': 'false'}
        return values

    def environment(self, one_shot):
        values = self.environment_values(one_shot)
        path = self.instance / ('provision.env' if one_shot else 'service.env')
        atomic_write(path, ('\n'.join(key + '=' + values[key] for key in sorted(values)) + '\n').encode())
        return path

    def ensure_container(self, phase):
        one_shot = phase == 'canonical'
        name = 'sprout-' + self.request['instance'] + ('-provision' if one_shot else '')
        existing = self.system.container(name)
        if existing:
            return self.verify_container(existing, phase)
        args = ['create', '--name', name, '--user', '995:995', '--network', 'none' if one_shot else 'bridge',
                '--restart', 'no', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
                '--pids-limit', '512', '--memory', '2g', '--cpus', '2',
                '--log-opt', 'max-size=10m', '--log-opt', 'max-file=3',
                '--env-file', str(self.environment(one_shot))]
        for key, value in {'generation': self.state['generation'], 'request': self.state['request_hash'], 'phase': phase}.items():
            args += ['--label', 'org.haven.sprout.' + key + '=' + value]
        for mount in self.mounts():
            args += ['--volume', mount]
        if not one_shot:
            args += ['--publish', '127.0.0.1:' + str(self.request['listen_port']) + ':8080']
        args += ['--entrypoint', '/usr/local/bin/cellscaffold-entrypoint', self.request['image'],
                 'serve', '--env', 'production', '--hostname', '0.0.0.0', '--port', '8080']
        identifier = self.system.docker(*args).decode().strip()
        require(re.fullmatch(r'[0-9a-f]{64}', identifier), 'invalid_container_id')
        result = self.system.container(name)
        require(result is not None and result.get('Id') == identifier, 'container_creation_unknown')
        return self.verify_container(result, phase)

    def provision(self):
        if self.state.get('canonical_complete'):
            return
        container = self.ensure_container('canonical')
        identifier = container['Id']
        self.pending_canonical = identifier
        if container['State'].get('Status') == 'created' or (container['State'].get('Running') is not True and container['State'].get('ExitCode') != 0):
            self.system.docker('start', identifier)
        exit_code = self.system.docker('wait', identifier, timeout=300).strip()
        require(exit_code == b'0', 'canonical_provisioning_failed_preserve_generation')
        output = self.system.docker('logs', identifier)
        require(b'status=eager_bootstrap_provisioning_complete' in output, 'canonical_provisioning_unverified')
        self.state['canonical_complete'] = True
        self.state['phase'] = 'canonical-ready'
        self.save()

    def health(self, attempts=90):
        for attempt in range(attempts):
            try:
                code, _, body = self.system.http(self.request['listen_port'], '/health/ready')
                ready = decode(body)
                require(code == 200 and ready.get('acceptsNewTraffic') is True, 'service_not_ready')
                code, _, body = self.system.http(self.request['listen_port'], '/health/build')
                build = decode(body)
                require(code == 200 and all(build.get(key) == value for key, value in self.state['build'].items()) and build.get('environment') == 'production', 'runtime_build_mismatch')
                code, _, body = self.system.http(self.request['listen_port'], '/login')
                require(code == 200 and b'passkey' in body.lower() and b'webauthn' in body.lower(), 'login_surface_unavailable')
                code, headers, _ = self.system.http(self.request['listen_port'], '/porthole')
                location = next((v for k, v in headers.items() if k.lower() == 'location'), '')
                require(code in (302, 303) and location.startswith('/login'), 'authentication_boundary_failed')
                # This is a real application POST for every selected purpose.
                # The configured runtime origin, not caller-supplied proxy headers,
                # must determine discovery endpoints. This does not authenticate
                # a WebSocket session or cryptographically verify its descriptor.
                domain = urllib.parse.urlsplit(self.request['public_origin']).hostname
                websocket_origin = 'wss://' + self.request['public_origin'][len('https://'):]
                for purpose in self.request['purposes']:
                    query = {'scaffold_domain': domain, 'purpose': purpose, 'interests': ['haven.core.bridge']}
                    code, _, body = self.system.http(self.request['listen_port'], '/v1/bridges/query', json_body=query)
                    discovery = decode(body)
                    bridges = discovery.get('bridges') if isinstance(discovery, dict) else None
                    require(code == 200 and isinstance(bridges, list) and 0 < len(bridges) <= 16, 'purpose_discovery_failed')
                    route = ('/v1/resolver/native-porthole/Porthole' if purpose == 'purpose://operate-local-haven-agent'
                             else '/bridgehead/Porthole/CloudBridge')
                    for bridge in bridges:
                        require(isinstance(bridge, dict) and bridge.get('scaffold_domain') == domain
                                and bridge.get('purpose_constraints') == [purpose]
                                and bridge.get('bridge_endpoint') == websocket_origin + route,
                                'purpose_discovery_binding_mismatch')
                return {'readiness': True, 'build_matches': True, 'login_surface': True,
                        'unauthenticated_porthole_denied': True, 'selected_purpose_discovery': True}
            except (Rejected, OSError, http.client.HTTPException, ValueError):
                if attempt + 1 == attempts:
                    raise Rejected('local_functional_acceptance_failed') from None
                self.system.pause()
        raise Rejected('local_functional_acceptance_failed')

    def receipt(self, container, checks):
        return {'schema': RECEIPT_SCHEMA, 'status': 'ready', 'instance': self.request['instance'],
            'image': self.request['image'], 'platform': self.request['platform'], 'profile': PROFILE,
            'purposes': self.request['purposes'], 'container_id': container['Id'],
            'url': 'http://127.0.0.1:' + str(self.request['listen_port']), 'public_origin': self.request['public_origin'],
            'public_tls_verified': False, 'build': self.state['build'],
            'manifest_sha256': self.state['enrollment']['manifestSHA256'], 'checks': checks, 'verified_at': stamp()}

    def execute(self, request):
        existing = self.preflight(request)
        if request['operation'] == 'preflight':
            return {'schema': RECEIPT_SCHEMA, 'status': 'preflight-ready', 'instance': request['instance'], 'writes': False}
        if request['operation'] == 'status':
            require(existing is not None and existing['State'].get('Running') is True and self.state.get('phase') == 'ready', 'instance_not_ready')
            require(existing['HostConfig']['RestartPolicy']['Name'] == 'unless-stopped', 'container_restart_policy_conflict')
            return self.receipt(existing, self.health(attempts=1))
        image_id, build = self.image_metadata()
        # Serialize before preparing any key or enrollment state. Root-owned
        # base lock protects initialization as well as the per-generation lock.
        for path in (ROOT.parent, ROOT):
            mkdir(path)
        lock_path = ROOT / '.installation.lock'
        global_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        info = os.fstat(global_fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == ROOT_UID and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600, 'unsafe_global_lock')
        local_fd = None
        started = None
        self.pending_canonical = None
        try:
            try:
                fcntl.flock(global_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Rejected('installation_busy') from None
            # Recheck after acquiring the writer lock.
            self.state = self.load(self.instance)
            if self.state:
                require(self.state['request'] == identity_request(request), 'instance_configuration_conflict')
            self.prepare(image_id, build)
            local_fd = self.lock()
            if self.state.get('phase') == 'ready':
                container = self.system.container('sprout-' + request['instance'])
                require(container is not None, 'instance_container_missing')
                self.verify_container(container, 'service')
                if container['State'].get('Running') is True and container['HostConfig']['RestartPolicy']['Name'] == 'unless-stopped':
                    return self.receipt(container, self.health(attempts=1))
                # A repeat install may restart this exact, previously accepted
                # generation. It never rebuilds or replaces its owner or keys.
                started = container['Id']
                if container['State'].get('Running') is not True:
                    self.system.docker('start', started)
                checks = self.health()
                self.system.docker('update', '--restart', 'unless-stopped', started)
                result = self.receipt(container, dict(checks, restart_verified=True))
                atomic_write(self.instance / 'receipt.json', canonical_json(result), replace=True)
                return result
            # A killed earlier coordinator may have left its provisional
            # container running. Track only exactly verified owned containers
            # before any later operation can fail, so failure leaves them idle.
            provisional = self.system.container('sprout-' + request['instance'])
            if provisional:
                self.verify_container(provisional, 'service')
                started = provisional['Id']
            canonical = self.system.container('sprout-' + request['instance'] + '-provision')
            if canonical:
                self.verify_container(canonical, 'canonical')
                self.pending_canonical = canonical['Id']
            binary = self.extract()
            self.enroll(binary, local_fd)
            self.provision()
            container = self.ensure_container('service')
            started = container['Id']
            if container['State'].get('Running') is not True:
                self.system.docker('start', started)
            checks = self.health()
            # Restart only this newly created, proven generation. Then verify
            # persisted state under normal require-existing startup a second time.
            self.system.docker('restart', '--time', '30', started)
            checks = self.health()
            self.system.docker('update', '--restart', 'unless-stopped', started)
            self.state['phase'] = 'ready'
            result = self.receipt(container, dict(checks, restart_verified=True))
            atomic_write(self.instance / 'receipt.json', canonical_json(result), replace=True)
            self.save()
            return result
        except BaseException:
            if self.pending_canonical:
                try:
                    current = self.system.container(self.pending_canonical)
                    if current:
                        self.verify_container(current, 'canonical')
                        if current.get('State', {}).get('Running') is True:
                            self.system.docker('stop', '--time', '30', self.pending_canonical)
                except Exception:
                    pass
            if started:
                # Safe rollback concerns only the exact container created for
                # this generation. Preserve every key, file and failed container.
                try:
                    current = self.system.container(started)
                    if current:
                        self.verify_container(current, 'service')
                        self.system.docker('update', '--restart', 'no', started)
                        self.system.docker('stop', '--time', '30', started)
                except Exception:
                    pass
            raise
        finally:
            if local_fd is not None:
                os.close(local_fd)
            os.close(global_fd)


def main():
    os.umask(0o077)
    try:
        request = request_document(decode(sys.stdin.buffer.read(MAX_JSON + 1)))
        result = Coordinator().execute(request)
        print(json.dumps(result, sort_keys=True))
        return 0
    except Rejected as error:
        print(json.dumps({'schema': RECEIPT_SCHEMA, 'status': 'failed', 'reason': error.reason,
                          'existing_keys_preserved': True, 'public_tls_verified': False}, sort_keys=True))
        return 2
    except (Exception, KeyboardInterrupt):
        # Never print subprocess output, environment values, tracebacks or keys.
        print(json.dumps({'schema': RECEIPT_SCHEMA, 'status': 'failed', 'reason': 'operation_failed_preserve_generation',
                          'existing_keys_preserved': True, 'public_tls_verified': False}, sort_keys=True))
        return 2


if __name__ == '__main__':
    sys.exit(main())
