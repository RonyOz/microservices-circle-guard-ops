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

echo "=== E2E: gateway-service ==="

check "Health endpoint"              GET  "/actuator/health"                    "200"
check "Validate empty token"         POST "/api/v1/gate/validate"              "400"  "-H 'Content-Type: application/json' -d '{}'"
check "Validate malformed token"     POST "/api/v1/gate/validate"              "200"  "-H 'Content-Type: application/json' -d '{\"token\":\"invalid-qr-code\"}'"

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
