import 'package:client/widgets/ansi_terminal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _base = TextStyle(fontSize: 12, color: Color(0xFFE0E0E0));

/// Plain text of a parsed span list (newlines between lines included).
String _plain(List<InlineSpan> spans) {
  final sb = StringBuffer();
  void walk(List<InlineSpan> list) {
    for (final s in list) {
      if (s is TextSpan) {
        if (s.text != null) sb.write(s.text);
        walk(s.children ?? const []);
      }
    }
  }

  walk(spans);
  return sb.toString();
}

Iterable<TextSpan> _textSpans(List<InlineSpan> spans) sync* {
  for (final s in spans) {
    if (s is TextSpan) {
      if (s.text != null) yield s;
      yield* _textSpans(s.children ?? const []);
    }
  }
}

void main() {
  group('AnsiTerminalParser: plain text', () {
    test('по одному символу на ячейку, текст сохраняется без переводов', () {
      final spans = AnsiTerminalParser('hello', baseStyle: _base).parse();
      expect(_plain(spans), 'hello');
    });

    test('пустой ввод — один пустой спан', () {
      final spans = AnsiTerminalParser('', baseStyle: _base).parse();
      expect(_textSpans(spans).single.text, '');
    });

    test('соседние символы с одинаковым стилем сливаются в один спан', () {
      final spans = AnsiTerminalParser('hi', baseStyle: _base).parse();
      final list = _textSpans(spans).toList();
      expect(list.length, 1);
      expect(list.single.text, 'hi');
    });

    test('строки разделяются переводом между линиями', () {
      final spans = AnsiTerminalParser('a\nb', baseStyle: _base).parse();
      expect(_plain(spans), 'a\nb');
    });
  });

  group('AnsiTerminalParser: carriage return', () {
    test('\\r перематывает в начало строки и перезаписывает ячейки', () {
      // «ABCDE» затем «\rXY» — остаётся «XYCDE», как в терминале.
      final spans = AnsiTerminalParser('ABCDE\rXY', baseStyle: _base).parse();
      expect(_plain(spans), 'XYCDE');
    });

    test('прогресс-бар через \\r остаётся одной строкой в последнем состоянии', () {
      final in0 = '[#       ] 12%';
      final in1 = '[###     ] 37%';
      final out = AnsiTerminalParser('$in0\r$in1', baseStyle: _base).parse();
      expect(_plain(out), in1);
    });

    test('\\r\\n — обычный перенос строки', () {
      final spans = AnsiTerminalParser('a\r\nb', baseStyle: _base).parse();
      expect(_plain(spans), 'a\nb');
    });
  });

  group('AnsiTerminalParser: SGR', () {
    test('базовый цвет применяется и сбрасывается', () {
      final spans = AnsiTerminalParser('\x1b[31mred\x1b[0m plain', baseStyle: _base).parse();
      final list = _textSpans(spans).toList();
      expect(list[0].text, 'red');
      expect(list[0].style!.color, const Color(0xFFCD3131));
      expect(list[1].text, ' plain');
      expect(list[1].style!.color, _base.color);
    });

    test('bold + цвет наследуется', () {
      final spans = AnsiTerminalParser('\x1b[1;32mok', baseStyle: _base).parse();
      final s = _textSpans(spans).single.style!;
      expect(s.fontWeight, FontWeight.bold);
      expect(s.color, const Color(0xFF0DBC79));
    });

    test('256-цвет (38;5;n)', () {
      // 196 — ярко-красный в кубе xterm: r=255, g=0, b=0.
      final spans = AnsiTerminalParser('\x1b[38;5;196mX', baseStyle: _base).parse();
      expect(_textSpans(spans).single.style!.color, const Color(0xFFFF0000));
    });

    test('truecolor (38;2;r;g;b)', () {
      final spans = AnsiTerminalParser('\x1b[38;2;10;20;30mX', baseStyle: _base).parse();
      expect(_textSpans(spans).single.style!.color, const Color(0xFF0A141E));
    });

    test('colon-SGR (4:3 — волнистое подчёркивание) не оставляет мусора', () {
      // Современные терминалы шлют подчёркивания в виде 4:3; двоеточие бьётся
      // как разделитель, а неизвестный код игнорируется.
      final spans = AnsiTerminalParser('\x1b[4:3mX', baseStyle: _base).parse();
      expect(_plain(spans), 'X');
      expect(_textSpans(spans).single.style!.decoration, TextDecoration.underline);
    });

    test('невалидная CSI-команда (22_) ведёт себя как в xterm — без падения', () {
      // `\x1b[22_m` в xterm трактуется как неизвестная команда с финальным
      // символом `_` (игнорируется), а `m` печатается как обычный текст.
      final spans = AnsiTerminalParser('\x1b[22_mX', baseStyle: _base).parse();
      expect(_plain(spans), 'mX');
    });
  });

  group('AnsiTerminalParser: прочие escape-последовательности', () {
    test('курсорные и прочие CSI вырезаются без мусора', () {
      final spans = AnsiTerminalParser('a\x1b[1A\x1b[2C\x1b[?25lb\x1b[0J', baseStyle: _base).parse();
      expect(_plain(spans), 'ab');
    });

    test('K (erase in line) вычищает хвост строки', () {
      // 12 символов, затем \r и «x» + EL(0) — остаётся «x`.
      final spans = AnsiTerminalParser('0123456789ab\rx\x1b[K', baseStyle: _base).parse();
      expect(_plain(spans), 'x');
    });

    test('2J (clear screen) обнуляет вывод до текущей строки включительно', () {
      final spans = AnsiTerminalParser('old text\x1b[2Jnew', baseStyle: _base).parse();
      expect(_plain(spans), 'new');
    });

    test('OSC (заголовок окна) вырезается целиком', () {
      final spans = AnsiTerminalParser('\x1b]0;herdr\x07ok', baseStyle: _base).parse();
      expect(_plain(spans), 'ok');
    });
  });
}