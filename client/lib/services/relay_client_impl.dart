import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/protocol/relay_exception.dart';
import '../core/protocol/relay_protocol.dart';
import '../core/protocol/request_response_manager.dart';
import '../core/transport/http_health.dart';
import '../core/transport/transport.dart';
import '../core/transport/websocket_transport.dart';
import '../models/pair_config.dart';
import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../models/relay_session.dart';
import 'relay_client.dart';

/// [RelayClient] built on the layered stack (docs/09-refactoring-plan.md §2.3):
///
/// ```
/// RelayClientImpl
///   ├─ RequestResponseManager  — requests/errors/timeouts/ping-pong
///   ├─ Transport.messages      — event frames -> typed RelayEvent
///   ├─ Transport.status        — ConnectionStatus -> RelayStatus
///   ├─ HttpHealth              — healthz()
///   └─ Transport.pause/resume  — pauseReconnect/resumeReconnect
/// ```
///
/// The client owns its [Transport] and [HttpHealth] and closes them in
/// [close]. In tests, pass a [FakeTransport] (test/fakes/) to drive frames
/// without a network.
class RelayClientImpl implements RelayClient {
  /// [transport] and [health] are injectable for tests; by default a
  /// [WebSocketTransport] and a real [HttpHealth] are created and connected.
  /// The timeouts flow into the [RequestResponseManager]
  /// (15 s request / 8 s cold-start connect in production).
  RelayClientImpl(
    this.config, {
    Transport? transport,
    HttpHealth? health,
    Duration requestTimeout = const Duration(seconds: 15),
    Duration connectWait = const Duration(seconds: 8),
  })  : _transport = transport ?? WebSocketTransport(),
        _health = health ?? HttpHealth() {
    _rpc = RequestResponseManager(
      _transport,
      requestTimeout: requestTimeout,
      connectWait: connectWait,
    );
    _events = StreamController<RelayEvent>.broadcast();
    status = ValueNotifier<RelayStatus>(RelayStatus.disconnected);

    _transport.messages.listen(_onRawMessage);
    _transport.status.addListener(_onTransportStatus);
    // Fire-and-forget like the legacy client: the transport reconnects on its
    // own with backoff.
    // ignore: unawaited_futures
    _transport.connect(config.wsUri);
  }

  final PairConfig config;
  final Transport _transport;
  final HttpHealth _health;
  late final RequestResponseManager _rpc;
  late final StreamController<RelayEvent> _events;

  @override
  late final ValueNotifier<RelayStatus> status;

  @override
  Stream<RelayEvent> get events => _events.stream;

  void _onRawMessage(String raw) {
    final Frame frame;
    try {
      frame = Frame.parse(raw);
    } on ProtocolException {
      return; // garbage frame — ignore
    }
    if (frame is EventFrame) {
      _events.add(RelayEvent.fromJson({'name': frame.event, 'data': frame.data}));
    }
  }

  void _onTransportStatus() {
    status.value = switch (_transport.status.value) {
      ConnectionStatus.connected => RelayStatus.connected,
      ConnectionStatus.connecting => RelayStatus.connecting,
      ConnectionStatus.disconnected => RelayStatus.disconnected,
    };
  }

  @override
  Future<List<RelayAgent>> snapshot() async {
    final result = await _rpc.request('agents.snapshot', const {});
    final list = result['agents'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => RelayAgent.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  @override
  Future<RelaySession> session() async {
    final result = await _rpc.request('session.snapshot', const {});
    return RelaySession.fromJson(result);
  }

  @override
  Future<void> sendText(String paneId, String text) async {
    await _rpc.request('pane.send_text', {'pane_id': paneId, 'text': text});
  }

  @override
  Future<void> startAgent(String name, String kind, String paneId) async {
    await _rpc.request('agent.start', {
      'name': name,
      'kind': kind,
      'pane_id': paneId,
    });
  }

  @override
  Future<String> createWorkspace({String? label, String? cwd}) async {
    final result = await _rpc.request('workspace.create', {
      if (label != null && label.isNotEmpty) 'label': label,
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    });
    return (result['workspace_id'] ?? '').toString();
  }

  @override
  Future<String> output(String target, {int lines = 200, String format = 'text'}) async {
    final result = await _rpc.request('agent.output', {
      'target': target,
      'lines': lines,
      'format': format,
    });
    return result['output'] as String? ?? '';
  }

  @override
  Future<void> keys(String target, List<String> keys) async {
    await _rpc.request('agent.keys', {'target': target, 'keys': keys});
  }

  @override
  Future<void> prompt(String target, String text) async {
    await _rpc.request('agent.prompt', {'target': target, 'text': text});
  }

  @override
  Future<bool> healthz() => _health.check(config.healthUri);

  @override
  void pauseReconnect() => _transport.pause();

  @override
  void resumeReconnect() => _transport.resume();

  @override
  Future<void> close() async {
    _rpc.dispose();
    await _transport.close();
    await _events.close();
    _health.close();
    status.value = RelayStatus.disconnected;
  }
}
