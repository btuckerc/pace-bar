# Security

Please [report vulnerabilities privately](https://github.com/btuckerc/pace-bar/security/advisories/new). Do not post credentials or raw account data in an issue. Include the affected commit, impact, and reproduction steps using synthetic data where possible.

Security fixes target the latest Pace Bar source on `main`. There are no separately maintained release branches.

Pace Bar reads existing provider credential files and makes authenticated requests to those providers. Settings contain paths, not copied tokens. Forecast history is stored locally with owner-only permissions and hashed account identifiers. See [data handling](PaceBar/docs/reference.md#accounts-and-data-fidelity).

The optional host API has no application-level authentication. Keep its listener on loopback and expose it only through a private network with appropriate access controls; see the [host setup](PaceBar/host/README.md).

This fork retains CodexBar history, including synthetic test tokens and publicly distributed client identifiers/configuration. These are not Pace Bar account credentials. Reviewed scanner findings are identified by exact commit/path fingerprints in `.gitleaksignore`; review new findings before committing.
