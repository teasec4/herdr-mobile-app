/// Represents the state of an asynchronous operation
sealed class AsyncValue<T> {
  const AsyncValue();

  bool get isLoading => this is AsyncLoading<T>;
  bool get hasData => this is AsyncData<T>;
  bool get hasError => this is AsyncError<T>;

  T? get dataOrNull => switch (this) {
    AsyncData(data: final d) => d,
    _ => null,
  };

  Object? get errorOrNull => switch (this) {
    AsyncError(error: final e) => e,
    _ => null,
  };
}

class AsyncIdle<T> extends AsyncValue<T> {
  const AsyncIdle();
}

class AsyncLoading<T> extends AsyncValue<T> {
  const AsyncLoading();
}

class AsyncData<T> extends AsyncValue<T> {
  final T data;
  const AsyncData(this.data);
}

class AsyncError<T> extends AsyncValue<T> {
  final Object error;
  final StackTrace? stackTrace;
  const AsyncError(this.error, [this.stackTrace]);
}
