import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../repositories/agent_repository.dart';
import '../services/relay_client.dart';
import '../utils/async_value.dart';

/// Single source of truth for agent/workspace status in the app.
///
/// Every consumer (Agents tab, AgentPage, WorkspacePage, SessionController)
/// reads live state from here instead of holding its own copy — status events
/// are applied once, in place, and all listeners see the same current values.
///
/// Owns the orchestration that used to live in AgentsController:
///   - live status deltas applied in place (no snapshot on status events);
///   - debounced snapshot refresh for pane.updated / unknown panes;
///   - reconnect catch-up (re-read after a disconnect);
///   - a generation counter discards stale responses when refreshes overlap.
///
/// Unlike the old per-page controller there is no "paused" state: the store
/// updates globally, so a detail route covering the page does not hide events
/// and returning to the list never shows stale statuses.
class AgentsStore extends ChangeNotifier {
  AgentsStore(this._repository) {
    _repository.status.addListener(_onStatusChanged);
    _eventSub = _repository.events.listen(_onEvent);
  }

  final AgentRepository _repository;
  StreamSubscription<RelayEvent>? _eventSub;
  Timer? _refreshDebounce;
  AsyncValue<List<RelayAgent>> _state = const AsyncIdle();
  int _generation = 0;

  /// pane_id -> agent, rebuilt on every snapshot so lookups (byId / statusOf /
  /// workspaceStatus) never read a stale list.
  final Map<String, RelayAgent> _byId = {};

  /// True once the connection dropped: on the next connected status the list
  /// is re-read (events during the gap were lost).
  bool _wasDisconnected = false;

  /// Bumped on every `pane.updated` event. SessionController listens to this
  /// instead of the raw event stream, so session/workspace UI refreshes derive
  /// from the same single source as the agents tab.
  final ValueNotifier<int> structureRevision = ValueNotifier<int>(0);

  AsyncValue<List<RelayAgent>> get state => _state;

  /// Current agents, sorted for display; empty (not null) while there is no
  /// data yet.
  List<RelayAgent> get all => _state.dataOrNull ?? const [];

  /// Live agent for [id], or null when the snapshot does not know it.
  RelayAgent? byId(String id) => _byId[id];

  /// Live status for [id], or null when unknown.
  String? statusOf(String id) => _byId[id]?.status;

  /// Loads the snapshot once (no-op once a load is in flight or done).
  void ensureLoaded() {
    if (_state is AsyncIdle<List<RelayAgent>>) refresh();
  }

  /// Re-reads the snapshot. Keeps the current list on screen while loading —
  /// the spinner only shows when there is no data yet.
  Future<void> refresh() async {
    final gen = ++_generation;
    if (_state is! AsyncData<List<RelayAgent>>) {
      _state = const AsyncLoading();
      notifyListeners();
    }
    try {
      final agents = await _repository.getAgents();
      if (gen != _generation) return; // superseded by a newer refresh
      _rebuildById(agents);
      _state = AsyncData(RelayAgent.sorted(agents));
      notifyListeners();
    } catch (e) {
      if (gen != _generation) return;
      _state = AsyncError(e);
      notifyListeners();
    }
  }

  /// Aggregates the statuses of [workspaceId]'s agents for a space tile:
  /// blocked > working > done > idle > unknown; `unknown` when the space has
  /// no agents.
  String workspaceStatus(String workspaceId) {
    const rank = {
      'blocked': 0,
      'working': 1,
      'done': 2,
      'idle': 3,
      'unknown': 4,
    };
    String best = 'unknown';
    var bestRank = rank['unknown']! + 1;
    for (final a in _byId.values) {
      if (a.workspaceId != workspaceId) continue;
      final r = rank[a.status.toLowerCase()] ?? rank['unknown']!;
      if (r < bestRank) {
        bestRank = r;
        best = a.status;
      }
    }
    return best;
  }

  void _onStatusChanged() {
    final status = _repository.status.value;
    if (status == RelayStatus.connected) {
      if (_wasDisconnected || _state.hasError) {
        _wasDisconnected = false;
        refresh();
      }
    } else {
      _wasDisconnected = true;
      // Events received while offline are pointless (the connection is gone);
      // the reconnect catch-up above re-reads the whole list.
      _refreshDebounce?.cancel();
    }
  }

  void _onEvent(RelayEvent event) {
    if (_wasDisconnected) return;

    if (event is AgentStatusChanged) {
      // The event carries the new status — update the tile in place instead of
      // re-reading the whole snapshot (statuses flip often while agents work).
      _applyStatusDelta(event);
      return;
    }
    if (event is PaneUpdated) {
      // A pane appeared/moved/changed — the list may need a full snapshot.
      structureRevision.value++;
      _scheduleRefresh();
    }
  }

  /// Applies a status change locally from the event. A full snapshot is only
  /// taken when the pane is not in the current list (unknown to us); pane.updated
  /// covers genuinely new panes.
  void _applyStatusDelta(AgentStatusChanged event) {
    final current = _state;
    if (current is! AsyncData<List<RelayAgent>>) {
      _scheduleRefresh(); // no list yet (loading/error) — fetch it
      return;
    }
    final existing = _byId[event.paneId];
    if (existing == null) {
      _scheduleRefresh(); // unknown pane — fall back to a snapshot
      return;
    }
    final updated = existing.copyWith(
      status: event.status,
      agent: event.agent.isEmpty ? existing.agent : event.agent,
      workspaceId: event.workspaceId ?? existing.workspaceId,
    );
    _byId[event.paneId] = updated;
    _state = AsyncData(RelayAgent.sorted([
      for (final a in current.data)
        if (a.id == event.paneId) updated else a,
    ]));
    notifyListeners();
  }

  /// Debounces an event burst (e.g. a batch task flipping many agents) into a
  /// single snapshot request.
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(
      const Duration(milliseconds: 300),
      () => refresh(),
    );
  }

  void _rebuildById(List<RelayAgent> agents) {
    _byId
      ..clear()
      ..addEntries(agents.map((a) => MapEntry(a.id, a)));
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _eventSub?.cancel();
    _repository.status.removeListener(_onStatusChanged);
    structureRevision.dispose();
    super.dispose();
  }
}
