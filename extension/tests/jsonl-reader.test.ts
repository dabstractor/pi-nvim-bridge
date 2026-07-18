import { test } from "node:test";
import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { attachJsonlLineReader, serializeJsonLine } from "../jsonl-reader.ts";

// Feed `chunks` through a fresh Readable, collect complete lines, resolve on 'end'.
// Readable.from([b1, b2]) emits one 'data' per element then 'end' (auto-end).
async function feed(chunks: Array<string | Buffer>): Promise<string[]> {
	const lines: string[] = [];
	const stream = Readable.from(chunks);
	attachJsonlLineReader(stream, (line) => lines.push(line));
	await new Promise<void>((resolve) => stream.on("end", resolve));
	return lines;
}

test("serializeJsonLine: LF-terminated, preserves U+2028/U+2029, JSON.parse round-trips", () => {
	const line = serializeJsonLine({ text: "a\u2028b\u2029c" });
	assert.equal(line.endsWith("\n"), true, "record must be LF-terminated");
	assert.ok(line.includes("a\u2028b\u2029c"), "U+2028/U+2029 must appear literally (unescaped)");
	assert.deepEqual(JSON.parse(line.trim()), { text: "a\u2028b\u2029c" });
});

test("reader: single complete line", async () => {
	assert.deepEqual(await feed([Buffer.from('{"a":1}\n')]), ['{"a":1}']);
});

test("reader: multiple lines in one chunk (drain loop)", async () => {
	assert.deepEqual(
		await feed([Buffer.from('{"a":1}\n{"b":2}\n')]),
		['{"a":1}', '{"b":2}'],
	);
});

test("reader: partial line split across chunks (buffering)", async () => {
	assert.deepEqual(
		await feed([Buffer.from('{"x":"'), Buffer.from('val"}\n')]),
		['{"x":"val"}'],
	);
});

test("reader: CRLF-delimited input — trailing \\r stripped", async () => {
	const lines = await feed([Buffer.from('{"a":1}\r\n{"b":2}\r\n')]);
	assert.deepEqual(lines, ['{"a":1}', '{"b":2}']);
	assert.ok(lines.every((l) => !l.endsWith("\r")), "no emitted line may end with \\r");
});

test("reader: final line without trailing LF is flushed on 'end'", async () => {
	assert.deepEqual(await feed([Buffer.from('{"final":true}')]), ['{"final":true}']);
});

test("reader: U+2028/U+2029 inside payload are preserved (LF-only split, not readline)", async () => {
	const obj = { text: "a\u2028b\u2029c" };
	const lines = await feed([Buffer.from(serializeJsonLine(obj))]);
	assert.equal(lines.length, 1, "U+2028/U+2029 must NOT split the record");
	assert.deepEqual(JSON.parse(lines[0]), obj);
});

test("reader: a multi-byte UTF-8 char split across Buffer chunks is reassembled (StringDecoder)", async () => {
	// "€" = 0xE2 0x82 0xAC (3 bytes). Split it mid-char across two chunks.
	const record = Buffer.from('{"e":"€"}\n');
	const mid = Math.floor(record.length / 2);
	const lines = await feed([record.slice(0, mid), record.slice(mid)]);
	assert.deepEqual(lines, ['{"e":"€"}'], "no U+FFFD — StringDecoder reassembled the char");
	assert.deepEqual(JSON.parse(lines[0]), { e: "€" });
});

test("reader: empty input emits no lines and does not throw", async () => {
	assert.deepEqual(await feed([]), []);
});

test("reader: detach removes listeners and stops further emissions", async () => {
	// Two records in one stream; detach AFTER the first line is emitted. Because
	// Readable.from drains synchronously on read, we use a manually-pushed stream
	// so we can detach between chunks.
	const lines: string[] = [];
	const stream = new Readable({ read() {} });
	const detach = attachJsonlLineReader(stream, (line) => lines.push(line));
	stream.push('{"a":1}\n');
	// Allow the data listener to drain the first chunk (next tick).
	await new Promise((r) => setImmediate(r));
	detach();
	stream.push('{"b":2}\n'); // after detach, this must NOT produce a line
	await new Promise((r) => setImmediate(r));
	stream.push(null); // end
	await new Promise((r) => setImmediate(r));
	assert.deepEqual(lines, ['{"a":1}'], "no line emitted after detach");
	assert.equal(stream.listenerCount("data"), 0, "detach removed the data listener");
	assert.equal(stream.listenerCount("end"), 0, "detach removed the end listener");
});
