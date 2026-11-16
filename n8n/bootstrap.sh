#!/bin/sh
# Imports the demo credentials and workflow from code, publishes the workflow, then starts n8n.
# Credentials are rendered from environment variables at boot, so no secret lives in the repo.
set -eu

: "${SYNC_WORKER_PASSWORD:?missing}"
: "${CRM_API_TOKEN:?missing}"

CREDS=/tmp/credentials.json
umask 077
cat > "$CREDS" <<EOF
[
  {
    "id": "pgSyncWorker0001",
    "name": "Postgres (sync_worker)",
    "type": "postgres",
    "data": {
      "host": "db", "port": 5432, "database": "leadflow",
      "user": "sync_worker", "password": "${SYNC_WORKER_PASSWORD}",
      "ssl": "disable", "allowUnauthorizedCerts": false, "sshTunnel": false
    }
  },
  {
    "id": "crmApiToken00001",
    "name": "CRM API token",
    "type": "httpHeaderAuth",
    "data": { "name": "Authorization", "value": "Zoho-oauthtoken ${CRM_API_TOKEN}" }
  }
]
EOF

n8n import:credentials --input="$CREDS"
rm -f "$CREDS"
n8n import:workflow --separate --input=/seed/workflows
n8n publish:workflow --id=crmLeadSync00001

exec n8n start
