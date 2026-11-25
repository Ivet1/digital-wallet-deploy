#!/bin/sh
VAULT="http://vault-0.vault-internal.default.svc:8200"
NS="default"
SECRET="vault-init"
PG_PASSWORD="${PG_PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)}"
SA_NAME="${SA_NAME:-digital-wallet-app-digital-wallet-chart}"
SA_NS="${SA_NS:-default}"
CONFIGURED=0

log() { echo "[$(date +%T)] $*"; }

configure() {
  TOKEN=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d)
  [ -z "$TOKEN" ] && { log "root token secret not available yet"; return 1; }

  VAULT_ADDR="$VAULT" VAULT_TOKEN="$TOKEN" SA_NAME="$SA_NAME" SA_NS="$SA_NS" ROLE_TTL="24h" \
    /bin/sh /scripts/configure-vault.sh

  H="X-Vault-Token: $TOKEN"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "$H" "$VAULT/v1/secret/data/digital-wallet/postgres")
  if [ "$CODE" = "404" ]; then
    log "creating postgres secret"
    jq -n --arg pw "$PG_PASSWORD" '{data:{password:$pw}}' \
      | curl -s -H "$H" -X POST -d @- "$VAULT/v1/secret/data/digital-wallet/postgres" >/dev/null
  fi

  log "vault configured"
  CONFIGURED=1
}

while true; do
  INIT=$(curl -sf "$VAULT/v1/sys/init" | jq -r .initialized 2>/dev/null)

  if [ "$INIT" = "false" ]; then
    log "initializing vault"
    RES=$(curl -sf -X PUT -d '{"secret_shares":1,"secret_threshold":1}' "$VAULT/v1/sys/init")
    KEY=$(echo "$RES" | jq -r '.keys_base64[0]')
    RT=$(echo "$RES" | jq -r '.root_token')
    if [ -n "$KEY" ] && [ "$KEY" != "null" ] && [ -n "$RT" ] && [ "$RT" != "null" ]; then
      kubectl -n "$NS" create secret generic "$SECRET" \
        --from-literal=unseal_key="$KEY" \
        --from-literal=root_token="$RT" \
        --dry-run=client -o yaml | kubectl apply -f - \
        || log "ERROR saving init secret"
    fi

  elif [ "$INIT" = "true" ]; then
    SEALED=$(curl -sf "$VAULT/v1/sys/seal-status" | jq -r .sealed 2>/dev/null)
    if [ "$SEALED" = "true" ]; then
      CONFIGURED=0
      KEY=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.unseal_key}' 2>/dev/null | base64 -d)
      if [ -z "$KEY" ]; then
        log "vault is initialized but secret $SECRET is missing; delete PVC data-vault-0 and recreate vault-0"
      else
        log "unsealing vault"
        curl -sf -X PUT -d "{\"key\":\"$KEY\"}" "$VAULT/v1/sys/unseal" >/dev/null
      fi
    elif [ "$SEALED" = "false" ] && [ "$CONFIGURED" = "0" ]; then
      configure
    fi
  else
    log "vault not reachable yet"
  fi

  sleep 5
done
