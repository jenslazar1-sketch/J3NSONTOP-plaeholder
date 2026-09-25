# Terminal

The Terminal (tool id `system.terminal`, route `/tool/system.terminal`, alias
route `/terminal`) is J3NSONTOP's **internal command interface**: a keyboard-first
prompt that runs the typed commands registered by the app's own feature modules
through the tool registry (`ToolRegistry.commands`).

## This is not a system shell

The Terminal is **not a system shell** and must never be described as "shell
access". It never starts operating-system processes, never runs scripts,
programs or `cmd`/`bash`/PowerShell, and cannot reach anything the app itself
is not already allowed to access. Every command is plain Dart code inside this
app, looked up by name in the registry. Typing an OS program name such as `ls`,
`cd` or `python` prints an error that says so. The banner and `help` repeat
this statement.

## Opening it

- `` Ctrl+` `` (desktop), the **Terminal** entry in the navigation, or the
  **Terminal** row of the command palette (`Ctrl+K`).
- From anywhere with the palette's **`>` mode**: type `>` followed by a command
  (`> help`, `> open settings`) and press Enter. The palette opens the terminal
  and runs the line there (see [Palette hand-over](#palette-hand-over)).
- From inside the terminal: `open terminal` / `open /terminal` are accepted too.

## The screen

- **Banner** on a new session: the mini skull, "J3NSONTOP // internal command
  interface - runs this app's own tools. This is not a system shell." and a
  hint to type `help`.
- **Prompt**: `j3nsontop@<active workspace name or ~>$`. Every command is echoed
  with the prompt. On narrow screens the input shows `$` and the toolbar shows
  the full prompt.
- **Output** is monospace and styled by `TermStyle`: `normal`, `dim`, `accent`,
  `success`, `warning` (text starts with `WARN:`), `error` (text starts with
  `ERROR:`, so colour is never the only signal), `command` and `ascii`.
  Consecutive `ascii` lines are rendered as one block that scales down to fit
  narrow screens without breaking alignment.
- **Long sessions**: the output is a virtualised list; the scrollback keeps the
  last **5 000 lines** and shows how many older lines were dropped. New output
  keeps the view pinned to the bottom unless you scrolled up; a
  "Scroll to latest output" button then brings you back.
- **Toolbar**: Copy all (clipboard), Export (`terminal-<timestamp>.txt` through
  the standard save flow: workspace, save dialog or share sheet) and Clear.
  Output can also be selected directly with mouse or touch.
- **Running commands** show a spinner row with a **Cancel** button and a
  RUNNING badge; `Ctrl+C` cancels too.
- **Errors never crash the screen**: tokenizer errors (unclosed quotes), unknown
  commands ("Did you mean ...?" via Levenshtein distance) and exceptions thrown
  by a command are printed as `ERROR:` lines.
- **Session state** (transcript and the unfinished input line) lives in
  non-autoDispose providers, so it survives navigating to other tools and back.
  It is not kept across app restarts. **Command history** (last 200 lines) is
  persisted in `userdata.json`.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `Enter` | Run the input line (the prompt keeps focus afterwards) |
| `Up` / `Down` | Walk the command history; walking past the newest entry restores what you were typing |
| `Tab` | Complete the word at the caret: command names first, then arguments. One match is inserted; several are narrowed to their common prefix and shown as a clickable suggestion row |
| `Esc` | Close the suggestion row, then clear the input |
| `Ctrl+C` | Cancel the running command (prints `^C`); at an idle prompt abandon the line. With text selected in the input it copies instead |
| `Ctrl+L` | Clear the screen (same as `clear`) |
| any character while the output or a toolbar button has focus | Jumps back to the prompt and types it |
| `<command> --help` | Detailed help for that command (same as `help <command>`) |

## Touch

On touch platforms and on screens narrower than 600 px a row of large (44 px)
keys sits under the input: **Tab**, **Up**, **Down** and the quick commands
`help`, `tools`, `open`, `history`, `ws`, `clear` (tapping one inserts it into
the input). The input row has a **Run** button, completion candidates are
tappable, and a running command has a **Cancel** button. On phones the prompt
is not focused automatically, so the soft keyboard only opens when you tap the
input. When the viewport is very short (small phone, large text, soft keyboard)
the whole terminal becomes scrollable instead of overflowing.

## Command-line syntax

- Words are separated by spaces. Single or double quotes group words
  (`ws use "My Mod Project"`); inside double quotes a backslash escapes the next
  character (`\"`). An unclosed quote is reported as an error.
