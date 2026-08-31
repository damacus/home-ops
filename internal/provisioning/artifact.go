package provisioning

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// FileMetadata records one artifact member or injected K3s payload.
type FileMetadata struct {
	Filename string `json:"filename"`
	SHA256   string `json:"sha256,omitempty"`
}

// Manifest is the immutable provenance contract for one generated image.
type Manifest struct {
	SchemaVersion   int                     `json:"schema_version"`
	ReleaseID       string                  `json:"release_id"`
	Timestamp       string                  `json:"timestamp"`
	HomeOpsCommit   string                  `json:"home_ops_commit"`
	K3sVersion      string                  `json:"k3s_version"`
	ArmbianCommit   string                  `json:"armbian_commit"`
	Board           string                  `json:"board"`
	Branch          string                  `json:"branch"`
	Release         string                  `json:"release"`
	BuildParameters map[string]string       `json:"build_parameters"`
	Files           map[string]FileMetadata `json:"files"`
}

// ArtifactSet identifies the immutable image and its two sidecars.
type ArtifactSet struct {
	Image    string
	Checksum string
	Manifest string
}

type artifactValidation struct {
	ReleaseID string `json:"release_id"`
	Image     string `json:"image"`
	Checksum  string `json:"checksum"`
	Manifest  string `json:"manifest"`
}

func (a *App) runArtifact(ctx context.Context, args []string) error {
	if len(args) == 0 || args[0] != "validate" {
		return usageError{message: "usage: provisioning artifact validate <artifact>"}
	}
	if err := requirePositionals(args[1:], 1, "provisioning artifact validate <artifact>"); err != nil {
		return err
	}
	set, manifest, err := a.validateArtifacts(ctx, args[1])
	if err != nil {
		return err
	}
	return writeJSON(a.exec.stdout, artifactValidation{
		ReleaseID: manifest.ReleaseID,
		Image:     set.Image,
		Checksum:  set.Checksum,
		Manifest:  set.Manifest,
	})
}

// ArtifactPaths accepts any member of an artifact set and returns all members.
func ArtifactPaths(input string) (ArtifactSet, error) {
	image, err := filepath.Abs(input)
	if err != nil {
		return ArtifactSet{}, err
	}
	switch {
	case strings.HasSuffix(image, ".img.xz.sha256"):
		image = strings.TrimSuffix(image, ".sha256")
	case strings.HasSuffix(image, ".manifest.json"):
		image = strings.TrimSuffix(image, ".manifest.json") + ".img.xz"
	}
	if !strings.HasSuffix(image, ".img.xz") {
		return ArtifactSet{}, fmt.Errorf("artifact must be a .img.xz image: %s", input)
	}
	releaseID := strings.TrimSuffix(filepath.Base(image), ".img.xz")
	return ArtifactSet{
		Image:    image,
		Checksum: image + ".sha256",
		Manifest: filepath.Join(filepath.Dir(image), releaseID+".manifest.json"),
	}, nil
}

