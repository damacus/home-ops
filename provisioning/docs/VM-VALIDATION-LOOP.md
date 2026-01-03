# VM-based Cloud-Init Validation Loop

## Purpose

Fast iteration on cloud-init and k3s-init provisioning logic without flashing physical hardware (RPi5, Rock5B). Boot a Lima VM with bridged networking to get a real LAN IP, then validate cluster join with InSpec.

## Architecture

```text
provisioning/
├── cloud-init/
│   └── init.sh                 # Hostname bootstrap script (runs before cloud-init)
├── templates/
│   └── cloud-init/
│       └── user-data.yaml.j2   # Jinja2 template (canonical cloud-init source)
├── config.env                  # Single source of truth for all config vars
├── build.sh                    # Builds gold master images for physical hardware
├── make-seed-iso.sh            # Generates NoCloud seed ISO from template
├── vm-lima.sh                  # Lima VM boot + provisioning + InSpec
├── vm-test.sh                  # InSpec against existing VM over SSH
├── lima/
│   └── ironstone-test.yaml     # Lima VM config with bridged networking
└── tests/
    ├── inspec-repo/            # Repo-level checks (config wiring, scripts exist)
    ├── inspec-node/            # Node cluster join validation
    └── inspec/                 # Full node compliance profile
```

## Quick Start

```bash
# Boot Lima VM with bridged networking and test cluster join
task provisioning:vm-lima

# Keep VM running for debugging
task provisioning:vm-lima -- --keep --no-test

# Test against existing VM
task provisioning:vm-test host=192.168.x.x port=22
```

## LLM Instructions for Future Sessions

### Context

The user is building a k3s cluster on ARM64 SBCs (Raspberry Pi 5, Rock5B). The provisioning pipeline uses:

- **cloud-init** for first-boot configuration
- **Lima** for VM testing with bridged networking (real LAN IP)
- **InSpec/CINC Auditor** for compliance testing (preferred over Bats)
- **Taskfile** for all commands (`task provisioning:*`)

### Key Files to Understand

1. **`provisioning/config.env`** — Single source of truth for:
   - `K3S_VIP`, `NFS_SERVER`, `NFS_SHARE`
   - Image URLs and checksums
   - K3s version

2. **`provisioning/templates/cloud-init/user-data.yaml.j2`** — Jinja2 cloud-init template:
   - `{{ K3S_VIP }}`, `{{ NFS_SERVER }}`, `{{ NFS_SHARE }}`
   - Rendered by `makejinja` in `build.sh`, `make-seed-iso.sh`, and `vm-test.sh`

3. **`provisioning/lima/ironstone-test.yaml`** — Lima VM config:
   - Uses bridged networking for real LAN IP
   - Debian Trixie genericcloud image
   - 4 CPUs, 4GB RAM, 20GB disk

4. **`provisioning/vm-lima.sh`** — Lima VM automation:
   - Boots VM with bridged networking
   - Templates and applies cloud-init config
   - Installs k3s and starts agent
   - Runs InSpec tests to verify cluster join

### Testing Workflow

1. **Repo checks (local, no VM):**

   ```bash
   task provisioning:test
   ```

2. **VM cluster join test (Lima):**

   ```bash
   task provisioning:vm-lima
   ```

3. **Physical node audit:**

   ```bash
   task provisioning:audit host=<node-ip>
   ```

### User Preferences

- **Shell:** fish (interactive), bash (scripts)
- **Testing:** InSpec/CINC Auditor, not Bats
- **Locale:** en_GB
- **OS:** Debian Trixie (not Bookworm)
- **TDD:** Required — write failing tests first, then implement
- **Commits:** Conventional Commits format

### Debugging Tips

- **VM won't start:** Check `limactl list`, ensure bridged network is configured in `~/.lima/_config/networks.yaml`
- **No LAN IP:** Verify `socket_vmnet` is installed and sudoers configured (`limactl sudoers`)
- **NFS mount fails:** Check NFS server is reachable from VM IP
- **k3s won't join:** Check token exists at NFS path, verify k3s VIP is reachable
- **InSpec fails:** SSH into VM with `limactl shell ironstone-test`

### Related Taskfile Commands

```yaml
provisioning:test        # InSpec repo checks
provisioning:test-bats   # Legacy Bats tests
provisioning:vm-test     # InSpec against existing VM (host=, port=)
provisioning:vm-lima     # Lima VM boot + cluster join test
provisioning:audit       # InSpec against physical node (host=)
provisioning:build       # Build gold master image
provisioning:copy        # Copy image from Lima VM
```
