set -eu

: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_TOKEN:?VAULT_TOKEN is required}"

SA_NAME="${SA_NAME:-digital-wallet-app-digital-wallet-chart}"
SA_NS="${SA_NS:-default}"
ROLE_TTL="${ROLE_TTL:-24h}"
KUBE_HOST="${KUBE_HOST:-https://kubernetes.default.svc:443}"
H="X-Vault-Token: $VAULT_TOKEN"

vault_post_json() {
  url="$1"
  payload="$2"
  printf '%s' "$payload" | curl -fsS -H "$H" -H "Content-Type: application/json" -X POST -d @- "$url" >/dev/null
}

vault_put_json() {
  url="$1"
  payload="$2"
  printf '%s' "$payload" | curl -fsS -H "$H" -H "Content-Type: application/json" -X PUT -d @- "$url" >/dev/null
}

MOUNTS=$(curl -fsS -H "$H" "$VAULT_ADDR/v1/sys/mounts")
if ! printf '%s' "$MOUNTS" | jq -e '."secret/"' >/dev/null 2>&1; then
  vault_post_json "$VAULT_ADDR/v1/sys/mounts/secret" '{"type":"kv","options":{"version":"2"}}'
fi

AUTH_METHODS=$(curl -fsS -H "$H" "$VAULT_ADDR/v1/sys/auth")
if ! printf '%s' "$AUTH_METHODS" | jq -e '."kubernetes/"' >/dev/null 2>&1; then
  vault_post_json "$VAULT_ADDR/v1/sys/auth/kubernetes" '{"type":"kubernetes"}'
fi

CFG_PAYLOAD=$(jq -n --arg kh "$KUBE_HOST" '{kubernetes_host:$kh}')
vault_post_json "$VAULT_ADDR/v1/auth/kubernetes/config" "$CFG_PAYLOAD"

POLICY='path "secret/data/digital-wallet/*" { capabilities = ["read","list"] }
path "secret/metadata/digital-wallet/*" { capabilities = ["read","list"] }'
POLICY_PAYLOAD=$(jq -n --arg p "$POLICY" '{policy:$p}')
vault_put_json "$VAULT_ADDR/v1/sys/policies/acl/digital-wallet-policy" "$POLICY_PAYLOAD"

ROLE_PAYLOAD=$(jq -n \
  --arg sa "$SA_NAME" \
  --arg ns "$SA_NS" \
  --arg ttl "$ROLE_TTL" \
  '{bound_service_account_names:$sa, bound_service_account_namespaces:$ns, policies:"digital-wallet-policy", ttl:$ttl}')
vault_post_json "$VAULT_ADDR/v1/auth/kubernetes/role/digital-wallet-role" "$ROLE_PAYLOAD"