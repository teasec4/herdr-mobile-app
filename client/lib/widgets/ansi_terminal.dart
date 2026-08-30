import 'package:flutter/material.dart';

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

/// One cell of the terminal grid: a single character + the style it was
/// drawn with. Cells are overwritten in place on a `\r` rewind.
class _Cell {
  _Cell(this.char, this.style);

  final String char;
  final TextStyle style;
}

/// A terminal line: cells plus the current write column. Writing past
/// [col] appends; a carriage return sets [col] back to 0 so later writes
/// overwrite earlier cells (real terminal semantics).
class _TermLine {
  final List<_Cell> cells = [];
  int col = 0;

  void write(String char, TextStyle style) {
    if (col < cells.length) {
      cells[col] = _Cell(char, style);
    } else {
      cells.add(_Cell(char, style));
    }
    col++;
  }

  void carriageReturn() => col = 0;

  /// EL (erase in line): 0 = to end, 1 = to start, 2 = whole line.
  void erase(int mode) {
    switch (mode) {
      case 0:
        if (col < cells.length) cells.removeRange(col, cells.length);
      case 1:
        if (col > 0 && col <= cells.length) {
          cells.removeRange(0, col);
          col = 0;
        }
      case 2:
        cells.clear();
        col = 0;
    }
  }
}

/// Current SGR (colors / attributes) state while scanning.
class _AnsiState {
  Color? fg;
  Color? bg;
  bool bold = false;
  bool italic = false;
  bool underline = false;
  TextStyle? _cache;

  void reset() {
    fg = null;
    bg = null;
    bold = italic = underline = false;
    _cache = null;
  }

  TextStyle styleFor(TextStyle base) {
    var s = _cache;
    if (s == null) {
      s = base;
      if (bold) s = s.copyWith(fontWeight: FontWeight.bold);
      if (italic) s = s.copyWith(fontStyle: FontStyle.italic);
      if (underline) {
        s = s.copyWith(decoration: TextDecoration.underline, decorationColor: fg);
      }
      if (fg != null) s = s.copyWith(color: fg);
      if (bg != null) s = s.copyWith(backgroundColor: bg);
      _cache = s;
    }
    return s;
  }
}

/// Parsed escape sequence: the SGR parameter list plus the final byte.
class _Escape {
  _Escape(this.params, this.finalByte, this.end);

  /// Parameter strings between `\x1b[` and the final byte (e.g. `38;5;196`).
  final List<String> params;
  final String finalByte;

  /// Index just past the whole sequence (exclusive).
  final int end;

  bool get isSgr => finalByte == 'm';
}

/// Parses raw terminal text into styled [InlineSpan]s.
class AnsiTerminalParser {
  AnsiTerminalParser(this.input, {required this.baseStyle});

  final String input;
  final TextStyle baseStyle;

  static const List<Color> _base = [
    Color(0xFF000000),
    Color(0xFFCD3131),
    Color(0xFF0DBC79),
    Color(0xFFE5E510),
    Color(0xFF2472C8),
    Color(0xFFBC3FBC),
    Color(0xFF11A8CD),
    Color(0xFFE5E5E5),
  ];

  static const List<Color> _bright = [
    Color(0xFF666666),
    Color(0xFFF14C4C),
    Color(0xFF23D18B),
    Color(0xFFF5F543),
    Color(0xFF3B8EEA),
    Color(0xFFD670D6),
    Color(0xFF29B8DB),
    Color(0xFFFFFFFF),
  ];

  List<InlineSpan> parse() {
    final lines = <_TermLine>[_TermLine()];
    final st = _AnsiState();
    var i = 0;
    final n = input.length;
    while (i < n) {
      final ch = input[i];
      if (ch == '\x1b') {
        final esc = _readEscape(input, i);
        i = esc.end;
        if (esc.isSgr) {
          _applySgr(esc.params, st);
        } else {
          _applyOther(esc, lines);
        }
        continue;
      }
      if (ch == '\r') {
        // `\r\n` is a plain newline (handled by the `\n` branch below); a
        // lone `\r` is a line rewind that reuses the same [_TermLine].
        if (i + 1 >= n || input[i + 1] != '\n') {
          lines.last.carriageReturn();
        }
        i++;
        continue;
      }
      if (ch == '\n') {
        lines.add(_TermLine());
        i++;
        continue;
      }
      // Printable char. Tab becomes a run of spaces so column alignment
      // (which tabs are usually there for) survives inside a cell grid.
      if (ch == '\t') {
        final tabs = 8 - (lines.last.col % 8);
        for (var t = 0; t < tabs; t++) {
          lines.last.write(' ', st.styleFor(baseStyle));
        }
      } else {
        lines.last.write(ch, st.styleFor(baseStyle));
      }
      i++;
    }
    return _buildSpans(lines);
  }

  List<InlineSpan> _buildSpans(List<_TermLine> lines) {
    final spans = <InlineSpan>[];
    for (var li = 0; li < lines.length; li++) {
      final cells = lines[li].cells;
      var start = 0;
      while (start < cells.length) {
        final style = cells[start].style;
        var end = start + 1;
        while (end < cells.length && cells[end].style == style) {
          end++;
        }
        final sb = StringBuffer();
        for (var k = start; k < end; k++) {
          sb.write(cells[k].char);
        }
        spans.add(TextSpan(text: sb.toString(), style: style));
        start = end;
      }
      if (li < lines.length - 1) {
        spans.add(const TextSpan(text: '\n'));
      }
    }
    if (spans.isEmpty) {
      spans.add(TextSpan(text: '', style: baseStyle));
    }
    return spans;
  }

