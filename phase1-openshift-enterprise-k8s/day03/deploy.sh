#!/usr/bin/env bash
# Day 3 — Apply security hardening to dotnet-demo namespace
set -euo pipefail

OC=/usr/local/bin/oc
API=https://api.crc.testing:6443
NS=dotnet-demo

echo "==> Logging in..."
$OC login -u kubeadmin -p WD2J7-fZZr9-XFXIn-qxDvg "$API" --insecure-skip-tls-verify

echo ""
echo "==> Applying ResourceQuota..."
$OC apply -f ~/day03/resourcequota.yaml
$OC describe resourcequota dotnet-demo-quota -n "$NS"

echo ""
echo "==> Applying LimitRange..."
$OC apply -f ~/day03/limitrange.yaml
$OC describe limitrange dotnet-demo-limits -n "$NS"

echo ""
echo "==> Applying NetworkPolicies..."
$OC apply -f ~/day03/networkpolicy.yaml
$OC get networkpolicy -n "$NS"

echo ""
echo "==> Verifying app still responds through the Route..."
ROUTE_HOST=$($OC get route aspnetapp -n "$NS" -o jsonpath='{.spec.host}')
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$ROUTE_HOST")
if [ "$HTTP_CODE" = "200" ]; then
  echo "    App reachable via Route — HTTP $HTTP_CODE"
else
  echo "    WARNING: Got HTTP $HTTP_CODE — check NetworkPolicy"
fi

echo ""
echo "==> Verifying quota enforcement — try to create a pod that exceeds limits..."
$OC run quota-test --image=busybox --restart=Never \
  --limits='cpu=4,memory=4Gi' \
  --requests='cpu=4,memory=4Gi' \
  -n "$NS" 2>&1 | head -5 || true
echo "    (above should show a quota/limit exceeded error)"
$OC delete pod quota-test -n "$NS" --ignore-not-found 2>/dev/null || true

echo ""
echo "==> Done. Current namespace security posture:"
echo "--- Pods ---"
$OC get pods -n "$NS" -o wide
echo "--- Quota ---"
$OC describe resourcequota dotnet-demo-quota -n "$NS" | grep -E "Resource|cpu|memory|pods"
