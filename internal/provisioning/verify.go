package provisioning

import (
	"bufio"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type verificationCheck struct {
	Status string `json:"status"`
	Detail string `json:"detail"`
}

type verificationReport struct {
	Status string                       `json:"status"`
	Checks map[string]verificationCheck `json:"checks"`
}

func passed(detail string) verificationCheck {
	return verificationCheck{Status: "pass", Detail: detail}
}
func failed(detail string) verificationCheck {
	return verificationCheck{Status: "fail", Detail: detail}
}

func (a *App) runVerify(ctx context.Context, args []string) error {
	rootfs, hasRootfs, err := takeValue(&args, "--rootfs")
	if err != nil {
		return err
	}
	manifestPath, hasManifest, err := takeValue(&args, "--manifest")
	if err != nil {
		return err
	}
	reportedVersion, _, err := takeValue(&args, "--k3s-version")
	if err != nil {
		return err
	}
	raw := takeBool(&args, "--raw")
	if len(args) > 1 || (len(args) == 1 && hasRootfs) {
		return usageError{message: "usage: provisioning verify [<artifact>] [--rootfs <directory>] [--raw]"}
	}
	if !hasRootfs && len(args) == 0 {
		return usageError{message: "verify requires an artifact or --rootfs"}
	}
	if hasRootfs && len(args) == 1 {
		return usageError{message: "verify accepts either an artifact or --rootfs"}
	}

	var report verificationReport
	if hasRootfs {
		var manifest *Manifest
		if hasManifest {
			loaded, loadErr := loadVerificationManifest(manifestPath)
			if loadErr != nil {
				return loadErr
			}
			manifest = &loaded
		}
		report, err = verifyRootFS(rootfs, manifest, reportedVersion)
	} else {
		set, manifest, validateErr := a.validateArtifacts(ctx, args[0])
		if validateErr != nil {
			return validateErr
		}
		report, err = a.inspectImageRootFS(ctx, set.Image, manifest)
	}
	if err != nil {
		return err
	}
	if raw {
		if err := writeJSON(a.exec.stdout, report); err != nil {
			return err
		}
	} else {
		keys := make([]string, 0, len(report.Checks))
		for name := range report.Checks {
			keys = append(keys, name)
		}
		sort.Strings(keys)
		for _, name := range keys {
			check := report.Checks[name]
			if _, err := fmt.Fprintf(a.exec.stdout, "%s %s: %s\n", strings.ToUpper(check.Status), name, check.Detail); err != nil {
				return err
			}
		}
	}
	if report.Status != "pass" {
		return fmt.Errorf("image verification failed")
	}
	return nil
}

func loadVerificationManifest(path string) (Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Manifest{}, err
	}
	manifest := Manifest{Files: map[string]FileMetadata{}}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return Manifest{}, fmt.Errorf("parse verification manifest: %w", err)
	}
	return manifest, nil
}

