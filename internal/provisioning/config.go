package provisioning

import (
	"path/filepath"
)

const (
	PublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMCLr7NoB34qERAAJNLHKgOy9EJ40smz4F9HhU5d5i8s"
	nasRoot   = "/var/nfs/shared/nfs/provisioning/images/radxa-5b-plus"
)

type buildParameter struct {
	Name  string
	Value string
}

var buildParameters = []buildParameter{
	{Name: "BOARD", Value: "rock-5b-plus"},
	{Name: "BRANCH", Value: "vendor"},
	{Name: "RELEASE", Value: "noble"},
	{Name: "BUILD_MINIMAL", Value: "yes"},
	{Name: "BUILD_DESKTOP", Value: "no"},
	{Name: "KERNEL_CONFIGURE", Value: "no"},
	{Name: "INSTALL_HEADERS", Value: "yes"},
	{Name: "INCLUDE_HOME_DIR", Value: "yes"},
	{Name: "ENABLE_EXTENSIONS", Value: "nvme-rescan"},
	{Name: "COMPRESS_OUTPUTIMAGE", Value: "xz"},
	{Name: "FIXED_IMAGE_SIZE", Value: "3072"},
}

func buildParameterMap() map[string]string {
	parameters := make(map[string]string, len(buildParameters))
	for _, parameter := range buildParameters {
		parameters[parameter.Name] = parameter.Value
	}
	return parameters
}

type paths struct {
	repo         string
	provisioning string
	image        string
	armbian      string
	userpatches  string
	artifacts    string
	staging      string
	k3sPlan      string
}

func newPaths(root string) paths {
	provisioning := filepath.Join(root, "provisioning")
	image := filepath.Join(provisioning, "armbian-build")
	return paths{
		repo:         root,
		provisioning: provisioning,
		image:        image,
		armbian:      filepath.Join(image, "armbian-build-repo"),
		userpatches:  filepath.Join(image, "userpatches"),
		artifacts:    filepath.Join(provisioning, "artifacts"),
		staging:      filepath.Join(image, ".staging"),
		k3sPlan: filepath.Join(
			root,
			"kubernetes/apps/system-upgrade/k3s/app/plan.yaml",
		),
	}
}
