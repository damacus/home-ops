#!/usr/bin/env fish
# Regenerate OIDC client secrets in Zitadel and update 1Password

set PAT (kubectl get secret -n authentication zitadel-admin-sa-pat -o jsonpath='{.data.pat}' | base64 -d)

if test -z "$PAT"
    echo "Error: Could not retrieve PAT from secret"
    exit 1
end

set ZITADEL_URL "https://zitadel.ironstone.casa"
set PROJECT_ID "355223427969320100"

echo "Retrieving existing OIDC applications..."
echo ""

# Get all apps in the project
set apps_response (curl -s "$ZITADEL_URL/management/v1/projects/$PROJECT_ID/apps/_search" \
    -H "Authorization: Bearer $PAT" \
    -H "Content-Type: application/json" \
    -d '{"queries": []}')

# Function to regenerate secret for an app
function regenerate_secret
    set app_name $argv[1]

    echo "Processing $app_name..."

    # Find the app ID
    set app_id (echo $apps_response | jq -r ".result[] | select(.name == \"$app_name\") | .id")
    set client_id (echo $apps_response | jq -r ".result[] | select(.name == \"$app_name\") | .oidcConfig.clientId")

    if test -z "$app_id"
        echo "  Error: Application '$app_name' not found"
        return 1
    end

    echo "  App ID: $app_id"
    echo "  Client ID: $client_id"

    # Check if it's a public client (Mealie)
    set auth_method (echo $apps_response | jq -r ".result[] | select(.name == \"$app_name\") | .oidcConfig.authMethodType")

    if test "$auth_method" = "OIDC_AUTH_METHOD_TYPE_NONE"
        echo "  Public client - no secret to regenerate"

        # Update 1Password with just client-id
        op item edit "zitadel-$app_name-oidc" --vault home-ops "client-id=$client_id" 2>/dev/null
        or op item create --category "API Credential" --vault "home-ops" --title "zitadel-$app_name-oidc" "client-id=$client_id"

        echo "  ✓ Updated 1Password item"
    else
        # Regenerate secret for confidential clients
        set secret_response (curl -s -X PUT "$ZITADEL_URL/management/v1/projects/$PROJECT_ID/apps/$app_id/oidc_config/secret" \
            -H "Authorization: Bearer $PAT" \
            -H "Content-Type: application/json")

        set client_secret (echo $secret_response | jq -r '.clientSecret // empty')

        if test -z "$client_secret"
            echo "  Error regenerating secret:"
            echo $secret_response | jq .
            return 1
        end

        echo "  New Client Secret: $client_secret"

        # Update 1Password
        op item edit "zitadel-$app_name-oidc" --vault home-ops "client-id=$client_id" "client-secret=$client_secret" 2>/dev/null
        or op item create --category "API Credential" --vault "home-ops" --title "zitadel-$app_name-oidc" "client-id=$client_id" "client-secret=$client_secret"

        echo "  ✓ Updated 1Password item"
    end

    echo ""
end

# Regenerate secrets for all apps
regenerate_secret "grafana"
regenerate_secret "paperless"
regenerate_secret "mealie"

echo "All OIDC client secrets regenerated and stored in 1Password!"
echo ""
echo "Next steps:"
echo "1. Wait for ExternalSecrets to sync (should happen automatically)"
echo "2. Verify secrets synced: kubectl get externalsecret -A | grep zitadel"
echo "3. Test login flows for each application"
