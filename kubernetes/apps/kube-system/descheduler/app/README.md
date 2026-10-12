# Descheduler balancing preview

The policy treats a node above 80% of its pod slots as overutilised. A destination
must be below all low thresholds: 50% CPU requests, 50% memory requests and 50%
pod slots. CPU and memory target thresholds remain 75% and 80%.

The deployment is deliberately in dry-run mode. It logs proposed evictions every
five minutes without evicting workloads. Dry-run is incompatible with leader
election, so the preview uses one replica with leader election disabled.

The policy caps evictions at two per node and two across the whole cluster per
cycle, including the other enabled plugins. The existing node-fit, local-storage
and affinity filters remain in place. Real eviction admission must still honour
PodDisruptionBudgets; a dry-run selection does not prove a real eviction will be
accepted or fix the replacement node.

## Preview

Read the deployed logs with an explicit context:

```sh
kubectl --context ironstone -n kube-system logs deployment/descheduler --since=10m
```

Use a completed cycle that reports the real node pod counts. The initial cycle
of a new dry-run process can see an empty simulated pod cache; an all-zero
utilisation result is not a valid preview.

In the live preview on 12 October 2026 at 08:10 BST, the first populated cycle
classified node-0b06a7 (105/110 pods) as overutilised and node-0b0715 (23/110)
as underutilised. It selected monitoring/vm-operator-67759459c5-fdtzw and
reflector/reflector-799bfbc795-pgshd from node-0b06a7, then stopped at the two-pod
limit. Other sampled cycles selected different equal-priority candidates,
including the OpenEBS local PV provisioner and ZITADEL login. No real eviction
requests were sent. Candidate order and eligibility can change with live state.

The descheduler chooses pods to evict; kube-scheduler chooses where replacements
run. node-0b0715 is an eligible destination, not a guaranteed target.

## Activation requires separate approval

Review a fresh populated preview and the affected workloads before enabling
real evictions. In a separate GitOps change, remove the dry-run option, restore
two replicas and enable leader election together. Retain the eviction caps.
Watch availability and replacement placement through the first cycle. Re-enable
the single-replica dry-run configuration through Git if results are unexpected;
this stops further descheduler evictions but does not move already recreated pods
back. Do not use a live restart or eviction as a substitute for this gate.
