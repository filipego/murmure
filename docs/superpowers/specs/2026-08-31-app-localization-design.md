# Murmure App Localization Design

## Goal

Murmure must offer a complete English, French, and Spanish interface. A new user chooses the interface language before the rest of onboarding. The same choice remains available in Settings. Interface language and transcription language remain independent.

## User experience

The first onboarding step is **Choose app language**. It presents English, Français, and Español using each language's native name. The initial selection follows the Mac language when it is French or Spanish and otherwise uses English. Changing the selection immediately updates the current window and persists for future launches.

Settings gains an **App language** picker near the top of the general settings surface. Changing it updates every Murmure window, sheet, menu, status, error, help string, and accessibility label without changing the selected speech engine or dictation language.

Existing users are not forced back through onboarding. They receive the Mac-derived default until they choose another language in Settings. Rerunning setup begins with the language step.

## Architecture

`AppLanguage` is a three-case Codable enum with stable raw values `en`, `fr`, and `es`. `AppLanguageStore` is the single observable owner of the selected interface language and persists it in `UserDefaults`. It does not participate in the external settings snapshot because language must be available before deferred storage hydration.

`L10n` owns the English source keys plus complete French and Spanish translation tables. Lookup is deterministic, synchronous, and falls back to the English key if a catalog entry is missing. Formatted messages use localized format strings and preserve placeholder types across all languages.

Every window root observes `AppLanguageStore` so a change invalidates all visible localized content. User-facing code uses `L10n.text` or `L10n.format`. Device names, dictated text, user-authored snippets, dictionary content, shortcuts, product names, and operating-system error descriptions remain verbatim.

## Coverage

Localization covers:

- onboarding and completion;
- Home, navigation, history, recovery, and recording controls;
- Dictionary and correction editing;
- Settings, snippets, diagnostics, permissions, storage, updates, and microphone testing;
- Command Mode, comparison, retranscription, shortcut recording, HUD, and menu bar;
- window titles, buttons, pickers, toggles, status strings, empty states, alerts, help text, and accessibility labels.

The HTML dashboard is legacy and scriptable support. Its visible English copy is localized only where the current native application still exposes it.

## Protected behavior and presentation

Localization must not alter speech recognition selection, cleanup behavior, dictionary rules, snippets, audio retention, history, shortcuts, permissions, update behavior, code signing, or storage.

The recorder design is locked. Colors, typography, spacing, sizing tokens, layout structure, animations, and imagery remain unchanged. Text may wrap naturally when French or Spanish is longer. A layout change beyond natural wrapping requires separate approval.

## Testing and proof

Tests must first fail for the absent language model and catalog. They then cover Mac-language defaulting, persistence, explicit selection, English fallback, complete French and Spanish key coverage, and format-placeholder parity.

`make test` and `make app` must pass. The staged bundle must be installed through `make install`. Exact-surface verification must exercise onboarding or Settings language selection and inspect Home, Dictionary, Settings, and one secondary workflow in English, French, and Spanish. The final proof records any text truncation or layout change.

## Acceptance criteria

1. A new onboarding run starts with an interface-language choice.
2. English, French, and Spanish selections persist across launch.
3. Changing App Language updates the visible Murmure interface without changing transcription language.
4. All active native user-facing strings have French and Spanish translations.
5. Existing behavior and recorder presentation remain unchanged apart from translated text and natural wrapping.
6. Tests, build, bundle, installation, and exact installed-app checks pass.
