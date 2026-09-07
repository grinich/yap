# Security policy

Michael Grinich maintains this independent macOS application and its managed Zoom authorization service. This is a small-project secure development policy, adopted September 7, 2026. It does not assert a security certification, independent audit, or guaranteed response time.

## Report a vulnerability privately

Email **mgrinich@gmail.com** with the affected version or commit, a description, and minimal reproduction steps using accounts and data you control. Do not include access tokens, refresh tokens, meeting passcodes, or other people's recordings. Use private email for vulnerabilities; GitHub Issues are for ordinary support. Reports are reviewed on a best-effort basis, and a fix and disclosure plan will be coordinated with the reporter when possible. No paid bug bounty is offered.

The current release and managed service are the maintenance targets. Older preview builds may need an update to receive fixes. Test only with authorization; do not disrupt service, access another user's data, or test Zoom or another provider outside its rules.

## Development and release process

Changes to authentication, permissions, network requests, persistence, or distribution must include a review of their data flows and trust boundaries. Request the least privilege needed, validate URLs and untrusted inputs, keep credentials out of source and logs, and add meaningful regression coverage for changed security boundaries.

The maintainer reviews changes before release. Pull-request CI resolves locked dependencies, runs application and release checks, tests the authorization service with synthetic credentials, checks TypeScript, and validates the service bundle without deploying. The CodeQL workflow schedules Swift and JavaScript/TypeScript static analysis on pushes, pull requests, and weekly. Review successful scan results and triage new findings before release; a workflow failure or an absent scan is not a clean result. These controls do not imply that branch protection or independent two-person review is enforced.

Swift dependencies use `Package.resolved`; the authentication service uses `package-lock.json` and installs without npm lifecycle scripts in CI. The private Zoom SDK archive is checked against its committed SHA-256 lock before extraction. Review dependency and SDK updates for security advisories, provenance, and compatibility. Signing credentials and service secrets belong in the operator's protected secret stores, never in ordinary pull-request CI or the public SDK-free build.

Public application releases require the release checks, Developer ID signing, notarization, and update-signature verification described in [Releases](Documentation/Releases.md). Release and service deployment are deliberate operator actions; ordinary CI does not publish them. Review privacy documentation when data handling changes.

For a confirmed incident, the maintainer assesses affected data and users, contains the problem, rotates or revokes affected credentials when applicable, patches and validates the fix, and coordinates appropriate provider and user notices. Do not publish exploit details or sensitive incident evidence before containment. There is currently no recurring independent penetration-testing program.

See [Security evidence](Documentation/SecurityEvidence.md) for implemented controls, current validation status, and known coverage limits.
