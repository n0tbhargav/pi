#!/usr/bin/env bash
#
# build-pi.sh - clone upstream pi and build a standalone binary tarball.
#
# Standalone: this file needs nothing from this repository. It clones upstream pi,
# optionally applies the session-directory fix below, installs a pinned Node and Bun
# into the work directory if the machine lacks them (no root, nothing system-wide),
# builds, packages, and smoke-tests.
#
#   ./build-pi.sh                         # latest upstream release, host platform
#   ./build-pi.sh --ref v1.0.0 --platform linux-x64
#   ./build-pi.sh --check                 # only report what the machine can reach
#
# See BUILD.md next to this file for the full guide. Run with --help for all options.

set -euo pipefail

# Never wait for a credential prompt: fail with a message instead.
export GIT_TERMINAL_PROMPT=0

# --------------------------------------------------------------------------- defaults
REPO_URL="${PI_REPO_URL:-https://github.com/earendil-works/pi.git}"
REF=""                                   # default: newest vX.Y.Z tag in the repo
WORKDIR="${PI_BUILD_DIR:-$PWD/pi-build}"
OUT=""                                   # default: $WORKDIR/out
PLATFORM=""                              # default: the machine this runs on
# Upstream CI builds releases with Bun 1.3.14 and Node 22. Node 22.20.0 is what we tested.
NODE_VERSION="${NODE_VERSION:-22.20.0}"
BUN_VERSION="${BUN_VERSION:-1.3.14}"
NODE_DIST_BASE="${NODE_DIST_BASE:-https://nodejs.org/dist}"
BUN_RELEASE_BASE="${BUN_RELEASE_BASE:-https://github.com/oven-sh/bun/releases/download}"
APPLY_CWD_FIX=1
MODEL_DATA=""                            # tarball or directory of pre-fetched model data
EXPORT_MODEL_DATA=""                     # write the fetched model data here
INSTALL_TOOLCHAIN=1
RUN_SMOKE=1
CHECK_ONLY=0
PRINT_PATCH=0

usage() {
	cat <<'EOF'
Usage: build-pi.sh [options]

  --ref <tag|branch|sha>     Upstream ref to build. Default: newest vX.Y.Z release tag.
  --repo <url>               Git URL to clone. Default: https://github.com/earendil-works/pi.git
                             (env PI_REPO_URL). Use this for an internal mirror.
  --platform <name>          linux-x64 | linux-arm64 | darwin-x64 | darwin-arm64.
                             Default: this machine. Other platforms cross-compile.
  --workdir <dir>            Where to clone, install tools and build. Default: ./pi-build
                             (env PI_BUILD_DIR).
  --out <dir>                Where the tarball and SHA256SUMS go. Default: <workdir>/out
  --model-data <path>        Use pre-fetched model data (a .tar.gz from --export-model-data, or a
                             directory) instead of fetching it. Use this on machines that cannot
                             reach models.dev / openrouter.ai.
  --export-model-data <file> After fetching model data, save it as a .tar.gz for other machines.
  --no-cwd-fix               Do not apply the session-directory-name patch built into this script.
  --no-install-toolchain     Never download Node/Bun; fail if the machine lacks suitable ones.
  --no-smoke-test            Skip running the built binary.
  --check                    Print tool versions and network reachability, then exit.
  --print-patch              Print the embedded session-directory patch to stdout and exit.
  -h, --help                 This help.

Environment: NODE_VERSION (22.20.0), BUN_VERSION (1.3.14), NODE_DIST_BASE, BUN_RELEASE_BASE,
PI_REPO_URL, PI_BUILD_DIR, plus the usual HTTPS_PROXY / NPM_CONFIG_REGISTRY.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--ref) REF="${2:?--ref needs a value}"; shift 2 ;;
	--repo) REPO_URL="${2:?--repo needs a value}"; shift 2 ;;
	--platform) PLATFORM="${2:?--platform needs a value}"; shift 2 ;;
	--workdir) WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
	--out) OUT="${2:?--out needs a value}"; shift 2 ;;
	--model-data) MODEL_DATA="${2:?--model-data needs a value}"; shift 2 ;;
	--export-model-data) EXPORT_MODEL_DATA="${2:?--export-model-data needs a value}"; shift 2 ;;
	--no-cwd-fix) APPLY_CWD_FIX=0; shift ;;
	--no-install-toolchain) INSTALL_TOOLCHAIN=0; shift ;;
	--no-smoke-test) RUN_SMOKE=0; shift ;;
	--check) CHECK_ONLY=1; shift ;;
	--print-patch) PRINT_PATCH=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

