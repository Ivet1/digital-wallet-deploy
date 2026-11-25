#!/bin/sh
set -eu

: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_TOKEN:?VAULT_TOKEN is required}"

SA_NAME="${SA_NAME:-digital-wallet-app-digital-wallet-chart}"
SA_NS="${SA_NS:-default}"
ROLE_TTL="${ROLE_TTL:-24h}"
KUBE_HOST="${KUBE_HOST:-https://kubernetes.default.svc:443}"
H="X-Vault-Token: $VAULT_TOKEN"

if ! curl -sf -H "$H" "$VAULT_ADDR/v1/sys/mounts" | jq -e '."secret/"' >/dev/null 2>&1; then
  curl -sf -H "$H" -X POST -d '{"type":"kv","options":{"version":"2"}}' "$VAULT_ADDR/v1/sys/mounts/secret" >/dev/null
fi

if ! curl -sf -H "$H" "$VAULT_ADDR/v1/sys/auth" | jq -e '."kubernetes/"' >/dev/null 2>&1; then
  curl -sf -H "$H" -X POST -d '{"type":"kubernetes"}' "$VAULT_ADDR/v1/sys/auth/kubernetes" >/dev/null
fi

curl -sf -H "$H" -X POST \
  -d "{\"kubernetes_host\":\"$KUBE_HOST\"}" \
  "$VAULT_ADDR/v1/auth/kubernetes/config" >/dev/null

POLICY='path "secret/data/digital-wallet/*" { capabilities = ["read","list"] }
path "secret/metadata/digital-wallet/*" { capabilities = ["read","list"] }'

jq -n --arg p "$POLICY" '{policy:$p}' | curl -sf -H "$H" -X PUT -d @- \
  "$VAULT_ADDR/v1/sys/policies/acl/digital-wallet-policy" >/dev/null

jq -n --arg sa "$SA_NAME" --arg ns "$SA_NS" --arg ttl "$ROLE_TTL" \
  '{bound_service_account_names:$sa, bound_service_account_namespaces:$ns, policies:"digital-wallet-policy", ttl:$ttl}' \
  | curl -sf -H "$H" -X POST -d @- "$VAULT_ADDR/v1/auth/kubernetes/role/digital-wallet-role" >/dev/null
