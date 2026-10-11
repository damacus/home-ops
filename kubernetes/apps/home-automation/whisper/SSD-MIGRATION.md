# Whisper SSD migration

Live cutover completed on 11 October 2026 with owner approval.

- Original claim: `home-automation/whisper-models`, 20Gi, `nfs-csi-unas`.
- Active claim: `home-automation/whisper-models-ssd`, 20Gi, `nfs-csi-ssd`.
- The original HDD claim remains intact for rollback. Both claims remain in
  `app/pvc.yaml` with pruning disabled.
- Whisper was stopped for the copy. The migration job mounted the source
  read-only and verified SHA-256 hashes, entry types and symbolic link targets:
  24 entries, 335,548,542 bytes. A second source inventory matched the first.
- Helm release revision 89 successfully activated the SSD claim. The running
  container mounts the SSD export at `/data` as UID/GID 1030, with group 100.
- Startup logged `Ready`. A Wyoming `describe` request through the existing
  Service returned `info`. A synthetic one-second audio request returned a
  transcript; this proves inference works, not speech recognition accuracy.
- The changed manifests render successfully with Kustomize; `git diff --check`
  passed. No Home Assistant voice end-to-end test has been performed.

## GitOps follow-up

The local manifests select `whisper-models-ssd` but have not been published.
The live `flux-system/whisper` Kustomization is temporarily suspended, with
`kustomize.toolkit.fluxcd.io/reconcile: disabled` preventing its parent from
undoing this pause. The `home-automation/wyoming-whisper` HelmRelease is active.
Other workloads and their reconciliation are unchanged.

After the owner approves publishing the manifests, verify that the Flux source
revision contains this SSD change. Remove the Kustomization's temporary
`reconcile: disabled` annotation, resume it and verify reconciliation leaves
Whisper attached to `whisper-models-ssd`. Do not resume against the old source:
it selects the HDD claim.

## Rollback

If rollback is needed, pause Whisper's HelmRelease, scale its Deployment to
zero and wait for the pod to exit. Change the HelmRelease's
`spec.values.persistence.models.existingClaim` back to `whisper-models`, then
resume the HelmRelease. Verify model loading and the Wyoming service. Keep both
claims. Align the repository configuration before resuming its Kustomization.

The model cache can be downloaded again. This migration deliberately retains
the source rather than relying on a new download during rollback.
