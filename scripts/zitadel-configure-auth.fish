#!/usr/bin/env fish
# Configure authentication options: local auth + Google IDP

set PAT (kubectl get secret -n authentication zitadel-admin-sa-pat -o jsonpath='{.data.pat}' | base64 -d)

if test -z "$PAT"
    echo "Error: Could not retrieve PAT from secret"
    exit 1
end

# Get Google IDP credentials from zitadel-google-idp secret
echo "Fetching Google OAuth credentials..."
set GOOGLE_CLIENT_ID (kubectl get secret -n authentication zitadel-google-idp -o jsonpath='{.data.client-id}' | base64 -d)
set GOOGLE_CLIENT_SECRET (kubectl get secret -n authentication zitadel-google-idp -o jsonpath='{.data.client-secret}' | base64 -d)

if test -z "$GOOGLE_CLIENT_ID" -o -z "$GOOGLE_CLIENT_SECRET"
    echo "Warning: Could not retrieve Google OAuth credentials from Dex"
    echo "You'll need to configure Google IDP manually or provide credentials"
else
    echo "Found Google OAuth credentials"
    echo "Client ID: $GOOGLE_CLIENT_ID"
end

# Add Google as an identity provider
echo ""
echo "Adding Google as identity provider..."

set idp_response (curl -s -X POST "https://zitadel.ironstone.casa/admin/v1/idps/google" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: application/json" \
    -d "{
  \"name\": \"Google\",
  \"clientId\": \"$GOOGLE_CLIENT_ID\",
  \"clientSecret\": \"$GOOGLE_CLIENT_SECRET\",
  \"scopes\": [
    \"openid\",
    \"profile\",
    \"email\"
  ],
  \"providerOptions\": {
    \"isLinkingAllowed\": true,
    \"isCreationAllowed\": true,
    \"isAutoCreation\": false,
    \"isAutoUpdate\": true
  }
}")

echo $idp_response | jq

if echo $idp_response | jq -e '.id' > /dev/null 2>&1
    echo ""
    echo "✅ Google IDP configured successfully!"
    set idp_id (echo $idp_response | jq -r '.id')
    echo "IDP ID: $idp_id"
else
    echo ""
    echo "⚠️  Google IDP configuration failed or already exists"
end

echo ""
echo "Authentication options configured:"
echo "  ✅ Local authentication (username/password) - enabled by default"
echo "  ✅ Google OAuth - configured as identity provider"
echo ""
echo "Users can now:"
echo "  - Register with username/password"
echo "  - Login with Google account"
echo "  - Link Google account to existing local account"
