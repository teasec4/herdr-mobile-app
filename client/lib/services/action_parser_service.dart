/// Suggested action parsed from agent output
class SuggestedAction {
  final String label;
  final String response;

  const SuggestedAction(this.label, this.response);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SuggestedAction &&
          runtimeType == other.runtimeType &&
          label == other.label &&
          response == other.response;

  @override
  int get hashCode => label.hashCode ^ response.hashCode;
}

/// Service for parsing suggested actions from agent output
class ActionParserService {
  /// How many recent output lines to scan for suggestions. Large enough to
  /// capture long numbered lists, but bounded so old output isn't re-parsed.
  static const _tailLines = 50;

  /// A candidate list must have between this many options to be actionable.
  static const _minOptions = 2;
  static const _maxOptions = 6;

  static const _maxLabelLength = 40;

  /// Parse suggested actions from terminal output
  /// Returns list of suggested actions (empty if none found)
  List<SuggestedAction> parse(String output) {
    if (output.isEmpty) return const [];

    // Strip ANSI escape codes before parsing
    final cleanOutput = _stripAnsi(output);
    final lines = cleanOutput.split('\n');
    // Only look at recent output
    final tail = lines.length > _tailLines ? lines.sublist(lines.length - _tailLines) : lines;

    // Strategy 1: Inline bracketed options like (y/n), [yes/no], {accept/reject}
    // or (1/2/3) at the end of a line. Bare option1/option2 is intentionally NOT
    // parsed — it is indistinguishable from a path (lib/foo/bar).
    for (final line in tail.reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final bracketed = RegExp(
        r'[\(\[\{]([a-z0-9]+(?:/[a-z0-9]+)+)[\)\]\}]\s*$',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (bracketed != null) {
        final options = bracketed.group(1)!.split('/');
        if (options.length >= _minOptions && options.length <= _maxOptions) {
          return options.map((opt) => SuggestedAction(opt, opt)).toList();
        }
      }
    }

    // Strategy 2: Questions phrased with "would you", "do you want", "should i"
    for (final line in tail.reversed) {
      final trimmed = line.trim().toLowerCase();
      if (trimmed.isEmpty) continue;

      if (trimmed.endsWith('?') &&
          (trimmed.contains('would you') ||
              trimmed.contains('do you want') ||
              trimmed.contains('should i'))) {
        return const [
          SuggestedAction('Yes', 'yes'),
          SuggestedAction('No', 'no'),
        ];
      }
    }

    // Strategy 3: Numbered list, one option per line: "1. Option" / "2) Option"
    final numberedOptions = <String>[];
    for (final line in tail) {
      final match = RegExp(r'^\s*(\d+)[\.\)]\s+(.+)$').firstMatch(line.trim());
      if (match != null) {
        final number = match.group(1)!;
        final text = match.group(2)!.trim();
        // Skip checkbox/task lists
        if (_isCheckbox(text)) continue;
        numberedOptions.add('$number: ${_truncate(text)}');
      }
    }
    if (numberedOptions.length >= _minOptions && numberedOptions.length <= _maxOptions) {
      return numberedOptions.map((opt) => SuggestedAction(opt, opt.split(':').first)).toList();
    }

    // Strategy 4: Inline numbered list on one line: "1) Build 2) Test 3) Deploy"
    for (final line in tail.reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final items = _parseInlineNumbered(trimmed);
      if (items != null) return items;
    }

    // Strategy 5: Comma-separated numeric choice: "Choose one: 1, 2, 3"
    for (final line in tail.reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final items = _parseCommaNumbers(trimmed);
      if (items != null) return items;
    }

    return const [];
  }

  /// Parse "1) Build 2) Test 3) Deploy" on a single line.
  /// Returns null if the line isn't a clean inline numbered list.
  List<SuggestedAction>? _parseInlineNumbered(String line) {
    final matches = RegExp(r'(\d+)[\.\)]\s+').allMatches(line).toList();
    if (matches.length < _minOptions || matches.length > _maxOptions) return null;

    final options = <SuggestedAction>[];
    for (var i = 0; i < matches.length; i++) {
      final number = matches[i].group(1)!;
      final textStart = matches[i].end;
      final textEnd = i + 1 < matches.length ? matches[i + 1].start : line.length;
      final text = line.substring(textStart, textEnd).trim();
      // Skip pure-numeric fragments like "2.0" and checkbox items
      if (text.isEmpty || _isCheckbox(text) || _isNumeric(text)) return null;
      options.add(SuggestedAction('$number: ${_truncate(text)}', number));
    }
    return options;
  }

  /// Parse "Choose one: 1, 2, 3" into numeric choice buttons.
  /// Returns null if the line doesn't clearly ask for a numeric pick.
  List<SuggestedAction>? _parseCommaNumbers(String line) {
    final match = RegExp(r'(\d+(?:\s*,\s*\d+)+)').firstMatch(line);
    if (match == null) return null;

    final numbers = match.group(1)!.split(RegExp(r'\s*,\s*'));
    if (numbers.length < _minOptions || numbers.length > _maxOptions) return null;

    // Require either a choice-like phrasing or a line that is essentially
    // just numbers — avoids misreading "errors 2, 3 in log" as a pick.
    final hasChoiceWord = RegExp(
      r'choose|select|option|pick|which|enter|type',
      caseSensitive: false,
    ).hasMatch(line);
    final onlyNumbers = line.replaceAll(RegExp(r'[\d,\s\(\)\[\]\{\}:.]'), '').isEmpty;
    if (!hasChoiceWord && !onlyNumbers) return null;

    return numbers.map((n) => SuggestedAction(n, n)).toList();
  }

  bool _isCheckbox(String text) {
    return text.startsWith('◻') ||
        text.startsWith('◼') ||
        text.startsWith('☐') ||
        text.startsWith('☑');
  }

  /// Whether the text is only digits/dots (e.g. "2.0") and so not a real label.
  bool _isNumeric(String text) {
    return text.replaceAll(RegExp(r'[\d\s.,;:]'), '').isEmpty;
  }

  String _truncate(String text, [int maxLength = _maxLabelLength]) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength - 1)}…';
  }

  /// Strip ANSI escape codes from text
  String _stripAnsi(String text) {
    // Remove ANSI escape sequences: ESC [ ... m (SGR), ESC [ ... (CSI), ESC ] ... (OSC)
    return text
        .replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '') // CSI sequences
        .replaceAll(RegExp(r'\x1B\][^\x07]*\x07'), '')    // OSC sequences
        .replaceAll(RegExp(r'\x1B[=>]'), '')              // Other ESC sequences
        .replaceAll(RegExp(r'\r'), '');                   // Carriage returns
  }
}
