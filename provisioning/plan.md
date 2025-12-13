# Zero-Touch Bare-Metal Provisioning Architecture

## 1. Executive Summary

The objective is to establish a fully automated, "zero-touch" provisioning pipeline for bare-metal Single Board Computers (SBCs) to join a Kubernetes cluster. The system must eliminate the need for manual interaction (keyboard/monitor) or physical intervention (removing NVMe drives to flash them) after the initial setup.

## 2. Problem Statement

Deploying Kubernetes on bare-metal SBCs typically involves:
1.  Physically attaching storage media to a workstation.
2.  Flashing an operating system image.
3.  Manually configuring the OS (network, users, SSH).
4.  Installing Kubernetes components and joining the cluster.
5.  Repeating this for every node or update.

This process is unscalable and prone to human error. Furthermore, many modern SBCs use high-speed onboard storage (like NVMe) that is not easily accessible for external flashing without specialized hardware or dismantling the cluster.

## 3. Core Concepts

To solve this, we define a two-stage image strategy:

### A. The "Target" Image (Gold Master)
This is the production operating system that will eventually run on the node's permanent storage (NVMe).
- **State**: Optimized, hardened, and pre-loaded with necessary dependencies (container runtimes, network drivers, cluster agents).
- **Configuration**: Generic enough to be deployed to any node of the same architecture, but capable of self-customization (hostname, IP) upon first boot.
- **Lifecycle**: Built centrally, versioned, and stored on a network file server.

### B. The "Installer" Image (Flasher)
This is a transient utility environment used solely to deploy the Target Image.
- **Medium**: Typically runs from removable media (SD Card) or network boot (PXE), serving as the "bootstrap" media.
- **Function**:
    1.  Boots the hardware.
    2.  Updates board firmware (e.g., SPI flash) if necessary to support NVMe booting.
    3.  Connects to the network.
    4.  Retrieves the latest **Target Image** from the network storage.
    5.  Writes the Target Image to the internal high-speed storage (NVMe).
    6.  Signals completion (e.g., LED pattern, network call) and powers down.

## 4. Provisioning Workflow

The proposed lifecycle for a new or repurposed node is as follows:

1.  **Build Phase (CI/CD)**
    - The pipeline generates the **Target Image** (Gold Master) with all software pre-baked.
    - The pipeline uploads this image to a central Network Attached Storage (NAS) or Artifact Repository.
    - Optionally, an **Installer Image** is generated if the bootstrap logic needs updates.

2.  **Bootstrap Phase**
    - The operator inserts the **Installer** media (SD Card) into the node.
    - The node powers on and boots the Installer.
    - The Installer automatically formats the NVMe drive and streams the **Target Image** from the NAS to the NVMe.
    - The node shuts down.

3.  **Production Phase**
    - The operator removes the Installer media (if physical) or changes boot order.
    - The node powers on and boots from NVMe (The Target Image).
    - **Initialization**: The OS detects it is a fresh boot. It contacts a metadata service (or uses embedded configuration) to set its unique identity.
    - **Cluster Join**: The node uses a pre-seeded or retrieved token to automatically join the Kubernetes cluster as a worker or control plane node.

## 5. Required Capabilities

To achieve this without prescribing specific tools, the solution requires:

- **OS Image Builder**: A tool capable of creating custom Linux disk images from scratch or modifying existing upstream images. It needs to support ARM architectures and chroot/virtualization environments.
- **Configuration Management**: A method to idempotently apply file changes, package installations, and system settings during the image build process.
- **Network Storage Protocol**: A standard protocol (e.g., HTTP, NFS, S3) accessible by the Installer to fetch large artifacts.
- **First-Boot Customization**: A mechanism (like standard cloud initialization patterns) that runs strictly on the first boot to finalize the unique setup of the node.
- **Firmware Management**: Capability to flash board-specific bootloaders (SPI) to ensure the hardware supports booting from the desired medium (NVMe).

## 6. Success Criteria

- **Zero Interaction**: Once the SD card is inserted and power applied, no further human input is required until the node appears as `Ready` in the Kubernetes API.
- **Speed**: The "flashing" process should be limited only by network/disk I/O, not manual configuration steps.
- **Reproducibility**: If a node fails, re-running the Installer SD card should return it to a known good state.
- **Observability**: The process should emit some form of status (logs to a central server, LED codes) so the operator knows when flashing is complete.

---

## 7. Implementation Status

### ✅ Completed (Golden Image)

- [x] **Packer Configuration**: `packer/ironstone.pkr.hcl` - ARM image builder for RPi5 and Rock5B
- [x] **Docker Build Environment**: `docker-compose.yaml` + `Dockerfile` - Containerised build pipeline
- [x] **Ansible Gold-Master Role**: Complete provisioning with:
  - [x] K3s binary installation (without starting)
  - [x] Kernel modules for Kubernetes (overlay, br_netfilter, ip_vs)
  - [x] Sysctl settings for networking
  - [x] Cloud-init configuration for Matchbox datasource
  - [x] `k3s-init.service` - First-boot k3s startup
  - [x] Image sealing (SSH keys, machine-id, cloud-init state)
