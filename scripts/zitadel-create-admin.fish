#!/usr/bin/env fish
# Create a human admin user in Zitadel for console access

set PAT (kubectl get secret -n authentication zitadel-admin-sa-pat -o jsonpath='{.data.pat}' | base64 -d)

if test -z "$PAT"
    echo "Error: Could not retrieve PAT from secret"
    exit 1
end

echo "Creating admin user..."

set response (curl -s -X POST "https://zitadel.ironstone.casa/management/v1/users/human/_import" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: application/json" \
    -d '{
  "userName": "admin",
  "profile": {
    "firstName": "Admin",
    "lastName": "User",
    "displayName": "Admin User"
  },
  "email": {
    "email": "admin@ironstone.casa",
    "isEmailVerified": true
  },
  "password": "TempPassword123!",
  "passwordChangeRequired": true
}')

echo $response | jq

if echo $response | jq -e '.userId' > /dev/null 2>&1
    echo ""
    echo "✅ Admin user created successfully!"
    echo ""
    echo "Login credentials:"
    echo "  URL: https://zitadel.ironstone.casa/ui/console/"
    echo "  Username: admin"
    echo "  Password: TempPassword123!"
    echo ""
    echo "⚠️  You will be prompted to change the password on first login"
else
    echo ""
    echo "❌ Failed to create user. Check the error above."
    exit 1
end
