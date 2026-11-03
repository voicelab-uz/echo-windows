# Echo releases with GitHub Actions

The private `voicelab-uz/echo` repository builds the application. The public
`voicelab-uz/echo-releases` repository contains immutable distribution files and
signed update feeds. CI calls the same release, publication and retention tools
used for the verified 1.0.0 launch; it does not implement a second release path.

## Everyday use

1. Merge changes to `main`. **CI** runs package tests, release/security regressions,
   localization/resource checks and an unsigned universal app build. PRs receive
   the same checks, with read-only repository access and no signing secrets.
2. Open Actions → **Prepare release** → Run workflow, selecting **main**. Enter
   a version (for example `1.0.1`), a channel and reviewed plain-text release notes.
   One nonempty line becomes one release-note item. Inputs are escaped, never
   evaluated as shell commands or accepted as arbitrary HTML.
3. After preparation succeeds, download its `echo-candidate-RUN-ATTEMPT` artifact.
   Install the DMG inside `publication/releases/TAG/`. Check sign-in, microphone,
   Fn, Accessibility, text insertion, preferences and update from the previous
   public version. Keep the Actions run ID and release tag from the summary.
4. Dispatch **Publish release** from **main**, entering that preparation run ID
   and the exact tested tag, such as `stable-1.0.1-116`. This is the deliberate
   publication action. It uploads the already tested bytes, verifies public
   downloads, updates the signed feed, applies retention, and checks the Echo
   landing page, `/echo` redirect and `/download` link.

The website already discovers public stable releases. Publication verifies that
discovery rather than deploying unrelated frontend changes. Its committed outage
fallback remains protected by the live release-protection manifest; updating that
fallback is a separate frontend change. If a website check fails after publication,
the update may already be live: fix the website/cache and retry publication.

Stable candidates contain the **stable** feed from the beginning. A test/beta DMG
cannot be converted to stable by changing a feed. To ship the same source through
another channel, prepare a new correctly configured build with a new build number.

## One-time repository setup

Use GitHub-hosted `xcode-27`, with `/Applications/Xcode_27.1.app` selected explicitly
and Python 3.13. Actions are pinned to commit SHAs. Revalidate these pins/toolchain
when upgrading. CI should fail visibly if GitHub removes the chosen Xcode; it must
not silently use another SDK. A dedicated Mac is an alternative only after adapting
cleanup and isolation; these workflows assume disposable hosted runners.
GitHub currently labels this runner image as preview, although Xcode 27.1 itself
is a release toolchain. Queue/image availability can change. Xcode 26.6 was tested
and its Swift compiler crashes during this app's optimized build; do not silently
fall back to it. The Xcode 27 project format and app code remain unchanged.
Validate another pinned toolchain before changing the runner.

The organization currently uses GitHub Free, which does not support deployment
environments for this private repository. Configure the following as **repository**
secrets/variables. Both release workflows and their orchestration code reject any
dispatch outside `main`. Repository writers must be trusted: without paid branch
protection/environments, someone able to change workflow code can also change these
guards. The current setup does not claim an enforced independent reviewer gate.

### Signing inputs

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `ECHO_SIGNING_P12_BASE64` | Base64 Developer ID **Application** identity export including its private key |
| Secret | `ECHO_SIGNING_P12_PASSWORD` | Password protecting that export |
| Secret | `ECHO_NOTARY_KEY_BASE64` | Base64 notarization API `.p8` key |
| Secret | `ECHO_PUSH_PROFILE_BASE64` | Base64 production Developer ID push provisioning profile |
| Secret | `ECHO_SPARKLE_PRIVATE_KEY` | Existing Sparkle key export text, not a newly generated key |
| Variable | `ECHO_NOTARY_KEY_ID` | Notarization API key ID |
| Variable | `ECHO_NOTARY_ISSUER` | Notarization API issuer UUID |
| Variable | `ECHO_SIGNING_IDENTITY` | Developer ID identity SHA-1; current identity is the workflow default |

Use `gh secret set --repo voicelab-uz/echo` with file/stdin
input; never put private values in commands, logs, issues or chat. Base64 is an
encoding, not encryption. GitHub Secrets protects the stored values. Never upload
the production backend's APNs provider key: app signing needs only the provisioning
profile. The notarization key and APNs provider key have different purposes.

