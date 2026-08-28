import 'package:flutter/material.dart';

/// Палитра статусов агента для списка и деталей.
///
/// Словарь статусов — `idle / working / blocked / done / unknown`
/// (см. docs/01-architecture.md). Неизвестные статусы терпим.
Color statusColor(ThemeData theme, String status) {
  final s = status.toLowerCase();
  if (s == 'done' || s == 'success' || s == 'idle') return Colors.green;
  if (s == 'blocked' || s == 'waiting') return Colors.amber.shade700;
  if (s == 'error' || s == 'failed') return theme.colorScheme.error;
  if (s == 'running' || s == 'working' || s == 'thinking') {
    return Colors.orange;
  }
  return Colors.blueGrey;
}

/// Компактный чип со статусом агента.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: statusColor(theme, status).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        status,
        style: theme.textTheme.labelSmall?.copyWith(
          color: statusColor(theme, status),
        ),
      ),
    );
  }
}
