# Zitadel TUI

A beautiful, interactive terminal user interface for managing Zitadel identity
provider configuration.

## Features

- **OIDC Application Management**
  - List all applications
  - Create new applications (with predefined templates or custom)
  - Regenerate client secrets
  - Delete applications
  - Quick setup for common apps (Grafana, Paperless, MinIO, Mealie)
  - 1Password integration for credential storage

- **User Management**
  - List all users
  - Create new users
  - Create admin users with password authentication
  - Grant IAM_OWNER role
  - Quick setup for predefined family users

- **Identity Provider Configuration**
  - List configured IDPs
  - Configure Google OAuth IDP
  - Fetch credentials from Kubernetes secrets

## Requirements

- Ruby >= 3.1
- kubectl configured with cluster access
- 1Password CLI (optional, for credential storage)

## Installation

```bash
cd scripts/zitadel-tui
bundle install
```

## Usage

```bash
# Run the TUI
./bin/zitadel-tui

# Or with bundle
bundle exec ./bin/zitadel-tui
```

## Docker

```bash
# Build the image
docker build -t zitadel-tui .

# Run with kubectl access
docker run -it --rm \
  -v ~/.kube:/root/.kube:ro \
  zitadel-tui
```

## Configuration

The TUI stores configuration in `~/.zitadel-tui.yml`:

```yaml
zitadel_url: https://zitadel.damacus.io
project_id: "355223427969320100"
onepassword_vault: home-ops
```

## Authentication

The TUI supports two authentication methods:

1. **Service Account (JWT)** - Uses a service account key from Kubernetes
   secret `zitadel-admin-sa` in namespace `authentication`

2. **Personal Access Token (PAT)** - Uses a PAT from Kubernetes secret
   `zitadel-admin-sa-pat` in namespace `authentication`

## Predefined Applications

The quick setup feature includes templates for:

| Application | Type         | Redirect URIs               |
|-------------|--------------|-----------------------------|
| Grafana     | Confidential | OAuth callback URLs         |
| Paperless   | Confidential | OAuth callback URLs         |
| MinIO       | Confidential | OAuth callback URL          |
| Mealie      | Public       | Login and API callback URLs |

## Development

```bash
# Run RuboCop
bundle exec rubocop

# Run tests
bundle exec rspec
```

## License

MIT
