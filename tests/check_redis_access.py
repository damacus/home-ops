"""Exercise the rendered Redis startup, ACLs and AOF with dummy credentials."""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'kubernetes/apps/database/redis/app'
USERS = ('default', 'paperless', 'n8n', 'penpot')
PASSWORDS = {user: f'isolated-{user}-password' for user in USERS}


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if check and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


def main() -> None:
    values = yaml.safe_load((APP / 'helmrelease.yaml').read_text())['spec']['values']
    template = yaml.safe_load((APP / 'externalsecret.yaml').read_text())['spec']['target']['template']['data']['users.acl']
    fields = {f'{user}_password': password for user, password in PASSWORDS.items() if user != 'default'}
    fields['admin_password'] = PASSWORDS['default']
    acl = re.sub(r'{{\s*\.(\w+)\s*\|\s*sha256sum\s*}}', lambda match: hashlib.sha256(fields[match[1]].encode()).hexdigest(), template)
    assert '{{' not in acl, 'Unresolved ACL template'
    image = f"registry-1.docker.io/bitnami/redis@{values['image']['digest']}"
    with tempfile.TemporaryDirectory(prefix='redis-access-') as temporary:
        directory = Path(temporary)
        directory.chmod(0o755)
        (directory / 'values.yaml').write_text(yaml.safe_dump(values))
        chart = os.environ.get('REDIS_TEST_CHART', 'oci://registry-1.docker.io/bitnamicharts/redis')
        rendered = run('helm', 'template', 'redis', chart, '--version', '28.2.0', '-f', str(directory / 'values.yaml')).stdout
        resources = list(yaml.safe_load_all(rendered))
        workload = next(item for item in resources if item.get('kind') == 'StatefulSet' and item['metadata']['name'] == 'redis-master')
        watched = workload['metadata'].get('annotations', {}).get('secret.reloader.stakater.com/reload', '')
        assert 'redis-auth' in watched.split(','), 'Redis must roll out when its external ACL Secret changes'
        config = next(item['data'] for item in resources if item.get('kind') == 'ConfigMap' and item['metadata']['name'] == 'redis-configuration')
        scripts = next(item['data'] for item in resources if item.get('kind') == 'ConfigMap' and item['metadata']['name'] == 'redis-scripts')
        for name in ('redis.conf', 'master.conf'):
            (directory / name).write_text(config[name])
        (directory / 'start-master.sh').write_text(scripts['start-master.sh'])
        (directory / 'start-master.sh').chmod(0o755)
        (directory / 'users.acl').write_text(acl)
        (directory / 'admin_password').write_text(PASSWORDS['default'])
        data = directory / 'data'
        data.mkdir(mode=0o777)
        data.chmod(0o777)
        container = ''
        def start() -> str:
            return run('docker', 'run', '-d', '--entrypoint', '/bin/bash',
                '-e', 'REDIS_PORT=6379', '-e', 'REDIS_PASSWORD_FILE=/test/admin_password',
                '-v', f'{directory}:/test:ro', '-v', f'{data}:/data',
                '-v', f'{directory}/redis.conf:/opt/bitnami/redis/mounted-etc/redis.conf:ro',
                '-v', f'{directory}/master.conf:/opt/bitnami/redis/mounted-etc/master.conf:ro',
                '-v', f'{directory}/users.acl:/opt/bitnami/redis/acl/users.acl:ro',
                image, '-ec', '/test/start-master.sh').stdout.strip()
        def cli(user: str | None, *command: str, password: str | None = None) -> str:
            credentials = [] if user is None else ['-e', f'REDISCLI_AUTH={password or PASSWORDS[user]}']
            arguments = [] if user is None else ['--user', user]
            result = run('docker', 'exec', *credentials, container, 'redis-cli', '--raw', *arguments, *command, check=False)
            return (result.stdout + result.stderr).strip()
        def ready() -> None:
            for _ in range(40):
                if cli('default', 'PING') == 'PONG':
                    return
                time.sleep(0.2)
            logs = run('docker', 'logs', container, check=False)
            raise RuntimeError(logs.stdout + logs.stderr)
        try:
            container = start()
            ready()
            assert 'NOAUTH' in cli(None, 'PING'), 'Anonymous access permitted'
            print('PASS: anonymous access rejected')
            for user in USERS[1:]:
                assert 'WRONGPASS' in cli(user, 'PING', password='wrong-password')
                assert cli(user, 'PING') == 'PONG'
                assert cli(user, 'SET', f'{user}:test', 'payload') == 'OK'
                assert cli(user, 'GET', f'{user}:test') == 'payload'
                assert cli(user, 'RPUSH', f'{user}:queue', 'job') == '1'
                assert cli(user, 'BLPOP', f'{user}:queue', '1').splitlines() == [f'{user}:queue', 'job']
                assert cli(user, 'EVAL', "return redis.call('GET', KEYS[1])", '1', f'{user}:test') == 'payload'
                assert cli(user, 'PUBLISH', f'{user}:events', 'event').isdigit()
                for command in [('CONFIG', 'GET', 'maxmemory'), ('ACL', 'WHOAMI')]:
                    assert 'NOPERM' in cli(user, *command), (user, command)
                for command in [('FLUSHALL',), ('FLUSHDB',), ('SHUTDOWN',), ('MODULE', 'LIST'), ('CONFIG', 'SET', 'maxmemory', '0')]:
                    response = cli('default', 'ACL', 'DRYRUN', user, *command).lower()
                    disabled_flush = command[0] in {'FLUSHALL', 'FLUSHDB'} and "not found" in response
                    assert 'no permissions' in response or disabled_flush, (user, command, response)
                for command in [('CLIENT', 'SETNAME', 'test'), ('CLIENT', 'SETINFO', 'LIB-NAME', 'test'), ('SCRIPT', 'LOAD', 'return 1'), ('SUBSCRIBE', f'{user}:events'), ('PSUBSCRIBE', f'{user}:*'), ('MULTI',), ('EXEC',)]:
                    assert cli('default', 'ACL', 'DRYRUN', user, *command) == 'OK', (user, command)
                print(f'PASS: {user} authentication, queue, Lua and pub/sub permissions; admin commands denied')
            assert cli('default', 'CONFIG', 'GET', 'maxmemory-policy').splitlines()[-1] == 'noeviction'
            assert cli('default', 'CONFIG', 'GET', 'maxmemory').splitlines()[-1] == '33554432'
            assert cli('default', 'SET', 'persistence:test', 'survives') == 'OK'
            old_password = PASSWORDS['n8n']
            PASSWORDS['n8n'] = 'isolated-rotated-n8n-password'
            rotated_acl = acl.replace(hashlib.sha256(old_password.encode()).hexdigest(), hashlib.sha256(PASSWORDS['n8n'].encode()).hexdigest())
            (directory / 'users.acl').write_text(rotated_acl)
            assert 'WRONGPASS' in cli('n8n', 'PING'), 'Mounted file updates alone must not be mistaken for ACL reload'
            assert cli('n8n', 'PING', password=old_password) == 'PONG'
            run('docker', 'stop', container)
            run('docker', 'rm', container)
            container = start()
            ready()
            assert cli('default', 'GET', 'persistence:test') == 'survives'
            assert cli('n8n', 'PING') == 'PONG'
            assert 'WRONGPASS' in cli('n8n', 'PING', password=old_password)
            print('PASS: rotated password accepted and previous password rejected after rollout')
            print('PASS: bounded memory, noeviction and AOF survives container replacement')
        finally:
            if container:
                run('docker', 'rm', '-f', container, check=False)


if __name__ == '__main__':
    main()
