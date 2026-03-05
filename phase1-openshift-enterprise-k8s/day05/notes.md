# Day 5 — Operators & ImageStreams

## What We Did

1. Installed **cert-manager** from OperatorHub via OLM (Operator Lifecycle Manager)
2. Created a **ClusterIssuer** to prove the operator's CRDs are live
3. Created an **ImageStream** tracking the aspnetapp image from MCR
4. Demonstrated ImageStream tagging (`:latest` → `:v1`) and scheduled re-import

---

## Files

| File | Purpose |
|------|---------|
| `cert-manager-namespace.yaml` | `cert-manager` namespace |
| `cert-manager-operatorgroup.yaml` | OperatorGroup (AllNamespaces mode) |
| `cert-manager-subscription.yaml` | OLM Subscription — channel `stable`, CSV `v1.16.5` |
| `imagestream.yaml` | ImageStream tracking `mcr.microsoft.com/dotnet/samples:aspnetapp` |

---

## Part 1 — Operators & OLM

### How OLM installs an Operator

```
Subscription  →  InstallPlan  →  CSV  →  Operator Pods  →  CRDs
```

1. **Subscription** — declares which operator you want and from which catalog
2. **InstallPlan** — OLM creates this automatically; lists all resources to install
3. **CSV (ClusterServiceVersion)** — the operator's manifest: what it deploys, what CRDs it registers
4. **Operator Pods** — the actual controllers running in the namespace
5. **CRDs** — new resource types the operator introduces

### Key gotcha: OperatorGroup install modes

cert-manager only supports `AllNamespaces` install mode.
Setting `targetNamespaces` in the OperatorGroup causes the CSV to fail immediately:

```
OwnNamespace InstallModeType not supported
```

**Fix:** Use `spec: {}` (empty spec) in the OperatorGroup — this means AllNamespaces.

```yaml
# Wrong — causes CSV failure for cert-manager
spec:
  targetNamespaces: [cert-manager]

# Correct — AllNamespaces mode
spec: {}
```

### cert-manager installed resources

```
PODS (3):
  cert-manager              ← main controller (issues/renews certs)
  cert-manager-cainjector   ← injects CA bundles into webhooks
  cert-manager-webhook      ← validates cert-manager CRDs at admission

CRDs (6):
  certificates.cert-manager.io
  certificaterequests.cert-manager.io
  clusterissuers.cert-manager.io
  issuers.cert-manager.io
  challenges.acme.cert-manager.io
  orders.acme.cert-manager.io
```

### ClusterIssuer — proving the operator works

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
```

```
ClusterIssuer: selfsigned-issuer  Ready: True
```

This CRD didn't exist before the operator was installed. Creating it and getting
`Ready: True` proves the operator's webhook and controller are fully functional.

---

## Part 2 — ImageStreams

### What an ImageStream does

An ImageStream is an OpenShift abstraction over a container image reference.
Instead of deployments pointing directly at `mcr.microsoft.com/dotnet/samples:aspnetapp`,
they can point at the ImageStream tag, which OpenShift resolves and tracks.

Benefits:
- **Digest pinning** — the IS records the exact `sha256` digest at import time
- **Scheduled polling** — `scheduled: true` re-imports every 15 minutes; if the upstream digest changes, the IS tag updates
- **Trigger-based rollouts** — a Deployment can be configured to auto-rollout when the IS tag digest changes
- **Immutable release tags** — tag `:latest` to `:v1` at release time to pin that digest forever

### ImageStream created

```
NAME        REPOSITORY                                                         TAGS     UPDATED
aspnetapp   .../dotnet-demo/aspnetapp                                          latest   ✅
```

### Digest captured

```
Tag:     aspnetapp:latest
Digest:  sha256:c0bb56e8730a16518af90b359363166978db5279ff0560445432da6ff2a2d81f
```

### Tagging a release (`:latest` → `:v1`)

```bash
oc tag dotnet-demo/aspnetapp:latest dotnet-demo/aspnetapp:v1
```

```
aspnetapp:latest   sha256:c0bb56e8...   9 min ago
aspnetapp:v1       sha256:c0bb56e8...   just now    ← pinned to same digest
```

`:v1` is now an immutable reference — even if `:latest` updates tomorrow, `:v1` stays pinned.

### Scheduled re-import (simulated)

```bash
oc import-image aspnetapp:latest -n dotnet-demo \
  --from=mcr.microsoft.com/dotnet/samples:aspnetapp --confirm
```

In production with `scheduled: true` in the ImageStream spec, OLM does this
automatically every ~15 minutes. When the upstream image updates, the IS tag's
digest changes — and if the Deployment has an image change trigger, it rolls out
the new version automatically.

---

## Troubleshooting Encountered

| Error | Cause | Fix |
|-------|-------|-----|
| `OwnNamespace InstallModeType not supported` | cert-manager requires AllNamespaces mode | Changed OperatorGroup `spec` to `{}` (empty) |
| Old InstallPlan left CSV in broken state | Deleting CSV without reconciling subscription | Deleted Subscription + InstallPlans, recreated Subscription |

---

## Key Concepts

- **OLM (Operator Lifecycle Manager)** — the system that manages operator installation, updates, and dependencies in OpenShift
- **CSV (ClusterServiceVersion)** — the operator's "package manifest"; describes its pods, CRDs, permissions, and upgrade path
- **OperatorGroup** — controls which namespaces an operator watches (`OwnNamespace`, `SingleNamespace`, `AllNamespaces`)
- **Subscription** — your "subscribe me to this operator" declaration; OLM handles installs and upgrades
- **ImageStream** — OpenShift's image tracking abstraction; decouples deployments from registry URLs and enables digest-based rollouts
- **Image trigger** — DeploymentConfig feature (or annotation on Deployment) that auto-rolls out when an IS tag digest changes

## Commands

```bash
# List available operators
oc get packagemanifests -n openshift-marketplace

# Check operator install status
oc get csv -n cert-manager
oc get subscription -n cert-manager

# Check installplan
oc get installplan -n cert-manager

# ImageStream operations
oc get imagestream -n dotnet-demo
oc get istag -n dotnet-demo
oc import-image aspnetapp:latest -n dotnet-demo --confirm
oc tag dotnet-demo/aspnetapp:latest dotnet-demo/aspnetapp:v1

# cert-manager resources
oc get clusterissuer
oc get certificate -A
```
