# Zitadel Actions Setup Guide

## Overview

This directory contains Zitadel Actions - JavaScript functions that execute during authentication flows to customize token claims and behavior.

## Actions

### 1. set-groups-claim.js

**Purpose**: Inject custom `groups` claim into OIDC tokens since Google OAuth doesn't provide group information.

**Behavior**:

- Admin users get: `["admin", "consoleAdmin", "user"]`
- Existing admin users also get `rustfs_policies: ["consoleAdmin"]`.
- Regular users get: `["user"]`
- Unapproved users get: no groups (effectively denied)

## Installation Steps

### Step 1: Create the Action in Zitadel Console

1. Navigate to <https://zitadel.damacus.io>
2. Go to **Actions** in the left sidebar
3. Click **"New Action"**
4. Fill in the form:
   - **Name**: `setGroupsClaim`
   - **Script**: Copy the contents of `set-groups-claim.js`
   - **Timeout**: 10s (default)
   - **Allowed to fail**: No (unchecked)
5. Click **"Save"**

### Step 2: Attach Action to Flow

1. Go to **Flows** in the left sidebar
2. Find the **"Complement token"** flow
3. Click **"Add Trigger"**
4. Select:
   - **Flow Type**: `Complement token`
   - **Trigger Type**: `Pre Userinfo creation`
   - **Action**: `setGroupsClaim` (the action you just created)
5. Click **"Save"**
6. Repeat the trigger setup for:
   - **Flow Type**: `Complement token`
   - **Trigger Type**: `Pre access token creation`
   - **Action**: `setGroupsClaim`

The userinfo trigger adds `groups` to ID tokens, userinfo responses, and
introspection responses. The access-token trigger adds `groups` to JWT access
tokens. OAuth2 Proxy requires the userinfo trigger when enforcing
`--allowed-group`.

### Step 3: Verify Action is Active

1. Go back to **Actions**
2. Find `setGroupsClaim`
3. Ensure it shows as **"Active"** and attached to both Complement Token triggers

## Testing

After installation, test the groups claim:

1. Log in to Mealie as admin user
2. Check that you have admin privileges
3. Log in as regular user
4. Check that you have standard user access

### Debug Token Claims

To see the actual token claims:

```bash

# Get an access token from Zitadel
# Then decode it at <https://jwt.io> to inspect claims
```

You should see:

```json
{
  "groups": ["admin", "consoleAdmin", "user"]  // for admin
  // or
  "groups": ["user"]           // for regular users
}
```


## Updating the User List

To add or remove users:

1. Edit `set-groups-claim.js`
2. Update the `adminEmails` or `approvedEmails` arrays
3. Go to Zitadel Console → Actions → `setGroupsClaim`
4. Update the script
5. Save

Changes take effect immediately on next login.

## Troubleshooting

### Groups claim not appearing in tokens

- Verify Action is attached to "Complement token" flow
- Check Action execution logs in Zitadel Console
- Ensure user email matches exactly (case-sensitive)

### User denied access despite being in list

- Check that OIDC application (Mealie) is requesting `groups` scope
- Verify `OIDC_GROUPS_CLAIM=groups` in Mealie config
- Check Mealie logs for OIDC errors

### Action execution errors

- Review Action logs in Zitadel Console
- Check JavaScript syntax
- Ensure `ctx.v1.user.email` is available

## RustFS policy mapping

RustFS uses `rustfs_policies` for both `claim_name` and `groups_claim`.
Leave `role_policy` empty: a fixed admin policy would grant every authenticated
user administrator access. General `groups` remain unchanged for other apps.
Only the existing admin email list receives the dedicated RustFS claim.
Keep the existing OIDC client ID, secret, callback and strict audience validation.
These provider settings are persisted in RustFS; update the existing Zitadel
action in place so its trigger attachments remain intact.

Run `node --test tests/test_zitadel_groups_action.cjs` to verify admin access
and denial for regular, unknown and machine users.

The action accepts both string email fields and the Email objects returned by
Zitadel 4.19.4. Both formats use the same exact approved email lists.
