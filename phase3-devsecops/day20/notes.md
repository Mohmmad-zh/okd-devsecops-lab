# Day 20 — Secure Pipeline Secrets (CI/CD + Vault)

## Goals
- Understand common pipeline secret anti-patterns
- Implement Vault AppRole auth for CI/CD systems
- Show Azure DevOps + Vault integration pattern
- Demonstrate pipeline secret rotation without pipeline changes

---

## Pipeline Secret Anti-Patterns

```yaml
# ❌ ANTI-PATTERN 1: Hardcoded in pipeline YAML
- script: |
    docker login -u myuser -p "hardcoded-password-123" registry.example.com

# ❌ ANTI-PATTERN 2: Stored as long-lived CI variable
# Azure DevOps / GitHub Secrets: static, rarely rotated, shared across pipelines

# ❌ ANTI-PATTERN 3: Committed to git
# .env files, config files with credentials
```

---

## Vault AppRole Auth for CI/CD

AppRole is designed for machine-to-machine authentication (perfect for CI/CD):

```
Pipeline → POST /v1/auth/approle/login
           with role_id + secret_id
         → Short-lived Vault token
         → Read secrets
         → Token expires after pipeline run
```

### Setup

```bash
# Enable AppRole auth
vault auth enable approle

# Create CI/CD policy (read-only, scoped to build secrets)
vault policy write cicd-policy - <<EOF
path "secret/data/cicd/*" {
  capabilities = ["read"]
}
path "secret/data/registry/credentials" {
  capabilities = ["read"]
}
EOF

# Create AppRole role (short TTL, limited uses)
vault write auth/approle/role/cicd-pipeline \
  secret_id_ttl=10m \           # secret_id expires in 10 minutes
  token_num_uses=5 \            # token can only be used 5 times
  token_ttl=20m \               # token expires in 20 minutes
  token_max_ttl=30m \
  policies=cicd-policy

# Get role_id (static, can be stored in CI)
vault read auth/approle/role/cicd-pipeline/role-id

# Get secret_id (dynamic, request fresh per pipeline run)
vault write -f auth/approle/role/cicd-pipeline/secret-id
```

---

## CI/CD Integration Architecture

```
┌──────────────────────────────────────────────────────────┐
│ CI/CD Server (Azure DevOps / GitHub Actions)              │
│                                                           │
│  Pipeline Step 1: Vault Login                             │
│  ──────────────────────────────                           │
│  ROLE_ID=${{ secrets.VAULT_ROLE_ID }}    ← static, safe  │
│  SECRET_ID=$(vault write -f .../secret-id) ← dynamic     │
│  TOKEN=$(vault login role_id secret_id)                   │
│                                                           │
│  Pipeline Step 2: Fetch secrets                           │
│  ──────────────────────────────                           │
│  REGISTRY_PASSWORD=$(vault kv get -field=password ...)    │
│  docker login -u ci -p "$REGISTRY_PASSWORD" registry/    │
│                                                           │
│  Pipeline Step 3: Build + Push                            │
│  TOKEN expires after pipeline completes                   │
└──────────────────────────────────────────────────────────┘
```

---

## Azure DevOps Pipeline (YAML)

