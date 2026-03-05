# Day 17 — Dependency Scanning (SCA)

## Goals
- Software Composition Analysis (SCA) for NuGet packages
- Identify vulnerable third-party dependencies
- Generate SBOM (Software Bill of Materials) for supply chain visibility
- Quality gate: block on HIGH/CRITICAL dependency vulnerabilities

---

## Tools Used

| Tool | Purpose |
|------|---------|
| `dotnet list package --vulnerable` | Built-in .NET SDK: queries NuGet advisory database |
| `trivy fs --scanners vuln` | SCA for lock files / project assets |
| `trivy image --format cyclonedx` | SBOM generation from container image |

---

## SCA with dotnet CLI

The .NET SDK has built-in vulnerability checking via the NuGet audit database:

```bash
# After dotnet restore
dotnet list package --vulnerable

# Output (vulnerable):
# Project `VulnerableApp` has the following vulnerable packages
#    [net8.0]:
#    Top-level Package  Requested  Resolved  Severity  Advisory URL
#    > Newtonsoft.Json  9.0.1      9.0.1     High      https://github.com/advisories/GHSA-5crp-9r3c-p9vr
```

---

## Demo: Dependency Vulnerability Lifecycle

### Step 1: Introduce vulnerable dependency

```xml
<!-- VulnerableApp.csproj -->
<PackageReference Include="Newtonsoft.Json" Version="9.0.1" />
```

**Vulnerability:** Newtonsoft.Json < 13.0.1 — Improper Handling of Exceptional Conditions
**CVE:** GHSA-5crp-9r3c-p9vr | Severity: HIGH

### Step 2: SCA Quality Gate — FAILED

```bash
VULN_COUNT=$(dotnet list package --vulnerable | grep -c "High\|Critical")
# VULN_COUNT=1 → exit 1 → pipeline blocked
```

### Step 3: Fix — upgrade to safe version

```bash
dotnet add package Newtonsoft.Json --version 13.0.3
```

### Step 4: SCA Quality Gate — PASSED

```bash
dotnet list package --vulnerable
# "The given project has no vulnerable packages given the current sources."
```

---

## SBOM Generation

A Software Bill of Materials lists every component in your software — like an ingredient list.

```bash
# Generate SBOM from container image
trivy image \
  --format cyclonedx \
  --output aspnetapp-sbom.json \
  mcr.microsoft.com/dotnet/samples:aspnetapp
```

**Result for aspnetapp:**
```
Format: CycloneDX 1.6
Subject: mcr.microsoft.com/dotnet/samples:aspnetapp
Components: 25 (OS packages + .NET runtime assemblies)
```

**SBOM use cases:**
- **Compliance**: SOC 2, FedRAMP, EU Cyber Resilience Act require SBOM
- **Incident response**: When Log4Shell dropped, teams with SBOMs identified affected apps in hours (not weeks)
- **License compliance**: Track GPL/LGPL dependencies that have copyleft implications
- **Vendor transparency**: Share SBOM with customers so they know what's in your product

---

## Trivy SCA for lock files

Trivy can scan language lock files directly (no Docker required):

```bash
# .NET (requires project.assets.json or packages.lock.json)
trivy fs --scanners vuln --severity HIGH,CRITICAL /path/to/project/

# npm
trivy fs --scanners vuln package-lock.json

# Python
trivy fs --scanners vuln requirements.txt
```

For .NET, generate the lock file first:
```bash
dotnet restore --use-lock-file
trivy fs --scanners vuln .
```

---

## CI Pipeline Integration

```bash
#!/bin/bash
# SCA stage in pipeline

# Step 1: Restore
dotnet restore

# Step 2: Vulnerability check
dotnet list package --vulnerable 2>&1 > sca-report.txt
VULN_HIGH=$(grep -c "High" sca-report.txt)
VULN_CRITICAL=$(grep -c "Critical" sca-report.txt)

if [ "$VULN_CRITICAL" -gt 0 ] || [ "$VULN_HIGH" -gt 0 ]; then
  echo "SCA FAILED: $VULN_CRITICAL Critical, $VULN_HIGH High findings"
  cat sca-report.txt
  exit 1
fi

# Step 3: Generate SBOM for audit trail
trivy image --format cyclonedx --output sbom.json "$IMAGE_TAG"
# Archive sbom.json as a build artifact

echo "SCA PASSED: no vulnerable dependencies"
```

---

## SCA vs SAST vs Container Scanning

| | SAST | SCA | Container Scanning |
|---|---|---|---|
| **What** | Your source code bugs | Third-party lib CVEs | OS + app CVEs in image layers |
| **When** | On commit (pre-build) | On restore/build | On image push |
| **Finds** | Injection, crypto misuse | Log4Shell, Heartbleed-type | Unpatched OS CVEs |
| **Tool** | Semgrep | `dotnet list package`, Trivy | Trivy, Grype |
| **Day** | Day 15 | Day 17 (this) | Day 16 |

All three layers together form a comprehensive DevSecOps security scanning pipeline.
