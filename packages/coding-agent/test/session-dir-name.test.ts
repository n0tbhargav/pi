import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { encodeSessionDirName } from "../src/utils/session-dir-name.ts";

const longCwd = (segments: number) =>
	`/${Array.from({ length: segments }, (_, i) => `dir${i}`.padEnd(39, "x")).join("/")}`;

describe("encodeSessionDirName", () => {
	it("keeps the historical encoding for short paths", () => {
		expect(encodeSessionDirName("/home/user/project")).toBe("--home-user-project--");
		expect(encodeSessionDirName("C:\\Users\\me\\proj")).toBe("--C--Users-me-proj--");
	});

	it("stays within the 255-byte filename limit for very long paths", () => {
		const name = encodeSessionDirName(longCwd(20));
		expect(Buffer.byteLength(name)).toBeLessThanOrEqual(200);
		expect(name.startsWith("--")).toBe(true);
		expect(name.endsWith("--")).toBe(true);
	});

	it("keeps the deepest directories readable", () => {
		expect(encodeSessionDirName(`${longCwd(20)}/leaf`)).toContain("-leaf-");
	});

	it("gives different long paths different names", () => {
		const a = `${longCwd(20)}/a`;
		const b = `${longCwd(20)}/b`;
		expect(encodeSessionDirName(a)).not.toBe(encodeSessionDirName(b));
	});

	it("is deterministic", () => {
		expect(encodeSessionDirName(longCwd(20))).toBe(encodeSessionDirName(longCwd(20)));
	});

	it("does not split multi-byte characters", () => {
		const name = encodeSessionDirName(`/${"é".repeat(300)}`);
		expect(Buffer.byteLength(name)).toBeLessThanOrEqual(200);
		expect(name).not.toContain("\uFFFD");
	});

	it("can be created on the filesystem", () => {
		const base = mkdtempSync(join(tmpdir(), "pi-dirname-"));
		try {
			mkdirSync(join(base, encodeSessionDirName(longCwd(20))), { recursive: true });
		} finally {
			rmSync(base, { recursive: true, force: true });
		}
	});
});