```yaml
# azure-pipelines.yml
stages:
  - stage: Build
    jobs:
      - job: BuildAndScan
        pool:
          vmImage: ubuntu-latest
        steps:
          # Step 1: Vault login using AppRole
          - script: |
              # Install Vault CLI
              curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
              sudo apt-add-repository "deb https://apt.releases.hashicorp.com $(lsb_release -cs) main"
              sudo apt-get install vault

              # Login with AppRole (ROLE_ID stored as non-secret var, SECRET_ID as secret)
              VAULT_TOKEN=$(vault write -format=json auth/approle/login \
                role_id="$(VAULT_ROLE_ID)" \
                secret_id="$(VAULT_SECRET_ID)" | jq -r '.auth.client_token')

              echo "##vso[task.setvariable variable=VAULT_TOKEN;issecret=true]$VAULT_TOKEN"
            displayName: "Vault Login"
            env:
              VAULT_ADDR: $(VAULT_ADDR)

          # Step 2: Fetch secrets
          - script: |
              REGISTRY_PASSWORD=$(vault kv get -field=password secret/data/registry/credentials)
              ACR_USERNAME=$(vault kv get -field=username secret/data/registry/credentials)

              echo "##vso[task.setvariable variable=ACR_PASSWORD;issecret=true]$REGISTRY_PASSWORD"
              echo "##vso[task.setvariable variable=ACR_USERNAME;issecret=true]$ACR_USERNAME"
            displayName: "Fetch Registry Credentials"
            env:
              VAULT_TOKEN: $(VAULT_TOKEN)
              VAULT_ADDR: $(VAULT_ADDR)

          # Step 3: Docker login (credentials never stored in pipeline YAML)
          - script: |
              echo "$(ACR_PASSWORD)" | docker login acr.example.com -u "$(ACR_USERNAME)" --password-stdin
            displayName: "Docker Login"

          # Step 4: SAST
          - script: semgrep scan --config semgrep-rules.yaml --error src/
            displayName: "SAST Scan"

          # Step 5: Build
          - script: docker build -t acr.example.com/aspnetapp:$(Build.BuildId) .
            displayName: "Build Image"

          # Step 6: Container scan
          - script: |
              trivy image --severity CRITICAL --exit-code 1 \
                acr.example.com/aspnetapp:$(Build.BuildId)
            displayName: "Container Security Scan"

          # Step 7: Push (if all gates pass)
          - script: docker push acr.example.com/aspnetapp:$(Build.BuildId)
            displayName: "Push Image"
```

**What's stored in Azure DevOps variables:**
- `VAULT_ADDR`: `https://vault.example.com` (non-secret)
- `VAULT_ROLE_ID`: role ID for AppRole (non-secret, public)
- `VAULT_SECRET_ID`: AppRole secret ID (secret, rotate regularly)

**What's NOT stored anywhere:**
- Container registry password
- Database credentials
- API keys
- Any application secrets

---

## Secret Rotation Without Pipeline Changes

```bash
# Old credentials compromised? Just rotate in Vault:
vault kv put secret/data/registry/credentials \
  username="ci-user" \
  password="new-rotated-password-$(date +%s)"

# Next pipeline run automatically gets new credentials.
# No pipeline YAML changes. No redeployment. No secrets leak.
```

---

## Vault AppRole for This Lab

```bash
# Configure on lab Vault
oc exec -n vault deployment/vault -- sh -c "
VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200

vault auth enable approle

vault policy write cicd-policy - <<EOF
path 'secret/data/aspnetapp/*' { capabilities = ['read'] }
EOF

vault write auth/approle/role/lab-cicd \
  secret_id_ttl=10m \
  token_ttl=20m \
  policies=cicd-policy

vault read auth/approle/role/lab-cicd/role-id
"
```

---

## Pipeline Security Comparison

| Approach | Secrets in Git | Secrets in CI vars | Short-lived | Rotation |
|----------|---------------|-------------------|-------------|----------|
| Hardcoded in YAML | ✗ YES | n/a | ✗ NO | Manual |
| CI/CD secret variables | No | ✗ YES (long-lived) | ✗ NO | Manual |
| Vault AppRole | No | role_id only (not secret) | ✓ YES (20min) | Zero-touch |
| Vault K8s auth | No | No | ✓ YES (1h) | Zero-touch |

---

## Summary: The Secrets Maturity Model

```
Level 0: Hardcoded in code/config (TERRIBLE)
Level 1: CI/CD variables (common, but long-lived)
Level 2: External secrets (AWS SM, Azure KV, Vault) — pulled at build time
Level 3: Dynamic secrets with short TTL — Vault AppRole/K8s auth
Level 4: Zero-trust dynamic secrets — no static credentials anywhere
```

This lab demonstrated Levels 3-4 using Vault Kubernetes auth and AppRole.
