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
  /// Parse suggested actions from terminal output
  /// Returns list of suggested actions (empty if none found)
  List<SuggestedAction> parse(String output) {
    if (output.isEmpty) return const [];

    final lines = output.split('\n');
    // Only look at last 10 lines (recent output)
    final tail = lines.length > 10 ? lines.sublist(lines.length - 10) : lines;

    // Strategy 1: Inline options like (y/n), [yes/no], option1/option2 at end of line
    for (final line in tail.reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Pattern: (y/n) or [yes/no] or {accept/reject}
      final inlineMatch = RegExp(r'[\(\[\{]([a-z]+)/([a-z]+)[\)\]\}]\s*$').firstMatch(trimmed);
      if (inlineMatch != null) {
        final opt1 = inlineMatch.group(1)!;
        final opt2 = inlineMatch.group(2)!;
        return [
          SuggestedAction(opt1, opt1),
          SuggestedAction(opt2, opt2),
        ];
      }

      // Pattern: option1/option2/option3 at end
      final slashMatch = RegExp(r'([a-z]+(?:/[a-z]+)+)\s*$').firstMatch(trimmed);
      if (slashMatch != null) {
        final options = slashMatch.group(1)!.split('/');
        if (options.length >= 2 && options.length <= 4) {
          return options.map((opt) => SuggestedAction(opt, opt)).toList();
        }
      }
    }

    // Strategy 2: Questions with yes/no pattern
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

    // Strategy 3: Numbered lists (1. Option, 2. Option)
    final numberedOptions = <String>[];
    for (final line in tail) {
      final match = RegExp(r'^\s*(\d+)[\.\)]\s+(.+)$').firstMatch(line.trim());
      if (match != null) {
        final number = match.group(1)!;
        final text = match.group(2)!.trim();
        // Skip if it looks like a checkbox/task list
        if (text.startsWith('◻') || text.startsWith('◼') || text.startsWith('☐') || text.startsWith('☑')) {
          continue;
        }
        numberedOptions.add('$number: ${_truncate(text, 40)}');
      }
    }

    if (numberedOptions.length >= 2 && numberedOptions.length <= 6) {
      return numberedOptions
          .map((opt) => SuggestedAction(opt, opt.split(':').first))
          .toList();
    }

    return const [];
  }

  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength - 1)}…';
  }
}
