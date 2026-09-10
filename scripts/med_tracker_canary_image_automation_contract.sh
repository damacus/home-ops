#!/usr/bin/env bash

set -euo pipefail

repo_root="${1:?repository root is required}"
flux_system="$repo_root/kubernetes/apps/flux-system"
automation_app="$flux_system/image-automation/app"
canary_release="$repo_root/kubernetes/apps/home/med-tracker-canary/app/helmrelease.yaml"
production_release="$repo_root/kubernetes/apps/home/med-tracker/app/helmrelease.yaml"
deployed_digest="sha256:41d783a8f0a2fdf5fb33569131c5f51ddc53bc868f7f6660a37cfce90e8b8ead"

assert_yq() {
  local expression="$1"
  local file="$2"
  if ! yq -e "$expression" "$file" >/dev/null; then
    echo "contract failed for $file: $expression" >&2
    exit 1
  fi
}

assert_yq '.resources | contains(["./image-automation/ks.yaml"])' "$flux_system/kustomization.yaml"
assert_yq '.resources | length == 5' "$automation_app/kustomization.yaml"
assert_yq '.resources[0] == "externalsecret.yaml" and .resources[1] == "gitrepository.yaml" and .resources[2] == "imagerepository.yaml" and .resources[3] == "imagepolicy.yaml" and .resources[4] == "imageupdateautomation.yaml"' "$automation_app/kustomization.yaml"

assert_yq '.spec.secretStoreRef.kind == "ClusterSecretStore" and .spec.secretStoreRef.name == "onepassword" and .spec.target.name == "patchbotmcbotface-github-app"' "$automation_app/externalsecret.yaml"
assert_yq '.spec.dataFrom[0].extract.key == "flux"' "$automation_app/externalsecret.yaml"
assert_yq '.spec.target.template.data.githubAppID == "{{ .PATCHBOT_GITHUB_APP_ID }}" and .spec.target.template.data.githubAppInstallationID == "{{ .PATCHBOT_GITHUB_APP_INSTALLATION_ID }}" and .spec.target.template.data.githubAppPrivateKey == "{{ .PATCHBOT_GITHUB_APP_PRIVATE_KEY }}" and (.spec.target.template.data | has("githubAppInstallationOwner") | not)' "$automation_app/externalsecret.yaml"

assert_yq '.spec.provider == "github" and .spec.url == "https://github.com/damacus/home-ops.git" and .spec.ref.branch == "main" and .spec.secretRef.name == "patchbotmcbotface-github-app"' "$automation_app/gitrepository.yaml"
assert_yq '.spec.image == "ghcr.io/damacus/med-tracker" and .spec.interval == "1m" and .spec.secretRef.name == "ghcr-credentials"' "$automation_app/imagerepository.yaml"
assert_yq '.spec.imageRepositoryRef.name == "med-tracker-beta" and .spec.filterTags.pattern == "^beta$" and .spec.digestReflectionPolicy == "Always" and .spec.interval == "1m"' "$automation_app/imagepolicy.yaml"

assert_yq '.spec.suspend == true and .spec.interval == "1m" and .spec.sourceRef.kind == "GitRepository" and .spec.sourceRef.name == "home-ops-image-automation"' "$automation_app/imageupdateautomation.yaml"
assert_yq '.spec.update.path == "./kubernetes/apps/home/med-tracker-canary/app" and .spec.update.strategy == "Setters"' "$automation_app/imageupdateautomation.yaml"
assert_yq '.spec.policySelector.matchLabels."image.toolkit.fluxcd.io/automation" == "med-tracker-canary"' "$automation_app/imageupdateautomation.yaml"
assert_yq '.spec.git.checkout.ref.branch == "main" and .spec.git.push.branch == "main" and .spec.git.commit.author.name == "Dan Webb" and .spec.git.commit.author.email == "dan.webb@damacus.io" and .spec.git.commit.messageTemplate == "chore(med-tracker): update canary beta digest\n"' "$automation_app/imageupdateautomation.yaml"

assert_yq 'explode(.) | [.spec.values.controllers[].initContainers[]?.image, .spec.values.controllers[].containers[]?.image] | length == 5' "$canary_release"
assert_yq "explode(.) | ([.spec.values.controllers[].initContainers[]?.image, .spec.values.controllers[].containers[]?.image] | map(select(.repository == \"ghcr.io/damacus/med-tracker\" and .tag == \"beta\" and .digest == \"$deployed_digest\" and .pullPolicy == \"Always\")) | length) == 5" "$canary_release"
if [[ "$(rg -c '\$imagepolicy' "$canary_release")" -ne 1 ]]; then
  echo "contract failed: Canary must contain exactly one Flux image policy marker" >&2
  exit 1
fi
rg -F '# {"$imagepolicy": "flux-system:med-tracker-beta:digest"}' "$canary_release" >/dev/null

if rg -q 'beta|\$imagepolicy|digestReflectionPolicy|ImageUpdateAutomation' "$production_release"; then
  echo "contract failed: production MedTracker must remain outside beta automation" >&2
  exit 1
fi

printf 'MedTracker Canary image automation contract passed\n'
