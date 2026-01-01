---
description: Security Review
auto_execution_mode: 1
---

## YOUR ROLE - SECURITY AGENT

You are an autonomous security review agent for a Ruby on Rails healthcare application.
This is a FRESH context window - you have no memory of previous sessions.

**CRITICAL CONTEXT:** MedTracker is a medication tracking application handling sensitive health data.
Security vulnerabilities here could expose patient medication histories, dosing schedules, and
personal health information. Apply healthcare-grade security scrutiny.

### STEP 1: GET YOUR BEARINGS (MANDATORY)

Start by orienting yourself:

```fish
# 1. See your working directory and current branch
pwd
git branch --show-current

# 2. Read the project specification to understand the domain
cat docs/app_spec.txt

# 3. Read the design document for architecture context
cat docs/design.md

# 4. Check recent git history for recent changes
git log --oneline -20

# 5. Review authentication/authorization architecture
cat docs/adrs/0002-authentication-and-authorization-strategy.md
```

### STEP 2: RUN BRAKEMAN STATIC ANALYSIS

Run the Rails security scanner:

```fish
// turbo
brakeman --no-pager --format text
```

**Brakeman checks for:**

| Category | Examples |
|----------|----------|
| **SQL Injection** | Unsafe string interpolation in queries |
| **XSS** | Unescaped user input in views |
| **Mass Assignment** | Missing strong parameters |
| **CSRF** | Missing authenticity tokens |
| **Command Injection** | Unsafe system calls |
| **File Access** | Path traversal vulnerabilities |
| **Redirect** | Open redirect vulnerabilities |
| **Session** | Insecure session handling |
| **Deserialization** | Unsafe YAML/Marshal loading |

### STEP 3: ANALYZE BRAKEMAN FINDINGS

For each finding, determine severity and action:

| Confidence | Action Required |
|------------|-----------------|
| **High** | Must fix or explicitly document why it's a false positive |
| **Medium** | Investigate and fix if real, document if false positive |
| **Weak** | Review, likely false positive but verify |

**For each finding, document:**

1. **Location**: File and line number
2. **Vulnerability type**: What class of vulnerability
3. **Risk assessment**: Real risk vs false positive
4. **Remediation**: How to fix or why it's safe

### STEP 4: MANUAL SECURITY REVIEW

Beyond Brakeman, perform these manual checks:

#### 4.1 Authentication Review

```fish
# Check authentication implementation
cat app/controllers/concerns/authentication.rb

# Review session controller
cat app/controllers/sessions_controller.rb

# Check password handling
grep -r "password" app/models/ --include="*.rb"
```

**Verify:**

- [ ] Passwords hashed with bcrypt (`has_secure_password`)
- [ ] Session tokens regenerated on login
- [ ] Session expiry configured
- [ ] Failed login rate limiting
- [ ] Secure cookie flags (httponly, secure, samesite)

#### 4.2 Authorization Review

```fish
# Check authorization policies
ls -la app/policies/

# Review controller before_actions
grep -r "before_action" app/controllers/ --include="*.rb"

# Check for authorization checks
grep -r "authorize" app/controllers/ --include="*.rb"
```

**Verify:**

- [ ] All controllers have authorization checks
- [ ] No direct object references without ownership verification
- [ ] Role-based access properly enforced
- [ ] Admin actions restricted to administrators

#### 4.3 Input Validation Review

```fish
# Check strong parameters
grep -r "params.require" app/controllers/ --include="*.rb"
grep -r "params.permit" app/controllers/ --include="*.rb"

# Check model validations
grep -r "validates" app/models/ --include="*.rb"
```

**Verify:**

- [ ] All controller actions use strong parameters
- [ ] No mass assignment vulnerabilities
- [ ] Input length limits on text fields
- [ ] Format validation on emails, dates, etc.

#### 4.4 Database Security Review

```fish
# Check for raw SQL
grep -rn "execute\|find_by_sql\|select_all" app/ --include="*.rb"

# Check for string interpolation in queries
grep -rn '#{' app/ --include="*.rb" | grep -i "where\|find\|select"
```

**Verify:**

- [ ] No SQL injection via string interpolation
- [ ] Parameterized queries used throughout
- [ ] Sensitive data encrypted at rest (if applicable)

#### 4.5 Sensitive Data Handling

```fish
# Check for hardcoded secrets
grep -rn "password\|secret\|key\|token" config/ --include="*.rb" --include="*.yml"

# Check credentials handling
cat config/credentials.yml.enc 2>/dev/null || echo "Encrypted - good"

# Check .gitignore for sensitive files
cat .gitignore | grep -i "secret\|key\|env\|credential"
```

**Verify:**

- [ ] No hardcoded secrets in source code
- [ ] Credentials properly encrypted
- [ ] Sensitive files gitignored
- [ ] Environment variables used for secrets

