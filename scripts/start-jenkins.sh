#!/usr/bin/env bash
# Builds and starts the Jenkins container, and writes a kubeconfig for it.
# Safe to re-run: the container is recreated, Jenkins data stays in the "jenkins_home" volume.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="inventory-jenkins:local"
docker build -t "$IMAGE" jenkins/

# Group that owns the Docker socket as seen from inside containers (differs between hosts)
DOCKER_GID="$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  --entrypoint stat "$IMAGE" -c %g /var/run/docker.sock)"

docker rm -f jenkins >/dev/null 2>&1 || true
docker run -d --name jenkins --restart unless-stopped \
  -p 127.0.0.1:8081:8080 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$DOCKER_GID" \
  --network minikube \
  "$IMAGE" >/dev/null

# Jenkins reaches the cluster over the "minikube" Docker network, not via 127.0.0.1
MINIKUBE_IP="$(minikube ip)"
kubectl config view --flatten --minify --context minikube \
  | sed -E "s#server: https://[^[:space:]]+#server: https://${MINIKUBE_IP}:8443#" \
  > "$HOME/jenkins-kubeconfig"
chmod 600 "$HOME/jenkins-kubeconfig"

echo "Jenkins is starting on http://localhost:8081"
echo "Kubeconfig for the Jenkins credential: $HOME/jenkins-kubeconfig"
echo
echo "Checking tools inside the container:"
sleep 5
docker exec jenkins sh -c 'docker version --format "docker {{.Server.Version}}" && kubectl version --client | head -1 && helm version --short && python3 --version && node --version'
