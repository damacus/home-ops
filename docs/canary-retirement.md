# Retiring the MedTracker canary

The canary is a synthetic demo, separate from production MedTracker. Its
application, reset job and dedicated database have been removed from GitOps.
The owner has approved discarding its data. Source removal does not by itself
prove that the namespace or database storage has disappeared: the namespace
has historically disabled Flux pruning, and storage reclamation depends on
its persistent-volume policy.

## After merge and reconciliation

Use the explicit production context for this retirement operation. Do not
switch the global context. First confirm that the intended production cluster
is selected and inventory only the dedicated canary namespace:

```console
kubectl --context ironstone cluster-info
kubectl --context ironstone get namespace medtracker-canary
kubectl --context ironstone -n medtracker-canary get deployments,statefulsets,cronjobs,jobs,pods,services,pvc
kubectl --context ironstone -n medtracker-canary get clusters.postgresql.cnpg.io
kubectl --context ironstone get pv -o custom-columns=NAME:.metadata.name,CLAIM_NAMESPACE:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,PHASE:.status.phase
```

Confirm that Flux has reconciled the removal and no longer manages or recreates
these resources. Check that the inventory belongs solely to `medtracker-canary`,
and that production MedTracker remains healthy in its own namespace.

Remove any remaining dedicated namespace, which also requests deletion of its
namespaced application resources and PVCs:

```console
kubectl --context ironstone delete namespace medtracker-canary --ignore-not-found --wait=false
kubectl --context ironstone get namespace medtracker-canary
```

A `NotFound` response confirms namespace deletion. If deletion is still pending,
inspect the remaining resources and controller events; do not force-remove
finalizers. Inspect the persistent-volume inventory again. A retained volume
or backing directory may outlive the PVC: dispose of only volumes whose claim
namespace is exactly `medtracker-canary`, using the storage provider's supported
procedure after confirming their identity. Namespace deletion alone is not
proof that every backing file has been reclaimed.

This is a post-reconciliation operating procedure, not a command run while
preparing the PR. Reverting the manifests can restore resource definitions but
cannot restore discarded database contents.
