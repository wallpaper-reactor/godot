import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

// scripts/build.sh: what each slice is built with, read from its --dry-run (which fetches and builds nothing), and the
// pins it fetches by.
const engine = join(dirname(fileURLToPath(import.meta.url)), '..');
const script = join(engine, 'scripts/build.sh');
const { slices } = JSON.parse(readFileSync(join(engine, 'slices.json'), 'utf8'));
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('GIT_')));
const dry = (slice, ...more) => spawnSync('bash', [script, slice, '--dry-run', ...more], { encoding: 'utf8', env: { ...env, WR_GODOT_OUT: '/out' } });
const options = (slice) => {
	const r = dry(slice);
	assert.equal(r.status, 0, `${slice}: ${r.stderr}`);
	return r.stdout.split('\n').filter((l) => l.startsWith('option: ')).map((l) => l.slice('option: '.length));
};

test('the table names nine slices, each with an asset and a runner', () => {
	assert.deepEqual(Object.keys(slices), ['linux', 'web', 'windows-x86_64', 'windows-arm64', 'macos', 'android-arm64', 'android-arm32', 'android-x86_64', 'android-x86_32']);
	for (const [name, s] of Object.entries(slices)) {
		assert.match(s.asset, /^(godot_[a-z]+_[a-z_]*release_wr\.|libgodot_android\.)/, name);
		assert.match(s.runner, /^(ubuntu|macos)-\d+(\.\d+)?$/, name);
	}
	assert.equal(new Set(Object.values(slices).map((s) => s.asset)).size, 9, 'every asset name is its own');
});

test('a dry run of every slice names its output, the asset under $WR_GODOT_OUT', () => {
	for (const [name, s] of Object.entries(slices)) {
		const r = dry(name);
		assert.equal(r.status, 0, `${name}: ${r.stderr}`);
		assert.match(r.stdout, new RegExp(`^output: /out/${s.asset.replaceAll('.', '\\.')}$`, 'm'), name);
	}
});

test('every slice is a production release template with the trim: its module switches and its build profile', () => {
	const trim = spawnSync('bash', ['-c', `source "${join(engine, 'profile/trim.sh')}"; printf '%s\\n' "\${standard[@]}"`], { encoding: 'utf8' }).stdout.trim().split('\n');
	assert.ok(trim.includes('module_mono_enabled=no') && trim.includes('module_enet_enabled=no'), trim.join(' '));
	for (const name of Object.keys(slices)) {
		const o = options(name);
		for (const want of ['target=template_release', 'production=yes', `build_profile=${engine}/profile/trim.gdbuild`, ...trim]) {
			assert.ok(o.includes(want), `${name} lacks ${want}`);
		}
	}
});

test('the per-platform options: path overrides on where a host passes --main-pack, the official recipes elsewhere', () => {
	assert.ok(options('linux').includes('disable_path_overrides=no'));
	const mac = options('macos');
	for (const want of ['platform=macos', 'disable_path_overrides=no', 'ccflags=-mllvm -vectorize-slp=false']) assert.ok(mac.includes(want), want);
	assert.ok(mac.some((o) => o.startsWith('angle_libs=')), 'macOS: ANGLE is the Compatibility fallback');
	const web = options('web');
	assert.ok(web.includes('platform=web') && web.includes('threads=no'));
	for (const arch of ['x86_64', 'arm64']) {
		const win = options(`windows-${arch}`);
		for (const want of ['platform=windows', `arch=${arch}`, 'use_mingw=yes', 'use_llvm=yes']) assert.ok(win.includes(want), `${arch} ${want}`);
		assert.ok(win.some((o) => o.startsWith('angle_libs=')), `${arch}: ANGLE is the Compatibility fallback`);
		assert.ok(win.includes('linkflags=-Wl,--no-insert-timestamp'), 'no link time in the PE header: two builds give the same bytes');
		assert.ok(!win.includes('disable_path_overrides=no'), 'Windows runs its pack beside it, as the official template');
	}
	for (const arch of ['arm64', 'arm32', 'x86_64', 'x86_32']) {
		const a = options(`android-${arch}`);
		for (const want of ['platform=android', `arch=${arch}`, 'swappy=no', 'optimize=size']) assert.ok(a.includes(want), `${arch} ${want}`);
	}
});

test('extra options after -- reach scons, and come last', () => {
	const r = dry('linux', '--', 'lto=full', 'vulkan=no');
	assert.equal(r.status, 0, r.stderr);
	const o = r.stdout.split('\n').filter((l) => l.startsWith('option: '));
	assert.deepEqual(o.slice(-2), ['option: lto=full', 'option: vulkan=no']);
});

test('an unknown slice prints the usage and builds nothing', () => {
	const r = dry('riscv');
	assert.equal(r.status, 2);
	assert.match(r.stderr, /usage:/);
	assert.doesNotMatch(r.stdout, /option:/);
});

test('every download is pinned by SHA-256, and every toolchain by version', () => {
	const text = readFileSync(script, 'utf8');
	const fetches = [...text.matchAll(/^\s*fetch (\S+) (\S+) (\S+)/gm)];
	assert.ok(fetches.length >= 8, `${fetches.length} fetches`);
	for (const [, name, sha] of fetches) assert.match(sha, /^[0-9a-f]{64}$/, name);
	for (const pin of [/^EMSCRIPTEN_VERSION=\d+\.\d+\.\d+\s/m, /^EMSDK_COMMIT=[0-9a-f]{40}\s/m, /^ANDROID_NDK_VERSION=\d+\.\d+\.\d+\s/m, /^XCODE_VERSION=\d+\.\d+\s/m]) {
		assert.ok(pin.test(text), `${pin} is pinned`);
	}
	assert.ok(!/curl[^\n]*\| *(ba)?sh/.test(text), 'nothing is piped into a shell');
});

test('the desktop slices are optimised for size with full LTO (measured: no startup or fps cost)', () => {
	for (const name of ['linux', 'windows-x86_64', 'windows-arm64', 'macos']) {
		const o = options(name);
		assert.ok(o.includes('optimize=size') && o.includes('lto=full'), name);
		assert.ok(!o.includes('lto=none'), name);
	}
});

test('no slice has a RenderingDevice driver: every wallpaper runs on Compatibility (OpenGL, or ANGLE beneath it)', () => {
	for (const name of Object.keys(slices)) {
		const o = options(name);
		for (const want of ['vulkan=no', 'module_glslang_enabled=no']) assert.ok(o.includes(want), `${name} lacks ${want}`);
		assert.ok(!o.some((x) => /^(vulkan_sdk_path|mesa_libs|use_volk)=/.test(x)), `${name}: an RD driver's input`);
	}
	for (const arch of ['x86_64', 'arm64']) assert.ok(options(`windows-${arch}`).includes('d3d12=no'), arch);
	assert.ok(options('macos').includes('metal=no'));
	const text = readFileSync(script, 'utf8');
	assert.ok(!/moltenvk-osxcross|godot-nir-static/.test(text), 'no RD driver archive is fetched');
	assert.match(text, /windows-\*\|macos\)\n\s*grep -qa 'Could not initialize ANGLE OpenGL\.'/, 'a Windows or macOS output without ANGLE is refused');
});
