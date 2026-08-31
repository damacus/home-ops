package provisioning

import (
	"path/filepath"
	"testing"
)

func TestArtifactPathsUseCanonicalSidecars(t *testing.T) {
	t.Parallel()

	image := filepath.Join(t.TempDir(), "radxa-5b-plus-20260830-0123456789ab.img.xz")
	set, err := ArtifactPaths(image + ".sha256")
	if err != nil {
		t.Fatalf("ArtifactPaths() error = %v", err)
	}
	if set.Image != image {
		t.Fatalf("Image = %q, want %q", set.Image, image)
	}
	if set.Checksum != image+".sha256" {
		t.Fatalf("Checksum = %q", set.Checksum)
	}
	wantManifest := filepath.Join(filepath.Dir(image), "radxa-5b-plus-20260830-0123456789ab.manifest.json")
	if set.Manifest != wantManifest {
		t.Fatalf("Manifest = %q, want %q", set.Manifest, wantManifest)
	}
}

func TestArtifactPathsRejectsOtherFiles(t *testing.T) {
	t.Parallel()

	if _, err := ArtifactPaths("image.tar"); err == nil {
		t.Fatal("ArtifactPaths() accepted a non-image file")
	}
}
