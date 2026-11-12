# Verification

Use the existing Docker Desktop Kubernetes cluster for deployment checks. Do not
add or run Python tests or replace them with another custom test framework.
Test observable behaviour: run the script, call the public interface or exercise
the service in an isolated environment. Add a regression test only when it catches
a concrete failure that existing checks do not cover. Changing an image tag, chart version,
resource name or file layout should not require updating an assertion.

Start with `kubectl --context docker-desktop get nodes --request-timeout=10s`.
Use an explicit context, a dedicated namespace and synthetic data and credentials.
Render the existing pinned Helm chart with its supported values, then install,
upgrade and restart the affected service using Helm and kubectl. Remove only
resources created for the check. Never use production as a development fallback.

Keep `task flux:flate-test`, `task k8s:yayamlls` and Mondoo for rendering, schema
and security posture. These do not establish runtime behaviour. Native Go,
JavaScript, Ruby and alert-rule tests remain where they exercise real behaviour.

## Cases to exercise when changing a service

- MQTT: use the current chart, broker configuration and ACL with dummy passwords.
  Check authenticated publish/subscribe, anonymous and wrong-password denial,
  Home Assistant commands, GrowHAT discovery and cross-device read/write denial.
  Replace the pod and check that a retained message survives.
- Redis: use the current chart and synthetic ACL credentials. Check each app's
  queue, Lua, transaction and pub/sub operations; reject anonymous access, wrong
  passwords and administrative commands. Check noeviction, data after pod
  replacement and password rotation that rejects the old password.
- Loki and kube-state-metrics: check required ordinary-resource access and deny
  Secret get/list/watch with `kubectl auth can-i`. For Loki, check discovery,
  updates and deletion across namespaces using the deployed chart.
- Paperless: inspect separate backup repositories and a paused, separate restore
  claim. Restore synthetic database and document data together and open a document.
- Authentication: verify allowed reads and denied anonymous, write and admin
  requests through the real service. A Python simulation of routing is not proof.
- Maintenance: inspect rendered reboot, drain and replica safeguards. Do not run
  node reboot or destructive maintenance commands against Docker Desktop.
- LiteLLM and migration helpers: verify dry runs, preserved application settings,
  budget/spend preservation, key restrictions and failed-authentication handling
  with synthetic services before changing real accounts.
- Spamhaus: exercise publication with a disposable destination. A failed or
  malformed refresh must preserve both previously published lists.

Record the commands and actual results for the changed service. Running one
service does not establish these cases for the others. Removal of the Python
tests also removes their generator, calculation and failed-publication coverage;
container readiness does not replace those checks.

Docker Desktop does not prove Cilium L7 policies, BGP/UniFi routing, VIP failover,
Rockchip devices, physical reboot/NVMe behaviour, Longhorn replica survival or
NAS recovery. Record these gaps and verify them only through an approved rollout.
