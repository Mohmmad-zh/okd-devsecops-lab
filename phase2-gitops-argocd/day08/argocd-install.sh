#!/usr/bin/env bash
# Day 8 — Install Argo CD on OpenShift (CRC)
set -euo pipefail
OC=/usr/local/bin/oc

echo "==> Creating argocd namespace..."
$OC create namespace argocd --dry-run=client -o yaml | $OC apply -f -

echo "==> Downloading Argo CD install manifests..."
curl -sL https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.0/manifests/install.yaml \
  -o /tmp/argocd-install.yaml

echo "==> Applying Argo CD..."
$OC apply -n argocd -f /tmp/argocd-install.yaml

echo "==> Patching Argo CD server for OpenShift (insecure mode — TLS handled by Route)..."
$OC patch deployment argocd-server -n argocd \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]' \
  2>/dev/null || true

echo "==> Creating Route for Argo CD UI..."
cat <<YAML | $OC apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: argocd-server
  namespace: argocd
spec:
  to:
    kind: Service
    name: argocd-server
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
YAML

echo "==> Waiting for Argo CD pods (up to 4 min)..."
$OC wait deployment argocd-server \
  -n argocd --for=condition=Available --timeout=240s

echo ""
echo "==> Argo CD pods:"
$OC get pods -n argocd

echo ""
echo "==> Admin password:"
$OC get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
echo ""
echo ""
echo "==> Argo CD URL:"
$OC get route argocd-server -n argocd -o jsonpath='https://{.spec.host}{"\n"}'
