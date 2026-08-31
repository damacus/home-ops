package provisioning

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var k3sVersionPattern = regexp.MustCompile(`(?m)^\s*version:\s*(v\d+\.\d+\.\d+\+k3s\d+)\s*$`)

// ResolveK3sVersion returns the one version shared by both system-upgrade Plans.
func ResolveK3sVersion(plan []byte) (string, error) {
	matches := k3sVersionPattern.FindAllSubmatch(plan, -1)
	if len(matches) != 2 {
		return "", fmt.Errorf("expected two K3s Plan versions, found %d", len(matches))
	}
	first := string(matches[0][1])
	second := string(matches[1][1])
	if first != second {
		return "", fmt.Errorf("K3s Plan versions differ: %s, %s", first, second)
	}
	return first, nil
}

type releaseURLs struct {
	Binary   string `json:"binary_url"`
	Airgap   string `json:"airgap_url"`
	Checksum string `json:"checksum_url"`
}

type k3sBuild struct {
	Version string `json:"version"`
	releaseURLs
}

type buildPlan struct {
	K3s             k3sBuild          `json:"k3s"`
	HomeOpsCommit   string            `json:"home_ops_commit"`
	ArmbianCommit   string            `json:"armbian_commit"`
	BuildParameters map[string]string `json:"build_parameters"`
}

func urlsForVersion(version string) releaseURLs {
	baseURL := os.Getenv("PROVISIONING_K3S_RELEASE_BASE_URL")
	if baseURL == "" {
		baseURL = os.Getenv("K3S_RELEASE_BASE_URL")
	}
	if baseURL == "" {
		baseURL = "https://github.com/k3s-io/k3s/releases/download"
	}
	encodedVersion := strings.ReplaceAll(url.PathEscape(version), "+", "%2B")
	base := strings.TrimRight(baseURL, "/") + "/" + encodedVersion
	return releaseURLs{
		Binary:   base + "/k3s-arm64",
		Airgap:   base + "/k3s-airgap-images-arm64.tar",
		Checksum: base + "/sha256sum-arm64.txt",
	}
}

func (a *App) buildPlan(ctx context.Context) (buildPlan, error) {
	planData, err := os.ReadFile(a.paths.k3sPlan)
	if err != nil {
		return buildPlan{}, fmt.Errorf("read K3s Plans: %w", err)
	}
	version, err := ResolveK3sVersion(planData)
	if err != nil {
		return buildPlan{}, err
	}
	homeOpsCommit, err := a.repoCommit(ctx)
	if err != nil {
		return buildPlan{}, err
	}
	armbianCommit, err := a.armbianCommit(ctx)
	if err != nil {
		return buildPlan{}, err
	}
	return buildPlan{
		K3s:             k3sBuild{Version: version, releaseURLs: urlsForVersion(version)},
		HomeOpsCommit:   homeOpsCommit,
		ArmbianCommit:   armbianCommit,
		BuildParameters: buildParameterMap(),
	}, nil
}

func (a *App) repoCommit(ctx context.Context) (string, error) {
	commit, err := a.exec.output(ctx, a.paths.repo, nil, "git", "rev-parse", "HEAD")
	if err != nil {
		return "", err
	}
	if !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(commit) {
		return "", fmt.Errorf("repository HEAD is not a full commit: %s", commit)
	}
	return commit, nil
}

func (a *App) armbianCommit(ctx context.Context) (string, error) {
	relative, err := filepath.Rel(a.paths.repo, a.paths.armbian)
	if err != nil {
		return "", err
	}
	output, err := a.exec.output(
		ctx,
		a.paths.repo,
		nil,
		"git",
		"ls-files",
		"--stage",
		"--",
		relative,
	)
	if err != nil {
		return "", err
	}
	match := regexp.MustCompile(`^160000 ([0-9a-f]{40}) 0\t.+$`).FindStringSubmatch(output)
	if len(match) != 2 {
		return "", fmt.Errorf("%s is not a pinned git submodule", a.paths.armbian)
	}
	return match[1], nil
}

func (a *App) requirePinnedSubmodule(ctx context.Context, expected string) error {
	if !fileExists(filepath.Join(a.paths.armbian, ".git")) {
		return fmt.Errorf(
			"Armbian submodule is not initialised; run git submodule update --init -- %s",
			a.paths.armbian,
		)
	}
	actual, err := a.exec.output(ctx, a.paths.armbian, nil, "git", "rev-parse", "HEAD")
	if err != nil {
		return err
	}
	if actual != expected {
		return fmt.Errorf("Armbian submodule is at %s, expected %s", actual, expected)
	}
	return nil
}

