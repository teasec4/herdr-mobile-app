import 'dart:async';

import 'package:client/core/transport/transport.dart';
import 'package:flutter/foundation.dart';

/// A scriptable [Transport] for fast unit tests: no network.
///
/// The test drives inbound frames with [simulateMessage] (or [simulateError])
/// and inspects what the layer under test sent via [sentMessages]. Status is a
/// plain [ValueNotifier] the test can flip.
class FakeTransport implements Transport {
  final StreamController<String> _messages = StreamController.broadcast();

  @override
  final ValueNotifier<ConnectionStatus> status =
      ValueNotifier<ConnectionStatus>(ConnectionStatus.disconnected);

  @override
  String? lastError;

  /// Frames sent by the layer under test.
  final List<String> sentMessages = [];

  @override
  Stream<String> get messages => _messages.stream;

  @override
  void send(String data) {
    sentMessages.add(data);
  }

  @override
  Future<void> connect(Uri uri) async {
    status.value = ConnectionStatus.connected;
  }

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  Future<void> close() async {
    status.value = ConnectionStatus.disconnected;
    await _messages.close();
  }

  /// Delivers an inbound frame to the consumer.
  void simulateMessage(String json) => _messages.add(json);

  /// Delivers an inbound error to the consumer.
  void simulateError(Object error) => _messages.addError(error);
}
