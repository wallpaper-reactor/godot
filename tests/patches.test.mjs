import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

// The source changes stay few and documented: README.md's table lists every file each patch touches, with its hunk
// count, so a Godot update that grows a patch has to say why.
const engine = join(dirname(fileURLToPath(import.meta.url)), '..');
const patchNames = readdirSync(join(engine, 'patches')).filter((f) => f.endsWith('.patch')).sort();
const hunks = (text) => {
	const counts = {};
	let file;
	for (const line of text.split('\n')) {
		const d = line.match(/^diff --git a\/(\S+) /);
		if (d) file = d[1];
		else if (line.startsWith('@@ ')) counts[file] = (counts[file] ?? 0) + 1;
	}
	return counts;
};
const patched = Object.assign({}, ...patchNames.map((p) => hunks(readFileSync(join(engine, 'patches', p), 'utf8'))));
const readme = readFileSync(join(engine, 'README.md'), 'utf8');
const table = readme.split('<!-- hunks -->')[1]?.split('<!-- /hunks -->')[0] ?? '';
const documented = Object.fromEntries(
	[...table.matchAll(/^\| `([^`]+)` \| (\d+) \|/gm)].map((m) => [m[1], Number(m[2])])
);

test('there are three patches: the hardening, the macOS one and the fast movie PNG', () => {
	assert.deepEqual(patchNames, ['harden.patch', 'macos-accessory.patch', 'movie-png-fast.patch']);
});

test('the README lists every patched file with its hunk count, and nothing else', () => {
	assert.ok(table, 'README has a hunks block');
	assert.deepEqual(documented, patched);
});

test('each hunk table row says why it is not a build option', () => {
	for (const row of table.split('\n').filter((l) => l.startsWith('| `'))) {
		const cells = row.split(' | ');
		assert.equal(cells.length, 4, row);
		assert.ok(cells[2].length > 20 && cells[3].replace(/\|$/, '').trim().length > 3, row);
	}
});

test('harden.patch is template-only, includes the generated header, and decodes no object once confined', () => {
	const patch = readFileSync(join(engine, 'patches/harden.patch'), 'utf8');
	assert.match(patch, /#include "core\/object\/wr_native_deny_list\.gen\.h"/);
	assert.match(patch, /^\+\t\tp_allow_objects = false;$/m);
	// Every hunk that adds code guards it, but the one include line marshalls.cpp needs.
	for (const hunk of patch.split(/^@@ /m).slice(1)) {
		const added = hunk.split('\n').filter((l) => l.startsWith('+')).join('\n');
		if (added === '+#include "core/io/file_access.h"') continue;
		assert.match(added, /TOOLS_ENABLED/, hunk.slice(0, 200));
	}
});

test('movie-png-fast.patch is template-only and touches the movie writer alone', () => {
	const patch = readFileSync(join(engine, 'patches/movie-png-fast.patch'), 'utf8');
	assert.match(patch, /image_to_png_fast\(p_image, png_buffer\)/);
	assert.match(patch, /png_set_compression_level\(png, 1\)/);
	for (const hunk of patch.split(/^@@ /m).slice(1)) {
		const added = hunk.split('\n').filter((l) => l.startsWith('+')).join('\n');
		assert.match(hunk, /TOOLS_ENABLED/, hunk.slice(0, 200));
		assert.ok(added.length > 0);
	}
	// The stock Image::save_png path is not edited.
	assert.doesNotMatch(patch, /^diff --git a\/core\//m);
	assert.doesNotMatch(patch, /^diff --git a\/drivers\/png\/(resource_saver|image_loader)/m);
});
