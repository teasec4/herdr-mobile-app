# Changelog

All notable changes to HerdRelay project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-29

### Added

#### Flutter Client
- **Home Page**: список всех AI агентов на компьютере с real-time обновлением статусов
- **Agent Page**: интерактивный терминал для взаимодействия с агентом
  - Live вывод агента с ANSI поддержкой (цвета, форматирование)
  - Отправка промптов и команд
  - Ctrl-C для прерывания работы агента
  - Умные интерактивные кнопки (парсят варианты ответа из вывода)
  - История команд с навигацией стрелками
- **Pair Page**: конфигурация подключения к relay (host, port, токен)
- **Status indicators**: визуальные чипы статусов (working, blocked, idle, done)
- **Provider-based DI**: RelayClient через Provider для shared state
- **Comprehensive tests**: 55 тестов покрывают все основные сценарии

#### Go Relay Server
- **WebSocket API**: real-time двусторонняя связь с клиентами
- **HTTP API**: REST endpoints для snapshot, agent output, prompt, keys
- **Event broadcasting**: push-уведомления об изменении статусов агентов
- **herdr integration**: взаимодействие с herdr CLI (agent list, read, prompt, send-keys)
- **Token authentication**: безопасная аутентификация через Bearer токен
- **Multi-client support**: одновременная работа нескольких клиентов

#### herdr Plugin
- **Event forwarding**: автоматическая отправка событий в relay
  - `pane.agent_status_changed` - изменение статуса агента
  - `pane.output_changed` - обновление вывода
  - `pane.updated` - общие изменения в pane
- **Auto-configuration**: автоматическая генерация токена при установке
- **Plugin lifecycle**: setup-menu, on-event hooks

#### Utilities & Documentation
- **relay-status.sh**: утилита управления relay (status, rebuild, restart, logs)
- **Diagnostics tools**: логирование на всех уровнях (plugin → relay → client)
- **Documentation**:
  - `README.md` - общее описание проекта (EN)
  - `RELAY_MANAGEMENT.md` - управление relay сервером
  - `DIAGNOSTICS.md` - диагностика обновления статусов
  - `DEBUG_STATUS_UPDATE.md` - детальная отладка событий
  - `client/TERMINAL_UI.md` - интерактивные кнопки терминала

### Features Details

#### Smart Interactive Buttons
Парсер автоматически распознаёт варианты ответа из вывода агента:
- **Inline опции**: `(y/n)`, `[yes/no]`, `accept/reject`
- **Вопросы**: "Would you like to...?" → Yes/No кнопки
- **Нумерованные списки**: `1. Option` → кнопки с текстом опций
- **Фильтрация**: task lists (◻/◼) не распознаются как варианты

#### Real-time Status Updates
- События от herdr пробрасываются через relay в Flutter
- Задержка 150ms между событием и snapshot (race condition fix)
- Правильная отмена подписок при dispose (no memory leaks)

#### Terminal Features
- ANSI escape codes rendering (цвета, bold, курсив)
- Auto-scroll to bottom (отключается при прокрутке вверх)
- Debounced output updates (не перегружает UI при быстром стриминге)
- Command history с навигацией (↑/↓)

### Fixed
- **Ctrl-C**: исправлен формат отправки (`C-c` вместо `['ctrl', 'c']`)
- **Subscription leaks**: правильная отмена StreamSubscription в dispose
- **Race condition**: задержка 150ms для синхронизации herdr state
- **Parser false positives**: убрана стратегия поиска ключевых слов

### Technical Stack
- **Frontend**: Flutter 3.24.3, Dart 3.5.3
- **Backend**: Go 1.23+
- **Integration**: herdr CLI, tmux, WebSocket
- **Testing**: flutter_test, widget tests, integration tests

### Known Limitations
- Только локальное подключение (localhost или IP в локальной сети)
- Требуется herdr >= 0.7.5
- macOS/Linux (Windows не тестировался)
- Парсер интерактивных кнопок работает только с текстовым выводом

---

## [Unreleased]

### Planned
- Remote API доступ (за пределами локальной сети)
- Поддержка мульти-workspace
- Настройки темы (тёмная/светлая)
- Поиск по выводу агента
- Экспорт истории агента
- Push notifications для критических событий

