#!/usr/bin/env bash
# Route a retained Mise facade to Task without confusing Task variables with CLI arguments.
set -euo pipefail

task_name="${1:?missing Task task name}"
shift

task_variables=()
cli_arguments=()
after_separator=false
for argument in "$@"; do
  if [[ "${after_separator}" == false && "${argument}" == -- ]]; then
    after_separator=true
  elif [[ "${after_separator}" == false && "${argument}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    task_variables+=("${argument}")
  else
    cli_arguments+=("${argument}")
  fi
done

exec task "${task_name}" "${task_variables[@]}" -- "${cli_arguments[@]}"
