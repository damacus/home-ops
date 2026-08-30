package provisioning

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

type flashTarget struct {
	Device    string
	RawDevice string
	Size      int64
	Model     string
}

func (a *App) runFlash(ctx context.Context, args []string) error {
	dryRun := takeBool(&args, "--dry-run")
	if err := requirePositionals(args, 2, "provisioning flash <artifact> <device> [--dry-run]"); err != nil {
		return err
	}
	artifact, err := filepath.Abs(args[0])
	if err != nil {
		return err
	}
	device, err := filepath.Abs(args[1])
	if err != nil {
		return err
	}
	if dryRun {
		return writeJSON(a.exec.stdout, map[string]any{
			"source":          artifact,
			"device":          device,
			"remote_download": false,
		})
	}
	set, _, err := a.validateArtifacts(ctx, artifact)
	if err != nil {
		return err
	}
	target, err := a.inspectFlashDevice(ctx, device)
	if err != nil {
		return err
	}
	imageSize, err := a.xzUncompressedSize(ctx, set.Image)
	if err != nil {
		return err
	}
	if target.Size == 0 || imageSize > target.Size {
		return fmt.Errorf("image is %d bytes but target capacity is %d bytes", imageSize, target.Size)
	}
	if _, err := fmt.Fprintf(a.exec.stderr, "Target: %s size=%d bytes model=%s\nType %s to overwrite it: ", target.Device, target.Size, target.Model, target.Device); err != nil {
		return err
	}
	confirmation, err := bufio.NewReader(a.exec.stdin).ReadString('\n')
	if err != nil && err != io.EOF {
		return err
	}
	if strings.TrimSpace(confirmation) != target.Device {
		return fmt.Errorf("device confirmation did not match")
	}
	if err := a.streamImageToDevice(ctx, set.Image, target.RawDevice); err != nil {
		return err
	}
	if err := a.exec.runToStderr(ctx, a.paths.repo, nil, "sync"); err != nil {
		return err
	}
	if runtime.GOOS == "darwin" {
		if err := a.exec.runToStderr(ctx, a.paths.repo, nil, "diskutil", "eject", target.Device); err != nil {
			return err
		}
	}
	return nil
}

func (a *App) streamImageToDevice(ctx context.Context, image, device string) error {
	reader, writer, err := os.Pipe()
	if err != nil {
		return err
	}
	defer reader.Close()
	defer writer.Close()
	xz := exec.CommandContext(ctx, "xz", "-dc", image)
	xz.Stdout = writer
	xz.Stderr = a.exec.stderr
	dd := exec.CommandContext(ctx, "sudo", "dd", "of="+device, "bs=4M", "conv=fsync", "status=progress")
	dd.Stdin = reader
	dd.Stdout = a.exec.stderr
	dd.Stderr = a.exec.stderr
	if err := xz.Start(); err != nil {
		return fmt.Errorf("start xz: %w", err)
	}
	if err := writer.Close(); err != nil {
		return err
	}
	if err := dd.Run(); err != nil {
		_ = xz.Process.Kill()
		_ = xz.Wait()
		return fmt.Errorf("image write failed: %w", err)
	}
	if err := xz.Wait(); err != nil {
		return fmt.Errorf("image decompression failed: %w", err)
	}
	return nil
}

func (a *App) inspectFlashDevice(ctx context.Context, device string) (flashTarget, error) {
	switch runtime.GOOS {
	case "linux":
		return a.inspectLinuxDevice(ctx, device)
	case "darwin":
		return a.inspectDarwinDevice(ctx, device)
	default:
		return flashTarget{}, fmt.Errorf("flashing is unsupported on %s", runtime.GOOS)
	}
}

func ensureBlockDevice(device string) error {
	info, err := os.Stat(device)
	if err != nil || info.Mode()&os.ModeDevice == 0 || info.Mode()&os.ModeCharDevice != 0 {
		return fmt.Errorf("flash target is not a block device: %s", device)
	}
	return nil
}

