# План: Автоматическое переключение режимов и улучшение UX

## Проблема

Когда пользователь уходит из дома:
- LAN недоступен → Disconnected
- Пользователь не знает что делать
- Нужно вручную переключиться на Tailscale
- Если endpoints не сохранены → тупик

## Цель

1. **Автоматическое переключение** на доступный режим
2. **Подсказки** когда relay доступен только через LAN
3. **Видимость manual mode** для ручного ввода
4. **Graceful degradation** когда ничего не работает

---

## Фаза 1: Подсказки при паринге (Quick Win)

### 1.1. Детектор "только LAN" при первом паринге

**Где:** `pair_page.dart` после успешного паринга

**Логика:**
```dart
Future<void> _connect(String link) async {
  final config = PairConfig.fromLink(link);
  
  // Проверить сколько endpoints сохранено
  if (config.endpoints.length == 1 && config.mode == 'lan') {
    _showLANOnlyWarning();
  }
  
  await widget.onPaired(config);
}
```

**UI: Bottom sheet с предупреждением**
```
⚠️ Limited connectivity detected

Your relay is only reachable via LAN (local WiFi).

When you leave home, you won't be able to connect unless:
• Install Tailscale on both devices
• Re-scan QR to save Tailscale endpoint

[Learn more] [Continue anyway]
```

**Файлы для изменения:**
- `client/lib/pages/pair_page.dart` — добавить `_showLANOnlyWarning()`
- Новый файл: `client/lib/widgets/lan_only_warning_dialog.dart`

---

### 1.2. Badge "LAN only" в Connection Page

**Где:** `connection_page.dart` → Device card

**UI:**
```
Device
┌─────────────────────────────────┐
│ 💻 MacBook Pro    [LAN only] ⚠️│
│ 192.168.1.100:8375              │
└─────────────────────────────────┘
```

**Логика:**
```dart
Widget _deviceCard(ThemeData theme) {
  final c = widget.config;
  final lanOnly = c.endpoints.length == 1 && c.endpoints.containsKey('lan');
  
  return Card(
    child: Column(
      children: [
        Row(
          children: [
            Text(c.displayName),
            Chip(label: Text(c.mode)),
            if (lanOnly) 
              Tooltip(
                message: 'Only reachable on local WiFi',
                child: Icon(Icons.warning_amber, color: Colors.orange),
              ),
          ],
        ),
        if (lanOnly) _lanOnlyHint(),
      ],
    ),
  );
}

Widget _lanOnlyHint() {
  return Padding(
    padding: EdgeInsets.all(8),
    child: Text(
      '💡 Tip: Enable Tailscale on both devices for remote access',
      style: TextStyle(fontSize: 12, color: Colors.orange),
    ),
  );
}
```

**Файлы для изменения:**
- `client/lib/pages/connection_page.dart` → `_deviceCard()`

---

## Фаза 2: Автоматическое переключение режимов (Core)

### 2.1. Fallback механизм в Transport

**Идея:** Когда WebSocket не может подключиться, попробовать другие сохранённые endpoints

**Где:** `client/lib/core/transport/websocket_transport.dart`

**Новая логика:**

```dart
class WebSocketTransport {
  PairConfig _config;
  List<String> _triedModes = [];
  
  Future<void> connect() async {
    while (true) {
      try {
        await _connectToMode(_config.mode);
        _triedModes.clear();
        return;
      } catch (e) {
        _triedModes.add(_config.mode);
        
        // Попробовать следующий доступный endpoint
        final nextMode = _findNextMode();
        if (nextMode != null) {
          _notifyModeSwitching(nextMode);
          _config = _config.connectVia(nextMode, _config.endpointFor(nextMode)!);
          continue; // Retry с новым режимом
        }
        
        // Все режимы перепробованы → обычный reconnect
        throw ConnectionException('All endpoints unreachable');
      }
    }
  }
  
  String? _findNextMode() {
    // Приоритет: tailscale > lan > funnel
    const priority = ['tailscale', 'lan', 'funnel', 'gateway'];
    
    for (final mode in priority) {
      if (!_triedModes.contains(mode) && _config.endpointFor(mode) != null) {
        return mode;
      }
    }
    return null;
  }
}
```

