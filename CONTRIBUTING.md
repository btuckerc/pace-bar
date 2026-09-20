# Contributing

Usage Bar is the standalone package in `UsageBar/`. The root package and its source directories belong to the retained CodexBar project.

Small fixes and focused improvements are welcome. For larger changes, open an issue first so we can agree on scope. Keep the app native, quiet, and inexpensive to run.

## Check a change

From the repository root, with Xcode 26.2 or later selected and Python 3 available:

```sh
make -C UsageBar test check package
```

Tests use synthetic data and temporary files. `check` downloads the pinned formatting/lint tools used by this repository. Do not run live provider probes as part of tests.

For a UI change, render a preview without accessing accounts:

```sh
swift run --package-path UsageBar UsageBar --render-preview /tmp/usage-bar.png
```

Describe the behavior changed and how you checked it. Include a synthetic preview for visual changes. Never attach auth files, raw provider responses, session logs, or screenshots containing private account information.

## Secret scanning

GitHub secret scanning and push protection are enabled. `.gitleaksignore` lists exact, reviewed findings inherited from CodexBar; it does not exclude directories or future commits.

To repeat the history scan with Gitleaks 8.30.1 installed:

```sh
gitleaks git . --log-opts="--all" --redact=100
```

Keep credentials, personal configuration, history exports, and diagnostic logs outside the checkout. The ignore rules are a guardrail, not a substitute for reviewing `git diff --cached`.
