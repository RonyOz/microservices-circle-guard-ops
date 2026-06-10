#!/usr/bin/env bash
set -euo pipefail

BASE="http://localhost:18080"
PASS=0; FAIL=0

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

echo "=== E2E: form-service ==="

check_any "Health endpoint"               GET  "/actuator/health"                "200 503"

SURVEY_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/surveys" \
    -H 'Content-Type: application/json' \
    -d '{"anonymousId":"550e8400-e29b-41d4-a716-446655440000","hasFever":false,"hasCough":false}' 2>/dev/null || echo "000")
if [ "$SURVEY_RESPONSE" = "200" ] || [ "$SURVEY_RESPONSE" = "201" ]; then
    echo "  PASS  Submit health survey"
    PASS=$((PASS+1))
else
    echo "  FAIL  Submit health survey (expected 200/201, got $SURVEY_RESPONSE)"
    FAIL=$((FAIL+1))
fi

check "Survey without anonymousId rejected"  POST "/api/v1/surveys" "400" \
    -H 'Content-Type: application/json' \
    -d '{"hasFever":true,"hasCough":true}'

check "Questionnaires: list all"             GET  "/api/v1/questionnaires" "200"

# Full lifecycle: create -> activate -> read active. Deterministic regardless
# of seed data (a fresh database has no active questionnaire, so a bare GET
# /active would legitimately 404).
Q_ID=$(curl -s -X POST "$BASE/api/v1/questionnaires" \
    -H 'Content-Type: application/json' \
    -d '{"title":"e2e symptom check","version":1}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$Q_ID" ]; then
    echo "  PASS  Questionnaire created ($Q_ID)"
    PASS=$((PASS+1))
    check "Questionnaire activate"            POST "/api/v1/questionnaires/$Q_ID/activate" "200"
    check "Questionnaires: get active"        GET  "/api/v1/questionnaires/active" "200"
else
    echo "  FAIL  Questionnaire created (no id in response)"
    FAIL=$((FAIL+1))
fi

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
