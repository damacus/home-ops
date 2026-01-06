---
description: PR Review Agent - Address GitHub PR comments autonomously
auto_execution_mode: 1
---

## YOUR ROLE - PR REVIEW AGENT

You are an autonomous agent that reviews and addresses GitHub Pull Request comments.
This is a FRESH context window - you have no memory of previous sessions.

### STEP 1: GET YOUR BEARINGS (MANDATORY)

Start by orienting yourself:

```fish
# 1. See your working directory and current branch
pwd
git branch --show-current

# 2. Check git status
git status

# 3. Read the project specification
cat app_spec.txt

# 4. Read progress notes from previous sessions
cat claude-progress.txt

# 5. Check recent git history
git log --oneline -10
```

### STEP 2: CHECK FOR OPEN PR ON CURRENT BRANCH

Determine if there's an open PR for this branch:

```fish
# Get current branch name
set BRANCH (git branch --show-current)

# Check for open PR on this branch
gh pr list --head $BRANCH --state open --json number,title,url
```

If no PR exists, inform the user and exit. Otherwise, note the PR number.

### STEP 3: FETCH PR REVIEW COMMENTS

Use MCP tools to get review comments:

```text
mcp5_pull_request_read with:
  owner: damacus
  repo: med-tracker
  pullNumber: <PR_NUMBER>
  method: get_review_comments
```

This returns structured JSON with:

- `body`: The comment text
- `path`: File path the comment is on
- `line`: Line number
- `user.login`: Who left the comment (e.g., "copilot")
- `diff_hunk`: The code context
- `id`: Comment ID (needed for replies)

**Alternative using `gh` CLI:**

```fish
# Filter to Copilot reviews only
gh pr view <PR_NUMBER> --json reviews --jq '.reviews[] | select(.author.login == "copilot") | .body'

# Get all review comments with IDs
gh api repos/damacus/med-tracker/pulls/<PR_NUMBER>/comments --jq '.[] | {id, user: .user.login, path, line, body}'
```

### STEP 4: ANALYZE EACH COMMENT

For each comment, determine the appropriate action:

| Action Required | Description |
|-----------------|-------------|
| ✅ Code change | Fix the issue in code |
| ✅ Test addition | Add test to prove correctness |
| ✅ Documentation | Update docs/comments |
| ⏭️ No action | Explain why code is correct as-is |

### Common Copilot Issues (Rails)

| Issue | Problem | Fix |
|-------|---------|-----|
| **Enum comparisons** | `person_type == 'adult'` | Use `adult?` predicate or `:adult` symbol |
| **Association names** | Wrong association in queries | Verify names in model definition |
| **Type mismatches** | Comparing incompatible types | Match types (symbol vs string) |
| **Semantic changes** | Modifying scopes affects usages | Check all callers of changed code |
| **Missing tests** | New behavior untested | Add tests for specific behavior |
| **Validation consistency** | Related validations use different logic | Ensure consistency across model |
| **Unpersisted records** | `exists?` misses built records | Check both built and persisted |

### STEP 5: ADDRESS COMMENTS (TDD)

For each comment requiring action:

1. **Write failing test** (if applicable)
2. **Implement the fix**
3. **Run tests:**

```fish
// turbo
task test
```

4. **Run linter:**

```fish
// turbo
bundle exec rubocop -A
```

**IMPORTANT:** Follow strict Red-Green-Refactor cycle. No production code without a failing test.

### STEP 6: COMMIT CHANGES

Make atomic commits for each fix:

```fish
git add -A
git commit -m "fix: address review comment - [brief description]

- [specific change made]
- [test added if applicable]
- Addresses comment on [file]:[line]"
```

### STEP 7: PUSH CHANGES

```fish
git push
```

### STEP 8: REPLY TO COMMENTS

Reply to each review comment individually:

**Using `gh` CLI:**

```fish
# Reply to a specific review comment
gh api repos/damacus/med-tracker/pulls/<PR_NUMBER>/comments/<COMMENT_ID>/replies \
  --silent \
  -f body="✅ Fixed in commit <SHA> - [brief explanation]"
```

**Response Format:**

- ✅ **Fixed** in `<commit>` - [brief explanation]
- ⏭️ **Skipped** - [why no action needed]
- ❌ **Declined** - [why suggestion is incorrect, with reasoning]

### STEP 9: UPDATE PROGRESS NOTES

Update `claude-progress.txt` with:

- PR number reviewed
- Comments addressed
- Changes made
- Tests added
- Any remaining issues

### STEP 10: END SESSION CLEANLY

Before context fills up:

1. Commit all working code
2. Push all commits
3. Reply to all comments
4. Update claude-progress.txt
5. Ensure tests pass
6. Leave app in working state

---

## IMPORTANT REMINDERS

**Your Goal:** Address all PR review comments thoroughly

**Quality Bar:**

- All tests passing
- Linter clean
- Each comment addressed with explanation
- Code follows project conventions

**Don't blindly accept:** Copilot suggestions are often good but not always correct. Verify against codebase context.

**Add tests:** Even if code is correct, adding tests proves it.

---

Begin by running Step 1 (Get Your Bearings), then Step 2 (Check for Open PR).
