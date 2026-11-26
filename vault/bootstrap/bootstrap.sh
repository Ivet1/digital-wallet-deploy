set -eu

VAULT="${VAULT:-http://vault-0.vault-internal.default.svc:8200}"
NS="${NS:-default}"
SECRET="${SECRET:-vault-init}"
SA_NAME="${SA_NAME:-digital-wallet-app-digital-wallet-chart}"
SA_NS="${SA_NS:-default}"
CONFIGURED=0

log() { echo "[$(date +%T)] $*"; }

get_secret_key() {
  key_name="$1"
  kubectl -n "$NS" get secret "$SECRET" -o jsonpath="{.data.${key_name}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

save_init_and_pg_secret() {
  unseal_key="$1"
  root_token="$2"
  pg_pw="$3"

  kubectl -n "$NS" create secret generic "$SECRET" \
    --from-literal=unseal_key="$unseal_key" \
    --from-literal=root_token="$root_token" \
    --from-literal=postgres_password="$pg_pw" \
    --dry-run=client -o yaml | kubectl apply -f -
}

sync_postgres_secret() {
  token="$1"
  h="X-Vault-Token: $token"
  resp_file="/tmp/vault_pg_resp.json"
  rm -f "$resp_file"

  code=$(curl -sS -o "$resp_file" -w '%{http_code}' -H "$h" "$VAULT/v1/secret/data/digital-wallet/postgres")

  if [ "$code" = "200" ]; then
    pg_pw=$(jq -r '.data.data.password // empty' "$resp_file")
    if [ -z "$pg_pw" ]; then
      log "ERROR: secret/data/digital-wallet/postgres exists (200) but 'password' key is empty"
      return 1
    fi
    existing_pg_pw=$(get_secret_key "postgres_password")
    if [ "$existing_pg_pw" != "$pg_pw" ]; then
      log "syncing postgres_password from Vault into secret/$SECRET"
      kubectl -n "$NS" patch secret "$SECRET" --type='merge' \
        -p "{\"stringData\":{\"postgres_password\":\"$pg_pw\"}}" >/dev/null
    fi
    return 0
  fi

  if [ "$code" = "404" ]; then
    pg_pw=$(get_secret_key "postgres_password")
    if [ -z "$pg_pw" ]; then
      pg_pw="${PG_PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)}"
    fi
    log "creating secret/data/digital-wallet/postgres in Vault"
    jq -n --arg pw "$pg_pw" '{data:{password:$pw}}' \
      | curl -fsS -H "$h" -X POST -d @- "$VAULT/v1/secret/data/digital-wallet/postgres" >/dev/null

    existing_pg_pw=$(get_secret_key "postgres_password")
    if [ "$existing_pg_pw" != "$pg_pw" ]; then
      kubectl -n "$NS" patch secret "$SECRET" --type='merge' \
        -p "{\"stringData\":{\"postgres_password\":\"$pg_pw\"}}" >/dev/null
    fi
    return 0
  fi

  log "ERROR: unexpected HTTP $code when reading secret/data/digital-wallet/postgres: $(cat "$resp_file" 2>/dev/null || true)"
  return 1
}

configure() {
  TOKEN=$(get_secret_key "root_token")
  if [ -z "$TOKEN" ]; then
    log "root token secret not available yet"
    return 1
  fi

  VAULT_ADDR="$VAULT" VAULT_TOKEN="$TOKEN" SA_NAME="$SA_NAME" SA_NS="$SA_NS" ROLE_TTL="24h" \
    /bin/sh /scripts/configure-vault.sh

  sync_postgres_secret "$TOKEN"

  log "vault configured"
  CONFIGURED=1
}

while true; do
  if ! INIT_JSON=$(curl -fsS "$VAULT/v1/sys/init" 2>/dev/null); then
    log "vault not reachable or /v1/sys/init failed"
    sleep 5
    continue
  fi

  INIT=$(echo "$INIT_JSON" | jq -r '.initialized')

  if [ "$INIT" = "false" ]; then
    log "initializing vault"
    RES=$(curl -fsS -X PUT -d '{"secret_shares":1,"secret_threshold":1}' "$VAULT/v1/sys/init")
    KEY=$(echo "$RES" | jq -r '.keys_base64[0] // empty')
    RT=$(echo "$RES" | jq -r '.root_token // empty')
    if [ -z "$KEY" ] || [ -z "$RT" ]; then
      log "ERROR: Vault init response missing keys_base64[0] or root_token"
      sleep 5
      continue
    fi
    PG_PW="${PG_PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)}"
    if ! save_init_and_pg_secret "$KEY" "$RT" "$PG_PW"; then
      log "ERROR: failed saving init secret $SECRET"
      sleep 5
      continue
    fi

  elif [ "$INIT" = "true" ]; then
    SEAL_JSON=$(curl -fsS "$VAULT/v1/sys/seal-status")
    SEALED=$(echo "$SEAL_JSON" | jq -r '.sealed')
    if [ "$SEALED" = "true" ]; then
      CONFIGURED=0
      KEY=$(get_secret_key "unseal_key")
      if [ -z "$KEY" ]; then
        log "ERROR: vault is initialized but unseal_key in secret/$SECRET is missing; delete PVC data-vault-0 and recreate vault-0"
      else
        log "unsealing vault"
        curl -fsS -X PUT -d "{\"key\":\"$KEY\"}" "$VAULT/v1/sys/unseal" >/dev/null
      fi
    elif [ "$SEALED" = "false" ] && [ "$CONFIGURED" = "0" ]; then
      if ! configure; then
        log "ERROR: configure step failed; will retry"
      fi
    fi
  else
    log "ERROR: unexpected initialized state: $INIT"
  fi

  sleep 5
done