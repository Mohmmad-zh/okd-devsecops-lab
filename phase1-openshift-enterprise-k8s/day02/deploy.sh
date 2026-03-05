#!/usr/bin/env bash
# Day 2 — Deploy hardened .NET app to OpenShift
# Run this on the VM after: crc start

set -euo pipefail

OC=/usr/local/bin/oc
API=https://api.crc.testing:6443
KUBEADMIN_PASS="WD2J7-fZZr9-XFXIn-qxDvg"
NS=dotnet-demo
MANIFEST_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Logging in as kubeadmin..."
$OC login -u kubeadmin -p "$KUBEADMIN_PASS" "$API" --insecure-skip-tls-verify

echo "==> Applying manifests..."
$OC apply -f "$MANIFEST_DIR/namespace.yaml"
$OC apply -f "$MANIFEST_DIR/deployment.yaml"
$OC apply -f "$MANIFEST_DIR/service.yaml"
$OC apply -f "$MANIFEST_DIR/route.yaml"

echo "==> Granting anyuid SCC so non-root UID 1001 is accepted..."
$OC adm policy add-scc-to-serviceaccount restricted-v2 -z default -n "$NS" 2>/dev/null || true

echo "==> Waiting for rollout..."
$OC rollout status deployment/aspnetapp -n "$NS" --timeout=120s

echo ""
echo "==> Route URL:"
$OC get route aspnetapp -n "$NS" -o jsonpath='https://{.spec.host}{"\n"}'

echo ""
echo "==> Pod status:"
$OC get pods -n "$NS" -o wide

echo ""
echo "==> Resource usage (if metrics-server is available):"
$OC adm top pods -n "$NS" 2>/dev/null || echo "   (metrics not available in CRC — that's fine)"