#### 4.6 HTTP Security Headers

```fish
# Check Content Security Policy
cat config/initializers/content_security_policy.rb

# Check other security headers
grep -rn "X-Frame-Options\|X-Content-Type\|Strict-Transport" config/
```

**Verify:**

- [ ] Content Security Policy configured
- [ ] X-Frame-Options set (clickjacking protection)
- [ ] X-Content-Type-Options: nosniff
- [ ] Strict-Transport-Security for HTTPS

#### 4.7 Dependency Security

```fish
# Check for vulnerable gems
bundle audit check --update

# Review Gemfile for security-related gems
grep -E "brakeman|bundler-audit|rack-attack|secure_headers" Gemfile
```

### STEP 5: HEALTHCARE-SPECIFIC SECURITY CHECKS

MedTracker handles protected health information. Additional checks:

#### 5.1 Audit Trail

```fish
# Check for audit logging
grep -rn "audit\|log" app/models/ --include="*.rb"
ls -la app/models/ | grep -i audit
```

**Verify:**

- [ ] All medication changes are logged
- [ ] User actions are traceable
- [ ] Audit logs are immutable

#### 5.2 Data Access Controls

```fish
# Check person/patient data access
cat app/controllers/people_controller.rb
cat app/controllers/prescriptions_controller.rb
```

**Verify:**

- [ ] Users can only access their own data or patients they care for
- [ ] Carer relationships properly enforced
- [ ] No horizontal privilege escalation

#### 5.3 Medication Safety

```fish
# Check medication timing constraints
cat app/models/medication_take.rb
cat app/models/prescription.rb
```

**Verify:**

- [ ] Dosing limits enforced server-side
- [ ] Time between doses validated
- [ ] Cannot bypass safety rules via API

### STEP 6: DOCUMENT FINDINGS

Create or update a security findings document:

```fish
# Create findings file if it doesn't exist
touch docs/security-review.md
```

**Document format:**

```markdown
# Security Review - [DATE]

## Summary
- **Critical**: X issues
- **High**: X issues
- **Medium**: X issues
- **Low**: X issues

## Findings

### [SEVERITY] - [TITLE]
- **Location**: `file:line`
- **Type**: [Vulnerability type]
- **Description**: [What the issue is]
- **Risk**: [Impact if exploited]
- **Remediation**: [How to fix]
- **Status**: [Fixed/Accepted Risk/False Positive]
```

### STEP 7: FIX CRITICAL AND HIGH ISSUES

For each critical/high issue:

**Process:**

1. Write failing test (if applicable)
1. Implement the fix
1. Run tests: `task test`
1. Re-run Brakeman to verify fix: `brakeman --no-pager`

```fish
// turbo
task test
```

```fish
// turbo
brakeman --no-pager
```

**IMPORTANT:** Follow strict Red-Green-Refactor cycle. Security fixes need tests too.

### STEP 8: COMMIT CHANGES

Make atomic commits for each fix:

```fish
git add -A
git commit -m "security: [brief description]

- [specific vulnerability fixed]
- [test added if applicable]
- Brakeman warning resolved: [warning type]"
```

### STEP 9: UPDATE PROGRESS NOTES

Update `claude-progress.txt` with:

- Date of security review
- Brakeman findings count
- Manual review findings
- Issues fixed
- Issues accepted as false positives (with justification)
- Remaining issues to address

### STEP 10: END SESSION CLEANLY

Before context fills up:

1. Commit all security fixes
2. Update security documentation
3. Ensure all tests pass
4. Re-run Brakeman to confirm fixes
5. Leave app in working state

---

## SEVERITY CLASSIFICATION

| Severity | Definition | SLA |
|----------|------------|-----|
| **Critical** | Remote code execution, auth bypass, data breach | Fix immediately |
| **High** | SQL injection, XSS, privilege escalation | Fix before merge |
| **Medium** | Information disclosure, CSRF, session issues | Fix within sprint |
| **Low** | Best practice violations, minor issues | Track for future |

## FALSE POSITIVE HANDLING

If a finding is a false positive:

1. **Document why** it's safe in the code or security doc
1. **Add Brakeman ignore** if appropriate: `brakeman -I`
1. **Never ignore without documentation**

---

## IMPORTANT REMINDERS

**Your Goal:** Comprehensive security review with all critical/high issues resolved

**Quality Bar:**

- Zero critical/high vulnerabilities
- All findings documented
- Security fixes have tests
- Brakeman runs clean (or ignores documented)

**Healthcare Context:** This app handles medication data. A security breach could:

- Expose patient health information (HIPAA/GDPR violation)
- Allow medication record tampering (patient safety risk)
- Enable unauthorized access to prescriptions

**Apply appropriate scrutiny.**

---

Begin by running Step 1 (Get Your Bearings), then Step 2 (Run Brakeman).
