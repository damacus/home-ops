#!/usr/bin/env python3
"""Check pinned Cinc/PG18 migrations in disposable Docker containers; no cluster writes."""
import subprocess
import time

from pathlib import Path
import json
import uuid

ROOT = Path(__file__).resolve().parents[1]

def manifest(path: str) -> dict:
    return json.loads(subprocess.check_output([
        "ruby", "-ryaml", "-rjson", "-e",
        "puts JSON.generate(YAML.load_file(ARGV[0]))", str(ROOT / path),
    ], text=True))

PG = manifest("kubernetes/apps/dev/cinc-registry-db/app/cluster.yaml")["spec"]["imageName"]
image = manifest("kubernetes/apps/dev/cinc-registry/app/helmrelease.yaml")["spec"]["values"]["controllers"]["api"]["containers"]["app"]["image"]
APP = image["repository"] + ":" + image["tag"]
network = "cinc-pg18-smoke-" + uuid.uuid4().hex[:12]
name = network

def run(*args, **kwargs):
    return subprocess.run(['docker', *args], text=True, capture_output=True, check=True, **kwargs)

run('network','create',network)
started=False
try:
    run('run','-d','--name',name,'--network',network,PG,'sh','-ec',
        'initdb -D /tmp/cinc-pg --auth=trust >/dev/null; exec postgres -D /tmp/cinc-pg -h 0.0.0.0')
    started=True
    for _ in range(40):
        try:
            run('exec',name,'pg_isready','-U','postgres')
            break
        except subprocess.CalledProcessError:
            time.sleep(0.5)
    run('exec','-i',name,'psql','-U','postgres','-v','ON_ERROR_STOP=1',input=
        'CREATE ROLE cinc_sm_owner LOGIN; CREATE ROLE cinc_sm_runtime LOGIN; CREATE DATABASE cinc_supermarket OWNER cinc_sm_owner;')
    dsn='postgres://cinc_sm_owner@127.0.0.1:5432/cinc_supermarket?sslmode=disable'
    result=run('run','--rm','--network','container:'+name,'--read-only','-e','CINC_SM_MIGRATION_DATABASE_URL='+dsn,
        '-e','CINC_SM_ARTIFACT_STORE_ENABLED=false',APP,'migrate')
    print('PASS: application migrations on pinned PostgreSQL 18 image')
    result=run('run','--rm','--network','container:'+name,'--read-only','-e','CINC_SM_DATABASE_URL='+dsn.replace('cinc_sm_owner','cinc_sm_runtime'),
        '-e','CINC_SM_ARTIFACT_STORE_ENABLED=false',APP,'generate-universe')
    print('PASS: initial universe generation using runtime account')
    result=run('exec',name,'psql','-U','postgres','-d','cinc_supermarket','-Atc',
        "SELECT has_table_privilege('cinc_sm_runtime','audit_events','INSERT'), has_table_privilege('cinc_sm_runtime','audit_events','DELETE'), has_table_privilege('cinc_sm_runtime','packages','DELETE');")
    assert result.stdout.strip()=='t|f|f',result.stdout
    print('PASS: runtime audit insertion allowed; audit/catalogue deletion denied')
except subprocess.CalledProcessError as e:
    print(e.stdout)
    print(e.stderr)
    raise
finally:
    if started: run('rm','-f',name)
    run('network','rm',network)
