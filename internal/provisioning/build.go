package provisioning

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

type payloads struct {
	binary string
	airgap string
}

func (a *App) runBuild(ctx context.Context, args []string) error {
	dryRun := takeBool(&args, "--dry-run")
	verbose := takeBool(&args, "--verbose", "-v")
	if err := requirePositionals(args, 0, "provisioning build [--dry-run] [--verbose]"); err != nil {
		return err
	}
	plan, err := a.buildPlan(ctx)
	if err != nil {
		return err
	}
	if dryRun {
		return writeJSON(a.exec.stdout, plan)
	}
	if !programAvailable("docker") {
		return fmt.Errorf("required program is unavailable: docker")
	}
	if err := a.requireBuildInputsUnchanged(ctx, plan); err != nil {
		return err
	}
	staged, err := a.stageK3sPayloads(ctx, plan)
	if err != nil {
		return err
	}
	// Capture the output directory before compilation. Armbian can leave an old
	// image in place, and its timestamp must never make that image publishable.
	previousOutputs := outputSnapshot(a.paths.armbian)
	if err := a.withInjectedUserpatches(staged, func() error {
		commandArgs := []string{"build"}
		for _, parameter := range buildParameters {
			commandArgs = append(commandArgs, parameter.Name+"="+parameter.Value)
		}
		if verbose {
			commandArgs = append(commandArgs, "PROGRESS_DISPLAY=plain")
		}
		return a.exec.runToStderr(ctx, a.paths.armbian, nil, "./compile.sh", commandArgs...)
	}); err != nil {
		return err
	}
	if err := a.requireBuildInputsUnchanged(ctx, plan); err != nil {
		return err
	}
	image, err := a.writeNewArtifacts(
		plan,
		staged,
		previousOutputs,
		time.Now().UTC(),
	)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(a.exec.stdout, image)
	return err
}

type outputState struct {
	modified time.Time
	size     int64
}

func outputSnapshot(armbianRoot string) map[string]outputState {
	states := make(map[string]outputState)
	images, _ := filepath.Glob(filepath.Join(armbianRoot, "output/images/*.img.xz"))
	for _, image := range images {
		info, err := os.Stat(image)
		if err == nil {
			states[image] = outputState{modified: info.ModTime(), size: info.Size()}
		}
	}
	return states
}

func newOutputImages(armbianRoot string, previous map[string]outputState) []string {
	images, _ := filepath.Glob(filepath.Join(armbianRoot, "output/images/*.img.xz"))
	type candidate struct {
		path     string
		modified time.Time
	}
	candidates := make([]candidate, 0, len(images))
	for _, image := range images {
		info, err := os.Stat(image)
		if err != nil {
			continue
		}
		before, existed := previous[image]
		changed := !existed || info.ModTime().After(before.modified) || info.Size() != before.size
		if changed {
			candidates = append(candidates, candidate{path: image, modified: info.ModTime()})
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].modified.After(candidates[j].modified)
	})
	paths := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		paths = append(paths, candidate.path)
	}
	return paths
}

func (a *App) stageK3sPayloads(ctx context.Context, plan buildPlan) (payloads, error) {
	if err := os.MkdirAll(a.paths.staging, 0o755); err != nil {
		return payloads{}, fmt.Errorf("create K3s staging: %w", err)
	}
	targets := map[string]string{
		"binary":    filepath.Join(a.paths.staging, "k3s-arm64"),
		"airgap":    filepath.Join(a.paths.staging, "k3s-airgap-images-arm64.tar"),
		"checksums": filepath.Join(a.paths.staging, "sha256sum-arm64.txt"),
	}
	client := &http.Client{Timeout: 120 * time.Second}
	for _, item := range []struct {
		url  string
		path string
	}{
		{url: plan.K3s.Binary, path: targets["binary"]},
		{url: plan.K3s.Airgap, path: targets["airgap"]},
		{url: plan.K3s.Checksum, path: targets["checksums"]},
	} {
		if err := downloadFile(ctx, client, item.url, item.path); err != nil {
			return payloads{}, err
		}
	}
	expected, err := checksumEntries(targets["checksums"])
	if err != nil {
		return payloads{}, err
	}
	for key, filename := range map[string]string{
		"binary": "k3s-arm64",
		"airgap": "k3s-airgap-images-arm64.tar",
	} {
		want, ok := expected[filename]
		if !ok {
			return payloads{}, fmt.Errorf("release checksum list does not contain %s", filename)
		}
		actual, hashErr := hashFile(targets[key])
		if hashErr != nil {
			return payloads{}, hashErr
		}
		if actual != want {
			return payloads{}, fmt.Errorf(
				"checksum mismatch for %s: expected %s, got %s",
				filename,
				want,
				actual,
			)
		}
	}
	return payloads{binary: targets["binary"], airgap: targets["airgap"]}, nil
}