func (a *App) inspectLinuxDevice(ctx context.Context, device string) (flashTarget, error) {
	if err := ensureBlockDevice(device); err != nil {
		return flashTarget{}, err
	}
	output, err := a.exec.output(ctx, a.paths.repo, nil, "lsblk", "--json", "--bytes", "--paths", "--output", "PATH,TYPE,SIZE,MODEL,MOUNTPOINTS", device)
	if err != nil {
		return flashTarget{}, err
	}
	var data struct {
		BlockDevices []linuxBlockDevice `json:"blockdevices"`
	}
	if err := json.Unmarshal([]byte(output), &data); err != nil {
		return flashTarget{}, fmt.Errorf("parse lsblk output: %w", err)
	}
	if len(data.BlockDevices) != 1 || data.BlockDevices[0].Type != "disk" {
		return flashTarget{}, fmt.Errorf("flash target is not a whole disk: %s", device)
	}
	target := data.BlockDevices[0]
	if mounts := target.mountedValues(); len(mounts) > 0 {
		return flashTarget{}, fmt.Errorf("flash target has mounted filesystems: %s", strings.Join(mounts, ", "))
	}
	rootSource, err := a.exec.output(ctx, a.paths.repo, nil, "findmnt", "--noheadings", "--output", "SOURCE", "/")
	if err != nil {
		return flashTarget{}, err
	}
	ancestry, err := a.exec.output(ctx, a.paths.repo, nil, "lsblk", "--inverse", "--noheadings", "--paths", "--output", "PATH", strings.TrimSpace(rootSource))
	if err != nil {
		return flashTarget{}, err
	}
	for _, path := range strings.Fields(ancestry) {
		if path == target.Path {
			return flashTarget{}, fmt.Errorf("refusing the disk containing the live root filesystem: %s", device)
		}
	}
	return flashTarget{Device: target.Path, RawDevice: target.Path, Size: target.Size, Model: firstNonEmpty(strings.TrimSpace(target.Model), "unknown")}, nil
}

type linuxBlockDevice struct {
	Path        string             `json:"path"`
	Type        string             `json:"type"`
	Size        int64              `json:"size"`
	Model       string             `json:"model"`
	Mountpoint  string             `json:"mountpoint"`
	Mountpoints []string           `json:"mountpoints"`
	Children    []linuxBlockDevice `json:"children"`
}

func (d linuxBlockDevice) mountedValues() []string {
	values := append([]string{}, d.Mountpoints...)
	if d.Mountpoint != "" {
		values = append(values, d.Mountpoint)
	}
	for _, child := range d.Children {
		values = append(values, child.mountedValues()...)
	}
	filtered := values[:0]
	for _, value := range values {
		if value != "" {
			filtered = append(filtered, value)
		}
	}
	return filtered
}

func (a *App) inspectDarwinDevice(ctx context.Context, device string) (flashTarget, error) {
	if err := ensureBlockDevice(device); err != nil {
		return flashTarget{}, err
	}
	info, err := a.diskutilJSON(ctx, "info", device)
	if err != nil {
		return flashTarget{}, err
	}
	if !boolValue(info["Whole"]) {
		return flashTarget{}, fmt.Errorf("flash target is not a whole disk: %s", device)
	}
	identifier := stringValue(info["DeviceIdentifier"])
	root, err := a.diskutilJSON(ctx, "info", "/")
	if err != nil {
		return flashTarget{}, err
	}
	apfs, err := a.diskutilJSON(ctx, "apfs", "list")
	if err != nil {
		return flashTarget{}, err
	}
	rootDisks := map[string]bool{stringValue(root["ParentWholeDisk"]): true}
	rootPhysicalDisks, err := a.apfsPhysicalWholeDisks(ctx, apfs, firstNonEmpty(stringValue(root["ParentWholeDisk"]), stringValue(root["DeviceIdentifier"])), false)
	if err != nil {
		return flashTarget{}, err
	}
	for disk := range rootPhysicalDisks {
		rootDisks[disk] = true
	}
	if rootDisks[identifier] {
		return flashTarget{}, fmt.Errorf("refusing the disk containing the live root filesystem: %s", device)
	}
	listing, err := a.diskutilJSON(ctx, "list", device)
	if err != nil {
		return flashTarget{}, err
	}
	for _, disk := range arrayValues(listing["AllDisksAndPartitions"]) {
		for _, partition := range arrayValues(disk["Partitions"]) {
			partitionInfo, infoErr := a.diskutilJSON(ctx, "info", "/dev/"+stringValue(partition["DeviceIdentifier"]))
			if infoErr != nil {
				return flashTarget{}, infoErr
			}
			if stringValue(partitionInfo["MountPoint"]) != "" {
				return flashTarget{}, fmt.Errorf("flash target has mounted filesystems: %s", stringValue(partitionInfo["MountPoint"]))
			}
		}
	}
	mountedPhysicalDisks, err := a.apfsPhysicalWholeDisks(ctx, apfs, "", true)
	if err != nil {
		return flashTarget{}, err
	}
	if mountedPhysicalDisks[identifier] {
		return flashTarget{}, fmt.Errorf("flash target has mounted filesystems: mounted APFS volume")
	}
	return flashTarget{Device: "/dev/" + identifier, RawDevice: "/dev/r" + identifier, Size: int64(numberValue(info["TotalSize"])), Model: firstNonEmpty(stringValue(info["MediaName"]), stringValue(info["DeviceModel"]), "unknown")}, nil
}

