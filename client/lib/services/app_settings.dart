import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Typed, key-centralized storage over [SharedPreferences].
///
/// All app-level persisted keys and their defaults live here — pages and
/// services never touch raw string keys. Values are cached in memory by
/// SharedPreferences after [SharedPreferences.getInstance], so reads are
/// synchronous (e.g. HomePage restores the selected tab without a flash).
///
/// A [ChangeNotifier]: setters persist and notify, so UI (e.g. the
/// notifications settings page) can react instead of keeping a manual copy.
///
/// Scope (per docs/13-client-settings.md): app-level UI settings + the agent
/// snapshot cache (previously ad-hoc keys in `agent_repository.dart`).
/// Profile/command-history storage keeps its own typed services (ConfigStore,
/// CommandHistoryService) — already key-centralized.
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  final SharedPreferences _prefs;

  // ── Storage keys (single source of truth) ──────────────────────────────

  static const String kHomeTabIndex = 'settings_home_tab_index';
  static const String kTerminalFontSize = 'settings_terminal_font_size';
  static const String kAutoScrollFollow = 'settings_auto_scroll_follow';
  static const String kNotificationsEnabled = 'settings_notifications_enabled';
  static const String kAgentSnapshot = 'last_snapshot';
  static const String kAgentSnapshotAt = 'last_snapshot:ts';
  static const String kUnseenDoneIds = 'attention_unseen_done_ids';

  // ── App-level settings ─────────────────────────────────────────────────

  /// Last selected HomePage tab (0 = Spaces, 1 = Agents, 2 = Run).
  int get homeTabIndex => _prefs.getInt(kHomeTabIndex) ?? 0;

  void setHomeTabIndex(int value) {
    // Fire-and-forget: settings writes are small and infrequent.
    _prefs.setInt(kHomeTabIndex, value);
    notifyListeners();
  }

  static const double kDefaultFontSize = 12;
  static const double kMinFontSize = 9;
  static const double kMaxFontSize = 20;

  /// Terminal font size in points (accessibility control on AgentPage).
  double get terminalFontSize {
    final v = _prefs.getDouble(kTerminalFontSize);
    return (v ?? kDefaultFontSize).clamp(kMinFontSize, kMaxFontSize).toDouble();
  }

  void setTerminalFontSize(double value) {
    _prefs.setDouble(
      kTerminalFontSize,
      value.clamp(kMinFontSize, kMaxFontSize).toDouble(),
    );
    notifyListeners();
  }

  /// Whether AgentPage should follow new output to the bottom.
  bool get autoScrollFollow => _prefs.getBool(kAutoScrollFollow) ?? true;

  void setAutoScrollFollow(bool value) {
    _prefs.setBool(kAutoScrollFollow, value);
    notifyListeners();
  }

  /// Whether local "agent blocked" notifications are shown while the app is
  /// in the background. Defaults to on.
  bool get notificationsEnabled => _prefs.getBool(kNotificationsEnabled) ?? true;

  void setNotificationsEnabled(bool value) {
    _prefs.setBool(kNotificationsEnabled, value);
    notifyListeners();
  }

  // ── Agent snapshot cache (offline fallback) ────────────────────────────

  /// Raw JSON of the last successful agents snapshot, or null when never
  /// cached (see `agent_repository.dart`).
  String? get agentSnapshot => _prefs.getString(kAgentSnapshot);

  void setAgentSnapshot(String json) {
    _prefs.setString(kAgentSnapshot, json);
    notifyListeners();
  }

  /// ISO-8601 timestamp of the last successful snapshot, or null.
  String? get agentSnapshotAt => _prefs.getString(kAgentSnapshotAt);

  void setAgentSnapshotAt(String iso) {
    _prefs.setString(kAgentSnapshotAt, iso);
    notifyListeners();
  }

  // ── Attention: "done — unseen" (finished while away) ─────────────────

  /// Pane ids of agents that finished while the user was not looking at them
  /// (see `controllers/attention_store.dart`). Kept across launches so a
  /// finish that happened before the app was closed is still marked when it
  /// opens again.
  List<String> get unseenDoneIds =>
      _prefs.getStringList(kUnseenDoneIds) ?? const [];

  void setUnseenDoneIds(List<String> ids) {
    _prefs.setStringList(kUnseenDoneIds, ids);
    notifyListeners();
  }
}