**Проблема:** Transport не должен менять config напрямую!

**Правильная архитектура:** Ввести `ConnectionManager` который управляет fallback

---

### 2.2. ConnectionManager с fallback (правильный подход)

**Новый файл:** `client/lib/core/connection/connection_fallback_manager.dart`

```dart
/// Manages automatic fallback to alternative endpoints when connection fails
class ConnectionFallbackManager {
  ConnectionFallbackManager({
    required this.transport,
    required this.configStore,
    required this.onModeChanged,
  });
  
  final Transport transport;
  final ConfigStore configStore;
  final Function(String oldMode, String newMode) onModeChanged;
  
  PairConfig _config;
  final Set<String> _failedModes = {};
  Timer? _fallbackTimer;
  
  /// Start monitoring connection and trigger fallback if needed
  void start(PairConfig config) {
    _config = config;
    _failedModes.clear();
    
    // Слушаем статус транспорта
    transport.status.addListener(_onStatusChanged);
  }
  
  void _onStatusChanged() {
    if (transport.status.value == TransportStatus.error) {
      _failedModes.add(_config.mode);
      _scheduleRetry();
    } else if (transport.status.value == TransportStatus.connected) {
      _failedModes.clear();
      _fallbackTimer?.cancel();
    }
  }
  
  void _scheduleRetry() {
    _fallbackTimer?.cancel();
    
    // Попробовать другой режим через 5 секунд
    _fallbackTimer = Timer(Duration(seconds: 5), () {
      final nextMode = _findNextAvailableMode();
      if (nextMode != null) {
        _switchToMode(nextMode);
      }
    });
  }
  
  String? _findNextAvailableMode() {
    // Приоритет переключения
    const priority = ['tailscale', 'lan', 'funnel', 'gateway'];
    
    for (final mode in priority) {
      if (!_failedModes.contains(mode)) {
        final endpoint = _config.endpointFor(mode);
        if (endpoint != null) {
          return mode;
        }
      }
    }
    return null;
  }
  
  Future<void> _switchToMode(String mode) async {
    final endpoint = _config.endpointFor(mode);
    if (endpoint == null) return;
    
    final oldMode = _config.mode;
    _config = _config.connectVia(mode, endpoint);
    
    // Сохранить новый активный режим
    await configStore.saveProfile(_config);
    await configStore.setActive(_config.profileKey);
    
    // Уведомить UI
    onModeChanged(oldMode, mode);
    
    print('Auto-switched from $oldMode to $mode');
  }
  
  void dispose() {
    transport.status.removeListener(_onStatusChanged);
    _fallbackTimer?.cancel();
  }
}
```

**Интеграция в main.dart:**

```dart
class _HerdRelayAppState extends State<HerdRelayApp> {
  ConnectionFallbackManager? _fallbackManager;
  
  Future<void> _setConfig(PairConfig config) async {
    await teardownRelayServices();
    setupRelayServices(config, clientFactory: widget.clientFactory);
    
    // Запустить fallback manager
    _fallbackManager?.dispose();
    _fallbackManager = ConnectionFallbackManager(
      transport: getIt<Transport>(),
      configStore: getIt<ConfigStore>(),
      onModeChanged: _onAutoModeSwitch,
    );
    _fallbackManager!.start(config);
    
    setState(() {
      _config = config;
      _loading = false;
    });
  }
  
  void _onAutoModeSwitch(String oldMode, String newMode) {
    // Показать toast/snackbar
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Switched from $oldMode to $newMode automatically'),
        duration: Duration(seconds: 3),
      ),
    );
  }
}
```

