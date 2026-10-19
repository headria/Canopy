# Contributing to Canopy

Bug reports, focused improvements, and documentation fixes are welcome. For larger changes, open an issue first to discuss the user flow and scope.

1. Fork and clone the repository. Use the README's build instructions and your own signing identity.
2. Keep view code focused on presentation. Put platform operations behind injectable adapters and reusable policy in `CanopyCore`.
3. Use synthetic notes, screenshots, and audio for development. Demo mode uses disposable storage; do not submit real meeting contents or private captures.
4. Run the relevant Swift tests and source checks. Run `npm test` and rebuild the bundled editor if changing `EditorWeb`.
5. Describe the problem, resulting behavior, validation, and remaining limitations in your pull request. Include a synthetic UI image for visible changes when useful.

Preserve the quiet shelf, explicit recording controls, local data handling, and the distinction between direct and sandboxed distribution. Store builds must not acquire screenshot system preferences or request temporary sandbox exceptions. Permission text must describe the next action neutrally and allow refusal.

Do not commit signing keys, certificates, provisioning profiles, API credentials, personal libraries, App Review contacts, recordings, or build outputs. A distributed fork needs its own identifiers, signing configuration, support pages, and privacy disclosures. Do not reuse the maintainer's Store listing or imply it is an official release.

Contributions are made under the repository's MIT license. Preserve third-party license notices and attribute external work accurately. Treat other contributors respectfully and report security issues through the process in `SECURITY.md`.
