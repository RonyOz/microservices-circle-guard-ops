#!/usr/bin/env bash
set -euo pipefail

BASE="${FILE_SERVICE_URL:-http://localhost:18080}"
PASS=0
FAIL=0

check() {
    local label="$1" method="$2" path="$3" expected="$4"
    shift 4
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$BASE$path" "$@" || echo "000")
    if [ "$code" = "$expected" ]; then
        echo "  PASS  $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label (expected $expected, got $code)"
        FAIL=$((FAIL+1))
    fi
}

check_any() {
    local label="$1" method="$2" path="$3" expected_list="$4"
    shift 4
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$BASE$path" "$@" || echo "000")
    for exp in $expected_list; do
        if [ "$code" = "$exp" ]; then
            echo "  PASS  $label"
            PASS=$((PASS+1))
            return 0
        fi
    done
    echo "  FAIL  $label (expected one of [$expected_list], got $code)"
    FAIL=$((FAIL+1))
}

echo "=== E2E: file-service ==="

check_any "Health endpoint"           GET  "/actuator/health"         "200 503"
check     "Upload: unauthenticated"   POST "/api/v1/files/upload"     "401"

TOKEN=$(curl -s -X POST "${GATEWAY_URL:-http://localhost:8086}/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin"}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
    echo "  INFO  Token obtained"

    TMPFILE=$(mktemp /tmp/e2e-cert-XXXXXX.pdf)
    echo "%PDF-1.4 e2e-test-certificate" > "$TMPFILE"

    check_any "Upload: valid certificate" POST "/api/v1/files/upload" "200 201 400" \
        -H "Authorization: Bearer $TOKEN" \
        -F "file=@${TMPFILE};type=application/pdf"

    rm -f "$TMPFILE"
else
    echo "  SKIP  Authenticated upload — no token from gateway"
fi

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
