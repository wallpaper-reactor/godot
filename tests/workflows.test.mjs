import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

// CI: every action pinned by commit, the matrix read from slices.json, and a release that publishes a checked run's
// bytes rather than rebuilding them.
const engine = join(dirname(fileURLToPath(import.meta.url)), '..');
const dir = join(engine, '.github/workflows');
const workflows = Object.fromEntries(readdirSync(dir).map((f) => [f, readFileSync(join(dir, f), 'utf8')]));

test('every action is pinned by a full commit SHA', () => {
	for (const [name, text] of Object.entries(workflows)) {
		for (const [, ref] of text.matchAll(/uses: ([^\s#]+)/g)) assert.match(ref, /^[\w-]+\/[\w-]+@[0-9a-f]{40}$/, `${name}: ${ref}`);
	}
});

test('the build matrix is slices.json, and every binary is attested', () => {
	const build = workflows['build.yml'];
	assert.match(build, /json\.load\(open\("slices\.json"\)\)/);
	assert.match(build, /matrix: \$\{\{ fromJSON\(needs\.slices\.outputs\.matrix\) \}\}/);
	assert.match(build, /attest-build-provenance@[0-9a-f]{40}[^\n]*\n\s+with:\n\s+subject-path: \$\{\{ runner\.temp \}\}\/out\/\$\{\{ matrix\.asset \}\}/);
	assert.match(build, /run: scripts\/build\.sh "\$\{\{ matrix\.slice \}\}"/);
});

test('the hardening check runs on the Linux and macOS slices, with their assets from slices.json', () => {
	const { slices } = JSON.parse(readFileSync(join(engine, 'slices.json'), 'utf8'));
	const build = workflows['build.yml'];
	for (const slice of ['linux', 'macos']) {
		const s = slices[slice];
		assert.ok(build.includes(`{ slice: ${slice}, asset: ${s.asset}, runner: ${s.runner} }`), slice);
	}
	assert.match(build, /check\/check-hardening\.sh "\$RUNNER_TEMP\/engine\/\$\{\{ matrix\.asset \}\}"/);
});

test('a release publishes one successful Build run of main, verified, and never replaces a release', () => {
	const release = workflows['release.yml'];
	assert.doesNotMatch(release, /build\.sh/, 'nothing is rebuilt');
	assert.match(release, /\$name" == Build && "\$conclusion" == success && "\$branch" == main/);
	assert.match(release, /sha256sum -c "\$asset\.sha256"/);
	assert.match(release, /gh attestation verify "\$f" --repo "\$GITHUB_REPOSITORY"/);
	assert.match(release, /releases are never replaced/);
	assert.doesNotMatch(release, /--clobber|gh release (delete|edit|upload)/);
});

test('only the release workflow can write', () => {
	assert.match(workflows['build.yml'], /^permissions:\n {2}contents: read$/m);
	assert.doesNotMatch(workflows['build.yml'], /contents: write/);
	assert.match(workflows['release.yml'], /^on:\n {2}workflow_dispatch:/m);
});
