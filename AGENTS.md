# SystemPermissions development

Rust owns permission descriptors, metadata, validation, operation results and deterministic state. Native adapters own OS calls, callbacks and scheduling. Hosts choose requirements, prompt timing, explanations and recovery UI. Unsupported and unknown are not denial or success. Apple Events permissions are scoped to a target application. No automatic requests, privilege elevation or security changes.

Use Git on main and GitHub-hosted CI without private dependency credentials. Preserve published pins, host data, live QA and original/sealed evidence. The old permissions-kit GitHub repository must remain unchanged.

Package.swift, Cargo.toml, sdk-tooling.toml, the Rust C ABI and native provenance own package/build contracts. Keep bindings, tests and README aligned. Test OS effects only in owned isolated fixtures. Report local tests, native runtime, CI and product integration separately. No new app/site publication. Use English maintained docs and comments.
