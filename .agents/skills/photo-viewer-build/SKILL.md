---
name: photo-viewer-build
description: Build, package and verify this Swift PhotoViewer application on macOS using Command Line Tools, including its local cache and Swift Testing setup.
---

# PhotoViewer build and verification

Run commands from the repository root:

```sh
./scripts/swift.sh test --disable-xctest
./scripts/build-app.sh
open dist/PhotoViewer.app
```

Use the wrapper instead of bare SwiftPM: it keeps Clang/Swift caches inside `.build`
and discovers the Swift Testing framework supplied with Command Line Tools.
XCTest is not available in the original CLT-only environment; tests use Swift Testing.

`dist/PhotoViewer.app` is locally ad-hoc signed, not notarized. Do not install global
packages, require full Xcode, or configure distribution merely to run this build.
For a clean check, run `./scripts/swift.sh package clean` before the commands above.

Read `docs/verification.md` for UI/RAW acceptance checks; record actual results and
unverified scenarios in `worklog/`. A supported-camera list is not evidence of
successful decoding of a user's RAF. Do not copy personal photo fixtures into Git.

If native GUI automation is unavailable, distinguish a successful build/signature
and process launch from a completed visual interaction check.