func verifyRootFS(rootfs string, manifest *Manifest, reportedVersion string) (verificationReport, error) {
	rootfs, err := filepath.Abs(rootfs)
	if err != nil {
		return verificationReport{}, err
	}
	info, err := os.Stat(rootfs)
	if err != nil {
		return verificationReport{}, err
	}
	if !info.IsDir() {
		return verificationReport{}, fmt.Errorf("rootfs input is not a directory: %s", rootfs)
	}
	root := func(parts ...string) string { return filepath.Join(append([]string{rootfs}, parts...)...) }
	checks := map[string]verificationCheck{}
	if regularFile(root("etc", "os-release")) {
		checks["rootfs_identity"] = passed("rootfs contains an operating-system identity")
	} else {
		checks["rootfs_identity"] = failed("rootfs contains an operating-system identity")
	}

	passwd := readFiles(root("etc", "passwd"))
	keysPath := root("home", "pi", ".ssh", "authorized_keys")
	keys := strings.Split(strings.TrimSpace(readFiles(keysPath)), "\n")
	piPresent := regexp.MustCompile(`(?m)^pi:[^:]*:1000:`).MatchString(passwd)
	if piPresent && len(keys) == 1 && keys[0] == PublicKey {
		checks["pi_access"] = passed("pi user and approved key are present")
	} else {
		checks["pi_access"] = failed("pi user and approved key are present")
	}
	keyMode := fileMode(keysPath)
	sshMode := fileMode(root("home", "pi", ".ssh"))
	if keyMode == 0o600 && sshMode == 0o700 {
		checks["authorized_keys_mode"] = passed("authorized_keys=0600, .ssh=0700")
	} else {
		checks["authorized_keys_mode"] = failed(fmt.Sprintf("authorized_keys=%#o, .ssh=%#o", keyMode, sshMode))
	}
	homeMode := fileMode(root("home", "pi"))
	if homeMode == 0o750 {
		checks["pi_home"] = passed("pi home has mode 0750")
	} else {
		checks["pi_home"] = failed(fmt.Sprintf("pi home mode=%#o, want 0750", homeMode))
	}

	password := effectiveSSHDValue(rootfs, "PasswordAuthentication")
	keyboard := effectiveSSHDValue(rootfs, "KbdInteractiveAuthentication")
	rootLogin := effectiveSSHDValue(rootfs, "PermitRootLogin")
	sshDetail := fmt.Sprintf("PasswordAuthentication=%s, KbdInteractiveAuthentication=%s, PermitRootLogin=%s", password, keyboard, rootLogin)
	if password == "no" && keyboard == "no" && rootLogin == "no" {
		checks["ssh_policy"] = passed(sshDetail)
	} else {
		checks["ssh_policy"] = failed(sshDetail)
	}

	periodic := readFiles(root("etc", "apt", "apt.conf.d", "20auto-upgrades"))
	unattended := readFiles(root("etc", "apt", "apt.conf.d", "50unattended-upgrades"))
	origins := []string{"Ubuntu:noble", "Ubuntu:noble-updates", "Ubuntu:noble-security", "Ubuntu:noble-backports", "Armbian:noble"}
	upgradeOK := strings.Contains(periodic, `APT::Periodic::Unattended-Upgrade "1"`) &&
		allContained(unattended, origins) && strings.Contains(unattended, `Automatic-Reboot "false"`) &&
		validTimerActivation(rootfs) && !kernelPackagesBlacklisted(unattended)
	if upgradeOK {
		checks["unattended_upgrades"] = passed("all Noble and Armbian origins enabled; timer active")
	} else {
		checks["unattended_upgrades"] = failed("all Noble and Armbian origins enabled; timer active")
	}

	clusterPaths := []string{
		root("etc", "rancher", "k3s", "config.yaml"),
		root("etc", "rancher", "k3s", "cluster-token"),
		root("var", "lib", "rancher", "k3s", "server", "token"),
		root("var", "lib", "rancher", "k3s", "server", "db"),
	}
	if !anyExists(clusterPaths) {
		checks["cluster_state"] = passed("no cluster config, token, or server state is baked")
	} else {
		checks["cluster_state"] = failed("no cluster config, token, or server state is baked")
	}
	kubeMode := fileMode(root("etc", "rancher", "k3s", "k3s.yaml"))
	if kubeMode == 0 || kubeMode == 0o600 {
		checks["kubeconfig_mode"] = passed(fmt.Sprintf("mode=%#o", kubeMode))
	} else {
		checks["kubeconfig_mode"] = failed(fmt.Sprintf("mode=%#o", kubeMode))
	}
	machineID := root("etc", "machine-id")
	identityClean := regularFile(machineID) && fileSize(machineID) == 0 &&
		!pathExists(root("var", "lib", "cloud", "instance")) &&
		!pathExists(root("var", "lib", "cloud", "instances"))
	hostKeys, _ := filepath.Glob(root("etc", "ssh", "ssh_host_*_key"))
	identityClean = identityClean && len(hostKeys) == 0
	if identityClean {
		checks["clean_identity"] = passed("machine ID, cloud-init state, and SSH host keys are clean")
	} else {
		checks["clean_identity"] = failed("machine ID, cloud-init state, and SSH host keys are clean")
	}
	shadow := readFiles(root("etc", "shadow"))
	accountsLocked := regexp.MustCompile(`(?m)^root:[!*]`).MatchString(shadow) && regexp.MustCompile(`(?m)^pi:[!*]`).MatchString(shadow)
	if accountsLocked {
		checks["locked_accounts"] = passed("root and pi passwords are locked")
	} else {
		checks["locked_accounts"] = failed("root and pi passwords are locked")
	}

	requiredPackages := []string{"cloud-init", "conntrack", "iptables", "ipvsadm", "multipath-tools", "nfs-common", "nvme-cli", "open-iscsi", "unattended-upgrades"}
	missingPackages := missingPackages(readFiles(root("var", "lib", "dpkg", "status")), requiredPackages)
	if len(missingPackages) == 0 {
		checks["node_packages"] = passed("missing=none")
	} else {
		checks["node_packages"] = failed("missing=" + strings.Join(missingPackages, ","))
	}
	modules := readFiles(root("etc", "modules-load.d", "k3s.conf"))
	sysctls := readFiles(root("etc", "sysctl.d", "99-k3s.conf"))
	configurationOK := strings.Contains(modules, "overlay") && strings.Contains(modules, "br_netfilter") && regexp.MustCompile(`(?m)^net\.ipv4\.ip_forward\s*=\s*1`).MatchString(sysctls)
	if configurationOK {
		checks["node_configuration"] = passed("Kubernetes modules and forwarding sysctls are configured")
	} else {
		checks["node_configuration"] = failed("Kubernetes modules and forwarding sysctls are configured")
	}
	inputs := []string{root("etc", "cloud", "cloud.cfg.d", "99-ironstone.cfg"), root("var", "lib", "cloud", "seed", "nocloud", "user-data"), root("etc", "fstab")}
	compactOK := allRegular(inputs) && !strings.Contains(readFiles(inputs...), "K3S_DATA")
	if compactOK {
		checks["compact_rootfs"] = passed("required image inputs exist without a fixed K3S_DATA partition")
	} else {
		checks["compact_rootfs"] = failed("required image inputs exist without a fixed K3S_DATA partition")
	}
	service := root("etc", "systemd", "system", "k3s.service")
	wants, _ := filepath.Glob(root("etc", "systemd", "system", "*.wants", "k3s.service"))
	presets, _ := filepath.Glob(root("etc", "systemd", "system-preset", "*.preset"))
	presetText := readFiles(presets...)
	dormant := regularFile(service) && strings.Contains(readFiles(service), "ConditionPathExists=/etc/rancher/k3s/config.yaml") && strings.Contains(readFiles(service), "ConditionPathExists=/etc/rancher/k3s/cluster-token") && len(wants) == 0 && !regexp.MustCompile(`(?m)^\s*enable\s+k3s\.service`).MatchString(presetText)
	if dormant {
		checks["dormant_k3s"] = passed("K3s unit requires enrolment files and is disabled")
	} else {
		checks["dormant_k3s"] = failed("K3s unit requires enrolment files and is disabled")
	}
	nvmeHook := root("etc", "initramfs-tools", "scripts", "local-premount", "nvme-rescan")
	initramfsOK, initramfsDetail := initramfsIncludesHook(rootfs)
	if fileMode(nvmeHook)&0o111 != 0 && initramfsOK {
		checks["nvme_rescan"] = passed("executable NVMe hook is embedded in " + initramfsDetail)
	} else {
		checks["nvme_rescan"] = failed("executable NVMe hook is embedded in " + initramfsDetail)
	}

	if manifest != nil {
		binary := root("usr", "local", "bin", "k3s")
		airgap := root("var", "lib", "rancher", "k3s", "agent", "images", "k3s-airgap-images-arm64.tar")
		payloadOK := regularFile(binary) && regularFile(airgap) && hashMatches(binary, manifest.Files["k3s_binary"].SHA256) && hashMatches(airgap, manifest.Files["k3s_airgap"].SHA256)
		if payloadOK {
			checks["k3s_payloads"] = passed("matching K3s " + manifest.K3sVersion + " payloads")
		} else {
			checks["k3s_payloads"] = failed("matching K3s " + manifest.K3sVersion + " payloads")
		}
		versions := regexp.MustCompile(`\bv\d+\.\d+\.\d+\+k3s\d+\b`).FindAllString(reportedVersion, -1)
		if len(versions) == 1 && versions[0] == manifest.K3sVersion {
			checks["k3s_version"] = passed("binary reports " + strings.TrimSpace(reportedVersion))
		} else {
			checks["k3s_version"] = failed("binary reports " + strings.TrimSpace(reportedVersion))
		}
	}

	status := "pass"
	for _, check := range checks {
		if check.Status != "pass" {
			status = "fail"
			break
		}
	}
	return verificationReport{Status: status, Checks: checks}, nil
}

