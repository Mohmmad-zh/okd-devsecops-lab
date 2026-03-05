# Day 12 — Rollback Simulation (git revert)

## Goals
- Demonstrate GitOps rollback via `git revert`
- Show Argo CD-native rollback via history
- Understand rollback audit trail

---

## Scenario

The probe change from Day 11 caused issues: `readinessProbe.initialDelaySeconds=5s` was too short for prod, causing pods to receive traffic before they were ready. Decision: roll back.

---

## Method 1: Git Revert (Recommended)

```bash
# 1. Find the commit to revert
git log --oneline
# ae407ba fix: tune health check probes for faster startup detection
# cbe1405 perf: tune dev resource requests for better bin-packing
# 583d9fa Initial GitOps manifests

# 2. Create a revert commit (preserves history)
git revert ae407ba --no-edit
# [main b2757e8] Revert "fix: tune health check probes for faster startup detection"

# 3. Push to git — Argo CD picks it up
git push origin main

# 4. Auto-syncs to dev immediately
# 5. Manually promote revert to test and prod
argocd app sync aspnetapp-test --grpc-web
argocd app sync aspnetapp-prod --grpc-web
```

**Result:** All environments reverted in < 30 seconds.

```
aspnetapp-dev: liveness=15s ✓ (reverted from 20s)
aspnetapp-test: liveness=15s ✓ (reverted from 20s)
aspnetapp-prod: liveness=15s ✓ (reverted from 20s)
```

---

## Method 2: Argo CD Native Rollback

Argo CD stores deployment history (configurable, default 10 entries):

```bash
# View history
argocd app history aspnetapp-dev --grpc-web
# ID  DATE                      REVISION
# 0   2026-03-03 15:53:48 +03   (583d9fa) - initial
# 1   2026-03-03 16:21:04 +03   (cbe1405) - resource tune
# 2   2026-03-03 16:23:05 +03   (ae407ba) - probe change
# 3   2026-03-03 16:27:26 +03   (b2757e8) - revert

# Roll back to a specific history ID
argocd app rollback aspnetapp-prod 1 --grpc-web
```

**Limitation:** Argo CD rollback pins to a historical revision and **disables auto-sync**. You must re-enable it after the emergency is resolved. Git revert is generally preferred because:
- Creates an audit trail in git
- Keeps auto-sync enabled
- No special Argo CD state to clean up

---

## Rollback Decision Tree

```
Was the bad commit merged to main?
├── YES → git revert (creates new commit, preserves history)
└── NO  → git reset + force push (only if you own the branch)
         └── WARNING: never force push to main in a team!

Is it an emergency (prod is down)?
├── YES → argocd app rollback <app> <history-id>  (fastest)
└── NO  → git revert + promote through dev/test first
```

---

## What Gets Rolled Back

A git revert reverts **the manifest spec**, which means:
- ✅ Deployment config (replicas, probes, resources, env vars)
- ✅ Service config (ports, selector)
- ✅ All other Kubernetes manifests
- ❌ Not the running container's data/state
- ❌ Not database schemas or migrations (handle separately)

---

## Audit Trail

Every rollback creates a traceable record:

```
git log --oneline
b2757e8 Revert "fix: tune health check probes..."   ← rollback
ae407ba fix: tune health check probes...             ← bad change
cbe1405 perf: tune dev resource requests...
583d9fa Initial GitOps manifests
```

```bash
argocd app history aspnetapp-prod
# Shows every deployment with timestamp and git revision
```

Combined with OpenShift audit logs, you have a complete picture of who changed what and when — without needing additional tooling.
