# Validation scope

Public-checkout source checks rerun: October 19, 2026, on an Apple silicon Mac running macOS 27.0.1. The Store candidate is version 1.0, build 24. This is development evidence, not App Store approval or a compatibility guarantee.

| Check | Result |
| --- | --- |
| Swift direct configuration | 158 tests passed in 23 suites |
| Swift Store compilation conditions | 156 tests passed in 22 suites |
| Store source readiness | Passed |
| Bundled editor source/dependency/output integrity | Passed |
| Tiptap editor and host bridge | 9 tests passed |
| Universal Store archive and export | Succeeded locally; signing materials are excluded from this repository |
| Store entitlement allowlist | Five expected entitlements; no temporary sandbox exceptions |
| Store binary preference adapter exclusion | Native screenshot preference adapter and domain absent |
| Synthetic demo UI | Compact Capture button, guide and neutral microphone Continue inspected |
| Capture permission denial | Recovery guidance appears; notes and existing captures remain available |
| Region selector and Escape | Opened after approved screen access; Escape canceled without adding an item |
| Completed build-24 physical region capture | Pending; automation could not drag inside the borderless selector |
| Intel / macOS 26 physical testing | Pending |

A previous Store archive was tested with generated speech playing through a real system-audio tap. Recognized passages were saved and survived relaunch. This does not establish every Zoom/Meet setup, audio route, speech language, or older OS behavior.

Physical UI results above were recorded October 18. Automated tests were rerun from the cleaned public checkout on October 19. Private release evidence and device recordings are excluded from the repository.

The automated suites cover repository safety, migration preservation, screenshot arrival/cancellation/refusal, watcher acknowledgments, routing retirement and stale flags, note documents, editor integration boundaries, preview edits and drag representations, permission wording, audio buffer lifetime, presentation timing, and workspace placement. Mocked lifecycle tests do not substitute for real capture-device checks.

## Reproduce

```sh
./scripts/test.sh
./scripts/test.sh --scratch-path build/store-tests -Xswiftc -DCANOPY_APP_STORE
python3 scripts/check-store-readiness.py
cd EditorWeb && npm ci --ignore-scripts && npm test
```

For physical testing, use synthetic images and generated speech, explicit permission grants, and a disposable library. Check region selection, correct pixels, shelf arrival, Escape, discard, drag/drop, Preview edits, multiple displays, permission refusal/recovery, live audio activity, transcript finalization and relaunch persistence. Do not record unrelated apps or real meetings for a bug report.
