#!/usr/bin/env fish
# Create OIDC clients for Grafana, Paperless, MinIO, and Mealie

set PAT (kubectl get secret -n authentication zitadel-admin-sa-pat -o jsonpath='{.data.pat}' | base64 -d)

if test -z "$PAT"
    echo "Error: Could not retrieve PAT from secret"
    exit 1
end

echo "Creating OIDC applications in Zitadel..."
echo ""

# Function to create an OIDC application
function create_oidc_app
    set app_name $argv[1]
    set redirect_uris $argv[2..-1]

    echo "Creating $app_name..."

    # Build redirect URIs JSON array
    set uris_json "["
    for uri in $redirect_uris
        set uris_json "$uris_json\"$uri\","
    end
    set uris_json (string trim -r -c ',' $uris_json)"]"

    set response (curl -s -X POST "https://zitadel.ironstone.casa/management/v1/projects/355223427969320100/apps/oidc" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        -d "{
  \"name\": \"$app_name\",
  \"redirectUris\": $uris_json,
  \"responseTypes\": [
    \"OIDC_RESPONSE_TYPE_CODE\"
  ],
  \"grantTypes\": [
    \"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\",
    \"OIDC_GRANT_TYPE_REFRESH_TOKEN\"
  ],
  \"appType\": \"OIDC_APP_TYPE_WEB\",
  \"authMethodType\": \"OIDC_AUTH_METHOD_TYPE_BASIC\",
  \"postLogoutRedirectUris\": [],
  \"version\": \"OIDC_VERSION_1_0\",
  \"devMode\": false,
  \"accessTokenType\": \"OIDC_TOKEN_TYPE_BEARER\",
  \"accessTokenRoleAssertion\": true,
  \"idTokenRoleAssertion\": true,
  \"idTokenUserinfoAssertion\": true,
  \"clockSkew\": \"0s\",
  \"additionalOrigins\": [],
  \"skipNativeAppSuccessPage\": false
}")

    if echo $response | jq -e '.clientId' > /dev/null 2>&1
        set client_id (echo $response | jq -r '.clientId')
        set client_secret (echo $response | jq -r '.clientSecret')
        echo "  ✅ Created successfully"
        echo "     Client ID: $client_id"
        echo "     Client Secret: $client_secret"
        echo ""

        # Save to file for reference
        echo "$app_name:" >> /tmp/zitadel-clients.txt
        echo "  client_id: $client_id" >> /tmp/zitadel-clients.txt
        echo "  client_secret: $client_secret" >> /tmp/zitadel-clients.txt
        echo "" >> /tmp/zitadel-clients.txt
    else
        echo "  ❌ Failed"
        echo $response | jq
        echo ""
    end
end

# Create public app (Mealie)
function create_public_oidc_app
    set app_name $argv[1]
    set redirect_uris $argv[2..-1]

    echo "Creating $app_name (public client)..."

    # Build redirect URIs JSON array
    set uris_json "["
    for uri in $redirect_uris
        set uris_json "$uris_json\"$uri\","
    end
    set uris_json (string trim -r -c ',' $uris_json)"]"

    set response (curl -s -X POST "https://zitadel.ironstone.casa/management/v1/projects/355223427969320100/apps/oidc" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        -d "{
  \"name\": \"$app_name\",
  \"redirectUris\": $uris_json,
  \"responseTypes\": [
    \"OIDC_RESPONSE_TYPE_CODE\"
  ],
  \"grantTypes\": [
    \"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\",
    \"OIDC_GRANT_TYPE_REFRESH_TOKEN\"
  ],
  \"appType\": \"OIDC_APP_TYPE_USER_AGENT\",
  \"authMethodType\": \"OIDC_AUTH_METHOD_TYPE_NONE\",
  \"postLogoutRedirectUris\": [],
  \"version\": \"OIDC_VERSION_1_0\",
  \"devMode\": false,
  \"accessTokenType\": \"OIDC_TOKEN_TYPE_BEARER\",
  \"accessTokenRoleAssertion\": true,
  \"idTokenRoleAssertion\": true,
  \"idTokenUserinfoAssertion\": true,
  \"clockSkew\": \"0s\",
  \"additionalOrigins\": [],
  \"skipNativeAppSuccessPage\": false
}")

    if echo $response | jq -e '.clientId' > /dev/null 2>&1
        set client_id (echo $response | jq -r '.clientId')
        echo "  ✅ Created successfully"
        echo "     Client ID: $client_id"
        echo "     (No client secret - public client)"
        echo ""

        # Save to file for reference
        echo "$app_name:" >> /tmp/zitadel-clients.txt
        echo "  client_id: $client_id" >> /tmp/zitadel-clients.txt
        echo "  public: true" >> /tmp/zitadel-clients.txt
        echo "" >> /tmp/zitadel-clients.txt
    else
        echo "  ❌ Failed"
        echo $response | jq
        echo ""
    end
end

# Clear previous output
rm -f /tmp/zitadel-clients.txt

# Create applications
create_oidc_app "Grafana" \
    "https://grafana.ironstone.casa/oauth2/callback" \
    "https://grafana.ironstone.casa/login/generic_oauth"

create_oidc_app "Paperless" \
    "https://paperless.ironstone.casa/oauth2/callback" \
    "https://paperless.ironstone.casa/accounts/oidc/dex/login/callback/"

create_oidc_app "MinIO" \
    "https://minio.ironstone.casa/oauth_callback"

create_public_oidc_app "Mealie"

echo "========================================="
echo "All OIDC clients created!"
echo ""
echo "Client details saved to: /tmp/zitadel-clients.txt"
echo ""
echo "Next steps:"
echo "1. Update application configs with new client IDs and secrets"
echo "2. Update OIDC endpoints to use Zitadel:"
echo "   - Issuer: https://zitadel.ironstone.casa"
echo "   - Authorization: https://zitadel.ironstone.casa/oauth/v2/authorize"
echo "   - Token: https://zitadel.ironstone.casa/oauth/v2/token"
echo "   - UserInfo: https://zitadel.ironstone.casa/oidc/v1/userinfo"
echo "   - JWKS: https://zitadel.ironstone.casa/oauth/v2/keys"