# --------------------------------------------------------------------------- helpers
log() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# True when version $1 >= version $2 (dotted numeric).
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

# Absolute form of a path whose parent may not exist yet (the parent is created).
abspath() {
	local parent
	parent="$(dirname "$1")"
	mkdir -p "$parent"
	(cd "$parent" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")")
}

sha256_of() {
	if have sha256sum; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

download() { # download <url> <dest>
	info "downloading $1"
	if have curl; then
		curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
	elif have wget; then
		wget -q -O "$2" "$1"
	else
		die "Need curl or wget to download $1"
	fi
}

detect_host() {
	local os arch
	case "$(uname -s)" in
	Linux) os=linux ;;
	Darwin) os=darwin ;;
	*) die "Unsupported OS $(uname -s). Use Linux or macOS (Windows builds: use WSL)." ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=x64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) die "Unsupported CPU $(uname -m)." ;;
	esac
	HOST_OS="$os"
	HOST_ARCH="$arch"
	HOST_PLATFORM="$os-$arch"
}

# Newest vX.Y.Z tag (no pre-release suffix) in the remote repository.
latest_release_tag() {
	git ls-remote --tags --refs "$REPO_URL" 'v*' |
		sed 's#.*refs/tags/##' |
		grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
		sort -V | tail -n1
}

# --------------------------------------------------------------------------- network check
check_network() {
	local need_models="$1" ok=1 host url
	log "Checking network reachability"
	local -a targets=(
		"$(printf '%s' "$REPO_URL" | sed -E 's#^(https?://[^/]+).*#\1#')"
		"https://registry.npmjs.org"
		"${NODE_DIST_BASE%/dist}"
		"$(printf '%s' "$BUN_RELEASE_BASE" | sed -E 's#^(https?://[^/]+).*#\1#')"
	)
	if [[ "$need_models" == 1 ]]; then
		targets+=("https://models.dev" "https://openrouter.ai" "https://ai-gateway.vercel.sh" "https://integrate.api.nvidia.com")
	fi
	local -a seen=()
	for url in "${targets[@]}"; do
		[[ " ${seen[*]:-} " == *" $url "* ]] && continue
		seen+=("$url")
		case "$url" in
		https://* | http://*) ;;
		*) continue ;;
		esac
		host="$url"
		if curl -sS -o /dev/null -I --connect-timeout 10 "$url" 2>/dev/null; then
			printf '    reachable    %s\n' "$host"
		else
			printf '    UNREACHABLE  %s\n' "$host"
			ok=0
		fi
	done
	if [[ "$ok" == 0 ]]; then
		warn "Some hosts are unreachable. See BUILD.md, section 'Restricted networks'."
		return 1
	fi
}

# --------------------------------------------------------------------------- toolchain
TOOLS=""

node_ok() {
	have node || return 1
	ver_ge "$(node --version | sed 's/^v//')" "22.19.0"
}

bun_ok() {
	have bun || return 1
	[[ "$(bun --version)" == "$BUN_VERSION" ]]
}

