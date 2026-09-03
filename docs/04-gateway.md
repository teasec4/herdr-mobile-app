# 04 — Gateway (Go, Docker, VPS)

> **Mode C — optional.** For the personal scenario and for the OSS onboarding
> "scan QR — it works" flow, the gateway is not needed: modes A (LAN) and B1
> (Tailscale, see [01-architecture](01-architecture.md) and
> [07-onboarding](07-onboarding.md)) are enough. The gateway makes sense when
> you need access **without Tailscale at all** (guest phone, FCM push from the
> cloud) and you have your own VPS.

The gateway is a "blind" relay between the phone and the laptop. Both ends make
**outbound** connections, so the laptop needs no open ports at all, and
everything works behind any NAT/firewall. The gateway stores no state: it keeps
the WS channels open and forwards frames between the pairs.

Inspiration: `cmd/herdr-gateway` + `Dockerfile.gateway` from
`0cv/herdr-mobile-relay` (the "blind gateway" model). Our variant — no WebRTC
or ICE, a simple persistent forwarder: terminal traffic is tiny, P2P is not
needed.

## Role and what it does NOT do

- Does not store data (stateless, can be updated without loss).
- Does not encrypt/decrypt content on v1 — frames travel over TLS, the gateway
  is trusted (your own VPS). End-to-end E2E — phase 3 (see roadmap).
- Does not handle push notifications on v1 (FCM/APNs — phase 3).
- Constrains: one token = one "relay ↔ phones" pair.

## Mechanics

```
phone ──wss://gw/ws?token=T&role=phone──┐
                                        ├─► registry(token, phone<->relay)
relay ──wss://gw/ws?token=T&role=relay──┘      │
                                               ▼
                                    форвард кадров в обе стороны
```

- Roles: `relay` (one per token), `phone` (as many as needed).
- On relay connect, the gateway registers a channel under the token; phones
  with the same token link to it.
- Frames are forwarded as-is. Heartbeat from both sides, timeout for dead
  channels.
- Reconnect: if the relay drops off, the gateway keeps the phone channels open
  for a short window and sends `{"type":"event","event":"relay_gone"}`.

## Docker deployment on a VPS

Structure in the repo:

```text
cmd/gateway/           # Go-бинарь
deploy/
  Dockerfile          # multi-stage: build (golang:1.26) -> scratch/distroless
  docker-compose.yml  # гейтвей + caddy (TLS)
  Caddyfile           # gw.<domain> -> gateway:8376, авто-LetsEncrypt
```

```bash
docker compose up -d   # на VPS
```

Example `docker-compose.yml` (v1, no surprises):

```yaml
services:
  gateway:
    build: { context: .., dockerfile: deploy/Dockerfile }
    restart: unless-stopped
    environment:
      - GATEWAY_TOKEN=сгенерировать-при-деплое
    expose: ["8376"]
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["443:443", "80:80"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
volumes:
  caddy_data:
```

- TLS: automatic Let’s Encrypt certificate via Caddy (domain → VPS IP).
  Enough for v1; mTLS/nobody — phase 3.
- The gateway token goes into env at deploy time; we do not commit it to the
  repo.
- Region: choose closer to the home network (see Decision 1 in
  [architecture](01-architecture.md)). If the laptop is often in one city — put
  the VPS there. The JPY region matters if home/the user lives there.

## Verification

```bash
curl https://gw.example.com/healthz   # -> {"ok":true}
```

Integration test without herdr: mini-client `cmd/fake-herdr` (as in 0cv)
or two curl/ws scripts pushing frames back and forth.
