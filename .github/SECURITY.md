# Security

## Supported versions

Only the latest release gets fixes. There is no auto-update, so check
[Releases](../../releases) before reporting something that may already be fixed.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: **Security → Report a
vulnerability** on this repository. Please do not open a public issue for
anything exploitable.

Useful in a report:

- Mandarina version (`Settings` → the DMG name, or `CFBundleShortVersionString`)
- Steps to reproduce, and the file that triggers it if it is a parser problem
- What you expected and what happened
- macOS version and whether ffmpeg and LibreOffice are installed

No bounty. I answer as fast as I can and will credit you in the release notes
if you want.

## Scope

In scope:

- `Sources/`, the app itself
- `build.sh`, `scripts/make-dmg.sh`, `.github/workflows/`

Out of scope:

- ffmpeg, LibreOffice, PDFKit, ImageIO, `sips` or macOS. Report those upstream,
  but tell me if Mandarina passes something to them unsafely.
- Anything that needs an attacker who already runs code as your user.

## What Mandarina does with your network

- **Update checks are the only traffic.** The app asks
  `api.github.com/repos/dmarttin/mandarina/releases/latest`, at most once every
  six hours and only if automatic checks are on. Installing an update downloads
  the DMG and its checksum from the same release. No telemetry, no analytics, no
  other hosts.
- Update traffic is refused unless it is HTTPS to GitHub. A download is
  installed only if its SHA-256 matches the published checksum and the Ed25519
  signature over that digest verifies against the key baked into the app.

## What Mandarina does with your files

- Conversions run on local processes and the files never leave the machine.
- It runs `sips`, `ffmpeg`, `ffprobe`, `soffice` and `osascript` as child
  processes, with argument arrays and no shell.
- It writes a log of file names to `~/Library/Logs/Mandarina.log`.
- Intermediate files for multi-hop conversions live in `$TMPDIR` and are
  removed when the job ends.
- The only TCC permission it asks for is Automation, for reading the Finder
  selection from the menu bar. The drag flow needs no permissions.

## Known limitations by design

- **Not notarized.** Builds are signed ad-hoc, so Gatekeeper refuses the first
  launch and there is no way to prove who built a download. Verify the
  `.sha256` published with each release and only download from this repository.
- **Untrusted files reach third-party parsers.** LibreOffice and ffmpeg run
  with your privileges and no sandbox. A malicious document could exploit them;
  that is the usual trade-off for a converter.
- **Rasterising is capped** at 40 megapixels and 16,384 px per side, so a
  crafted PDF or image fails with an error instead of exhausting memory.
- **The update trust root is one Ed25519 key.** The private half lives in the
  repository's `MANDARINA_UPDATE_KEY` secret; the public half is compiled into
  the app. If that secret leaks, someone could sign a malicious release. If it
  is lost, updates cannot be signed until a new key ships in a build. The
  checksum alone is not a trust anchor, since it comes from the same release.
