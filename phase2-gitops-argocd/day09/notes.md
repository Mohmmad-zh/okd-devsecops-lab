# Day 9 — GitOps Repo Structure: Base + Overlays with Kustomize

## Goals
- Demonstrate Kustomize base + overlays pattern
- Show environment-specific config (dev/test/prod)
- Sync test environment manually
- Verify config differences between environments

---

## Repo Structure

```
gitops-repo/
├── base/
│   ├── kustomization.yaml    # Common resources (no namespace)
│   ├── deployment.yaml       # Base deployment (Production defaults)
│   ├── service.yaml
│   ├── route.yaml
│   └── serviceaccount.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml    # namespace: aspnetapp-dev
    │   ├── namespace.yaml        # Creates the namespace
    │   └── deployment-patch.yaml # Overrides: replicas=1, env=Development
    ├── test/
    │   ├── kustomization.yaml    # namespace: aspnetapp-test
    │   ├── namespace.yaml
    │   └── deployment-patch.yaml # Overrides: replicas=1, env=Staging
    └── prod/
        ├── kustomization.yaml    # namespace: aspnetapp-prod
        ├── namespace.yaml
        └── deployment-patch.yaml # Overrides: replicas=2, env=Production
```

---

## How Kustomize Overlays Work

Each overlay `kustomization.yaml` references `../../base` as a resource and adds a strategic merge patch:

```yaml
# overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: aspnetapp-dev
resources:
  - ../../base
  - namespace.yaml
patches:
  - path: deployment-patch.yaml
    target:
      kind: Deployment
      name: aspnetapp
```

The patch file uses **strategic merge patch** — only specified fields are overridden:

```yaml
# overlays/dev/deployment-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aspnetapp
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: aspnetapp
          env:
            - name: ASPNETCORE_ENVIRONMENT
              value: "Development"
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "200m", memory: "128Mi" }
```

---

## Environment Comparison

| Setting | dev | test | prod |
|---|---|---|---|
| Replicas | 1 | 1 | 2 |
| ASPNETCORE_ENVIRONMENT | Development | Staging | Production |
| CPU request | 50m | 75m | 100m |
| CPU limit | 200m | 300m | 500m |
| Memory request | 64Mi | 96Mi | 128Mi |
| Memory limit | 128Mi | 192Mi | 256Mi |
| Sync policy | Automated | Manual | Manual |

---

## Argo CD Applications

```
NAME             SYNC STATUS  HEALTH   SYNC POLICY
aspnetapp-dev    Synced       Healthy  Auto-Prune (automated)
aspnetapp-test   Synced       Healthy  Manual
aspnetapp-prod   OutOfSync    Missing  Manual
```

- **dev**: Auto-syncs on every git push (rapid iteration)
- **test**: Manual sync (requires deliberate promotion)
- **prod**: Manual sync (human approval gate)

---

## Verifying Environment Config

```bash
# Check env vars in running pod
oc get deployment aspnetapp -n aspnetapp-test \
  -o jsonpath='{.spec.template.spec.containers[0].env}'

# Output: [{"name":"ASPNETCORE_ENVIRONMENT","value":"Staging"},...]

# Compare replicas
oc get deployment aspnetapp -n aspnetapp-dev  -o jsonpath='{.spec.replicas}'  # 1
oc get deployment aspnetapp -n aspnetapp-prod -o jsonpath='{.spec.replicas}'  # 2 (after sync)
```

---

## Key Kustomize Commands

```bash
# Preview what would be applied (run locally with kustomize)
kustomize build overlays/dev
kustomize build overlays/prod

# Or via kubectl
kubectl kustomize overlays/dev
```

---

## What Day 9 Proves

Kustomize base + overlays is the standard GitOps pattern for multi-environment deployments:
- **DRY**: Common config in base, only differences in overlays
- **Auditable**: Every environment config lives in Git
- **Safe**: Prod changes require a deliberate git commit + manual sync
- **Consistent**: All environments share the same base image and security context