ensure_node() {
	if node_ok; then
		info "node $(node --version) (system) - ok"
		return
	fi
	[[ "$INSTALL_TOOLCHAIN" == 1 ]] || die "Need Node >= 22.19.0 on PATH (found: $(node --version 2>/dev/null || echo none))."
	local name="node-v${NODE_VERSION}-${HOST_OS}-${HOST_ARCH}"
	if [[ ! -x "$TOOLS/$name/bin/node" ]]; then
		log "Installing Node ${NODE_VERSION} into $TOOLS"
		mkdir -p "$TOOLS"
		download "$NODE_DIST_BASE/v${NODE_VERSION}/${name}.tar.gz" "$TOOLS/node.tar.gz"
		tar -xzf "$TOOLS/node.tar.gz" -C "$TOOLS"
		rm -f "$TOOLS/node.tar.gz"
	fi
	export PATH="$TOOLS/$name/bin:$PATH"
	node_ok || die "Installed Node does not satisfy >= 22.19.0."
	info "node $(node --version) ($TOOLS/$name) - ok"
}

ensure_bun() {
	if bun_ok; then
		info "bun $(bun --version) (system) - ok"
		return
	fi
	[[ "$INSTALL_TOOLCHAIN" == 1 ]] || die "Need Bun ${BUN_VERSION} on PATH (found: $(bun --version 2>/dev/null || echo none))."
	local asset
	case "$HOST_PLATFORM" in
	linux-x64) asset="bun-linux-x64-baseline" ;; # baseline runs on every x86-64 CPU
	linux-arm64) asset="bun-linux-aarch64" ;;
	darwin-x64) asset="bun-darwin-x64" ;;
	darwin-arm64) asset="bun-darwin-aarch64" ;;
	esac
	local dir="$TOOLS/bun-${BUN_VERSION}"
	if [[ ! -x "$dir/bun" ]]; then
		log "Installing Bun ${BUN_VERSION} into $TOOLS"
		mkdir -p "$dir"
		download "$BUN_RELEASE_BASE/bun-v${BUN_VERSION}/${asset}.zip" "$TOOLS/bun.zip"
		if have unzip; then
			unzip -q -o "$TOOLS/bun.zip" -d "$TOOLS/bun-unpack"
		elif have python3; then
			python3 -c "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TOOLS/bun.zip" "$TOOLS/bun-unpack"
		else
			die "Need unzip or python3 to unpack the Bun archive."
		fi
		cp "$TOOLS/bun-unpack/$asset/bun" "$dir/bun"
		chmod +x "$dir/bun"
		rm -rf "$TOOLS/bun.zip" "$TOOLS/bun-unpack"
	fi
	export PATH="$dir:$PATH"
	bun_ok || die "Installed Bun is not ${BUN_VERSION} (got $(bun --version 2>/dev/null || echo none))."
	info "bun $(bun --version) ($dir) - ok"
}

# --------------------------------------------------------------------------- source
clone_source() {
	local src="$WORKDIR/src"
	if [[ -d "$src/.git" ]]; then
		log "Updating existing clone in $src"
		git -C "$src" remote set-url origin "$REPO_URL"
		git -C "$src" fetch --tags --force origin || die "Cannot fetch from $REPO_URL (check the URL, network, proxy and credentials)."
		git -C "$src" reset --hard -q
		git -C "$src" clean -fdxq -e node_modules -e packages/ai/src/providers/data
	else
		log "Cloning $REPO_URL"
		mkdir -p "$WORKDIR"
		git clone "$REPO_URL" "$src" || die "Cannot clone $REPO_URL (check the URL, network, proxy and credentials)."
	fi
	if [[ -z "$REF" ]]; then
		REF="$(latest_release_tag)"
		[[ -n "$REF" ]] || die "Could not find a release tag in $REPO_URL. Pass --ref."
		info "newest release tag: $REF"
	fi
	git -C "$src" checkout -q --force "$REF" || die "Cannot check out $REF"
	git -C "$src" reset --hard -q
	info "building $(git -C "$src" describe --tags --always) ($(git -C "$src" rev-parse --short HEAD))"
	SRC="$src"
}

