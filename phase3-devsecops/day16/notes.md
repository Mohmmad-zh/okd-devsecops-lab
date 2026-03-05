# Day 16 — Container Scanning with Trivy (Block on HIGH/CRITICAL)

## Goals
- Scan container images for OS and language CVEs
- Scan Kubernetes manifests for security misconfigurations
- Quality gate: block on CRITICAL findings
- Fix a real misconfiguration found in the GitOps manifests

---

## Tool: Trivy

Trivy is an all-in-one security scanner covering:
- **Container images** — OS packages (Alpine, Debian, Ubuntu) + language deps (.NET, npm, pip)
- **Filesystems** — local directories, Kubernetes manifests
- **Git repos** — scan source + dependencies
- **Kubernetes clusters** — live cluster audit

```bash
# Install
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
  | sudo sh -s -- -b /usr/local/bin

# Scan image
trivy image <image>:<tag>

# Scan manifests
trivy fs --scanners misconfig /path/to/manifests/
```

---

## Image Scanning Results

### python:3.8 (End-of-Life, Debian 12.7)

```bash
trivy image --severity HIGH,CRITICAL python:3.8
```

| Severity | Count |
|----------|-------|
| CRITICAL | 181   |
| HIGH     | 1288  |
| **Total**| **1469** |

Selected CRITICAL findings:
- `CVE-2025-53014` — ImageMagick: Heap Buffer Overflow (CVSS 9.8)
- `CVE-2026-23876` — ImageMagick: Arbitrary code execution (CVSS 9.8)

**Quality Gate: FAILED** — 181 CRITICAL CVEs block the pipeline.

### mcr.microsoft.com/dotnet/samples:aspnetapp (.NET 10, Alpine 3.23.3)

```bash
trivy image --severity HIGH,CRITICAL mcr.microsoft.com/dotnet/samples:aspnetapp
```

| Severity | Count |
|----------|-------|
| CRITICAL | 0     |
| HIGH     | 0     |

**Quality Gate: PASSED** — clean current base image.

---

## Manifest Misconfiguration Scan

```bash
trivy fs --scanners misconfig --severity HIGH,CRITICAL gitops-repo/
```

**Finding (KSV-0014 — HIGH):**
```
Container 'aspnetapp' should set 'securityContext.readOnlyRootFilesystem' to true
An immutable root file system prevents applications from writing to their local disk.
This can limit intrusions, as attackers cannot tamper with the filesystem.
```

**Fix applied** to `base/deployment.yaml`:
```yaml
# Before
securityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  capabilities:
    drop: [ALL]

# After
securityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  readOnlyRootFilesystem: true   # ← added
  capabilities:
    drop: [ALL]
```

Committed to Gitea → Argo CD auto-synced to dev → pod verified `1/1 Running`.

---

## Quality Gate Pipeline Integration

```bash
#!/bin/bash
IMAGE="$1"    # e.g. registry.example.com/myapp:1.2.3

# Fail on any CRITICAL CVE in the image
trivy image \
  --severity CRITICAL \
  --exit-code 1 \
  --scanners vuln \
  "$IMAGE"

if [ $? -ne 0 ]; then
  echo "BLOCKED: CRITICAL CVEs found in $IMAGE"
  echo "Update the base image to a patched version before deploying."
  exit 1
fi

# Fail on HIGH+ Kubernetes misconfigurations
trivy fs \
  --scanners misconfig \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  manifests/

echo "PASSED: image and manifests are clean"
```

---

## Trivy Scan Modes

| Mode | Command | What it scans |
|------|---------|---------------|
| Image | `trivy image nginx:1.25` | OS packages + language deps in image |
| Filesystem | `trivy fs .` | Files, manifests, source code |
| Repo | `trivy repo https://github.com/...` | Remote git repo |
| Kubernetes | `trivy k8s cluster` | Live cluster resources |
| Config | `trivy config .` | IaC files (Terraform, Helm, K8s) |
| SBOM | `trivy sbom image.spdx.json` | Software Bill of Materials |

---

## Choosing What to Block

| Severity | Recommended Action |
|----------|-------------------|
| CRITICAL | Block always — no exceptions in pipeline |
| HIGH | Block by default; allow documented exceptions |
| MEDIUM | Report but don't block (fix in next sprint) |
| LOW | Report only; fix during planned maintenance |

In practice, `--severity CRITICAL --exit-code 1` in CI provides a strong security gate without the noise of blocking on MEDIUM/LOW.

---

## Key Lesson: Image Freshness vs Vulnerability Count

The aspnetapp image uses:
- **Alpine 3.23.3** (current LTS) — minimal attack surface
- **.NET 10.0** (current) — receives active security patches
- **Multi-stage build** — only runtime layer in final image

This is why it has 0 CVEs while `python:3.8` (Debian-based, EOL Python) has 1469. **Using minimal, current base images is the single highest-impact container security practice.**
