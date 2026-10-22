# Big Bang

Process selected text with configurable AI prompts from the macOS menu bar. Results stream into temporary desktop notes.

## Features

- Translate, explain, summarize or visualize selected text with global shortcuts.
- Add, rename and reorder presets; customize prompts and record shortcuts.
- Switch the preset in an existing note to process its original input again.
- Select and copy results, stop or retry a request, pin notes and chain another preset from a note's selection.
- Render Markdown, tables, code, math and Mermaid diagrams with bundled resources.
- Use English or Simplified Chinese and optionally launch at login.

## Requirements

macOS 14 or later, on Apple Silicon or Intel. Text selection requires Accessibility permission. Model requests require a configured HTTP(S) service; the default OpenAI endpoint requires an API key.

## Installation

Build and run from a source checkout:

```sh
./scripts/app.py build
./scripts/app.py run
```

The app bundle is named `BigBang.app`; its English display name is **Big Bang**. See [Development](docs/development.md) and [Releasing](docs/releasing.md).

## Usage

1. Allow Big Bang in **System Settings → Privacy & Security → Accessibility**. Follow any macOS instruction to relaunch after granting permission.
2. Open Settings and enter the service's API key, model, base URL and interface type. Changes save automatically after a short typing pause; switches and preset changes save immediately. Invalid settings retain the last valid configuration.
3. Select text in another app and press a preset shortcut. With copy fallback enabled, release the keys and stay in the source app until copying finishes.

| Default shortcut | Preset |
| --- | --- |
| `⌃⌥1` | Translate |
| `⌃⌥2` | Explain |
| `⌃⌥3` | Summarize |
| `⌃⌥4` | Visualize |
| `⌃⌥5` | Assistant |

English presets translate non-English text into English and English text into Simplified Chinese. Chinese presets reverse that direction. Explain, Summarize and Visualize use the selected app language. Visualize requests one concise Markdown table or Mermaid diagram without invented data or added explanation. Assistant answers direct questions and carries out requests in an independent turn, using the selected app language unless requested otherwise. Trigger without selected text to type or paste a question. Edited names and prompts, custom presets, order and shortcuts are preserved when changing language. Restore Defaults adds missing built-in presets without replacing existing edits; use it to add Assistant to an existing configuration.

The shortcut shows a note immediately while selection capture continues without blocking the interface. If no text can be captured, the note becomes a text editor. Choose a preset, type or paste your text, then click **Submit** or press **⌘Enter**. Return inserts a newline; active input-method composition is never submitted. Blank input is not submitted; input over 100 KB or a credential error keeps your draft available to correct and try again.

Select a different preset in a note's title to replace its result using the same original input. A running request is cancelled before the replacement starts. Retry uses the current preset and its latest saved prompt. Selecting text inside a note and pressing another preset shortcut creates a new note from that rendered selection.

Click **Back to Edit** beside Retry to return the note's latest submitted input to the text editor. This cancels any running request and keeps the current preset. Edit the text, then click **Submit** or press **⌘Enter** to replace the result in the same note. Subsequent retries use the edited input.

Notes grow with streaming text, then scroll when they reach the available height. Scrolling away from the bottom or selecting text pauses following. Click **Jump to Latest** to return to the bottom and resume following; the context menu also controls Follow Output. Copy Result copies the original Markdown. Closing a note cancels its request and discards its contents. Up to eight notes can stay open.

### Model service

Enter a base URL, including any service path prefix. The app appends the interface route:

| Base URL | Interface | Request route |
| --- | --- | --- |
| `https://api.openai.com/v1` | Responses | `/responses` |
| `https://gateway.example.com/proxy/openai/v1` | Chat Completions | `/chat/completions` |
| `http://127.0.0.1:11434/v1` | Chat Completions | `/chat/completions` |

These are configuration examples; compatibility depends on the service. Do not include credentials, query parameters, fragments or an operation route in the base URL. HTTPS uses system certificate validation; HTTP sends data without transport encryption. The default model is `gpt-4.1-mini`. An unauthenticated local service can be used after deleting the saved key.

### Settings and appearance

Settings groups General, Model Service, Presets and Text Reading. Choose **简体中文** or **English** to update the interface immediately. Launch at Login reflects the system's actual state and offers a link to Login Items when approval is needed. Login launches stay in the menu bar.

Deleting a preset shows **Undo Delete**, which restores the most recently deleted preset's content, shortcut and position. The notice stays until dismissed, undone or replaced by another deletion; it is not retained after quitting the app. New presets receive an available Control–Option number shortcut, adding Shift when needed. If all automatic combinations are in use, the app keeps the current list and asks you to free a shortcut.

Notes use native Liquid Glass on macOS 26 and later, with a system material fallback on older versions or with Reduce Transparency enabled. Preview Note is an offline UI demonstration.

## Privacy

Selected text and prompts are sent to the configured model service. API keys are stored in Keychain; notes remain in memory. Bundled rendering works offline, but remote images and opened links can access external services. See [Privacy](docs/privacy.md).

## Development

Use `./scripts/app.py build`, `run`, `test`, `package` and `release --dry-run`. Open `BigBang.xcodeproj` for native Xcode development. Product checks and Markdown tooling are described in [Development](docs/development.md).

## Contributing

See [Contributing](CONTRIBUTING.md). Maintained by [Mayflies](https://github.com/mayflies-app); optional support is available through [GitHub Sponsors](https://github.com/sponsors/nshcr).

## License

[MIT](LICENSE).
