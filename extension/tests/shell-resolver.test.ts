/**
 * shell-resolver.test.ts — P2.M1.T1.S2: unit tests for the §17.10.2 `resolveShell()`
 * 3-branch resolution chain (`PI_NVIM_SHELL` → `$SHELL` → `/bin/bash`), the
 * `getShellInfo()` cache, and the `__setShellInfoForTest()` test seam.
 *
 * PATTERN: mirrors `hello-handler.test.ts`'s node:test + save/restore-env-in-finally
 * shape. `process.env` is SHARED across tests in one process (bridge-env.test.ts
 * GOTCHA #6) AND `$SHELL` varies across machines, so every test saves/restores
 * `PI_NVIM_SHELL` + `SHELL` and resets the module cache via
 * `__setShellInfoForTest(undefined)` in a `finally`.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import {
	resolveShell,
	getShellInfo,
	__setShellInfoForTest,
	SHELL_MIRROR_ENV,
	type ShellInfo,
} from "../pi-nvim-bridge.ts";

// Save/restore PI_NVIM_SHELL + SHELL + the cache around every test. `resolveShell`
// is pure (reads only process.env), so the helper drives it deterministically;
// `getShellInfo` needs the cache reset so each test re-resolves from the stubbed env.
function withEnv(
	env: Partial<{ piNvimShell: string | undefined; shell: string | undefined }>,
	fn: () => void,
) {
	const savedPi = process.env[SHELL_MIRROR_ENV];
	const savedShell = process.env.SHELL;
	__setShellInfoForTest(undefined); // force re-resolution
	if (env.piNvimShell === undefined) delete process.env[SHELL_MIRROR_ENV];
	else process.env[SHELL_MIRROR_ENV] = env.piNvimShell;
	if (env.shell === undefined) delete process.env.SHELL;
	else process.env.SHELL = env.shell;
	try {
		fn();
	} finally {
		if (savedPi === undefined) delete process.env[SHELL_MIRROR_ENV];
		else process.env[SHELL_MIRROR_ENV] = savedPi;
		if (savedShell === undefined) delete process.env.SHELL;
		else process.env.SHELL = savedShell;
		__setShellInfoForTest(undefined);
	}
}

test("resolveShell: PI_NVIM_SHELL set → { shell, shellSource:'pi', shellPath }", () => {
	withEnv({ piNvimShell: "/bin/zsh", shell: "/bin/bash" }, () => {
		const r = resolveShell();
		assert.equal(r.shell, "/bin/zsh");
		assert.equal(r.shellSource, "pi");
		assert.equal(r.shellPath, "/bin/zsh");
	});
});

test("resolveShell: PI_NVIM_SHELL wins over SHELL when both set (precedence)", () => {
	withEnv({ piNvimShell: "/bin/fish", shell: "/bin/zsh" }, () => {
		assert.equal(resolveShell().shellSource, "pi");
		assert.equal(resolveShell().shell, "/bin/fish");
	});
});

test("resolveShell: only SHELL set → { shell, shellSource:'$SHELL' }, NO shellPath", () => {
	withEnv({ piNvimShell: undefined, shell: "/bin/zsh" }, () => {
		const r = resolveShell();
		assert.equal(r.shell, "/bin/zsh");
		assert.equal(r.shellSource, "$SHELL");
		assert.equal(r.shellPath, undefined, "shellPath absent in the $SHELL branch");
	});
});

test("resolveShell: neither set → { '/bin/bash', 'default' }, NO shellPath", () => {
	withEnv({ piNvimShell: undefined, shell: undefined }, () => {
		const r = resolveShell();
		assert.equal(r.shell, "/bin/bash");
		assert.equal(r.shellSource, "default");
		assert.equal(r.shellPath, undefined, "shellPath absent in the default branch");
	});
});

test("getShellInfo caches: 2nd call returns the SAME object (resolveShell runs once)", () => {
	withEnv({ piNvimShell: "/bin/zsh" }, () => {
		const a = getShellInfo();
		const b = getShellInfo();
		assert.equal(a, b, "same reference — cached, no re-resolution");
		assert.equal(a.shellSource, "pi");
	});
});

test("__setShellInfoForTest overrides the cache; undefined resets", () => {
	withEnv({ piNvimShell: "/bin/zsh" }, () => {
		const injected: ShellInfo = {
			shell: "/custom/sh",
			shellSource: "pi",
			shellPath: "/custom/sh",
		};
		__setShellInfoForTest(injected);
		assert.equal(getShellInfo(), injected, "seam overrides resolution");
		__setShellInfoForTest(undefined); // reset → next call re-resolves from env
		assert.equal(getShellInfo().shell, "/bin/zsh", "reset re-resolves from PI_NVIM_SHELL");
	});
});