func (a *App) apfsPhysicalWholeDisks(ctx context.Context, apfs map[string]any, volumeIdentifier string, mountedOnly bool) (map[string]bool, error) {
	wholeDisks := map[string]bool{}
	for _, container := range arrayValues(apfs["Containers"]) {
		volumes := arrayValues(container["Volumes"])
		matches := volumeIdentifier != "" && stringValue(container["ContainerReference"]) == volumeIdentifier
		for _, volume := range volumes {
			if (volumeIdentifier != "" && stringValue(volume["DeviceIdentifier"]) == volumeIdentifier) || (mountedOnly && stringValue(volume["MountPoint"]) != "") {
				matches = true
			}
		}
		if !matches {
			continue
		}
		for _, store := range arrayValues(container["PhysicalStores"]) {
			storeID := stringValue(store["DeviceIdentifier"])
			if storeID == "" {
				continue
			}
			storeInfo, err := a.diskutilJSON(ctx, "info", "/dev/"+storeID)
			if err != nil {
				return nil, err
			}
			wholeDisks[firstNonEmpty(stringValue(storeInfo["ParentWholeDisk"]), storeID)] = true
		}
	}
	return wholeDisks, nil
}

func (a *App) diskutilJSON(ctx context.Context, args ...string) (map[string]any, error) {
	if len(args) == 0 {
		return nil, fmt.Errorf("diskutil command is required")
	}
	diskutilArgs := append([]string{}, args...)
	if args[0] == "apfs" && len(args) > 1 {
		diskutilArgs = append([]string{args[0], args[1], "-plist"}, args[2:]...)
	} else {
		diskutilArgs = append([]string{args[0], "-plist"}, args[1:]...)
	}
	command := exec.CommandContext(ctx, "diskutil", diskutilArgs...)
	command.Dir = a.paths.repo
	plist, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("diskutil failed: %w", err)
	}
	converter := exec.CommandContext(ctx, "plutil", "-convert", "json", "-o", "-", "-")
	converter.Stdin = bytes.NewReader(plist)
	jsonData, err := converter.Output()
	if err != nil {
		return nil, fmt.Errorf("convert diskutil plist: %w", err)
	}
	var data map[string]any
	if err := json.Unmarshal(jsonData, &data); err != nil {
		return nil, fmt.Errorf("parse diskutil plist: %w", err)
	}
	return data, nil
}

func stringValue(value any) string  { result, _ := value.(string); return result }
func boolValue(value any) bool      { result, _ := value.(bool); return result }
func numberValue(value any) float64 { result, _ := value.(float64); return result }
func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
func arrayValues(value any) []map[string]any {
	values, _ := value.([]any)
	result := make([]map[string]any, 0, len(values))
	for _, value := range values {
		if item, ok := value.(map[string]any); ok {
			result = append(result, item)
		}
	}
	return result
}
