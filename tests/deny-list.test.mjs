import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

// native-deny-list.json is the one copy of the methods the engine never binds; the C++ header the bind-path hook in
// patches/harden.patch includes is generated from it.
const engine = join(dirname(fileURLToPath(import.meta.url)), '..');
const list = JSON.parse(readFileSync(join(engine, 'native-deny-list.json'), 'utf8'));
const pairs = Object.entries(list.methods).flatMap(([cls, methods]) => methods.map((m) => `${cls}::${m}`));

function generate(listPath) {
	const dir = mkdtempSync(join(tmpdir(), 'wr-deny-header-'));
	try {
		const out = join(dir, 'wr_native_deny_list.gen.h');
		const args = [join(engine, 'scripts/deny-header.py'), out, ...(listPath ? ['--list', listPath] : [])];
		const run = spawnSync('python3', args, { encoding: 'utf8' });
		return { status: run.status, stderr: run.stderr, header: run.status === 0 ? readFileSync(out, 'utf8') : '' };
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

test('the list names identifiers, each once', () => {
	assert.ok(pairs.length > 0);
	assert.equal(new Set(pairs).size, pairs.length);
	for (const pair of pairs) assert.match(pair, /^[A-Za-z][A-Za-z0-9]*::[a-z_][a-z0-9_]*$/);
});

test('the generated header denies exactly the list', () => {
	const { status, stderr, header } = generate();
	assert.equal(status, 0, stderr);
	const entries = [...header.matchAll(/\{"([^"]+)", "([^"]+)"\}/g)].map((m) => `${m[1]}::${m[2]}`);
	assert.deepEqual(entries.sort(), [...pairs].sort());
});

test('the header carries the list digest, the marker a built engine is checked for', () => {
	const digest = spawnSync('sha256sum', [join(engine, 'native-deny-list.json')], { encoding: 'utf8' }).stdout.split(' ')[0];
	assert.match(generate().header, new RegExp(`"WR_NATIVE_DENY_LIST_SHA256=${digest}"`));
});

test('a name that is not an identifier is refused, not written into C++', () => {
	const dir = mkdtempSync(join(tmpdir(), 'wr-deny-bad-'));
	try {
		const bad = join(dir, 'list.json');
		spawnSync('bash', ['-c', `printf '%s' '{"methods":{"OS":["execute\\"); system(\\"x"]}}' > "${bad}"`]);
		const { status, stderr } = generate(bad);
		assert.notEqual(status, 0);
		assert.match(stderr, /not an identifier/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
