#!/bin/bash
# Configure the mcp-gateway realm so VS Code can sign in to the gateway through
# Keycloak dynamic client registration (DCR). Idempotent: safe to re-run.
#
# Applies:
#   1. Trusted Hosts (anonymous DCR policy): VS Code's redirect and client URIs,
#      and turns off the sending-host check (see below).
#   2. Allowed Client Scopes (anonymous DCR policy): the mcp-servers-* scopes.
#   3. Realm default optional client scopes: the mcp-servers-* scopes, so every
#      client VS Code registers may request them.
#
# Usage: keycloak/setup/configure-vscode-dcr.sh [--dry-run]
# See docs/vscode-keycloak-setup.md for the manual steps and troubleshooting.

set -euo pipefail

KEYCLOAK_CONTAINER="${KEYCLOAK_CONTAINER:-mcp-gateway-registry-keycloak-1}"
REALM="${REALM:-mcp-gateway}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# VS Code registers with redirect URIs on 127.0.0.1 / localhost and
# vscode.dev (+ insiders.vscode.dev), and client_uri https://code.visualstudio.com.
TRUSTED_HOSTS=(localhost 127.0.0.1 vscode.dev '*.vscode.dev' code.visualstudio.com)
MCP_SCOPES=(
    mcp-servers-unrestricted/read
    mcp-servers-unrestricted/execute
    mcp-servers-restricted/read
    mcp-servers-restricted/execute
)
POLICY_TYPE=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy
KCADM_CONFIG=/tmp/kcadm-vscode-dcr.config

# kcadm runs inside the container, so the admin password never leaves it.
kc() {
    docker exec -i "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh "$@" --config "$KCADM_CONFIG"
}

login() {
    docker exec "$KEYCLOAK_CONTAINER" sh -c \
        '/opt/keycloak/bin/kcadm.sh config credentials --config '"$KCADM_CONFIG"' \
            --server http://localhost:8080 --realm master \
            --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"' >/dev/null
}

# Apply a jq filter to an anonymous DCR policy and save it if it changed.
update_policy() {
    local name=$1 filter=$2; shift 2
    local component id updated
    # Filter subType in jq: each policy name exists for both anonymous and
    # authenticated registration.
    component=$(kc get components -r "$REALM" -q type="$POLICY_TYPE" |
        jq --arg n "$name" '.[] | select(.name == $n and .subType == "anonymous")')
    if [ -z "$component" ]; then
        echo "Error: anonymous DCR policy '$name' not found in realm $REALM" >&2
        exit 1
    fi
    id=$(jq -r .id <<<"$component")
    updated=$(jq "$filter" --args "$@" <<<"$component")

    # Config values are lists whose order Keycloak doesn't keep; compare sorted.
    local normalize='.config |= map_values(sort)'
    if [ "$(jq -S "$normalize" <<<"$component")" = "$(jq -S "$normalize" <<<"$updated")" ]; then
        echo "  $name: already configured"
    elif [ "$DRY_RUN" = 1 ]; then
        echo "  $name: would change config to $(jq -c .config <<<"$updated")"
    else
        kc update "components/$id" -r "$REALM" -f - <<<"$updated"
        echo "  $name: updated"
    fi
}

echo "Configuring realm $REALM in $KEYCLOAK_CONTAINER for VS Code DCR$([ "$DRY_RUN" = 1 ] && echo ' (dry run)')"
login

echo "Registration policies:"
# The sending-host check compares the caller's address with the trusted hosts.
# Registration requests reach Keycloak from the Docker bridge (e.g. 172.22.0.1),
# never a trusted host, so the check has to be off; client-uris-must-match stays on.
update_policy "Trusted Hosts" '
    .config["trusted-hosts"] = ((.config["trusted-hosts"] // []) + $ARGS.positional | unique)
    | .config["host-sending-registration-request-must-match"] = ["false"]
    | .config["client-uris-must-match"] = ["true"]' "${TRUSTED_HOSTS[@]}"
update_policy "Allowed Client Scopes" '
    .config["allowed-client-scopes"] = ((.config["allowed-client-scopes"] // []) + $ARGS.positional | unique)
    | .config["allow-default-scopes"] = ["true"]' "${MCP_SCOPES[@]}"

echo "Realm default optional client scopes:"
scopes=$(kc get client-scopes -r "$REALM")
optional=$(kc get "realms/$REALM/default-optional-client-scopes")
for scope in "${MCP_SCOPES[@]}"; do
    scope_id=$(jq -r --arg n "$scope" '.[] | select(.name == $n) | .id' <<<"$scopes")
    if [ -z "$scope_id" ]; then
        echo "Error: client scope $scope not found in realm $REALM" >&2
        exit 1
    fi
    if jq -e --arg n "$scope" 'any(.[]; .name == $n)' <<<"$optional" >/dev/null; then
        echo "  $scope: already optional"
    elif [ "$DRY_RUN" = 1 ]; then
        echo "  $scope: would add as optional"
    else
        kc update "realms/$REALM/default-optional-client-scopes/$scope_id" -n
        echo "  $scope: added as optional"
    fi
done

echo "Done. Clients VS Code registered before this ran lack the new scopes: delete them"
echo "under Clients, then run 'Authentication: Remove Dynamic Authentication Providers' in VS Code."
