import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/relay_agent.dart';
import '../services/relay_client.dart';
import '../widgets/status_chip.dart';

/// Детали агента: живой вывод терминала, отправка промпта, быстрые клавиши.
///
/// Клиент берёт из Provider — тот же [RelayClient], что и список (один
/// WS-канал на всё), поэтому не закрывает его при выходе.
class AgentPage extends StatefulWidget {
  const AgentPage({super.key, required this.agent});

  /// Снимок агента на момент открытия; статус дальше обновляется по событиям.
  final RelayAgent agent;

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  late final RelayClient _client;
  late RelayAgent _agent;
  late final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  String _output = '';
  bool _loading = true;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _client = context.read<RelayClient>();
    _agent = widget.agent;
    _client.events.listen(_onEvent);
    _refresh();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onEvent(RelayEvent event) {
    if (event.name != 'pane.agent_status_changed') return;
    final data = event.data;
    if (data is Map && data['pane_id'] != _agent.id) return;
    if (!mounted) return;
    setState(() {
      _agent = RelayAgent.fromJson(
        data is Map ? data.cast<String, dynamic>() : const {},
      );
    });
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final output = await _client.output(_agent.id, lines: 500);
      if (!mounted) return;
      setState(() {
        _output = output;
        _loading = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _client.prompt(_agent.id, text);
      _input.clear();
      // после отправки перечитываем вывод: агент начал работать
      await _refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendKeys(List<String> keys) async {
    try {
      await _client.keys(_agent.id, keys);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(_agent.displayAgent, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            StatusChip(status: _agent.status),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
            tooltip: 'Обновить вывод',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildOutput(theme)),
            _buildInputBar(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildOutput(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              TextButton(onPressed: _refresh, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }
    if (_loading && _output.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      children: [
        SelectableText(
          _output.isEmpty ? '(вывод пуст)' : _output,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3),
        ),
      ],
    );
  }

  Widget _buildInputBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Быстрые клавиши: Esc и Ctrl-C — это agent.keys.
              IconButton(
                icon: const Icon(Icons.keyboard_tab, size: 20),
                onPressed: () => _sendKeys(const ['esc']),
                tooltip: 'Esc',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.stop_circle_outlined, size: 20),
                onPressed: () => _sendKeys(const ['ctrl', 'c']),
                tooltip: 'Ctrl-C (прервать)',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  decoration: const InputDecoration(
                    hintText: 'Сообщение агенту…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                onPressed: _sending ? null : _send,
                tooltip: 'Отправить',
              ),
            ],
          ),
        ],
      ),
    );
  }
}