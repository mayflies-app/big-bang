# Privacy

## Local Data

API keys use the macOS Keychain service `app.mayfiles.BigBang.openai`. Model settings, endpoints, interface choices and presets use macOS user defaults. Note contents remain in memory and are discarded when closed.

Keys are not written to settings, command lines or logs. Changing another setting does not rewrite the key. The app does not display raw error response bodies.

### Removing Data

Delete a saved key through Settings before uninstalling if you want to remove that Keychain item. Quit the app before removing its bundle or preferences. Removing the app does not revoke a service-side API key; revoke it with the provider if needed.

## Network Access

The app sends selected text, preset prompts and the configured key to the selected HTTP(S) endpoint. Responses requests set `store=false`; the service's own retention policy still applies. An unauthenticated service receives no Authorization header after the saved key is deleted.

Markdown parsers, fonts, syntax highlighting, math and diagram rendering are bundled locally. HTTP(S) images can contact their source; opening an external link uses the system app. Local-file and SVG images are blocked, raw HTML is shown as text and fenced code is not executed. WebKit uses a nonpersistent data store.

## Permissions

Accessibility permission allows reading the active app's selection. Password fields are rejected. When direct reading fails and copy fallback is enabled, the app sends Copy to the source app after shortcut release, waits for fresh text and restores the previous clipboard formats. Keep the source app focused until this finishes.

Launch at Login uses macOS Login Items and can require system approval. System permission dialogs follow the macOS language independently of the app language.
