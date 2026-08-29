# HerdRelay: Управление и диагностика

## Быстрая проверка статуса

```bash
./relay-status.sh
```

Показывает:
- ✓/✗ Процесс relay запущен (PID, использование CPU/памяти, время сборки бинарника)
- ✓/✗ Порт 8375 слушается
- ✓/✗ API отвечает (количество агентов, их статусы)
- ✓/✗ Плагин herdr установлен и включен
- Токен доступа (первые/последние символы)

## Команды

### Статус (по умолчанию)
```bash
./relay-status.sh status
./relay-status.sh          # то же самое
```

### Перезапуск после изменений

**После изменения Go кода** (cmd/relay/*.go):
```bash
./relay-status.sh rebuild
```
Пересоберёт бинарник, перезапустит relay и покажет статус.

**Просто перезапустить** (без пересборки):
```bash
./relay-status.sh restart
```

**После изменения плагина** (plugin/*.sh, plugin/herdr-plugin.toml):
- Изменения применяются сразу (плагин установлен через `herdr plugin link`)
- Перезапуск не нужен

### Логи
```bash
./relay-status.sh logs
```
Показывает последние 20 строк из `~/Library/Logs/herdrelay.log`

### Токен
```bash
./relay-status.sh token
```
Показывает токен доступа (нужен для подключения Flutter клиента)

### Проверка только API
```bash
./relay-status.sh api
```

## Ручные команды

### Проверить процесс
```bash
ps aux | grep herdrelay | grep -v grep
```

### Проверить порт
```bash
lsof -nP -iTCP:8375 -sTCP:LISTEN
```

### Проверить API напрямую
```bash
curl -H "Authorization: Bearer $(cat ~/.config/herdr/herdrelay.token)" \
  http://localhost:8375/api/snapshot | jq '.'
```

### Проверить плагин herdr
```bash
herdr plugin list | grep -A2 herdrelay
```

### Пересобрать вручную
```bash
bash plugin/install.sh
```

### Перезапустить через launchd (macOS)
```bash
launchctl unload ~/Library/LaunchAgents/com.herdr.relay.plist
launchctl load ~/Library/LaunchAgents/com.herdr.relay.plist
```

### Или убить процесс (автоматически перезапустится)
```bash
pkill herdrelay
```

## Конфигурация

### Порт
Relay работает на порту **8375** (не 8787!)

Настраивается через:
- `HERDRELAY_LISTEN` env переменную
- Или в `cmd/relay/config.go` (по умолчанию `:8375`)

### Токен
Хранится в `~/.config/herdr/herdrelay.token`
- Генерируется автоматически при первом запуске
- 64 символа hex (32 байта random)

### Режимы
```bash
export HERDRELAY_MODE=lan        # по умолчанию (слушает :8375)
export HERDRELAY_MODE=funnel     # 127.0.0.1:8375
export HERDRELAY_MODE=tailscale  # :8375
export HERDRELAY_MODE=gateway    # требует HERDRELAY_GATEWAY_URL
```

## Troubleshooting

### Relay не запускается
1. Проверьте логи: `./relay-status.sh logs`
2. Проверьте, что порт 8375 свободен: `lsof -nP -iTCP:8375`
3. Пересоберите: `./relay-status.sh rebuild`

### API не отвечает
1. Проверьте токен: `cat ~/.config/herdr/herdrelay.token`
2. Проверьте порт: `./relay-status.sh` (должен показать "Слушает порт 8375")
3. Проверьте firewall (если подключаетесь с телефона)

### Плагин не работает
1. Проверьте статус: `herdr plugin list | grep herdrelay`
2. Если не установлен: `herdr plugin link /Users/yg_kovalev/go/herdr_relay/plugin`
3. Если disabled: `herdr plugin enable herdrelay.events`

### Flutter клиент не подключается
1. Убедитесь, что используете правильный порт: **8375**
2. Проверьте токен в клиенте (должен совпадать с `~/.config/herdr/herdrelay.token`)
3. Проверьте, что компьютер и телефон в одной сети
4. Проверьте IP адрес компьютера: `ifconfig | grep "inet " | grep -v 127.0.0.1`

## Workflow после изменений

### Изменили Go код (cmd/relay/\*.go)
```bash
./relay-status.sh rebuild
```

### Изменили плагин (plugin/\*.sh, plugin/\*.toml)
Ничего делать не нужно - изменения применяются сразу.

### Изменили Flutter клиент (client/\*)
```bash
cd client
flutter run
```

### Хотите проверить, что всё работает
```bash
./relay-status.sh
```
Должны быть все галочки зелёные ✓

## Файлы и пути

```
/Users/yg_kovalev/go/herdr_relay/
├── cmd/relay/              # Go код relay сервера
│   ├── main.go
│   ├── server.go
│   ├── httpapi.go
│   └── ...
├── plugin/                 # Плагин для herdr
│   ├── herdr-plugin.toml   # Манифест плагина
│   ├── install.sh          # Сборка и установка
│   ├── on-event.sh         # Обработчик событий
│   ├── setup-menu.sh       # Меню настройки
│   └── bin/herdrelay       # Скомпилированный бинарник
├── client/                 # Flutter клиент
│   └── lib/
├── relay-status.sh         # Этот скрипт
└── RELAY_MANAGEMENT.md     # Эта документация

~/.config/herdr/
├── herdrelay.token         # Токен доступа
├── herdr.sock              # Unix socket herdr
└── plugins/
    └── config/
        └── herdrelay.events/

~/Library/LaunchAgents/
└── com.herdr.relay.plist   # launchd конфиг (macOS)

~/Library/Logs/
└── herdrelay.log           # Логи relay
```
