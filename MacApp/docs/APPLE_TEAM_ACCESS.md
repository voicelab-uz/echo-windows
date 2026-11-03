# Apple team access for Echo developers

## Current membership and access

Team `FWCSVFT76D` was verified in Apple Developer → Membership details on
October 21, 2026. It is enrolled as **Individual**.

For this membership type, inviting someone to App Store Connect does **not** add
them to the Apple Developer Program signing team. Even an App Store Connect Admin
cannot gain Certificates, Identifiers & Profiles access through that invitation.
An invitation therefore does not make `FWCSVFT76D` available for that user's
automatic Xcode signing. Repository access is also separate from Apple access.

Source: [Apple's account roles](https://developer.apple.com/help/account/access/roles).

## Build and sign locally today

Another developer can use their own Apple Development identity for local testing.
Keep production signing on the configured release Mac until a separate release
machine is explicitly provisioned.

1. Pull the identity-alignment changes from GitHub.
2. In Xcode → Settings → Apple Accounts, add your own Apple Account. Use Manage
   Certificates to create an Apple Development certificate if one is missing.
3. Find your own team ID, then run the command below from the repository root.
   Replace `YOUR_TEAM_ID` and `YOUR_SUFFIX` with your values. These command-line
   overrides do not edit the shared Xcode project.

   ```sh
   xcodebuild -project Voicelab.xcodeproj -scheme Voicelab \
     -configuration Debug -destination 'platform=macOS' \
     -derivedDataPath build/developer \
     DEVELOPMENT_TEAM="YOUR_TEAM_ID" \
     CODE_SIGN_STYLE=Automatic \
     CODE_SIGN_IDENTITY="Apple Development" \
     PRODUCT_BUNDLE_IDENTIFIER="uz.voicelab.desktop.dev.YOUR_SUFFIX" \
     build
   ```

4. Run `build/developer/Build/Products/Debug/Echo.app` locally. Expect a separate
   preferences identity and fresh permissions. The native data/Keychain service
   still has shared storage names, so use a separate macOS test account if the
   production app is also installed. The developer reset-request mechanism only
   supports the production bundle ID; do not use it with this alternate ID.
5. Keep these personal signing overrides local. Do not distribute this build or
   use it as a production upgrade. CDN releases must still use the confirmed
   Developer ID identity, `FWCSVFT76D`, and `uz.voicelab.desktop`.

Echo requests microphone access, not Push Notifications. Remove any locally added
APNs capability instead of trying to provision it with a personal team. If the
developer's identity is missing or invalid, resolve that in their Xcode account
settings; importing a public `.cer` alone does not provide its private key.

## Grant actual Xcode team access

For ongoing team development, the Account Holder can request that Apple convert
the existing Individual membership to an **Organization** membership. Apple asks
for founder/cofounder status, the organization's D-U-N-S Number, and may request
business documents. Conversion requires Apple's review; an App Store Connect
role change cannot perform it. Ask Apple to confirm continuity of the existing
team, app identifiers, and signing assets before making release changes.

Start with [Apple's membership conversion instructions](https://developer.apple.com/help/account/membership/updating-your-account-information/).

After Apple approves the conversion:

1. Open App Store Connect → Users and Access. Select the existing developer user
   or invite a new one. Use the **Developer** role for routine development; do not
   add Admin or finance permissions merely to enable signing.
2. Grant **Access to Certificates, Identifiers & Profiles**. This resource access
   applies across the team and cannot be limited to one app; review that scope
   before saving.
3. Have the developer accept any invitation, sign in to their own Apple Account
   in Xcode, select the team, and create their own development certificate.
4. Verify a normal Debug build. Developer ID release signing and notarization
   still require their separate release credentials.

Sources: [Add and edit users](https://developer.apple.com/help/app-store-connect/manage-your-team/add-and-edit-users/),
[roles and access](https://developer.apple.com/help/account/access/roles).

## Release signing on another Mac

An authorized release machine can use the existing Developer ID identity imported
from an encrypted `.p12`, plus its own notarization Keychain profile. This is local
credential provisioning, not membership in the Apple Developer portal. The
account holder must explicitly authorize the recipient and secure transfer: the
private key allows signing software as this publisher.

Follow [the CDN release setup](CDN_RELEASE.md#one-time-signing-setup). Transfer
private material only through approved secret storage, with the `.p12` password
shared separately. Never upload private keys or passwords to GitHub or share the
Account Holder's Apple Account password/2FA codes. Team IDs, certificate
fingerprints, and the setup instructions are the shareable repository content.
