# Friend-share hardening plan

## Outcome

Produce an honestly labeled, reproducible Murmure archive for friends using Apple Silicon
Macs on macOS 26. The archive, updater, onboarding, and local data must remain safe across a
fresh install and replacement update. Intel support is not claimed by this phase.

## Compatibility contract

- The modern app requires Apple Silicon (`arm64`) and macOS 26 or later.
- `Info.plist`, the packaged Mach-O, `README.md`, and generated `dist/INSTALL.md` must agree.
- A small launch policy reports a clear unsupported-Mac message in any environment where the
  binary can execute but the runtime contract is not met.
- Intel remains a separate measured investigation on the actual target Mac.

## Implementation

1. Add failing unit tests for supported/unsupported architecture and OS combinations.
2. Add a pure compatibility policy and a launch-time unsupported-Mac alert without changing
   the normal supported UI.
3. Update friend installation documentation for requirements, first-run onboarding,
   Automatic language recognition, model downloads, microphone testing, snippets,
   diagnostics, local storage, permissions, updates, and the unnotarized launch boundary.
4. Harden `make release` so it verifies the packaged architecture and minimum OS in addition
   to the existing signature, pinned requirement, version, and checksum checks.
5. Build the real share ZIP, inspect its contents, verify its checksum and signature, and
   exercise installation/update preservation using the existing tested updater contracts.
6. Run the complete test suite and recheck the installed app settings, permissions, and data.

## Safety boundaries

- Never package the operator's data folder, settings, history, audio, snippets, dictionary,
  credentials, certificates, or signing keys.
- Never claim notarization or Intel compatibility.
- Do not reset TCC, replace user data, or alter unrelated files on an external drive.
