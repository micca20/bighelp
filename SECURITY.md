# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting or Security Advisory feature for
this repository. If that feature is unavailable, contact the maintainers through
a private channel you have already used and ask for a secure reporting path
before sending technical details.

Include:

- A concise description and expected impact
- The affected app version or commit
- Reproduction steps using local fixtures or accounts you own
- Relevant logs with credentials, tokens, identifiers, and user content removed
- A suggested mitigation, if known

Do not include real user data or secrets.

## Testing boundaries

Security research must not:

- Access accounts, devices, hosts, or data you do not own
- Target production availability
- Enumerate production users or identifiers
- Attempt social engineering
- Send unsolicited notifications
- Extract or publish credentials
- Test third-party infrastructure without its owner's authorization

Use the fixture mode and locally controlled services wherever possible.

## Scope and expectations

The latest maintained source is the supported version. This document does not
create a bug bounty or safe harbor. Agree on coordinated disclosure terms
privately before testing beyond your own environment.
