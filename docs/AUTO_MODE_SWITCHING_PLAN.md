# Plan: Automatic mode switching and UX improvements

## Problem

When the user leaves home:
- LAN unreachable → Disconnected
- The user doesn't know what to do
- Must manually switch to Tailscale
- If endpoints aren't saved → dead end

## Goal

1. **Automatic switching** to an available mode
2. **Hints** when the relay is reachable only via LAN
3. **Manual mode visibility** for manual entry
4. **Graceful degradation** when nothing works

---

## Phase 1: Pairing hints (Quick Win)

### 1.1. "LAN only" detector at first pairing

**Where:** `pair_page.dart` after successful pairing

**Logic:**
```dart
Future<void> _connect(String link) async {
  final config = PairConfig.fromLink(link);
  
  // Check how many endpoints are saved
  if (config.endpoints.length == 1 && config.mode == 'lan') {
    _showLANOnlyWarning();
  }
  
  await widget.onPaired(config);
}
```

**UI: Warning bottom sheet**
```
⚠️ Limited connectivity detected

Your relay is only reachable via LAN (local WiFi).

When you leave home, you won't be able to connect unless:
• Install Tailscale on both devices
• Re-scan QR to save Tailscale endpoint

[Learn more] [Continue anyway]
```

**Files to change:**
- `client/lib/pages/pair_page.dart` — add `_showLANOnlyWarning()`
- New file: `client/lib/widgets/lan_only_warning_dialog.dart`

---

### 1.2. "LAN only" badge in Connection Page

**Where:** `connection_page.dart` → Device card

**UI:**
```
Device
┌─────────────────────────────────┐
│ 💻 MacBook Pro    [LAN only] ⚠️│
│ 192.168.1.100:8375              │
└─────────────────────────────────┘
```

**Logic:**
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

**Files to change:**
- `client/lib/pages/connection_page.dart` → `_deviceCard()`

---

## Phase 2: Automatic mode switching (Core)

### 2.1. Fallback mechanism in Transport

**Idea:** When WebSocket can't connect, try the other saved endpoints

**Where:** `client/lib/core/transport/websocket_transport.dart`

**New logic:**

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
        
        // Try the next available endpoint
        final nextMode = _findNextMode();
        if (nextMode != null) {
          _notifyModeSwitching(nextMode);
          _config = _config.connectVia(nextMode, _config.endpointFor(nextMode)!);
          continue; // Retry with a new mode
        }
        
        // All modes tried → normal reconnect
        throw ConnectionException('All endpoints unreachable');
      }
    }
  }
  
  String? _findNextMode() {
    // Priority: tailscale > lan > funnel
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

**Problem:** Transport must not change the config directly!

**Correct architecture:** Introduce a `ConnectionManager` that manages the fallback

---

### 2.2. ConnectionManager with fallback (the right approach)

**New file:** `client/lib/core/connection/connection_fallback_manager.dart`

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
    
    // Listen to transport status
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
    
    // Try another mode in 5 seconds
    _fallbackTimer = Timer(Duration(seconds: 5), () {
      final nextMode = _findNextAvailableMode();
      if (nextMode != null) {
        _switchToMode(nextMode);
      }
    });
  }
  
  String? _findNextAvailableMode() {
    // Switch priority
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
    
    // Save the new active mode
    await configStore.saveProfile(_config);
    await configStore.setActive(_config.profileKey);
    
    // Notify UI
    onModeChanged(oldMode, mode);
    
    print('Auto-switched from $oldMode to $mode');
  }
  
  void dispose() {
    transport.status.removeListener(_onStatusChanged);
    _fallbackTimer?.cancel();
  }
}
```

**Integration into main.dart:**

```dart
class _HerdrMobileAppState extends State<HerdrMobileApp> {
  ConnectionFallbackManager? _fallbackManager;
  
  Future<void> _setConfig(PairConfig config) async {
    await teardownRelayServices();
    setupRelayServices(config, clientFactory: widget.clientFactory);
    
    // Start the fallback manager
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
    // Show toast/snackbar
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Switched from $oldMode to $newMode automatically'),
        duration: Duration(seconds: 3),
      ),
    );
  }
}
```

**Files to create/change:**
- New: `client/lib/core/connection/connection_fallback_manager.dart`
- Change: `client/lib/main.dart` → integrate fallback manager
- Change: `client/lib/core/service_locator.dart` → registration

---

### 2.3. Auto-switch UI indicator

**Where:** Home page — show when a fallback happens

**UI: Banner at the top of the screen**
```
┌──────────────────────────────────────────┐
│ 🔄 Switching to Tailscale...             │
└──────────────────────────────────────────┘
```

After a successful switch:
```
┌──────────────────────────────────────────┐
│ ✅ Connected via Tailscale               │
│    [Dismiss]                             │
└──────────────────────────────────────────┘
```

**Implementation:**
```dart
class HomePage extends StatefulWidget {
  // ...
}

