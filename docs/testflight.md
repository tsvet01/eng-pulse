# TestFlight

Ship Eng Pulse (`org.tsvetkov.eng-pulse`, team `9XQ7BW6Q4T`) from GitHub without a Mac. The **TestFlight** workflow (`.github/workflows/testflight.yml`) runs only when someone starts it from the Actions tab. It does not run on pull requests or on pushes. Only people with write access can start it. Fork pull requests cannot read these secrets.

A green run means App Store Connect accepted the package. The upload is a TestFlight build and does not start App Store review. TestFlight still spends a few minutes processing before the build appears.

## What the run does

The job uses a GitHub-hosted `macos-latest` runner, the same image as the existing simulator tests.

1. It writes the ignored `Secrets.xcconfig` and the CI Firebase placeholder for that run. Pilot builds do not initialize Firebase. The files are not uploaded as artifacts, because the archive's Info.plist contains the publishable key and any Cloud TTS key.
2. It sets the archived push entitlement to `production`. Distribution profiles reject `development`.
3. It archives the `EngPulse` scheme in **Release** for a generic iOS device. The archive is unsigned. A development profile would need a registered device, and the runner has none.
4. It exports with App Store Connect API automatic signing and uploads the result. `CFBundleShortVersionString` stays `1.0` (`MARKETING_VERSION`). `CFBundleVersion` is the build number below. The app declares `ITSAppUsesNonExemptEncryption` false: it uses HTTPS and CryptoKit SHA-256 only.

Signing uses `-allowProvisioningUpdates` and the API key. Xcode creates or reuses an Apple Distribution certificate and an App Store provisioning profile on Apple's side. There is no `.p12` and no `.mobileprovision` secret, and nothing to export from Keychain. That is the path that works on a runner with no Apple login.

The committed entitlements stay `development` for local device builds. The workflow edits that file on the runner after checkout.

## Secrets

Add these under **Settings → Secrets and variables → Actions → Repository secrets**. Use the names exactly. Put them on the repository, not in the `production` environment. This workflow does not use an environment. Do not commit any of them.

| Secret | Required | Where it comes from |
|---|---|---|
| `APP_STORE_CONNECT_API_KEY_ID` | yes | App Store Connect API key |
| `APP_STORE_CONNECT_ISSUER_ID` | yes | App Store Connect API page |
| `APP_STORE_CONNECT_API_KEY` | yes | The downloaded `.p8` |
| `SUPABASE_PUBLISHABLE_KEY` | yes | Supabase API settings |
| `GOOGLE_CLOUD_TTS_API_KEY` | no | Google Cloud TTS key |

### APP_STORE_CONNECT_API_KEY_ID

### APP_STORE_CONNECT_ISSUER_ID

### APP_STORE_CONNECT_API_KEY

Create these three together. The API key is created in App Store Connect, not in the Apple Developer portal.

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com) as an Account Holder or Admin on team `9XQ7BW6Q4T`.
2. Open **Users and Access → Integrations → App Store Connect API**.
3. Copy the **Issuer ID** at the top of that page. That value is `APP_STORE_CONNECT_ISSUER_ID`.
4. Click **Generate API Key** (or **+**). Name it `eng-pulse-testflight`. Access: **Admin**.
5. Download the `.p8` immediately. Apple offers that file once. The Key ID is the 10-character value in the table and in the filename `AuthKey_<KeyID>.p8`. That value is `APP_STORE_CONNECT_API_KEY_ID`.
6. `APP_STORE_CONNECT_API_KEY` is the whole file, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines. GitHub keeps the line breaks. A base64 encoding of the same file also works.

The key needs the **Admin** role so the first run can create the distribution certificate. An App Manager key can upload later, but it cannot create that certificate. This key is not the push key already stored as `APNS_KEY_BASE64`. Do not reuse it.

### SUPABASE_PUBLISHABLE_KEY

