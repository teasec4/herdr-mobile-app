import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../repositories/agent_repository.dart';
import '../services/relay_client.dart';
import '../utils/async_value.dart';

/// Agents list state for the HomePage Agents tab (a light per-page ViewModel,
/// plain ChangeNotifier — no state-management framework).
///
/// Owns the orchestration that used to live in _HomePageState:
///   - live status deltas applied in place (no snapshot on status events);
///   - debounced snapshot refresh for pane.updated / unknown panes;
///   - reconnect catch-up (re-read after a disconnect);
///   - pause while a detail route covers the page (RouteAware delegates here);
///   - a generation counter discards stale responses when refreshes overlap.
class AgentsController extends ChangeNotifier {
  AgentsController(this._repository) {
    _repository.status.addListener(_onStatusChanged);
    _eventSub = _repository.events.listen(_onEvent);
  }

  final AgentRepository _repository;
  StreamSubscription<RelayEvent>? _eventSub;
  Timer? _refreshDebounce;
  AsyncValue<List<RelayAgent>> _state = const AsyncIdle();
  int _generation = 0;

  /// True once the connection dropped: on the next connected status the list
  /// is re-read (events during the gap were lost).
  bool _wasDisconnected = false;

  /// True while a detail route (AgentPage/WorkspacePage) covers the page: live
  /// events are ignored; [setPaused]`(false)` runs the catch-up refresh.
  bool _paused = false;

  AsyncValue<List<RelayAgent>> get state => _state;

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
      _state = AsyncData(RelayAgent.sorted(agents));
      notifyListeners();
    } catch (e) {
      if (gen != _generation) return;
      _state = AsyncError(e);
      notifyListeners();
    }
  }

  /// Called by the page's RouteAware callbacks. Unpausing triggers the
  /// catch-up refresh (events while covered were ignored).
  void setPaused(bool paused) {
    _paused = paused;
    if (!paused) refresh();
  }

  void _onStatusChanged() {
    final status = _repository.status.value;
    if (status == RelayStatus.connected) {
      if (_wasDisconnected || _state.hasError) {
        _wasDisconnected = false;
        if (!_paused) refresh();
      }
    } else {
      _wasDisconnected = true;
      // Events received while offline are pointless (the connection is gone);
      // the reconnect catch-up above re-reads the whole list.
      _refreshDebounce?.cancel();
    }
  }

  void _onEvent(RelayEvent event) {
    if (_paused || _wasDisconnected) return;

    if (event is AgentStatusChanged) {
      // The event carries the new status — update the tile in place instead of
      // re-reading the whole snapshot (statuses flip often while agents work).
      _applyStatusDelta(event);
      return;
    }
    if (event is PaneUpdated) {
      // A pane appeared/moved/changed — the list may need a full snapshot.
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
    if (!current.data.any((a) => a.id == event.paneId)) {
      _scheduleRefresh(); // unknown pane — fall back to a snapshot
      return;
    }
    _state = AsyncData(RelayAgent.sorted([
      for (final a in current.data)
        if (a.id == event.paneId)
          a.copyWith(
            status: event.status,
            agent: event.agent.isEmpty ? a.agent : event.agent,
            workspaceId: event.workspaceId ?? a.workspaceId,
          )
        else
          a,
    ]));
    notifyListeners();
  }

  /// Debounces an event burst (e.g. a batch task flipping many agents) into a
  /// single snapshot request.
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), () {
      // Skip while covered by AgentPage/WorkspacePage: unpausing runs the
      // catch-up refresh, so no work is lost — just no hidden snapshot fetch.
      if (!_paused) refresh();
    });
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _eventSub?.cancel();
    _repository.status.removeListener(_onStatusChanged);
    super.dispose();
  }
}
