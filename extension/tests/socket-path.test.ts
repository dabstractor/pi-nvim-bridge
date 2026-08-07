/**
 * socket-path.test.ts — regression tests for the AF_UNIX `sun_path` byte limit.
 *
 * BUG: `join(tmpdir(), "pi-nvim-bridge-<uuid>.sock")` measured 105 bytes under macOS's
 * per-user sandbox tmpdir (`/var/folders/xx/<26>/T`, 49 bytes). `sun_path` holds 104
 * bytes on macOS/BSD, so Node 26's libuv rejected the bind with
 * `listen EINVAL: invalid argument`; the `server.on("error")` handler then ran
 * `stopBridge()`, which deletes `PI_NVIM_BRIDGE` — every editor launched afterwards
 * inherited nothing and the plugin stayed dormant.
 *
 * PATTERN: node:test + jiti, same shape as shell-resolver.test.ts.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, basename } from "node:path";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	resolveSocketPath,
	SOCKET_PATH_MAX_BYTES,
	startBridge,
	stopBridge,
	getServer,
	getSocketPath,
} from "../pi-nvim-bridge.ts";

test("resolveSocketPath: fits the sun_path budget under the real tmpdir", () => {
	const p = resolveSocketPath();
	assert.ok(
		Buffer.byteLength(p) <= SOCKET_PATH_MAX_BYTES,
		`socket path must be <= ${SOCKET_PATH_MAX_BYTES} bytes, got ${Buffer.byteLength(p)}: ${p}`,
	);
	assert.match(basename(p), /^pi-nvim-bridge-[0-9a-f]{16}\.sock$/);
});

test("startBridge (real): binds successfully and keeps 0o600 with the shortened path", async () => {
	startBridge({} as ExtensionContext);
	const srv = getServer();
	const path = getSocketPath();
	assert.ok(srv && path);
	try {
		await once(srv!, "listening"); // would reject with EINVAL under the old path length
		assert.equal(srv!.listening, true);
		assert.ok(Buffer.byteLength(path!) <= SOCKET_PATH_MAX_BYTES);
		assert.equal(dirname(path!), tmpdir());
		if (process.platform !== "win32") {
			assert.equal(statSync(path!).mode & 0o777, 0o600);
		}
	} finally {
		stopBridge();
	}
});
