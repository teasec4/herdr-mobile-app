import 'dart:async';

import 'package:client/models/relay_agent.dart';
import 'package:client/services/relay_client.dart';
import 'package:flutter/foundation.dart';

/// Фейк клиента релея для виджет-тестов: без сети, с контролем из теста.
///
/// Отвечает из заранее заданных полей и записывает вызовы (`prompts`,
/// `keysCalls`), чтобы тест мог проверить, что UI действительно ходит в релей.
class FakeRelayClient implements RelayClient {
  @override
  final ValueNotifier<RelayStatus> status =
      ValueNotifier<RelayStatus>(RelayStatus.connected);

  final StreamController<RelayEvent> _events = StreamController.broadcast();

  @override
  Stream<RelayEvent> get events => _events.stream;

  /// Снимок, который вернёт `snapshot()`.
  List<RelayAgent> agents = const [];

  /// Текст, который вернёт `output()` для любого агента.
  String outputText = '';

  /// Если true, `snapshot()` бросает [RelayException].
  bool snapshotError = false;

  /// Записанные вызовы `prompt(target, text)`.
  final List<(String, String)> prompts = [];

  /// Записанные вызовы `keys(target, keys)`.
  final List<(String, List<String>)> keysCalls = [];

  @override
  Future<List<RelayAgent>> snapshot() async {
    if (snapshotError) {
      throw const RelayException('boom', 'ошибка снимка');
    }
    return agents;
  }

  @override
  Future<String> output(String target, {int lines = 200, String format = 'text'}) async {
    return outputText;
  }

  @override
  Future<void> keys(String target, List<String> keys) async {
    keysCalls.add((target, keys));
  }

  @override
  Future<void> prompt(String target, String text) async {
    prompts.add((target, text));
  }

  @override
  Future<bool> healthz() async => true;

  @override
  Future<void> close() async {}

  /// Эмитит событие так, как оно пришло бы по WS.
  void emit(RelayEvent event) => _events.add(event);
}
