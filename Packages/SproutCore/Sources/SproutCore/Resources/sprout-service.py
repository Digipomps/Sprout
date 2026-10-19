#!/usr/bin/python3
"""Root-only fixed web/Admin/node stack coordinator, embedded in Sprout.

One bounded typed request authorizes exact publisher-verified OCI digests.
Commands, mounts, environment and resource limits are fixed here, never catalog
scripts. Admin and web have independent strict owner ceremonies and vaults.
Admin TLS and actual fresh signed sidecar telemetry precede web provisioning.
Existing keys survive every failure; unknown Admin writes recover verify-only.
Only an exact legacy web generation at phase=enrolled may gain this stack via
its durable explicit upgrade journal. No general image/config/owner migration.
Status is read-only. Public web TLS/end-user authority require separate tests.
"""
from __future__ import annotations

import base64
import copy
import datetime as dt
import errno
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

ROOT = Path('/var/lib/haven-sprout')
LEGACY_ROOT = Path('/var/lib/haven/sprout')
ROOT_UID = 0
ROOT_GID = 0
RUNTIME_UID = 995
RUNTIME_GID = 995
PROFILE = 'cellscaffold-web-v1'  # Read-only verification of an enrolled v0.3.1 generation.
STACK_PROFILE = 'cellscaffold-web-stack-v1'
ADMIN_UID = ADMIN_GID = 65532
NODE_UID = NODE_GID = 65531
RESOURCE_LIMITS = {'web': 'memory=2g,cpus=2,pids=512',
                   'admin': 'memory=1g,cpus=1,pids=256', 'node': 'memory=256m,cpus=0.25,pids=64'}
STACK_FIELDS = {'admin_image', 'node_image', 'admin_public_origin', 'admin_listen_port',
                'catalog_publisher', 'catalog_sha256_b64url', 'catalog_id', 'catalog_domain', 'resource_limits'}
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
    require(set(value) <= minimal | install | STACK_FIELDS, 'unknown_request_field')
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
    require(value['platform'] in ('linux/amd64', 'linux/arm64') and value['profile'] in (PROFILE, STACK_PROFILE), 'unsupported_profile')
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
    if value['profile'] == STACK_PROFILE:
        require(STACK_FIELDS <= set(value), 'incomplete_stack_request')
        for key in ('admin_image', 'node_image'):
            probe = dict(result, profile=PROFILE, image=value[key])
            for field in STACK_FIELDS: probe.pop(field, None)
            request_document(probe)
        require(len({value['image'], value['admin_image'], value['node_image']}) == 3, 'duplicate_stack_image')
        probe = dict(result, profile=PROFILE, public_origin=value['admin_public_origin'])
        for field in STACK_FIELDS: probe.pop(field, None)
        request_document(probe)
        require(value['admin_public_origin'] != value['public_origin'], 'admin_origin_not_distinct')
        require(type(value['admin_listen_port']) is int and 1024 <= value['admin_listen_port'] <= 65535
                and value['admin_listen_port'] != value['listen_port'], 'invalid_admin_port')
        require(all(isinstance(value[k], str) and TOKEN.fullmatch(value[k]) for k in ('catalog_publisher', 'catalog_sha256_b64url')),
                'invalid_catalog_authority')
        require(isinstance(value['catalog_id'], str) and 0 < len(value['catalog_id']) <= 256
                and all(ord(c) >= 32 for c in value['catalog_id']), 'invalid_catalog_id')
        require(isinstance(value['catalog_domain'], str) and len(value['catalog_domain']) <= 253
                and re.fullmatch(r'[a-z0-9]+(?:[.-][a-z0-9]+)*', value['catalog_domain']), 'invalid_catalog_domain')
        require(value['resource_limits'] == RESOURCE_LIMITS, 'unsupported_resource_limits')
    else:
        require(not (set(value) & STACK_FIELDS), 'legacy_request_has_stack_fields')
    return result


def identity_request(request):
    return {key: value for key, value in request.items() if key not in ('operation', 'schema')}


def same_stack_binding(first, second):
    # Signed catalogs are renewed, so their payload hash is evidence rather than
    # mutable service identity. Every other request field remains exact.
    return (first.get('profile') == second.get('profile') == STACK_PROFILE
            and {k: v for k, v in first.items() if k != 'catalog_sha256_b64url'}
            == {k: v for k, v in second.items() if k != 'catalog_sha256_b64url'})


def docker_run_timestamp(value):
    # Docker State timestamps use RFC3339Nano. Preserve nanoseconds in --since
    # boundaries; truncating to seconds could include the preceding run.
    require(isinstance(value, str), 'admin_run_timestamp_invalid')
    match = re.fullmatch(r'([2-9][0-9]{3}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.([0-9]{1,9}))?Z', value)
    require(match is not None, 'admin_run_timestamp_invalid')
    require(valid_timestamp(match[1] + 'Z'), 'admin_run_timestamp_invalid')
    return match[1], int((match[2] or '').ljust(9, '0'))


def validate_directory(path, uid=None, mode=None):
    uid = ROOT_UID if uid is None else uid
    info = os.lstat(path)
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == uid and not (info.st_mode & 0o022), 'unsafe_directory')
    if mode is not None:
        require(stat.S_IMODE(info.st_mode) == mode, 'unsafe_directory_mode')
    return info


def validate_runtime_ancestor(path):
    info = validate_directory(path)
    # setpriv clears supplementary groups. POSIX selects exactly one access
    # class; world r+x cannot compensate for a matching group's missing r+x.
    mask = (0o500 if info.st_uid == RUNTIME_UID else
            0o050 if info.st_gid == RUNTIME_GID else 0o005)
    require(info.st_mode & mask == mask, 'runtime_ancestor_inaccessible')


