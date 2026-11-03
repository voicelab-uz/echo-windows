# Release artifact retention

Installers live in the public `voicelab-uz/echo-releases` GitHub repository, not on
the production API server. The default target is the newest **three stable**,
**one test**, and **one beta** installers, ranked by numeric build number. A change
from marketing version `2.0.0` to `1.0.0` does not change this ordering.

These are storage targets, not permission to break downloads. Retention always
keeps more releases when needed by a signed appcast, a website's current download
or static fallback, or the 24-hour publication grace period. Unknown releases,
drafts, mutable releases, incomplete metadata and unsupported assets are preserved.
The cleaner does not remove local build directories, notarization evidence,
source commits, Git tags, or installed applications.

GitHub permits deleting an entire immutable release. Individual assets cannot be
deleted or replaced, and an immutable release's tag name can never be reused even
after deletion. The cleaner deletes only whole releases by their exact numeric ID;
it never disables immutability or removes assets individually. See
[GitHub's immutable release documentation](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).

## Before enabling cleanup

1. Publish, sign and publicly verify the current appcast. The release preparer owns
   feed trimming and compatibility checks. This cleaner cannot edit or trim feeds.
2. Deploy the website protection contract at **both** origins:
   `https://echo.voicelab.uz/.well-known/echo-release-protection.json` and
   `https://voicelab.uz/.well-known/echo-release-protection.json`. Each must return
   direct HTTPS 200, `Cache-Control: no-store`, and this public shape:

   ```json
   {"schema_version":1,"repository":"voicelab-uz/echo-releases","protected_tags":["stable-1.0.0-115","stable-2.0.0-108"]}
   ```

   Tags here illustrate the planned current/fallback releases; actual responses
   must reflect verified live downloads. Both hosts' lists are protected as a
   union, in addition to every signed feed reference. An unavailable, redirected,
   cached, empty or invalid protection response stops cleanup.
3. Verify actual public downloads first, then review a deletion plan. Keep website
   deployment/rollback changes paused during apply. Before changing a static
   fallback, ensure its tag is retained; never roll a website back to a removed
   installer. A new fallback should advance by build number. The web resolver's
   outage fallback must remain included in its protection response.
4. Every publisher/pruner must use the current tooling and shared operation lock.
   Do not run older publisher scripts or manually change feeds during cleanup.
   GitHub does not offer a transaction spanning release DELETE, signed feed CAS,
   and another service's website deployment; these operator constraints matter.

## Plan, review, apply

Use the independently reviewed `ECHO_SPARKLE_PUBLIC_KEY` and `ECHO_TEAM_ID` already
configured for releases. Private signing material is not needed. Authentication
uses `gh`; the scripts do not inspect its token or keychain.

```sh
python3 scripts/release_retention.py plan \
  --policy scripts/release-retention-policy.json \
  --output /private/tmp/echo-retention-plan.json
```

Planning is read-only. It verifies signed feed bytes against GitHub's Contents API
and public raw CDN, enumerates at most 2,000 releases, and records at most 20
deletions. Each candidate includes the exact release ID/tag, every asset ID/size/
SHA-256, publication and feed hashes, source provenance, release notes and checksum
metadata. It also records feed hashes and both website protection responses'
canonical hashes. Inspect `delete`, `kept_tags` and `preserved`; the printed plan
hash is SHA-256 of canonical JSON, independent of formatting or a trailing newline.

After review and authorization of those exact candidates:

```sh
python3 scripts/release_retention.py apply /private/tmp/echo-retention-plan.json \
  --confirm-sha256 THE_PRINTED_CANONICAL_PLAN_HASH
```

Apply rechecks repository immutability, signatures, CDN convergence, website
protection, channel retention and exact release/asset identities. A plan older
than 24 hours is rejected. Before the first DELETE it commits the complete
lightweight audit to `retention/audits/<plan-hash>.json` on the artifacts repository's
`main` branch and verifies that commit. This metadata remains in Git after the DMG
and release disappear. The audit records the reviewed plan, not a claim that every
deletion completed. Each deletion is confirmed by a subsequent read.

An interrupted or ambiguous DELETE can be reconciled by applying the **same** plan:
already absent IDs are accepted only if their old tag does not resolve to a
replacement release. Remaining IDs are revalidated. Changes to any protection
snapshot stop further cleanup; prepare a new plan instead. A deleted immutable
release cannot be restored under its original tag, so publish a fresh build if an
installer must become available again.

## Automatic cleanup after publication

The normal publisher automatically uses the checked-in
`scripts/release-retention-policy.json` after every verified publication. Until
both website protection endpoints are deployed, cleanup safely defers. It acquires
the same operation lock regardless of whether cleanup is enabled:

```sh
python3 scripts/publish_github.py dist/Echo-VERSION-BUILD-publication \
  --promote
```

The publisher runs retention only after immutable assets **and the public signed
feed** have been verified. Pending raw-CDN caches never trigger cleanup. It writes
the plan to the publication directory before applying it and commits audit evidence
before deletion. An unavailable website, stale feed, verification error, or cleanup
failure prints a deferred-cleanup message and preserves the successful publication.
There is no scheduled/background job or live deletion merely from installing this
tooling. Rerun a reviewed plan or the exact publication after dependencies recover.
An operator can explicitly defer cleanup with `--skip-retention` or select a
reviewed, more conservative policy using `--retention-policy`; the minimum keep
counts and grace period cannot be reduced. Existing published test feeds retain
all nine test releases until the next signed test-feed advance trims them. The
public cleaner cannot rewrite a signed feed and will leave those releases intact.
The initial inventory was approximately 118 MiB on GitHub, not production disks;
that one-time pin is preferable to breaking already published update URLs.

## Concurrent operations and abandoned-lock recovery

Supported publishers and pruning use an atomic Git reference,
`refs/heads/echo-release-operation`, pointing to a unique operation commit. The
reference is removed when the operation exits. Publisher mutations and each
DELETE check ownership again; feed promotion retains its existing CAS check.
Lock commits contain an operation label/UUID and the existing public tree, never
credentials. The lock is deliberately **never stolen automatically by age**.

If a process or host was interrupted, inspect the lock commit and release/feed
state. Confirm the original publisher/pruner is stopped on every host and that no
upload or API operation remains active. Then explicitly clear only that reviewed
commit:

```sh
gh api repos/voicelab-uz/echo-releases/git/ref/heads/echo-release-operation
python3 scripts/release_retention.py unlock \
  --expected-commit EXACT_REVIEWED_LOCK_COMMIT --confirm-no-active-operation
```

A changed commit is refused. Never use this as a way to interrupt an active
release. Reconcile the original publication/plan after clearing an abandoned lock.
If lock cleanup itself fails after a verified publication, the publisher reports
that reconciliation is required; it does not falsely report a failed publication.

## Validation

```sh
python3 Tests/ReleaseRetentionRegression.py
python3 Tests/GitHubPublicationRegression.py
```

These tests use synthetic releases and mocked API/HTTP operations. They exercise
preserved feeds/fallbacks, numeric build ordering, pending CDN state, strict bounds,
audit-before-delete, changed protection, exact identity checks, ambiguous/partial
deletion recovery, lock exclusion and operator recovery. They send no live DELETE.
