# Day 15 — SAST with Semgrep (Fail on Critical Findings)

## Goals
- Static Application Security Testing (SAST) on C# source code
- Custom rules targeting OWASP Top 10 vulnerabilities
- Quality gate: block pipeline on security findings

---

## Tool Choice: Semgrep vs SonarQube

SonarQube Community Edition requires ~2GB RAM (for embedded Elasticsearch), which exceeds available capacity on a single-node CRC lab cluster. **Semgrep** was used instead — it's a modern, widely-adopted SAST tool:

| | Semgrep | SonarQube CE |
|---|---|---|
| Deployment | CLI only (no server) | Requires server + DB |
| Languages | 30+ (C#, Python, Go, JS...) | 27 |
| Custom rules | YAML-based, easy to write | XML + plugin SDK |
| CI integration | Exit code based | Quality Gates API |
| License | OSS (LGPL) | LGPL (Community) |

---

## Sample Vulnerable Application

Created `VulnerableApp` — a .NET 8 minimal API with intentional security issues:

| Vulnerability | CWE | Severity |
|---|---|---|
| Hardcoded credentials (`DbPassword`, `AdminApiKey`) | CWE-798 | ERROR |
| SQL Injection (string interpolation into query) | CWE-89 | ERROR |
| Command Injection (`Process.Start` with user input) | CWE-78 | ERROR |
| Insecure Random (`new Random()` for tokens) | CWE-338 | WARNING |
| Exposed exception stack trace to client | CWE-209 | WARNING |

---

## Custom Semgrep Rules

Rules defined in `semgrep-rules.yaml`, using Semgrep's pattern language:

```yaml
rules:
  - id: csharp-insecure-random
    pattern: new Random()
    message: "Use RandomNumberGenerator instead of System.Random"
    languages: [csharp]
    severity: WARNING

  - id: csharp-hardcoded-secret-const
    patterns:
      - pattern: const string $NAME = "$VALUE";
      - metavariable-regex:
          metavariable: $NAME
          regex: (?i)(password|secret|key|token|apikey)
    message: "Hardcoded credential detected"
    languages: [csharp]
    severity: ERROR
```

---

## Scan Results: Before Fix

```
2 Code Findings
  Program.cs
  ❯❱ csharp-insecure-random     [BLOCKING] line 40
  ❯❱ csharp-exposed-exception   [BLOCKING] line 56

Quality Gate: FAILED (exit code 1)
```

---

## Fixes Applied

| Issue | Before | After |
|---|---|---|
| Hardcoded secrets | `const string DbPassword = "admin123!"` | `Environment.GetEnvironmentVariable("DB_PASSWORD")` |
| SQL injection | `$"SELECT ... '{username}'"` | Parameterized: `cmd.Parameters.AddWithValue("@username", value)` |
| Command injection | `Process.Start("bash", $"-c 'ping {host}'")` | Allowlist validation (no shell execution) |
| Insecure random | `new Random()` | `RandomNumberGenerator.Fill(bytes)` |
| Exposed exception | `Results.Problem(ex.ToString())` | `logger.LogError(ex, ...); Results.Problem("generic")` |

---

## Scan Results: After Fix

```
0 findings
Quality Gate: PASSED (exit code 0)
```

---

## CI Pipeline Integration

```bash
#!/bin/bash
# In your CI/CD pipeline (Azure DevOps, GitHub Actions, etc.)

# Step 1: Run SAST
semgrep scan \
  --config semgrep-rules.yaml \
  --config "p/owasp-top-ten" \
  --config "p/secrets" \
  --json --output semgrep-results.json \
  src/

# Step 2: Quality gate
FINDINGS=$(python3 -c "import json; d=json.load(open('semgrep-results.json')); print(len(d['results']))")
if [ "$FINDINGS" -gt 0 ]; then
  echo "SAST FAILED: $FINDINGS security findings"
  exit 1
fi
echo "SAST PASSED: pipeline continues"
```

---

## Install

```bash
# Install Semgrep
pip3 install semgrep

# Run against a project
semgrep scan --config "p/csharp" --config "p/secrets" src/

# With custom rules
semgrep scan --config my-rules.yaml src/

# JSON output for pipeline integration
semgrep scan --config my-rules.yaml --json --output results.json src/
```

---

## What SAST Catches (vs Does Not Catch)

**SAST finds:**
- Injection vulnerabilities in source code (SQL, command, LDAP)
- Hardcoded secrets in source
- Insecure cryptographic usage
- Common API misuse patterns

**SAST does NOT catch:**
- Runtime misconfigurations (requires DAST)
- Vulnerable dependencies (requires SCA)
- Container image CVEs (requires image scanning)
- Logic bugs (requires code review + testing)

**Rule:** SAST → SCA → Container scan → DAST: each layer covers different attack surfaces.
