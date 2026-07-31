#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tempo_privacy_check.sh <tempo-trace.json> <loki-response.json>

Checks every scalar key and value in bounded Tempo and Loki JSON responses.
The command prints only failing JSON paths; it never prints inspected values.
Set TEMPO_PRIVACY_DENY_PATTERN to add release-specific prohibited value terms.
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

for command in jq rg; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
done

trace_json="$1"
loki_json="$2"

for input in "$trace_json" "$loki_json"; do
  if [[ ! -f "$input" ]]; then
    echo "Missing privacy input: $input" >&2
    exit 1
  fi
  jq -e . "$input" >/dev/null
done

key_pattern='(^|[._])(authorization|cookie|credential|medication|medicine|dose|dosage|person|household|patient|request[._]?body|response[._]?body|db[._]?statement|exception[._]?(message|stacktrace)|password|secret|token|email|user)([._]|$)'
value_pattern='(bearer[[:space:]]+|basic[[:space:]]+|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|medication|medicine|dosage|dose|household|patient|person|password|secret|authorization|cookie|request[._ -]?body|response[._ -]?body)'
if [[ -n "${TEMPO_PRIVACY_DENY_PATTERN:-}" ]]; then
  value_pattern="($value_pattern|${TEMPO_PRIVACY_DENY_PATTERN})"
fi

violations=0
for input in "$trace_json" "$loki_json"; do
  while IFS=$'\t' read -r json_path scalar_value; do
    if printf '%s' "$json_path" | rg --quiet --ignore-case "$key_pattern"; then
      echo "privacy check failed at $input:$json_path (prohibited key)" >&2
      violations=$((violations + 1))
      continue
    fi

    if printf '%s' "$scalar_value" | rg --quiet --ignore-case "$value_pattern"; then
      echo "privacy check failed at $input:$json_path (prohibited value)" >&2
      violations=$((violations + 1))
    fi
  done < <(
    jq -r '
      paths(scalars) as $path
      | [
          ($path | map(tostring) | join(".")),
          (getpath($path) | tostring)
        ]
      | @tsv
    ' "$input"
  )
done

if [[ "$violations" -ne 0 ]]; then
  echo "Tempo privacy check rejected $violations prohibited field(s)" >&2
  exit 1
fi

echo "Tempo privacy check passed"
