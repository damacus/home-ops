/**
 * Zitadel Action: Set Groups Claim
 *
 * This action injects a custom 'groups' claim into OIDC tokens based on user email.
 * Since Google OAuth doesn't provide group claims, we "fudge" them here.
 *
 * Attach this action to: "Complement token" flow
 *
 * Approved users:
 * - Admin: dan.m.webb@gmail.com
 * - Users: 28lauracummings@gmail.com, webbglor@googlemail.com, gtxthor37@gmail.com
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

    // Get user email from context
    const userEmail = ctx.v1.user.email;

    // Initialize groups array
    const groups = [];

    // Check if user is admin
    if (adminEmails.includes(userEmail)) {
        groups.push('admin');
        groups.push('consoleAdmin'); // MinIO console admin
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

    // Set the groups claim in the token
    if (groups.length > 0) {
        api.v1.claims.setClaim('groups', groups);
    }
}
