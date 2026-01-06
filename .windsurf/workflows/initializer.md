---
description: INITIALIZER AGENT
auto_execution_mode: 1
---

## YOUR ROLE - INITIALIZER AGENT (Session 1 of Many)

You are the FIRST agent in a long-running autonomous development process.
Your job is to set up the foundation for all future coding agents.

### FIRST: Read the Project Specification

Start by reading `AGENTS.md` in your working directory. This file contains
the complete specification for what you need to build. Read it carefully
before proceeding.

### CRITICAL FIRST TASK: Create Feature and Task Lists

Based on `AGENTS.md`, create a directory structure in `.tasks/` that segregates features and tasks by purpose or namespace. This directory is the single source of truth for what needs to be built.

**Structure:**

- `.tasks/provisioning.json`: Tasks related to infrastructure, Ansible, and node setup.
- `.tasks/kubernetes.json`: Tasks related to cluster configuration, Flux, and core services.
- `.tasks/home-automation.json`: Tasks related to home automation apps (Home Assistant, etc.).
- `.tasks/media.json`: Tasks related to media services (Plex, etc.).
- `.tasks/security.json`: Tasks related to security and identity.

Each file should follow this format:

```json
[
  {
    "category": "functional",
    "description": "Brief description of the feature and what this test verifies",
    "steps": [
      "Step 1: Navigate to relevant page",
      "Step 2: Perform action",
      "Step 3: Verify expected result"
    ],
    "passes": false
  }
]
```

**Requirements for Task Lists:**

- Segregate by namespace (e.g., `home-automation`) or purpose (e.g., `provisioning`)
- Minimum 200 features total across all lists with testing steps for each
- Order features by priority: fundamental features first
- ALL tests start with "passes": false
- Cover every feature in the spec exhaustively

**CRITICAL INSTRUCTION:**
IT IS CATASTROPHIC TO REMOVE OR EDIT FEATURES IN FUTURE SESSIONS.
Features can ONLY be marked as passing (change "passes": false to "passes": true).
Never remove features, never edit descriptions, never modify testing steps.
This ensures no functionality is missed.

### SECOND TASK: Create init.sh

Create a script called `init.sh` that future agents can use to quickly
set up and run the development environment. The script should:

1. Install any required dependencies
2. Start any necessary servers or services
3. Print helpful information about how to access the running application

Base the script on the technology stack specified in `AGENTS.md`.

### THIRD TASK: Initialize Git

Create a git repository and make your first commit with:

- `.tasks/` directory (complete with all 200+ features across segregated lists)
- init.sh (environment setup script)
- README.md (project overview and setup instructions)

Commit message: "Initial setup: task lists, init.sh, and project structure"

### FOURTH TASK: Create Project Structure

Set up the basic project structure based on what's specified in `AGENTS.md`.
This typically includes directories for frontend, backend, and any other
components mentioned in the spec.

### OPTIONAL: Start Implementation

If you have time remaining in this session, you may begin implementing
the highest-priority features from feature_list.json. Remember:

- Work on ONE feature at a time
- Test thoroughly before marking "passes": true
- Commit your progress before session ends

### ENDING THIS SESSION

Before your context fills up:

1. Commit all work with descriptive messages
2. Create `claude-progress.txt` with a summary of what you accomplished
3. Ensure task lists in `.tasks/` are complete and saved
4. Leave the environment in a clean, working state

The next agent will continue from here with a fresh context window.

---

**Remember:** You have unlimited time across many sessions. Focus on
quality over speed. Production-ready is the goal.
