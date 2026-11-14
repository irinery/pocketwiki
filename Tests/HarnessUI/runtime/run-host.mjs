import { spawn } from 'node:child_process';
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const args = process.argv.slice(2);
const option = name => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
const surface = option('--surface'), reportDir = option('--report-dir');
if (!['web', 'macos'].includes(surface) || !reportDir) { console.error('usage: run-host.mjs --surface web|macos --report-dir <dir>'); process.exit(2); }
await mkdir(reportDir, { recursive: true });
const temp = await mkdtemp(path.join(os.tmpdir(), 'runtime-ui-host-'));
const cases = ['02-01', '02-02', '02-03', '02-04'].map(id => ({ id, status: 'failed', detail: 'cenário não concluído' }));
let log = '', status = 1, generatedProject;
async function run(program, argv, options = {}) {
  return new Promise((resolve, reject) => {
    const { timeoutMS, ...spawnOptions } = options;
    const child = spawn(program, argv, { ...spawnOptions, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, timeoutMS || 180000);
    for (const stream of [child.stdout, child.stderr]) stream.on('data', data => { output = (output + data.toString()).slice(-65536); });
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('close', code => { clearTimeout(timer); log += `$ ${program} ${argv.join(' ')}\n${output}\nexit=${code}\n`; resolve(code); });
  });
}
try {
  const root = process.env.POCKETKERNEL_NH00_ROOT;
  if (!root) { status = 2; throw new Error('POCKETKERNEL_NH00_ROOT obrigatório'); }
  const snapshot = path.join(temp, 'kernel'); await mkdir(snapshot);
  const archive = path.join(temp, 'kernel.tar');
  if (await run('git', ['-C', root, 'archive', '--output', archive, '582e216c13feb7485fa9620d9543b272ec3794b5'])) throw new Error('snapshot Kernel indisponível');
  if (await run('tar', ['-xf', archive, '-C', snapshot])) throw new Error('extração Kernel falhou');
  const kernel = path.join(temp, 'pocketkernel');
  if (await run('go', ['build', '-o', kernel, './cmd/pocketkernel'], { cwd: snapshot, env: { ...process.env, GOFLAGS: '-buildvcs=false' } })) throw new Error('build Kernel falhou');
  try { await access('node_modules/@playwright/test/package.json'); }
  catch {
    if (await run('git', ['diff', '--quiet', '--', 'node_modules']) || await run('git', ['diff', '--cached', '--quiet', '--', 'node_modules'])) throw new Error('node_modules rastreados têm alterações locais');
    if (await run('npm', ['ci', '--ignore-scripts'], { timeoutMS: 600000 })) throw new Error('npm ci falhou');
    if (await run('git', ['restore', '--worktree', '--', 'node_modules'])) throw new Error('não foi possível restaurar dependências rastreadas');
  }
  const literalSwift = path.join(temp, 'replay-literal');
  const swiftSources = ['Sources/PocketWikiMac/Models/Harness/HarnessV1.swift', 'Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift', 'Sources/PocketWikiMac/Services/Harness/Runtime/RuntimeProjection.swift', 'Tests/HarnessUI/runtime/macos/RuntimeReplayLiteral.swift'];
  if (await run('swiftc', ['-parse-as-library', ...swiftSources, '-o', literalSwift], { timeoutMS: 600000 })) throw new Error('build teste Swift literal falhou');
  if (await run(literalSwift, [])) throw new Error('replay Swift literal falhou');
  if (await run(process.execPath, ['--test', 'Tests/HarnessUI/runtime/projection.test.mjs'])) throw new Error('replay JS literal falhou');
  if (surface === 'web') {
    if (await run('npx', ['playwright', 'install', 'chromium-headless-shell'], { timeoutMS: 600000 })) throw new Error('Chromium indisponível');
    const legacySource = await readFile('Tests/HarnessUI/runtime/legacy-host/main.go');
    await writeFile(path.join(snapshot, 'legacy-ui-host.go'), legacySource);
    const legacy = path.join(temp, 'legacy-host');
    if (await run('go', ['build', '-o', legacy, 'legacy-ui-host.go'], { cwd: snapshot, env: { ...process.env, GOFLAGS: '-buildvcs=false' } })) throw new Error('build legado falhou');
    const baseEnv = { ...process.env, RUNTIME_KERNEL_BINARY: kernel, RUNTIME_LEGACY_BINARY: legacy };
    const scenarios = [
      ['02-01', 'RUNTIME_REPLAY', 'Kernel: B=9, replay 8/9/10/11/12; B=10/9/10/11 apenas em testes unitários JS e Swift'],
      ['02-03', 'RUNTIME_PAUSE_EFFECT', ''],
      ['02-04', 'RUNTIME_INCOMPATIBLE', '']
    ];
    for (const [id, flag, detail] of scenarios) {
      const code = await run(process.execPath, ['Tests/HarnessUI/runtime/web-smoke.mjs'], { env: { ...baseEnv, [flag]: '1' } });
      const row = cases.find(item => item.id === id);
      row.status = code === 0 ? 'passed' : 'failed';
      row.detail = code === 0 ? detail || 'validado' : `host falhou: exit ${code}`;
    }
    const bundle = path.join(temp, 'runtime-bundle.js');
    if (await run('npx', ['esbuild', 'Tests/HarnessUI/runtime/web/main.mjs', '--bundle', '--format=esm', '--platform=browser', '--inject:Tests/HarnessUI/runtime/web/buffer-shim.mjs', `--outfile=${bundle}`], { timeoutMS: 600000 })) throw new Error('bundle runtime falhou');
    if (await run('npm', ['run', 'build:legacy-web-assets'], { timeoutMS: 600000 })) throw new Error('assets legados falharam');
    const legacyCode = await run(process.execPath, ['Tests/NewHarnessE2E/legacy-web-host.mjs'], { env: { ...process.env, NH_RUNTIME_UI_BUNDLE: bundle } });
    const legacyRow = cases.find(item => item.id === '02-02');
    legacyRow.status = legacyCode === 0 ? 'passed' : 'failed'; legacyRow.detail = legacyCode === 0 ? 'slot e chat legado pela bridge validados' : `host legado falhou: exit ${legacyCode}`;
  } else {
    const project = 'Tests/HarnessUI/runtime/macos/PocketWikiRuntimeUIHost.xcodeproj';
    const derived = path.join(temp, 'derived');
    try { await access(project); throw new Error('projeto XCTest gerado já existe'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    generatedProject = project;
    if (await run('xcodegen', ['generate', '--spec', 'Tests/HarnessUI/runtime/macos/project.yml'], { timeoutMS: 600000 })) throw new Error('xcodegen falhou');
    if (await run('xcodebuild', ['-project', project, '-scheme', 'PocketWikiRuntimeUIHost', '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', derived, 'build-for-testing', 'CODE_SIGNING_ALLOWED=NO', '-quiet'], { timeoutMS: 600000 })) throw new Error('build XCTest falhou');
    const env = { ...process.env, RUNTIME_KERNEL_BINARY: kernel, RUNTIME_MACOS: '1', RUNTIME_DERIVED_DATA: derived };
    for (const [id, flag] of [['02-01', 'RUNTIME_REPLAY'], ['02-03', 'RUNTIME_PAUSE_EFFECT'], ['02-04', 'RUNTIME_INCOMPATIBLE']]) {
      const code = await run(process.execPath, ['Tests/HarnessUI/runtime/web-smoke.mjs'], { env: { ...env, [flag]: '1' } });
      const row = cases.find(item => item.id === id); row.status = code === 0 ? 'passed' : 'failed'; row.detail = code === 0 ? (id === '02-01' ? 'Kernel: B=9, replay 8/9/10/11/12; B=10/9/10/11 apenas em testes unitários JS e Swift' : 'validado') : `XCTest falhou: exit ${code}`;
    }
  }
  status = cases.every(row => row.status === 'passed') ? 0 : 1;
} catch (error) { log += `erro: ${error.message}\n`; }
finally {
  await writeFile(path.join(reportDir, 'result.json'), JSON.stringify({ surface, cases }, null, 2) + '\n');
  await writeFile(path.join(reportDir, 'host.log'), log);
  if (generatedProject) await rm(generatedProject, { recursive: true, force: true });
  await rm(temp, { recursive: true, force: true });
}
process.exitCode = status;
