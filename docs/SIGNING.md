# Signing

Signing proves who built an app and lets operating systems accept updates.
This project never commits signing material: keystores, `.p12`, `.pfx`,
`.mobileprovision`, `.cer` and `android/key.properties` are git-ignored, and
the workflows read them only from **GitHub repository secrets**.

> **Never paste a keystore, certificate, provisioning profile, password or
> their base64 text into a chat, an issue, a pull request, a commit or a log.**
> Enter secrets only in *Settings -> Secrets and variables -> Actions* of the
> repository (or with `gh secret set`, which prompts for the value). If a
> secret leaked, revoke/replace it (new keystore for a not-yet-published app,
> revoke the Apple/Windows certificate) and update the secret.

Where signing is used:

| Build | Signing | Installable? |
| --- | --- | --- |
| CI / Release `build_type=test` Android APK | Android debug key (`...-test-debugsigned.apk`) | Yes, for testing. Cannot be updated by the release build. |
| Release `build_type=release` Android APK/AAB | your upload/release key | Yes; AAB for Google Play |
| CI / Release `build_type=test` iOS | none (`...-ios-UNSIGNED-compile-check.zip`) | **No** |
| Release `build_type=release` iOS IPA | Apple certificate + provisioning profile | depends on export method (below) |
| Windows ZIP/installer | none, or Authenticode if a certificate is configured | Yes (SmartScreen warns when unsigned) |

Secret summary (exact names):

| Secret / variable | Used by | Required |
| --- | --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Android release | yes (release) |
| `ANDROID_KEYSTORE_PASSWORD` | Android release | yes (release) |
| `ANDROID_KEY_ALIAS` | Android release | yes (release) |
| `ANDROID_KEY_PASSWORD` | Android release | yes (release) |
| `IOS_CERTIFICATE_P12_BASE64` | iOS release | yes (release) |
| `IOS_CERTIFICATE_PASSWORD` | iOS release | yes (release) |
| `IOS_PROVISIONING_PROFILE_BASE64` | iOS release | yes (release) |
| `IOS_TEAM_ID` (secret **or** repository variable) | iOS release | yes (release) |
| `IOS_KEYCHAIN_PASSWORD` | iOS release | optional (random if empty) |
| `WINDOWS_CERTIFICATE_PFX_BASE64` | Windows release | optional |
| `WINDOWS_CERTIFICATE_PASSWORD` | Windows release | optional (required if the PFX is set) |
| `WINDOWS_TIMESTAMP_URL` (repository variable) | Windows release | optional (default `http://timestamp.digicert.com`) |

With `build_type=release`, a missing Android or iOS secret makes that job
**fail immediately and name the missing secrets** - it never silently produces
an unsigned or debug-signed "release". Pull-request and push builds (CI) never
receive any secret.

---

## Android

### 1. Create the upload/release keystore (once)

`keytool` ships with every JDK. On Windows, Android Studio's copy is at
`"C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe"`.

```powershell
keytool -genkeypair -v -storetype PKCS12 -keystore j3nsontop-release.jks `
  -alias j3nsontop -keyalg RSA -keysize 4096 -validity 10000 `
  -dname "CN=J3NSONTOP, O=J3NSONTOP, C=DE"
```

