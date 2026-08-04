# Contributing

Issues and PRs welcome. The server test suite is the gate:

    cd server && npm ci && npx vitest run

iOS/Mac changes should build with XcodeGen (`xcodegen generate` in `ios/` or
`mac/`). Screen Time entitlements require a paid Apple Developer account and a
real device — CI only covers the server.
