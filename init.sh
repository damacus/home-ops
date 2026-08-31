#!/usr/bin/env bash

# Home-Ops Development Environment Initialization Script

set -euo pipefail

echo "🚀 Initializing home-ops development environment..."

# Check for required tools
command -v mise >/dev/null 2>&1 || { echo >&2 "❌ mise is required but not installed. Aborting."; exit 1; }

mise install

# Install pre-commit hooks if applicable
if [ -d .git ]; then
    echo "📦 Setting up git hooks..."
    # Placeholder for git hook setup
fi

# Run initial configuration
echo "⚙️ Running initial configuration..."
mise run configure

echo "✅ Environment initialized successfully!"
echo "📖 Refer to AGENTS.md for project specification and .tasks/ for current objectives."
