import 'package:client/core/connection/connection_manager.dart';
import 'package:client/core/transport/retry_policy.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fakes/fake_transport.dart';

/// ConnectionManager: app lifecycle is translated into transport
/// pause/resume, and the observer is removed on dispose.
void main() {
  testWidgets('paused/hidden pause the transport; resumed resumes it',
      (tester) async {
    final t = _CountingTransport();
    final manager = ConnectionManager(t, ExponentialBackoff());
    addTearDown(manager.dispose);

    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(t.paused, 1);

    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(t.paused, 2);

    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(t.resumed, 1);
  });

  testWidgets('inactive/detached do not touch the transport', (tester) async {
    final t = _CountingTransport();
    final manager = ConnectionManager(t, ExponentialBackoff());
    addTearDown(manager.dispose);

    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.detached);

    expect(t.paused, 0);
    expect(t.resumed, 0);
  });

  testWidgets('dispose removes the lifecycle observer', (tester) async {
    final t = _CountingTransport();
    final manager = ConnectionManager(t, ExponentialBackoff());

    manager.dispose();
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);

    expect(t.paused, 0, reason: 'observer removed, no pause forwarded');
  });
}

class _CountingTransport extends FakeTransport {
  int paused = 0;
  int resumed = 0;

  @override
  void pause() => paused++;

  @override
  void resume() => resumed++;
}
