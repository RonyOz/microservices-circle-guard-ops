#!/usr/bin/env bash
# Seed circleguard_qr_validations_total (Grafana panel "QR Validations Rate by result")
# via the forwarded services. Run scripts/port-forward-dev.sh first (NS=<namespace>).
#
# Uso:
#   ./scripts/seed-qr-metrics.sh
#   AUTH_BASE=http://localhost:8180 GATEWAY_BASE=http://localhost:8087 ./scripts/seed-qr-metrics.sh
set -euo pipefail

AUTH_BASE="${AUTH_BASE:-http://localhost:8180}"
GATEWAY_BASE="${GATEWAY_BASE:-http://localhost:8087}"
CG_USER="${CG_USER:-staff_guard}"
CG_PASS="${CG_PASS:-password}"
# Must match qr.secret on auth/gateway (default from application.yml, unset in charts)
QR_SECRET="${QR_SECRET:-my-qr-secret-key-for-dev-1234567890}"
INVALID_COUNT="${INVALID_COUNT:-1}"
SUCCESS_COUNT="${SUCCESS_COUNT:-1}"

json_field() {
    python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || echo ""
}

# validate <label> <payload> -> prints response, returns 0 if HTTP 200 and valid:true
validate() {
    local label="$1" payload="$2"
    local response code body
    response=$(curl -s -w '\n%{http_code}' -X POST "$GATEWAY_BASE/api/v1/gate/validate" \
        -H 'Content-Type: application/json' -d "$payload" || echo -e '\n000')
    code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)
    echo "  [$label] HTTP $code -> $body"
    [ "$code" = "200" ] && echo "$body" | grep -q '"valid":true'
}

# Mint a QR JWT locally (HS256, same shape as QrTokenService) for the given subject
mint_qr_token() {
    python3 - "$QR_SECRET" "$1" <<'EOF'
import base64, hashlib, hmac, json, sys, time
def b64(d): return base64.urlsafe_b64encode(d).rstrip(b"=")
secret, sub = sys.argv[1], sys.argv[2]
header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
now = int(time.time())
payload = b64(json.dumps({"sub": sub, "iat": now, "exp": now + 60}).encode())
sig = b64(hmac.new(secret.encode(), header + b"." + payload, hashlib.sha256).digest())
print((header + b"." + payload + b"." + sig).decode())
EOF
}

echo "=== Seed: circleguard_qr_validations_total ==="
echo "  Auth:    $AUTH_BASE"
echo "  Gateway: $GATEWAY_BASE"
echo

echo "--- result=invalid (${INVALID_COUNT}x garbage token) ---"
for i in $(seq 1 "$INVALID_COUNT"); do
    validate "invalid #$i" '{"token":"seed-invalid-token"}' || true
done
echo

echo "--- result=success (login -> qr/generate -> validate, ${SUCCESS_COUNT}x) ---"
LOGIN_BODY=$(curl -s -X POST "$AUTH_BASE/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$CG_USER\",\"password\":\"$CG_PASS\"}")
TOKEN=$(echo "$LOGIN_BODY" | json_field token)
ANON_ID=$(echo "$LOGIN_BODY" | json_field anonymousId)

if [ -z "$TOKEN" ] || [ -z "$ANON_ID" ]; then
    echo "  ERROR: login failed for user '$CG_USER' against $AUTH_BASE" >&2
    echo "  The invalid samples above were still recorded; success samples skipped." >&2
    exit 1
fi
echo "  login OK (anonymousId=$ANON_ID)"

for i in $(seq 1 "$SUCCESS_COUNT"); do
    QR_TOKEN=$(curl -s "$AUTH_BASE/api/v1/auth/qr/generate" \
        -H "Authorization: Bearer $TOKEN" | json_field qrToken)
    if [ -n "$QR_TOKEN" ] && validate "success #$i (backend token)" "{\"token\":\"$QR_TOKEN\"}"; then
        continue
    fi
    # Deployed auth-service may still issue 300ms-lived tokens (pre-fix); mint a
    # 60s-lived token locally with the shared qr.secret instead.
    echo "  backend token rejected — minting local 60s token"
    LOCAL_TOKEN=$(mint_qr_token "$ANON_ID")
    validate "success #$i (local token)" "{\"token\":\"$LOCAL_TOKEN\"}" || {
        echo "  ERROR: locally minted token also rejected (QR_SECRET mismatch or user status denied)" >&2
        exit 1
    }
done
echo

echo "Done. Prometheus scrapes every 30s; panel uses rate[5m] — wait ~1 min in Grafana."
