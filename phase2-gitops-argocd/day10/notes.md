# Day 10 — Auto Sync + Self-Healing (Drift Correction)

## Goals
- Understand Argo CD's auto-sync and self-heal mechanisms
- Demonstrate drift correction in action
- Understand what counts as "drift" in Argo CD's model

---

## Auto-Sync vs Self-Heal

| Feature | Auto-Sync | Self-Heal |
|---|---|---|
| **Trigger** | New git commit | Live resource differs from desired |
| **What it does** | Applies new desired state | Reverts unauthorized changes |
| **Flag** | `--sync-policy automated` | `--self-heal` |
| **Checks** | On git poll (default 3 min) or webhook | Continuous watch on cluster events |

Both are enabled on `aspnetapp-dev`:
```bash
argocd app create aspnetapp-dev \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

---

## Experiment 1: Scale Drift

Manual change → immediate self-heal (replicas restored):
```bash
# Current: 1 replica (from git)
oc scale deployment aspnetapp -n aspnetapp-dev --replicas=3
# Argo CD restores to 1 within seconds
oc get deployment aspnetapp -n aspnetapp-dev -o jsonpath='{.spec.replicas}'
# Output: 1
```

**Result:** Reverted in < 5 seconds.

---

## Experiment 2: Deleted Resource

Deleting a managed resource triggers immediate recreation:
```bash
oc delete service aspnetapp -n aspnetapp-dev
# Argo CD recreates it within seconds
oc get service aspnetapp -n aspnetapp-dev
# Output: NAME      TYPE      CLUSTER-IP      PORT(S)    AGE
#         aspnetapp ClusterIP 10.217.5.225   8080/TCP   40s
```

**Result:** Service recreated in < 5 seconds. This is the most important self-heal behavior — prevents accidental or malicious deletion of cluster resources.

---

## Experiment 3: Env Var Drift (Strategic Merge Patch Behavior)

```bash
oc set env deployment/aspnetapp -n aspnetapp-dev DEBUG=true
argocd app diff aspnetapp-dev  # No diff output!
```

**Why no drift detected?** Argo CD uses **3-way strategic merge patch** for comparison:
- Desired state (from git): env vars `ASPNETCORE_ENVIRONMENT`, `ASPNETCORE_URLS`
- Live state: those two env vars + `DEBUG=true`
- Argo CD only manages what's in the desired state; extra fields aren't "drift"

This is correct behavior for strategic merge. If you need to detect and remove extra env vars, use `replace: true` in the patch strategy, or use server-side apply.

---

## How Argo CD Detects Drift

Argo CD polls git every 3 minutes by default, and watches cluster resources continuously.

**Drift detected when:**
- A managed resource is deleted
- A field managed by Argo CD is changed (using 3-way merge comparison)
- A new resource from git doesn't exist in cluster

**Drift NOT detected (by default) when:**
- Extra fields are added to live resources that aren't in git (strategic merge behavior)

---

## Checking Sync Status

```bash
# Show current sync status
argocd app get aspnetapp-dev --grpc-web

# Show diff between desired (git) and live (cluster)
argocd app diff aspnetapp-dev --grpc-web

# Force immediate sync check
argocd app refresh aspnetapp-dev --grpc-web

# Show sync history
argocd app history aspnetapp-dev --grpc-web
```

---

## Production Implications

- **dev**: Auto-sync + self-heal = rapid feedback, zero-touch operations
- **test/prod**: Manual sync = human approval required before any change applies
- Self-heal protects against: accidental `kubectl` changes, malicious access, operator errors
- Every reconciliation is logged in Argo CD (audit trail without Kubernetes audit log)
