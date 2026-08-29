import 'package:flutter/material.dart';

/// Color palette for agent statuses in the list and details.
///
/// Status vocabulary — `idle / working / blocked / done / unknown`
/// (see docs/01-architecture.md). Unknown statuses are tolerated.
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

/// Compact chip with the agent's status.
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
