set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/../../digital-wallet-api"

echo "==> 1. Building Docker image from API repository..."
docker build -f "$PROJECT_ROOT/DigitalWallet.Api/Dockerfile" -t digital-wallet-api:latest "$PROJECT_ROOT"

echo "==> 2. Loading image into kind cluster..."
kind load docker-image digital-wallet-api:latest --name dev-cluster

echo "==> 3. Upgrading Helm release..."
cd "$SCRIPT_DIR/../charts/digital-wallet-chart"
helm upgrade --install digital-wallet-release . -f ../../environments/staging/values.yaml

echo "==> 4. Restarting deployment..."
kubectl rollout restart deployment digital-wallet-release-digital-wallet-chart

echo -e "\n==> Ready! Here is current pods status:"
kubectl get pods