In the Supabase project `zimjnykjqsxwsidwmemd`, open **Project Settings → API Keys** and copy the public publishable key. Use that key, never the service-role key, the SMTP password, or a signing secret. The TestFlight build cannot sign in without it. It is the same value as the local `Secrets.xcconfig` entry. The workflow accepts letters, digits, `.`, `_`, and `-`.

### GOOGLE_CLOUD_TTS_API_KEY

Optional. Leave the secret unset to ship without Cloud Text-to-Speech. On-device speech still works. To enable Cloud TTS, use the same API key as the local `GOOGLE_CLOUD_TTS_API_KEY` in `Secrets.xcconfig` (Cloud Text-to-Speech enabled on the GCP project). The value is restricted to letters, digits, `.`, `_`, and `-`.

## Apple Developer portal

The portal does not mint the API key. It does have to allow the profile Xcode creates.

1. Open [Identifiers](https://developer.apple.com/account/resources/identifiers/list) and select `org.tsvetkov.eng-pulse`.
2. Confirm **Sign in with Apple** and **Push Notifications** are enabled. Both were registered on 2026-10-14.
3. `com.apple.developer.carplay-audio` is restricted. Apple has to grant it. Until that grant is on the App ID, leave **Include the CarPlay audio entitlement** off when you start the workflow. With it on, export fails because the profile cannot contain the entitlement. The phone app still installs and runs; CarPlay does not connect. See the open item in [phase 0 setup](runbooks/phase0-setup.md#pilot-app-identity).
4. Do not create a distribution certificate or a provisioning profile by hand. If export reports that the account is at its Apple Distribution certificate limit, revoke an unused one in **Certificates** and run the workflow again.

Also create the app record before the first run. In App Store Connect, **Apps → + → New App**:

- Platforms: iOS
- Name: Eng Pulse
- Primary language: English
- Bundle ID: `org.tsvetkov.eng-pulse`
- SKU: `eng-pulse`
- User access: Full Access

Apple does not allow changing that bundle ID after the first upload. There was no app record on this account on 2026-10-15.

If export fails because a license agreement is pending, open App Store Connect and accept it. A free TestFlight app does not need the Paid Applications agreement.

## Run the workflow

On the default branch, after this workflow file is on `main`: **Actions → TestFlight → Run workflow**.

- Branch: `main`, unless you are deliberately uploading some other commit.
- **CFBundleVersion**: leave empty. The workflow run number is the build number. It starts at 1 and increases on every dispatch. Apple rejects a number already uploaded for version `1.0`. A re-run keeps the same run number; if Apple already accepted it, type a higher integer and start the workflow again.
- **Include the CarPlay audio entitlement**: leave off until the grant above is in place.

The existing simulator CI is unchanged and does not upload anything.

## External testers and the public link

Internal testers are people with a role on the App Store Connect team. They can install from the TestFlight tab as soon as processing finishes. They do not wait for Beta App Review.

Friends who are not on the team need an external group:

1. Wait until the build appears under the app's **TestFlight** tab and processing has finished.
2. If App Store Connect still asks about encryption, answer that the app uses only exempt encryption. The build already sets `ITSAppUsesNonExemptEncryption` to false.
3. Open **TestFlight → Test Information**. Fill in the beta description, a feedback email, and a privacy policy URL if Apple asks for one. The app opens on a sign-in screen, so add a demo account the reviewer can use. A public link does not admit anyone to the engineering feed. The reviewer, and each friend, still needs an invited account that `/v1/me` accepts.
4. Open **TestFlight → External Testing** and create a group, for example `Friends`.
5. Add the processed build to that group.
6. Turn on **Public Link** and copy the `https://testflight.apple.com/join/...` URL.
7. Submit the group for review when App Store Connect asks.

**The first build you send to an external group goes through Beta App Review.** The public link does not install until that review is approved. Later builds for the same group are usually faster, and some are accepted without another full review. Tell friends they need iOS 17 or later and Apple's TestFlight app. They open the link, accept the invite, and install. An external group can hold up to 10,000 testers. Turn the public link off on the group page when you want to stop new joins.