func downloadFile(ctx context.Context, client *http.Client, sourceURL, destination string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, sourceURL, nil)
	if err != nil {
		return fmt.Errorf("create download request: %w", err)
	}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("download %s: %w", sourceURL, err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("download %s: HTTP %s", sourceURL, response.Status)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	temporary := destination + ".tmp"
	output, err := os.OpenFile(temporary, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(output, response.Body)
	closeErr := output.Close()
	if copyErr != nil {
		_ = os.Remove(temporary)
		return copyErr
	}
	if closeErr != nil {
		_ = os.Remove(temporary)
		return closeErr
	}
	if err := os.Rename(temporary, destination); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func checksumEntries(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	entries := map[string]string{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) != 2 || len(fields[0]) != sha256.Size*2 {
			continue
		}
		entries[filepath.Base(strings.TrimPrefix(fields[1], "*"))] = strings.ToLower(fields[0])
	}
	return entries, scanner.Err()
}

func hashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func (a *App) withInjectedUserpatches(staged payloads, action func() error) error {
	destination := filepath.Join(a.paths.armbian, "userpatches")
	backupRoot, err := os.MkdirTemp(a.paths.armbian, ".userpatches-backup-")
	if err != nil {
		return err
	}
	backup := filepath.Join(backupRoot, "userpatches")
	hadExisting := fileExists(destination)
	if hadExisting {
		if err := os.Rename(destination, backup); err != nil {
			_ = os.Remove(backupRoot)
			return err
		}
	}
	restore := func() error {
		if err := os.RemoveAll(destination); err != nil {
			return err
		}
		if hadExisting {
			if err := os.Rename(backup, destination); err != nil {
				return err
			}
		}
		return os.Remove(backupRoot)
	}
	if err := copyTree(a.paths.userpatches, destination); err != nil {
		_ = restore()
		return err
	}
	binary := filepath.Join(destination, "overlay/usr/local/bin/k3s")
	airgap := filepath.Join(
		destination,
		"overlay/var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar",
	)
	if err := copyFile(staged.binary, binary, 0o755); err != nil {
		_ = restore()
		return err
	}
	if err := copyFile(staged.airgap, airgap, 0o644); err != nil {
		_ = restore()
		return err
	}
	actionErr := action()
	restoreErr := restore()
	if actionErr != nil && restoreErr != nil {
		return fmt.Errorf("%w; userpatches restoration also failed: %v", actionErr, restoreErr)
	}
	if actionErr != nil {
		return actionErr
	}
	return restoreErr
}

func copyTree(source, destination string) error {
	return filepath.WalkDir(source, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, relative)
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return os.MkdirAll(target, info.Mode().Perm())
		}
		if entry.Type()&os.ModeSymlink != 0 {
			link, err := os.Readlink(path)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		}
		return copyFile(path, target, info.Mode().Perm())
	})
}

