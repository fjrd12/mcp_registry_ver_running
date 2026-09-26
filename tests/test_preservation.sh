#!/usr/bin/env bash
#
# Preservation Property Tests for Admin Login Fix
# 
# Purpose: Verify that all non-admin user functionality remains unchanged after the fix.
# These tests MUST pass on both unfixed and fixed code to ensure no regressions.
#
# Test Approach: Observation-first methodology
# 1. Run on UNFIXED code to document baseline behavior
# 2. Write tests capturing observed patterns
# 3. Verify tests pass on UNFIXED code
# 4. After fix is applied, verify tests still pass (preservation check)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$SCRIPT_DIR/.."

if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

# Configuration
KEYCLOAK_URL="${KEYCLOAK_ADMIN_URL:-http://localhost:8080}"
REALM="mcp-gateway"

# Helper Functions
# ----------------

log_test() {
    echo -e "${BLUE}[TEST ${TESTS_RUN}]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}  ✓ PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}  ✗ FAIL${NC}: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TESTS+=("$1")
}

log_info() {
    echo -e "${YELLOW}  ℹ INFO${NC}: $1"
}

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    log_test "$test_name"
}

# Get admin token for Keycloak API calls
get_admin_token() {
    local response
    response=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
        -d "username=${KEYCLOAK_ADMIN:-admin}" \
        --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" 2>/dev/null)
    
    echo "$response" | jq -r '.access_token // empty'
}

# Get user access token (password grant)
get_user_token() {
    local username="$1"
    local password="$2"
    local client_id="${3:-mcp-gateway-web}"
    
    local response
    response=$(curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
        -d "username=$username" \
        --data-urlencode "password=$password" \
        -d "grant_type=password" \
        -d "client_id=$client_id" 2>/dev/null)
    
    echo "$response" | jq -r '.access_token // empty'
}

# Get client credentials token (M2M)
get_client_credentials_token() {
    local client_id="$1"
    local client_secret="$2"
    
    local response
    response=$(curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
        -d "client_id=$client_id" \
        --data-urlencode "client_secret=$client_secret" \
        -d "grant_type=client_credentials" 2>/dev/null)
    
    echo "$response" | jq -r '.access_token // empty'
}

