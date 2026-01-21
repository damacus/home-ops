#!/usr/bin/env fish
# Create OIDC clients in Zitadel for Grafana, Paperless, and Mealie

set PAT (kubectl get secret -n authentication zitadel-admin-sa-pat -o jsonpath='{.data.pat}' | base64 -d)

if test -z "$PAT"
    echo "Error: Could not retrieve PAT from secret"
    exit 1
end

set ZITADEL_URL "https://zitadel.ironstone.casa"
set PROJECT_ID "355223427969320100"

echo "Creating OIDC clients in Zitadel..."
echo ""

# Function to create an OIDC application
function create_oidc_app
    set app_name $argv[1]
    set -e argv[1]
    set redirect_uris $argv

    echo "Creating $app_name..."

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

    # Create the application
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
        echo "Error creating $app_name:"
        echo $response | jq .
        return 1
    end

    echo "  Client ID: $client_id"

    if test "$auth_method" = "OIDC_AUTH_METHOD_TYPE_BASIC"
        set client_secret (echo $response | jq -r '.clientSecret // empty')
        echo "  Client Secret: $client_secret"
        echo ""

        # Store in Kubernetes secret
        kubectl create secret generic "zitadel-$app_name-oidc" \
            --from-literal=client-id="$client_id" \
            --from-literal=client-secret="$client_secret" \
            --namespace=authentication \
            --dry-run=client -o yaml | kubectl apply -f -

        echo "  ✓ Secret zitadel-$app_name-oidc created in authentication namespace"
    else
        echo "  (Public client - no secret)"
        echo ""

        # Store client ID only for public clients
        kubectl create secret generic "zitadel-$app_name-oidc" \
            --from-literal=client-id="$client_id" \
            --namespace=authentication \
            --dry-run=client -o yaml | kubectl apply -f -

        echo "  ✓ Secret zitadel-$app_name-oidc created in authentication namespace"
    end

    echo ""
end

# Create Grafana OIDC client
create_oidc_app "grafana" \
    "https://grafana.ironstone.casa/oauth2/callback" \
    "https://grafana.ironstone.casa/login/generic_oauth"

# Create Paperless OIDC client
create_oidc_app "paperless" \
    "https://paperless.ironstone.casa/oauth2/callback" \
    "https://paperless.ironstone.casa/accounts/oidc/zitadel/login/callback/"

# Create Mealie OIDC client (public)
create_oidc_app "mealie" \
    "https://mealie.ironstone.casa/login" \
    "https://mealie.ironstone.casa/login?direct=1" \
    "https://mealie.ironstone.casa/api/auth/oauth/callback"

echo "All OIDC clients created successfully!"
echo ""
echo "Next steps:"
echo "1. Update application HelmReleases to use Zitadel OIDC"
echo "2. Test login flows"
echo "3. Decommission Dex once all applications are migrated"
