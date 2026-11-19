# Light

Liquid glass sidebar, native passkeys support (see below), redesigned UI.

Because `com.apple.developer.web-browser.public-key-credential`, `com.apple.application-identifier`, and `keychain-access-groups` are restricted Apple entitlements, macOS AMFI (`amfid`) rejects ad-hoc signed builds carrying them unless the binary's `cdhash` is allowed with [**Lakr233/amfi-allow**](https://github.com/Lakr233/amfi-allow).

## Building

1. Generate the build directory and compile `chrome`:
   ```bash
   gn gen out/Release_GN_arm64
   autoninja -C out/Release_GN_arm64 chrome
   ```

2. Ad-hoc sign the built app (`out/Release_GN_arm64/Chromium.app`) with Passkeys entitlements and register its `cdhash` with `amfi-allow` (auto-installs `amfi-allow` if missing):
   ```bash
   ./sign_passkeys.sh
   ```

   You can also pass one or more `.app` bundles explicitly:
   ```bash
   ./sign_passkeys.sh --app out/Release_GN_arm64/Chromium.app
   ```

3. Launch the browser:
   ```bash
   open out/Release_GN_arm64/Chromium.app
   ```