(macOS/Linux: same command with `\` instead of the backtick line breaks.)
keytool asks for the keystore password. For PKCS12 keystores the key password
is the same as the keystore password - use that value for both
`ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_PASSWORD`. The alias is
`j3nsontop` (-> `ANDROID_KEY_ALIAS`).

Show the certificate fingerprint (safe to share; useful to verify releases):
`keytool -list -v -keystore j3nsontop-release.jks -alias j3nsontop`.

### 2. Back it up - you need the same key for every update

Android only installs an update if it is signed with **the same certificate**
as the installed app. If the keystore or its password is lost:

* APKs you distribute yourself can never be updated again - users must
  uninstall (losing the app's data) and install a build signed with a new key.
* On Google Play with *Play App Signing* this file is your *upload key*; a lost
  upload key can be reset through Play Console support, but it is slow.

Keep at least two copies (e.g. a password manager attachment and an encrypted
offline USB drive) and store the passwords separately. Do not put it in the
repository, cloud-synced project folders or e-mail.

### 3. Local release builds

Create `android/key.properties` (git-ignored). Use forward slashes in the path
(backslashes are escape characters in `.properties` files); relative paths are
resolved against the `android/` folder:

```properties
storeFile=C:/Users/you/keys/j3nsontop-release.jks
storePassword=...
keyAlias=j3nsontop
keyPassword=...
```

Alternatively set the environment variables `J3_KEYSTORE_PATH`,
`J3_KEYSTORE_PASSWORD`, `J3_KEY_ALIAS`, `J3_KEY_PASSWORD` (used when
`android/key.properties` does not exist). Then run
`scripts\build_android.ps1 -Mode Release` (or `scripts/build_android.sh --mode release`).
Release mode passes `-Pj3RequireReleaseSigning=true` (the same as
`J3_REQUIRE_RELEASE_SIGNING=true`), so an incomplete configuration fails the
build with a list of the missing items.

### 4. Repository secrets for the Release workflow

Base64-encode the keystore:

* Windows PowerShell:
  `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$PWD\j3nsontop-release.jks")) | Set-Clipboard`
* macOS: `base64 -i j3nsontop-release.jks | pbcopy`
* Linux: `base64 -w0 j3nsontop-release.jks`

Add the secrets (web UI: *Settings -> Secrets and variables -> Actions -> New
repository secret*), or with the GitHub CLI (it prompts for each value):

```powershell
gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_ALIAS
gh secret set ANDROID_KEY_PASSWORD
```

The workflow decodes the keystore into the runner's temp folder, checks that
the password opens it and the alias exists, builds with
`-Pj3RequireReleaseSigning=true`, verifies with `apksigner` that the signer is
**not** the Android debug certificate, and deletes the keystore in an
`if: always()` step.

---

## iOS

An installable iOS build needs a paid **Apple Developer Program** membership
(99 USD/year), an App ID, a signing certificate with its private key (`.p12`)
and a provisioning profile. Without them the workflows only produce the
**unsigned compile check**, which cannot be installed.

### Which export method gives what

| `ios_export_method` | Xcode method | Certificate | Profile type | Who can install |
| --- | --- | --- | --- | --- |
| `development` | `debugging` | Apple Development | iOS App Development | devices whose **UDIDs are registered** in the profile |
| `ad-hoc` | `release-testing` | Apple Distribution | Ad Hoc | devices whose **UDIDs are registered** in the profile (max. 100 per device family per year) |
| `app-store` | `app-store-connect` | Apple Distribution | App Store Connect | nobody directly: upload to App Store Connect, then install via **TestFlight** or the **App Store** |
| `enterprise` | `enterprise` | Apple Distribution (In-House) | In-House | employees; requires the Apple Developer **Enterprise** Program |

So for "install on my own iPhone without the App Store", use **ad-hoc** (or
development) and register the device's UDID first. Install the IPA with Apple
Configurator or Finder/Xcode on a Mac (drag the `.ipa` onto the device), or via
an over-the-air (`itms-services`) page served over HTTPS. `app-store` IPAs are
uploaded with Apple's Transporter app or `xcrun altool` and then distributed
through TestFlight.

### 1. App ID and devices (developer.apple.com -> Certificates, IDs & Profiles)

1. *Identifiers* -> **+** -> App IDs -> App -> Bundle ID (explicit)
   `com.j3nsontop.multitool`, description "J3NSONTOP Multitool". No extra
   capabilities are needed.
2. For development/ad-hoc: *Devices* -> **+** -> add each iPhone/iPad UDID
   (on a Mac: Finder or Apple Configurator; on Windows: connect the device in
   iTunes and click the serial number until the UDID is shown).

### 2. Certificate (.p12)

On a Mac: *Keychain Access -> Certificate Assistant -> Request a Certificate
From a Certificate Authority* (save to disk) -> upload the CSR at *Certificates
-> +* choosing **Apple Distribution** (ad-hoc/app-store/enterprise) or **Apple
Development** (development) -> download and double-click the `.cer` -> in
Keychain Access (*My Certificates*) right-click the certificate -> *Export* as
`.p12` with a strong password.

Without a Mac (e.g. Git Bash / OpenSSL on Windows):

```bash
openssl req -new -newkey rsa:2048 -nodes -keyout j3-ios.key -out j3-ios.csr \
  -subj "/emailAddress=you@example.com/CN=J3NSONTOP/C=DE"
# upload j3-ios.csr on developer.apple.com, download distribution.cer, then:
openssl x509 -inform DER -in distribution.cer -out distribution.pem
openssl pkcs12 -export -legacy -inkey j3-ios.key -in distribution.pem -out j3-ios.p12
```

(`-legacy` produces the PKCS#12 encryption that every macOS `security import`
accepts; drop it if your OpenSSL does not know the option.) Delete the
unencrypted `j3-ios.key` afterwards or store it as carefully as the `.p12`.

Certificates expire after one year; renew them, create new profiles and update
the secrets.

### 3. Provisioning profile (.mobileprovision)

*Profiles -> +* -> choose the type from the table above -> App ID
`com.j3nsontop.multitool` -> the certificate from step 2 -> (development/ad
hoc) select the devices -> name it, e.g. `J3NSONTOP AdHoc` -> download.
After adding devices, edit and re-download the profile, then update the secret.

### 4. Team ID

*Membership details* on developer.apple.com: 10 characters, e.g. `ABCDE12345`.
It is not secret: store it as a repository **variable** (`IOS_TEAM_ID`) or a
secret with the same name.

### 5. Repository secrets

Base64-encode the files:

* macOS: `base64 -i j3-ios.p12 | pbcopy` and `base64 -i J3NSONTOP_AdHoc.mobileprovision | pbcopy`
* Windows PowerShell:
  `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$PWD\j3-ios.p12")) | Set-Clipboard`

```powershell
gh secret set IOS_CERTIFICATE_P12_BASE64
gh secret set IOS_CERTIFICATE_PASSWORD
gh secret set IOS_PROVISIONING_PROFILE_BASE64
gh variable set IOS_TEAM_ID --body ABCDE12345
# optional: gh secret set IOS_KEYCHAIN_PASSWORD
```

Then run the Release workflow with `platform=ios` (or `all`),
`build_type=release` and the matching `ios_export_method`. The job:
creates a temporary keychain (`create-keychain`, `set-keychain-settings -lut
21600`, `unlock-keychain`, `import` of the `.p12`, `set-key-partition-list`,
`list-keychains -d user -s`), decodes the profile and reads its UUID, Name,
TeamIdentifier and application-identifier (`security cms -D` + `PlistBuddy`),
fails if the team or bundle id do not match, the profile expired, the profile
type does not fit the export method or no keychain identity matches a
certificate in the profile, installs the profile into
`~/Library/MobileDevice/Provisioning Profiles` and
`~/Library/Developer/Xcode/UserData/Provisioning Profiles`, configures manual
signing for the Runner target only, generates `ExportOptions.plist`, runs
`flutter build ipa`, verifies the IPA (`codesign -dv --verbose=4`,
`codesign --verify --deep --strict`, embedded profile and bundle id) and finally
deletes the keychain and the installed profile (`if: always()`).

Local signed builds: [BUILD.md](BUILD.md#4-ios-build-macos-only).

---

## Windows (optional Authenticode)

Unsigned Windows builds work, but SmartScreen shows "Windows protected your
PC" for downloaded unsigned executables. Users should compare the SHA-256 of
the download with `SHA256SUMS` before choosing *More info -> Run anyway*.

To sign, provide a code signing certificate as a password-protected `.pfx`:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$PWD\codesign.pfx")) | Set-Clipboard
gh secret set WINDOWS_CERTIFICATE_PFX_BASE64
gh secret set WINDOWS_CERTIFICATE_PASSWORD
# optional: gh variable set WINDOWS_TIMESTAMP_URL --body http://timestamp.digicert.com
```

For `build_type=release`, `scripts/build_windows.ps1` then imports the
certificate into the runner's user certificate store (no password on any
command line), signs the exe and every not-yet-signed DLL with
`signtool sign /fd SHA256 /tr <RFC 3161 timestamp URL> /td SHA256`, lets Inno
Setup sign the installer and its uninstaller, verifies that
`Get-AuthenticodeSignature` reports `Valid`, and removes the certificate again.
If only one of the two secrets is set the build fails; if neither is set the
summary states "not code-signed". Test builds are never signed.

Important: since June 2023, publicly trusted code signing certificates (OV and
EV) must keep their private key on a hardware token or in a cloud HSM, so new
certificates usually cannot be exported as a `.pfx`. The PFX path works for
older exportable certificates or an internal CA. For cloud signing services
(e.g. Azure Trusted Signing, DigiCert KeyLocker, SSL.com eSigner) the signing
step in `scripts/build_windows.ps1` has to be adapted to the provider's
signtool plug-in.

The same variables work locally:
`$env:WINDOWS_CERTIFICATE_PFX_BASE64 = ...; $env:WINDOWS_CERTIFICATE_PASSWORD = ...; scripts\build_windows.ps1`.