apply_cwd_fix() {
	[[ "$APPLY_CWD_FIX" == 1 ]] || { info "cwd fix: skipped (--no-cwd-fix)"; return; }
	log "Applying the session-directory fix"
	local patch="$WORKDIR/cwd-fix.patch"
	embedded_patch >"$patch"
	if git -C "$SRC" apply --check "$patch" 2>/dev/null; then
		git -C "$SRC" apply "$patch"
		info "applied: bounds the session directory name to 200 bytes"
	elif git -C "$SRC" apply --check --reverse "$patch" 2>/dev/null; then
		info "already present in this source - nothing to apply"
	else
		die "The embedded patch does not apply to $REF (upstream changed those files). Re-run with --no-cwd-fix, or update the patch."
	fi
}

# --------------------------------------------------------------------------- model data
model_data_dir() { printf '%s/packages/ai/src/providers/data' "$SRC"; }

prepare_model_data() {
	local dest
	dest="$(model_data_dir)"
	if [[ -n "$MODEL_DATA" ]]; then
		log "Using pre-fetched model data from $MODEL_DATA"
		mkdir -p "$dest"
		if [[ -d "$MODEL_DATA" ]]; then
			cp -R "$MODEL_DATA"/. "$dest"/
		else
			tar -xzf "$MODEL_DATA" -C "$dest"
		fi
	else
		log "Fetching model data (needs models.dev, openrouter.ai, ai-gateway.vercel.sh, integrate.api.nvidia.com)"
		(cd "$SRC" && npm run hydrate:model-data)
	fi
	[[ -n "$(ls -A "$dest" 2>/dev/null)" ]] || die "No model data in $dest."
	(cd "$SRC" && npm run check:model-data) ||
		die "Model data failed validation. Data must come from a build of the same upstream ref (--export-model-data from that ref)."
	if [[ -n "$EXPORT_MODEL_DATA" ]]; then
		mkdir -p "$(dirname "$EXPORT_MODEL_DATA")"
		tar -czf "$EXPORT_MODEL_DATA" -C "$dest" .
		info "saved model data to $EXPORT_MODEL_DATA"
	fi
}

# --------------------------------------------------------------------------- build
build_and_package() {
	log "Installing dependencies (npm ci, lifecycle scripts disabled)"
	(cd "$SRC" && npm ci --ignore-scripts)

	prepare_model_data

	log "Building ${PLATFORM} binary (this takes a few minutes)"
	(cd "$SRC" && ./scripts/build-binaries.sh --skip-install --offline-model-data --platform "$PLATFORM" --out "$WORKDIR/raw")

	log "Packaging"
	mkdir -p "$OUT"
	local stage="$WORKDIR/stage"
	rm -rf "$stage" && mkdir -p "$stage"
	cp -R "$WORKDIR/raw/$PLATFORM" "$stage/pi"
	local tarball="$OUT/pi-${PLATFORM}.tar.gz"
	rm -f "$tarball"
	if [[ "$(uname -s)" == "Darwin" ]]; then
		have xattr && xattr -rc "$stage/pi" || true
		COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --uid 0 --gid 0 --numeric-owner -czf "$tarball" -C "$stage" pi
	else
		tar --owner=0 --group=0 --numeric-owner -czf "$tarball" -C "$stage" pi
	fi
	(cd "$OUT" && sha256_of "pi-${PLATFORM}.tar.gz" >SHA256SUMS)
	BUILT_DIR="$WORKDIR/raw/$PLATFORM"
	TARBALL="$tarball"
}

