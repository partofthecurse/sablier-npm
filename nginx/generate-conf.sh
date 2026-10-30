#!/bin/sh
# Sablier-aware reverse proxy for NPM.
# Each configured domain starts its Sablier group before proxying requests.

set -eu

API_URL="${SABLIER_API_URL:-http://host.docker.internal:10000}"
DURATION="${SABLIER_SESSION_DURATION:-30m}"
ROUTES="${SABLIER_ROUTES:-}"

SERVER_BLOCKS=""

if [ -n "$ROUTES" ]; then
    routes_normalized=$(printf '%s' "$ROUTES" | tr '\n' ',')
    routes_space=$(printf '%s' "$routes_normalized" | tr ',' ' ')

    for route in $routes_space; do
        domain="${route%%:*}"
        rest="${route#*:}"

        path="${rest%%:*}"
        rest="${rest#*:}"

        group="${rest%%:*}"
        target="${rest#*:}"

        if [ -z "$domain" ] || [ -z "$path" ] ||
           [ -z "$group" ] || [ -z "$target" ]; then
            echo "Invalid route: $route" >&2
            exit 1
        fi

        # Generate a virtual server for each service domain.
        SERVER_BLOCKS="$SERVER_BLOCKS

server {
    listen 80;
    server_name $domain;

    server_tokens off;

    # Start the Sablier group and wait until it is ready.
    location = /__sablier_start {
        internal;

        proxy_pass ${API_URL}/api/strategies/blocking?group=${group}&session_duration=${DURATION};

        proxy_http_version 1.1;
        proxy_set_header Host \$host;

        proxy_pass_request_body off;
        proxy_set_header Content-Length \"\";

        proxy_connect_timeout 5s;
        proxy_read_timeout 10m;
        proxy_send_timeout 10m;
    }

    # Every request must pass the Sablier readiness check.
    location / {
        auth_request /__sablier_start;

        proxy_pass $target;

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;

        # WebSocket support (Jellyfin uses /socket).
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";

        # Streaming and large uploads.
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_connect_timeout 10s;
    }
}
"
    done
fi

cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 80 default_server;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    add_header Cache-Control "no-store" always;
    server_tokens off;

    location = /health {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        try_files \$uri \$uri/ /index.html =404;
    }
}

$SERVER_BLOCKS
EOF

exec nginx -g 'daemon off;'