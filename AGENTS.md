# Repository Guidelines

- This is a fork of CodexBar; the product is **Usage Bar** in `UsageBar/`. Root `Sources/`, `Tests/`, and `Scripts/` are inherited CodexBar code and not part of Usage Bar.
- After any change: `make -C UsageBar check test`, then `make -C UsageBar install` (quits the old app, installs, relaunches). Never leave the old build running.
- Verify UI on the live desktop by finding menu bar items and controls by accessibility name, never by screen position.
- Style: explicit `self`; `@Observable` with `@State`/`@Bindable`; Swift Testing names in backticked sentences; only released or fictitious model names in code and tests.
- Never trigger macOS Keychain prompts. Keep each provider's identity and plan data out of other providers' UI.
- Commit messages: short imperative clauses.