def verify_ancestors(path, runtime_access=False):
    require(path.is_absolute() and '..' not in path.parts and '.' not in path.parts, 'unsafe_path')
    cursor = Path('/')
    if runtime_access:
        validate_runtime_ancestor(cursor)
    for part in path.parts[1:]:
        cursor /= part
        if not cursor.exists() and not cursor.is_symlink():
            break
        if runtime_access:
            validate_runtime_ancestor(cursor)
        else:
            validate_directory(cursor)


def reject_legacy_instance(instance):
    # Never turn an old, partial or ambiguous generation into a fresh identity.
    # Inspect metadata only; the shared HAVEN parent may intentionally be 0700.
    verify_ancestors(LEGACY_ROOT)
    require(not os.path.lexists(LEGACY_ROOT / instance), 'legacy_instance_requires_explicit_recovery')


def storage_preflight(instance):
    verify_ancestors(ROOT.parent, runtime_access=True)
    require(ROOT.parent.is_dir(), 'service_parent_missing')
    for path in (ROOT, ROOT / instance):
        if os.path.lexists(path):
            info = validate_directory(path, mode=0o755)
            require(info.st_gid == ROOT_GID, 'unsafe_directory_group')
    reject_legacy_instance(instance)


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

    def admin_http(self, port, path, origin, token=None):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        headers = {'Host': urllib.parse.urlsplit(origin).netloc}
        if token is not None: headers['Authorization'] = 'Bearer ' + token
        try:
            connection.request('GET', path, headers=headers)
            response = connection.getresponse()
            body = response.read(MAX_JSON + 1)
            require(len(body) <= MAX_JSON, 'http_response_too_large')
            return response.status, dict(response.getheaders()), body
        finally: connection.close()

    def https(self, origin, path):
        url = urllib.parse.urlsplit(origin)
        connection = http.client.HTTPSConnection(url.hostname, url.port or 443, timeout=5)
        try:
            connection.request('GET', path)
            response = connection.getresponse()
            body = response.read(MAX_JSON + 1)
            require(len(body) <= MAX_JSON, 'http_response_too_large')
            return response.status, dict(response.getheaders()), body
        finally: connection.close()

    def port_free(self, port):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                # Closed TCP connections may retain TIME_WAIT after an owned
                # service stops. Test listener availability, not plain-bind reuse.
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(('127.0.0.1', port))
                probe.listen(1)
        except OSError as error:
            reason = 'listen_port_busy' if error.errno == errno.EADDRINUSE else 'listen_port_probe_failed'
            raise Rejected(reason) from None

    def pause(self):
        time.sleep(1)


