#!/usr/bin/env node
/**
 * vloop-skill — installer for the vloop universal agent skill.
 *
 * Model (follows the agentskills.io ecosystem conventions):
 *   1. Canonical copy   -> ~/.agents/skills/vloop  (global) or .agents/skills/vloop (project)
 *      Natively scanned by: codex, cursor, gemini-cli, github-copilot, opencode,
 *      goose, crush, amp, zed, warp, cline ... (no per-host work needed).
 *   2. Symlinks         -> per-host skills dirs for hosts that do NOT scan .agents/skills
 *      (claude-code, zcode, kiro, droid/factory, antigravity, qwen, trae, windsurf).
 *   3. Own manifest     -> <canonical>/.install-manifest.json (never touches the
 *      `npx skills` CLI's ~/.agents/.skill-lock.json).
 */
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

const NAME = 'vloop';
const HOME = os.homedir();
const PKG_SKILL = path.join(__dirname, '..', 'skills', 'vloop');

// Hosts already covered by the canonical ~/.agents/skills install (do NOT symlink —
// duplicate listings confuse hosts like codex that show dupes instead of merging).
const NATIVE_AGENTS_HOSTS = [
  'codex', 'cursor', 'gemini-cli', 'github-copilot', 'opencode', 'goose', 'crush', 'amp', 'zed',
];

// Hosts that need a symlink into their own skills dir. detect: any of these
// existing dirs (relative to HOME) or binaries on PATH marks the host as installed.
const LINK_HOSTS = {
  'claude-code':     { skills: '.claude/skills',                 detectDirs: ['.claude'],                    detectBins: ['claude'] },
  'zcode':           { skills: '.zcode/skills',                  detectDirs: ['.zcode'],                     detectBins: [] },
  'kiro-cli':        { skills: '.kiro/skills',                   detectDirs: ['.kiro'],                      detectBins: ['kiro-cli'] },
  'droid':           { skills: '.factory/skills',                detectDirs: ['.factory'],                   detectBins: ['droid'] },
  'antigravity':     { skills: '.gemini/antigravity/skills',     detectDirs: ['.gemini/antigravity'],        detectBins: [] },
  'antigravity-cli': { skills: '.gemini/antigravity-cli/skills', detectDirs: ['.gemini/antigravity-cli'],    detectBins: [] },
  'qwen-code':       { skills: '.qwen/skills',                   detectDirs: ['.qwen'],                      detectBins: ['qwen'] },
  'trae':            { skills: '.trae/skills',                   detectDirs: ['.trae'],                      detectBins: [] },
  'windsurf':        { skills: '.codeium/windsurf/skills',       detectDirs: ['.codeium/windsurf'],          detectBins: [] },
};

const log = (m) => console.log(m);
const die = (m) => { console.error(`vloop-skill: ${m}`); process.exit(1); };

function which(bin) {
  const r = spawnSync(process.platform === 'win32' ? 'where' : 'which', [bin], { stdio: 'pipe' });
  return r.status === 0;
}

function detectHost(id) {
  const h = LINK_HOSTS[id];
  return h.detectDirs.some((d) => fs.existsSync(path.join(HOME, d))) || h.detectBins.some(which);
}

function copyDir(src, dst) {
  fs.rmSync(dst, { recursive: true, force: true });
  fs.mkdirSync(dst, { recursive: true });
  fs.cpSync(src, dst, { recursive: true });
}

function linkOrCopy(target, linkPath, copyMode) {
  fs.mkdirSync(path.dirname(linkPath), { recursive: true });
  let existing = null;
  try { existing = fs.lstatSync(linkPath); } catch {}
  if (existing) {
    const isOurLink = existing.isSymbolicLink() && (() => {
      try { return path.resolve(path.dirname(linkPath), fs.readlinkSync(linkPath)) === path.resolve(target); } catch { return false; }
    })();
    const manifest = fs.existsSync(path.join(linkPath, '.install-manifest.json')) ||
                     fs.existsSync(path.join(linkPath, 'SKILL.md'));
    if (isOurLink) return 'exists';
    if (!existing.isSymbolicLink() && !manifest) return 'conflict';
    fs.rmSync(linkPath, { recursive: true, force: true });
  }
  if (copyMode) { fs.cpSync(target, linkPath, { recursive: true }); return 'copied'; }
  try {
    fs.symlinkSync(target, linkPath, 'junction'); // 'junction' only affects Windows dirs
    return 'linked';
  } catch {
    fs.cpSync(target, linkPath, { recursive: true }); // no-symlink environments
    return 'copied';
  }
}

