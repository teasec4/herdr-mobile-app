# herdrelay

Личный релей для удалённого управления [herdr](https://herdr.dev) (terminal
workspace manager for AI coding agents) с телефона.

Запускаешь агентов на ноуте, уходишь из дома — с телефона смотришь, что делают
агенты, читаешь вывод терминала, шлёшь промпты и клавиши, отвечаешь на
blocked-состояния.

## Стек

| Часть | Технология | Где живёт |
| --- | --- | --- |
| Мобильный клиент | Flutter (iOS/Android) | `app/` |
| Релей на ноуте | Go (модуль `herdrelay`) | `cmd/relay/` |
| Гейтвей (VPS, **опция**) | Go + Docker | `cmd/gateway/`, `deploy/` |
| Интеграция с herdr | плагин `herdr-plugin.toml` | `plugin/` |
| Документация | Markdown | `docs/` |

Транспорт — три режима через один QR-онбординг «навёл — работает»:
**A. LAN** (одна сеть), **B. Tailscale** (tailnet напрямую / публичный Funnel),
**C. Gateway** на VPS (опционально). SSH как транспорт не используется
(подробности в [01-architecture](docs/01-architecture.md)).

## Документация

- [01 — Архитектура](docs/01-architecture.md) — компоненты, три транспорта, протокол.
- [02 — Интеграция с herdr (плагин)](docs/02-herdr-integration.md) — как плагин
  подрубается к herdr: манифест, события, install/link.
- [03 — Релей (Go)](docs/03-relay.md) — связь с herdr socket API, WS-API, авторизация.
- [04 — Гейтвей (VPS + Docker)](docs/04-gateway.md) — слепой релей, деплой на VPS (режим C).
- [05 — Flutter-приложение](docs/05-flutter-app.md) — экраны, пакеты, нотификации.
- [06 — План и открытые вопросы](docs/06-roadmap.md) — фазы, что вне скоупа, ADR.
- [07 — Онбординг «скан QR»](docs/07-onboarding.md) — URL-схема пары, режимы, OSS-флоу.
- [08 — Исполнительный план](docs/08-execution-plan.md) — лупы, контрольные точки, проверки.

## Статус

Планирование. Ведётся дизайн и настройка стека (фаза 0/1), см.
[roadmap](docs/06-roadmap.md).
