#!/usr/bin/env bash
# Replace the https://github.com/tejasrao97/poc-tpg-fleet-v9.git placeholder with your repository URL.
# Usage: scripts/set-repo-url.sh https://github.com/acme/tpg-fleet.git
set -euo pipefail
URL="${1:?repository URL}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -rl --exclude-dir=.git 'https://github.com/tejasrao97/poc-tpg-fleet-v9.git' "$ROOT" | while read -r f; do
  sed -i.bak "s#https://github.com/tejasrao97/poc-tpg-fleet-v9.git#${URL}#g" "$f" && rm -f "$f.bak"
  echo "updated ${f#"$ROOT"/}"
done
