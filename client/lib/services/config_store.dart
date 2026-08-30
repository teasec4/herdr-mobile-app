import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/pair_config.dart';

/// Tiny async mutex (no package dependency): serializes read-modify-write
/// operations so concurrent `saveProfile` calls cannot lose a profile.
class _Lock {
  Future<void> _tail = Future.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    // Keep the chain going even if the previous action failed.
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// Stores the saved relay profiles in SharedPreferences so the QR does not
/// have to be scanned on every launch.
///
/// A user may pair with several relays (home machine, work machine, ...) and
/// switch between them without re-scanning. Each profile is keyed by
/// [PairConfig.profileKey]; the active one is tracked separately.
class ConfigStore {
  static const String _profilesKey = 'pair_profiles';
  static const String _activeKey = 'active_profile';
  static const String _legacyKey = 'pair_config';

  final _saveLock = _Lock();

  /// Returns all saved profiles, in the order they were added.
  ///
  /// Migrates the legacy single-profile key on first use if the new keys are
  /// absent.
  Future<List<PairConfig>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesKey);
    if (raw == null) {
      return _migrateLegacy(prefs);
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => PairConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupt profiles: drop them rather than crashing the app.
      await prefs.remove(_profilesKey);
      await prefs.remove(_activeKey);
      return [];
    }
  }

  /// One-time migration from the old single `pair_config` key.
  Future<List<PairConfig>> _migrateLegacy(SharedPreferences prefs) async {
    final raw = prefs.getString(_legacyKey);
    if (raw == null) {
      return [];
    }
    PairConfig? config;
    try {
      config = PairConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await prefs.remove(_legacyKey);
      return [];
    }
    await prefs.remove(_legacyKey);
    await prefs.setString(_profilesKey, jsonEncode([config.toJson()]));
    await prefs.setString(_activeKey, config.profileKey);
    return [config];
  }

  /// Returns the active profile, or null when there is none.
  ///
  /// Falls back to the first profile if the stored active key no longer
  /// matches any profile.
  Future<PairConfig?> loadActive() async {
    final profiles = await loadProfiles();
    if (profiles.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final activeKey = prefs.getString(_activeKey);
    for (final p in profiles) {
      if (p.profileKey == activeKey) return p;
    }
    return profiles.first;
  }

  /// Saves (upserts) a profile and makes it active.
  ///
  /// Serialized via [_saveLock]: without it two concurrent deep links (e.g.
  /// parallel Android intents) would read the same profile list, each add its
  /// own profile and the last write would silently drop the other's profile.
  Future<void> saveProfile(PairConfig config) {
    return _saveLock.synchronized(() async {
      final profiles = await loadProfiles();
      final index = profiles.indexWhere((p) => p.profileKey == config.profileKey);
      if (index >= 0) {
        profiles[index] = config;
      } else {
        profiles.add(config);
      }
      await _write(profiles);
      await setActive(config.profileKey);
    });
  }

  /// Marks the profile as active without touching the profile list.
  Future<void> setActive(String profileKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, profileKey);
  }

  /// Removes a profile. If it was active, the first remaining profile becomes
  /// active (call [loadActive] to read the new state).
  Future<void> forget(String profileKey) async {
    final profiles = await loadProfiles();
    profiles.removeWhere((p) => p.profileKey == profileKey);
    await _write(profiles);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_activeKey) == profileKey) {
      await prefs.remove(_activeKey);
    }
  }

  /// Removes everything, including legacy data.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_profilesKey);
    await prefs.remove(_activeKey);
    await prefs.remove(_legacyKey);
  }

  Future<void> _write(List<PairConfig> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _profilesKey,
      jsonEncode([for (final p in profiles) p.toJson()]),
    );
  }
}
