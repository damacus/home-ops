# Repository tooling

Mise pins the operator toolchain. Task exposes Kubernetes and service commands;
Mise file tasks expose provisioning operations. List commands with:

```console
mise install
bundle install
task --list
mise tasks
```

Ruby runs the repository's provisioning, cluster-health and UniFi orchestration
without compiling a local binary. The scripts invoke the existing Kubernetes,
Helm, Flux, SSH and Docker tools; those tools retain their normal authentication
and context handling. Use the documented task entry points rather than changing
the global Kubernetes context.

## Operational entry points

- Provisioning: `mise run provisioning:build -- --dry-run`; see the provisioning
  guide before building, flashing, enrolling or retiring a host.
- Cluster health: use the Kubernetes health tasks listed by `task --list`.
  Read-only reports do not authorise remediation.
- UniFi diagnostics: `task unifi:mesh-status`, with `json=true` for structured
  output and `no_ping=true` to omit reachability probes.
- Spamhaus publication runs as a scheduled Ruby workload. It is not a
  workstation command; its application README describes feeds and recovery.

## Retired tooling

The local Go compilation wrappers, repository Python virtualenv and standalone
Python helpers have been removed. There is no automatic electricity analysis,
Mealie provider-cutover helper, LiteLLM key-policy helper or Mondoo scan wrapper.
Use Home Assistant's Energy dashboard, supported application administration
interfaces and the remaining direct cnspec commands as appropriate.

The separate MedTracker canary environment and its reset job have been retired.
Its synthetic database is disposable. The production MedTracker deployment is
independent of that removal.

## Ruby dependencies

Commit the Bundler lockfile with dependency changes. Before publishing, check
for newer stable versions with `bundle outdated` and audit the locked gems:

```console
bundle exec bundle-audit check --update
```

Bundler-Audit checks known gem vulnerabilities and insecure sources. It does
not prove script correctness or replace the gem-version check. An advisory
database update failure must be resolved rather than treated as a clean scan.

The current Bridgetown release constrains four dependencies: amazing_print,
Liquid, Rouge and Samovar. Use their newest compatible stable releases until
upstream supports newer versions; do not override those constraints locally.
Run `bundle outdated --strict` to check compatible updates.
