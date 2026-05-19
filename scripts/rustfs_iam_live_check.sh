#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: rustfs_iam_live_check.sh <policy-name> <access-key> <bucket> [bucket...]

Verifies a live RustFS IAM user and policy using the configured rc alias named
"rustfs". The policy must be attached to the user and scoped only to the
specified bucket(s).
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 3 ]]; then
  usage >&2
  exit 2
fi

require_command rc
require_command jq

policy_name="$1"
access_key="$2"
shift 2
buckets=("$@")

buckets_json="$(jq -cn '$ARGS.positional' --args "${buckets[@]}")"

user_json="$(rc admin user info rustfs "$access_key" --json)"
printf '%s' "$user_json" | jq -e \
  --arg policy_name "$policy_name" \
  '.status == "enabled" and (.policies | index($policy_name) != null)' >/dev/null

policy_json="$(rc admin policy info rustfs "$policy_name" --json)"
printf '%s' "$policy_json" | jq -e \
  --argjson buckets "$buckets_json" \
  '
    def required_bucket_actions: [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads"
    ];

    def required_object_actions: [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ];

    def expected_bucket_resources:
      $buckets | map("arn:aws:s3:::" + .) | sort;

    def expected_object_resources:
      $buckets | map("arn:aws:s3:::" + . + "/*") | sort;

    def actions:
      [.Action[]] | unique | sort;

    def resources:
      [.Resource[]] | unique | sort;

    (.policy.policy | fromjson) as $doc
    | ($doc.Statement | map(select((resources) == expected_bucket_resources)) | length == 1)
    and ($doc.Statement | map(select((resources) == expected_object_resources)) | length == 1)
    and ($doc.Statement | map(select((resources) == expected_bucket_resources)) | .[0] | actions) == (required_bucket_actions | sort)
    and ($doc.Statement | map(select((resources) == expected_object_resources)) | .[0] | actions) == (required_object_actions | sort)
    and ([ $doc.Statement[].Resource[] ] | unique | sort) == ((expected_bucket_resources + expected_object_resources) | unique | sort)
  ' >/dev/null

printf 'ok: %s -> %s scoped to %s\n' "$access_key" "$policy_name" "${buckets[*]}"