# --------------------------------------------------------------------------- smoke test
smoke_test() {
	[[ "$RUN_SMOKE" == 1 ]] || { info "smoke test skipped"; return; }
	if [[ "$PLATFORM" != "$HOST_PLATFORM" ]]; then
		info "smoke test skipped: $PLATFORM binary cannot run on $HOST_PLATFORM"
		return
	fi
	log "Smoke test"
	local bin="$BUILT_DIR/pi" home
	home="$(mktemp -d)"
	[[ "$HOST_OS" == darwin ]] && codesign --force -s - "$bin" >/dev/null 2>&1 || true
	info "version: $(HOME="$home" "$bin" --version)"

	# A cwd whose encoded session directory name would exceed the 255-byte filename limit.
	local deep="$home/work" i seg
	seg="$(printf 'a%.0s' $(seq 1 39))"
	for i in 1 2 3 4 5 6 7 8; do deep="$deep/$seg"; done
	mkdir -p "$deep"
	info "long-cwd test: cwd is ${#deep} characters"
	if (cd "$deep" && HOME="$home" PI_OFFLINE=1 "$bin" -p "hi" </dev/null >/dev/null 2>&1; true) &&
		[[ -d "$home/.pi/agent/sessions" ]]; then
		local name longest=0
		for name in "$home/.pi/agent/sessions"/*; do
			name="$(basename "$name")"
			((${#name} > longest)) && longest=${#name}
		done
		if ((longest > 0 && longest <= 200)); then
			info "long-cwd test: ok (session directory name is $longest bytes)"
		else
			warn "long-cwd test: unexpected session directory name length: $longest"
		fi
	else
		warn "long-cwd test: pi did not start in a very long directory$([[ "$APPLY_CWD_FIX" == 0 ]] && echo ' (expected: the fix was not applied)')"
	fi
	rm -rf "$home"
}

# --------------------------------------------------------------------------- embedded patch
# Bounds the session directory name so pi starts in very long working directories.
# Names of 200 bytes or less are unchanged. Generated from the commit
# "fix(sessions): bound the session directory name for long cwds".
embedded_patch() {
	cat <<'PATCH_EOF'
diff --git a/packages/coding-agent/src/core/session-manager.ts b/packages/coding-agent/src/core/session-manager.ts
index df5281a0a..20fe6b019 100644
--- a/packages/coding-agent/src/core/session-manager.ts
+++ b/packages/coding-agent/src/core/session-manager.ts
@@ -31,6 +31,7 @@ import { createInterface } from "readline";
 import { StringDecoder } from "string_decoder";
 import { APP_NAME, getAgentDir as getDefaultAgentDir, getSessionsDir } from "../config.ts";
 import { normalizePath, resolvePath } from "../utils/paths.ts";
+import { encodeSessionDirName } from "../utils/session-dir-name.ts";
 import {
 	type BashExecutionMessage,
 	type CustomMessage,
@@ -589,7 +590,7 @@ export function buildSessionContext(
 function getDefaultSessionDirPath(cwd: string, agentDir: string = getDefaultAgentDir()): string {
 	const resolvedCwd = resolvePath(cwd);
 	const resolvedAgentDir = resolvePath(agentDir);
-	const safePath = `--${resolvedCwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
+	const safePath = encodeSessionDirName(resolvedCwd);
 	return join(resolvedAgentDir, "sessions", safePath);
 }
 
diff --git a/packages/coding-agent/src/migrations.ts b/packages/coding-agent/src/migrations.ts
index 3f02ba659..860ef5a93 100644
--- a/packages/coding-agent/src/migrations.ts
+++ b/packages/coding-agent/src/migrations.ts
@@ -7,6 +7,7 @@ import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, w
 import { dirname, join } from "path";
 import { CONFIG_DIR_NAME, getAgentDir, getBinDir } from "./config.ts";
 import { migrateKeybindingsConfig } from "./core/keybindings.ts";
+import { encodeSessionDirName } from "./utils/session-dir-name.ts";
 import { stripBom } from "./utils/text.ts";
 
 const MIGRATION_GUIDE_URL =
@@ -109,7 +110,7 @@ export function migrateSessionsFromAgentRoot(): void {
 			const cwd: string = header.cwd;
 
 			// Compute the correct session directory (same encoding as session-manager.ts)
-			const safePath = `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
+			const safePath = encodeSessionDirName(cwd);
 			const correctDir = join(agentDir, "sessions", safePath);
 
 			// Create directory if needed
diff --git a/packages/coding-agent/src/utils/session-dir-name.ts b/packages/coding-agent/src/utils/session-dir-name.ts
new file mode 100644
index 000000000..e6bdf61b8
--- /dev/null
+++ b/packages/coding-agent/src/utils/session-dir-name.ts
@@ -0,0 +1,45 @@
+/** Longest session directory name, in UTF-8 bytes. Filesystems cap one path component at 255 bytes. */
+const MAX_SESSION_DIR_NAME_BYTES = 200;
+const HASH_SUFFIX = 16;
+
+const encoder = new TextEncoder();
+
+/** Two independent 32-bit FNV-1a hashes of the input, as 16 hex characters. */
+function hashCwd(value: string): string {
+	let a = 0x811c9dc5;
+	let b = 0x01000193;
+	for (const byte of encoder.encode(value)) {
+		a = Math.imul(a ^ byte, 0x01000193) >>> 0;
+		b = Math.imul(b ^ byte, 0x85ebca6b) >>> 0;
+	}
+	return a.toString(16).padStart(8, "0") + b.toString(16).padStart(8, "0");
+}
+
+/** Keep the trailing `maxBytes` bytes of `value` without splitting a code point. */
+function tailByBytes(value: string, maxBytes: number): string {
+	const chars = Array.from(value);
+	let bytes = 0;
+	let start = chars.length;
+	while (start > 0) {
+		const size = encoder.encode(chars[start - 1]).length;
+		if (bytes + size > maxBytes) break;
+		bytes += size;
+		start--;
+	}
+	return chars.slice(start).join("");
+}
+
+/**
+ * Encode a cwd as one safe directory name under the sessions directory.
+ *
+ * Short paths keep the historical `--<path-with-dashes>--` form, so existing sessions still resolve.
+ * A path whose encoded name would exceed the filesystem's component limit keeps its deepest
+ * directories and gains a hash of the full path, which keeps distinct long paths from colliding.
+ */
+export function encodeSessionDirName(cwd: string): string {
+	const readable = cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-");
+	const full = `--${readable}--`;
+	if (encoder.encode(full).length <= MAX_SESSION_DIR_NAME_BYTES) return full;
+	const budget = MAX_SESSION_DIR_NAME_BYTES - "--".length - "-".length - HASH_SUFFIX - "--".length;
+	return `--${tailByBytes(readable, budget)}-${hashCwd(cwd)}--`;
+}
diff --git a/packages/coding-agent/test/sdk-session-manager.test.ts b/packages/coding-agent/test/sdk-session-manager.test.ts
index cf1349f51..5ec3fbc51 100644
--- a/packages/coding-agent/test/sdk-session-manager.test.ts
+++ b/packages/coding-agent/test/sdk-session-manager.test.ts
@@ -5,6 +5,7 @@ import { getModel } from "@earendil-works/pi-ai/compat";
 import { afterEach, beforeEach, describe, expect, it } from "vitest";
 import { createAgentSession } from "../src/core/sdk.ts";
 import { SessionManager } from "../src/core/session-manager.ts";
+import { encodeSessionDirName } from "../src/utils/session-dir-name.ts";
 
 describe("createAgentSession session manager defaults", () => {
 	let tempDir: string;
@@ -35,7 +36,7 @@ describe("createAgentSession session manager defaults", () => {
 			model: model!,
 		});
 
-		const safePath = `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
+		const safePath = encodeSessionDirName(cwd);
 		const expectedSessionDir = join(agentDir, "sessions", safePath);
 		const sessionDir = session.sessionManager.getSessionDir();
 		const sessionFile = session.sessionManager.getSessionFile();
diff --git a/packages/coding-agent/test/session-dir-name.test.ts b/packages/coding-agent/test/session-dir-name.test.ts
new file mode 100644
index 000000000..3727d3ca4
--- /dev/null
+++ b/packages/coding-agent/test/session-dir-name.test.ts
@@ -0,0 +1,51 @@
+import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
+import { tmpdir } from "node:os";
+import { join } from "node:path";
+import { describe, expect, it } from "vitest";
+import { encodeSessionDirName } from "../src/utils/session-dir-name.ts";
+
+const longCwd = (segments: number) =>
+	`/${Array.from({ length: segments }, (_, i) => `dir${i}`.padEnd(39, "x")).join("/")}`;
+
+describe("encodeSessionDirName", () => {
+	it("keeps the historical encoding for short paths", () => {
+		expect(encodeSessionDirName("/home/user/project")).toBe("--home-user-project--");
+		expect(encodeSessionDirName("C:\\Users\\me\\proj")).toBe("--C--Users-me-proj--");
+	});
+
+	it("stays within the 255-byte filename limit for very long paths", () => {
+		const name = encodeSessionDirName(longCwd(20));
+		expect(Buffer.byteLength(name)).toBeLessThanOrEqual(200);
+		expect(name.startsWith("--")).toBe(true);
+		expect(name.endsWith("--")).toBe(true);
+	});
+
+	it("keeps the deepest directories readable", () => {
+		expect(encodeSessionDirName(`${longCwd(20)}/leaf`)).toContain("-leaf-");
+	});
+
+	it("gives different long paths different names", () => {
+		const a = `${longCwd(20)}/a`;
+		const b = `${longCwd(20)}/b`;
+		expect(encodeSessionDirName(a)).not.toBe(encodeSessionDirName(b));
+	});
+
+	it("is deterministic", () => {
+		expect(encodeSessionDirName(longCwd(20))).toBe(encodeSessionDirName(longCwd(20)));
+	});
+
+	it("does not split multi-byte characters", () => {
+		const name = encodeSessionDirName(`/${"é".repeat(300)}`);
+		expect(Buffer.byteLength(name)).toBeLessThanOrEqual(200);
+		expect(name).not.toContain("\uFFFD");
+	});
+
+	it("can be created on the filesystem", () => {
+		const base = mkdtempSync(join(tmpdir(), "pi-dirname-"));
+		try {
+			mkdirSync(join(base, encodeSessionDirName(longCwd(20))), { recursive: true });
+		} finally {
+			rmSync(base, { recursive: true, force: true });
+		}
+	});
+});
PATCH_EOF
}

# --------------------------------------------------------------------------- main
main() {
	if [[ "$PRINT_PATCH" == 1 ]]; then embedded_patch; exit 0; fi
	detect_host
	PLATFORM="${PLATFORM:-$HOST_PLATFORM}"
	case "$PLATFORM" in
	linux-x64 | linux-arm64 | darwin-x64 | darwin-arm64) ;;
	*) die "Unsupported --platform '$PLATFORM'." ;;
	esac
	have git || die "git is required."
	have tar || die "tar is required."
	have gzip || die "gzip is required."
	have curl || have wget || die "curl or wget is required."

	local need_models=1
	[[ -n "$MODEL_DATA" ]] && need_models=0
	if [[ "$CHECK_ONLY" == 1 ]]; then
		log "Tools on PATH"
		info "git:  $(git --version)"
		info "node: $(node --version 2>/dev/null || echo 'not found') (need >= 22.19.0)"
		info "npm:  $(npm --version 2>/dev/null || echo 'not found')"
		info "bun:  $(bun --version 2>/dev/null || echo 'not found') (need ${BUN_VERSION})"
		check_network "$need_models" || exit 1
		exit 0
	fi
	WORKDIR="$(abspath "$WORKDIR")"
	OUT="$(abspath "${OUT:-$WORKDIR/out}")"
	TOOLS="$WORKDIR/toolchain"

	log "pi source build"
	info "host:      $HOST_PLATFORM"
	info "target:    $PLATFORM"
	info "repo:      $REPO_URL"
	info "workdir:   $WORKDIR"
	info "toolchain: node ${NODE_VERSION}, bun ${BUN_VERSION}"
	if ! check_network "$need_models"; then
		warn "Continuing; the build fails at the unreachable step (model data needs --model-data on such networks)."
	fi

	log "Toolchain"
	mkdir -p "$WORKDIR"
	ensure_node
	ensure_bun
	have npm || die "npm not found (it ships with Node)."

	clone_source
	apply_cwd_fix
	build_and_package
	smoke_test

	log "Done"
	info "tarball:   $TARBALL"
	info "checksums: $OUT/SHA256SUMS"
	info "install:   tar -xzf $(basename "$TARBALL") -C /opt   # then run /opt/pi/pi (keep the whole directory together)"
}

main "$@"
