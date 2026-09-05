# Flutter Client Architecture

## State Management

### AsyncValue<T>

Unified state representation for asynchronous operations across the app.

```dart
sealed class AsyncValue<T> {
  const AsyncValue();
}

class AsyncIdle<T> extends AsyncValue<T>     // Initial state
class AsyncLoading<T> extends AsyncValue<T>  // Loading in progress
class AsyncData<T> extends AsyncValue<T>     // Success with data
class AsyncError<T> extends AsyncValue<T>    // Error occurred
```

**Usage:**
- `HomePage`: uses `AsyncValue<List<RelayAgent>>` for agent list state
- Pattern matching with `switch` for clean state handling
- Replaces manual `bool _loading`, `T? _data`, `String? _error` patterns

**Benefits:**
- Type-safe state representation
- Exhaustive pattern matching catches missing cases
- Single source of truth for async operations
- Easy to test and reason about

### Dependency Injection: get_it

Services and controllers are registered in `core/service_locator.dart` and
resolved with `getIt<T>()` (no Provider / `context.read`).

- **`setupDependencies()`** — app-wide singletons that outlive a relay switch:
  `ConfigStore`, `AppSettings` (a `ChangeNotifier`), `CommandHistoryService`,
  `ModeService`, `ModesController`, `NotificationApi`.
- **`setupRelayServices(config)`** — per-connection stack, torn down and
  rebuilt on every config change: `Transport`, `ConnectionManager`,
  `RelayClient`, `AgentRepository`, `AgentsStore`, `SessionController`,
  `NotificationService`.

Pages resolve dependencies in `initState` (or via constructor injection, as
`ModesController` / `PairConfig` do) instead of `context.read`:

```dart
final _store = getIt<AgentsStore>();
```

**Benefits:**
- Single transport/event stream shared across pages (same as the old Provider
  intent, but with explicit lifecycle: `teardownRelayServices()` disposes the
  relay stack on profile switch)
- Controllers (`AgentsStore`, `SessionController`, `ModesController`) are
  `ChangeNotifier`s — UI subscribes with `ListenableBuilder` /
  `AnimatedBuilder` / `ValueListenableBuilder`
- No prop drilling, no disposed-object references: pages are recreated with a
  new `ValueKey` when the active config changes

## Error Handling

### ToastService

Unified toast notifications for errors and messages:

```dart
ToastService.showError(context, error);      // Red toast with error icon
ToastService.showSuccess(context, message);  // Green toast with check icon
ToastService.show(context, message, type: ToastType.warning);
```

**Types:**
- `success` - green, check icon
- `error` - red, error icon
- `warning` - orange, warning icon
- `info` - blue, info icon

**Implementation:**
- Uses `ScaffoldMessenger.showSnackBar`
- Floating behavior with rounded corners
- 3 second default duration
- Icon + message layout
- Automatic error formatting (strips "Exception:" prefix)

### Error Flow

**Before (inconsistent):**
- `HomePage`: stored `_error` in state, showed inline
- `AgentPage`: mixed inline error display + SnackBar
- `PairPage`: stored `_error`, showed below input

**After (unified):**
- All pages use `ToastService.showError()` for transient errors
- `HomePage`: uses `AsyncValue` for loading/error states
- `AgentPage`: shows toast for send/keys errors, keeps terminal visible
- `PairPage`: shows toast for connection errors

**Benefits:**
- Consistent UX across the app
- No stale error state (toasts auto-dismiss)
- Cleaner UI (no error placeholders taking space)
- Better for mobile (toasts don't block content)

## Page States

### HomePage

**State:**
```dart
AsyncValue<List<RelayAgent>> _agentsState
```

**Flow:**
1. `initState`: subscribe to events, call `_refresh()`
2. `_refresh()`: set `AsyncLoading`, fetch snapshot, set `AsyncData` or `AsyncError`
3. `_onEvent()`: on status change event, update the tile locally; a 1 s poll
   (only while an agent is `working`) re-reads output with revision-based
   caching — revision 0 always refetches
4. `build()`: pattern match on `_agentsState` to show loading/error/empty/list

**Race condition fix:**
- 150ms delay between event and snapshot refresh
- Gives herdr time to update internal state before we read it

### AgentPage

**State:**
```dart
String _output
bool _loading
bool _sending
```

**Error handling:**
- `_refresh()` errors: show toast (keeps last good output visible)
- `_send()` errors: show toast
- `_sendKeys()` errors: show toast

**No error state field** - terminal always shows last good output, errors are transient toasts.

### PairPage

**State:**
```dart
bool _busy
```

**Error handling:**
- Connection errors: show toast immediately
- No inline error display (cleaner UI)

## Testing

All 55 tests passing after refactor:
- State transitions work correctly
- Error handling doesn't break existing behavior
- Toast service is mockable in tests (uses `ScaffoldMessenger`)

## Migration Summary

**Added:**
- `lib/utils/async_value.dart` - AsyncValue sealed class
- `lib/utils/toast_service.dart` - ToastService

**Modified:**
- `lib/pages/home_page.dart` - uses AsyncValue, ToastService
- `lib/pages/agent_page.dart` - uses ToastService, removed `_error` field
- `lib/pages/pair_page.dart` - uses ToastService, removed `_error` field

**Benefits:**
- Cleaner code (less state to manage)
- Better UX (consistent error display)
- Type-safe state representation
- Easier to test and maintain