func effectiveSSHDValue(rootfs, key string) string {
	value := ""
	var parse func(string)
	parse = func(path string) {
		if value != "" {
			return
		}
		file, err := os.Open(path)
		if err != nil {
			return
		}
		defer file.Close()
		inMatch := false
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			line := strings.TrimSpace(strings.SplitN(scanner.Text(), "#", 2)[0])
			if line == "" {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) == 0 {
				continue
			}
			if strings.EqualFold(fields[0], "Match") {
				inMatch = true
				continue
			}
			if strings.EqualFold(fields[0], "Include") && !inMatch {
				for _, pattern := range fields[1:] {
					pattern = strings.TrimPrefix(pattern, "/")
					matches, _ := filepath.Glob(filepath.Join(rootfs, pattern))
					sort.Strings(matches)
					for _, match := range matches {
						parse(match)
					}
				}
				continue
			}
			if !inMatch && len(fields) > 1 && strings.EqualFold(fields[0], key) {
				value = strings.ToLower(fields[1])
				return
			}
		}
	}
	parse(filepath.Join(rootfs, "etc", "ssh", "sshd_config"))
	return value
}

func validTimerActivation(rootfs string) bool {
	activation := filepath.Join(rootfs, "etc", "systemd", "system", "timers.target.wants", "apt-daily-upgrade.timer")
	target, err := os.Readlink(activation)
	if err != nil {
		return false
	}
	if filepath.IsAbs(target) {
		target = filepath.Join(rootfs, strings.TrimPrefix(target, string(filepath.Separator)))
	} else {
		target = filepath.Join(filepath.Dir(activation), target)
	}
	resolved := filepath.Clean(target)
	for _, expected := range []string{
		filepath.Join(rootfs, "lib", "systemd", "system", "apt-daily-upgrade.timer"),
		filepath.Join(rootfs, "usr", "lib", "systemd", "system", "apt-daily-upgrade.timer"),
	} {
		if resolved == expected && regularFile(resolved) {
			return true
		}
	}
	return false
}

