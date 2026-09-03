# Terminal UI - Interactive buttons

## Concept

Instead of a set of static buttons with unclear functions (Esc, Ctrl-L, Ctrl-D, etc.), the terminal now shows **only relevant actions**:

1. **Ctrl-C** - always available (interrupt the agent)
2. **Smart buttons** - appear automatically, parsing real options from the agent's output

## How parsing works

When the agent is in the `blocked` status, the output is analyzed to find response options. The parser uses **only clear patterns**, it doesn't guess:

### Strategy 1: Inline options in the last line

Recognizes inline options in parentheses or separated by a slash:

```
Do you want to proceed? (y/n)          → кнопки: Y, N
Would you like to continue? [yes/no]   → кнопки: Yes, No
Please accept/reject this change       → кнопки: Accept, Reject
```

**Patterns:**
- `(option1/option2)` - in parentheses
- `[option1/option2]` - in square brackets  
- `option1/option2` - simply separated by a slash (only in the last line)

### Strategy 2: Question sentences

If the last lines contain a question with key phrases:

```
Would you like to...?    → кнопки: Yes, No
Do you want to...?       → кнопки: Yes, No
Should I...?             → кнопки: Yes, No
Can I...?                → кнопки: Yes, No
```

### Strategy 3: Numbered options

Recognizes lists with numbers:

```
Please choose:
1. Create new file       → кнопка: "Create new file" (отправляет "1")
2. Update existing       → кнопка: "Update existing" (отправляет "2")
3. Skip this step        → кнопка: "Skip this step" (отправляет "3")
```

**Patterns:**
- `1. text` - with a period
- `1) text` - with a parenthesis

Shows between 2 and 6 options. Long texts are truncated to 40 characters.

### Strategy 4: Checkbox lists (skipped)

If a list with checkboxes is encountered, it is **NOT** recognized as response options:

```
◻ Task one
◻ Task two
◼ Task three (done)
```

This is a task list, not a choice of options.

## What is NOT recognized

The parser does **NOT guess** options from keywords in the text. For example:

```
You can continue working or skip this step.
```

Buttons will **NOT appear**, because there is no clear pattern (no "(continue/skip)", no numbering).

This is done deliberately to avoid false positives.

## Examples of how it works

### Example 1: Simple yes/no
**Agent output:**
```
✻ File already exists. Overwrite? (y/n)
❯
```

**Buttons:** `Y` `N`

### Example 2: Expanded options
**Agent output:**
```
✻ This operation requires confirmation.
  Would you like to proceed? [yes/no]
❯
```

**Buttons:** `Yes` `No`

### Example 3: Multiple choice
**Agent output:**
```
✻ Select migration strategy:
  1. Incremental migration (safer)
  2. Full rewrite (faster)
  3. Keep both versions
  4. Cancel operation
❯
```

**Buttons:** `Incremental migration (safer)` `Full rewrite (faster)` `Keep both versions` `Cancel operation`

Pressing sends: `1`, `2`, `3`, `4` respectively.

### Example 4: Inline actions
**Agent output:**
```
✻ Changes ready. You can approve/reject or skip this file.
❯
```

**Buttons:** `Approve` `Reject` `Skip`

## Code

### Parsing (agent_page.dart:435-545)

The main logic is in `_parseSuggestedActions()`:

1. Works only when `agent.status == 'blocked'`
2. Analyzes the last 50 lines of output
3. Finds the last non-empty line (usually the prompt)
4. Applies parsing strategies by priority (1→2→3→4)
5. Stops at the first successful strategy
6. **Does not guess** - if no pattern is found, the buttons do not appear

```dart
void _parseSuggestedActions(String output) {
  _suggestedActions = [];
  if (_agent.status != 'blocked') return;

  // 1. Найти последнюю непустую строку
  // 2. Попробовать распарсить inline опции (y/n)
  // 3. Попробовать найти вопрос с yes/no
  // 4. Попробовать найти нумерованный список
  // Если ничего не найдено - не показывать кнопки
}
```

### UI (agent_page.dart:265-286)

Buttons are shown only if `_suggestedActions` is not empty:

```dart
if (_suggestedActions.isNotEmpty) ...[
  Wrap(
    spacing: 8,
    children: _suggestedActions.map((action) {
      return FilledButton.tonal(
        onPressed: () {
          _input.text = action.response;
          _send();
        },
        child: Text(action.label),
      );
    }).toList(),
  ),
],
```

## Benefits of the new parser

✅ **Accuracy** - parses only clear patterns, doesn't guess  
✅ **No false positives** - if no pattern is found, the buttons don't appear  
✅ **Priorities** - inline options take precedence over questions, questions over lists  
✅ **Text cleanup** - strips ANSI escape codes, truncates long lines  
✅ **Smart filtering** - does not show task lists as response options  
✅ **Simplicity** - only 4 strategies, easy to understand and extend

## Limitations

- The parser only works with text output (doesn't understand rich UI)
- If the agent doesn't format options clearly, the buttons may not appear
- Maximum of 6 options in a numbered list (otherwise the UI overflows)
- Button text is truncated to 40 characters

## Tests

Two tests cover the main scenarios:

1. **Inline options:** `(y/n)` → buttons `Y`, `N`
2. **Numbered list:** `1. Option` → button with the option's text, sends the number

```dart
testWidgets('предложенные действия появляются когда агент blocked с yes/no', ...);
testWidgets('предложенные действия парсят нумерованные варианты', ...);
```

## What was removed

- ❌ Ctrl-Z, Esc, Ctrl-L, Ctrl-D, Enter - confusing and unnecessary
- ❌ "Quick commands" menu with made-up commands
- ❌ Grouping buttons by color
- ❌ Making up buttons based on keywords without context

Only this remains:
- ✅ Ctrl-C (always visible)
- ✅ Smart buttons parsed from the agent's real output

## Extension

To add a new pattern, add a strategy to `_parseSuggestedActions()`:

```dart
// Strategy 6: Custom pattern
if (lastNonEmpty.contains('your_custom_pattern')) {
  _suggestedActions.add(_SuggestedAction('Option 1', 'opt1'));
  _suggestedActions.add(_SuggestedAction('Option 2', 'opt2'));
  return;
}
```

Strategies run from top to bottom. The first successful one stops the parsing.