func copyFile(source, destination string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(output, input)
	closeErr := output.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func (a *App) writeArtifacts(
	plan buildPlan,
	staged payloads,
	builtAfter time.Time,
	timestamp time.Time,
) (string, error) {
	images, err := filepath.Glob(filepath.Join(a.paths.armbian, "output/images/*.img.xz"))
	if err != nil {
		return "", err
	}
	type candidate struct {
		path     string
		modified time.Time
	}
	candidates := []candidate{}
	for _, image := range images {
		info, statErr := os.Stat(image)
		if statErr == nil && !info.ModTime().Before(builtAfter) {
			candidates = append(candidates, candidate{path: image, modified: info.ModTime()})
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].modified.After(candidates[j].modified)
	})
	if len(candidates) == 0 {
		return "", fmt.Errorf("Armbian build produced no new .img.xz image")
	}
	return a.writeArtifactCandidate(plan, staged, candidates[0].path, timestamp)
}

func (a *App) writeNewArtifacts(
	plan buildPlan,
	staged payloads,
	previous map[string]outputState,
	timestamp time.Time,
) (string, error) {
	candidates := newOutputImages(a.paths.armbian, previous)
	if len(candidates) == 0 {
		return "", fmt.Errorf("Armbian build produced no new .img.xz image")
	}
	return a.writeArtifactCandidate(plan, staged, candidates[0], timestamp)
}

func (a *App) writeArtifactCandidate(
	plan buildPlan,
	staged payloads,
	candidate string,
	timestamp time.Time,
) (string, error) {
	if !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(plan.HomeOpsCommit) {
		return "", fmt.Errorf("build plan home-ops commit is not a full commit")
	}
	releaseID := fmt.Sprintf(
		"radxa-5b-plus-%s-%s",
		timestamp.Format("20060102"),
		plan.HomeOpsCommit[:12],
	)
	set, err := ArtifactPaths(filepath.Join(a.paths.artifacts, releaseID+".img.xz"))
	if err != nil {
		return "", err
	}
	for _, path := range []string{set.Image, set.Checksum, set.Manifest} {
		if fileExists(path) {
			return "", fmt.Errorf("artifact set member already exists: %s", path)
		}
	}
	if err := os.MkdirAll(a.paths.artifacts, 0o755); err != nil {
		return "", err
	}
	if err := os.Rename(candidate, set.Image); err != nil {
		return "", err
	}
	keepImage := false
	defer func() {
		if !keepImage {
			_ = os.Remove(set.Image)
			_ = os.Remove(set.Checksum)
			_ = os.Remove(set.Manifest)
		}
	}()
	imageHash, err := hashFile(set.Image)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(
		set.Checksum,
		[]byte(imageHash+"  "+filepath.Base(set.Image)+"\n"),
		0o644,
	); err != nil {
		return "", err
	}
	binaryHash, err := hashFile(staged.binary)
	if err != nil {
		return "", err
	}
	airgapHash, err := hashFile(staged.airgap)
	if err != nil {
		return "", err
	}
	manifest := Manifest{
		SchemaVersion:   1,
		ReleaseID:       releaseID,
		Timestamp:       timestamp.Truncate(time.Second).Format(time.RFC3339),
		HomeOpsCommit:   plan.HomeOpsCommit,
		K3sVersion:      plan.K3s.Version,
		ArmbianCommit:   plan.ArmbianCommit,
		Board:           plan.BuildParameters["BOARD"],
		Branch:          plan.BuildParameters["BRANCH"],
		Release:         plan.BuildParameters["RELEASE"],
		BuildParameters: plan.BuildParameters,
		Files: map[string]FileMetadata{
			"image":      {Filename: filepath.Base(set.Image), SHA256: imageHash},
			"checksum":   {Filename: filepath.Base(set.Checksum)},
			"manifest":   {Filename: filepath.Base(set.Manifest)},
			"k3s_binary": {Filename: "k3s-arm64", SHA256: binaryHash},
			"k3s_airgap": {Filename: "k3s-airgap-images-arm64.tar", SHA256: airgapHash},
		},
	}
	manifestData, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return "", err
	}
	manifestData = append(manifestData, '\n')
	if err := os.WriteFile(set.Manifest, manifestData, 0o644); err != nil {
		return "", err
	}
	keepImage = true
	return set.Image, nil
}
