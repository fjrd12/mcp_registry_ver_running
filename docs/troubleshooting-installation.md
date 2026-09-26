# Troubleshooting MCP Gateway Installation

Common problems after a Docker Compose install, and how to check each one.
Commands assume you are in the repository root with `.env` loaded
(`set -a; source .env; set +a`). Add `-f docker-compose.prebuilt.yml` to the
`docker compose` commands if you deployed with `--prebuilt`.

## Admin Login Issues

### Expected behavior: password change on first login

The realm `admin` user is created by `keycloak/setup/init-keycloak.sh` with
`INITIAL_ADMIN_PASSWORD` as a **temporary** password. The first login through
the web UI at http://localhost shows Keycloak's "Update password" page. Set a new
password and you are redirected to the registry dashboard. This is intentional:
the initial password lives in `.env` in plain text.

### Symptom: token request returns "Account is not fully set up"

```json
{"error":"invalid_grant","error_description":"Account is not fully set up"}
```

The admin user still has the `UPDATE_PASSWORD` required action. Log in once
through the web UI and change the password, then retry with the new password.

### Symptom: "Invalid username or password"

**Possible causes and fixes**:
1. **Wrong password**: check `INITIAL_ADMIN_PASSWORD` in `.env`. If you already
   completed the first-login change, use the new password instead.
2. **Password changed in `.env` after the first start**: Keycloak stores users in
   its Postgres volume, so editing `.env` does not change an existing user's
   password. Reset it (see below) or recreate the volumes.
3. **Account temporarily locked**: the realm has brute-force protection
   (5 failures, lockout up to 15 minutes). Wait, or unlock the user in the
   Keycloak admin console (`mcp-gateway` realm, Users, admin).

### Symptom: login page does not load or redirects fail

- **Keycloak still starting**: it can take 2-3 minutes after the containers
  start. Check `curl -s http://localhost:8080/realms/mcp-gateway` returns JSON.
- **Stale browser session**: clear cookies for `localhost` or use a private window.
- **Port conflicts**: ports 80, 443, 8080 and 8888 must be free. Check with
  `sudo ss -ltnp | grep -E ':(80|443|8080|8888)\b'`.
- **`SESSION_COOKIE_SECURE=true` over plain HTTP**: set it to `false` for
  `http://localhost`, then recreate the containers.

### Verifying the admin user

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user "${KEYCLOAK_ADMIN}" --password "${KEYCLOAK_ADMIN_PASSWORD}"

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh get users -r mcp-gateway \
  -q username=admin -q exact=true --fields id,username,enabled,requiredActions
```

`requiredActions` contains `UPDATE_PASSWORD` until the first-login change is done.

### Resetting the admin password

After `config credentials` above:

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh set-password -r mcp-gateway \
  --username admin --new-password 'NewTemporaryPassword' --temporary
```

`--temporary` keeps the first-login change; the admin must choose a new
password on the next login.

## Deployment Issues

### Symptom: `build_and_run.sh` fails with "Failed to prepare host log directory"

The registry, auth-server and mcpgw containers write logs to
`/var/log/containers/ai-registry` on the host, and the script uses `sudo` to
create it. When run without a terminal (for example from another script),
`sudo` cannot ask for a password. Prepare the directory once by hand:

```bash
sudo ./scripts/prepare-log-dirs.sh
```

## Verifying the Installation

```bash
# All services should be "Up" (keycloak, registry, auth-server, nginx, mongodb, ...)
docker compose ps

# Keycloak realm is reachable
curl -s http://localhost:8080/realms/mcp-gateway | jq .realm

# Machine-to-machine client can get a token
curl -s -X POST "http://localhost:8080/realms/mcp-gateway/protocol/openid-connect/token" \
  -d grant_type=client_credentials \
  -d client_id=mcp-gateway-m2m \
  -d "client_secret=${KEYCLOAK_M2M_CLIENT_SECRET}" | jq -r '.access_token | length'
```

A non-zero length means the M2M client works. For the admin user, use the web
UI: API password-grant tokens only work after the first-login password change.
