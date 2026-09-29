/** Longest session directory name, in UTF-8 bytes. Filesystems cap one path component at 255 bytes. */
const MAX_SESSION_DIR_NAME_BYTES = 200;
const HASH_SUFFIX = 16;

const encoder = new TextEncoder();

/** Two independent 32-bit FNV-1a hashes of the input, as 16 hex characters. */
function hashCwd(value: string): string {
	let a = 0x811c9dc5;
	let b = 0x01000193;
	for (const byte of encoder.encode(value)) {
		a = Math.imul(a ^ byte, 0x01000193) >>> 0;
		b = Math.imul(b ^ byte, 0x85ebca6b) >>> 0;
	}
	return a.toString(16).padStart(8, "0") + b.toString(16).padStart(8, "0");
}

/** Keep the trailing `maxBytes` bytes of `value` without splitting a code point. */
function tailByBytes(value: string, maxBytes: number): string {
	const chars = Array.from(value);
	let bytes = 0;
	let start = chars.length;
	while (start > 0) {
		const size = encoder.encode(chars[start - 1]).length;
		if (bytes + size > maxBytes) break;
		bytes += size;
		start--;
	}
	return chars.slice(start).join("");
}

/**
 * Encode a cwd as one safe directory name under the sessions directory.
 *
 * Short paths keep the historical `--<path-with-dashes>--` form, so existing sessions still resolve.
 * A path whose encoded name would exceed the filesystem's component limit keeps its deepest
 * directories and gains a hash of the full path, which keeps distinct long paths from colliding.
 */
export function encodeSessionDirName(cwd: string): string {
	const readable = cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-");
	const full = `--${readable}--`;
	if (encoder.encode(full).length <= MAX_SESSION_DIR_NAME_BYTES) return full;
	const budget = MAX_SESSION_DIR_NAME_BYTES - "--".length - "-".length - HASH_SUFFIX - "--".length;
	return `--${tailByBytes(readable, budget)}-${hashCwd(cwd)}--`;
}
