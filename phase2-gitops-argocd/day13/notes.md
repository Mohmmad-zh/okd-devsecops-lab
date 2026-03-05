# Day 13 — Argo CD Security: RBAC, AppProject, Sync Windows

## Goals
- Restrict what each project can deploy and where
- Control who can sync prod vs dev/test
- Limit prod syncs to business hours only

---

## Security Layers in Argo CD

```
Argo CD Security
├── AppProject        — limits repos, destinations, resource types
├── RBAC (argocd-rbac-cm) — who can do what (sync, delete, get)
└── Sync Windows      — when syncs are allowed (time-based gates)
```

---

## 1. AppProject

AppProjects restrict what an Application is allowed to do. This prevents an app from being redirected to deploy to the wrong cluster/namespace.

### Prod Project

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: aspnetapp-prod
  namespace: argocd
spec:
  description: "Production environment - restricted sync access"

  # Only allow manifests from this specific repo
  sourceRepos:
    - "https://gitea-gitea.apps-crc.testing/gitops/aspnetapp.git"

  # Only deploy to prod namespace on this cluster
  destinations:
    - namespace: aspnetapp-prod
      server: https://kubernetes.default.svc

  # Cluster-scoped resources allowed
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace   # Must be explicit; Namespace is cluster-scoped

  # Namespace-scoped resources allowed (strict allowlist)
  namespaceResourceWhitelist:
    - group: "apps"
      kind: Deployment
    - group: ""
      kind: Service
    - group: ""
      kind: ServiceAccount
    - group: "route.openshift.io"
      kind: Route

  # Sync window: Mon-Fri 09:00-17:00 only
  syncWindows:
    - kind: allow
      schedule: "0 9 * * 1-5"
      duration: 8h
      applications: ["*"]
      manualSync: true

  # Project-level roles
  roles:
    - name: prod-deployer
      policies:
        - "p, proj:aspnetapp-prod:prod-deployer, applications, sync, aspnetapp-prod/*, allow"
        - "p, proj:aspnetapp-prod:prod-deployer, applications, get, aspnetapp-prod/*, allow"
      groups:
        - ops-team
```

**What the AppProject prevents:**
- ❌ Deploying to any other namespace (e.g., `kube-system`)
- ❌ Creating `ClusterRole`, `ClusterRoleBinding`, `PersistentVolume` etc.
- ❌ Pulling from any other Git repo (prevents supply chain attack)
- ❌ Deploying to any other cluster
- ✅ Only `Deployment`, `Service`, `ServiceAccount`, `Route`, `Namespace` in `aspnetapp-prod`

### Security Incident: Namespace Blocked

When `clusterResourceWhitelist: []` (empty), Argo CD blocked the sync:
```
resource :Namespace is not permitted in project aspnetapp-prod
```
This is correct security behavior — the platform team controls namespace lifecycle. In production, pre-create namespaces outside the AppProject and remove `namespace.yaml` from overlays.

---

## 2. Argo CD RBAC

Configured in `argocd-rbac-cm` ConfigMap:

```yaml
data:
  policy.default: role:readonly   # All users default to read-only
  policy.csv: |
    # Admin
    p, role:admin, *, *, */*, allow

    # Ops team: can sync prod, read all
    p, role:ops, applications, sync, aspnetapp-prod/*, allow
    p, role:ops, applications, get, */*, allow

    # Dev team: full control over nonprod, read-only on prod
    p, role:developer, applications, *, aspnetapp-nonprod/*, allow
    p, role:developer, applications, get, aspnetapp-prod/*, allow

    # Group bindings
    g, admin, role:admin
```

**Policy syntax:** `p, <subject>, <resource>, <action>, <appproject>/<app>, <effect>`

| Subject | Can sync prod | Can sync dev/test | Can delete apps |
|---|---|---|---|
| admin | ✅ | ✅ | ✅ |
| ops-team | ✅ | read only | ❌ |
| dev-team | ❌ | ✅ | nonprod only |
| (default) | read only | read only | ❌ |

---

## 3. Sync Windows

Sync windows are cron-based time gates on the AppProject:

```yaml
syncWindows:
  - kind: allow           # "allow" or "deny"
    schedule: "0 9 * * 1-5"  # Mon-Fri 9:00 AM
    duration: 8h           # Window duration
    applications: ["*"]   # Applies to all apps in project
    manualSync: true       # Manual sync also blocked outside window
```

**Outside the window:**
```
SyncWindow: Sync Blocked
```

**Using a deny window instead** (inverse approach):
```yaml
  - kind: deny
    schedule: "0 0 * * *"   # Every midnight
    duration: 2h             # Block 00:00-02:00 for maintenance
```

**Verify window status:**
```bash
argocd app get aspnetapp-prod --grpc-web | grep SyncWindow
# SyncWindow: Sync Allowed   (during business hours)
# SyncWindow: Sync Blocked   (outside business hours)
```

---

## Application-to-Project Assignment

```bash
# Assign prod app to restricted prod project
argocd app set aspnetapp-prod --project aspnetapp-prod --grpc-web

# Assign dev/test to nonprod project
argocd app set aspnetapp-dev  --project aspnetapp-nonprod --grpc-web
argocd app set aspnetapp-test --project aspnetapp-nonprod --grpc-web
```

**Final state:**
```
NAME             PROJECT            SYNC    HEALTH
aspnetapp-dev    aspnetapp-nonprod  Synced  Healthy
aspnetapp-test   aspnetapp-nonprod  Synced  Healthy
aspnetapp-prod   aspnetapp-prod     Synced  Healthy
```

---

## Defense-in-Depth Model

```
Git repo (Gitea) — who can push to main?
    │
    ▼
Argo CD AppProject — what can be deployed where?
    │
    ▼
Argo CD RBAC — who can trigger syncs?
    │
    ▼
Sync Windows — when can prod be touched?
    │
    ▼
OpenShift SCC — what can containers do at runtime?
    │
    ▼
NetworkPolicy — what traffic is allowed between pods?
```

Each layer provides independent defense. A compromised developer account cannot sync prod (RBAC). A compromised ops account cannot deploy to `kube-system` (AppProject). An automated sync cannot run at midnight (sync window).