**Файлы для создания/изменения:**
- Новый: `client/lib/core/connection/connection_fallback_manager.dart`
- Изменить: `client/lib/main.dart` → интеграция fallback manager
- Изменить: `client/lib/core/service_locator.dart` → регистрация

---

### 2.3. UI индикатор автопереключения

**Где:** Home page — показывать когда происходит fallback

**UI: Banner сверху экрана**
```
┌──────────────────────────────────────────┐
│ 🔄 Switching to Tailscale...             │
└──────────────────────────────────────────┘
```

После успешного переключения:
```
┌──────────────────────────────────────────┐
│ ✅ Connected via Tailscale               │
│    [Dismiss]                             │
└──────────────────────────────────────────┘
```

**Реализация:**
```dart
class HomePage extends StatefulWidget {
  // ...
}

class _HomePageState extends State<HomePage> {
  String? _modeSwitchBanner;
  
  @override
  void initState() {
    super.initState();
    // Слушать события от fallback manager (через EventBus или Stream)
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          if (_modeSwitchBanner != null) _buildModeSwitchBanner(),
          Expanded(child: _buildAgentList()),
        ],
      ),
    );
  }
  
  Widget _buildModeSwitchBanner() {
    return Material(
      color: Colors.blue,
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.sync, color: Colors.white),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                _modeSwitchBanner!,
                style: TextStyle(color: Colors.white),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, color: Colors.white),
              onPressed: () => setState(() => _modeSwitchBanner = null),
            ),
          ],
        ),
      ),
    );
  }
}
```

**Файлы для изменения:**
- `client/lib/pages/home_page.dart` → добавить banner

---

## Фаза 3: Улучшение Manual Mode UI (Visibility)

### 3.1. Кнопка "Manual mode" всегда видна

**Сейчас:** Manual mode спрятан внутри mode_picker_sheet

**Улучшение:** Сделать его более заметным в Connection Page

**UI: В Connection Page добавить секцию**
```
Connection mode
┌─────────────────────────────────────┐
│ ○ LAN (192.168.1.100)               │
│ ○ Tailscale (not configured)        │
│                                      │
│ [Switch mode manually] →            │
└─────────────────────────────────────┘
```

При нажатии "Switch mode manually" открыть:
```
Manual Connection
┌─────────────────────────────────────┐
│ Mode: [Tailscale ▼]                 │
│ Host: [mac.tailnet.ts.net        ]  │
│ Port: [8375                      ]  │
│                                      │
│ 💡 Use this when automatic mode     │
│    switching doesn't work           │
│                                      │
│         [Connect]                   │
└─────────────────────────────────────┘
```

**Файлы для изменения:**
- `client/lib/pages/connection_page.dart` → добавить "Manual mode" кнопку
- `client/lib/widgets/mode_picker_sheet.dart` → может быть отдельным диалогом

---

### 3.2. Улучшенный Manual Mode с валидацией

**Добавить live-проверку доступности:**

