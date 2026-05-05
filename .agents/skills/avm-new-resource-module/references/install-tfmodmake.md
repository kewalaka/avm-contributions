# Installing tfmodmake

If `tfmodmake --help` fails, install it using one of the following options.

## Option A — pre-built release (preferred)

No Go required. Download the binary for the current platform from the [releases page](https://github.com/matt-FFFFFF/tfmodmake/releases).

Example for Linux amd64:
```bash
curl -sL https://github.com/matt-FFFFFF/tfmodmake/releases/latest/download/tfmodmake_linux_amd64.tar.gz \
  | tar -xz -C /usr/local/bin tfmodmake
chmod +x /usr/local/bin/tfmodmake
```

Common platform suffixes: `linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64`, `windows_amd64.zip`.

## Option B — build from source

Use when Go ≥ 1.21 is available but no pre-built binary suits the platform:

```bash
git clone https://github.com/matt-FFFFFF/tfmodmake.git /tmp/tfmodmake-src
cd /tmp/tfmodmake-src && go build -o /usr/local/bin/tfmodmake ./cmd/tfmodmake
```

Confirm with `tfmodmake --help` before continuing.
