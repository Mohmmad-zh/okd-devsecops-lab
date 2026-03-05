# Day 1 — OKD / OpenShift Local (CRC)

## Cluster Info
- **Distribution**: OKD 4.20.0-okd-scos.11 (Community OpenShift)
- **Node**: `crc` — single node, roles: control-plane + master + worker
- **Kubernetes version**: v1.33.5
- **Operators running**: 24 (all Available, none Degraded)
- **Projects**: 65 (system + user)

---

## How OpenShift Differs from Vanilla Kubernetes

### 1. Projects vs Namespaces
- In vanilla K8s, a `Namespace` is a raw isolation boundary with no extra metadata.
- In OpenShift, a `Project` wraps a Namespace and adds:
  - Display name and description
  - Automatic RBAC defaults (deployer, builder service accounts)
  - Resource quota hooks
- Command: `oc new-project` vs `kubectl create namespace`

### 2. Routes vs Ingress
- Vanilla K8s uses `Ingress` objects + an Ingress Controller (nginx, traefik, etc.) installed separately.
- OpenShift has `Routes` built-in via the HAProxy-based Router Operator.
- Routes support TLS termination types out of the box:
  - `edge` — TLS terminates at the router
  - `passthrough` — TLS goes all the way to the pod
  - `reencrypt` — TLS terminates at router, re-encrypted to pod
- Observed in cluster:
  ```
  oauth-openshift.apps-crc.testing        passthrough
  console-openshift-console.apps-crc.testing   reencrypt
  downloads-openshift-console.apps-crc.testing edge
  ```

### 3. ImageStreams (No vanilla K8s equivalent)
- OpenShift tracks container images via `ImageStream` objects.
- Instead of hardcoding `image: nginx:1.25`, you reference an ImageStream tag.
- When the tag updates, OpenShift can **automatically trigger a new deployment** — zero pipeline change needed.
- Pre-built ImageStreams available in `openshift` namespace include:
  - `dotnet` — tags: 6.0, 8.0, 9.0 (relevant for Day 2!)
  - `java`, `golang`, `httpd`, `jenkins`, `mariadb`, `nodejs`

### 4. Security Context Constraints (SCC) — OpenShift's Security Model
- Vanilla K8s has `PodSecurityAdmission` (PSA) with three levels: privileged, baseline, restricted.
- OpenShift has `SCC` — more granular and predated PSA.
- SCCs control: whether a pod can run as root, which capabilities it can have, SELinux context, volume types.
- SCCs observed in cluster:

| SCC | Privileged | RunAsUser | Use Case |
|-----|-----------|-----------|----------|
| `restricted-v2` | No | MustRunAsRange | Default for all user workloads |
| `nonroot-v2` | No | MustRunAsNonRoot | Apps that set their own UID |
| `anyuid` | No | RunAsAny | Apps that need to run as root (avoid!) |
| `privileged` | Yes | RunAsAny | System components only |

- By default all user pods get `restricted-v2` — they **cannot run as root**.
- This is why containerizing .NET apps requires a non-root user (Day 2).

### 5. RBAC Differences
- OpenShift adds `ClusterRole` + `Role` on top of K8s RBAC, same as vanilla.
- Key addition: **`oc policy who-can`** — lets you audit who has a specific permission.
- OpenShift also has `cluster-admin`, `admin`, `edit`, `view` roles pre-configured per project.
- Service accounts auto-created per project: `default`, `deployer`, `builder`.

### 6. Built-in CI/CD Primitives
- OpenShift includes `BuildConfig` and `DeploymentConfig` (legacy but still present).
- `BuildConfig` can trigger S2I (Source-to-Image) builds directly from Git.
- Vanilla K8s has none of this — you need external CI (Jenkins, GitHub Actions, etc.).

### 7. Operator Lifecycle Manager (OLM)
- Both OpenShift and vanilla K8s support Operators (CRD + Controller loop).
- OpenShift ships with OLM pre-installed, providing:
  - OperatorHub (marketplace for operators)
  - Automatic upgrade paths for operators
- Vanilla K8s requires manual OLM installation.

---

## Commands Reference

```bash
# Set up oc CLI
sudo ln -sf ~/.crc/cache/crc_okd_libvirt_4.20.0-okd-scos.11_amd64/oc /usr/local/bin/oc

# Login
oc login -u kubeadmin -p <password> https://api.crc.testing:6443 --insecure-skip-tls-verify
oc login -u developer -p developer https://api.crc.testing:6443 --insecure-skip-tls-verify

# Projects
oc new-project <name>
oc projects
oc project <name>   # switch project

# Routes
oc get routes -A
oc expose svc/<service-name>  # creates a Route

# ImageStreams
oc get is -n openshift
oc describe is dotnet -n openshift

# SCCs
oc get scc
oc describe scc restricted-v2
oc adm policy add-scc-to-serviceaccount nonroot-v2 -z default -n <project>

# RBAC
oc policy who-can <verb> <resource> -n <namespace>
oc adm policy add-role-to-user admin <user> -n <project>
```

---

## Credentials
- **kubeadmin**: `WD2J7-fZZr9-XFXIn-qxDvg`
- **developer**: `developer`
- **Console**: https://console-openshift-console.apps-crc.testing
- **API**: https://api.crc.testing:6443
