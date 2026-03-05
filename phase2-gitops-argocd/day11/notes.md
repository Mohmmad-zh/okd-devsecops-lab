# Day 11 — Promotion Strategy: Dev → Test → Prod

## Goals
- Demonstrate a real change flowing through environments
- Show manual approval gates for test and prod
- Understand the GitOps promotion model

---

## Promotion Model

```
Developer commits → Gitea main branch
                          │
                    ┌─────▼──────┐
                    │    dev     │  Auto-sync (immediate)
                    │ aspnetapp  │
                    └─────┬──────┘
                          │ Validated ✓
                    ┌─────▼──────┐
                    │    test    │  Manual sync (QA gate)
                    │ aspnetapp  │
                    └─────┬──────┘
                          │ Approved ✓
                    ┌─────▼──────┐
                    │    prod    │  Manual sync (human approval)
                    │ aspnetapp  │
                    └────────────┘
```

**Key principle:** All environments use the same git commit (same `main` branch). Promotion = syncing the next environment to that commit. There's no "copy" of manifests — they're all in Git, differentiated by overlays.

---

## Change 1: Dev-Only Resource Tuning

```bash
# Committed: overlays/dev/deployment-patch.yaml resource adjustment
git commit -m "perf: tune dev resource requests for better bin-packing"
git push origin main
```

- **Dev**: Auto-synced immediately (cpu request: 50m → 75m)
- **Test**: No change (test overlay has its own resource values)
- **Prod**: No change (prod overlay has its own resource values)

---

## Change 2: Base Probe Tuning (All Environments)

```bash
# Committed: base/deployment.yaml probe delay change
git commit -m "fix: tune health check probes for faster startup detection

Increase liveness initial delay: 15s → 20s
Decrease readiness initial delay: 10s → 5s"
git push origin main
```

### Step 1: Check diff before promoting
```bash
argocd app diff aspnetapp-test --grpc-web
# Shows: initialDelaySeconds 15 → 20, 10 → 5
```

### Step 2: Promote to test
```bash
argocd app sync aspnetapp-test --grpc-web
# Result: Phase: Succeeded, Duration: 2s
```

### Step 3: Verify test
```bash
oc get deployment aspnetapp -n aspnetapp-test \
  -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds}'
# Output: 20
```

### Step 4: Promote to prod (final gate)
```bash
argocd app sync aspnetapp-prod --grpc-web
# Prod now has 2 replicas + updated probes
```

---

## Final State After Promotion

| Environment | Replicas | Liveness Delay | Readiness Delay | CPU Request |
|---|---|---|---|---|
| dev | 1 | 20s | 5s | 75m |
| test | 1 | 20s | 5s | 100m |
| prod | 2 | 20s | 5s | 100m |

---

## Why This Is Better Than Scripts

| Old way (scripts) | GitOps |
|---|---|
| `./deploy.sh prod` | `argocd app sync aspnetapp-prod` |
| No record of who ran it | Audit trail in Argo CD + git log |
| "What version is prod on?" | `argocd app get aspnetapp-prod` |
| Rollback: re-run old script | `git revert <hash>; git push` |
| Drift: "someone changed it manually" | Argo CD alerts + self-heal |

---

## Argo CD Application Status After Promotion

```
NAME             SYNC STATUS  HEALTH   REVISION
aspnetapp-dev    Synced       Healthy  ae407ba (latest)
aspnetapp-test   Synced       Healthy  ae407ba (promoted)
aspnetapp-prod   Synced       Healthy  ae407ba (promoted)
```

---

## Production-Grade Promotion Patterns

In production, teams use:
1. **Branch-per-environment** — `main` → dev, `release` → test/prod (promotes via PR)
2. **Image tag pinning** — base uses `image: app:SHA256` that gets bumped per env
3. **Argo CD AppProject + sync windows** — restrict prod syncs to business hours
4. **Argo CD notifications** — Slack alert before/after each promotion
5. **`argocd app wait`** — block CI pipeline until health check passes
