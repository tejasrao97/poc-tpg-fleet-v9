#!/usr/bin/env bash
# split-first.sh BATCHES_JSON -> /tmp/first.json, /tmp/rest.json, /tmp/has-rest
set -euo pipefail
b="$1"
jq -c '.[0] // []' <<<"$b" > /tmp/first.json
jq -c '.[1:]' <<<"$b" > /tmp/rest.json
if [[ "$(jq 'length' /tmp/rest.json)" -gt 0 ]]; then echo true > /tmp/has-rest; else echo false > /tmp/has-rest; fi
