# Building pi from source

This guide builds a standalone `pi` binary from the upstream repository
(<https://github.com/earendil-works/pi>) on your own machine, with one patch applied: the
**long working-directory fix**. It is driven by one script, [`build-pi.sh`](build-pi.sh), which
needs nothing else from this repository. You can copy the file anywhere and run it.

## Why the patch

Pi names its session directory after the working directory, turning every `/` into `-` and
putting the whole result in a single directory name. A working directory of roughly 250
characters or more produces a name over the 255-byte filename limit of Linux and macOS, so
`mkdir` fails with `ENAMETOOLONG` and pi cannot start.

The patch (see `./build-pi.sh --print-patch`) keeps names of 200 bytes or less exactly as they
were, so existing sessions are unaffected. Longer names keep their deepest directories and gain
a hash of the full path, so different long paths never collide. As of upstream v1.0.0 the bug is
still present; check before assuming it still is.

## Quick start

```bash
curl -fsSLO https://raw.githubusercontent.com/n0tbhargav/pi/qcom-lite/qcom/build-pi.sh
chmod +x build-pi.sh
./build-pi.sh --check        # what this machine has, and what it can reach
./build-pi.sh                # build the newest upstream release for this machine
```

The result is in `./pi-build/out/`:

```
pi-linux-x64.tar.gz     the build (the name carries the platform)
SHA256SUMS
```

Install it:

```bash
cd pi-build/out && sha256sum -c SHA256SUMS
sudo tar -xzf pi-linux-x64.tar.gz -C /opt        # creates /opt/pi/
sudo ln -s /opt/pi/pi /usr/local/bin/pi
pi --version
```

Keep the whole `/opt/pi/` directory together. The binary needs the files next to it (theme,
assets, a wasm module, docs and native helpers); copying only the `pi` file will not work.

## What you need

The script installs Node and Bun itself into its work directory when the machine lacks them.
Nothing is installed system-wide and no root access is needed.

| Item | Needed | Notes |
|---|---|---|
| OS and CPU | Linux or macOS, x86-64 or arm64 | Windows: use WSL. |
| `git`, `tar`, `gzip` | yes | On a minimal SLES image: `zypper install git tar gzip unzip`. |
| `curl` or `wget` | yes | |
| `unzip` or `python3` | yes, if the script downloads Bun | Used to unpack Bun's zip archive. |
| Node.js | 22.19.0 or newer | Upstream's `engines` requirement. The script installs **22.20.0**, which is what we tested. |
| npm | any that ships with Node 22 | |
| Bun | **exactly 1.3.14** | The version upstream's release CI pins. A different version is replaced, not used. |
| Disk | about 1.1 GB | Measured: 566 MB source and `node_modules`, 293 MB toolchain, 151 MB build output. |
| Memory | 5 GB was enough | Tested with a 5 GB container limit. |
| Time | about 1.5 minutes | Measured on an x86-64 build under emulation, with a warm network. |

A C compiler is **not** needed. Dependencies are installed with `npm ci --ignore-scripts`, and the
native helper libraries pi uses ship pre-built inside the upstream repository.

## What it connects to

| Host | Used for | Needed when |
|---|---|---|
| `github.com` | cloning the source; downloading Bun | always |
| `registry.npmjs.org` | `npm ci` | always |
| `nodejs.org` | downloading Node | only if Node 22.19+ is not installed |
| `models.dev`, `openrouter.ai`, `ai-gateway.vercel.sh`, `integrate.api.nvidia.com` | the model catalog, fetched at build time | unless you pass `--model-data` |

**The model-catalog step matters.** Upstream does not commit its model list. The build fetches it
from the four hosts above and, in strict mode, fails if any of them is unreachable. This is the
most likely failure on a company network. See "Restricted networks".

Cross-compiling (building a platform other than the machine's own) makes Bun download the target
runtime while compiling. We saw that happen for an arm64-to-x64 build and did not see it for a
build whose target matched the machine. We did not record which host it contacted; if you
cross-compile on a restricted network, expect to need `github.com` (Bun's releases live there).

## Options

| Option | Meaning |
|---|---|
| `--ref <tag\|branch\|sha>` | What to build. Default: the newest `vX.Y.Z` release tag. |
| `--repo <url>` | Git URL to clone. Default: upstream. Use this for an internal mirror (or `PI_REPO_URL`). |
| `--platform <name>` | `linux-x64`, `linux-arm64`, `darwin-x64` or `darwin-arm64`. Default: this machine. |
| `--workdir <dir>` | Clone, toolchain and build directory. Default: `./pi-build` (or `PI_BUILD_DIR`). |
| `--out <dir>` | Where the tarball and `SHA256SUMS` go. Default: `<workdir>/out`. |
| `--model-data <path>` | Use pre-fetched model data (a `.tar.gz` from `--export-model-data`, or a directory). |
| `--export-model-data <file>` | After fetching model data, save it as a `.tar.gz`. |
| `--no-cwd-fix` | Build plain upstream, without the patch. |
| `--no-install-toolchain` | Never download Node or Bun; fail if the machine lacks them. |
| `--no-smoke-test` | Do not run the built binary afterwards. |
| `--check` | Report tool versions and network reachability, then exit. Writes nothing. |
| `--print-patch` | Print the embedded patch and exit. |

Environment variables: `NODE_VERSION` (22.20.0), `BUN_VERSION` (1.3.14), `NODE_DIST_BASE`
(`https://nodejs.org/dist`), `BUN_RELEASE_BASE` (`https://github.com/oven-sh/bun/releases/download`),
`PI_REPO_URL`, `PI_BUILD_DIR`, and the usual `HTTPS_PROXY`, `NPM_CONFIG_REGISTRY`.

## Restricted networks

Choose the pattern that matches what your network allows.

**1. Everything is allowed.** Run the script. Nothing else to do.

**2. Only some hosts are allowed.** Run `./build-pi.sh --check`. It lists every host as reachable
or not. Ask for the missing ones to be allowed, or use pattern 3 for the model-catalog hosts.

**3. The model-catalog hosts are blocked, but GitHub and npm work.** Fetch the model data once
on a machine that can reach those hosts, then carry the small file (about 57 KB) across:

```bash
# On a machine with open access:
./build-pi.sh --ref v1.0.0 --export-model-data model-data.tar.gz

# On the restricted machine, building the same ref:
./build-pi.sh --ref v1.0.0 --model-data model-data.tar.gz
```

The data must come from the **same ref** you build; data from another version fails validation
with a message saying so.

**4. Only internal mirrors are reachable.** Point the script at them:

```bash
export NPM_CONFIG_REGISTRY=https://npm.mirror.example.com/
export NODE_DIST_BASE=https://mirror.example.com/nodejs/dist          # must mirror nodejs.org/dist
export BUN_RELEASE_BASE=https://mirror.example.com/bun/releases/download   # must mirror github.com/oven-sh/bun
./build-pi.sh --repo https://git.example.com/mirrors/pi.git --model-data model-data.tar.gz
```

Or install Node 22.19+ and Bun 1.3.14 yourself and add `--no-install-toolchain`.

**Proxies.** `git`, `curl` and `npm` honor `HTTPS_PROXY`. The model-catalog step runs inside
Node, whose built-in `fetch` does not read proxy variables by default. If your only route out is
a proxy, use pattern 3. (Newer Node 22 releases have an opt-in `NODE_USE_ENV_PROXY=1`; we did not
test it.)

## What the script does

1. Detects the platform and checks for `git`, `tar`, `gzip`, `curl`/`wget`.
2. Checks network reachability and prints it.
3. Installs Node and Bun into `<workdir>/toolchain` if the machine's are missing or wrong.
4. Clones the repository into `<workdir>/src` (or updates an existing clone) and checks out the ref.
5. Applies the session-directory patch. If the files changed upstream so that it no longer
   applies, the script stops and says so; re-run with `--no-cwd-fix`. If the source already has
   the change, it says so and moves on.
6. `npm ci --ignore-scripts`.
7. Fetches model data (or unpacks yours), then validates it with `npm run check:model-data`.
8. Runs upstream's `scripts/build-binaries.sh --skip-install --offline-model-data --platform <p>`.
9. Repacks the result into `pi-<platform>.tar.gz` with `SHA256SUMS`. The repacking removes macOS
   file metadata that otherwise makes GNU tar print hundreds of
   `Ignoring unknown extended header keyword 'LIBARCHIVE.xattr...'` lines on Linux.
10. If the build target is this machine's platform, runs the binary and starts it from a
    344-character directory to confirm the fix works.

### The same thing by hand

```bash
git clone https://github.com/earendil-works/pi.git && cd pi
git checkout v1.0.0
./path/to/build-pi.sh --print-patch | git apply          # optional: the cwd fix
npm ci --ignore-scripts
npm run hydrate:model-data && npm run check:model-data   # or unpack your model-data into packages/ai/src/providers/data/
./scripts/build-binaries.sh --skip-install --offline-model-data --platform linux-x64 --out ./out
# the archive is ./out/pi-linux-x64.tar.gz
```

This needs Node 22.19+ and Bun 1.3.14 on your `PATH`.

## Updating to a new upstream release

```bash
./build-pi.sh                 # picks up the newest release tag automatically
./build-pi.sh --ref v1.1.0    # or name one
```

The script reuses `<workdir>/src`, fetches new tags, and resets to a clean checkout. To pin a
release for reproducible builds, always pass `--ref`. Upstream test and lint suites are not run;
the script builds and smoke-tests only.

## Installing for a team

Install once under `/opt/pi` (see "Quick start"). To share extensions from one directory instead of each user's
home, put them in e.g. `/opt/pi-shared/extensions/` (root-owned, writable only by trusted
maintainers, because extensions run with each user's permissions), then use exactly **one** of:

- each user's `~/.pi/agent/settings.json`: `{ "extensions": ["/opt/pi-shared/extensions"] }`
- a launcher script that passes `-e <file>` for every file in that directory
- a shared read-only agent directory: `PI_CODING_AGENT_DIR=/opt/pi-shared/agent`, plus
  `PI_CODING_AGENT_SESSION_DIR=$HOME/.pi-sessions` per user

Combining mechanisms loads an extension twice and renames its commands (`name:1`, `name:2`).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Need Node >= 22.19.0 on PATH` | You passed `--no-install-toolchain`. Install Node 22.19+, or drop the flag. |
| `Cannot clone ...` | Wrong URL, no network, or a proxy/credential problem. Try `git ls-remote <url>` by hand. |
| Model data fetch fails, `UNREACHABLE` in the report | Use "Restricted networks", pattern 3. |
| `Model data failed validation` | The data came from a different ref. Export it again from a build of the same ref. |
| `The embedded patch does not apply` | Upstream changed those files. Re-run with `--no-cwd-fix`, and check whether upstream already fixed the bug. |
| `npm warn EBADENGINE` lines | Harmless: a few optional dev dependencies declare newer engines than Node 22. |
| macOS: the binary is killed immediately (exit 137) | Unsigned binary. Run `codesign --force -s - <path>/pi`. The script's smoke test does this itself. |
| `ENAMETOOLONG` when starting pi | You are running an unpatched build, or a build made with `--no-cwd-fix`. |
| `pi` fails after being copied elsewhere | Copy the whole `pi/` directory, not just the executable. |

## What was tested

Tested, using this script against upstream **v1.0.0**:

- A complete default build inside a clean **SLES 15 SP4** container on arm64, and another on
  x86-64 under emulation (about 1.5 minutes): Node and Bun auto-installed, build, packaging,
  smoke test, and the 344-character directory check, which passed with a 200-byte session
  directory name.
- A cross-build for linux-x64 from the arm64 machine, using exported model data and an existing
  clone (26 seconds). That x64 artifact was then extracted and run on x86-64 SLES 15 SP4:
  checksum matched, no tar warnings, correct version, and the long-directory check passed.
- `--check` on a bare image, `--no-install-toolchain` with nothing installed, a bad repository URL,
  a different upstream ref (the patch applied to v0.87.1 too), and a model-data mismatch.

Not tested: macOS and Windows hosts, behind a proxy or on air-gapped networks (patterns 3 and 4
are described, not exercised), any ref other than v1.0.0 and v0.87.1, and running the full
upstream test suite as part of this script.