func (a *App) validateArtifacts(ctx context.Context, input string) (ArtifactSet, Manifest, error) {
	set, err := ArtifactPaths(input)
	if err != nil {
		return ArtifactSet{}, Manifest{}, err
	}
	for _, path := range []string{set.Image, set.Checksum, set.Manifest} {
		info, statErr := os.Stat(path)
		if statErr != nil || !info.Mode().IsRegular() {
			return ArtifactSet{}, Manifest{}, fmt.Errorf("artifact is missing: %s", path)
		}
	}
	checksumFile, err := os.Open(set.Checksum)
	if err != nil {
		return ArtifactSet{}, Manifest{}, err
	}
	scanner := bufio.NewScanner(checksumFile)
	lines := []string{}
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	closeErr := checksumFile.Close()
	if err := scanner.Err(); err != nil {
		return ArtifactSet{}, Manifest{}, err
	}
	if closeErr != nil {
		return ArtifactSet{}, Manifest{}, closeErr
	}
	checksumPattern := regexp.MustCompile(`^([0-9a-fA-F]{64})\s+\*?(.+)$`)
	if len(lines) != 1 {
		return ArtifactSet{}, Manifest{}, fmt.Errorf(
			"checksum sidecar must contain exactly the image hash and filename",
		)
	}
	checksumMatch := checksumPattern.FindStringSubmatch(strings.TrimSpace(lines[0]))
	if len(checksumMatch) != 3 || filepath.Base(checksumMatch[2]) != filepath.Base(set.Image) {
		return ArtifactSet{}, Manifest{}, fmt.Errorf(
			"checksum sidecar must contain exactly the image hash and filename",
		)
	}
	actualHash, err := hashFile(set.Image)
	if err != nil {
		return ArtifactSet{}, Manifest{}, err
	}
	manifestData, err := os.ReadFile(set.Manifest)
	if err != nil {
		return ArtifactSet{}, Manifest{}, err
	}
	manifest := Manifest{Files: map[string]FileMetadata{}, BuildParameters: map[string]string{}}
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		return ArtifactSet{}, Manifest{}, fmt.Errorf("parse artifact manifest: %w", err)
	}
	releaseID := strings.TrimSuffix(filepath.Base(set.Image), ".img.xz")
	canonicalID := regexp.MustCompile(`^radxa-5b-plus-\d{8}-[0-9a-f]{12}$`)
	if !canonicalID.MatchString(releaseID) {
		return ArtifactSet{}, Manifest{}, fmt.Errorf(
			"artifact filename does not contain a canonical release ID",
		)
	}
	if manifest.SchemaVersion != 1 || manifest.ReleaseID != releaseID {
		return ArtifactSet{}, Manifest{}, fmt.Errorf(
			"manifest schema or release ID does not match artifact",
		)
	}
	fullCommit := regexp.MustCompile(`^[0-9a-f]{40}$`)
	if !fullCommit.MatchString(manifest.HomeOpsCommit) {
		return ArtifactSet{}, Manifest{}, fmt.Errorf("manifest home-ops commit is not a full commit")
	}
	if !strings.HasSuffix(releaseID, manifest.HomeOpsCommit[:12]) {
		return ArtifactSet{}, Manifest{}, fmt.Errorf(
			"manifest home-ops commit does not match the release ID",
		)
	}
	if _, err := time.Parse(time.RFC3339, manifest.Timestamp); err != nil {
		return ArtifactSet{}, Manifest{}, fmt.Errorf("manifest timestamp is not RFC 3339: %w", err)
	}
	parameters := buildParameterMap()
	wrongTarget := manifest.Board != parameters["BOARD"] ||
		manifest.Branch != parameters["BRANCH"] ||
		manifest.Release != parameters["RELEASE"]
	if wrongTarget || !maps.Equal(manifest.BuildParameters, parameters) {
		return ArtifactSet{}, Manifest{}, fmt.Errorf(
			"manifest build target does not match the approved build",
		)
	}
	imageMetadata := manifest.Files["image"]
	wantHash := strings.ToLower(checksumMatch[1])
	if wantHash != actualHash || imageMetadata.SHA256 != actualHash {
		return ArtifactSet{}, Manifest{}, fmt.Errorf(
			"image checksum, checksum sidecar, and manifest do not agree",
		)
	}
	if imageMetadata.Filename != filepath.Base(set.Image) ||
		manifest.Files["checksum"].Filename != filepath.Base(set.Checksum) ||
		manifest.Files["manifest"].Filename != filepath.Base(set.Manifest) {
		return ArtifactSet{}, Manifest{}, fmt.Errorf("manifest filenames do not match artifact set")
	}
	binary := manifest.Files["k3s_binary"]
	airgap := manifest.Files["k3s_airgap"]
	validHash := regexp.MustCompile(`^[0-9a-f]{64}$`)
	if binary.Filename != "k3s-arm64" || !validHash.MatchString(binary.SHA256) ||
		airgap.Filename != "k3s-airgap-images-arm64.tar" || !validHash.MatchString(airgap.SHA256) {
		return ArtifactSet{}, Manifest{}, fmt.Errorf("manifest K3s payload metadata is incomplete")
	}
	planData, err := os.ReadFile(a.paths.k3sPlan)
	if err != nil {
		return ArtifactSet{}, Manifest{}, err
	}
	version, err := ResolveK3sVersion(planData)
	if err != nil {
		return ArtifactSet{}, Manifest{}, err
	}
	if manifest.K3sVersion != version {
		return ArtifactSet{}, Manifest{}, fmt.Errorf(
			"manifest K3s version does not match the cluster Plans",
		)
	}
	armbianCommit, err := a.armbianCommit(ctx)
	if err != nil {
		return ArtifactSet{}, Manifest{}, err
	}
	if manifest.ArmbianCommit != armbianCommit {
		return ArtifactSet{}, Manifest{}, fmt.Errorf(
			"manifest Armbian commit does not match the pinned submodule",
		)
	}
	return set, manifest, nil
}

func (a *App) runStage(ctx context.Context, args []string) error {
	dryRun := takeBool(&args, "--dry-run")
	if err := requirePositionals(args, 1, "provisioning stage <artifact> [--dry-run]"); err != nil {
		return err
	}
	set, manifest, err := a.validateArtifacts(ctx, args[0])
	if err != nil {
		return err
	}
	destination := filepath.Join(nasRoot, manifest.ReleaseID)
	if dryRun {
		return writeJSON(a.exec.stdout, map[string]any{
			"validate":    set.Image,
			"copy":        []string{set.Image, set.Checksum, set.Manifest},
			"destination": destination,
		})
	}
	if err := os.MkdirAll(nasRoot, 0o755); err != nil {
		return err
	}
	if fileExists(destination) {
		return fmt.Errorf("staged release already exists: %s", destination)
	}
	temporary, err := os.MkdirTemp(nasRoot, "."+manifest.ReleaseID+".")
	if err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(temporary)
		}
	}()
	for _, source := range []string{set.Image, set.Checksum, set.Manifest} {
		if err := copyFile(source, filepath.Join(temporary, filepath.Base(source)), 0o644); err != nil {
			return err
		}
	}
	if _, _, err := a.validateArtifacts(
		ctx,
		filepath.Join(temporary, filepath.Base(set.Image)),
	); err != nil {
		return err
	}
	if err := os.Rename(temporary, destination); err != nil {
		return err
	}
	committed = true
	return nil
}

func (a *App) runRelease(ctx context.Context, args []string) error {
	dryRun := takeBool(&args, "--dry-run")
	if err := requirePositionals(args, 1, "provisioning release <artifact> [--dry-run]"); err != nil {
		return err
	}
	set, manifest, err := a.validateArtifacts(ctx, args[0])
	if err != nil {
		return err
	}
	files := []string{set.Image, set.Checksum, set.Manifest}
	if dryRun {
		return writeJSON(a.exec.stdout, map[string]any{
			"validate": set.Image,
			"tag":      manifest.ReleaseID,
			"files":    files,
		})
	}
	commandArgs := []string{"release", "create", manifest.ReleaseID}
	commandArgs = append(commandArgs, files...)
	commandArgs = append(
		commandArgs,
		"--title",
		manifest.ReleaseID,
		"--generate-notes",
	)
	return a.exec.run(ctx, a.paths.repo, nil, "gh", commandArgs...)
}
