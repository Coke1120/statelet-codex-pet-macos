# Third-party notices

Statelet is a macOS lifecycle companion for Codex distributed under the MIT
license. The repository uses or interoperates with the following third-party
software. Each component remains subject to its own license.

## Runtime and build components

- Apple macOS SDK, AppKit, AVFoundation, Swift, Xcode command-line tools,
  `avconvert`, and `codesign` are provided under Apple's applicable license
  terms. They are not redistributed by this repository.
- Python is provided under the Python Software Foundation License. The local
  lifecycle publisher uses the Python standard library.
- NumPy is available under the BSD 3-Clause License. The hash-locked alpha
  authoring environment uses NumPy 2.0.2.
- Pillow is available under the HPND License. The hash-locked alpha authoring
  environment uses Pillow 11.3.0.
- FFmpeg and FFprobe are user-installed tools. Their license depends on the
  selected build and enabled components; common builds are licensed under the
  LGPL and may include GPL components. Statelet does not bundle them.

## Automation

GitHub Actions workflows use `actions/checkout` and `actions/setup-python`, each
under its upstream license. These actions are CI tooling and are not shipped in
the Statelet application.

No third-party animation media is included. Contributors are responsible for
confirming that any media they use or distribute is authorized for that use.
