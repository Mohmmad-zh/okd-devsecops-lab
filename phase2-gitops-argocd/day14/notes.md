# Day 14 — GitOps Documentation and Phase 2 Summary

## Phase 2 Complete: GitOps with Argo CD

Days 8-14 covered the full GitOps lifecycle on OpenShift (OKD 4.20.0) using Argo CD v2.13.0 and Gitea 1.22.

---

## Architecture Deployed

```
┌─────────────────────────────────────────────────────────┐
│                  OpenShift (OKD 4.20.0)                  │
│                                                           │
│  ┌──────────────┐    ┌──────────────────────────────┐   │
│  │ gitea ns     │    │ argocd ns                    │   │
│  │ ──────────── │    │ ──────────────────────────── │   │
│  │ Gitea 1.22   │◄───│ argocd-server                │   │
│  │ (Git server) │    │ argocd-repo-server           │   │
│  │ Port 3000    │    │ argocd-application-controller│   │
│  └──────────────┘    │ argocd-redis                 │   │
│         │            │ argocd-dex-server             │   │
│         │ watches    │ argocd-applicationset         │   │
│         │            └──────────────┬───────────────┘   │
│         │                           │ syncs              │
│         │            ┌──────────────▼───────────────┐   │
│         │            │ Apps (3 environments)         │   │
│         │            │ aspnetapp-dev   (replicas: 1) │   │
│         │            │ aspnetapp-test  (replicas: 1) │   │
│         │            │ aspnetapp-prod  (replicas: 2) │   │
│         └────────────┘                               │   │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

---

## GitOps Repo Structure

```
gitops-repo/
├── base/                      # Shared config (Production defaults)
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── route.yaml
│   └── serviceaccount.yaml
└── overlays/
    ├── dev/    (replicas=1, env=Development, low resources)
    ├── test/   (replicas=1, env=Staging, mid resources)
    └── prod/   (replicas=2, env=Production, full resources)
```

---

## Day-by-Day Summary

| Day | Topic | Key Outcome |
|-----|-------|-------------|
| 8 | Install Argo CD + Gitea | Cluster GitOps infrastructure running |
| 9 | Kustomize base + overlays | 3-env repo structure, dev auto-synced |
| 10 | Auto-sync + self-healing | Self-heal demo: deleted service restored in < 5s |
| 11 | Promotion strategy | Change flowed dev → test → prod via git |
| 12 | Rollback | `git revert` rolled all envs back in < 30s |
| 13 | Security | AppProject + RBAC + sync windows |
| 14 | Documentation | This document |

---

## Key Credentials (Lab Only)

| Service | URL | Credentials |
|---------|-----|-------------|
| Argo CD | `https://argocd-server-argocd.apps-crc.testing` | admin / ALjUhNzZ9NDCLVt7 |
| Gitea | `https://gitea-gitea.apps-crc.testing` | gitops / gitops123! |
| Gitea API token | — | 7709e7fe2133803c781dfdc7d817586c49720409 |

---

## OpenShift-Specific Lessons

### SCC (SecurityContextConstraints) Issues

1. **Gitea** (s6-overlay init, runs as root then drops to git UID 1000):
   - Required `anyuid` SCC
   - Fix: ClusterRoleBinding to `system:openshift:scc:anyuid`
   - Cannot use `runAsUser: 1000` in pod spec (breaks s6-overlay)

2. **Argo CD Redis** (UID 999):
   - Required `nonroot-v2` SCC
   - Old-style seccomp annotations rejected — must remove from pod template
   - Remove `runAsUser: 999` from securityContext

3. **OKD 4.20 change**: `oc adm policy add-scc-to-serviceaccount -z` flag removed
   - Fix: Create `ClusterRoleBinding` to `system:openshift:scc:<scc-name>` directly

### Gitea Configuration
- Use `GITEA__section__key` env vars, not ConfigMap-mounted `app.ini`
- Admin user creation: `exec -- su git -s /bin/sh -c "gitea admin user create ..."`
- Use `--must-change-password=false` to avoid API lockout on new users

### Argo CD Repo Registration
- Self-signed certs require `--insecure-skip-server-verification`
- Use API token (not password) to avoid must-change-password lockout
- `--grpc-web` flag needed when Argo CD server is behind a Route/proxy

---

## GitOps Patterns Demonstrated

### 1. Single-Branch Multi-Env (This Lab)
```
main → overlays/dev (auto-sync)
     → overlays/test (manual sync)
     → overlays/prod (manual sync + sync window)
```
Simple, good for small teams. All envs always on same commit.

### 2. Branch-per-Environment (Production Pattern)
```
feature/xyz → develop (CI runs tests)
develop → staging (auto)
staging → main (PR + human approval → prod sync)
```

### 3. Image Tag Promotion (Immutable Builds)
```
# Only change: image tag in overlay
spec:
  template:
    spec:
      containers:
        - name: aspnetapp
          image: registry/aspnetapp:sha256-abc123  # CI bumps this
```

---

## Commands Reference

```bash
# Login
argocd login argocd-server-argocd.apps-crc.testing \
  --username admin --password <pass> --insecure

# List apps
argocd app list --grpc-web

# Sync an app
argocd app sync aspnetapp-prod --grpc-web

# Check diff before syncing
argocd app diff aspnetapp-prod --grpc-web

# Show deployment history
argocd app history aspnetapp-dev --grpc-web

# Rollback to specific history ID
argocd app rollback aspnetapp-prod 2 --grpc-web

# Watch sync until healthy
argocd app wait aspnetapp-prod --health --grpc-web

# Add git repo
argocd repo add <url> --username <user> --password <token> \
  --insecure-skip-server-verification --grpc-web
```

---

## Phase 2 Outcomes

By the end of Phase 2, the lab environment demonstrates:
- ✅ Full GitOps pipeline: git push → Argo CD → cluster
- ✅ Multi-environment promotion with manual gates
- ✅ Self-healing (drift correction in < 5 seconds)
- ✅ Rollback via `git revert` in < 30 seconds
- ✅ Security: AppProject, RBAC, sync windows
- ✅ OpenShift-specific SCC workarounds documented
