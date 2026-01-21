# Zitadel InSpec Tests

This directory contains InSpec tests to validate the Zitadel identity provider is running correctly.

## Running Tests

### Prerequisites

- InSpec installed (`brew install inspec` or `gem install inspec`)
- Network access to `zitadel.damacus.io`

### Run All Tests

```bash
inspec exec kubernetes/apps/authentication/zitadel/tests
```

### Run with Custom URL

```bash
inspec exec kubernetes/apps/authentication/zitadel/tests \
  --input zitadel_url=https://zitadel.example.com
```

### Run Specific Controls

```bash
# Only OIDC tests
inspec exec kubernetes/apps/authentication/zitadel/tests \
  --controls ZITADEL-OIDC-001 ZITADEL-OIDC-002 ZITADEL-OIDC-003

# Only health checks
inspec exec kubernetes/apps/authentication/zitadel/tests \
  --controls '/ZITADEL-HEALTH-.*/'
```

## Test Categories

| Control ID         | Category     | Description                                   |
|--------------------|--------------|-----------------------------------------------|
| `ZITADEL-HTTPS-*`  | Connectivity | HTTPS endpoint and TLS certificate validation |
| `ZITADEL-HEALTH-*` | Health       | Health and readiness endpoints                |
| `ZITADEL-UI-*`     | UI           | Login and console UI accessibility            |
| `ZITADEL-OIDC-*`   | OIDC         | OpenID Connect discovery and JWKS             |
| `ZITADEL-API-*`    | API          | gRPC and Management API endpoints             |
| `ZITADEL-SEC-*`    | Security     | Security headers validation                   |

## Impact Levels

- **1.0 (Critical)**: Core functionality that must work
- **0.7 (High)**: Important but not blocking
- **0.5 (Medium)**: Nice to have, security hardening

## Integration with CI/CD

These tests can be run as part of a deployment pipeline to validate the application after deployment:

```yaml
# Example GitHub Actions step
- name: Validate Zitadel
  run: |
    inspec exec kubernetes/apps/authentication/zitadel/tests \
      --reporter cli json:results.json
```
