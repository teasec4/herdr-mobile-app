import 'package:flutter/material.dart';

import 'ansi_terminal_parser.dart';

/// Renders terminal output (ANSI SGR colors + `\r` line rewrites) the way a
/// terminal would: `\r` rewinds to the start of the current line and
/// overwrites its cells (so progress bars / spinners don't turn into mush),
/// SGR sequences are turned into styled spans, and every other escape is
/// stripped safely.
///
/// Long lines wrap to the widget width so tail output on a phone stays
/// readable within the screen; the widget scrolls vertically via the
/// optional [controller], so the page can keep a sticky "follow output"
/// scroll.
class AnsiTerminal extends StatefulWidget {
  const AnsiTerminal({
    super.key,
    required this.text,
    this.controller,
    this.style,
    this.backgroundColor = const Color(0xFF1E1E1E),
    this.padding = const EdgeInsets.all(12),
  });

  /// Raw terminal text (may contain ANSI escapes and `\r`).
  final String text;

  /// Vertical scroll controller (owned by the page for sticky scrolling).
  final ScrollController? controller;

  /// Base style for uncolored text. Defaults to a readable dark-terminal look.
  final TextStyle? style;

  /// Terminal backdrop. Defaults to a VS Code style dark gray.
  final Color backgroundColor;

  final EdgeInsetsGeometry padding;

  static const TextStyle defaultStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.3,
    fontFamilyFallback: ['Menlo', 'RobotoMono', 'Courier New', 'monospace'],
    fontFeatures: [FontFeature.tabularFigures()],
    color: Color(0xFFE0E0E0),
  );

  /// Dark-on-light variant used when no explicit style is given and the app
  /// runs in light mode (audit P2.2: the const default is light-on-dark).
  static const TextStyle lightStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.3,
    fontFamilyFallback: ['Menlo', 'RobotoMono', 'Courier New', 'monospace'],
    fontFeatures: [FontFeature.tabularFigures()],
    color: Color(0xFF1F1F1F),
  );

  @override
  State<AnsiTerminal> createState() => _AnsiTerminalState();
}

class _AnsiTerminalState extends State<AnsiTerminal> {
  /// Memoization: the parsed [SelectableText.rich] for the last rendered text.
  /// Live updates re-read the whole tail (~500 lines); while the text is
  /// unchanged (e.g. duplicate/status-only rebuilds) we return the identical
  /// widget instance, so Flutter skips both the ANSI reparse and the relayout.
  String? _cacheText;
  TextStyle? _cacheStyle;
  SelectableText? _cacheSelectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The default style is a const; make the memoization key theme-aware so a
    // light/dark switch re-parses with readable colors instead of reusing the
    // stale light-on-light const (audit P2.2).
    final base = widget.style ??
        (theme.brightness == Brightness.light
            ? AnsiTerminal.lightStyle
            : AnsiTerminal.defaultStyle);
    if (widget.text != _cacheText || base != _cacheStyle) {
      final spans = AnsiTerminalParser(widget.text, baseStyle: base).parse();
      _cacheText = widget.text;
      _cacheStyle = base;
      _cacheSelectable = SelectableText.rich(
        TextSpan(children: spans),
        style: base,
      );
    }
    return Container(
      color: widget.backgroundColor,
      child: SingleChildScrollView(
        controller: widget.controller,
        padding: widget.padding,
        physics: const AlwaysScrollableScrollPhysics(),
        child: _cacheSelectable!,
      ),
    );
  }
}
