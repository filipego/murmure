# Localized Snippet Command Design

## Goal

Replace the English-only two-word `Voice add` prefix with one natural insertion command for every spoken language supported by Murmure. Show the command where snippets are created and managed so a non-technical user can discover it without reading separate documentation.

## Command vocabulary

The command follows **Language you speak**, not Display language. Automatic accepts every command in the table.

| Spoken language | Command | Example |
|---|---|---|
| English | Insert | Insert my address |
| Spanish | Inserta | Inserta mi dirección |
| French | Insère | Insère mon adresse |
| Bulgarian | Вмъкни | Вмъкни моя адрес |
| Croatian | Umetni | Umetni moju adresu |
| Czech | Vlož | Vlož mou adresu |
| Danish | Indsæt | Indsæt min adresse |
| Dutch | Voeg | Voeg mijn adres toe |
| Estonian | Sisesta | Sisesta minu aadress |
| Finnish | Lisää | Lisää osoitteeni |
| German | Einfügen | Einfügen meine Adresse |
| Greek | Εισαγωγή | Εισαγωγή τη διεύθυνσή μου |
| Hungarian | Illeszd | Illeszd a címemet |
| Italian | Inserisci | Inserisci il mio indirizzo |
| Latvian | Ievieto | Ievieto manu adresi |
| Lithuanian | Įterpk | Įterpk mano adresą |
| Maltese | Daħħal | Daħħal l-indirizz tiegħi |
| Polish | Wstaw | Wstaw mój adres |
| Portuguese | Insira | Insira meu endereço |
| Romanian | Inserează | Inserează adresa mea |
| Russian | Вставь | Вставь мой адрес |
| Slovak | Vlož | Vlož moju adresu |
| Slovenian | Vstavi | Vstavi moj naslov |
| Swedish | Infoga | Infoga min adress |
| Ukrainian | Встав | Встав мою адресу |

The trigger itself remains user-defined. Examples illustrate syntax and do not create translated aliases for a saved trigger.

## Matching behavior

`SnippetCommandLexicon` owns the mapping from `TranscriptionLanguageOption` to normalized command words. `SnippetExpander` receives the active spoken-language option together with the entries.

- An explicit spoken language accepts only its command.
- Automatic accepts commands from every supported language.
- Matching is case-insensitive, NFC-normalized, and requires a whitespace or punctuation boundary after the command.
- The text immediately after the command must begin with a complete enabled snippet trigger.
- The longest matching trigger wins and later speech is preserved.
- A trigger spoken as the complete utterance continues to work without a command.
- A trigger inside ordinary prose continues not to expand.
- `Voice add` is retired rather than advertised as a hidden alternate command.

The selected language captured for the dictation operation is used for expansion. A settings change during transcription therefore cannot alter how that recording is interpreted.

## Interface

The Snippets destination shows a compact instruction using the command for the current spoken-language selection. For Automatic, it explains that Murmure accepts the localized insertion word and shows examples for English, French, and Spanish.

The Add/Edit snippet sheet places the instruction directly above **When I say**. It shows a complete example constructed from the current command and the trigger placeholder. English, French, and Spanish Display language strings describe the same behavior in the selected interface language, while the command example still follows Language you speak.

No layout, colors, typography, or unrelated settings change.

## Tests

- One command test for every explicit spoken language.
- Automatic accepts every command.
- Explicit languages reject commands belonging only to another language.
- Unicode commands work in composed and decomposed form.
- Command boundaries reject prefixes embedded inside longer words.
- Longest-trigger and trailing-speech behavior remains intact.
- Whole-utterance triggers remain intact.
- Ordinary prose remains untouched.
- Localization catalog tests require the new English, French, and Spanish interface copy.

Run the focused snippet and localization tests first, then the complete macOS suite through `make` as required by the repository.
