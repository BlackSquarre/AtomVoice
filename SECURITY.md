# Security Policy

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security problems.

Email the maintainer (address listed on the maintainer's GitHub profile) with a subject prefixed by `[SECURITY]`. Include:

- A clear description of the issue and its impact
- Reproduction steps (or a proof-of-concept) if you have them
- Affected AtomVoice version and macOS version
- Whether you intend to publish details, and on what timeline

You will get a first response **within 14 days**.

## Supported Versions

Only the latest published release receives security fixes. Beta and Debug builds follow the same release cadence; previous versions are not back-patched.

## In Scope

The following are explicitly in scope for a security report:

- Any local or remote app extracting API keys that AtomVoice stores (LLM, Doubao, future credentials)
- AtomVoice unexpectedly uploading captured audio or recognized text to any network destination
- User settings, Keychain entries, or update artifacts being modifiable by another unprivileged app on the same machine
- Any path that bypasses the existing SHA256 + code signature checks during in-app updates
- Local privilege escalation enabled by AtomVoice components (helper tools, daemons, login items)

## Out of Scope

The following are not considered vulnerabilities under this policy:

- Issues that require **physical access** to an unlocked Mac
- Leaks of API keys the user voluntarily entered into LLM or Doubao settings (key management is the user's responsibility once provisioned)
- Security or privacy properties of third-party ASR / LLM services AtomVoice can be configured to call (e.g., OpenAI, Anthropic, Volcengine/Doubao). Report those upstream.
- Bugs in the on-device Sherpa-ONNX runtime or ONNX Runtime itself — please report upstream and reference the bundled version
- Denial-of-service from supplying obviously malicious local input (very large strings, etc.) when no privilege is gained

## Coordinated Disclosure

- We aim to acknowledge within 14 days and ship a fix within **90 days** of the initial report.
- A public security issue will be opened **30 days after** the fix ships in a release, summarizing the impact and the reporter (with consent).
- If you need to publish earlier (regulatory deadline, conference talk), tell us in the first email and we'll coordinate.

## What We Do Not Do

- We do **not** participate in CVE numbering for this project at this time.
- We do **not** offer bug bounties.
- We do **not** use GitHub Security Advisories as the primary intake channel — email is faster for a project this size.
