import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/pair_config.dart';

/// Хранит конфигурацию пары в SharedPreferences, чтобы не сканировать QR
/// при каждом запуске.
class ConfigStore {
  static const String _key = 'pair_config';

  /// Возвращает сохранённую пару или null, если её нет (или она битая).
  Future<PairConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      return PairConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(PairConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.toJson()));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}