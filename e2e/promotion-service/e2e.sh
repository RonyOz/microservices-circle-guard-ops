#!/usr/bin/env bash
set -euo pipefail

BASE="http://localhost:18080"
PASS=0; FAIL=0

check() {
    local label="$1" method="$2" path="$3" expected="$4" extra_args="${5:-}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$BASE$path" $extra_args || echo "000")
    if [ "$code" = "$expected" ]; then
        echo "  PASS  $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label (expected $expected, got $code)"
        FAIL=$((FAIL+1))
    fi
}

echo "=== E2E: promotion-service ==="

check "Health endpoint"               GET  "/actuator/health"                     "200"
check "List buildings (empty)"        GET  "/api/v1/buildings/"                  "200"
check "Mesh stats (not found)"        GET  "/api/v1/mesh/stats/e2e-nonexistent"  "404"  "-w '%{http_code}'"
check "Admin settings"                GET  "/api/v1/admin/settings/"              "200"
check "System sessions (not found)"   DELETE "/api/v1/sessions/nonexistent-mac"   "204"

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
