# План исправления обязательных security и correctness проблем

## Обзор

Исправляем 4 критические проблемы (P1-P2), найденные в ходе Linus аудита:
1. **P1**: Timing attack в token verification
2. **P1**: Race condition в event subscription
3. **P2**: Отсутствие timeout в exec.Command (netdetect)
4. **P2**: Race condition при создании token/identity файлов

## Детали исправлений

### 1. Timing attack в token verification

**Файл:** `cmd/relay/router.go:51-56`

**Проблема:** Используется простое сравнение строк `==` для проверки токена, что позволяет атакующему восстановить токен побайтово через timing attack.

**Решение:**
```go
import "crypto/subtle"

func verifyToken(r *http.Request, token string) bool {
    var candidate string
    if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
        candidate = h[len("Bearer "):]
    } else {
        candidate = r.URL.Query().Get("token")
    }
    return subtle.ConstantTimeCompare([]byte(candidate), []byte(token)) == 1
}
```

**Обоснование:** `crypto/subtle.ConstantTimeCompare` выполняет сравнение за константное время независимо от позиции первого различающегося байта.

**Тесты:** Добавить `TestVerifyTokenConstantTime` — проверить, что неправильные токены отклоняются (функциональность), явная проверка timing невозможна в unit-тесте, но код review покажет использование subtle.

---

### 2. Race condition в event subscription

**Файл:** `cmd/relay/main.go:49-59`

**Проблема:** Горутина вызывает `Subscribe()` после старта. Если `Start()` начнёт генерировать события до вызова `Subscribe()`, они потеряются.

**Текущий код:**
```go
hub := ws.NewHub()

go func() {
    events := eventService.Subscribe()  // ← вызывается внутри горутины
    for event := range events {
        hub.BroadcastEvent(event)
    }
}()

if err := eventService.Start(); err != nil {  // ← Start может начать генерить события раньше Subscribe
```

**Решение:**
```go
hub := ws.NewHub()
events := eventService.Subscribe()  // ← Subscribe ДО запуска горутины и Start

go func() {
    for event := range events {
        hub.BroadcastEvent(event)
    }
}()

if err := eventService.Start(); err != nil {
```

**Обоснование:** `Subscribe()` создаёт канал и добавляет его в список listeners до того, как `Start()` начнёт broadcast. EventService уже имеет sync.RWMutex для защиты listeners, так что это безопасно.

**Тесты:** Добавить `TestEventSubscriptionOrdering` — проверить, что Subscribe() возвращает канал до Start(), и что события не теряются.

---

### 3. Отсутствие timeout в exec.Command

**Файл:** `internal/infrastructure/netdetect/detector.go`

**Проблема:** Все вызовы `exec.Command()` (ipconfig, hostname, tailscale) без timeout. Зависший процесс блокирует HTTP handler навсегда.

**Методы для исправления:**
- `LANIP()` — строки 45, 52
- `Tailscale()` — строка 74
- `TailscaleReachable()` — уже есть 2s timeout в net.DialTimeout, ОК
- `FunnelEnabled()` — строка 113

**Решение:** Добавить `context.WithTimeout(2*time.Second)` для всех exec.Command:

```go
import "context"

func (SystemDetector) LANIP() string {
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()
    
    switch runtime.GOOS {
    case "darwin":
        for _, iface := range []string{"en0", "en1"} {
            out, err := exec.CommandContext(ctx, "ipconfig", "getifaddr", iface).Output()
            if err == nil {
                if ip := strings.TrimSpace(string(out)); ip != "" {
                    return ip
                }
            }
        }
    case "linux":
        out, err := exec.CommandContext(ctx, "hostname", "-I").Output()
        if err == nil {
            for _, ip := range strings.Fields(string(out)) {
                if !strings.Contains(ip, ":") {
                    return ip
                }
            }
        }
    }
    return ""
}
```

Аналогично для `Tailscale()` и `FunnelEnabled()`.

