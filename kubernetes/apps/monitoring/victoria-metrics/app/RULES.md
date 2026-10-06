# VictoriaMetrics rule discovery

VMAlert reads VMRule resources. The operator converts existing PrometheusRules;
Alertmanager receives evaluated alerts and does not load these rule definitions.

Select these namespace names explicitly:

| Namespace | Coverage |
| --- | --- |
| monitoring | Existing chart defaults, miscellaneous rules, Longhorn and Tempo |
| cert-manager | Certificate readiness and expiry |
| home-automation | One global CloudNativePG rule set covering all scraped databases |
| kube-system | Kured reboot coordination |

The October 6 source and loaded-rule comparison found 188 alert definitions in
42 loaded groups (274 total alert and recording definitions). Namespace selection
was missing, so VMAlert loaded only monitoring rules. This change should add 12
alert definitions: four cert-manager, six database and two Kured. Counts depend
on the source inventory remaining unchanged; compare full identities and queries,
not counts alone, after deployment.

The database rule resources in home repeat the same unfiltered queries as the
six-rule set in home-automation. The five-rule canary set is a subset. Keep their
resources in place but exclude home from selection to avoid repeated evaluation.
Storage contains the same 11 Longhorn queries already loaded from monitoring,
and a legacy MinIO rule set whose targets have not been qualified. Keep storage
excluded. Do not select all namespaces until those additional sources are needed
and duplicates have been resolved.

Flux rules remain deliberately excluded. The parent flux-system Kustomization
includes neither the monitoring directory nor flux-instance/ks.yaml, and the live
flux-system namespace has no PrometheusRule or VMRule resources. Selecting that
namespace would not add rules. Enable and qualify those sources separately,
including their metric dependencies, before adding the namespace.

Kured chart 6.1.0 requires metrics.create=true to render its metrics Service and
ServiceMonitor. This PR enables both. The operator converts the ServiceMonitor
into a VMServiceScrape; VMagent's existing all-monitor selection must discover it.
Loading RebootRequired alone does not prove coverage: its kured_reboot_required
series must be present and fresh for every Kured pod after rollout.

The existing Flate Test and Yayamlls CI jobs render the pinned Helm charts on
Kubernetes changes; Mondoo also scans those rendered manifests. There is no
optional VM_CHART_PATH test. These structural checks do not prove live metric
collection or successful rule evaluation; the rollout checks below do.

This change does not alter operator RBAC or scrape credentials. Audit Secret
permissions separately against actual credential dependencies.

Before deployment record source PrometheusRule/VMRule definitions and VMAlert's
`/api/v1/rules` response. After Flux applies the change, verify the original
monitoring definitions remain, the 12 expected alerts load and evaluate healthily,
and no second CNPG or Longhorn copy was added. Verify the converted Kured
VMServiceScrape, healthy scrape targets, and a fresh kured_reboot_required sample
for every Kured pod. Query up and timestamp(kured_reboot_required), rather than
relying on alert counts or a healthy rule with an empty result. Alertmanager
routing is unchanged.
Rollback through Git by reverting namespace selection and Kured metrics creation. Preserve source resources.