```dart
class ManualModeDialog extends StatefulWidget {
  // ...
}

class _ManualModeDialogState extends State<ManualModeDialog> {
  bool _checking = false;
  bool? _reachable;
  
  Future<void> _checkReachability() async {
    setState(() {
      _checking = true;
      _reachable = null;
    });
    
    try {
      final host = _hostController.text.trim();
      final port = int.tryParse(_portController.text) ?? 8375;
      
      // Попробовать подключиться
      final socket = await Socket.connect(host, port, timeout: Duration(seconds: 3));
      socket.destroy();
      
      setState(() {
        _reachable = true;
        _checking = false;
      });
    } catch (e) {
      setState(() {
        _reachable = false;
        _checking = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Manual Connection'),
      content: Column(
        children: [
          // Mode dropdown
          DropdownButtonFormField<String>(
            value: _manualMode,
            items: [
              DropdownMenuItem(value: 'lan', child: Text('LAN')),
              DropdownMenuItem(value: 'tailscale', child: Text('Tailscale')),
              DropdownMenuItem(value: 'funnel', child: Text('Funnel')),
            ],
            onChanged: (v) => setState(() => _manualMode = v!),
          ),
          
          // Host field
          TextField(
            controller: _hostController,
            decoration: InputDecoration(
              labelText: 'Host',
              hintText: _hostHint,
              suffixIcon: _reachable == null ? null :
                Icon(
                  _reachable! ? Icons.check_circle : Icons.error,
                  color: _reachable! ? Colors.green : Colors.red,
                ),
            ),
            onChanged: (_) => setState(() => _reachable = null),
          ),
          
          // Port field
          TextField(
            controller: _portController,
            decoration: InputDecoration(labelText: 'Port'),
            keyboardType: TextInputType.number,
          ),
          
          SizedBox(height: 16),
          
          // Check button
          TextButton.icon(
            onPressed: _checking ? null : _checkReachability,
            icon: _checking 
              ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(Icons.check),
            label: Text('Test connection'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'),
        ),
        FilledButton(
          onPressed: _connectManual,
          child: Text('Connect'),
        ),
      ],
    );
  }
}
```

**Новые файлы:**
- `client/lib/widgets/manual_mode_dialog.dart`

---

## Фаза 4: Smart QR — один QR для всех режимов

### 4.1. Использовать Universal QR из relay

**Сейчас:** Relay генерирует `universal_qr` (без mode параметра)

**Клиент должен:**
1. Распарсить QR без mode
2. Сделать `GET /pair` чтобы получить все режимы
3. Сохранить все endpoints сразу
4. Показать диалог выбора primary режима

**Логика в pair_page.dart:**

```dart
Future<void> _connect(String link) async {
  if (_busy) return;
  setState(() => _busy = true);
  
  try {
    final config = PairConfig.fromLink(link);
    
    // Если mode не указан (universal QR) — fetch все режимы
    if (!link.contains('mode=')) {
      final modes = await _fetchAllModes(config);
      
      // Показать выбор режима
      final selectedMode = await _showModeSelectionDialog(modes);
      if (selectedMode == null) {
        setState(() => _busy = false);
        return;
      }
      
      // Обогатить config всеми endpoints
      final enrichedConfig = config.withEndpoints({
        for (final m in modes) m.mode: RelayEndpoint.fromUrl(m.url),
      }).connectVia(selectedMode.mode, RelayEndpoint.fromUrl(selectedMode.url));
      
      await widget.onPaired(enrichedConfig);
    } else {
      // Обычный QR с конкретным режимом
      await widget.onPaired(config);
    }
  } catch (e) {
    if (mounted) ToastService.showError(context, e);
  } finally {
    if (mounted) setState(() => _busy = false);
  }
}

Future<List<RelayModeInfo>> _fetchAllModes(PairConfig config) async {
  final uri = config.httpBaseUri
      .replace(path: '/pair')
      .replace(queryParameters: {'token': config.token});
  final res = await http.get(uri).timeout(Duration(seconds: 5));
  // Parse и вернуть список режимов
}

Future<RelayModeInfo?> _showModeSelectionDialog(List<RelayModeInfo> modes) async {
  return showDialog<RelayModeInfo>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Select connection mode'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: modes.map((mode) => 
          ListTile(
            title: Text(mode.mode),
            subtitle: Text(mode.description),
            onTap: () => Navigator.pop(context, mode),
          ),
        ).toList(),
      ),
    ),
  );
}
```

**Файлы для изменения:**
- `client/lib/pages/pair_page.dart` → поддержка universal QR
- `client/lib/models/pair_config.dart` → проверить парсинг без mode

---

## Фаза 5: Документация и онбординг

### 5.1. In-app помощь

**Добавить Help screen:**

