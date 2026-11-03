# Mixed-language alphabet conversion

The STT response's `language` describes the whole transcript, not each word.
With the modern alphabet selected, Echo checks language evidence and individual
words before applying `o‘ → ö`, `g‘ → ğ`, `sh → ş`, and `ch → ç`. Recognized Uzbek
portions can be converted even when the recording's dominant language is English.

For example:

```
I am switching. Hozir o‘zgartiryapti, chopayapti.
I am switching. Hozir özgartiryapti, çopayapti.
```

Both dictation and onboarding Try it use `DictationText.render`. Remote history
keeps the server's original text, detected language and revision. All desktop STT
requests use `language=auto`, including callers with a legacy language preference.

Recognition uses bundled Uzbek stems/lemmas, common bounded inflection rules,
and an English preservation vocabulary. Unknown words and English homographs
(such as `chat`, `chin`, and `chop` on their own) remain unchanged. This is
intentionally conservative; it is not perfect language identification, and
unrecognized Uzbek forms may retain the current spelling. Per-word language
metadata from STT would be needed to resolve genuinely ambiguous words in context.

## Code switching and display

`SpeechLanguages` combines the bundled Uzbek vocabulary with macOS NaturalLanguage
text recognition. It uses clauses, script changes and bounded non-overlapping
phrase checks. URLs, email addresses and code are excluded from language evidence.
The OS recognizer does not support Uzbek, so strong Uzbek evidence takes precedence
over its guesses. Shared English words cannot establish Uzbek language evidence.

History shows a localized language name for a single-language result and the
single label **Multilingual** (**Ko‘ptilli** in Uzbek) when multiple languages have
clear text evidence. The evidence is saved in the encrypted local transcript and
recomputed when fetching remote history. The API's canonical audio-level language
is retained separately. Existing cached records without evidence retain their
previous language until history refreshes. No extra audio upload or LLM call occurs.

This is conservative text inference, not authoritative per-word audio detection.
Very short switches, names, overlapping vocabularies, transliterated text, missing
punctuation and misrecognition can remain ambiguous. Uncertain words stay unchanged;
an uncertain language switch keeps the provider's language label. The supported
inference catalog currently contains 33 languages, not every language in the world.

## Backend deployment

Deploy the backend update together with the app update. Current backend `main`
already supports automatic detection in `internal/httpapi/desktop_stt.go`; this
update completes language persistence in `internal/desktopusage/service.go`:

- Echo explicitly sends `auto`, enabling provider language detection and bypassing
  the saved onboarding language. Older clients that omit the field retain their
  saved profile/default behavior.
- Use `ResolveResultLanguage`; never save `auto` as the detected language or
  guess Uzbek when detection fails. Failure rolls back the quota reservation.
- Save every language in the shared STT catalog instead of the old three-language
  allowlist. The existing v169 migration already widens the database constraint;
  no new migration is introduced.
- Keep explicit supported language requests compatible for older clients.

The app also accepts statistics for languages outside Uzbek, English and Russian.
These changes have not been deployed. Inference model quality still needs
real-audio checks after deployment; the automated endpoint tests use a controlled
provider with real isolated PostgreSQL/Redis and authentication/accounting.

Explicit Uzbek Latin dictionary entries can identify unfamiliar Uzbek words.
Other dictionary languages, including All languages, preserve the entered
spelling. Snippet expansions, URLs, email addresses, domains, code, identifiers,
spacing and punctuation remain protected. Old corrupted text is not guessed at
or rewritten retroactively.

## Vocabulary maintenance

`scripts/generate-alphabet-lexicon.py` regenerates the vocabulary from pinned
public data, verifies SHA-256 hashes, normalizes entries, and writes a Swift data
file plus `Voicelab/Resources/AlphabetLexiconNotices.txt`. The latter ships with
the app and includes source attribution and full licenses. The generated Swift
data is also available to the standalone regression harnesses; no runtime
download, OS dictionary, or missing-resource fallback is required.

## Verification

- `swift test --package-path Packages/VoiceLabCore`
- `scripts/test-alphabet-preferences.sh` covers preferences, dictation rendering,
  native editor insertion, and encrypted note persistence with a stub STT response.
- `scripts/test-try-it.sh` covers the onboarding trial, including mixed speech.
- Build the `Voicelab` Xcode scheme and verify that the license notice is bundled.
