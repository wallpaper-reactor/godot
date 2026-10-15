import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

// scripts/prepare.sh turns a Godot checkout into the hardened source: the pinned commit, the patches, the generated
// deny-list header, and nothing else. Run here against a fixture engine directory (a copy of the real scripts with
// its own godot.env and patches) and a fixture checkout, so no Godot source is needed.
const engine = join(dirname(fileURLToPath(import.meta.url)), '..');
// Every GIT_* variable is dropped: a hook's GIT_DIR would point the fixture's git at another repository.
const ownEnv = () => Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('GIT_')));
const ident = { GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' };
const git = (cwd, ...args) => spawnSync('git', args, { cwd, encoding: 'utf8', env: { ...ownEnv(), ...ident } });

const HARDEN = `diff --git a/core/object/a.txt b/core/object/a.txt
--- a/core/object/a.txt
+++ b/core/object/a.txt
@@ -1 +1,2 @@
 stock a
+hardened a
`;
const EXTRA = `diff --git a/platform/b.txt b/platform/b.txt
--- a/platform/b.txt
+++ b/platform/b.txt
@@ -1 +1,2 @@
 stock b
+extra b
`;

/** A fixture: `dir/engine` (the scripts, a godot.env pinning the checkout's commit) and `dir/godot` (the checkout). */
function fixture({ pin } = {}) {
	const dir = mkdtempSync(join(tmpdir(), 'wr-engine-prepare-'));
	const src = join(dir, 'godot');
	mkdirSync(join(src, 'core/object'), { recursive: true });
	mkdirSync(join(src, 'platform'), { recursive: true });
	writeFileSync(join(src, 'core/object/a.txt'), 'stock a\n');
	writeFileSync(join(src, 'platform/b.txt'), 'stock b\n');
	git(src, 'init', '-q', '-b', 'main');
	// Fail safe: commit nothing unless git agrees the fixture is its own repository.
	const gitDir = git(src, 'rev-parse', '--absolute-git-dir').stdout.trim();
	if (gitDir !== join(realpathSync(src), '.git')) throw new Error(`the fixture resolved to ${gitDir}, not its own repository`);
	git(src, 'add', '-A');
	git(src, 'commit', '-q', '-m', 'stock');
	const commit = git(src, 'rev-parse', 'HEAD').stdout.trim();

	const eng = join(dir, 'engine');
	for (const f of ['scripts/prepare.sh', 'scripts/deny-header.py', 'native-deny-list.json']) {
		mkdirSync(dirname(join(eng, f)), { recursive: true });
		copyFileSync(join(engine, f), join(eng, f));
	}
	mkdirSync(join(eng, 'patches'));
	writeFileSync(join(eng, 'patches/harden.patch'), HARDEN);
	writeFileSync(join(eng, 'patches/extra.patch'), EXTRA);
	writeFileSync(join(eng, 'godot.env'), `GODOT_TAG=fixture\nGODOT_COMMIT=${pin ?? commit}\nSCONS_VERSION=0\n`);
	return { dir, src, eng, commit };
}

const prepare = (f, ...extra) =>
	spawnSync('bash', [join(f.eng, 'scripts/prepare.sh'), f.src, ...extra], { encoding: 'utf8', env: ownEnv() });
const read = (f, p) => readFileSync(join(f.src, p), 'utf8');

function withFixture(opts, body) {
	const f = fixture(opts);
	try {
		body(f);
	} finally {
		rmSync(f.dir, { recursive: true, force: true });
	}
}

test('refuses a checkout at any commit but the pinned one, and changes nothing', () => {
	withFixture({ pin: 'f'.repeat(40) }, (f) => {
		const r = prepare(f);
		assert.notEqual(r.status, 0, r.stdout);
		assert.match(r.stderr, new RegExp(`pinned ${'f'.repeat(40)}`));
		assert.equal(read(f, 'core/object/a.txt'), 'stock a\n');
		assert.ok(!existsSync(join(f.src, 'core/object/wr_native_deny_list.gen.h')));
	});
});

test('applies harden.patch and writes the deny-list header carrying the list digest', () => {
	withFixture({}, (f) => {
		const r = prepare(f);
		assert.equal(r.status, 0, r.stderr);
		assert.equal(read(f, 'core/object/a.txt'), 'stock a\nhardened a\n');
		assert.equal(read(f, 'platform/b.txt'), 'stock b\n', 'an extra patch is applied only when named');
		const digest = spawnSync('sha256sum', [join(f.eng, 'native-deny-list.json')], { encoding: 'utf8' }).stdout.split(' ')[0];
		assert.match(read(f, 'core/object/wr_native_deny_list.gen.h'), new RegExp(`WR_NATIVE_DENY_LIST_SHA256=${digest}`));
	});
});

test('a second run takes the prepared checkout as it is', () => {
	withFixture({}, (f) => {
		assert.equal(prepare(f).status, 0);
		const r = prepare(f);
		assert.equal(r.status, 0, r.stderr);
		assert.equal(read(f, 'core/object/a.txt'), 'stock a\nhardened a\n');
	});
});

test('an extra patch is applied beside harden.patch, also to a checkout that already carries harden.patch', () => {
	withFixture({}, (f) => {
		assert.equal(prepare(f).status, 0);
		const r = prepare(f, join(f.eng, 'patches/extra.patch'));
		assert.equal(r.status, 0, r.stderr);
		assert.equal(read(f, 'core/object/a.txt'), 'stock a\nhardened a\n');
		assert.equal(read(f, 'platform/b.txt'), 'stock b\nextra b\n');
	});
});

test('any other change to a tracked file is refused', () => {
	withFixture({}, (f) => {
		writeFileSync(join(f.src, 'platform/b.txt'), 'stock b\nsomething else\n');
		const r = prepare(f);
		assert.notEqual(r.status, 0, r.stdout);
		assert.match(r.stderr, /differs from/);
	});
});

test('a patch that does not apply is named', () => {
	withFixture({}, (f) => {
		writeFileSync(join(f.src, 'core/object/a.txt'), 'moved upstream\n');
		const r = prepare(f);
		assert.notEqual(r.status, 0, r.stdout);
		assert.match(r.stderr, /harden\.patch does not apply/);
	});
});

test('a GIT_DIR in the environment does not redirect it to another repository', () => {
	withFixture({}, (f) => {
		const other = mkdtempSync(join(tmpdir(), 'wr-engine-other-'));
		try {
			git(other, 'init', '-q', '-b', 'main');
			const r = spawnSync('bash', [join(f.eng, 'scripts/prepare.sh'), f.src], {
				encoding: 'utf8',
				env: { ...ownEnv(), GIT_DIR: join(other, '.git') },
			});
			assert.equal(r.status, 0, r.stderr);
			assert.equal(read(f, 'core/object/a.txt'), 'stock a\nhardened a\n');
		} finally {
			rmSync(other, { recursive: true, force: true });
		}
	});
});

test('without a checkout it prints its usage', () => {
	const r = spawnSync('bash', [join(engine, 'scripts/prepare.sh')], { encoding: 'utf8', env: ownEnv() });
	assert.notEqual(r.status, 0);
	assert.match(r.stderr, /usage:/);
});

test('an extra patch may be named relative to the working directory', () => {
	withFixture({}, (f) => {
		const r = spawnSync('bash', [join(f.eng, 'scripts/prepare.sh'), f.src, 'patches/extra.patch'], { cwd: f.eng, encoding: 'utf8', env: ownEnv() });
		assert.equal(r.status, 0, r.stderr);
		assert.equal(read(f, 'platform/b.txt'), 'stock b\nextra b\n');
	});
});
