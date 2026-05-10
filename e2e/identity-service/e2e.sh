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

echo "=== E2E: identity-service ==="

check "Health endpoint"              GET    "/actuator/health"                "200"
check "Register visitor (missing)"   POST   "/api/v1/identities/visitor"     "400"  "-H 'Content-Type: application/json' -d '{}'"

VISITOR_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$BASE/api/v1/identities/visitor" \
    -H 'Content-Type: application/json' \
    -d '{"name":"E2E Test","email":"e2e@test.com","reason_for_visit":"testing"}' 2>/dev/null || echo "000")
VISITOR_CODE=$(echo "$VISITOR_RESPONSE" | tail -1)
VISITOR_BODY=$(echo "$VISITOR_RESPONSE" | head -n -1)
if [ "$VISITOR_CODE" = "200" ]; then
    echo "  PASS  Register visitor"
    PASS=$((PASS+1))
    ANON_ID=$(echo "$VISITOR_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('anonymousId',''))" 2>/dev/null || echo "")
    if [ -n "$ANON_ID" ]; then
        check "Lookup visitor by ID"  GET  "/api/v1/identities/lookup/$ANON_ID"  "200"
    fi
else
    echo "  FAIL  Register visitor (expected 200, got $VISITOR_CODE)"
    FAIL=$((FAIL+1))
fi

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
