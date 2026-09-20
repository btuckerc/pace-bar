# Security

Please [report vulnerabilities privately](https://github.com/btuckerc/usage-bar/security/advisories/new). Do not post credentials or raw account data in an issue. Include the affected commit, impact, and reproduction steps using synthetic data where possible.

Security fixes target the latest Usage Bar source on `main`. There are no separately maintained release branches.

Usage Bar reads existing provider credential files and makes authenticated requests to those providers. Settings contain paths, not copied tokens. Forecast history is stored locally with owner-only permissions and hashed account identifiers. See [data handling](UsageBar/docs/reference.md#accounts-and-data-fidelity).

The optional host API has no application-level authentication. Keep its listener on loopback and expose it only through a private network with appropriate access controls; see the [host setup](UsageBar/host/README.md).

This fork retains CodexBar history, including synthetic test tokens and publicly distributed client identifiers/configuration. These are not Usage Bar account credentials. Reviewed scanner findings are identified by exact commit/path fingerprints in `.gitleaksignore`; new findings still fail CI.
