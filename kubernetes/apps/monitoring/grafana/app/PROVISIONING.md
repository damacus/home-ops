# Grafana file provisioning

Grafana has no Kubernetes API permissions or service-account token. Dashboards and alerts are mounted from named ConfigMaps in monitoring. Its own credentials continue to use explicit Secret references.

The existing reloader auto annotation rolls Grafana when referenced ConfigMaps change. This reloads the UniFi alert file mounted with subPath; preserve this behaviour because subPath mounts do not receive live file updates. Dashboard directories are polled every 30 seconds.

Cilium and CloudNativePG create dashboard ConfigMaps directly in monitoring. Med Tracker dashboard manifests are managed by the Grafana Flux Kustomization. No Secret or ConfigMap mirroring is needed.

Chart-generated dashboard names and file keys are explicit dependencies. Update the mount inventory when upgrading a chart that changes them. A missing required ConfigMap prevents Grafana starting rather than silently dropping a dashboard.

Migration removes discovery only. Existing dashboard JSON, folders, datasource UIDs, alert UIDs, expressions and paused states are retained. Do not remove Grafana without migrating its alert rules and CLI health checks.

## Dashboard inventory

| ConfigMap | Dashboard | Folder |
| --- | --- | --- |
| cilium-dashboard | Cilium Metrics | Cilium |
| cilium-operator-dashboard | Cilium Operator | Cilium |
| cnpg-grafana-dashboard | CloudNativePG | General |
| med-tracker-canary-logs-dashboard | Med Tracker Canary Logs | Home |
| med-tracker-logs-dashboard | Med Tracker Logs | Home |
| unifi-radio-dashboard | UniFi Radio Health | Network |
| vm-dashboard-alertmanager-overview | Alertmanager / Overview | General |
| vm-dashboard-apiserver | Kubernetes / API server | General |
| vm-dashboard-cluster-total | Kubernetes / Networking / Cluster | General |
| vm-dashboard-k8s-resources-cluster | Kubernetes / Compute Resources / Cluster | General |
| vm-dashboard-k8s-resources-multicluster | Kubernetes / Compute Resources /  Multi-Cluster | General |
| vm-dashboard-k8s-resources-namespace | Kubernetes / Compute Resources / Namespace (Pods) | General |
| vm-dashboard-k8s-resources-node | Kubernetes / Compute Resources / Node (Pods) | General |
| vm-dashboard-k8s-resources-nodes-overview | Kubernetes / Compute Resources / Nodes Overview | General |
| vm-dashboard-k8s-resources-pod | Kubernetes / Compute Resources / Pod | General |
| vm-dashboard-k8s-resources-windows-cluster | Kubernetes / Compute Resources / Cluster(Windows) | General |
| vm-dashboard-k8s-resources-windows-namespace | Kubernetes / Compute Resources / Namespace(Windows) | General |
| vm-dashboard-k8s-resources-windows-pod | Kubernetes / Compute Resources / Pod(Windows) | General |
| vm-dashboard-k8s-resources-workload | Kubernetes / Compute Resources / Workload | General |
| vm-dashboard-k8s-resources-workloads-namespace | Kubernetes / Compute Resources / Namespace (Workloads) | General |
| vm-dashboard-k8s-windows-cluster-rsrc-use | Kubernetes / USE Method / Cluster(Windows) | General |
| vm-dashboard-k8s-windows-node-rsrc-use | Kubernetes / USE Method / Node(Windows) | General |
| vm-dashboard-kubelet | Kubernetes / Kubelet | General |
| vm-dashboard-kubernetes-system-api-server | Kubernetes / System / API Server | General |
| vm-dashboard-kubernetes-system-coredns | Kubernetes / System / CoreDNS | General |
| vm-dashboard-kubernetes-views-global | Kubernetes / Views / Global | General |
| vm-dashboard-kubernetes-views-namespaces | Kubernetes / Views / Namespaces | General |
| vm-dashboard-kubernetes-views-nodes | Kubernetes / Views / Nodes | General |
| vm-dashboard-kubernetes-views-pods | Kubernetes / Views / Pods | General |
| vm-dashboard-namespace-by-pod | Kubernetes / Networking / Namespace (Pods) | General |
| vm-dashboard-namespace-by-workload | Kubernetes / Networking / Namespace (Workload) | General |
| vm-dashboard-node-cluster-rsrc-use | Node Exporter / USE Method / Cluster | General |
| vm-dashboard-node-exporter-full | Node Exporter Full | General |
| vm-dashboard-node-rsrc-use | Node Exporter / USE Method / Node | General |
| vm-dashboard-nodes | Node Exporter / Nodes | General |
| vm-dashboard-nodes-aix | Node Exporter / AIX | General |
| vm-dashboard-nodes-darwin | Node Exporter / MacOS | General |
| vm-dashboard-persistentvolumesusage | Kubernetes / Persistent Volumes | General |
| vm-dashboard-pod-total | Kubernetes / Networking / Pod | General |
| vm-dashboard-prometheus | Prometheus / Overview | General |
| vm-dashboard-prometheus-remote-write | Prometheus / Remote Write | General |
| vm-dashboard-victoriametrics-operator | VictoriaMetrics - operator | General |
| vm-dashboard-victoriametrics-single-node | VictoriaMetrics - single-node | General |
| vm-dashboard-victoriametrics-vmagent | VictoriaMetrics - vmagent | General |
| vm-dashboard-victoriametrics-vmalert | VictoriaMetrics - vmalert | General |
| vm-dashboard-workload-total | Kubernetes / Networking / Workload | General |

Eight existing chart-downloaded dashboards remain: API server, CoreDNS, Kubernetes global/namespaces/nodes/pods, Longhorn and Node Exporter Full. Some duplicate the VictoriaMetrics collection.

## Alerts

The directly mounted unifi-radio-alerts ConfigMap retains all three rules and their paused states: unifi-channel-warning, unifi-channel-critical and unifi-telemetry-unavailable. Existing Helm-provisioned backup, WAL, crash-loop and deployment alerts remain unchanged.

## Deployment verification

After merging, verify Flux and Grafana readiness; confirm no discovery containers or API token mounts; check that the Grafana service account cannot get/list/watch Secrets; compare dashboard UIDs and folders and Grafana alert UIDs/paused states against the pre-change inventory. No direct cluster apply is required.
