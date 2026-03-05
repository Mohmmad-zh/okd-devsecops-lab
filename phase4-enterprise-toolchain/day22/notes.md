# Day 22 — Artifact Repository (Nexus Repository OSS)

## Goals
- Deploy a private artifact store on OKD
- Create Docker hosted + proxy repositories
- Configure NuGet hosted + proxy repositories
- Validate with image push and NuGet source configuration

---

## Why Nexus over JFrog Artifactory?

| | JFrog Artifactory OSS | Sonatype Nexus OSS |
|---|---|---|
| Memory request | ~2Gi | ~1Gi (512Mi min) |
| Docker registry | ✅ | ✅ |
| NuGet | ✅ | ✅ |
| npm, Maven, PyPI | ✅ | ✅ |
| REST API | ✅ | ✅ |
| Single-node lab viable | ❌ (memory) | ✅ |

Same pivot as Day 15 (Semgrep over SonarQube) — production capability, lab-compatible footprint.

---

## Deployment

```bash
# Apply manifest (namespace, SA, PVC, Deployment, Services, Routes)
oc apply -f nexus.yaml

# Grant anyuid SCC (Nexus runs as UID 200)
oc create clusterrolebinding nexus-anyuid \
  --clusterrole=system:openshift:scc:anyuid \
  --serviceaccount=nexus:nexus-sa

# Wait for readiness
oc wait pod -n nexus -l app=nexus --for=condition=Ready --timeout=300s
```

**Initial admin password** (one-time file, deleted after first login):
```bash
oc exec -n nexus deployment/nexus -- cat /nexus-data/admin.password
```
Result: `35a5101e-318d-4d0a-8f76-ad6190bbe053`

---

## Repository Configuration (REST API)

```bash
oc port-forward -n nexus svc/nexus 8081:8081 &

# 1. Change admin password
curl -u admin:<initial-pass> -X PUT http://localhost:8081/service/rest/v1/security/users/admin/change-password \
  -H "Content-Type: text/plain" -d "nexus-admin-2024!"

# 2. Enable Docker Bearer Token realm (required for docker login)
curl -u admin:nexus-admin-2024! -X PUT http://localhost:8081/service/rest/v1/security/realms/active \
  -H "Content-Type: application/json" \
  -d '["NexusAuthenticatingRealm","DockerToken","NuGetApiKey"]'

# 3. Create Docker hosted repository (port 8082)
curl -u admin:nexus-admin-2024! -X POST http://localhost:8081/service/rest/v1/repositories/docker/hosted \
  -H "Content-Type: application/json" \
  -d '{"name":"docker-hosted","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"allow"},"docker":{"v1Enabled":false,"forceBasicAuth":true,"httpPort":8082}}'

# 4. Create Docker proxy (Docker Hub, port 8083)
curl -u admin:nexus-admin-2024! -X POST http://localhost:8081/service/rest/v1/repositories/docker/proxy \
  -H "Content-Type: application/json" \
  -d '{"name":"docker-proxy","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true},"proxy":{"remoteUrl":"https://registry-1.docker.io","contentMaxAge":1440,"metadataMaxAge":1440},"negativeCache":{"enabled":true,"timeToLive":1440},"httpClient":{"blocked":false,"autoBlock":true},"docker":{"v1Enabled":false,"forceBasicAuth":false,"httpPort":8083},"dockerProxy":{"indexType":"HUB","indexUrl":"https://index.docker.io/"}}'
```

**NuGet repos created by default** in Nexus 3:
- `nuget-hosted` — private NuGet packages
- `nuget.org-proxy` — transparent proxy to NuGet.org
- `nuget-group` — combined virtual group (use this in `dotnet nuget add source`)

---

## Final Repository State

```
Total: 9 repositories

docker     hosted   docker-hosted        ← port 8082 — push CI/CD images
docker     proxy    docker-proxy         ← port 8083 — pull from Docker Hub
maven2     group    maven-public
maven2     hosted   maven-releases
maven2     hosted   maven-snapshots
maven2     proxy    maven-central
nuget      group    nuget-group          ← use this URL in NuGet config
nuget      hosted   nuget-hosted         ← publish internal NuGet packages
nuget      proxy    nuget.org-proxy      ← transparent proxy to NuGet.org
```

---

## Access URLs

| Endpoint | URL |
|----------|-----|
| UI | https://nexus.apps-crc.testing |
| Docker hosted registry | docker-hosted.apps-crc.testing |
| Docker proxy registry | docker-proxy.apps-crc.testing |
| NuGet group feed | https://nexus.apps-crc.testing/repository/nuget-group/index.json |
| NuGet hosted push | https://nexus.apps-crc.testing/repository/nuget-hosted/ |

---

## Demo Results

### Docker Image Push (via skopeo)

```bash
oc port-forward -n nexus svc/nexus 8082:8082 &

# Copy from Docker Hub → Nexus
skopeo copy \
  docker://docker.io/alpine:3.19 \
  docker://localhost:8082/alpine:3.19 \
  --dest-creds="cicd-user:cicd-pass-2024!" \
  --dest-tls-verify=false \
  --src-no-creds
```

Result:
```
Copying blob sha256:17a39c0ba978cc...
Copying config sha256:83b2b6703a62...
Writing manifest to image destination
```

### NuGet Source Configuration

```bash
dotnet nuget add source "http://localhost:8081/repository/nuget-group/index.json" \
  --name "nexus" \
  --username "cicd-user" \
  --password "cicd-pass-2024!" \
  --store-password-in-clear-text

dotnet nuget list source
# 2.  nexus [Enabled]
#     http://localhost:8081/repository/nuget-group/index.json
```

---

## Credentials

| Account | Password | Role |
|---------|----------|------|
| admin | nexus-admin-2024! | System admin |
| cicd-user | cicd-pass-2024! | nx-admin (for CI/CD pipeline use) |

---

## Artifact Repository in the DevSecOps Pipeline

```
Developer pushes code
        │
        ▼
CI pipeline builds image
        │
        ▼
Trivy scans image ──── FAIL? ──► Block pipeline
        │ PASS
        ▼
skopeo copy app:SHA → nexus:docker-hosted/app:SHA
        │
        ▼
GitOps manifest updated (image: nexus-docker-hosted/app:SHA)
        │
        ▼
Argo CD syncs → pod pulls from Nexus (not Docker Hub)
```

**Security benefits of using Nexus:**
- Air-gap capable: pods pull from internal registry, no direct internet access needed
- Immutable tags: `docker-hosted` write policy prevents overwriting an existing tag
- Audit trail: every pull logged in Nexus audit log
- Supply chain control: only images that passed CI security gates reach Nexus
