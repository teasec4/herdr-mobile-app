import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing command history
class CommandHistoryService {
  static const String _keyPrefix = 'command_history_';
  static const int _maxHistorySize = 100;

  final SharedPreferences _prefs;

  CommandHistoryService(this._prefs);

  /// Load command history for a specific agent
  Future<List<String>> load(String agentId) async {
    return _prefs.getStringList('$_keyPrefix$agentId') ?? [];
  }

  /// Save command history for a specific agent
  Future<void> save(String agentId, List<String> commands) async {
    await _prefs.setStringList('$_keyPrefix$agentId', commands);
  }

  /// Add command to history (avoids duplicates at end)
  Future<void> addCommand(String agentId, String command) async {
    final history = await load(agentId);

    // Avoid duplicate if it's the last command
    if (history.isNotEmpty && history.last == command) {
      return;
    }

    history.add(command);

    // Keep only last N commands
    if (history.length > _maxHistorySize) {
      history.removeRange(0, history.length - _maxHistorySize);
    }

    await save(agentId, history);
  }

  /// Clear history for a specific agent
  Future<void> clear(String agentId) async {
    await _prefs.remove('$_keyPrefix$agentId');
  }

  /// Clear all command histories
  Future<void> clearAll() async {
    final keys = _prefs.getKeys().where((key) => key.startsWith(_keyPrefix));
    for (final key in keys) {
      await _prefs.remove(key);
    }
  }
}
