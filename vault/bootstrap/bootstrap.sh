#!/bin/sh
# Auto-init, unseal, and configure Vault for local kind clusters.
VAULT="http://vault-0.vault-internal.default.svc:8200"
NS="default"
SECRET="vault-init"
# Random password, used only if Vault has no postgres secret yet (never stored in Git)
PG_PASSWORD="${PG_PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)}"
SA_NAME="${SA_NAME:-digital-wallet-app-digital-wallet-chart}"
SA_NS="${SA_NS:-default}"
CONFIGURED=0

log() { echo "[$(date +%T)] $*"; }

configure() {
  TOKEN=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d)
  [ -z "$TOKEN" ] && { log "root token secret not available yet"; return 1; }
  H="X-Vault-Token: $TOKEN"

  # Enable KV v2 engine at secret/ if not already mounted.
  if ! curl -sf -H "$H" "$VAULT/v1/sys/mounts" | jq -e '."secret/"' >/dev/null 2>&1; then
    log "enabling kv-v2 at secret/"
    curl -sf -H "$H" -X POST -d '{"type":"kv","options":{"version":"2"}}' "$VAULT/v1/sys/mounts/secret" >/dev/null
  fi

  # Enable Kubernetes auth method if not already enabled.
  if ! curl -sf -H "$H" "$VAULT/v1/sys/auth" | jq -e '."kubernetes/"' >/dev/null 2>&1; then
    log "enabling kubernetes auth"
    curl -sf -H "$H" -X POST -d '{"type":"kubernetes"}' "$VAULT/v1/sys/auth/kubernetes" >/dev/null
  fi

  # Configure Kubernetes API endpoint inside the cluster.
  curl -sf -H "$H" -X POST \
    -d '{"kubernetes_host":"https://kubernetes.default.svc:443"}' \
    "$VAULT/v1/auth/kubernetes/config" >/dev/null

  # Write read/list policy for digital-wallet secrets.
  POLICY='path "secret/data/digital-wallet/*" { capabilities = ["read","list"] }
path "secret/metadata/digital-wallet/*" { capabilities = ["read","list"] }'
  jq -n --arg p "$POLICY" '{policy:$p}' | curl -sf -H "$H" -X PUT -d @- \
    "$VAULT/v1/sys/policies/acl/digital-wallet-policy" >/dev/null

  # Bind Kubernetes service account and namespace to the policy.
  jq -n --arg sa "$SA_NAME" --arg ns "$SA_NS" \
    '{bound_service_account_names:$sa, bound_service_account_namespaces:$ns, policies:"digital-wallet-policy", ttl:"24h"}' \
    | curl -sf -H "$H" -X POST -d @- "$VAULT/v1/auth/kubernetes/role/digital-wallet-role" >/dev/null

  # Seed Postgres secret only if it does not exist yet.
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
