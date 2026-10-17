# SwiftVM

SwiftVM is a virtual machine software for macOS 27 that lets user to boot up virtual machines in their macs.

## Testing Rules

- Only test critical paths
- Don't test obvious code, defaults, or UI details like pixels, layout, colors, and titles.
- Do not test the scripts.
- For all the test vms you make, set the password exactly `password` and username exactly `username`

## Working / Investigation / Researching

- Never only-rely on docs/, they might be outdated or in-accurate. Consider studying the codebase instead.