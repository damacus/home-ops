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

This change does not alter operator RBAC or scrape credentials. Audit Secret
permissions separately against actual credential dependencies.

Before deployment record source PrometheusRule/VMRule definitions and VMAlert's
`/api/v1/rules` response. After Flux applies the change, verify the original
monitoring definitions remain, the 12 expected alerts load and evaluate healthily,
and no second CNPG or Longhorn copy was added. Alertmanager routing is unchanged.
Rollback through Git by reverting namespace selection. Preserve source resources.
