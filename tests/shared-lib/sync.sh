#!/usr/bin/env bash
# Copy this repository's shared library block (">>> tpg-shared" ... "<<< tpg-shared")
# over the block in the other repository, so the two copies are identical again:
#   tpg-fleet/workflows/scripts/common.sh  <->  tpg-aks-infra/scripts/lib/common.sh
# Run it in the repository where you edited the block, then commit both.
# The other repository is found next to this one, or through INFRA_LOCAL_DIR
# (from tpg-fleet) / FLEET_LOCAL_DIR (from tpg-aks-infra).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
if [[ -f "$ROOT/workflows/scripts/common.sh" ]]; then
  SELF="$ROOT/workflows/scripts/common.sh"
  OTHER="${INFRA_LOCAL_DIR:-$(cd "$ROOT/.." && pwd)/tpg-aks-infra}/scripts/lib/common.sh"
else
  SELF="$ROOT/scripts/lib/common.sh"
  OTHER="${FLEET_LOCAL_DIR:-$(cd "$ROOT/.." && pwd)/tpg-fleet}/workflows/scripts/common.sh"
fi
[[ -f "$OTHER" ]] || { echo "not found: $OTHER" >&2; exit 1; }
python3 - "$SELF" "$OTHER" <<'PY'
import sys
start, end = "# >>> tpg-shared >>>\n", "# <<< tpg-shared <<<\n"
src = open(sys.argv[1]).read()
block = src[src.index(start):src.index(end) + len(end)]
dst = open(sys.argv[2]).read()
new = dst[:dst.index(start)] + block + dst[dst.index(end) + len(end):]
if new == dst:
    print("already identical:", sys.argv[2])
else:
    open(sys.argv[2], "w").write(new)
    print("copied the tpg-shared block to", sys.argv[2])
PY
