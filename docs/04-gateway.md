# 04 — Гейтвей (Go, Docker, VPS)

> **Режим C — опциональный.** Для личного сценария и для OSS-онбординга
> «скан QR — работает» гейтвей не нужен: достаточно режимов A (LAN) и B1
> (Tailscale, см. [01-architecture](01-architecture.md) и
> [07-onboarding](07-onboarding.md)). Гейтвей имеет смысл, когда нужен доступ
> **вообще без Tailscale** (гостевой телефон, FCM-пуш из облака) и есть свой
> VPS.

Гейтвей — это «слепой» релей между телефоном и ноутом. Оба конца звонят
**исходящими** соединениями, поэтому на ноуте не нужно ни одного открытого
портов, а за любым NAT/файрволом всё работает. Гейтвей не хранит состояние:
держит открытые WS-каналы и переправляет кадры между парами.

Вдохновение: `cmd/herdr-gateway` + `Dockerfile.gateway` из
`0cv/herdr-mobile-relay` (модель «blind gateway»). Наш вариант — без WebRTC и
ICE, простой постоянный пересыльщик: трафик терминала крошечный, P2P не нужен.

## Роль и что он НЕ делает

- Не хранит данные (stateless, можно обновлять без потерь).
- Не шифрует/дешифрует содержимое на v1 — кадры идут поверх TLS, гейтвей
  доверенный (свой VPS). Сквозное E2E — фаза 3 (см. roadmap).
- Не занимается push-уведомлениями в v1 (FCM/APNs — фаза 3).
- Ограничивает: один токен = одна пара «релей ↔ телефоны».

## Механика

```
phone ──wss://gw/ws?token=T&role=phone──┐
                                        ├─► registry(token, phone<->relay)
relay ──wss://gw/ws?token=T&role=relay──┘      │
                                               ▼
                                    форвард кадров в обе стороны
```

- Роли: `relay` (один на токен), `phone` (сколько угодно).
- При коннекте релея гейтвей регистрирует канал под токеном; телефоны с тем же
  токеном линкуются к нему.
- Кадры пересылаются as-is. Heartbeat с обеих сторон, таймаут мёртвых каналов.
- Повторного коннекта: если релей отвалился, гейтвей держит телефонные каналы
  короткое окно и шлёт `{"type":"event","event":"relay_gone"}`.

## Docker-деплой на VPS

Структура в репо:

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

Пример `docker-compose.yml` (v1, без сюрпризов):

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

- TLS: автоматический сертификат Let’s Encrypt через Caddy (домен → IP VPS).
  На v1 достаточно; мтls/никто — фаза 3.
- Токен гейтвея кладём в env при деплое, в репо не коммитим.
- Регион: выбирать ближе к домашней сети (см. Решение 1 в
  [architecture](01-architecture.md)). Если ноут часто в одном городе — VPS
  там же. JPY-регион актуален, если там дом/пользователь живёт.

## Проверка

```bash
curl https://gw.example.com/healthz   # -> {"ok":true}
```

Интеграционный тест без herdr: мини-клиент `cmd/fake-herdr` (как у 0cv)
или два curl/ws-скрипта, гоняющие кадры туда-обратно.