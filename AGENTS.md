# Yap build requirements

- Every Yap build (debug, local, test distribution, and release) must include the same Google desktop OAuth client from `Sources/YapCalendar/Resources/GoogleOAuth.plist`.
- Google Calendar is a normal sign-in flow. Never add developer setup, Google Cloud links, client import/replacement controls, or a fallback to developer configuration in Keychain.
- Do not make Google configuration depend on environment variables or local files outside the repository. A missing or invalid canonical resource must fail packaging. Preserve the verification in `Scripts/build-app.sh` and run the Google configuration regression tests after related changes.
- The desktop OAuth client is public application configuration. User OAuth tokens, signing keys, and server credentials must never be added to source or build artifacts.
- Use a bounded macOS caffeinate assertion for builds/UI testing when needed, checking for an existing assertion first. Product screenshots should be native full-resolution PNG window captures with shadows and alpha.