func initramfsIncludesHook(rootfs string) (bool, string) {
	images, _ := filepath.Glob(filepath.Join(rootfs, "boot", "initrd.img-*"))
	for _, image := range images {
		contains, err := archiveContains(image, "scripts/local-premount/nvme-rescan")
		if err == nil && contains {
			return true, filepath.Base(image)
		}
		output, commandErr := exec.Command("lsinitramfs", image).Output()
		if commandErr == nil && strings.Contains(string(output), "scripts/local-premount/nvme-rescan") {
			return true, filepath.Base(image)
		}
	}
	return false, "a generated initramfs"
}

func archiveContains(path, name string) (bool, error) {
	file, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer file.Close()
	header := make([]byte, 2)
	if _, err := io.ReadFull(file, header); err != nil {
		return false, err
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return false, err
	}
	var reader io.Reader = file
	if header[0] == 0x1f && header[1] == 0x8b {
		gzipReader, err := gzip.NewReader(file)
		if err != nil {
			return false, err
		}
		defer gzipReader.Close()
		reader = gzipReader
	}
	return newcContains(reader, name)
}

func newcContains(reader io.Reader, wanted string) (bool, error) {
	for {
		header := make([]byte, 110)
		if _, err := io.ReadFull(reader, header); err != nil {
			return false, err
		}
		if string(header[:6]) != "070701" && string(header[:6]) != "070702" {
			return false, fmt.Errorf("not a newc archive")
		}
		namesize, err := parseHex(header[94:102])
		if err != nil || namesize < 1 {
			return false, fmt.Errorf("invalid newc name size")
		}
		filesize, err := parseHex(header[54:62])
		if err != nil {
			return false, fmt.Errorf("invalid newc file size")
		}
		filename := make([]byte, namesize)
		if _, err := io.ReadFull(reader, filename); err != nil {
			return false, err
		}
		if err := discardPadding(reader, 110+namesize); err != nil {
			return false, err
		}
		name := strings.TrimSuffix(string(filename), "\x00")
		if name == "TRAILER!!!" {
			return false, nil
		}
		if name == wanted {
			return true, nil
		}
		if _, err := io.CopyN(io.Discard, reader, int64(filesize)); err != nil {
			return false, err
		}
		if err := discardPadding(reader, filesize); err != nil {
			return false, err
		}
	}
}

