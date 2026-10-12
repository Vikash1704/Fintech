#!/usr/bin/env bash
# Idempotent, NON-destructive queue setup via the RabbitMQ management HTTP API.
# Never deletes or recreates a queue. If fraud-high-priority exists without x-max-priority=10 it only warns.
set -euo pipefail
MGMT="${RABBIT_MGMT:-http://localhost:15672}"
USER_NAME="${RABBIT_USER:-guest}"
PASS="${RABBIT_PASS:-guest}"
VHOST="%2F"

ensure_queue() {
  local name="$1" body="$2" check_priority="$3" out code
  out="$(mktemp)"
  code=$(curl -s -o "$out" -w "%{http_code}" -u "$USER_NAME:$PASS" "$MGMT/api/queues/$VHOST/$name")
  if [ "$code" = "200" ]; then
    echo "[exists] $name"
    if [ "$check_priority" = "yes" ] && ! grep -q '"x-max-priority":10' "$out"; then
      echo "  WARNING: $name exists WITHOUT x-max-priority=10. RabbitMQ cannot change queue arguments in place."
      echo "  Message priority 10 will NOT be honoured. See README section 'Queue priority'."
    fi
  elif [ "$code" = "404" ]; then
    code=$(curl -s -o "$out" -w "%{http_code}" -u "$USER_NAME:$PASS" -X PUT \
      -H "content-type: application/json" -d "$body" "$MGMT/api/queues/$VHOST/$name")
    echo "[create] $name -> HTTP $code (201 = created)"
  else
    echo "[error] could not query $name: HTTP $code"; cat "$out"; exit 1
  fi
  rm -f "$out"
}

ensure_queue fraud-high-priority '{"durable":true,"auto_delete":false,"arguments":{"x-max-priority":10}}' yes
ensure_queue fraud-standard      '{"durable":true,"auto_delete":false,"arguments":{}}' no
ensure_queue fraud-dlq           '{"durable":true,"auto_delete":false,"arguments":{}}' no
