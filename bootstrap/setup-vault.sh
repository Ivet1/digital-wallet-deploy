#!/usr/bin/env bash
# Manual recovery script. Vault runs in dev mode (in-memory), so everything it holds is lost when
# the vault-0 pod restarts. Run this afterwards to recreate the Kubernetes auth config, policy,
# role and the database secret.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-digital-wallet-app-digital-wallet-chart}"

echo "Waiting for vault-0 pod to be ready..."
kubectl wait --for=condition=Ready pod/vault-0 -n "$NAMESPACE" --timeout=60s

echo "Waiting for Vault service to respond..."
until kubectl exec -n "$NAMESPACE" vault-0 -- vault status -format=json >/dev/null 2>&1; do
  sleep 2
done

echo "Enabling Kubernetes authentication..."
kubectl exec -n "$NAMESPACE" vault-0 -- vault auth enable kubernetes || true

echo "Configuring Kubernetes auth host..."
kubectl exec -n "$NAMESPACE" vault-0 -- vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc"

echo "Creating Vault policy..."
kubectl exec -i -n "$NAMESPACE" vault-0 -- vault policy write digital-wallet-policy - <<'EOF_POLICY'
path "secret/data/digital-wallet/*" {
  capabilities = ["read"]
}
EOF_POLICY

echo "Creating Vault Kubernetes role..."
kubectl exec -n "$NAMESPACE" vault-0 -- vault write auth/kubernetes/role/digital-wallet-role \
    bound_service_account_names="$SERVICE_ACCOUNT" \
    bound_service_account_namespaces="$NAMESPACE" \
    policies=digital-wallet-policy \
    ttl=1h

echo "Seeding the PostgreSQL password in Vault (taken from the same Secret Postgres uses)..."
DB_PASSWORD="$(kubectl get secret postgres-credentials -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)"
kubectl exec -n "$NAMESPACE" vault-0 -- vault kv put secret/digital-wallet/postgres POSTGRES_PASSWORD="$DB_PASSWORD"

echo "Vault setup completed successfully."