class _HomePageState extends State<HomePage> {
  String? _modeSwitchBanner;
  
  @override
  void initState() {
    super.initState();
    // Listen to events from the fallback manager (via EventBus or Stream)
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

**Files to change:**
- `client/lib/pages/home_page.dart` → add banner

---

## Phase 3: Manual Mode UI improvements (Visibility)

### 3.1. "Manual mode" button always visible

**Now:** Manual mode is hidden inside mode_picker_sheet

**Improvement:** Make it more prominent in the Connection Page

**UI: Add a section in the Connection Page**
```
Connection mode
┌─────────────────────────────────────┐
│ ○ LAN (192.168.1.100)               │
│ ○ Tailscale (not configured)        │
│                                      │
│ [Switch mode manually] →            │
└─────────────────────────────────────┘
```

When "Switch mode manually" is tapped, open:
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

**Files to change:**
- `client/lib/pages/connection_page.dart` → add "Manual mode" button
- `client/lib/widgets/mode_picker_sheet.dart` → may become a separate dialog

---

### 3.2. Improved Manual Mode with validation

**Add live reachability check:**

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
      
      // Try to connect
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

**New files:**
- `client/lib/widgets/manual_mode_dialog.dart`

---

## Phase 4: Smart QR — one QR for all modes

### 4.1. Use Universal QR from the relay

**Now:** The relay generates `universal_qr` (without a mode parameter)

**The client should:**
1. Parse the QR without a mode
2. Make a `GET /pair` request to fetch all modes
3. Save all endpoints at once
4. Show a dialog to pick the primary mode

**Logic in pair_page.dart:**

```dart
Future<void> _connect(String link) async {
  if (_busy) return;
  setState(() => _busy = true);
  
  try {
    final config = PairConfig.fromLink(link);
    
    // If mode is not specified (universal QR) — fetch all modes
    if (!link.contains('mode=')) {
      final modes = await _fetchAllModes(config);
      
      // Show mode selection
      final selectedMode = await _showModeSelectionDialog(modes);
      if (selectedMode == null) {
        setState(() => _busy = false);
        return;
      }
      
      // Enrich config with all endpoints
      final enrichedConfig = config.withEndpoints({
        for (final m in modes) m.mode: RelayEndpoint.fromUrl(m.url),
      }).connectVia(selectedMode.mode, RelayEndpoint.fromUrl(selectedMode.url));
      
      await widget.onPaired(enrichedConfig);
    } else {
      // Regular QR with a specific mode
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
  // Parse and return the list of modes
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

**Files to change:**
- `client/lib/pages/pair_page.dart` → support universal QR
- `client/lib/models/pair_config.dart` → check parsing without mode

---

## Phase 5: Documentation and onboarding

### 5.1. In-app help

**Add a Help screen:**

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

**Files to create:**
- `client/lib/pages/help_page.dart`
- Add an entry to the drawer/menu

---

### 5.2. Update INSTALL.md

Add a "Best Practices" section:

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

## Final implementation checklist

### Phase 1: Quick Wins (1-2 days)
- [x] LAN-only warning at pairing
- [x] "LAN only" badge in Connection page
- [x] Tailscale tip hint

### Phase 2: Auto-switching (3-5 days)
- [x] ConnectionFallbackManager
- [x] Integration into main.dart
- [x] UI banner to indicate a switch
- [x] Tests for the fallback logic

### Phase 3: Manual Mode (2-3 days)
- [x] "Manual mode" button in Connection page
- [x] Separate dialog for manual entry
- [x] Live reachability check
- [x] Improved hints

### Phase 4: Universal QR (2-3 days)
- [x] Support QR without a mode parameter
- [x] Automatic fetch of all modes
- [x] Primary mode selection dialog
- [x] Tests for universal QR

### Phase 5: Documentation (1 day)
- [x] Help page in the app
- [x] Update INSTALL.md
- [x] Update README.md

---

## Prioritization

### Must Have (for the first release):
1. ✅ Phase 1: Hints (critical for UX)
2. ✅ Phase 2: Auto-switching (core feature)
3. ✅ Phase 3.1: Manual mode button (fallback)

### Should Have (v0.2.0):
4. Phase 3.2: Live check in manual mode
5. Phase 4: Universal QR
6. Phase 5: Documentation

### Nice to Have (v0.3.0+):
7. Smart mode prioritization (geolocation?)
8. Mode switch history
9. Network quality indicator

---

## Effort estimate

- **Phase 1**: 1-2 days (simple UI changes)
- **Phase 2**: 3-5 days (core logic + testing)
- **Phase 3**: 2-3 days (UI + validation)
- **Phase 4**: 2-3 days (protocol changes)
- **Phase 5**: 1 day (docs)

**Total: 9-14 days of work**

For the MVP (release v0.2.0): implement Phase 1 + Phase 2 + Phase 3.1 = ~6-8 days
