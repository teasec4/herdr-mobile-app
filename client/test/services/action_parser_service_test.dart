import 'package:client/services/action_parser_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final parser = ActionParserService();

  List<SuggestedAction> parse(String output) => parser.parse(output);

  List<String> responses(String output) =>
      parse(output).map((a) => a.response).toList();

  group('bracketed options', () {
    test('(y/n) parses to y and n buttons', () {
      final actions = parse('Do you want to continue? (y/n)');
      expect(actions, [
        const SuggestedAction('y', 'y'),
        const SuggestedAction('n', 'n'),
      ]);
    });

    test('[yes/no] parses to yes and no', () {
      final actions = parse('Proceed? [yes/no]');
      expect(actions, [
        const SuggestedAction('yes', 'yes'),
        const SuggestedAction('no', 'no'),
      ]);
    });

    test('{accept/reject} parses to accept and reject', () {
      final actions = parse('Please choose {accept/reject}');
      expect(actions, [
        const SuggestedAction('accept', 'accept'),
        const SuggestedAction('reject', 'reject'),
      ]);
    });

    test('(1/2/3) parses to numbers 1, 2, 3', () {
      final actions = parse('Pick (1/2/3)');
      expect(responses('Pick (1/2/3)'), ['1', '2', '3']);
      expect(actions.map((a) => a.label), ['1', '2', '3']);
    });
  });

  group('yes/no questions', () {
    test('"Do you want to continue?" parses to Yes/No', () {
      final actions = parse('Do you want to continue?');
      expect(actions, [
        const SuggestedAction('Yes', 'yes'),
        const SuggestedAction('No', 'no'),
      ]);
    });

    test('"Should I proceed?" parses to Yes/No', () {
      expect(responses('Should I proceed?'), ['yes', 'no']);
    });
  });

  group('numbered list (one option per line)', () {
    test('parses 3 numbered lines with numeric responses', () {
      final output = '''
Please choose an option:
1. Create new file
2. Update existing
3. Skip this step
''';
      final actions = parse(output);
      expect(actions, hasLength(3));
      expect(actions[0].label, '1: Create new file');
      expect(actions[0].response, '1');
      expect(actions[1].label, '2: Update existing');
      expect(actions[1].response, '2');
      expect(actions[2].label, '3: Skip this step');
      expect(actions[2].response, '3');
    });

    test('parses list with ")" separators too', () {
      final actions = parse('1) Build\n2) Test\n3) Deploy');
      expect(actions.map((a) => a.label), ['1: Build', '2: Test', '3: Deploy']);
      expect(actions.map((a) => a.response), ['1', '2', '3']);
    });

    test('skips checkbox/task list lines', () {
      final actions = parse('- [ ] a\n- [ ] b');
      expect(actions, isEmpty);
    });
  });

  group('inline numbered list', () {
    test('"1) Build 2) Test 3) Deploy" parses inline', () {
      final actions = parse('1) Build 2) Test 3) Deploy');
      expect(actions, hasLength(3));
      expect(actions.map((a) => a.label), ['1: Build', '2: Test', '3: Deploy']);
      expect(responses('1) Build 2) Test 3) Deploy'), ['1', '2', '3']);
    });

    test('pure-numeric fragments like "2.0" do not produce buttons', () {
      expect(parse('1) 2.0 3) 4.0'), isEmpty);
    });
  });

  group('comma-separated numeric choice', () {
    test('"Choose one: 1, 2, 3" parses to 1/2/3', () {
      final actions = parse('Choose one: 1, 2, 3');
      expect(responses('Choose one: 1, 2, 3'), ['1', '2', '3']);
    });

    test('bare "1, 2, 3" parses to 1/2/3', () {
      expect(responses('1, 2, 3'), ['1', '2', '3']);
    });

    test('"errors 2, 3 in log" does not produce buttons', () {
      expect(parse('errors 2, 3 in log'), isEmpty);
    });
  });

  group('false positives', () {
    test('file path at end of line is not parsed as options', () {
      expect(parse('import lib/foo/bar'), isEmpty);
      expect(parse('the path is lib/foo/bar'), isEmpty);
    });

    test('URL with path is not parsed as options', () {
      expect(parse('see http://host/a/b'), isEmpty);
      expect(parse('docs at https://example.com/x/y'), isEmpty);
    });

    test('single option is not enough (min 2)', () {
      expect(parse('1. Only option'), isEmpty);
    });

    test('too many options are ignored (max 6)', () {
      final many = List.generate(7, (i) => '${i + 1}. Option $i').join('\n');
      expect(parse(many), isEmpty);
    });
  });
}
