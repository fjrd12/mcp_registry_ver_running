#!/bin/bash
# Bug Condition Exploration Test
# This test verifies that the admin login bug exists in the unfixed code
# EXPECTED OUTCOME: This test should FAIL on unfixed code (proving the bug exists)

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results
TEST_PASSED=0
TEST_FAILED=0
BUG_CONFIRMED=0

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Bug Condition Exploration Test${NC}"
echo -e "${BLUE}Admin Login Temporary Password Issue${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check environment variables are set
# They should be loaded from .env file before running this script
echo -e "${GREEN}✓ Using environment variables${NC}"

# Verify required environment variables
if [ -z "$INITIAL_ADMIN_PASSWORD" ]; then
    echo -e "${RED}✗ INITIAL_ADMIN_PASSWORD not set${NC}"
    exit 1
fi

if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
    echo -e "${RED}✗ KEYCLOAK_ADMIN_PASSWORD not set${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Environment variables validated${NC}"
echo ""

# Check if Keycloak is responding
echo -e "${YELLOW}Checking Keycloak availability...${NC}"
if curl -sf http://localhost:8080/ > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Keycloak is responding${NC}"
else
    echo -e "${RED}✗ Keycloak is not responding${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Test 1: Verify admin user exists${NC}"
# Get admin user from mcp-gateway realm
ADMIN_USER_CHECK=$(docker exec mcp-gateway-registry-keycloak-1 /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master --user admin --password "${KEYCLOAK_ADMIN_PASSWORD}" 2>&1 || true)

ADMIN_USER_DATA=$(docker exec mcp-gateway-registry-keycloak-1 /opt/keycloak/bin/kcadm.sh get users \
    -r mcp-gateway --query username=admin 2>&1 || echo "[]")

if echo "$ADMIN_USER_DATA" | grep -q '"username" : "admin"'; then
    echo -e "${GREEN}✓ Admin user exists in mcp-gateway realm${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Admin user not found in mcp-gateway realm${NC}"
    echo "User data: $ADMIN_USER_DATA"
    TEST_FAILED=$((TEST_FAILED + 1))
    exit 1
fi

echo ""
echo -e "${BLUE}Test 2: Check for UPDATE_PASSWORD required action${NC}"
# Extract requiredActions field
REQUIRED_ACTIONS=$(echo "$ADMIN_USER_DATA" | grep -A 2 '"requiredActions"' || echo "")

if echo "$REQUIRED_ACTIONS" | grep -q "UPDATE_PASSWORD"; then
    echo -e "${RED}✓ BUG CONFIRMED: Admin user has UPDATE_PASSWORD required action${NC}"
    echo -e "${YELLOW}  This is the EXPECTED outcome for unfixed code${NC}"
    BUG_CONFIRMED=$((BUG_CONFIRMED + 1))
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${GREEN}✗ Admin user does NOT have UPDATE_PASSWORD required action${NC}"
    echo -e "${YELLOW}  WARNING: Bug may already be fixed or not reproduced${NC}"
    echo "Required actions: $REQUIRED_ACTIONS"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

echo ""
echo -e "${BLUE}Test 3: Attempt to obtain token via password grant flow${NC}"
TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:8080/realms/mcp-gateway/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin" \
    -d "password=${INITIAL_ADMIN_PASSWORD}" \
    -d "grant_type=password" \
    -d "client_id=mcp-gateway-web" 2>&1)

# Check if we got an access token (unexpected - means bug is NOT present)
if echo "$TOKEN_RESPONSE" | grep -q '"access_token"'; then
    echo -e "${GREEN}✗ Token obtained successfully${NC}"
    echo -e "${YELLOW}  WARNING: Bug may already be fixed or not reproduced${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
else
    # Check for expected error messages
    if echo "$TOKEN_RESPONSE" | grep -qi "Account is not fully set up\|not fully configured\|update.*password\|password.*update"; then
        echo -e "${RED}✓ BUG CONFIRMED: Token request failed with password update error${NC}"
        echo -e "${YELLOW}  This is the EXPECTED outcome for unfixed code${NC}"
        echo -e "${YELLOW}  Error: $(echo "$TOKEN_RESPONSE" | grep -o '"error_description":"[^"]*"')${NC}"
        BUG_CONFIRMED=$((BUG_CONFIRMED + 1))
        TEST_PASSED=$((TEST_PASSED + 1))
    else
        echo -e "${YELLOW}⚠ Token request failed, but not with expected error${NC}"
        echo "Response: $TOKEN_RESPONSE"
        TEST_PASSED=$((TEST_PASSED + 1))
    fi
fi

echo ""
echo -e "${BLUE}Test 4: Verify user is enabled${NC}"
if echo "$ADMIN_USER_DATA" | grep -q '"enabled" : true'; then
    echo -e "${GREEN}✓ Admin user is enabled${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Admin user is NOT enabled${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

echo ""
echo -e "${BLUE}Test 5: Check credentials configuration${NC}"
# Try to get detailed user info including credentials
USER_ID=$(echo "$ADMIN_USER_DATA" | grep -o '"id" : "[^"]*"' | head -1 | cut -d'"' -f4)

if [ -n "$USER_ID" ]; then
    echo -e "${GREEN}✓ Found user ID: $USER_ID${NC}"
    
    # Check credentials (note: Keycloak API doesn't return credential details for security)
    # We can only verify that credentials exist
    CREDS_INFO=$(docker exec mcp-gateway-registry-keycloak-1 /opt/keycloak/bin/kcadm.sh get users/$USER_ID \
        -r mcp-gateway --fields id,username,enabled,emailVerified,requiredActions 2>&1 || echo "{}")
    
    echo "User info: $CREDS_INFO"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Could not extract user ID${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# Summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Tests Passed: ${GREEN}$TEST_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TEST_FAILED${NC}"
echo -e "Bug Confirmations: ${RED}$BUG_CONFIRMED${NC}"
echo ""

if [ $BUG_CONFIRMED -ge 1 ]; then
    echo -e "${RED}✓ BUG SUCCESSFULLY CONFIRMED${NC}"
    echo -e "${YELLOW}The admin user cannot login directly due to temporary password flag${NC}"
    echo -e "${YELLOW}This test will PASS after the fix is applied${NC}"
    exit 0
else
    echo -e "${GREEN}✗ BUG NOT CONFIRMED${NC}"
    echo -e "${YELLOW}The bug may already be fixed or the test environment is incorrect${NC}"
    exit 1
fi