func parseHex(value []byte) (int, error) {
	var parsed int
	_, err := fmt.Sscanf(string(value), "%x", &parsed)
	return parsed, err
}

func discardPadding(reader io.Reader, length int) error {
	padding := (4 - (length % 4)) % 4
	if padding == 0 {
		return nil
	}
	_, err := io.CopyN(io.Discard, reader, int64(padding))
	return err
}

func regularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func pathExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func fileMode(path string) os.FileMode {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Mode().Perm()
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return -1
	}
	return info.Size()
}

func readFiles(paths ...string) string {
	contents := make([]string, 0, len(paths))
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err == nil {
			contents = append(contents, string(data))
		}
	}
	return strings.Join(contents, "\n")
}

func allContained(input string, values []string) bool {
	for _, value := range values {
		if !strings.Contains(input, value) {
			return false
		}
	}
	return true
}

func kernelPackagesBlacklisted(input string) bool {
	blacklist := input
	if index := strings.Index(blacklist, "Package-Blacklist"); index >= 0 {
		blacklist = blacklist[index:]
	}
	return regexp.MustCompile(`(?i)(linux-image|linux-dtb|linux-u-boot|armbian-firmware)`).MatchString(blacklist)
}

func anyExists(paths []string) bool {
	for _, path := range paths {
		if pathExists(path) {
			return true
		}
	}
	return false
}

func missingPackages(status string, wanted []string) []string {
	installed := map[string]bool{}
	for _, paragraph := range strings.Split(status, "\n\n") {
		if !regexp.MustCompile(`(?m)^Status:\s+install ok installed\s*$`).MatchString(paragraph) {
			continue
		}
		match := regexp.MustCompile(`(?m)^Package:\s*(\S+)\s*$`).FindStringSubmatch(paragraph)
		if len(match) == 2 {
			installed[match[1]] = true
		}
	}
	missing := []string{}
	for _, name := range wanted {
		if !installed[name] {
			missing = append(missing, name)
		}
	}
	sort.Strings(missing)
	return missing
}

func allRegular(paths []string) bool {
	for _, path := range paths {
		if !regularFile(path) {
			return false
		}
	}
	return true
}

func hashMatches(path, expected string) bool {
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(expected) {
		return false
	}
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return false
	}
	return hex.EncodeToString(digest.Sum(nil)) == expected
}

