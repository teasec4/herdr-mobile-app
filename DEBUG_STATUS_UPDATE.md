# Проблема: статус агента не обновляется на главном экране

## Поток событий (как должно работать)

1. **herdr** обнаруживает изменение статуса агента
2. **herdr** вызывает хук → `plugin/on-event.sh`
3. **on-event.sh** отправляет POST на `http://127.0.0.1:8375/api/events/herdr`
4. **relay** получает событие и делает broadcast через WebSocket
5. **Flutter клиент** получает событие через WebSocket
6. **HomePage** слушает события и вызывает `_refresh()` при `pane.agent_status_changed`

## Возможные причины сбоя

### 1. Плагин не вызывается herdr
**Симптомы:** События вообще не доходят до relay  
**Причины:**
- Плагин отключен: `herdr plugin list` показывает disabled
- herdr не распознаёт событие `pane.agent_status_changed` (старая версия herdr < 0.7.5)
- Хук не зарегистрирован правильно в manifest

**Проверка:**
```bash
# Проверить что плагин enabled
herdr plugin list | grep herdrelay

# Проверить версию herdr (нужна >= 0.7.5)
herdr --version

# Посмотреть логи плагина
tail -f ~/.local/state/herdr/logs/plugin_*.log
```

**Диагностика relay:**
```bash
# Добавить логирование в on-event.sh (временно)
echo "Event received: $HERDR_PLUGIN_EVENT_JSON" >> /tmp/herdr-events.log
```

### 2. on-event.sh не может отправить на relay
**Симптомы:** События генерируются, но не доходят до relay  
**Причины:**
- Токен файл не найден: `~/.config/herdr/herdrelay.token` отсутствует
- Relay не запущен (порт 8375 не слушается)
- Неправильный порт (по умолчанию 8375, но может быть переопределён)
- curl не установлен или не работает

**Проверка:**
```bash
# Токен существует?
ls -la ~/.config/herdr/herdrelay.token

# Relay слушает порт?
lsof -nP -iTCP:8375 -sTCP:LISTEN

# Проверить вручную
TOKEN=$(cat ~/.config/herdr/herdrelay.token)
curl -v -X POST "http://127.0.0.1:8375/api/events/herdr" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"data":{"pane_id":"test","agent_status":"blocked"}}'
```

**Фикс:** on-event.sh молча игнорирует ошибки (`|| exit 0` на строке 41), поэтому можно временно убрать это:
```bash
# Изменить строку 36-41 в plugin/on-event.sh на:
curl -v -X POST "http://127.0.0.1:${PORT}/api/events/herdr" \
  -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  -H "Content-Type: application/json" \
  --data-binary "$RAW"
# Это покажет ошибки в логах herdr
```

### 3. Relay не broadcast'ит события
**Симптомы:** События доходят до relay, но не идут в WebSocket  
**Причины:**
- Ошибка парсинга JSON в `handlePluginEvent` (строка 125-138 httpapi.go)
- Hub пустой (нет подключённых клиентов) - нормально, но события теряются
- Ошибка записи в WebSocket (`c.write(b) != nil` на ws.go:89)

**Проверка:**
```bash
# Добавить логирование в cmd/relay/httpapi.go:137
log.Printf("Broadcasting event %s: %s", name, string(ev.Data))

# Пересобрать
./relay-status.sh rebuild

# Посмотреть логи
./relay-status.sh logs
```

### 4. WebSocket отключился на клиенте
**Симптомы:** События broadcast'ятся, но клиент не получает  
**Причины:**
- WebSocket connection dropped (нет реконнекта)
- События приходят, но `_events` stream закрыт
- Listener был удалён (`_client.events.listen(_onEvent)` отписался)

**Проверка в Flutter:**
```dart
// В HomePage._onEvent добавить лог:
void _onEvent(RelayEvent event) {
  print('Event received: ${event.name} - ${event.data}');
  if (event.name == 'pane.agent_status_changed' || event.name == 'pane.updated') {
    _refresh();
  }
}
```

**Типичная проблема:** `StreamController<RelayEvent>` не broadcast, поэтому только один listener работает.