function parseArgs(argv) {
  const o = { _: [], agents: [], project: false, copy: false, yes: false, all: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--project' || a === '-p') o.project = true;
    else if (a === '--copy') o.copy = true;
    else if (a === '--all') o.all = true;
    else if (a === '-y' || a === '--yes') o.yes = true;
    else if (a === '--agent' || a === '-a') o.agents.push(argv[++i]);
    else o._.push(a);
  }
  return o;
}

function canonicalDir(project) {
  return project
    ? path.join(process.cwd(), '.agents', 'skills', NAME)
    : path.join(HOME, '.agents', 'skills', NAME);
}

function manifestPath(project) { return path.join(canonicalDir(project), '.install-manifest.json'); }

function install(o) {
  if (!fs.existsSync(path.join(PKG_SKILL, 'SKILL.md'))) die('package is broken: skills/vloop/SKILL.md missing');
  const canonical = canonicalDir(o.project);
  copyDir(PKG_SKILL, canonical);
  // scripts must stay executable after npm packing
  for (const s of ['vloop.sh', 'adapter.sh']) {
    const p = path.join(canonical, 'scripts', s);
    if (fs.existsSync(p)) fs.chmodSync(p, 0o755);
  }
  log(`canonical  ${canonical}`);
  log(`  covers natively: ${NATIVE_AGENTS_HOSTS.join(', ')} (via ${o.project ? '.agents/skills' : '~/.agents/skills'})`);

  let targets;
  if (o.all) targets = Object.keys(LINK_HOSTS);
  else if (o.agents.length) {
    for (const a of o.agents) if (!LINK_HOSTS[a] && !NATIVE_AGENTS_HOSTS.includes(a)) die(`unknown agent '${a}'. known: ${[...NATIVE_AGENTS_HOSTS, ...Object.keys(LINK_HOSTS)].join(', ')}`);
    targets = o.agents.filter((a) => LINK_HOSTS[a]);
  } else targets = Object.keys(LINK_HOSTS).filter(detectHost);

  const links = [];
  for (const id of targets) {
    const base = o.project && id === 'claude-code'
      ? path.join(process.cwd(), '.claude', 'skills') // project scope: only claude needs a project link
      : path.join(HOME, LINK_HOSTS[id].skills);
    if (o.project && id !== 'claude-code') continue;
    const linkPath = path.join(base, NAME);
    const st = linkOrCopy(canonical, linkPath, o.copy);
    if (st === 'conflict') { log(`  SKIP ${id}: ${linkPath} exists and is not ours (remove it manually)`); continue; }
    links.push(linkPath);
    log(`  ${st.padEnd(6)} ${id} -> ${linkPath}`);
  }

  fs.writeFileSync(manifestPath(o.project), JSON.stringify({
    name: NAME, version: require('../package.json').version,
    installedAt: new Date().toISOString(), canonical, links,
  }, null, 2));
  log('\ndone. invoke as: /vloop (slash) or $vloop (codex/zcode) in your agent; `npx vloop-skill doctor` to verify.');
}

function uninstall(o) {
  for (const project of [o.project, !o.project]) { // prefer requested scope, fall back to the other
    const mp = manifestPath(project);
    if (!fs.existsSync(mp)) continue;
    const m = JSON.parse(fs.readFileSync(mp, 'utf8'));
    for (const l of m.links || []) { fs.rmSync(l, { recursive: true, force: true }); log(`removed ${l}`); }
    fs.rmSync(m.canonical, { recursive: true, force: true });
    log(`removed ${m.canonical}`);
    return;
  }
  die('no install manifest found (global or project)');
}