The setup script uses a temporary Keychain and owner-only files outside the
checkout. P12/notary source files are removed after import; the Keychain, Sparkle
key and profile are removed in an `always()` cleanup step. A terminated hosted VM
is discarded. Recovery artifacts include signed products/provisioning metadata,
not the Keychain, private keys or secret environment files.

### Publishing access

Create a dedicated GitHub App installed **only** on `echo-releases`
with **Contents: read and write**. Set `ECHO_RELEASE_APP_ID` as a repository Actions
variable and its private key as `ECHO_RELEASE_APP_PRIVATE_KEY`. The workflow mints
a short-lived installation token after validating the candidate, then revokes it
using the action's post step. Preparation also checks publisher access with a
separate token and a read-only repository request; it never publishes anything. No source-repository write access is needed.

These workflows require this scoped GitHub App rather than a personal token.
GitHub checks the requested Contents write permission while minting the token;
preflight checks its installation repository list contains only `echo-releases`.
The user-oriented `permissions.push` field is not present for App tokens.

After upgrading to a plan that supports the needed private-repository protections,
move signing inputs to an `echo-signing` environment and publishing access to an
`echo-production` environment, restrict both to main, add the workflow environment
fields, and configure required reviewers where supported. The separate dispatch and exact-tag
confirmation remain the publication boundary for the current setup. Never add signing secrets
to the ordinary CI workflow or use `pull_request_target` to execute PR code.

## Ordering and recovery

The private `echo-release-builds` branch stores a compare-and-swap ledger. It takes
the maximum of the permanent high-water mark and all release tags, then reserves
one new build for the Actions run. The launch floor is 115. Versions may change;
build numbers never reset. The most recent 256 retry records are retained, without
release-note text. An expired retry fails rather than allocating a different build.

Preparation and publication each serialize their runs. Publication also uses the
existing cross-tool repository operation lock and signed-feed compare-and-swap.
An older candidate is rejected after a newer build has reached any channel.

- **Notarization timeout:** Re-run failed jobs within three days. The workflow
  downloads the prior attempt's checkpoint, keeps the same build and resumes saved
  Apple submission IDs. Never rebuild an already submitted archive with that number.
- **Archive/export interrupted midway:** The existing script deliberately refuses
  to overwrite partial signed work. Inspect the checkpoint or start a new preparation
  run, which reserves a new number. No public release has changed.
- **Unknown Apple submission result:** Use the saved submission records and Apple's
  history/info to reconcile it. Do not blindly resubmit; see `CDN_RELEASE.md`.
- **No checkpoint/expired checkpoint:** Start a new preparation run. A rerun refuses
  to silently create different bytes for its old build number.
- **Upload failure:** Retry the same Publish run. Matching existing draft/assets are
  reused; different bytes are rejected. Public files are never overwritten.
- **Feed propagation:** Publication retries the known pending-CDN state. If it still
  fails, rerun the same Publish run later; the release/feed may already be committed.
- **Stale candidate feed:** Prepare a new candidate after another publication. Do
  not force a feed overwrite or alter the tested publication manifest.
- **Bad public release:** Prepare the known-good source changes as a new commit on
  main and a higher build number. Removing an artifact or decreasing a version does
  not safely undo an already installed update.

Private candidate artifacts expire after 14 days; recovery after three days; audit
artifacts after 30 days; failed CI logs after seven days. Public retention uses
`release-retention-policy.json`: three stable and one each beta/test, a grace period,
and protected website/feed references. A failed cleanup does not delete live files.

## Validation limits

Automated tests cover counters, CAS conflicts, retry reconciliation, source/run
provenance, signatures, tampering, retention and both binary architectures. They do
not prove physical Intel compatibility or exercise real human voice, Fn hardware,
Touch ID, OAuth consent, every macOS permission state, disk exhaustion or power loss.
Keep a release checklist on real Macs. App Store distribution requires a separate
signing/sandbox/review workflow; it must not publish this Developer ID DMG unchanged.

References: [GitHub macOS signing](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
[deployment environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
[Sparkle](https://sparkle-project.org/documentation/).