Проверить в `relay_client.dart`:
```dart
// Должно быть:
final StreamController<RelayEvent> _events = StreamController.broadcast();
```

### 5. _refresh() вызывается, но UI не обновляется
**Симптомы:** События приходят, _refresh вызывается, но список не меняется  
**Причины:**
- `setState()` не вызывается внутри `_refresh()` (есть на строке 69-72 home_page.dart - OK)
- Агент не в списке (фильтр отсекает?)
- `RelayAgent.sorted()` возвращает старые данные (кеш?)
- `_client.snapshot()` возвращает устаревшие данные

**Проверка:**
```dart
// В HomePage._refresh добавить лог:
Future<void> _refresh() async {
  setState(() => _error = null);
  try {
    final agents = await _client.snapshot();
    print('Refreshed: ${agents.length} agents');
    for (var a in agents) {
      print('  ${a.id}: ${a.status}');
    }
    if (mounted) {
      setState(() {
        _agents = RelayAgent.sorted(agents);
        _loaded = true;
      });
    }
  } catch (e) {
    print('Refresh error: $e');
    if (mounted) setState(() => _error = '$e');
  }
}
```

### 6. Race condition: событие приходит раньше snapshot
**Симптомы:** Иногда работает, иногда нет  
**Причины:**
- Событие `pane.agent_status_changed` приходит
- `_refresh()` вызывает `snapshot()` по HTTP
- Но herdr ещё не обновил свой internal state
- snapshot возвращает старый статус

**Фикс:** Добавить небольшую задержку перед refresh:
```dart
void _onEvent(RelayEvent event) {
  if (event.name == 'pane.agent_status_changed' || event.name == 'pane.updated') {
    // Дать herdr время обновить state перед snapshot
    Future.delayed(const Duration(milliseconds: 100), _refresh);
  }
}
```

### 7. Событие приходит, но для другого pane_id
**Симптомы:** События приходят, но не для нужного агента  
**Причины:**
- herdr генерирует события для всех panes, включая не-агентские
- Событие есть, но `pane_id` не совпадает с `agent.id`

**Проверка:**
```dart
void _onEvent(RelayEvent event) {
  print('Event: ${event.name}');
  print('Data: ${event.data}');
  if (event.name == 'pane.agent_status_changed' || event.name == 'pane.updated') {
    _refresh();
  }
}
```

## Рекомендации по диагностике

### Уровень 1: Быстрая проверка
```bash
# 1. Relay работает?
./relay-status.sh

# 2. Плагин enabled?
herdr plugin list | grep herdrelay

# 3. Версия herdr поддерживает событие?
herdr --version  # должна быть >= 0.7.5
```

### Уровень 2: Логирование
Добавить логи в критических точках:

1. **on-event.sh** - echo в /tmp/herdr-events.log
2. **httpapi.go:137** - log.Printf перед broadcast
3. **home_page.dart:_onEvent** - print события
4. **home_page.dart:_refresh** - print результатов

### Уровень 3: Мониторинг WebSocket
```bash
# Подключиться к WebSocket и смотреть события
websocat "ws://localhost:8375/ws" \
  -H "Authorization: Bearer $(cat ~/.config/herdr/herdrelay.token)"

# Должны приходить события вида:
# {"type":"event","event":"pane.agent_status_changed","data":{...}}
```

## Наиболее вероятные причины

По убыванию вероятности:

1. **WebSocket отключился** - клиент потерял соединение и не реконнектится
2. **Race condition** - snapshot возвращает старые данные до того как herdr обновился
3. **on-event.sh не может отправить** - токен не найден или relay не работает
4. **События не для того pane** - фильтрация нужна на клиенте

## Предлагаемый фикс

Добавить в HomePage:

```dart
void _onEvent(RelayEvent event) {
  if (!mounted) return;
  
  print('[HomePage] Event: ${event.name}'); // DEBUG
  
  if (event.name == 'pane.agent_status_changed' || event.name == 'pane.updated') {
    // Небольшая задержка чтобы herdr успел обновить state
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _refresh();
    });
  }
}
```

И проверить что StreamController broadcast:
```dart
// В relay_client.dart
final StreamController<RelayEvent> _events = StreamController.broadcast();
```