- [x] **MAC-Based Naming**: Via Matchbox (see `kubernetes/apps/default/matchbox/helmrelease.yaml`)
- [x] **Architecture Documentation**: `docs/ARCHITECTURE.md`

### 🔄 In Progress (Flasher Image)

- [x] **Ansible Flasher Role**: Basic implementation complete
- [ ] **Testing**: End-to-end flasher workflow validation

### 📋 Pending (CI/CD & Hardening)

See phases below for detailed roadmap.

---

## Phase 1: Local Build Improvements

### 1.1 Build Script Enhancements

- [x] Externalised configuration (`config.env`)
- [x] Secret management (K3S_TOKEN from env/file)
- [x] Dry-run validation mode
- [ ] CI mode flag for non-interactive builds

---

## Phase 2: GitHub Actions Integration

### 2.1 Basic Workflow

```yaml
# .github/workflows/build-image.yaml
name: Build Provisioning Image
on:
  workflow_dispatch:
    inputs:
      board:
        type: choice
        options: [rpi5, rock5b]
      image_type:
        type: choice
        options: [gold, flasher]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build Image
        env:
          K3S_TOKEN: ${{ secrets.K3S_TOKEN }}
        run: |
          ./provisioning/build.sh --ci ${{ inputs.board || 'rpi5' }} ${{ inputs.image_type || 'gold' }}
      - name: Upload Artifact
        uses: actions/upload-artifact@v4
        with:
          name: ironstone-image
          path: provisioning/packer/builds/*.img
          retention-days: 30
```

### 2.2 Required GitHub Secrets

| Secret Name | Description |
|-------------|-------------|
| `K3S_TOKEN` | K3s cluster join token |
| `NFS_HOST` | NFS server address (optional) |
| `NFS_USER` | NFS credentials (if using authenticated NFS) |
| `NFS_PASS` | NFS password |

### 2.3 Self-Hosted Runner Considerations

ARM image builds require:

- QEMU for ARM emulation (slow on x86)
- Privileged Docker access for loopback mounts
- ~10GB disk space per build

Options:

1. **GitHub-hosted runners** - Use QEMU, slower but no infrastructure
2. **Self-hosted ARM runner** - Native builds, faster, requires maintenance
3. **Buildjet/Actuated** - Paid ARM runners, fast, no maintenance

---

## Phase 3: Artifact Management

### 3.1 Storage Options

| Option | Pros | Cons |
|--------|------|------|
| GitHub Artifacts | Free, integrated | 90-day retention, 500MB limit |
| S3/GCS | Unlimited, cheap | Requires setup |
| GitHub Releases | Permanent, versioned | Manual tagging |
| Self-hosted NFS | Current workflow | Not accessible externally |

### 3.2 Recommended Approach

1. **PR builds**: GitHub Artifacts (validation only, no full build)
2. **Main builds**: Upload to S3 + GitHub Release for tagged versions
3. **NFS upload**: Keep for local network access

---

## Phase 4: Security Hardening

### 4.1 Image Scanning

- [ ] Integrate Trivy or Grype for vulnerability scanning
- [ ] Fail build on critical vulnerabilities
- [ ] Generate SBOM (Software Bill of Materials)

### 4.2 Secret Rotation

- [ ] Document K3S_TOKEN rotation procedure
- [ ] Add secret expiry monitoring

### 4.3 Audit Trail

- [ ] Log all builds with git SHA, timestamp, builder
- [ ] Store build logs with artifacts

---

## Phase 5: Documentation for External Users

### 5.1 Fork-Friendly Setup

- [ ] Document all required secrets
- [ ] Provide example `config.env.example` with placeholders
- [ ] Add setup script for first-time users
- [ ] Create GitHub template repository

### 5.2 Required Documentation

- [ ] `CONTRIBUTING.md` - How to contribute
- [ ] `docs/ci-setup.md` - CI configuration guide
- [ ] `docs/secrets.md` - Secret management guide
- [ ] `docs/customisation.md` - How to adapt for other networks

---

## Implementation Order

1. **Phase 1.3** - Add validation (low risk, immediate value)
2. **Phase 1.1** - Refactor for CI compatibility
3. **Phase 2.1** - Basic GitHub Actions workflow (validate only)
4. **Phase 2.2** - Add secrets, enable builds
5. **Phase 3** - Artifact management
6. **Phase 4** - Security hardening
7. **Phase 5** - External user documentation

---

## Open Questions

1. Should we support multiple K3s clusters (different tokens)?
2. Do we need to support non-GitHub CI systems (GitLab, Jenkins)?
3. Should built images be publicly downloadable?
4. What's the retention policy for old images?

---

## References

- [Packer ARM Builder](https://github.com/mkaczanowski/packer-builder-arm)
- [GitHub Actions ARM Support](https://github.blog/changelog/2024-06-03-actions-arm-based-linux-and-windows-runners-are-now-in-public-beta/)
- [Trivy Container Scanner](https://trivy.dev/)
