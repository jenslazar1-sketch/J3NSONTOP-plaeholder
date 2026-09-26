# Public test signing key

`j3-test.keystore` signs **debug and test builds only** (CI test APKs,
`flutter run`, `scripts/build_android.sh --mode test`). It is committed on
purpose so every machine and every CI run signs test builds with the same key:
testers can install a newer test APK over an older one and keep their data.

It is **not a secret** and gives no protection:

| Store | Store type | Password | Alias | Key password | Certificate |
| --- | --- | --- | --- | --- | --- |
| `j3-test.keystore` | PKCS12 | `android` | `androiddebugkey` | `android` | `CN=Android Debug, O=Android, C=US` |

Certificate SHA-256:
`DB:B9:02:DA:EF:42:CA:97:8C:44:72:52:DF:4B:5C:27:6D:B5:3F:72:27:4F:39:28:18:31:15:65:1B:B4:23:20`

Never sign anything you distribute with it. Release builds use your own
upload key (see `docs/SIGNING.md`); the build scripts refuse a release APK
whose certificate is `CN=Android Debug`.
