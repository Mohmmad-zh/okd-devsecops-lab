# Day 8 — Install Argo CD + Gitea, First Application Sync

## Goals
- Deploy Gitea (self-hosted Git) on OKD
- Install Argo CD v2.13.0
- Push Kustomize manifests to Gitea
- Create first Argo CD Application syncing from Git

---

## 1. Gitea Deployment

Deployed Gitea 1.22 into the `gitea` namespace.

**Key lessons:**
- Gitea's Docker image uses s6-overlay init: starts as root, drops to `git` user (UID 1000). Must grant `anyuid` SCC.
- Configuration via `GITEA__section__key` env vars (not app.ini ConfigMap mount — Gitea reads from `/data/gitea/conf/app.ini`, not `/etc/gitea/`).
- Admin user creation: `oc exec ... -- su git -s /bin/sh -c "gitea admin user create ..."`
- Flag `--must-change-password=false` required to avoid API lockout.

**Credentials:**
- URL: `https://gitea-gitea.apps-crc.testing`
- Admin: `gitops / gitops123!`
- Repo: `https://gitea-gitea.apps-crc.testing/gitops/aspnetapp.git`

**OKD SCC workaround** (OKD 4.20 removed `-z` shorthand from `oc adm policy`):
```yaml
# ClusterRoleBinding to grant anyuid SCC
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: gitea-anyuid-scc
subjects:
  - kind: ServiceAccount
    name: gitea
    namespace: gitea
roleRef:
  kind: ClusterRole
  apiGroup: rbac.authorization.k8s.io
  name: system:openshift:scc:anyuid
```

---

## 2. Argo CD Installation

Installed from upstream `install.yaml` (v2.13.0), then patched for OKD:

**Issues resolved:**
1. `argocd-redis` UID 999 rejected by `restricted-v2` → granted `nonroot-v2` SCC
2. Old-style seccomp annotations (`seccomp.security.alpha.kubernetes.io`) rejected → removed from pod template
3. Redis `runAsUser: 999` rejected → removed from securityContext
4. Argo CD Route needed `--insecure` flag on `argocd-server` (Route terminates TLS, not the app)

**Admin credentials:**
- URL: `https://argocd-server-argocd.apps-crc.testing`
- Password: `ALjUhNzZ9NDCLVt7` (from `argocd-initial-admin-secret`)

**CLI install:**
```bash
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/download/v2.13.0/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
argocd login argocd-server-argocd.apps-crc.testing \
  --username admin --password <password> --insecure
```

---

## 3. Repository Registration

Gitea uses a self-signed cert. Argo CD repo-server cannot verify it:
```
fatal: server certificate verification failed. CAfile: none
```

**Fix:** Use `--insecure-skip-server-verification` with a Gitea API token (not password — must-change-password lockout prevented password auth via API).

```bash
# Create API token in Gitea
TOKEN=$(curl -sk -X POST https://gitea-gitea.apps-crc.testing/api/v1/users/gitops/tokens \
  -u gitops:gitops123! \
  -d '{"name":"argocd-token","scopes":["read:repository"]}' | jq -r .sha1)

# Register repo
argocd repo add https://gitea-gitea.apps-crc.testing/gitops/aspnetapp.git \
  --username gitops --password "$TOKEN" \
  --insecure-skip-server-verification --grpc-web
```

---

## 4. First Application — Dev

```bash
argocd app create aspnetapp-dev \
  --repo https://gitea-gitea.apps-crc.testing/gitops/aspnetapp.git \
  --path overlays/dev \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace aspnetapp-dev \
  --sync-policy automated --auto-prune --self-heal \
  --grpc-web
```

**Result:** `Synced + Healthy` — pod Running in `aspnetapp-dev` namespace.

---

## What GitOps Means in Practice

| Traditional | GitOps |
|---|---|
| `kubectl apply` manually | Git commit triggers sync |
| Drift possible | Self-heal reverts manual changes |
| No audit trail | Every change is a git commit |
| Rollback = re-apply old manifest | Rollback = `git revert` |

---

## Key Commands

```bash
# Check app status
argocd app list --grpc-web
argocd app get aspnetapp-dev --grpc-web

# Manual sync
argocd app sync aspnetapp-test --grpc-web

# Watch sync
argocd app wait aspnetapp-dev --health --grpc-web
```
