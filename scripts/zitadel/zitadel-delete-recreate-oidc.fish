#!/usr/bin/env fish
# Delete and recreate OIDC clients in Zitadel for Grafana, Paperless, and Mealie

set PAT (kubectl get secret -n authentication zitadel-admin-sa-pat -o jsonpath='{.data.pat}' | base64 -d)

if test -z "$PAT"
    echo "Error: Could not retrieve PAT from secret"
    exit 1
end

set ZITADEL_URL "https://zitadel.ironstone.casa"
set PROJECT_ID "355223427969320100"

echo "Deleting and recreating OIDC clients in Zitadel..."
echo ""

# Function to delete and recreate an OIDC application
function recreate_oidc_app
    set app_name $argv[1]
    set app_id $argv[2]
    set -e argv[1..2]
    set redirect_uris $argv

    echo "Processing $app_name (ID: $app_id)..."

    # Delete the existing app
    echo "  Deleting existing app..."
    set delete_response (curl -s -X DELETE "$ZITADEL_URL/management/v1/projects/$PROJECT_ID/apps/$app_id" \
        -H "Authorization: Bearer $PAT")

    set delete_code (echo $delete_response | jq -r '.code // empty')
    if test -n "$delete_code"
        echo "  Warning during delete:"
        echo $delete_response | jq .
    else
        echo "  ✓ Deleted successfully"
    end

    # Build redirect URIs JSON array
    set uris_json "["
    for uri in $redirect_uris
        set uris_json "$uris_json\"$uri\","
    end
    set uris_json (string trim -r -c ',' $uris_json)"]"

    # Determine if this should be a public client (Mealie)
    set auth_method "OIDC_AUTH_METHOD_TYPE_BASIC"
    if test "$app_name" = "mealie"
        set auth_method "OIDC_AUTH_METHOD_TYPE_NONE"
    end

    # Create the new application
    echo "  Creating new app..."
    set response (curl -s -X POST "$ZITADEL_URL/management/v1/projects/$PROJECT_ID/apps/oidc" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$app_name\",
            \"redirectUris\": $uris_json,
            \"responseTypes\": [\"OIDC_RESPONSE_TYPE_CODE\"],
            \"grantTypes\": [\"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\"],
            \"appType\": \"OIDC_APP_TYPE_WEB\",
            \"authMethodType\": \"$auth_method\",
            \"version\": \"OIDC_VERSION_1_0\",
            \"devMode\": false,
            \"accessTokenType\": \"OIDC_TOKEN_TYPE_BEARER\",
            \"idTokenRoleAssertion\": false,
            \"idTokenUserinfoAssertion\": false,
            \"clockSkew\": \"0s\",
            \"additionalOrigins\": [],
            \"skipNativeAppSuccessPage\": false
        }")

    set client_id (echo $response | jq -r '.clientId // empty')

    if test -z "$client_id"
        echo "  Error creating $app_name:"
        echo $response | jq .
        return 1
    end

    echo "  ✓ Created successfully"
    echo "  Client ID: $client_id"

    if test "$auth_method" = "OIDC_AUTH_METHOD_TYPE_BASIC"
        set client_secret (echo $response | jq -r '.clientSecret // empty')
        echo "  Client Secret: $client_secret"

        # Update 1Password
        echo "  Updating 1Password..."
        op item delete "zitadel-$app_name-oidc" --vault home-ops 2>/dev/null
        op item create --category "API Credential" --vault "home-ops" --title "zitadel-$app_name-oidc" \
            "client_id[text]=$client_id" \
            "client_secret[password]=$client_secret"

        echo "  ✓ 1Password item created"
    else
        echo "  (Public client - no secret)"

        # Update 1Password with just client_id
        echo "  Updating 1Password..."
        op item delete "zitadel-$app_name-oidc" --vault home-ops 2>/dev/null
        op item create --category "API Credential" --vault "home-ops" --title "zitadel-$app_name-oidc" \
            "client_id[text]=$client_id"

        echo "  1Password item created"
    end

    echo ""
end

# Recreate Grafana OIDC client (correct app ID: 355231366813584431)
recreate_oidc_app "grafana" "355231366813584431" \
    "https://grafana.ironstone.casa/oauth2/callback" \
    "https://grafana.ironstone.casa/login/generic_oauth"

# Recreate Paperless OIDC client (correct app ID: 355231366931024943)
recreate_oidc_app "paperless" "355231366931024943" \
    "https://paperless.ironstone.casa/oauth2/callback" \
    "https://paperless.ironstone.casa/accounts/oidc/zitadel/login/callback/"

# Mealie was already recreated, but including for completeness
# If you need to recreate it again, uncomment and update the app ID
# recreate_oidc_app "mealie" "355240244963970095" \
#     "https://mealie.ironstone.casa/login" \
#     "https://mealie.ironstone.casa/login?direct=1" \
#     "https://mealie.ironstone.casa/api/auth/oauth/callback"

echo "All OIDC clients recreated successfully!"
echo ""
echo "Next steps:"
echo "1. Wait for ExternalSecrets to sync (should happen automatically within 1 hour)"
echo "2. Or force sync: kubectl annotate externalsecret -n monitoring zitadel-grafana-oidc force-sync=(date +%s) --overwrite"
echo "3. Verify secrets: kubectl get secret -n monitoring zitadel-grafana-oidc -o yaml"
echo "4. Test login flows for each application"