func (a *App) inspectImageRootFS(ctx context.Context, image string, manifest Manifest) (verificationReport, error) {
	if !programAvailable("docker") || !programAvailable("xz") || !programAvailable("go") {
		return verificationReport{}, fmt.Errorf("image verification requires docker, xz, and go")
	}
	imageSize, err := a.xzUncompressedSize(ctx, image)
	if err != nil {
		return verificationReport{}, err
	}
	free, err := a.availableBytes(ctx, os.TempDir())
	if err != nil {
		return verificationReport{}, err
	}
	required := imageSize + 1024*1024*1024
	if free < required {
		return verificationReport{}, fmt.Errorf("image extraction requires %.1f GiB; %.1f GiB is free", float64(required)/float64(1024*1024*1024), float64(free)/float64(1024*1024*1024))
	}
	temporary, err := os.MkdirTemp("", "provisioning-verify-")
	if err != nil {
		return verificationReport{}, err
	}
	defer os.RemoveAll(temporary)
	raw := filepath.Join(temporary, "image.img")
	if err := a.extractXZ(ctx, image, raw); err != nil {
		return verificationReport{}, err
	}
	manifestPath := filepath.Join(temporary, "manifest.json")
	data, err := json.Marshal(manifest)
	if err != nil {
		return verificationReport{}, err
	}
	if err := os.WriteFile(manifestPath, data, 0o600); err != nil {
		return verificationReport{}, err
	}
	verifier := filepath.Join(temporary, "provisioning")
	if err := a.buildLinuxVerifier(ctx, verifier); err != nil {
		return verificationReport{}, err
	}

	script := `set -eux
apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq util-linux e2fsprogs initramfs-tools-core >/dev/null
if command -v python3 >/dev/null 2>&1; then
  echo "verification container must not include Python" >&2
  exit 1
fi
loop=""
mounted=false
cleanup() {
  if [ "$mounted" = true ]; then umount /mnt/root 2>/dev/null || true; fi
  if [ -n "$loop" ]; then losetup -d "$loop" 2>/dev/null || true; fi
}
trap cleanup EXIT HUP INT TERM
loop=$(losetup --find --show --partscan /image.img)
lsblk -rno PATH,TYPE,MAJ:MIN "$loop" | while read -r candidate type device_number; do
  if [ "$type" = part ] && [ ! -b "$candidate" ]; then
    mknod -m 0660 "$candidate" b "${device_number%:*}" "${device_number#*:}"
  fi
done
mkdir -p /mnt/root
root=""
for candidate in $(lsblk -rno PATH,TYPE "$loop" | awk '$2 == "part" {print $1}'); do
  [ "$(blkid -s TYPE -o value "$candidate" || true)" = ext4 ] || continue
  mount -o ro,noload "$candidate" /mnt/root
  mounted=true
  if test -f /mnt/root/etc/os-release && test -x /mnt/root/usr/local/bin/k3s && test -f /mnt/root/var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar; then
    root="$candidate"
    break
  fi
  umount /mnt/root
  mounted=false
done
test -n "$root"
reported_version=$(chroot /mnt/root /usr/local/bin/k3s --version 2>&1)
/verifier/provisioning verify --rootfs /mnt/root --manifest /verifier/manifest.json --k3s-version "$reported_version" --raw`
	output, err := a.exec.output(ctx, a.paths.repo, nil, "docker", "run", "--rm", "--privileged", "--platform", "linux/arm64", "-e", "MISE_PROJECT_ROOT=/verifier", "-v", raw+":/image.img:ro", "-v", manifestPath+":/verifier/manifest.json:ro", "-v", verifier+":/verifier/provisioning:ro", "debian:bookworm-slim", "sh", "-ceu", script)
	if err != nil {
		return verificationReport{}, err
	}
	var report verificationReport
	if err := json.Unmarshal([]byte(output), &report); err != nil {
		return verificationReport{}, fmt.Errorf("verifier container returned invalid JSON: %w", err)
	}
	return report, nil
}

func (a *App) xzUncompressedSize(ctx context.Context, image string) (int64, error) {
	output, err := a.exec.output(ctx, a.paths.repo, nil, "xz", "--robot", "--list", image)
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) >= 5 && fields[0] == "totals" {
			var size int64
			if _, err := fmt.Sscan(fields[4], &size); err == nil && size > 0 {
				return size, nil
			}
		}
	}
	return 0, fmt.Errorf("could not determine the uncompressed image size")
}

func (a *App) availableBytes(ctx context.Context, directory string) (int64, error) {
	output, err := a.exec.output(ctx, a.paths.repo, nil, "df", "-Pk", directory)
	if err != nil {
		return 0, err
	}
	lines := strings.Split(strings.TrimSpace(output), "\n")
	if len(lines) < 2 {
		return 0, fmt.Errorf("could not determine free disk space")
	}
	fields := strings.Fields(lines[len(lines)-1])
	if len(fields) < 4 {
		return 0, fmt.Errorf("could not determine free disk space")
	}
	var blocks int64
	if _, err := fmt.Sscan(fields[3], &blocks); err != nil {
		return 0, fmt.Errorf("could not determine free disk space: %w", err)
	}
	return blocks * 1024, nil
}

func (a *App) extractXZ(ctx context.Context, image, destination string) error {
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer output.Close()
	command := exec.CommandContext(ctx, "xz", "-dc", image)
	command.Stdout = output
	command.Stderr = a.exec.stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("xz extraction failed: %w", err)
	}
	return output.Sync()
}

func (a *App) buildLinuxVerifier(ctx context.Context, destination string) error {
	command := exec.CommandContext(ctx, "go", "build", "-o", destination, "./cmd/provisioning")
	command.Dir = a.paths.repo
	command.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOARCH=arm64")
	command.Stdout = a.exec.stderr
	command.Stderr = a.exec.stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("build Linux ARM64 verifier: %w", err)
	}
	return nil
}
