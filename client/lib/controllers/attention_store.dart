import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/relay_event.dart';
import '../repositories/agent_repository.dart';
import '../services/app_settings.dart';
import 'agents_store.dart';

/// Tracks agents that *finished while the user was not looking at them* — the
/// "done — unseen" attention model (mirrors herdr-web's behavior).
///
/// A finish is a `working → done` / `working → idle` status transition that
/// happens while the pane's chat is NOT open ([view] is only called for the
/// pane the user is actually reading). Such panes stay marked as unseen until
/// they are opened (which clears the mark) or the agent starts working again;
/// the mark survives app restarts via [AppSettings].
///
/// `blocked` is deliberately NOT part of this store: blocked agents already
/// surface through their own notification path and are sorted to the top of
/// the agent list — this store is about the "something finished while I was
/// away" case the user would otherwise miss.
///
/// Statuses come from the live event stream ([AgentRepository.events]); the
/// previous status is tracked here (seeded from [AgentsStore] snapshots) so a
/// transition is recognized even when the app opened while the agent was
/// already working. Marks are pruned (pane gone / agent working again)
/// whenever [AgentsStore] refreshes.
class AttentionStore extends ChangeNotifier {
  AttentionStore(
    this._repository,
    this._store,
    this._settings,
  ) {
    _unseen.addAll(_settings.unseenDoneIds);
    _eventSub = _repository.events.listen((event) {
      if (event is AgentStatusChanged) _onEvent(event);
    });
    _store.addListener(_onStoreChanged);
    _seedFromStore();
  }

  final AgentRepository _repository;
  final AgentsStore _store;
  final AppSettings _settings;
  StreamSubscription<RelayEvent>? _eventSub;

  /// pane_id -> last seen status (from events, seeded from snapshots). Only
  /// filled when unknown: once a pane is tracked by events, a snapshot must
  /// never overwrite the more recent event-derived status.
  final Map<String, String> _prevStatus = {};

  /// Pane ids currently marked "finished while away, not viewed yet".
  final Set<String> _unseen = {};

  /// Pane currently open in a chat (AgentPage); a finish while it is open is
  /// seen by definition and must not be marked.
  String? _viewingPaneId;

  /// Whether [id] is marked "finished while you were away".
  bool isUnseen(String id) => _unseen.contains(id);

  /// Number of unseen panes (drives the AppBar badge).
  int get unseenCount => _unseen.length;

  /// Unseen pane ids, for a "jump to the next unseen agent" action.
  List<String> get unseenPaneIds => List.unmodifiable(_unseen);

  /// The user opened the chat for [paneId]: whatever was unseen there is now
  /// seen, and finishes while it stays open are not marked.
  void view(String paneId) {
    _viewingPaneId = paneId;
    if (_unseen.remove(paneId)) {
      _persist();
      notifyListeners();
    }
  }

  /// The user left the chat for [paneId].
  void closeView(String? paneId) {
    if (_viewingPaneId != paneId) return;
    _viewingPaneId = null;
  }

  void _onEvent(AgentStatusChanged event) {
    final paneId = event.paneId;
    final status = event.status.toLowerCase();
    final prev = _prevStatus[paneId];
    _prevStatus[paneId] = status;

    // No previous status (the pane's earlier state is unknown — e.g. a brand
    // new pane): do not guess a transition.
    if (prev == null) return;

    if (prev == 'working' &&
        (status == 'done' || status == 'idle') &&
        paneId != _viewingPaneId) {
      _unseen.add(paneId);
      _persist();
      notifyListeners();
      return;
    }
    // The agent started working again (or needs input): it is no longer
    // "finished" — an old mark must not linger.
    if ((status == 'working' || status == 'blocked') &&
        _unseen.remove(paneId)) {
      _persist();
      notifyListeners();
    }
  }

  void _onStoreChanged() {
    // A store change can precede our own event handler for the same delta, so
    // seeding only fills *unknown* panes — an already-tracked prev status is
    // never overwritten (otherwise a transition would be missed). Both passes
    // always run (no short-circuit).
    final seeded = _seedFromStore();
    final pruned = _prune();
    if (seeded || pruned) notifyListeners();
  }

  /// Fills [_prevStatus] for panes the store knows but we have never seen an
  /// event for (e.g. the app opened while the agent was already working).
  bool _seedFromStore() {
    var changed = false;
    for (final agent in _store.all) {
      if (!_prevStatus.containsKey(agent.id)) {
        _prevStatus[agent.id] = agent.status;
        changed = true;
      }
    }
    return changed;
  }

  /// Drops marks for panes that are gone or whose agent is working/blocked
  /// again (a fresh start clears the "finished" state).
  bool _prune() {
    final known = <String>{for (final a in _store.all) a.id};
    final statuses = <String, String>{
      for (final a in _store.all) a.id: a.status.toLowerCase(),
    };
    var changed = false;
    _unseen.removeWhere((id) {
      final stale = !known.contains(id) ||
          statuses[id] == 'working' ||
          statuses[id] == 'blocked';
      if (stale) changed = true;
      return stale;
    });
    return changed;
  }

  void _persist() {
    // Fire-and-forget: persistence is best-effort and must not stall anything.
    // ignore: unawaited_futures
    _settings.setUnseenDoneIds(_unseen.toList());
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }
}
