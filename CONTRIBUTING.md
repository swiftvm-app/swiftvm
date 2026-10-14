# Contributing to SwiftVM

Thank you for your interest in contributing to SwiftVM! This guide will help you get started.

## Getting Started

Read [docs/tech](docs/tech/README.md) first. It describes how SwiftVM is built and the lessons that shape the code.

### Prerequisites

- macOS 27 or newer, on Apple silicon
- Xcode 27 or newer
- For the QEMU that runs Windows guests, which the build scripts build the first
  time: `brew install ninja meson pkgconf glib pixman python`. Without them,
  `SWIFTVM_QEMU=-` builds the app without it

No Apple Developer account is needed, except for [USB devices](docs/tech/building.md#usb-devices).

### Setup

```bash
git clone https://github.com/swiftvm-app/swiftvm.git
cd swiftvm
```

### Running

```bash
swift run SwiftVM         # builds and opens a development copy
```

The development copy is an app of its own, **SwiftVM Dev**. It keeps its
machines in `~/Library/Application Support/SwiftVM-Dev`, so it never touches the
machines of the SwiftVM you use. See [Building](docs/tech/building.md) for the
rest.

## Development Workflow

1. Fork the repository and create a branch from `main`
2. Make your changes
3. Run checks before committing:

```bash
swift build               # must be free of warnings
scripts/test.sh           # all tests
```

4. Commit your changes, push your branch, and open a pull request

## Code Standards

- **Engine first** — logic goes in `Packages/SwiftVMKit`, with a `swiftvm` command to drive it. The interface comes last
- **Check against a real guest** — drive the running app with `swiftvm` and see that it does what you meant
- **Comments say why**, not what
- **Fix root causes**, not symptoms
- **Follow existing patterns** but suggest refactors if they improve quality
- **Security first** — no command injection, and nothing a guest can use against the Mac
- **Few dependencies** — discuss a new one before adding it
- **Keep the docs current** — when behavior changes, change the page that describes it. Docs stay high level, simple, and clear

Two rules protect your own Mac while you work:

- Never kill the app while a machine is running. Its network's address range
  stays blocked for a long time. Stop the machines, then quit.
- Keep test machines in a data folder of their own, with `SWIFTVM_HOME`.

## Checks

All PRs must pass CI, which builds the app and runs the tests on macOS 27:

```bash
scripts/build.sh --output /tmp/SwiftVM.app
scripts/test.sh
```

## Pull Request Guidelines

- Keep PRs focused on a single change
- Write a clear title and description explaining the "why"
- Ensure all checks pass before requesting review
- Link any related issues
- Say which guests you tried the change on

## Reporting Issues

- Report bugs and ideas on [GitHub Issues](https://github.com/swiftvm-app/swiftvm/issues)
- Search existing issues before creating a new one
- For bugs, see [what to include](docs/user-guide/troubleshooting.md#reporting-a-bug)

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