def host_preflight(request):
    require(sys.platform == 'linux' and os.geteuid() == 0, 'linux_root_required')
    architecture = {'x86_64': 'linux/amd64', 'aarch64': 'linux/arm64'}.get(platform.machine())
    require(architecture is not None and request.get('platform', architecture) == architecture, 'unsupported_host_platform')
    for tool in (DOCKER, '/usr/bin/unshare', '/usr/bin/setpriv', '/usr/bin/openssl'):
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
        storage_preflight(request['instance'])
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

    def image_metadata(self, image=None, require_build_env=True):
        image = image or self.request['image']
        report = decode(self.system.docker('image', 'inspect', image))
        require(isinstance(report, list) and len(report) == 1, 'invalid_image_report')
        item = report[0]
        require(image in [normalize_image(x) for x in item.get('RepoDigests', [])]
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
        if require_build_env:
            require(environment.get('APP_BUILD_REVISION') == revision and environment.get('APP_BUILD_TIMESTAMP') == created, 'image_build_metadata_conflict')
        return item['Id'], {'app_revision': revision, 'build_timestamp': created}

    def reconcile_request(self, request):
        if self.state:
            require(self.state['request'] == identity_request(request), 'instance_configuration_conflict')

    def dependencies(self):
        pass

    def prepare(self, image_id, build):
        # All caller-selected paths end at the fixed, root-owned base.
        # Shared system parents are read-only prerequisites, never ours to chmod.
        mkdir(ROOT)
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
        # Shared system parents are read-only prerequisites, never ours to chmod.
        mkdir(ROOT)
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
            storage_preflight(request['instance'])
            self.state = self.load(self.instance)
            self.reconcile_request(request)
            self.prepare(image_id, build)
            local_fd = self.lock()
            if self.state.get('phase') == 'ready':
                self.dependencies()
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
            self.dependencies()
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


# The fixed loop checks the existing counter before EVERY invocation, including
# after a Docker restart. It never repairs/removes the file or rotates a key.
# NodeAdminAgent records the next sequence before attempting ingestion; gaps
# after a failed POST are safe, replay/reset is not. Exactly one owned container
# is permitted to mount this private state.
NODE_LOOP = r'''set -eu
umask 077
while :; do
  test -f /state/sequence && test ! -L /state/sequence || exit 72
  test "$(stat -c '%u:%g:%a:%h' /state/sequence)" = '65531:65531:600:1' || exit 72
  test "$(wc -c < /state/sequence)" -le 19 || exit 72
  read -r sequence < /state/sequence || exit 72
  case "$sequence" in ''|*[!0-9]*) exit 72;; esac
  case "$sequence" in 0|[1-9]*) :;; *) exit 72;; esac
  test "$sequence" -lt 900000000000000000 || exit 72
  /tools/NodeAdminAgent "$@" || exit 73
  sleep 60
done'''


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def private_http(system, port, path, origin, token=None):
    return system.admin_http(port, path, origin, token)


class StackCoordinator(Coordinator):
    """Three fixed signed roles; no generic upgrade, command or mount surface."""
    def old_view(self, state):
        view = Coordinator(self.system)
        view.instance = self.instance
        view.state = state
        view.request = request_document(dict(state['request'], schema=SCHEMA, operation='install'))
        return view

    def preserved_files(self):
        paths = [self.instance / 'auth.json']
        for directory in ('data', 'ceremony', 'runtime-secrets'):
            base = self.instance / directory
            for parent, dirs, files in os.walk(base, followlinks=False):
                for name in dirs:
                    require(not (Path(parent) / name).is_symlink(), 'unsafe_preserved_directory')
                paths.extend(Path(parent) / name for name in files)
        result = {}
        require(len(paths) <= 1024, 'preserved_state_too_large')
        for path in paths:
            info = path.lstat()
            require(info.st_uid in (ROOT_UID, RUNTIME_UID) and stat.S_ISREG(info.st_mode)
                    and not info.st_mode & 0o022 and info.st_nlink == 1, 'unsafe_preserved_file')
            blob = read_file(path, info.st_uid, (stat.S_IMODE(info.st_mode),), 16 << 20)
            result[str(path.relative_to(self.instance))] = {'sha256': digest(blob), 'uid': info.st_uid,
                'gid': info.st_gid, 'mode': stat.S_IMODE(info.st_mode)}
        return result

    def upgrade_contract(self, request):
        path = self.instance / 'stack-upgrade.json'
        journal = decode(read_file(path)) if os.path.lexists(path) else None
        old = journal['old_state'] if journal else self.state
        require(isinstance(old, dict) and old.get('phase') == 'enrolled'
                and old.get('canonical_complete') is not True and old.get('request', {}).get('profile') == PROFILE,
                'upgrade_requires_enrolled_legacy_generation')
        require(request.get('profile') == STACK_PROFILE, 'unsupported_upgrade')
        expected = dict(identity_request(request))
        for field in STACK_FIELDS: expected.pop(field)
        expected['profile'] = PROFILE
        require(old['request'] == expected
                and old.get('request_hash') == hashlib.sha256(canonical_json(old['request'])).hexdigest(),
                'upgrade_web_binding_conflict')
        require(self.state == old or (journal and self.state.get('request') == journal['new_request']
                and self.state.get('request_hash') == journal['new_request_hash']
                and all(self.state.get(k) == old.get(k) for k in ('generation', 'owner_uuid', 'enrollment_id', 'issued_at', 'build', 'image_id', 'enrollment'))),
                'upgrade_state_conflict')
        if journal:
            require(self.preserved_files() == journal['preserved_files'], 'upgrade_preserved_state_changed')
        view = self.old_view(old)
        view.validate_enrollment(old['enrollment'], read_file(self.instance / 'ceremony' / 'manifest.json', RUNTIME_UID))
        require(self.system.container('sprout-' + request['instance']) is None, 'upgrade_service_exists')
        name = 'sprout-' + request['instance'] + '-provision'
        archive = name + '-legacy-' + old['generation']
        candidate = self.system.container(journal['container_id'] if journal else name)
        require(candidate is not None and candidate.get('State', {}).get('Running') is False
                and candidate.get('State', {}).get('Status') in ('exited', 'created'), 'upgrade_requires_stopped_provision')
        view.verify_container(candidate, 'canonical')
        require(candidate.get('Name', '').lstrip('/') in (name, archive), 'upgrade_container_name_conflict')
        new_request = identity_request(request)
        new_hash = hashlib.sha256(canonical_json(new_request)).hexdigest()
        if journal:
            require(journal.get('schema') == 'haven.sprout.stack-upgrade.v1'
                    and same_stack_binding(journal['new_request'], new_request)
                    and journal['new_request_hash'] == hashlib.sha256(canonical_json(journal['new_request'])).hexdigest()
                    and journal['archive_name'] == archive and journal['container_id'] == candidate['Id'], 'upgrade_journal_conflict')
            require(self.preserved_files() == journal['preserved_files'], 'upgrade_preserved_state_changed')
        else:
            journal = {'schema': 'haven.sprout.stack-upgrade.v1', 'old_state': copy.deepcopy(old),
                'new_request': new_request, 'new_request_hash': new_hash, 'container_id': candidate['Id'],
                'archive_name': archive, 'preserved_files': self.preserved_files(), 'phase': 'prepared',
                'historical_publisher_continuity': 'not-recorded-by-legacy-client'}
        return journal, candidate

    def reconcile_request(self, request):
        if not self.state or same_stack_binding(self.state['request'], identity_request(request)):
            return
        journal, candidate = self.upgrade_contract(request)
        atomic_write(self.instance / 'stack-upgrade.json', canonical_json(journal))
        if candidate['Name'].lstrip('/') != journal['archive_name']:
            require(self.system.container(journal['archive_name']) is None, 'upgrade_archive_name_in_use')
            self.system.docker('rename', candidate['Id'], journal['archive_name'])
        archived = self.system.container(candidate['Id'])
        require(archived and archived['Name'].lstrip('/') == journal['archive_name'], 'upgrade_archive_unknown')
        self.old_view(journal['old_state']).verify_container(archived, 'canonical')
        original = self.instance / 'provision.env'
        retained = self.instance / 'legacy-provision.env'
        expected = ('\n'.join(k + '=' + v for k, v in sorted(self.old_view(journal['old_state']).environment_values(True).items())) + '\n').encode()
        if os.path.lexists(original):
            require(read_file(original) == expected and not os.path.lexists(retained), 'upgrade_environment_conflict')
            os.rename(original, retained)
            directory = os.open(self.instance, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try: os.fsync(directory)
            finally: os.close(directory)
        require(read_file(retained) == expected, 'upgrade_environment_conflict')
        require(self.preserved_files() == journal['preserved_files'], 'upgrade_preserved_state_changed')
        self.state['request'] = journal['new_request']
        self.state['request_hash'] = journal['new_request_hash']
        self.state['stack_upgrade'] = {'journal_sha256': digest(read_file(self.instance / 'stack-upgrade.json')),
                                     'archived_container_id': candidate['Id']}
        self.save()

    def preflight(self, request):
        host_preflight(request)
        storage_preflight(request['instance'])
        self.instance = ROOT / request['instance']
        self.state = self.load(self.instance)
        self.request = request
        if request['operation'] == 'status':
            require(self.state is not None, 'instance_not_installed')
            self.request = request_document(dict(self.state['request'], schema=SCHEMA, operation='install'))
        require(self.request.get('profile') == STACK_PROFILE, 'complete_stack_profile_required')
        if self.state and not same_stack_binding(self.state['request'], identity_request(self.request)):
            self.upgrade_contract(self.request)
        serving = self.system.container('sprout-' + request['instance'])
        if serving:
            require(self.state is not None, 'container_name_in_use')
            self.verify_container(serving, 'service')
        if request['operation'] != 'status' and (not serving or not serving.get('State', {}).get('Running')):
            self.system.port_free(self.request['listen_port'])
        for role in ('admin-enroll', 'admin-verify', 'admin', 'node'):
            container = self.system.container(self.member_name(role))
            if container:
                require(self.state is not None and 'stack' in self.state, 'dependency_container_name_in_use')
                self.verify_member(container, role, require_restart=request['operation'] == 'status')
                if role in ('admin-enroll', 'admin-verify'):
                    require(not container.get('State', {}).get('Running'), 'admin_ceremony_still_running')
        if request['operation'] == 'status':
            for role in ('admin', 'node'):
                member = self.system.container(self.member_name(role))
                require(member is not None and member.get('State', {}).get('Running') is True, 'dependency_not_running')
        admin = self.system.container(self.member_name('admin'))
        if request['operation'] != 'status' and (not admin or not admin.get('State', {}).get('Running')):
            self.system.port_free(self.request['admin_listen_port'])
        return serving

    def prepare(self, image_id, build):
        super().prepare(image_id, build)
        # This records the current caller-verified catalog without changing the
        # original request/container binding or the initial acceptance receipt.
        atomic_write(self.instance / 'catalog-verification.json', canonical_json({
            'schema': 'haven.sprout.catalog-verification.v1', 'publisher': self.request['catalog_publisher'],
            'domain': self.request['catalog_domain'], 'catalog_id': self.request['catalog_id'],
            'sha256_b64url': self.request['catalog_sha256_b64url'], 'observed_at': stamp()}), replace=True)
        if 'stack' not in self.state:
            admin_id, admin_build = self.image_metadata(self.request['admin_image'])
            node_id, node_build = self.image_metadata(self.request['node_image'], require_build_env=False)
            self.state['stack'] = {'phase': 'prepared', 'admin_owner_uuid': str(uuid.uuid4()),
                'admin_enrollment_id': str(uuid.uuid4()), 'issued_at': stamp(),
                'agent_uuid': str(uuid.uuid4()), 'agent_id': 'sprout-' + self.state['generation'],
                'node_id': 'sidecar-' + self.state['generation'], 'key_id': 'key-' + str(uuid.uuid4()),
                'client_id': 'web-' + self.state['generation'], 'channel_key_id': 'channel-' + str(uuid.uuid4()),
                'admin_image_id': admin_id, 'admin_build': admin_build, 'node_image_id': node_id, 'node_build': node_build}
            self.save()
        stack = self.state['stack']
        for role, uid, gid in [('admin-data', ADMIN_UID, ADMIN_GID), ('admin-secrets', ADMIN_UID, ADMIN_GID),
                               ('node-state', NODE_UID, NODE_GID), ('node-secrets', NODE_UID, NODE_GID)]:
            mkdir(self.instance / role, uid, gid, 0o700)
        if stack['phase'] == 'prepared':
            self.prepare_stack_secrets()
            stack['phase'] = 'secrets-ready'
            self.save()
        self.validate_stack_secrets()

    def secret_once(self, path, factory, uid, gid, mode=0o400):
        if not os.path.lexists(path): atomic_write(path, factory(), uid, gid, mode)
        return read_file(path, uid, (mode,))

    def prepare_stack_secrets(self):
        stack = self.state['stack']
        admin = self.instance / 'admin-secrets'
        node = self.instance / 'node-secrets'
        require(not os.path.lexists(self.instance / 'admin-data' / '.admin-owner-enrollment-v1.json'), 'uncheckpointed_admin_initialization')
        self.secret_once(admin / 'master-key', lambda: secrets.token_bytes(32), ADMIN_UID, ADMIN_GID)
        self.secret_once(admin / 'metrics-token', lambda: secrets.token_urlsafe(48).encode(), ADMIN_UID, ADMIN_GID)
        channel = self.secret_once(admin / 'channel-key', lambda: secrets.token_bytes(32), ADMIN_UID, ADMIN_GID)
        key_b64 = base64.b64encode(channel).decode()
        keyring = {'schemaVersion': 'haven.admin.bridge.keyring.v2', 'clientID': stack['client_id'],
            'activeKeyID': stack['channel_key_id'], 'keys': [{'keyID': stack['channel_key_id'], 'keyBase64': key_b64}]}
        # The exact keyring shape is validated again by Admin before serving.
        atomic_write(admin / 'bridge-keyring.json', canonical_json(keyring), ADMIN_UID, ADMIN_GID, 0o400)
        client = {'schemaVersion': 'haven.admin.bridge.client-credential.v1', 'clientID': stack['client_id'],
            'keyID': stack['channel_key_id'], 'keyBase64': key_b64}
        atomic_write(self.instance / 'runtime-secrets' / 'admin-client.json', canonical_json(client), RUNTIME_UID, RUNTIME_GID, 0o400)
        der = node / 'ed25519-private.der'
        if not os.path.lexists(der):
            code, out, _ = self.system.run(['/usr/bin/openssl', 'genpkey', '-algorithm', 'ED25519', '-outform', 'DER'])
            require(code == 0 and len(out) == 48 and out[:16].hex() == '302e020100300506032b657004220420', 'node_key_generation_failed')
            atomic_write(der, out, NODE_UID, NODE_GID, 0o400)
        private = read_file(der, NODE_UID, (0o400,))
        require(len(private) == 48 and private[:16].hex() == '302e020100300506032b657004220420', 'invalid_node_private_key')
        code, public, _ = self.system.run(['/usr/bin/openssl', 'pkey', '-inform', 'DER', '-in', str(der), '-pubout', '-outform', 'DER'])
        require(code == 0 and len(public) == 44 and public[:12].hex() == '302a300506032b6570032100', 'invalid_node_public_key')
        atomic_write(node / 'signing-key', b64url(private[16:]).encode(), NODE_UID, NODE_GID, 0o400)
        stack['agent_public_key'] = b64url(public[12:])
        trust = self.agent_trust()
        atomic_write(admin / 'trusted-agent.json', canonical_json(trust), ADMIN_UID, ADMIN_GID, 0o400)
        self.secret_once(self.instance / 'node-state' / 'sequence', lambda: b'0\n', NODE_UID, NODE_GID, 0o600)
        stack['node_key_sha256'] = digest(read_file(node / 'signing-key', NODE_UID, (0o400,)))

    def agent_trust(self):
        stack = self.state['stack']
        return {'agentIdentityUUID': stack['agent_uuid'], 'agentID': stack['agent_id'],
            'nodeID': stack['node_id'], 'scaffoldInstanceID': self.state['generation'],
            'keyID': stack['key_id'], 'publicKeyBase64URL': stack['agent_public_key']}

    def validate_stack_secrets(self):
        stack = self.state['stack']
        admin = self.instance / 'admin-secrets'
        require(len(read_file(admin / 'master-key', ADMIN_UID, (0o400,))) == 32, 'invalid_admin_master_key')
        token = read_file(admin / 'metrics-token', ADMIN_UID, (0o400,)).decode()
        require(re.fullmatch(r'[A-Za-z0-9_-]{64}', token), 'invalid_admin_metrics_token')
        channel = read_file(admin / 'channel-key', ADMIN_UID, (0o400,))
        require(len(channel) == 32, 'invalid_channel_key')
        key = base64.b64encode(channel).decode()
        client = decode(read_file(self.instance / 'runtime-secrets' / 'admin-client.json', RUNTIME_UID, (0o400,)))
        require(client == {'schemaVersion': 'haven.admin.bridge.client-credential.v1', 'clientID': stack['client_id'],
            'keyID': stack['channel_key_id'], 'keyBase64': key}, 'channel_credential_conflict')
        require(decode(read_file(admin / 'bridge-keyring.json', ADMIN_UID, (0o400,))) == {
            'schemaVersion': 'haven.admin.bridge.keyring.v2', 'clientID': stack['client_id'],
            'activeKeyID': stack['channel_key_id'], 'keys': [{'keyID': stack['channel_key_id'], 'keyBase64': key}]}, 'channel_keyring_conflict')
        require(decode(read_file(admin / 'trusted-agent.json', ADMIN_UID, (0o400,))) == self.agent_trust(), 'agent_trust_conflict')
        seed = read_file(self.instance / 'node-secrets' / 'signing-key', NODE_UID, (0o400,)).decode()
        require(TOKEN.fullmatch(seed) and digest(seed.encode()) == stack['node_key_sha256'], 'invalid_node_signing_key')
        self.node_sequence()

    def node_sequence(self):
        value = read_file(self.instance / 'node-state' / 'sequence', NODE_UID, (0o600,), 19)
        require(re.fullmatch(rb'(0|[1-9][0-9]{0,17})\n', value) and int(value) < 900000000000000000, 'node_sequence_invalid')
        return int(value)

    def member_name(self, role):
        return 'sprout-' + self.request['instance'] + '-' + role

    def environment_values(self, one_shot):
        values = super().environment_values(one_shot)
        values.update(DEVICE_CALLBACK_PUBLIC_ORIGIN=self.request['public_origin'],
            ADMIN_CONTROL_PLANE_MODE='remote_admin_scaffold', ADMIN_SCAFFOLD_PUBLIC_ORIGIN=self.request['admin_public_origin'],
            ADMIN_SCAFFOLD_BRIDGE_CLIENT_CREDENTIAL_PATH='/etc/haven/cellscaffold-runtime-secrets/admin-client.json')
        return values

    def member_spec(self, role):
        stack = self.state['stack']
        if role in ('admin', 'admin-enroll', 'admin-verify'):
            environment = {'VAPOR_ENV': 'production', 'ADMIN_SCAFFOLD_IDENTITY_PROFILE': 'strict_enrolled',
                'ADMIN_SCAFFOLD_STORAGE_ROOT': '/state', 'CELL_VAULT_DOCUMENT_ROOT': '/state',
                'CELL_VAULT_MASTER_KEY_PATH': '/secrets/master-key',
                'ADMIN_SCAFFOLD_OWNER_UUID': stack['admin_owner_uuid'], 'ADMIN_SCAFFOLD_OWNER_CONTEXT': 'AdminScaffold',
                'ADMIN_SCAFFOLD_ENROLLMENT_ID': stack['admin_enrollment_id'], 'ADMIN_SCAFFOLD_ENROLLMENT_ISSUED_AT': stack['issued_at'],
                'APP_BUILD_REVISION': stack['admin_build']['app_revision'],
                'ADMIN_SCAFFOLD_PUBLIC_ORIGIN': self.request['admin_public_origin'],
                'ADMIN_SCAFFOLD_BRIDGE_KEYRING_PATH': '/secrets/bridge-keyring.json',
                'ADMIN_SCAFFOLD_METRICS_BEARER_TOKEN_PATH': '/secrets/metrics-token',
                'ADMIN_SCAFFOLD_TRUSTED_AGENT_KEYS_PATH': '/secrets/trusted-agent.json',
                'ADMIN_SCAFFOLD_REQUIRE_TRUSTED_AGENT_KEY': 'true', 'ADMIN_SCAFFOLD_REQUIRE_FRESH_SNAPSHOT_FOR_READINESS': 'true',
                'ADMIN_SCAFFOLD_ALLOW_OWNER_CREATE': 'false'}
            if role == 'admin':
                receipt = stack['enrollment']
                environment['ADMIN_SCAFFOLD_OWNER_SIGNING_KEY_FINGERPRINT'] = receipt['owner']['signingKeyFingerprintDigest']
                environment['ADMIN_SCAFFOLD_ENROLLMENT_JOURNAL_SHA256'] = receipt['journalSHA256']
            return {'image': self.request['admin_image'], 'image_id': stack['admin_image_id'], 'uid': '65532:65532',
                'network': 'bridge' if role == 'admin' else 'none',
                'entrypoint': '/app/AdminScaffold' if role == 'admin' else '/app/AdminScaffoldBootstrap',
                'command': (['serve', '--env', 'production', '--hostname', '0.0.0.0', '--port', '8082'] if role == 'admin' else ['verify-owner' if role == 'admin-verify' else 'enroll-first-owner']),
                'env': environment, 'mounts': [str(self.instance / 'admin-data') + ':/state:rw', str(self.instance / 'admin-secrets') + ':/secrets:ro'],
                'ports': {} if role != 'admin' else {'8082/tcp': [{'HostIp': '127.0.0.1', 'HostPort': str(self.request['admin_listen_port'])}]},
                'memory': '1g', 'memory_bytes': 1073741824, 'cpus': '1', 'nanocpus': 1000000000, 'pids': 256}
        args = ['--signed-envelope', '--agent-id', stack['agent_id'], '--node-id', stack['node_id'],
            '--scaffold-instance-id', self.state['generation'], '--build-revision', stack['node_build']['app_revision'],
            '--environment', 'production', '--signing-key-path', '/secrets/signing-key', '--signing-key-id', stack['key_id'],
            '--agent-identity-uuid', stack['agent_uuid'], '--sequence-file', '/state/sequence', '--require-existing-sequence-file', '--ttl-seconds', '300',
            '--ingest-url', self.request['admin_public_origin'] + '/v1/node-snapshots', '--output', '/state/latest.json', '--compact']
        return {'image': self.request['node_image'], 'image_id': stack['node_image_id'], 'uid': '65531:65531', 'network': 'bridge',
            'entrypoint': '/bin/sh', 'command': ['-c', NODE_LOOP, 'sprout-node-loop', *args], 'env': {},
            'mounts': [str(self.instance / 'node-state') + ':/state:rw', str(self.instance / 'node-secrets') + ':/secrets:ro'],
            'ports': {}, 'memory': '256m', 'memory_bytes': 268435456, 'cpus': '0.25', 'nanocpus': 250000000, 'pids': 64}

    def verify_member(self, container, role, require_restart=False):
        expected = self.member_spec(role)
        config = container.get('Config') or {}
        host = container.get('HostConfig') or {}
        labels = config.get('Labels') or {}
        require(container.get('Image') == expected['image_id'] and config.get('Image') == expected['image']
                and container.get('Name', '').lstrip('/') == self.member_name(role)
                and all(labels.get('org.haven.sprout.' + k) == v for k, v in {
                    'generation': self.state['generation'], 'request': self.state['request_hash'], 'phase': role}.items()), 'dependency_binding_conflict')
        require(config.get('User') == expected['uid'] and config.get('Entrypoint') == [expected['entrypoint']]
                and config.get('Cmd') == expected['command'] and host.get('NetworkMode') == expected['network']
                and host.get('Privileged') is False and host.get('CapDrop') == ['ALL']
                and not host.get('CapAdd') and not host.get('Devices') and not host.get('DeviceRequests')
                and host.get('PidMode', '') == '' and host.get('UsernsMode', '') == ''
                and host.get('ReadonlyRootfs') is True and host.get('SecurityOpt') == ['no-new-privileges:true']
                and host.get('Memory') == expected['memory_bytes'] and host.get('NanoCpus') == expected['nanocpus']
                and host.get('PidsLimit') == expected['pids'], 'dependency_security_conflict')
        require(sorted(host.get('Binds') or []) == sorted(expected['mounts']) and (host.get('PortBindings') or {}) == expected['ports']
                and (host.get('Tmpfs') or {}) == {'/tmp': 'rw,noexec,nosuid,size=16777216,mode=1777'}, 'dependency_mount_conflict')
        environment = dict(x.split('=', 1) for x in config.get('Env', []) if '=' in x)
        require(all(environment.get(k) == v for k, v in expected['env'].items())
                and not any(k in environment for k in ('CELL_VAULT_MASTER_KEY_B64', 'NODE_ADMIN_AGENT_SIGNING_PRIVATE_KEY_BASE64URL', 'NODE_ADMIN_AGENT_SEQUENCE')), 'dependency_environment_conflict')
        policy = host.get('RestartPolicy') or {}
        allowed = (('no',) if role in ('admin-enroll', 'admin-verify') else
                   ('unless-stopped',) if require_restart else ('no', 'unless-stopped'))
        require(policy.get('Name') in allowed
                and policy.get('MaximumRetryCount', 0) == 0, 'dependency_restart_conflict')
        return container

    def ensure_member(self, role):
        existing = self.system.container(self.member_name(role))
        if existing: return self.verify_member(existing, role)
        spec = self.member_spec(role)
        envpath = self.instance / (role + '.env')
        atomic_write(envpath, ('\n'.join(k + '=' + v for k, v in sorted(spec['env'].items())) + '\n').encode())
        args = ['create', '--name', self.member_name(role), '--user', spec['uid'], '--network', spec['network'],
            '--restart', 'no', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
            '--memory', spec['memory'], '--cpus', spec['cpus'], '--pids-limit', str(spec['pids']),
            '--log-opt', 'max-size=10m', '--log-opt', 'max-file=3', '--tmpfs', '/tmp:rw,noexec,nosuid,size=16777216,mode=1777',
            '--env-file', str(envpath)]
        for k, v in {'generation': self.state['generation'], 'request': self.state['request_hash'], 'phase': role}.items():
            args += ['--label', 'org.haven.sprout.' + k + '=' + v]
        for mount in spec['mounts']: args += ['--volume', mount]
        for port, binding in spec['ports'].items(): args += ['--publish', '127.0.0.1:' + binding[0]['HostPort'] + ':' + port.split('/')[0]]
        args += ['--entrypoint', spec['entrypoint'], spec['image'], *spec['command']]
        identifier = self.system.docker(*args).decode().strip()
        require(re.fullmatch(r'[0-9a-f]{64}', identifier), 'invalid_dependency_id')
        result = self.system.container(identifier)
        require(result and result['Id'] == identifier, 'dependency_creation_unknown')
        return self.verify_member(result, role)

    def validate_admin_receipt(self, receipt):
        stack = self.state['stack']
        require(isinstance(receipt, dict) and receipt.get('schemaVersion') == 'haven.admin.first-owner-receipt.v1'
            and receipt.get('status') == 'verified' and receipt.get('operation') in ('enroll-first-owner', 'verify-owner')
            and receipt.get('enrollmentID') == stack['admin_enrollment_id']
            and receipt.get('appRevision') == stack['admin_build']['app_revision'], 'invalid_admin_enrollment_receipt')
        owner = receipt.get('owner', {})
        require(owner.get('uuid') == stack['admin_owner_uuid'] and owner.get('context') == 'AdminScaffold'
            and TOKEN.fullmatch(owner.get('signingKeyFingerprintDigest', '')), 'admin_owner_pin_conflict')
        journal = read_file(self.instance / 'admin-data' / '.admin-owner-enrollment-v1.json', ADMIN_UID)
        require(receipt.get('journalSHA256') == hashlib.sha256(journal).hexdigest(), 'admin_journal_pin_conflict')

    def dependencies(self):
        self.validate_stack_secrets()
        stack = self.state['stack']
        if 'enrollment' not in stack:
            require(self.system.container(self.member_name('admin')) is None, 'admin_service_before_enrollment')
            # Checkpoint invocation before launching it. Any ambiguous outcome
            # may only use the native read-only verifier on a later invocation.
            role = 'admin-verify' if stack.get('ceremony_started') else 'admin-enroll'
            container = self.ensure_member(role)
            if not stack.get('ceremony_started'):
                stack['ceremony_started'] = True
                self.save()
            self.started_members[role] = container['Id']
            if container['State'].get('Status') == 'created' or container['State'].get('ExitCode') != 0:
                self.system.docker('start', container['Id'])
            active = self.system.container(container['Id'])
            require(active is not None, 'admin_run_unknown')
            self.verify_member(active, role)
            started = active.get('State', {}).get('StartedAt')
            start_time = docker_run_timestamp(started)
            require(self.system.docker('wait', container['Id'], timeout=240).strip() == b'0', 'admin_enrollment_unknown_verify_only')
            ended = self.system.container(container['Id'])
            require(ended is not None, 'admin_run_unknown')
            self.verify_member(ended, role)
            run = ended.get('State', {})
            require(run.get('StartedAt') == started and run.get('Running') is False
                    and run.get('Status') == 'exited' and run.get('ExitCode') == 0, 'admin_run_changed')
            finished = run.get('FinishedAt')
            require(docker_run_timestamp(finished) >= start_time, 'admin_run_timestamp_invalid')
            # Docker timestamps log lines during asynchronous pipe copying; a
            # final receipt may be recorded after the process exit timestamp.
            # Do not use FinishedAt as --until. The unchanged run-state check
            # below rejects a later invocation contributing any output.
            output = self.system.docker('logs', '--since', started, container['Id'])
            after_logs = self.system.container(container['Id'])
            require(after_logs is not None and after_logs.get('State') == run, 'admin_run_changed')
            self.verify_member(after_logs, role)
            receipt = decode(output)
            require(receipt.get('operation') == ('verify-owner' if role == 'admin-verify' else 'enroll-first-owner'), 'admin_operation_mismatch')
            self.validate_admin_receipt(receipt)
            stack['enrollment'] = receipt
            stack['phase'] = 'enrolled'
            self.save()
        self.validate_admin_receipt(stack['enrollment'])
        for role in ('admin', 'node'):
            container = self.ensure_member(role)
            if not container.get('State', {}).get('Running') or self.state['phase'] != 'ready':
                self.started_members[role] = container['Id']
            if not container.get('State', {}).get('Running'):
                self.system.docker('start', container['Id'])
            if role == 'admin':
                self.admin_started()
        # Start the real signer before requiring freshness; otherwise readiness
        # would deadlock on the very first snapshot it is supposed to receive.
        self.admin_health()
        for role in ('admin', 'node'):
            container = self.system.container(self.member_name(role))
            self.verify_member(container, role)
            self.system.docker('update', '--restart', 'unless-stopped', container['Id'])
            require(self.system.container(container['Id'])['HostConfig']['RestartPolicy']['Name'] == 'unless-stopped', 'dependency_restart_conflict')
        stack['phase'] = 'ready'
        self.save()

    def admin_started(self, attempts=60):
        # Initial readiness needs telemetry. Wait only for the initialized HTTP
        # listener before launching the signer, never for final ready=true here.
        for attempt in range(attempts):
            try:
                code, _, data = private_http(self.system, self.request['admin_listen_port'], '/health/startup', self.request['admin_public_origin'])
                require(code == 200 and decode(data).get('status') == 'started', 'admin_not_started')
                return
            except (Rejected, OSError, http.client.HTTPException, ValueError):
                if attempt + 1 == attempts: raise Rejected('admin_startup_failed') from None
                self.system.pause()

    def admin_health(self, attempts=90):
        stack = self.state['stack']
        token = read_file(self.instance / 'admin-secrets' / 'metrics-token', ADMIN_UID, (0o400,)).decode()
        for attempt in range(attempts):
            try:
                for role in ('admin', 'node'):
                    container = self.system.container(self.member_name(role))
                    require(container and container.get('State', {}).get('Running'), 'stack_member_not_running')
                    self.verify_member(container, role)
                sequence = self.node_sequence()
                require(sequence > 0, 'node_snapshot_missing')
                code, _, data = private_http(self.system, self.request['admin_listen_port'], '/health/restore-audit', self.request['admin_public_origin'], token)
                audit = decode(data)
                require(code == 200 and audit.get('schemaVersion') == 'haven.admin.restore-audit.v1'
                        and audit.get('ownerUUID') == stack['admin_owner_uuid']
                        and audit.get('ownerSigningKeyFingerprint') == stack['enrollment']['owner']['signingKeyFingerprintDigest']
                        and audit.get('activeTrustedAgentKeyCount') == 1 and audit.get('persistenceStatus') == 'healthy'
                        and isinstance(audit.get('latestSnapshotAcceptedAt'), (float, int))
                        and 0 <= time.time() - audit['latestSnapshotAcceptedAt'] <= 300, 'admin_owner_audit_failed')
                code, _, data = private_http(self.system, self.request['admin_listen_port'], '/health/ready', self.request['admin_public_origin'])
                ready = decode(data)
                require(code == 200 and ready.get('status') == 'ready'
                        and ready.get('trustedAgentKeyPolicy') == 'required' and ready.get('freshSnapshotPolicy') == 'required'
                        and ready.get('activeTrustedAgentKeyCount') == 1 and ready.get('freshRecordCount') == 1
                        and ready.get('publicOriginReady') is True and ready.get('bridgeReady') is True, 'admin_not_ready')
                code, _, data = self.system.https(self.request['admin_public_origin'], '/health/ready')
                require(code == 200 and decode(data).get('status') == 'ready', 'admin_public_tls_not_ready')
                code, _, data = self.system.https(self.request['admin_public_origin'], '/health/build')
                build = decode(data)
                require(code == 200 and all(build.get(k) == v for k, v in stack['admin_build'].items())
                        and build.get('environment') == 'production', 'admin_build_mismatch')
                self.last_admin_audit = {'owner_uuid': audit['ownerUUID'], 'owner_fingerprint': audit['ownerSigningKeyFingerprint'],
                    'active_trusted_agent_keys': audit['activeTrustedAgentKeyCount'], 'latest_snapshot_accepted_at': audit.get('latestSnapshotAcceptedAt'),
                    'observed_sequence': sequence, 'public_tls_verified': True, 'scope': 'dedicated-sidecar-no-host-collector'}
                return self.last_admin_audit
            except (Rejected, OSError, http.client.HTTPException, ValueError):
                if attempt + 1 == attempts: raise Rejected('admin_functional_acceptance_failed') from None
                self.system.pause()

    def health(self, attempts=90):
        self.admin_health(attempts)
        return dict(super().health(attempts), admin_ready=True, signed_node_snapshot_ready=True)

    def receipt(self, container, checks):
        result = super().receipt(container, checks)
        result['profile'] = STACK_PROFILE
        result['generation'] = self.state['generation']
        result['owner_uuid'] = self.state['owner_uuid']
        result['catalog_publisher'] = self.request['catalog_publisher']
        result['catalog_sha256_b64url'] = self.request['catalog_sha256_b64url']
        result['catalog_domain'] = self.request['catalog_domain']
        result['catalog_id'] = self.request['catalog_id']
        result['initial_catalog_sha256_b64url'] = self.state['request']['catalog_sha256_b64url']
        result['request_sha256'] = self.state['request_hash']
        result['resource_limits'] = RESOURCE_LIMITS
        result['admin'] = dict(self.last_admin_audit, image=self.request['admin_image'],
            public_origin=self.request['admin_public_origin'], listen_port=self.request['admin_listen_port'],
            build=self.state['stack']['admin_build'], container_id=self.system.container(self.member_name('admin'))['Id'])
        result['node'] = {'image': self.request['node_image'], 'build': self.state['stack']['node_build'],
            'container_id': self.system.container(self.member_name('node'))['Id'], 'agent': self.agent_trust()}
        return result

    def execute(self, request):
        self.started_members = {}
        try:
            result = super().execute(request)
            return result
        except BaseException:
            for role, identifier in reversed(list(self.started_members.items())):
                try:
                    current = self.system.container(identifier)
                    if current:
                        self.verify_member(current, role)
                        self.system.docker('update', '--restart', 'no', identifier)
                        if current.get('State', {}).get('Running'):
                            self.system.docker('stop', '--time', '30', identifier)
                except Exception: pass
            raise

def main():
    os.umask(0o077)
    try:
        request = request_document(decode(sys.stdin.buffer.read(MAX_JSON + 1)))
        require(request['operation'] == 'status' or request.get('profile') == STACK_PROFILE, 'complete_stack_profile_required')
        result = StackCoordinator().execute(request)
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
