# Day 4 — RBAC & Service Accounts (Least-Privilege)

## What We Did

Replaced the `default` ServiceAccount on the aspnetapp pod with a dedicated
least-privilege `aspnetapp-sa`, bound to a custom `Role` that grants only the
minimum permissions the app needs.

## Files

| File | Purpose |
|------|---------|
| `serviceaccount.yaml` | `aspnetapp-sa` — dedicated SA with token automount disabled |
| `role.yaml` | `aspnetapp-role` — get/list/watch configmaps, get secrets, get pods |
| `rolebinding.yaml` | Binds `aspnetapp-sa` → `aspnetapp-role` in `dotnet-demo` |
| `../day02/deployment.yaml` | Updated: `serviceAccountName: aspnetapp-sa`, `automountServiceAccountToken: false` |

---

## ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aspnetapp-sa
  namespace: dotnet-demo
automountServiceAccountToken: false
```

- **Dedicated SA** — not the `default` SA (which every pod in the namespace would share)
- **`automountServiceAccountToken: false`** — the K8s API token is NOT mounted into
  the pod filesystem. A compromised container can't call the API at all.
- The Deployment also sets `automountServiceAccountToken: false` for defence in depth.

---

## Role (namespace-scoped)

```yaml
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]   # read app configuration
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]                    # read credentials
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get"]                    # health/metrics sidecars may need this
```

**Role vs ClusterRole:**
- `Role` is namespace-scoped — permissions apply only within `dotnet-demo`
- A `ClusterRole` would grant cluster-wide access — not appropriate here

---

## RBAC Verification (oc auth can-i)

```
ALLOWED                                    DENIED
─────────────────────────────────────────  ─────────────────────────────────────────────
get configmaps -n dotnet-demo    → yes     create pods        -n dotnet-demo    → no
list configmaps -n dotnet-demo   → yes     delete pods        -n dotnet-demo    → no
get secrets -n dotnet-demo       → yes     create secrets     -n dotnet-demo    → no
get pods -n dotnet-demo          → yes     delete secrets     -n dotnet-demo    → no
                                           get deployments    -n dotnet-demo    → no
                                           list nodes         (cluster-wide)    → no
                                           get configmaps -n  default           → no
                                           get configmaps -n  openshift-monitoring → no
```

Cross-namespace access is denied — Role is strictly scoped to `dotnet-demo`.

---

## Pod Verification

```
Pod: aspnetapp-6c959d7cf8-4bbtk
SA:  aspnetapp-sa
Token automounted: false
```

No SA token mounted in the container — even if an attacker gets a shell, they
cannot use `kubectl`/`oc` to interact with the cluster API.

---

## Security Layers — Full Picture (Days 2–4)

| Layer | Control | Enforced by |
|-------|---------|-------------|
| Pod | Non-root, drop ALL caps, no priv-esc, seccomp | SCC restricted-v2 |
| Pod | Liveness + readiness probes | kubelet |
| Pod | Resource requests + limits | Scheduler / cgroups |
| Pod | Dedicated SA, no token mount | RBAC |
| Namespace | default-deny NetworkPolicy | OVN-Kubernetes |
| Namespace | Allow only router ingress + DNS egress | NetworkPolicy |
| Namespace | ResourceQuota (compute + object counts) | Admission |
| Namespace | LimitRange (container min/max + defaults) | Admission |
| RBAC | Least-privilege Role (3 resources, read-only) | API server |
| RBAC | No cross-namespace access | Role (not ClusterRole) |
| RBAC | No cluster-level access | Role (not ClusterRole) |

---

## Key Concepts

- **ServiceAccount** — identity a pod uses to authenticate to the Kubernetes API
- **Role** — namespaced set of permission rules (resource + verbs)
- **ClusterRole** — same but cluster-wide; use only when cross-namespace access is needed
- **RoleBinding** — attaches a Role/ClusterRole to a subject (SA, User, Group) within a namespace
- **`automountServiceAccountToken: false`** — prevents the SA JWT from being mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`; best practice for apps that don't call the API
- **`oc auth can-i`** — essential tool for auditing RBAC: `oc auth can-i <verb> <resource> --as=<subject>`

## Commands

```bash
# Check what a SA can do
oc auth can-i get pods -n dotnet-demo \
  --as=system:serviceaccount:dotnet-demo:aspnetapp-sa

# List all roles in namespace
oc get role -n dotnet-demo

# List all rolebindings
oc get rolebinding -n dotnet-demo

# Full audit of what an SA can do
oc auth can-i --list \
  --as=system:serviceaccount:dotnet-demo:aspnetapp-sa \
  -n dotnet-demo
```