**Обоснование:** 2 секунды — достаточно для выполнения локальной команды, но предотвращает бесконечное зависание.

**Тесты:** Существующие тесты в `server_test.go` используют `stubDetector`, который не вызывает реальные команды. Добавить integration test с реальным SystemDetector — проверить, что методы возвращаются за разумное время (< 3s).

---

### 4. Race condition при создании token/identity файлов

**Файлы:** 
- `cmd/relay/token.go:12-32`
- `cmd/relay/identity.go:17-48`

**Проблема:** Два concurrent relay процесса могут оба прочитать отсутствующий файл и создать разные токены/relay_ids. Последний WriteFile победит, но первый процесс будет работать с неправильным значением.

**Решение:** Использовать `os.OpenFile` с флагом `O_EXCL` — атомарно создаёт файл, возвращает ошибку если файл уже существует.

**Для token.go:**
```go
func loadToken(cfg Config) (string, error) {
    if cfg.Token != "" {
        return cfg.Token, nil
    }
    
    // Try to read existing file
    if b, err := os.ReadFile(cfg.TokenFile); err == nil {
        if t := strings.TrimSpace(string(b)); t != "" {
            return t, nil
        }
    }
    
    // Generate new token
    tok, err := newToken()
    if err != nil {
        return "", err
    }
    
    // Create directory
    dir := filepath.Dir(cfg.TokenFile)
    if err := os.MkdirAll(dir, 0o700); err != nil {
        return "", err
    }
    
    // Atomic create with O_EXCL
    f, err := os.OpenFile(cfg.TokenFile, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
    if err != nil {
        if os.IsExist(err) {
            // Another process won the race, re-read the file
            return loadToken(cfg)
        }
        return "", err
    }
    defer f.Close()
    
    if _, err := f.WriteString(tok + "\n"); err != nil {
        return "", err
    }
    return tok, nil
}
```

**Для identity.go:** Аналогичная логика, но с JSON маршаллингом.

**Обоснование:** 
- `O_EXCL` гарантирует атомарное создание файла на уровне ОС
- Если файл уже существует (другой процесс победил), делаем recursive call для чтения существующего файла
- Рекурсия безопасна: максимум 2 уровня (первый создаёт, второй читает)

**Тесты:** 
- Расширить `TestLoadTokenCreatesFile` — запустить два concurrent loadToken() и проверить, что оба получат одинаковый токен
- Расширить `TestLoadIdentityCreatesFile` — аналогично для identity

---

## Порядок выполнения

1. **Fix timing attack** (task #1) — независимое изменение, простое
2. **Fix event subscription race** (task #2) — независимое изменение, простое
3. **Add timeouts to netdetect** (task #3) — независимое изменение, средняя сложность
4. **Fix token race** (task #4) — средняя сложность
5. **Fix identity race** (task #5) — аналогично #4, можно копировать паттерн
6. **Add tests** (task #6) — после всех исправлений, проверяем correctness

## Проверка

После всех изменений:
1. Запустить существующие тесты: `go test ./cmd/relay -v`
2. Запустить новые тесты для security fixes
3. Проверить, что relay стартует и отвечает на `/pair`
4. Проверить, что WebSocket клиенты получают events

## Риски и компромиссы

**Минимальные изменения:** Все исправления локальны, не меняют публичные API или behaviour (кроме исправления bugs).

**Backwards compatibility:** 
- Token/identity файлы, созданные старой версией, читаются новой версией без проблем
- Новая версия создаёт файлы в том же формате

**Performance:** 
- `subtle.ConstantTimeCompare` добавляет ~microseconds на каждый HTTP request — незаметно
- `context.WithTimeout` для exec.Command не влияет на happy path (команды выполняются быстро)
- O_EXCL в loadToken/loadIdentity вызывается один раз при старте — нет impact

**Concurrency:** Race conditions исправлены, concurrent старт relay процессов теперь безопасен.
