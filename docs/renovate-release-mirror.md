# Private image updates through Release Mirror

Renovate uses its native Kubernetes, Flux and Helm-values managers to read and
update the manifests. Exact package rules in `.github/renovate.json5` redirect
the selected images to the `custom.release-mirror` datasource. Their original
image names remain in the manifests and PRs. Only the public alias is sent to
`https://releases.damacus.io/api/v1/services/<alias>/renovate`.

| Image package | Public alias | Tracking |
| --- | --- | --- |
| `forgejo.ironstone.casa/damacus/ironbridge` | `ironbridge` | Numbered upstream tags |
| `forgejo.ironstone.casa/damacus/usage-ledger` | `usage-ledger` | Existing `main` image, pinned by digest |
| `forgejo.ironstone.casa/damacus/northbot` | `northbot` | `main` |
| `ghcr.io/damacus/med-tracker` | `med-tracker` | Numbered upstream tags; production review remains manual |
| `ghcr.io/damacus/unifi-release-announcer` | `unifi-release-announcer` | Numbered upstream tags |
| `ghcr.io/damacus/k8s-reflecto-rs` | `k8s-reflecto-rs` | Numbered upstream tags |

The datasource override replaces Docker lookup for these exact packages; it
does not disable public image updates or all of GHCR. It supports plain image
references, multiple containers, multi-document YAML, separate Helm
`repository` and `tag` fields, and YAML anchors. Numbered tags can receive both
a new version and digest. Moving tags retain their tag and update only their
digest. A tag-only reference receives a digest pin from the catalogue.

Ironbridge's existing `0.3.0` tag was verified against its pinned digest. Ledger's
initial `main` tag was created against its existing image index, preserving its
digest. Neither image was rebuilt. Automated versioned Ledger releases are a
separate producer change; do not invent a release number for the existing image.

The checked `med-tracker-loco` and `home-ops-medtracker-canary-reset` trial
images remain immutable. Their Docker lookups are disabled explicitly. Update
the application image and reset runner's `LOCO_IMAGE` together through the
existing checked canary procedure, not an automatic latest-image update.

## Verify the consumer

Install Renovate 44.222.5 in an isolated directory, then run:

```text
node tests/check_release_mirror.mjs --renovate-dir <directory>/node_modules/renovate
```

The contract reads the actual manifests, runs Renovate extraction and lookup
against a loopback catalogue, and exercises Renovate's replacement engine. It
checks numbered updates, moving tags, digest pins, anchored Helm values,
third-party Docker handling and fixed trial images. It never applies manifests
or reads registry credentials. The GitHub workflow runs the same contract.

## Rollout requirements

Before merging the consumer change, deploy Release Mirror and arrange for each
producer to publish its actual tags and digests under the aliases above. Include
the currently deployed numbered tags so their digests can be resolved. Verify
the alias feeds anonymously and run the real Renovate job in lookup-only mode.
Missing feeds must remain visible as lookup failures; there is no fallback to
private registry access and no automatic deployment merge for these packages.

At preparation time, the public endpoint returned HTTP 404. The local contract
proves consumer behaviour; it does not establish live feed availability,
publisher authentication or hosted Renovate success. No Flux reconciliation or
production rollout is part of this change.
