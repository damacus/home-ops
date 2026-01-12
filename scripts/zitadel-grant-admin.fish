#!/usr/bin/env fish
# Grant IAM_OWNER role to admin user for full instance access

set PAT (kubectl get secret -n authentication zitadel-admin-sa-pat -o jsonpath='{.data.pat}' | base64 -d)

if test -z "$PAT"
    echo "Error: Could not retrieve PAT from secret"
    exit 1
end

# Get the admin user ID
echo "Fetching admin user ID..."
set user_response (curl -s -X POST "https://zitadel.ironstone.casa/management/v1/users/_search" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: application/json" \
    -d '{
  "query": {
    "offset": "0",
    "limit": 100,
    "asc": true
  },
  "queries": [
    {
      "userNameQuery": {
        "userName": "admin",
        "method": "TEXT_QUERY_METHOD_EQUALS"
      }
    }
  ]
}')

set user_id (echo $user_response | jq -r '.result[0].id')

if test -z "$user_id" -o "$user_id" = "null"
    echo "Error: Could not find admin user"
    echo $user_response | jq
    exit 1
end

echo "Found user ID: $user_id"
echo "Granting IAM_OWNER role..."

# Grant IAM_OWNER role to the user
set grant_response (curl -s -X POST "https://zitadel.ironstone.casa/admin/v1/members" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: application/json" \
    -d "{
  \"userId\": \"$user_id\",
  \"roles\": [
    \"IAM_OWNER\"
  ]
}")

echo $grant_response | jq

if echo $grant_response | jq -e '.details' > /dev/null 2>&1
    echo ""
    echo "✅ IAM_OWNER role granted successfully!"
    echo ""
    echo "The admin user now has full instance administration rights."
    echo "Log out and log back in to see the changes."
else
    echo ""
    echo "❌ Failed to grant role. Check the error above."
    exit 1
end
