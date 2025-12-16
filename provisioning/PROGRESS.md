# Provisioning Progress Tracker

## Overview

This file tracks the progress of implementing and verifying the K3s node provisioning requirements.

**Last Updated:** 2025-12-16
**Target Board:** Rock 5B+ (priority), Raspberry Pi 5

## Requirements Summary

| Category | Total | Passing | Failing |
|----------|-------|---------|---------|
| cloud-init | 5 | 0 | 5 |
| user | 2 | 0 | 2 |
| ssh | 3 | 0 | 3 |
| system | 5 | 0 | 5 |
| kernel | 4 | 0 | 4 |
| k3s | 5 | 0 | 5 |
| nfs | 3 | 0 | 3 |
| storage | 2 | 0 | 2 |
| init | 2 | 0 | 2 |
| boot | 3 | 0 | 3 |
| **Total** | **34** | **0** | **34** |

## Test Profiles

### Gold Image Tests (pre-boot)

Run against the built image before first boot:

```bash
task provisioning:test-cloud-init image=<path-to-image> profile=gold
```

Requirements tested:

- REQ-CLOUD-001 through REQ-CLOUD-005
- REQ-SSH-003 (host keys removed)
- REQ-SYSTEM-001 (machine-id cleared)
- REQ-K3S-001 through REQ-K3S-005
- REQ-NFS-001, REQ-NFS-002
- REQ-INIT-001, REQ-INIT-002

### Running System Tests (post-boot)

Run against a booted node after cloud-init completes:

```bash
task provisioning:audit host=<ip-address>
```

Requirements tested:

- REQ-USER-001, REQ-USER-002
- REQ-SSH-001, REQ-SSH-002, REQ-SSH-003 (keys generated)
- REQ-SYSTEM-002 through REQ-SYSTEM-005
- REQ-KERNEL-001 through REQ-KERNEL-004
- REQ-NFS-003
- REQ-STORAGE-001, REQ-STORAGE-002
- REQ-BOOT-001 through REQ-BOOT-003

## Next Steps

1. [ ] Build Rock 5B+ gold image with `task provisioning:build board=rock5b`
2. [ ] Run gold image tests in Lima VM
3. [ ] Flash image to hardware and boot
4. [ ] Run running system tests
5. [ ] Mark passing requirements in `requirements.json`

## Session Notes

### 2025-12-16

- Consolidated `features/cloud-init.json` into `requirements.json`
- Added `passes: false` field to all 34 requirements
- Updated InSpec profiles to use requirement IDs (REQ-XXX-NNN)
- Updated `inspec-gold` and `inspec-running` controls
- Deleted redundant `features/` directory

## How to Update Progress

Use `jq` to update the `passes` field in `requirements.json`:

```bash
# Mark a single requirement as passing
jq '(.requirements[] | select(.id == "REQ-CLOUD-001")).passes = true' \
  provisioning/requirements.json | sponge provisioning/requirements.json

# Count passing requirements
jq '[.requirements[] | select(.passes == true)] | length' provisioning/requirements.json
```
