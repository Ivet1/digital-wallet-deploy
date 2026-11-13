set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> 1. Building Docker image..."
docker build -f "$SCRIPT_DIR/Dockerfile" -t digital-wallet-api:latest "$PROJECT_ROOT"

echo "==> 2. Loading image into kind cluster..."
kind load docker-image digital-wallet-api:latest --name dev-cluster

echo "==> 3. Upgrading Helm release..."
cd "$SCRIPT_DIR"
helm upgrade --install digital-wallet-release ../digital-wallet-chart

echo "==> 4. Restarting deployment..."
kubectl rollout restart deployment digital-wallet-release-digital-wallet-chart

echo -e "\n==> Ready! Here is current pods status:"
kubectl get pods