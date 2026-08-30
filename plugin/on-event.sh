#!/bin/sh
# REMOVED: the herdr [[events]] hook channel (docs/12-fix-plan.md A1).
#
# Status changes (pane.agent_status_changed) used to arrive twice: once via
# this plugin hook (herdr -> on-event.sh -> POST /api/events/herdr) and once
# via the relay's direct unix-socket subscription. The relay now relies solely
# on the socket subscription (internal/infrastructure/herdr/socket_event_repository.go),
# which also covers live output (pane.scroll_changed); the plugin hook and the
# /api/events/* routes were removed. This file is kept only as a tombstone —
# herdr-plugin.toml no longer registers an [[events]] hook, so herdr never
# invokes it.
exit 0
