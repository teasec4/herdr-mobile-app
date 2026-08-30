import 'package:flutter/material.dart';

import '../core/service_locator.dart';
import '../models/pair_config.dart';
import '../services/config_store.dart';

/// Picker of saved relay profiles: switch the active device or forget one.
class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.onSwitch,
    required this.onForget,
  });

  /// Switch to another profile; the parent makes it active and reconnects.
  final Future<void> Function(PairConfig config) onSwitch;

  /// Forget a profile by its [PairConfig.profileKey].
  final Future<void> Function(String profileKey) onForget;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  List<PairConfig> _profiles = const [];
  String? _activeKey;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final store = getIt<ConfigStore>();
    final profiles = await store.loadProfiles();
    final active = await store.loadActive();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeKey = active?.profileKey;
    });
  }

  Future<void> _switchTo(PairConfig config) async {
    await widget.onSwitch(config);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _forget(PairConfig config) async {
    await widget.onForget(config.profileKey);
    await _reload();
    if (mounted && _profiles.isEmpty) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Switch device')),
      body: ListView.separated(
        itemCount: _profiles.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final p = _profiles[i];
          final isActive = p.profileKey == _activeKey;
          return ListTile(
            onTap: isActive ? null : () => _switchTo(p),
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                p.displayName.isEmpty
                    ? '?'
                    : p.displayName.characters.first.toUpperCase(),
                style: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(p.displayName),
            subtitle: Text('${p.mode} · ${p.host}:${p.port}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isActive)
                  Icon(Icons.check, color: theme.colorScheme.primary)
                else
                  const SizedBox(width: 24),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Forget',
                  onPressed: () => _forget(p),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}