#!/usr/bin/env bash
# Workflow input types: workflows/params/types.yaml against the generated
# admission policy, the WorkflowTemplates, workflows/params/cluster-map-keys.yaml
# and the Type columns of docs/workflow-commands.md (check_params.py).
# Requires python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP tests/params: python3 PyYAML not installed" >&2; exit 0; }
if out="$(python3 "$HERE/check_params.py")"; then
  echo "ok   types.yaml, the admission policy, the templates, cluster-map-keys.yaml and the docs agree"
  echo
  echo "tests/params: passed"
else
  printf 'FAIL %s\n' "$out" | sed '2,$s/^/FAIL /'
  echo
  echo "tests/params: failed"
  exit 1
fi
