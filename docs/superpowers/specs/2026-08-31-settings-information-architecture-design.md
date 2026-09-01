# Settings Information Architecture Design

## Goal

Make Murmure's settings understandable to non-technical users without changing its field-recorder visual language. Replace the single long page with six focused categories, make the distinction between interface language and spoken language explicit, and promote Snippets to a first-class workspace destination.

## Approved structure

The global navigation order is Home, Dictionary, Snippets, Settings. Settings opens on Dictation and presents a persistent category list with one selected category's cards visible at a time:

1. Dictation — spoken-language selection, engine, comparison, and cleanup.
2. Shortcuts — push-to-talk, hands-free, and Command Mode.
3. Microphone & sounds — input selection, microphone test, and start/finish sounds.
4. Appearance — display-language selection.
5. Privacy & storage — permissions, local data location, and private diagnostics.
6. Advanced & updates — rerun setup and update controls.

## Language copy

- Display language: “Changes Murmure’s menus, buttons, and instructions. It does not change the language you dictate.”
- Language you speak: “Automatic recognizes supported languages while you speak. Choose a language only when you want to give the speech engine a specific hint.”
- Every new title, explanation, button label, and accessibility label is provided in English, French, and Spanish through the existing localization catalog.

## Architecture

`SettingsCategory` is the typed ordering and metadata model for the category rail. `SettingsWindow` owns only settings-specific state and shows the selected category through a single internal seam. `SnippetPanel` owns snippet listing, enablement, editing, and deletion independently of Settings. `MainWindow` adds the Snippets destination through `HubSection`.

## Constraints

- Preserve all existing recording, hotkey, microphone, cleanup, permission, diagnostics, storage, and update behavior.
- Preserve the existing design system; any new dimensions must be design tokens.
- Keep Automatic spoken-language recognition as the default and do not conflate it with display language.
- Build with `make`, install to `/Applications/Murmure.app`, and verify the installed app in English, French, and Spanish.

## Acceptance criteria

- Settings no longer requires scrolling past unrelated categories.
- The category rail remains visible while the selected category content scrolls independently.
- Snippets appears between Dictionary and Settings and all existing snippet actions work there.
- “Display language” and “Language you speak” are unambiguous in all three languages.
- Existing tests plus new navigation/localization tests pass, and the installed app is visually exercised in all three languages.