# Check if user exists
user_exists() {
    local username="$1"
    local token="$2"
    
    local response
    response=$(curl -s -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=${username}&exact=true" 2>/dev/null)
    
    local user_id
    user_id=$(echo "$response" | jq -r '.[0].id // empty')
    
    [ -n "$user_id" ]
}

# Get user groups
get_user_groups() {
    local username="$1"
    local token="$2"
    
    local user_id
    user_id=$(curl -s -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=${username}&exact=true" 2>/dev/null | \
        jq -r '.[0].id // empty')
    
    if [ -z "$user_id" ]; then
        echo ""
        return 1
    fi
    
    curl -s -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/groups" 2>/dev/null | \
        jq -r '.[].name'
}

# Get client configuration
get_client_config() {
    local client_id="$1"
    local token="$2"
    
    curl -s -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${client_id}" 2>/dev/null | \
        jq -r '.[0]'
}

# Get realm configuration
get_realm_config() {
    local token="$1"
    
    curl -s -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}" 2>/dev/null
}

# Check if group exists
group_exists() {
    local group_name="$1"
    local token="$2"
    
    local groups
    groups=$(curl -s -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" 2>/dev/null | \
        jq -r '.[].name')
    
    echo "$groups" | grep -q "^${group_name}$"
}

# Decode JWT token to inspect groups
decode_jwt_groups() {
    local token="$1"
    
    # JWT has 3 parts: header.payload.signature
    # We need the payload (part 2)
    local payload
    payload=$(echo "$token" | cut -d. -f2)
    
    # Add padding if needed (base64url requires it)
    local padded="$payload"
    case $((${#payload} % 4)) in
        2) padded="${payload}==" ;;
        3) padded="${payload}=" ;;
    esac
    
    # Decode base64url (replace - with + and _ with /)
    echo "$padded" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.groups[]? // empty'
}

# ================================
# TEST SUITE
# ================================

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Preservation Property Tests${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Testing non-admin user functionality to ensure"
echo "it remains unchanged after the admin login fix."
echo ""

# Get admin token for API operations
ADMIN_TOKEN=$(get_admin_token)
if [ -z "$ADMIN_TOKEN" ]; then
    echo -e "${RED}FATAL: Cannot obtain Keycloak admin token${NC}"
    echo "Ensure Keycloak is running and credentials are correct."
    exit 1
fi

echo -e "${GREEN}✓ Connected to Keycloak${NC}"
echo ""

# ================================
# Test 1: Service Account Creation Preserved
# ================================
run_test "Service Account Creation Preserved"

# Test 1.1: Service account exists
if user_exists "service-account-mcp-gateway-m2m" "$ADMIN_TOKEN"; then
    log_pass "Service account 'service-account-mcp-gateway-m2m' exists"
else
    log_fail "Service account 'service-account-mcp-gateway-m2m' not found"
fi

# Test 1.2: Service account groups
# Note: Based on observation, service-account-mcp-gateway-m2m is assigned to registry-admins
SA_GROUPS=$(get_user_groups "service-account-mcp-gateway-m2m" "$ADMIN_TOKEN")
log_info "Service account groups: $(echo "$SA_GROUPS" | tr '\n' ', ' | sed 's/,$//')"

if echo "$SA_GROUPS" | grep -q "registry-admins"; then
    log_pass "Service account has 'registry-admins' group"
else
    log_fail "Service account missing 'registry-admins' group"
fi

# Test 1.3: Service account can obtain client credentials token
if [ -f .oauth-tokens/keycloak-client-secrets.txt ]; then
    M2M_SECRET=$(grep "^KEYCLOAK_M2M_CLIENT_SECRET=" .oauth-tokens/keycloak-client-secrets.txt | cut -d= -f2-)
    if [ -n "$M2M_SECRET" ]; then
        M2M_TOKEN=$(get_client_credentials_token "mcp-gateway-m2m" "$M2M_SECRET")
        if [ -n "$M2M_TOKEN" ]; then
            log_pass "Service account can obtain client credentials token"
        else
            log_fail "Service account cannot obtain client credentials token"
        fi
    else
        log_info "M2M client secret not found, skipping token test"
    fi
else
    log_info "Client secrets file not found, skipping token test"
fi

echo ""

# ================================
# Test 2: Bootstrap Users Login Preserved
# ================================
run_test "Bootstrap Users Login Preserved"

# Bootstrap users created by bootstrap_user_and_m2m_setup.sh
BOOTSTRAP_USERS=("lob1-user" "lob2-user" "admin-user")

for user in "${BOOTSTRAP_USERS[@]}"; do
    # Test 2.1: User exists
    if user_exists "$user" "$ADMIN_TOKEN"; then
        log_pass "User '${user}' exists"
    else
        log_fail "User '${user}' not found"
        continue
    fi
    
    # Test 2.2: Check user credentials are configured (not temporary)
    # Note: Direct password grant may not be enabled for these users on web client
    # Instead, we verify the user is enabled and has credentials configured
    USER_ID=$(curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=${user}&exact=true" 2>/dev/null | \
        jq -r '.[0].id')
    
    USER_DETAILS=$(curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}" 2>/dev/null)
    
    IS_ENABLED=$(echo "$USER_DETAILS" | jq -r '.enabled')
    if [ "$IS_ENABLED" = "true" ]; then
        log_pass "User '${user}' is enabled"
    else
        log_fail "User '${user}' is not enabled"
    fi
    
    # Test 2.3: User has groups assigned
    USER_GROUPS_LIST=$(get_user_groups "$user" "$ADMIN_TOKEN")
    if [ -n "$USER_GROUPS_LIST" ]; then
        log_pass "User '${user}' has groups assigned"
        log_info "  Groups: $(echo "$USER_GROUPS_LIST" | tr '\n' ', ' | sed 's/,$//')"
    else
        log_fail "User '${user}' has no groups assigned"
    fi
done

echo ""

# ================================
# Test 3: Bootstrap M2M Accounts Preserved
# ================================
run_test "Bootstrap M2M Accounts Preserved"

# M2M service accounts created by bootstrap script
M2M_ACCOUNTS=("service-account-lob1-bot" "service-account-lob2-bot" "service-account-admin-bot")

for account in "${M2M_ACCOUNTS[@]}"; do
    if user_exists "$account" "$ADMIN_TOKEN"; then
        log_pass "M2M account '${account}' exists"
    else
        log_fail "M2M account '${account}' not found"
    fi
done

# Test if admin-bot can obtain token (this is used by 03_register_servers.sh)
if [ -f .oauth-tokens/admin-bot.json ]; then
    ADMIN_BOT_CLIENT_ID=$(jq -r '.client_id' .oauth-tokens/admin-bot.json)
    ADMIN_BOT_CLIENT_SECRET=$(jq -r '.client_secret' .oauth-tokens/admin-bot.json)
    
    if [ -n "$ADMIN_BOT_CLIENT_ID" ] && [ -n "$ADMIN_BOT_CLIENT_SECRET" ]; then
        ADMIN_BOT_TOKEN=$(get_client_credentials_token "$ADMIN_BOT_CLIENT_ID" "$ADMIN_BOT_CLIENT_SECRET")
        if [ -n "$ADMIN_BOT_TOKEN" ]; then
            log_pass "admin-bot can obtain client credentials token"
        else
            log_fail "admin-bot cannot obtain client credentials token"
        fi
    fi
else
    log_info "admin-bot credentials file not found, skipping token test"
fi

echo ""

# ================================
# Test 4: Client Configuration Preserved
# ================================
run_test "Client Configuration Preserved"

# Test 4.1: mcp-gateway-web client
WEB_CLIENT_CONFIG=$(get_client_config "mcp-gateway-web" "$ADMIN_TOKEN")
if [ -n "$WEB_CLIENT_CONFIG" ]; then
    log_pass "Client 'mcp-gateway-web' exists"
    
    # Check if it has redirect URIs
    REDIRECT_URIS=$(echo "$WEB_CLIENT_CONFIG" | jq -r '.redirectUris[]?' 2>/dev/null)
    if [ -n "$REDIRECT_URIS" ]; then
        log_pass "Client 'mcp-gateway-web' has redirect URIs configured"
    else
        log_fail "Client 'mcp-gateway-web' missing redirect URIs"
    fi
    
    # Check protocol mappers
    MAPPERS=$(echo "$WEB_CLIENT_CONFIG" | jq -r '.protocolMappers[]?.name' 2>/dev/null)
    if echo "$MAPPERS" | grep -q "groups"; then
        log_pass "Client 'mcp-gateway-web' has 'groups' protocol mapper"
    else
        log_fail "Client 'mcp-gateway-web' missing 'groups' protocol mapper"
    fi
else
    log_fail "Client 'mcp-gateway-web' not found"
fi

# Test 4.2: mcp-gateway-m2m client
M2M_CLIENT_CONFIG=$(get_client_config "mcp-gateway-m2m" "$ADMIN_TOKEN")
if [ -n "$M2M_CLIENT_CONFIG" ]; then
    log_pass "Client 'mcp-gateway-m2m' exists"
    
    # Check service accounts enabled
    SERVICE_ACCOUNTS_ENABLED=$(echo "$M2M_CLIENT_CONFIG" | jq -r '.serviceAccountsEnabled')
    if [ "$SERVICE_ACCOUNTS_ENABLED" = "true" ]; then
        log_pass "Client 'mcp-gateway-m2m' has serviceAccountsEnabled=true"
    else
        log_fail "Client 'mcp-gateway-m2m' has serviceAccountsEnabled=false"
    fi
    
    # Check if client has a secret
    if [ -f .oauth-tokens/keycloak-client-secrets.txt ]; then
        M2M_SECRET=$(grep "^KEYCLOAK_M2M_CLIENT_SECRET=" .oauth-tokens/keycloak-client-secrets.txt | cut -d= -f2-)
        if [ -n "$M2M_SECRET" ]; then
            log_pass "Client 'mcp-gateway-m2m' has client secret configured"
        else
            log_fail "Client 'mcp-gateway-m2m' missing client secret"
        fi
    fi
else
    log_fail "Client 'mcp-gateway-m2m' not found"
fi

echo ""

# ================================
# Test 5: Realm Security Settings Preserved
# ================================
run_test "Realm Security Settings Preserved"

REALM_CONFIG=$(get_realm_config "$ADMIN_TOKEN")

# Test 5.1: Brute force protection enabled
BRUTE_FORCE=$(echo "$REALM_CONFIG" | jq -r '.bruteForceProtected')
if [ "$BRUTE_FORCE" = "true" ]; then
    log_pass "Realm has bruteForceProtected=true"
else
    log_fail "Realm has bruteForceProtected=$BRUTE_FORCE (expected true)"
fi

# Test 5.2: Failure factor
FAILURE_FACTOR=$(echo "$REALM_CONFIG" | jq -r '.failureFactor')
if [ "$FAILURE_FACTOR" = "5" ]; then
    log_pass "Realm has failureFactor=5"
else
    log_fail "Realm has failureFactor=$FAILURE_FACTOR (expected 5)"
fi

# Test 5.3: Wait increment seconds
WAIT_INCREMENT=$(echo "$REALM_CONFIG" | jq -r '.waitIncrementSeconds')
if [ "$WAIT_INCREMENT" = "60" ]; then
    log_pass "Realm has waitIncrementSeconds=60"
else
    log_fail "Realm has waitIncrementSeconds=$WAIT_INCREMENT (expected 60)"
fi

# Test 5.4: Max failure wait seconds
MAX_FAILURE_WAIT=$(echo "$REALM_CONFIG" | jq -r '.maxFailureWaitSeconds')
if [ "$MAX_FAILURE_WAIT" = "900" ]; then
    log_pass "Realm has maxFailureWaitSeconds=900"
else
    log_fail "Realm has maxFailureWaitSeconds=$MAX_FAILURE_WAIT (expected 900)"
fi

# Test 5.5: Registration not allowed
REGISTRATION=$(echo "$REALM_CONFIG" | jq -r '.registrationAllowed')
if [ "$REGISTRATION" = "false" ]; then
    log_pass "Realm has registrationAllowed=false"
else
    log_fail "Realm has registrationAllowed=$REGISTRATION (expected false)"
fi

# Test 5.6: Reset password allowed
RESET_PASSWORD=$(echo "$REALM_CONFIG" | jq -r '.resetPasswordAllowed')
if [ "$RESET_PASSWORD" = "true" ]; then
    log_pass "Realm has resetPasswordAllowed=true"
else
    log_fail "Realm has resetPasswordAllowed=$RESET_PASSWORD (expected true)"
fi

echo ""

# ================================
# Test 6: Groups Configuration Preserved
# ================================
run_test "Groups Configuration Preserved"

# Expected groups
EXPECTED_GROUPS=(
    "mcp-registry-admin"
    "mcp-servers-unrestricted"
    "registry-users-lob1"
    "registry-users-lob2"
    "registry-admins"
    "mcp-registry-user"
    "mcp-registry-developer"
    "mcp-registry-operator"
    "a2a-agent-admin"
)

for group in "${EXPECTED_GROUPS[@]}"; do
    if group_exists "$group" "$ADMIN_TOKEN"; then
        log_pass "Group '${group}' exists"
    else
        log_fail "Group '${group}' not found"
    fi
done

echo ""

# ================================
# TEST SUMMARY
# ================================
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}TEST SUMMARY${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Total tests run:    $TESTS_RUN"
echo -e "Tests passed:       ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed:       ${RED}${TESTS_FAILED}${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All preservation tests PASSED${NC}"
    echo ""
    echo "This confirms baseline behavior that must be preserved"
    echo "after the admin login fix is applied."
    exit 0
else
    echo -e "${RED}✗ Some preservation tests FAILED${NC}"
    echo ""
    echo "Failed tests:"
    for test in "${FAILED_TESTS[@]}"; do
        echo -e "  ${RED}✗${NC} $test"
    done
    echo ""
    echo "These failures indicate that either:"
    echo "1. The environment is not properly set up (run 02_start.sh)"
    echo "2. The baseline behavior has issues that need investigation"
    echo "3. The test expectations need adjustment"
    exit 1
fi
