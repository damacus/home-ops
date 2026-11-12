# Tests

Test observable behaviour: run the script, call the public interface or exercise
the service in an isolated environment. Add a regression test only when it catches
a concrete failure that existing checks do not cover. Changing an image tag, chart version,
resource name or file layout should not require updating an assertion.

Use `task flux:flate-test` for Flux and Helm rendering, `task k8s:yayamlls` for
rendered schema validation, and the existing Mondoo scans for security posture.
Do not duplicate manifest values or workflow commands in Python tests.

Keep narrow safety checks where rendering alone cannot catch the risk: Secret
permissions, CRD pruning, backup isolation, authentication restrictions and
maintenance settings that could force a reboot or lose a replica. These checks
do not prove live access or recovery; use isolated integration tests or an
approved rollout for that evidence.

For deployment verification, prefer the existing local Docker Kubernetes stack.
Check availability with `kubectl --context docker-desktop get nodes --request-timeout=10s`.
Use an explicit `--context docker-desktop` and a dedicated namespace with synthetic
data for local checks; do not change the global context or fall back to production.
Exercise the existing chart with the proposed values and check the affected
application behaviour, including upgrade, restart or denied access where relevant.
Remove only resources created for that verification. Record gaps where Docker
Kubernetes cannot reproduce production storage, networking or hardware.

`tests/loki/test_discovery_integration.py` is an opt-in black box test for a
disposable kind cluster. It covers discovery, updates, deletion and Secret
denial. It must never target the production cluster.
