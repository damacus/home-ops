#!/usr/bin/env bash

# Home-Ops Development Environment Initialization Script

set -e

echo "🚀 Initializing home-ops development environment..."

# Check for required tools
command -v task >/dev/null 2>&1 || { echo >&2 "❌ task (go-task) is required but not installed. Aborting."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo >&2 "❌ kubectl is required but not installed. Aborting."; exit 1; }
command -v flux >/dev/null 2>&1 || { echo >&2 "❌ flux is required but not installed. Aborting."; exit 1; }

# Install pre-commit hooks if applicable
if [ -d .git ]; then
    echo "📦 Setting up git hooks..."
    # Placeholder for git hook setup
fi

# Run initial configuration task
echo "⚙️ Running initial configuration..."
task configure --optional

echo "✅ Environment initialized successfully!"
echo "📖 Refer to AGENTS.md for project specification and .tasks/ for current objectives."
