# Sablier On-Demand Setup

This setup uses [Sablier](https://sablier.app/) to automatically start Docker containers on first request and stop them when idle. As NPM ist not supported and i did not want to switch my setup, i came up with a workaround. its not as perfect, but it works good enough.

## Components

- **socket-proxy** (`lscr.io/linuxserver/socket-proxy`) – Secure, restricted access to the Docker socket for Sablier
- **sablier** – Starts/stops containers via the Docker provider in `stop` mode. API runs on port `10000`
- **sablier-startportal** (nginx) – Dynamically generates nginx config from environment variables. Starts the corresponding Sablier group before proxying each request to the target

## Files

- `compose.yaml` – Docker Compose definition for all services
- `nginx/generate-conf.sh` – Script that generates the nginx configuration from environment variables
- `html/` – Static files for the start portal

## Configuration

All settings are configured in the `sablier-startportal` service in `compose.yaml`:

| Variable | Description | Default |
| --- | --- | --- |
| `SABLIER_API_URL` | URL to the Sablier blocking API | `http://host.docker.internal:10000` |
| `SABLIER_SESSION_DURATION` | Duration a group stays active after being started | `30m` |
| `SABLIER_ROUTES` | List of routes in `domain:/path:group:target-url` format | see compose.yaml |

### Route format

```text
domain:/path:sablier-group:http://target:port
```

Example from current config:

```text
kino.part0.duckdns.org:/kino:jellyfin:http://192.168.178.128:8096
```

## 1. NPM Proxy Host (required)

You must create a **proxy host in Nginx Proxy Manager (NPM)** that forwards to port **8097** (the start portal port), e.g. `kino.part0.duckdns.org` for Jellyfin. Based on the subdomain (domain part of the route), the start portal determines the correct service and triggers the Sablier API to start it.

## 2. Docker image (required)

Use the **`sablierapp/sablier:next`** image (current state). The `compose.yaml` already pins this image. This is important, as the activity tracking is not yet in main branch. 

## 3. Service labels (required)

Every service managed by Sablier (e.g. `jellyfin`) must be opted into Sablier management and assigned to the correct group via Docker labels. The group name must match the group in the route (e.g. `jellyfin` for `kino.part0.duckdns.org:/kino:jellyfin:IP:PORT`):

```yaml
services:
  jellyfin:
    image: ...
    labels:
      - sablier.enable=true
      - sablier.group=jellyfin
      - sablier.strategy=stop
      - "sablier.activity.enable=true"
      - "sablier.activity.ports=6080"
      - "sablier.activity.session-duration=30m"
```

- `sablier.enable=true` – opts the container into Sablier management
- `sablier.group=<group>` – assigns the container to a Sablier group
- `sablier.strategy=stop` – stops the container instead of pausing it (pause is buggy in the `next` image)
- `sablier.activity.enable=true` – enables activity tracking so user activity extends the session
- `sablier.activity.ports=6080` – ports monitored for activity (adjust to your service's port)
- `sablier.activity.session-duration=30m` – how long the session stays active after the last activity

## Session and activity tracking

A request to a configured domain asks Sablier to start the associated group. Sablier keeps the session active while traffic keeps arriving. After the configured period of inactivity (`SABLIER_SESSION_DURATION`, default `30m`), the session expires and Sablier stops the containers.

With **activity tracking enabled** (`--activity.enabled=true` on the Sablier server — already set in `compose.yaml`), user activity extends the session, so active usage keeps the service running beyond the last network request.

## Important notes

- **Strategy:** Use `--provider.docker.strategy=stop` (containers are stopped, not just paused). The **pause strategy is currently buggy in the `next` image**, so `stop` must be used for now.
- **Jellyfin clients:** Jellyfin clients must be addressed via `kino.part0.duckdns.org` (the proxy host domain), so the start portal can detect the request and trigger the container start. Direct access to the container port will not start the container.
- **Jellyfin startup delay:** The Jellyfin client has a shorter timeout than the container startup time. After triggering the start, wait about **20 seconds** until the service is up before using the client.
- WebSocket support enabled (e.g. for Jellyfin)
- `proxy_buffering` and `proxy_request_buffering` disabled for better streaming
- Long timeouts configured for persistent connections
- The socket-proxy runs on an isolated internal network

## Usage

```bash
docker compose up -d
```

The start portal is available on port `8097`. Visiting any configured domain will automatically trigger Sablier to start the associated group.
