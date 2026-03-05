# Day 23 — Pipeline Integration with Nexus Artifact Registry

## Goals
- Simulate end-to-end CI/CD pipeline: scan → tag → push → promote
- Integrate Nexus as the artifact store in the GitOps workflow
- Demonstrate SHA-tagged immutable image promotion
- Document the TLS registry challenge and solution

---

## Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                       CI/CD Pipeline                                │
│                                                                     │
│  1. Source code committed to Git                                    │
│         │                                                           │
│         ▼                                                           │
│  2. SAST scan (Semgrep) ─────── FAIL → Block pipeline             │
│         │ PASS                                                       │
│         ▼                                                           │
│  3. Build image (tagged with GIT_SHA)                              │
│         │                                                           │
│         ▼                                                           │
│  4. Trivy image scan ────────── FAIL → Block pipeline             │
│         │ PASS (0 CRITICAL)                                        │
│         ▼                                                           │
│  5. skopeo copy → Nexus docker-hosted/app:$GIT_SHA               │
│       or → OpenShift internal registry (when TLS not configured)   │
│         │                                                           │
│  6. Nexus also proxies NuGet.org for dependency resolution         │
│         │                                                           │
│         ▼                                                           │
│  7. Update GitOps manifest: image: registry/app:$GIT_SHA          │
│         │                                                           │
│         ▼                                                           │
│  8. git commit + push → Gitea                                      │
│         │                                                           │
│         ▼                                                           │
│  9. Argo CD auto-sync → deploys new image to dev                  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Demo Results

### Step 1: Trivy Quality Gate

```bash
GIT_SHA="a3f8b2c"
APP_IMAGE="mcr.microsoft.com/dotnet/samples:aspnetapp"

trivy image --severity CRITICAL --exit-code 1 --quiet $APP_IMAGE
```

Result:
```
alpine 3.23.3:  0 CVEs
dotnet-core:    0 CVEs
Security gate PASSED: 0 CRITICAL CVEs
```

### Step 2: Push to Nexus docker-hosted

```bash
oc port-forward -n nexus svc/nexus 8082:8082 &

skopeo copy \
  docker://mcr.microsoft.com/dotnet/samples:aspnetapp \
  docker://localhost:8082/aspnetapp:a3f8b2c \
  --dest-creds="cicd-user:cicd-pass-2024!" \
  --dest-tls-verify=false \
  --src-no-creds
```

Result:
```
Copying blob sha256:7f91c1abd0be4b30205d13084d8f3c713b3197420e066e41fe6c06ba0406500f
Copying blob sha256:158e462dd18ca9d3c5d1cbac7c6e0caf0e64a885c5fdf24d937b7e4c8a137a9c
...
Writing manifest to image destination
```

Image `aspnetapp:a3f8b2c` now in Nexus docker-hosted. Stored with:
- `Digest: sha256:c0bb56e8730a...` (immutable)
- Layers: 8
- Architecture: amd64/linux

### Step 3: Update GitOps Manifest (Nexus → internal registry)

```bash
# Initial attempt: docker-hosted.apps-crc.testing/aspnetapp:a3f8b2c
# FAILED: x509: certificate signed by unknown authority
# CRI-O doesn't trust the OKD wildcard self-signed cert

# Fix: Push to OpenShift internal registry (already trusted by cluster)
skopeo copy \
  docker://mcr.microsoft.com/dotnet/samples:aspnetapp \
  docker://localhost:5000/aspnetapp-dev/aspnetapp:a3f8b2c \
  --dest-creds="$(oc whoami):$(oc whoami -t)" \
  --dest-tls-verify=false \
  --src-no-creds
```

```bash
# Update deployment.yaml
sed -i 's|image: mcr.microsoft.com/dotnet/samples:aspnetapp|image: image-registry.openshift-image-registry.svc:5000/aspnetapp-dev/aspnetapp:a3f8b2c|g' base/deployment.yaml

git add base/deployment.yaml
git commit -m "ci: promote aspnetapp:a3f8b2c from internal registry to dev"
git push origin main
```

### Step 4: Argo CD Auto-sync

```
Sync Revision: 556ca50
Phase:         Succeeded
Status:        Synced to (556ca50)
Health:        Healthy

Image: image-registry.openshift-image-registry.svc:5000/aspnetapp-dev/aspnetapp:a3f8b2c
```

---

## Lab Challenge: TLS Certificate for Nexus Route

In the lab, CRI-O couldn't pull from `docker-hosted.apps-crc.testing` because the OKD wildcard cert is self-signed.

**Error:**
```
Failed to pull image: x509: certificate signed by unknown authority
```

**Production fix options:**

| Option | Command | Impact |
|--------|---------|--------|
| Add OKD CA to cluster trust | `oc edit proxy/cluster` + `additionalTrustBundle` | MachineConfig rollout (node restart) |
| Configure as insecure registry | `oc edit image.config.openshift.io/cluster` | MachineConfig rollout (node restart) |
| cert-manager TLS cert for Route | Issue Let's Encrypt cert for Nexus Route | No node restart, recommended |
| Use internal registry | Push to `image-registry.openshift-image-registry.svc:5000` | No node restart, works in lab |

**For lab:** Used the OpenShift internal registry (already trusted, no cert issues).

---

## Immutable Image Tag Policy

The key principle demonstrated: **SHA-based immutable tags, not mutable tags like `latest`**.

| Tag strategy | `latest` | `v1.0` | `a3f8b2c` (SHA) |
|---|---|---|---|
| Reproducible | ❌ Changes over time | ❌ Can be overwritten | ✅ Immutable |
| Audit trail | ❌ | ❌ | ✅ Links to git commit |
| Rollback | ❌ Can't reproduce | ❌ | ✅ Previous SHA still exists |
| Nexus enforcement | N/A | N/A | `writePolicy: allow_once` in prod |

**Production Nexus config for immutable tags:**
```json
"storage": {
  "writePolicy": "allow_once"   // Prevents overwriting existing tags
}
```

---

## NuGet Integration (Day 22 foundation)

Nexus `nuget-group` URL used in the pipeline:

```bash
# Add Nexus as NuGet source (proxies NuGet.org)
dotnet nuget add source "https://nexus.apps-crc.testing/repository/nuget-group/index.json" \
  --name "nexus" \
  --username "cicd-user" \
  --password "cicd-pass-2024!" \
  --store-password-in-clear-text

# Restore packages through Nexus (proxied from NuGet.org)
dotnet restore --source nexus
```

**Benefit:** All NuGet packages routed through Nexus:
- Cached locally (faster builds)
- Audit log of which packages were used
- Can block specific package versions

---

## Git Commits Created

```
git log --oneline
556ca50 ci: use OpenShift internal registry for aspnetapp:a3f8b2c
6d38a57 ci: promote aspnetapp:a3f8b2c from Nexus to dev
3e461c1 security: add readOnlyRootFilesystem to container securityContext
b2757e8 Revert "fix: tune health check probes..."
```

Each CI promotion is a traceable git commit — full audit trail from code commit to production image.
