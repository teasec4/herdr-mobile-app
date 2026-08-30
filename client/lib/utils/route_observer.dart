import 'package:flutter/widgets.dart';

/// App-wide [RouteObserver] so pages can track route visibility with
/// [RouteAware] — e.g. HomePage pauses live event handling while AgentPage is
/// pushed on top (docs/12-fix-plan.md M1) and refreshes on return.
///
/// Registered in [main] via `MaterialApp.navigatorObservers`; pages subscribe
/// in `didChangeDependencies` and unsubscribe in `dispose`.
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();
