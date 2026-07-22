/**
 * jsonl-reader.ts — strict JSONL framing for the pi-nvim-bridge IPC socket.
 *
 * This module is a VERBATIM LOGIC MIRROR of pi's own authoritative framing module
 * `packages/coding-agent/src/modes/rpc/jsonl.ts` (compiled: `dist/modes/rpc/jsonl.js`),
 * designated the framing mirror by PRD §16 ("RPC framing reference") and by the
 * `extension/protocol.ts` module-level JSDoc ("the authoritative framing mirror is
 * pi's own dist/modes/rpc/jsonl.js ... IMPLEMENTED by the JSONL reader task (S7)").
 *
 * Framing rules (PRD §5.2): exactly one JSON object per line, delimited by `\n` ONLY.
 * An optional trailing `\r` is stripped (CRLF tolerance). Do NOT use readers that split
 * on U+2028 / U+2029 — those are valid INSIDE JSON strings (JSON.stringify does not
 * escape them) and would corrupt payloads. Both sides must buffer partial lines and
 * decode on `\n`.
 *
 * STATUS (P1.M2.T4.S7): framing half of parent task P1.M2.T4 ("JSONL framing &
 * connection handling"). The reader is built + unit-tested HERE; the connection
 * half (attach to a net.Socket, JSON.parse, narrow envelopes, dispatch, write
 * responses, handle socket error/close) is S8. This module is dead code (imported
 * nowhere) until S8 — by design, so the framing logic is tested in isolation.
 *
 * Node builtins only (PRD §6.7 "no npm runtime dependencies"). No module state.
 */

import type { Readable } from "node:stream";
import { StringDecoder } from "node:string_decoder";

/**
 * Serialize a single strict JSONL record: `${JSON.stringify(value)}\n`.
 *
 * `JSON.stringify` does NOT escape U+2028 / U+2029 — they appear literally in the
 * payload, which is precisely WHY the reader must split on `\n` only (see
 * {@link attachJsonlLineReader}). The trailing `\n` is the record terminator.
 *
 * S8 uses this to write JSON-RPC responses: `sock.write(serializeJsonLine(response))`.
 *
 * STATUS (P1.M2.T4.S7): faithful companion to the reader (shipped together because the
 * PRD §16 mirror file ships both, and because framing — not connection-handling — is
 * S7's lane; S8 consumes it).
 */
export function serializeJsonLine(value: unknown): string {
	return `${JSON.stringify(value)}\n`;
}

/**
 * Attach an LF-only JSONL line reader to a `Readable` stream (a `net.Socket` IS a
 * `Readable` — `Socket extends Duplex extends Readable` — so S8 passes the socket
 * directly: `attachJsonlLineReader(sock, handleLine)`).
 *
 * For each COMPLETE line (terminated by `\n`), `onLine` is invoked with the line as a
 * raw `string`, with a single optional trailing `\r` stripped. Incomplete trailing
 * data is buffered across `data` events; a final line lacking a trailing `\n` is
 * emitted when the stream emits `'end'`. The returned function detaches the reader
 * (removes its `data`/`end` listeners) — call it on socket close/error to avoid a
 * listener leak.
 *
 * This intentionally does NOT use Node `readline`. Readline splits on additional
 * Unicode separators (U+2028 / U+2029) that are valid inside JSON strings and
 * therefore does not implement strict JSONL framing. A `StringDecoder` reassembles
 * multi-byte UTF-8 characters split across two `Buffer` chunks (e.g. `€` = E2 82 AC
 * delivered as `[E2 82]` then `[AC]`) — without it the split would yield U+FFFD and
 * corrupt the JSON.
 *
 * The reader emits RAW `string` lines only. It does NOT `JSON.parse`, narrow to
 * JsonRpcRequest/Response/Notification, or dispatch — that is S8's job (with S15
 * error-wrapping a `JSON.parse` throw into a JSON-RPC -32700).
 *
 * STATUS (P1.M2.T4.S7): the title-named deliverable. Mirrors pi's
 * `attachJsonlLineReader` in `modes/rpc/jsonl.ts` byte-for-byte.
 *
 * @param stream any Readable (a net.Socket in S8's onConnection).
 * @param onLine called once per complete, `\r`-stripped line.
 * @returns a detach function that removes the reader's `data`/`end` listeners.
 */
export function attachJsonlLineReader(
	stream: Readable,
	onLine: (line: string) => void,
): () => void {
	const decoder = new StringDecoder("utf8");
	let buffer = "";

	const emitLine = (line: string) => {
		onLine(line.endsWith("\r") ? line.slice(0, -1) : line);
	};

	const onData = (chunk: string | Buffer) => {
		buffer += typeof chunk === "string" ? chunk : decoder.write(chunk);

		// Drain ALL complete lines in this chunk (a chunk may carry several records).
		while (true) {
			const newlineIndex = buffer.indexOf("\n"); // LF ONLY — never readline / regex.
			if (newlineIndex === -1) {
				return; // incomplete trailing line stays buffered for the next chunk
			}
			emitLine(buffer.slice(0, newlineIndex));
			buffer = buffer.slice(newlineIndex + 1); // advance past the consumed "\n"
		}
	};

	const onEnd = () => {
		buffer += decoder.end(); // flush any multi-byte bytes StringDecoder held back
		if (buffer.length > 0) {
			emitLine(buffer); // a final line without a trailing "\n"
			buffer = "";
		}
	};

	stream.on("data", onData);
	stream.on("end", onEnd);

	// Detach: remove THIS reader's listeners (identity-equal closures). S8 calls this
	// from sock.on("error")/sock.on("close"). Does NOT touch other listeners.
	return () => {
		stream.off("data", onData);
		stream.off("end", onEnd);
	};
}