- Options: `--key value` (only for options the command declares in
  `valueOptions`), `--key=value`, `--flag` and `-f`. `--` ends option parsing
  (`echo -- --not-an-option`). Negative numbers are positional arguments.
- Command names and aliases are matched exactly, then case-insensitively.

## Command reference

The built-in commands below are generated from the implementation
(`test/features/terminal/terminal_docs_test.dart` fails when they drift;
regenerate with `UPDATE_TERMINAL_DOCS=1 flutter test test/features/terminal/terminal_docs_test.dart`).
Hidden commands (easter eggs) are omitted, as in `help`. Other features add
their own commands (for example `hash`, `json`, `diff`, `profiles`, `uuid`,
`b64`, `url`, `ts`); type `help` in the app to list everything in your build.

<!-- BEGIN GENERATED COMMAND REFERENCE -->

### `help`

List commands, or show details for one.

- Usage: `help [command]`
- Aliases: `?`
- Arguments:
  - `command` (optional): Command name or alias to describe.
- Examples: `help`, `help open`, `open --help`

### `tools`

List tools by section, or search them.

- Usage: `tools [section|query]`
- Arguments:
  - `section|query` (optional): Section key (workspaces, mods, config, assets, files, dev, system) or search words.
- Examples: `tools`, `tools dev`, `tools json format`

### `open`

Open a tool, section or page.

- Usage: `open <tool-id|section|route>`
- Arguments:
  - `target`: Tool id (e.g. dev.base64), tool name, section/page (mods, settings...) or route (/activity).
- Examples: `open settings`, `open dev`, `open /activity`, `open system.terminal`

### `history`

Show recent operations (what tools actually did).

- Usage: `history [n] [--failed]`
- Arguments:
  - `n` (optional): How many operations to show (1-300, default 20).
  - `--failed` (optional): Only failed operations. Values: `--failed`.
- Examples: `history`, `history 5`, `history --failed`

### `theme`

Show or change accent, effects and motion.

- Usage: `theme [show] | theme accent <neon|crimson|infrared|ember> | theme effects <low|full> | theme intensity <0-100> | theme scanlines|particles|glow <on|off> | theme motion <system|reduced|full>`
- Arguments:
  - `setting` (optional): What to show or change. Values: `show`, `accent`, `effects`, `intensity`, `scanlines`, `particles`, `glow`, `motion`.
  - `value` (optional): New value for the setting (see usage).
- Examples: `theme`, `theme accent crimson`, `theme effects low`, `theme intensity 40`, `theme scanlines off`, `theme motion reduced`

### `ws`

List workspaces, switch the active one, check its folder.

- Usage: `ws [list] | ws use <name|id> | ws info [name|id]`
- Aliases: `workspace`
- Arguments:
  - `action` (optional): list (default), use or info. Values: `list`, `use`, `info`.
  - `workspace` (optional): Workspace name or id (for use/info).
- Examples: `ws`, `ws use "Sample Mod Project"`, `ws info`

### `clear`

Clear the screen (Ctrl+L).

- Usage: `clear`
- Aliases: `cls`

### `echo`

Print text.

- Usage: `echo <text...>`
- Arguments:
  - `text` (optional): Words to print (quote to keep spacing).
- Examples: `echo hello world`, `echo "  keeps   spacing  "`, `echo -- --not-an-option`

### `about`

App name, version, platform, tool and command counts.

- Usage: `about`
- Aliases: `version`

### `date`

Current local and UTC time (ISO 8601).

- Usage: `date`

<!-- END GENERATED COMMAND REFERENCE -->

## Registering commands from a feature

Commands are contributed by feature modules, exactly like tools. Implement
`TerminalCommand` (`lib/core/commands/terminal_command.dart`) and list it in the
module's `commands`:

```dart
class UuidCommand extends TerminalCommand {
  const UuidCommand();

  @override
  String get name => 'uuid';

  @override
  String get summary => 'Generate random v4 UUIDs';

  @override
  String get usage => 'uuid [count] [--upper]';

  @override
  List<CommandArg> get args => const [
    CommandArg('count', 'How many (1-100)', optional: true),
    CommandArg('--upper', 'Upper-case output', optional: true, values: ['--upper']),
  ];

  @override
  List<String> get examples => const ['uuid', 'uuid 5 --upper'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final n = int.tryParse(args.at(0) ?? '1');
    if (n == null || n < 1 || n > 100) {
      return CommandResult.error('count must be 1-100', usage: usage);
    }
    final lines = <TermLine>[];
    for (var i = 0; i < n; i++) {
      ctx.token.throwIfCancelled(); // long loops honour Ctrl+C
      final id = generateUuid(); // the feature's own implementation
      lines.add(TermLine(args.flag('upper') ? id.toUpperCase() : id));
    }
    return CommandResult.ok(lines);
  }
}

final FeatureModule devToolsModule = FeatureModule(
  id: 'dev_tools',
  tools: [/* ... */],
  commands: const [UuidCommand()],
);
```

Rules:

- **Names are global.** The registry throws on a duplicate name or alias at
  startup. Built-in names: `help` (`?`), `tools`, `open`, `history`, `theme`,
  `ws` (`workspace`), `clear` (`cls`), `echo`, `about` (`version`), `date`,
  plus the hidden `skull`.
- **Call the feature's real implementation**, never a shell or an external
  process. Output must be honest: no fake progress, and decorative text must
  be obviously cosmetic.
- **Errors**: return `CommandResult.error(message, usage: usage)` (prints
  `ERROR: ...` plus the usage). Uncaught exceptions are contained and printed,
  but a clear message is better.
- **Long work** checks `ctx.token` (`throwIfCancelled()` or `whenCancelled`).
  Ctrl+C stops waiting immediately either way and discards late output. Work
  that changes files goes through `activityProvider` like it does in the UI, so
  it shows up in Activity and in `history`.
- **Providers**: read app state with `ctx.read(someProvider)`; navigate with
  `ctx.navigate('/tool/<id>')`.
- **Help and completion**: `usage`, `summary`, `args` (with `values` for
  enumerable arguments) and `examples` feed `help`, `<command> --help`, Tab
  completion and this document. Override `complete(ctx, typedArgs)` for
  context-dependent values (the last element of `typedArgs` is the word being
  typed). Set `hidden` for easter eggs that should not appear in `help`.
- **Styles**: use `TermLine.error/warn/ok/dim` so errors and warnings keep their
  text prefix; `TermStyle.ascii` for fixed-width art.

## Palette hand-over

The palette and the terminal are separate features and do not import each
other. The palette's `>` mode hands a command line to the terminal through the
core session draft store:

1. `ref.read(draftValueProvider('system.terminal/pending').notifier).set(line)`
2. `router.go('/tool/system.terminal')`

The terminal screen listens to that key (also when it is already open or kept
alive offstage), resets it to `null` and runs the line once. Any other UI may
use the same contract. Both sides define the key as a constant
(`kTerminalPendingCommandKey`, `kPaletteTerminalRequestKey`) and a test checks
they match.

## Implementation map

| Path | Content |
| --- | --- |
| `lib/features/terminal/terminal_module.dart` | Registers the tool and the built-in commands |
| `lib/features/terminal/commands/` | Built-in commands (`help`, `tools`, `open`, `history`, `theme`, `ws`, `clear`, `echo`, `about`, `date`, `skull`) |
| `lib/features/terminal/domain/` | Tab completion, history cursor, Levenshtein suggestions |
| `lib/features/terminal/presentation/terminal_session.dart` | Session state (transcript, scrollback cap, running command, cancellation) and the execution engine |
| `lib/features/terminal/presentation/terminal_screen.dart` | The terminal UI |
| `lib/features/palette/command_palette.dart` | Command palette including `>` mode |
| `test/features/terminal/`, `test/features/palette/` | Unit, widget and layout tests |