func (a *App) requireCleanBuildSources(ctx context.Context) error {
	relevant := []string{
		".mise/tasks/provisioning",
		"cmd/provisioning",
		"internal/provisioning",
		"mise.toml",
		"mise.lock",
		"provisioning",
		"kubernetes/apps/system-upgrade/k3s/app/plan.yaml",
		":(exclude)provisioning/armbian-build/.staging",
	}
	args := []string{"status", "--porcelain", "--untracked-files=all", "--"}
	args = append(args, relevant...)
	dirty, err := a.exec.output(ctx, a.paths.repo, nil, "git", args...)
	if err != nil {
		return err
	}
	if dirty != "" {
		return fmt.Errorf("build inputs are dirty; commit or remove these changes first:\n%s", dirty)
	}
	return nil
}

func (a *App) requireCleanArmbian(
	ctx context.Context,
	expected string,
	allowUserpatches bool,
) error {
	if err := a.requirePinnedSubmodule(ctx, expected); err != nil {
		return err
	}
	args := []string{
		"status",
		"--porcelain",
		"--untracked-files=all",
		"--ignored",
		"--",
		".",
		":(exclude)cache",
		":(exclude)output",
		":(exclude).tmp",
	}
	if allowUserpatches {
		args = append(args, ":(exclude)userpatches")
	}
	dirty, err := a.exec.output(ctx, a.paths.armbian, nil, "git", args...)
	if err != nil {
		return err
	}
	remaining := []string{}
	for _, line := range strings.Split(dirty, "\n") {
		if line == "" || line == "!! Dockerfile" || line == "!! .dockerignore" {
			continue
		}
		remaining = append(remaining, line)
	}
	if len(remaining) != 0 {
		return fmt.Errorf("pinned Armbian checkout is dirty:\n%s", strings.Join(remaining, "\n"))
	}
	return nil
}

func (a *App) requireArmbianCommand(command, handler string) error {
	path := filepath.Join(a.paths.armbian, "lib/functions/cli/commands.sh")
	contents, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read Armbian command registry: %w", err)
	}
	needle := regexp.MustCompile(fmt.Sprintf(
		`(?m)^\s*\["%s"\]\s*=\s*"%s"(\s|#|$)`,
		regexp.QuoteMeta(command),
		regexp.QuoteMeta(handler),
	))
	if !needle.Match(contents) {
		return fmt.Errorf("pinned Armbian source does not register compile.sh %s", command)
	}
	return nil
}

func (a *App) requireBuildContract(ctx context.Context, expected string) error {
	if err := a.requireCleanArmbian(ctx, expected, true); err != nil {
		return err
	}
	if err := a.requireArmbianCommand("build", "standard_build"); err != nil {
		return err
	}
	partitioning := filepath.Join(a.paths.armbian, "lib/functions/image/partitioning.sh")
	contents, err := os.ReadFile(partitioning)
	if err != nil {
		return fmt.Errorf("read Armbian partitioning implementation: %w", err)
	}
	if !strings.Contains(string(contents), "FIXED_IMAGE_SIZE") {
		return fmt.Errorf("pinned Armbian source does not support FIXED_IMAGE_SIZE")
	}
	return nil
}

func (a *App) requireBuildInputsUnchanged(ctx context.Context, plan buildPlan) error {
	commit, err := a.repoCommit(ctx)
	if err != nil {
		return err
	}
	if commit != plan.HomeOpsCommit {
		return fmt.Errorf(
			"home-ops HEAD changed during build: expected %s, found %s",
			plan.HomeOpsCommit,
			commit,
		)
	}
	if err := a.requireCleanBuildSources(ctx); err != nil {
		return err
	}
	return a.requireBuildContract(ctx, plan.ArmbianCommit)
}

func (a *App) runArmbian(ctx context.Context, args []string) error {
	if len(args) == 0 || args[0] != "check" {
		return usageError{message: "usage: provisioning armbian check docker-purge"}
	}
	if err := requirePositionals(args[1:], 1, "provisioning armbian check docker-purge"); err != nil {
		return err
	}
	if args[1] != "docker-purge" {
		return usageError{message: "usage: provisioning armbian check docker-purge"}
	}
	expected, err := a.armbianCommit(ctx)
	if err != nil {
		return err
	}
	if err := a.requireCleanArmbian(ctx, expected, false); err != nil {
		return err
	}
	return a.requireArmbianCommand("docker-purge", "docker")
}

func (p buildPlan) marshal() ([]byte, error) {
	return json.MarshalIndent(p, "", "  ")
}