function doctor() {
  log(`vloop-skill ${require('../package.json').version}\n`);
  log('== dependencies (needed by the loop orchestrator) ==');
  for (const b of ['bash', 'git', 'jq', 'python3']) log(`  ${which(b) ? 'ok  ' : 'MISS'} ${b}`);
  log('\n== canonical install ==');
  for (const project of [false, true]) {
    const c = canonicalDir(project);
    log(`  ${fs.existsSync(path.join(c, 'SKILL.md')) ? 'ok  ' : '-   '} ${c}`);
  }
  log('\n== hosts needing symlinks ==');
  for (const id of Object.keys(LINK_HOSTS)) {
    const detected = detectHost(id);
    const lp = path.join(HOME, LINK_HOSTS[id].skills, NAME);
    const linked = fs.existsSync(path.join(lp, 'SKILL.md'));
    log(`  ${detected ? (linked ? 'ok  ' : 'todo') : '-   '} ${id.padEnd(16)} ${detected ? lp : '(not detected)'}`);
  }
  log(`\n== hosts covered by ~/.agents/skills natively ==\n  ${NATIVE_AGENTS_HOSTS.join(', ')}`);
  log('\n== loop backends on PATH ==');
  for (const b of ['claude', 'codex', 'opencode', 'gemini', 'aider', 'copilot', 'cursor-agent', 'droid', 'amp', 'qwen', 'goose', 'kiro-cli'])
    log(`  ${which(b) ? 'ok  ' : '-   '} ${b}`);
}

function run(argv) {
  for (const project of [true, false]) {
    const sh = path.join(canonicalDir(project), 'scripts', 'vloop.sh');
    if (fs.existsSync(sh)) {
      const r = spawnSync('bash', [sh, ...argv], { stdio: 'inherit' });
      process.exit(r.status ?? 1);
    }
  }
  // not installed: run straight from the npm package
  const r = spawnSync('bash', [path.join(PKG_SKILL, 'scripts', 'vloop.sh'), ...argv], { stdio: 'inherit' });
  process.exit(r.status ?? 1);
}

function init() {
  const dst = path.join(process.cwd(), '.vloop');
  fs.mkdirSync(path.join(dst, 'runs'), { recursive: true });
  const tpl = path.join(PKG_SKILL, 'templates');
  const map = { 'loop.json': 'loop.json', 'prd.json': 'prd.json', 'plan.md': 'plan.md', 'AGENT.md': 'AGENT.md' };
  for (const [src, name] of Object.entries(map)) {
    const p = path.join(dst, name);
    if (fs.existsSync(p)) { log(`keep   ${p}`); continue; }
    fs.copyFileSync(path.join(tpl, src), p);
    log(`create ${p}`);
  }
  log('\nedit .vloop/loop.json + .vloop/prd.json, then: npx vloop-skill run');
  log('(or use the configurator from inside any skills-capable agent: /vloop setup)');
}

const [cmd, ...rest] = process.argv.slice(2);
const opts = parseArgs(rest);
switch (cmd) {
  case 'install': install(opts); break;
  case 'uninstall': uninstall(opts); break;
  case 'doctor': doctor(); break;
  case 'run': run(rest); break;
  case 'init': init(); break;
  case 'list': doctor(); break;
  default:
    log(`vloop-skill — universal 3-layer loop-engineering skill installer

usage:
  npx vloop-skill install [--project] [--copy] [--all] [-a <agent>]...
      canonical -> ~/.agents/skills/vloop (or .agents/skills with --project)
      + symlinks into detected hosts: ${Object.keys(LINK_HOSTS).join(', ')}
      (codex/cursor/gemini/copilot/opencode/goose/crush/amp read ~/.agents/skills natively)
  npx vloop-skill uninstall [--project]
  npx vloop-skill doctor        check deps, hosts, backends, install state
  npx vloop-skill init          scaffold .vloop/ config templates in this repo
  npx vloop-skill run [...]     run the unattended loop orchestrator (Mode B)

ecosystem alternative: npx skills add wikieden/vloop   (vercel-labs/skills, 70+ agents)`);
}
