/**
 * Zitadel Action: Set Groups Claim
 *
 * This action injects a custom 'groups' claim into OIDC tokens based on user email.
 * Since Google OAuth doesn't provide group claims, we "fudge" them here.
 *
 * Attach this action to: "Complement token" flow
 *
 */

function setGroupsClaim(ctx, api) {
    // Define admin users
    const adminEmails = [
        'dan.m.webb@gmail.com',
        'dan.webb@damacus.io'
    ];

    // Define approved regular users
    const approvedEmails = [
        '28lauracummings@gmail.com',
        'webbglor@googlemail.com',
        'gtxthor37@gmail.com',
        'dan.webb@damacus.io'
    ];

    // Complement Token actions can also run for machine users.
    const user = ctx.v1.getUser();
    if (!user.human) {
        return;
    }
    // Zitadel versions expose either a string or an Email object.
    const email = user.human.email;
    const userEmail = email == null ? undefined : String(email);

    // Initialize groups array
    const groups = [];

    // Check if user is admin
    if (adminEmails.includes(userEmail)) {
        groups.push('admin');
        groups.push('consoleAdmin'); // Object storage console admin
        groups.push('user'); // Admins are also users
    }
    // Check if user is approved regular user
    else if (approvedEmails.includes(userEmail)) {
        groups.push('user');
    }
    // Unapproved user - no groups (will be denied access)
    else {
        // Optionally log or handle unapproved users
        // For now, we just don't add any groups
    }

    // RustFS 1.0.1 requires every mapped value to name an existing policy.
    // Keep general application groups separate from storage permissions.
    if (groups.includes('consoleAdmin')) {
        api.v1.claims.setClaim('rustfs_policies', ['consoleAdmin']);
    }

    // Set the groups claim in the token
    if (groups.length > 0) {
        api.v1.claims.setClaim('groups', groups);
    }
}

function setGroupClaims(ctx, api) {
    setGroupsClaim(ctx, api);
}