  /// Scans one escape sequence starting at [start] (`\x1b[...`). Returns the
  /// parsed params/final byte plus the end index (exclusive).
  _Escape _readEscape(String s, int start) {
    if (start + 1 >= s.length) return _Escape(const [], '', start + 1);
    final c = s[start + 1];
    if (c == '[') {
      var i = start + 2;
      // Private / intermediate markers: `?25h`, `>0c`, `<0`.
      if (i < s.length && '?><='.contains(s[i])) i++;
      final params = <String>[];
      final sb = StringBuffer();
      while (i < s.length) {
        final pc = s[i];
        if (pc.codeUnitAt(0) >= 0x30 && pc.codeUnitAt(0) <= 0x39 ||
            pc == ';' ||
            pc == ':') {
          sb.write(pc);
          i++;
        } else {
          break;
        }
      }
      if (sb.isNotEmpty) {
        params.addAll(sb.toString().split(RegExp('[;:]')));
      }
      var finalByte = '';
      if (i < s.length && _isFinalByte(s[i])) {
        finalByte = s[i];
        i++;
      }
      return _Escape(params, finalByte, i);
    }
    if (c == ']') {
      // OSC (window title, etc.): consume until BEL or ST (`ESC \`).
      var i = start + 2;
      while (i < s.length) {
        if (s[i] == '\x07') return _Escape(const [], '', i + 1);
        if (s[i] == '\x1b' && i + 1 < s.length && s[i + 1] == '\\') {
          return _Escape(const [], '', i + 2);
        }
        i++;
      }
      return _Escape(const [], '', i);
    }
    // Charset select `ESC ( B`, single-char CSI, etc.: consume two bytes.
    return _Escape(const [], '', start + 2);
  }

  static bool _isFinalByte(String c) {
    return (c.codeUnitAt(0) >= 0x40 && c.codeUnitAt(0) <= 0x7E) &&
        !(c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x3F);
  }

  /// Applies an SGR sequence (`\x1b[...m`) to [st].
  void _applySgr(List<String> params, _AnsiState st) {
    var i = 0;
    if (params.isEmpty) {
      st.reset();
      return;
    }
    while (i < params.length) {
      final p = _param(params, i);
      if (p >= 30 && p <= 37) {
        st.fg = _base[p - 30];
      } else if (p >= 90 && p <= 97) {
        st.fg = _bright[p - 90];
      } else if (p >= 40 && p <= 47) {
        st.bg = _base[p - 40];
      } else if (p >= 100 && p <= 107) {
        st.bg = _bright[p - 100];
      } else {
        switch (p) {
          case 0:
            st.reset();
          case 1:
            st.bold = true;
          case 3:
            st.italic = true;
          case 4:
            st.underline = true;
          case 22:
            st.bold = false;
          case 23:
            st.italic = false;
          case 24:
            st.underline = false;
          case 39:
            st.fg = null;
          case 49:
            st.bg = null;
          case 38:
          case 48:
            i = _applyExtended(params, i, st, isBg: p == 48);
        }
      }
      i++;
    }
    st._cache = null;
  }

  /// Handles `38;5;n` / `48;5;n` (256-color) and `38;2;r;g;b` / `48;2;r;g;b`
  /// (truecolor). Returns the index of the last consumed param.
  int _applyExtended(List<String> params, int i, _AnsiState st, {required bool isBg}) {
    if (i + 1 >= params.length) return i;
    final mode = _param(params, i + 1);
    Color? color;
    var consumed = 0;
    if (mode == 5 && i + 2 < params.length) {
      color = _color256(_param(params, i + 2));
      consumed = 2;
    } else if (mode == 2 && i + 4 < params.length) {
      color = Color.fromARGB(
        255,
        _param(params, i + 2).clamp(0, 255),
        _param(params, i + 3).clamp(0, 255),
        _param(params, i + 4).clamp(0, 255),
      );
      consumed = 4;
    }
    if (color != null) {
      if (isBg) {
        st.bg = color;
      } else {
        st.fg = color;
      }
      i += consumed;
    }
    return i;
  }

  static int _param(List<String> params, int i) {
    if (i >= params.length) return 0;
    return int.tryParse(params[i]) ?? 0;
  }

  /// xterm 256-color lookup: 16 base/bright, 6x6x6 cube, 24-step gray ramp.
  Color _color256(int n) {
    if (n < 16) return n < 8 ? _base[n] : _bright[n - 8];
    if (n < 232) {
      final v = n - 16;
      final r = v ~/ 36, g = (v ~/ 6) % 6, b = v % 6;
      int level(int c) => c == 0 ? 0 : 55 + c * 40;
      return Color.fromARGB(255, level(r), level(g), level(b));
    }
    final gray = 8 + (n - 232) * 10;
    return Color.fromARGB(255, gray, gray, gray);
  }

  /// Non-SGR CSI: `K` (erase in line), `J` (erase display); others ignored.
  void _applyOther(_Escape esc, List<_TermLine> lines) {
    if (esc.params.isEmpty && esc.finalByte == 'K') {
      lines.last.erase(0);
      return;
    }
    final mode = esc.params.isEmpty ? 0 : _param(esc.params, 0);
    switch (esc.finalByte) {
      case 'K':
        lines.last.erase(mode);
      case 'J':
        if (mode == 0) {
          lines.last.erase(0);
          lines.removeRange(1, lines.length);
        } else if (mode == 1 || mode == 2 || mode == 3) {
          // Clear the whole screen and restart below the cursor line.
          final keep = lines.last;
          lines.clear();
          lines.add(keep..erase(2));
        }
    }
  }
}
