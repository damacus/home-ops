# Longhorn namespace guard

Kubernetes admission policies reject Longhorn custom resources and workloads in
`default`. Workloads are identified by `longhornio` images or the standard
Longhorn component image names, including images mirrored to another registry.
Both normal containers and init containers are checked, including controller
pod templates. Helm installations targeting `default` therefore cannot start a
Longhorn manager, even if the HelmRelease lives in another namespace.

The policies match only `default`. The active installation in `storage` and
ordinary workloads in `default` are unaffected. Deletes remain allowed so the
guard does not obstruct cleanup. This prevents accidental installation; a
cluster administrator can still remove the admission policies.

The storage namespace Kustomization includes this directory directly, separately
from the Longhorn HelmRelease, so uninstalling the chart does not remove the
guard. No Longhorn chart values or webhook configuration are changed.
