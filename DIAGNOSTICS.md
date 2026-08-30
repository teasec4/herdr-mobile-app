# Диагностика обновления статуса агента

> ⚠ 30.08: документ описывает отладочную сессию на старой схеме. Сейчас
> плагинный хук удалён — статусы приходят только по socket-подписке релея
> (`events.subscribe`), а debug-`print` из HomePage/AgentPage убраны
> (docs/12-fix-plan.md A1, G1). Пункты ниже про `on-event.sh` и
> `/api/events/herdr` неактуальны.

## Что добавлено

### 1. Логирование на всех уровнях

**Плагин herdr (plugin/on-event.sh):**
- Логирует все входящие события в `/tmp/herdr-relay-events.log`
- Формат: `[2026-08-29 10:30:00] Event: {"data":{...}}`

**Relay сервер (cmd/relay/httpapi.go):**
- Логирует broadcast событий с количеством подключённых клиентов
- Видно в логах relay: `/tmp/herdrelay.log` или `./relay-status.sh logs`

**Flutter клиент (client/lib/services/relay_client.dart):**
- Логирует входящие WebSocket события: `[RelayClient] WS event: pane.agent_status_changed`

**HomePage (client/lib/pages/home_page.dart):**
- Логирует получение событий: `[HomePage] Event received: ...`
- Логирует refresh: `[HomePage] Fetching snapshot...`
- Логирует результаты: `[HomePage] Got N agents: ...`

### 2. Race condition fix

Добавлена задержка 150ms между получением события и вызовом snapshot, чтобы herdr успел обновить свой internal state:

```dart
if (event.name == 'pane.agent_status_changed' || event.name == 'pane.updated') {
  Future.delayed(const Duration(milliseconds: 150), () {
    if (mounted) _refresh();
  });
}
```

## Как использовать диагностику

### Запустить Flutter приложение с логами

```bash
cd client
flutter run 2>&1 | grep -E '\[HomePage\]|\[RelayClient\]'
```

Или просто:
```bash
cd client
flutter run
```

И смотреть консоль на логи с префиксами `[HomePage]` и `[RelayClient]`.

### Проверить логи herdr плагина

```bash
# События от herdr
tail -f /tmp/herdr-relay-events.log

# Должны появляться строки при изменении статуса агента:
# [2026-08-29 10:30:15] Event: {"data":{"pane_id":"wH:p7","agent":"claude","agent_status":"blocked"}}
```

### Проверить логи relay

```bash
# Текущие логи relay
tail -f /tmp/herdrelay.log

# Или через утилиту
./relay-status.sh logs

# Должны быть строки:
# [relay] Broadcasting event pane.agent_status_changed to 1 clients: {...}
```

### Полный flow проверки

1. **Запустить Flutter с логами:**
   ```bash
   cd client && flutter run
   ```

2. **В другом терминале следить за событиями:**
   ```bash
   tail -f /tmp/herdr-relay-events.log
   ```

3. **Изменить статус агента** (например, запустить команду в herdr агенте)

4. **Проверить что произошло:**
   - `/tmp/herdr-relay-events.log` - событие пришло от herdr? ✓
   - `/tmp/herdrelay.log` - relay получил и broadcast'нул? ✓
   - Flutter консоль - `[RelayClient] WS event` - клиент получил? ✓
   - Flutter консоль - `[HomePage] Event received` - HomePage обработал? ✓
   - Flutter консоль - `[HomePage] Fetching snapshot` - запросил обновление? ✓
   - Flutter консоль - `[HomePage] Got N agents` - получил агентов? ✓
   - Flutter консоль - `[HomePage] UI updated` - обновил UI? ✓

## Типичные проблемы

### Событие не приходит в /tmp/herdr-relay-events.log
**Причина:** herdr не вызывает плагин  
**Решение:**
```bash
# Проверить что плагин enabled
herdr plugin list | grep herdrelay

# Проверить версию herdr (нужна >= 0.7.5)
herdr --version

# Посмотреть логи herdr
tail -f ~/.local/state/herdr/logs/plugin_*.log
```

### Событие в логе есть, но relay не broadcast'ит
**Причина (старая схема):** Токен не найден, relay не работает, curl не может отправить.
**Статус:** роут `/api/events/herdr` **удалён** (docs/12 A1) — проверять статусы
надо по socket-подписке релея (лог `herdr socket: connected to ...`), а не через хук:
```bash
# Проверить relay
./relay-status.sh

# Лог сокет-подписки релея (статусы/вывод)
tail -f ~/.local/state/herdrelay/relay.err.log | grep 'herdr socket'
```

### Relay broadcast'ит, но клиент не получает
**Причина:** WebSocket отключён  
**Решение:** Смотреть Flutter консоль на reconnect логи, проверить что `status.value == RelayStatus.connected`

### Клиент получает, но UI не обновляется
**Причина:** Race condition (herdr ещё не обновил state) или setState не вызывается  
**Решение:** Уже исправлено задержкой 150ms, смотреть логи `[HomePage] UI updated`

## После диагностики

Когда проблема найдена и исправлена, можно отключить DEBUG логи:

### Отключить лог событий в плагине
```bash
# В plugin/on-event.sh закомментировать строку:
# echo "[$(date '+%Y-%m-%d %H:%M:%S')] Event: $RAW" >> /tmp/herdr-relay-events.log
```

### Убрать print() из Flutter
Удалить или закомментировать `print()` в:
- `client/lib/services/relay_client.dart` (_onMessage)
- `client/lib/pages/home_page.dart` (_onEvent, _refresh)

### Убрать лог из relay
Удалить или закомментировать `log.Printf` в `cmd/relay/httpapi.go:137`

Но оставить задержку 150ms в _onEvent - она исправляет race condition!

## Чек-лист для проверки

- [ ] Relay запущен (`./relay-status.sh`)
- [ ] Плагин enabled (`herdr plugin list`)
- [ ] herdr >= 0.7.5 (`herdr --version`)
- [ ] События пишутся в `/tmp/herdr-relay-events.log`
- [ ] Relay broadcast'ит события (`tail -f /tmp/herdrelay.log`)
- [ ] Flutter получает события (консоль `[RelayClient]`)
- [ ] HomePage обрабатывает события (консоль `[HomePage]`)
- [ ] UI обновляется после snapshot