```
Help & Troubleshooting

Connection Issues
┌─────────────────────────────────────┐
│ Q: Can't connect when away from home│
│ A: Enable Tailscale on both devices │
│    and re-scan QR code              │
│    [Learn more]                     │
└─────────────────────────────────────┘

Connection Modes
┌─────────────────────────────────────┐
│ LAN - Same WiFi network             │
│ Tailscale - Anywhere with Tailscale │
│ Funnel - Public HTTPS (no Tailscale)│
│ [View detailed guide]               │
└─────────────────────────────────────┘
```

**Файлы для создания:**
- `client/lib/pages/help_page.dart`
- Добавить пункт в drawer/menu

---

### 5.2. Обновить INSTALL.md

Добавить секцию "Best Practices":

```markdown
## Best Practices for Remote Access

### Setup Checklist

✅ **Before first pairing:**
1. Install Tailscale on laptop: `brew install tailscale && sudo tailscale up`
2. Install Tailscale app on phone
3. Restart relay: `bash plugin/redeploy.sh`
4. Scan QR → all modes saved automatically

✅ **Switching networks:**
- At home: LAN (fastest)
- Away: Tailscale (automatic fallback)
- Without Tailscale: Funnel (public HTTPS)

### Troubleshooting

**Problem: "Can't connect when away from home"**

Solution:
1. Open Connection page → "Switch mode manually"
2. Select "Tailscale"
3. Enter your relay hostname (e.g., mac.tailnet.ts.net)
4. Connect

**Problem: "Only LAN mode available"**

This means Tailscale wasn't running during QR generation.

Solution:
1. On laptop: `sudo tailscale up`
2. Restart relay: `bash plugin/redeploy.sh`
3. On phone: Open Connection page → "Refresh modes"
4. Select Tailscale mode
```

---

## Итоговый чеклист реализации

### Phase 1: Quick Wins (1-2 дня)
- [x] LAN-only warning при паринге
- [x] Badge "LAN only" в Connection page
- [x] Hint с советом про Tailscale

### Phase 2: Auto-switching (3-5 дней)
- [x] ConnectionFallbackManager
- [x] Интеграция в main.dart
- [x] UI banner для индикации переключения
- [x] Тесты для fallback логики

### Phase 3: Manual Mode (2-3 дня)
- [x] Кнопка "Manual mode" в Connection page
- [x] Отдельный диалог для ручного ввода
- [x] Live-проверка доступности
- [x] Улучшенные подсказки

### Phase 4: Universal QR (2-3 дня)
- [x] Поддержка QR без mode параметра
- [x] Автоматический fetch всех режимов
- [x] Диалог выбора primary режима
- [x] Тесты для universal QR

### Phase 5: Documentation (1 день)
- [x] Help page в приложении
- [x] Обновить INSTALL.md
- [x] Обновить README.md

---

## Приоритизация

### Must Have (для первого релиза):
1. ✅ Phase 1: Подсказки (критично для UX)
2. ✅ Phase 2: Auto-switching (core feature)
3. ✅ Phase 3.1: Manual mode кнопка (fallback)

### Should Have (v0.2.0):
4. Phase 3.2: Live проверка в manual mode
5. Phase 4: Universal QR
6. Phase 5: Documentation

### Nice to Have (v0.3.0+):
7. Умная приоритизация режимов (геолокация?)
8. History переключений режимов
9. Network quality индикатор

---

## Оценка трудозатрат

- **Phase 1**: 1-2 дня (simple UI changes)
- **Phase 2**: 3-5 дней (core logic + testing)
- **Phase 3**: 2-3 дня (UI + validation)
- **Phase 4**: 2-3 дня (protocol changes)
- **Phase 5**: 1 день (docs)

**Total: 9-14 дней работы**

Для MVP (релиз v0.2.0): реализовать Phase 1 + Phase 2 + Phase 3.1 = ~6-8 дней
