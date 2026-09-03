import 'package:flutter/material.dart';

/// Single source of icons/labels for connection modes. Pages previously
/// repeated their own switch over mode names (and even disagreed on the
/// tailscale icon) — everything here comes from one place.
IconData modeIcon(String mode) => switch (mode) {
      'lan' => Icons.wifi,
      'tailscale' => Icons.vpn_lock,
      'funnel' => Icons.public,
      _ => Icons.link,
    };

String modeLabel(String mode) => switch (mode) {
      'lan' => 'LAN',
      'tailscale' => 'Tailscale',
      'funnel' => 'Funnel',
      _ => mode,
    };
