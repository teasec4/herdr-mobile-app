import 'package:flutter/foundation.dart';

import '../core/connection/mode_service.dart';
import '../models/pair_config.dart';
import '../utils/async_value.dart';

/// Single source of truth for the relay's available connection modes (fetched
/// from /pair). The Connection screen, the mode picker sheet and the pair flow
/// all read from here instead of owning a private list + merge logic — the
/// merge ("switch mode but keep every other advertised endpoint") lives in
/// [switchMode] only, so all callers behave identically.
class ModesController extends ChangeNotifier {
  ModesController(this._fetch);

  /// Fetches the modes for a config; production passes [ModeService.fetch]
  /// (which retries transient failures), tests pass stubs.
  final Future<List<RelayModeInfo>> Function(PairConfig config) _fetch;

  AsyncValue<List<RelayModeInfo>> _state = const AsyncIdle();
  AsyncValue<List<RelayModeInfo>> get state => _state;

  /// Cache keyed by profile+mode: switching between two relays (or two modes
  /// of the same relay) refetches; revisiting the same one serves the cache.
  final Map<String, List<RelayModeInfo>> _cache = {};

  /// In-flight loads keyed the same way — a repeat [load] for the same config
  /// reuses the running future instead of firing a second /pair request.
  final Map<String, Future<void>> _inFlight = {};

  static String _key(PairConfig config) => '${config.profileKey}:${config.mode}';

  /// Loads modes for [config]. Serves the cache when fresh; [force] re-fetches
  /// (used by the manual refresh button).
  Future<void> load(PairConfig config, {bool force = false}) {
    final key = _key(config);
    if (!force) {
      final cached = _cache[key];
      if (cached != null) {
        _state = AsyncData(cached);
        notifyListeners();
        return Future.value();
      }
      final running = _inFlight[key];
      if (running != null) return running;
    }
    final future = _run(key, config, force);
    _inFlight[key] = future;
    return future;
  }

  Future<void> _run(String key, PairConfig config, bool force) async {
    if (force || _state is! AsyncData<List<RelayModeInfo>>) {
      _state = const AsyncLoading();
      notifyListeners();
    }
    try {
      final modes = await _fetch(config);
      _cache[key] = modes;
      _state = AsyncData(modes);
      notifyListeners();
    } catch (e) {
      _state = AsyncError(e);
      notifyListeners();
    } finally {
      _inFlight.remove(key);
    }
  }

  /// Merges every known mode endpoint into [base] and connects via [mode] —
  /// the single merge used by the mode picker sheet, the Connection screen and
  /// the pair flow (switching modes never forgets the other endpoints).
  PairConfig switchMode(PairConfig base, RelayModeInfo mode) {
    return base.withEndpoints({
      for (final m in _state.dataOrNull ?? const <RelayModeInfo>[])
        m.mode: RelayEndpoint.fromUrl(m.url),
    }).connectVia(mode.mode, RelayEndpoint.fromUrl(mode.url));
  }

  @override
  void dispose() {
    _inFlight.clear();
    _cache.clear();
    super.dispose();
  }
}