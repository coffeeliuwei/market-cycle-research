import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const edgeCandidates = [
  process.env.EDGE_PATH,
  process.env['ProgramFiles(x86)'] && path.join(process.env['ProgramFiles(x86)'], 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
  process.env.ProgramFiles && path.join(process.env.ProgramFiles, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
].filter(Boolean);
const edgeExecutable = edgeCandidates.find((candidate) => existsSync(candidate));
if (!edgeExecutable) throw new Error('Microsoft Edge was not found. Set EDGE_PATH.');

const profileDirectory = path.resolve(
  process.env.COINGLASS_PROFILE || path.join(projectRoot, 'state', 'runtime', 'coinglass-edge-profile'),
);
const port = Number(process.env.COINGLASS_CDP_PORT || 9225);
const proxy = process.env.MARKET_DATA_PROXY || process.env.HTTPS_PROXY || 'http://127.0.0.1:7897';

if (process.argv.includes('--describe')) {
  console.log(JSON.stringify({ projectRoot, edgeExecutable, profileDirectory, port, proxy }, null, 2));
  process.exit(0);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function cdpReady() {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/version`);
    if (!response.ok) return false;
    const value = await response.json();
    return Boolean(value.webSocketDebuggerUrl);
  } catch {
    return false;
  }
}

if (await cdpReady()) {
  console.log(JSON.stringify({ ready: true, reused: true, port, profileDirectory }));
  process.exit(0);
}

mkdirSync(profileDirectory, { recursive: true });
const child = spawn(edgeExecutable, [
  '--remote-debugging-address=127.0.0.1',
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${profileDirectory}`,
  `--proxy-server=${proxy}`,
  '--proxy-bypass-list=<-loopback>',
  'https://www.coinglass.com/pro',
], {
  detached: true,
  stdio: 'ignore',
  windowsHide: true,
});
child.unref();

for (let attempt = 1; attempt <= 30; attempt += 1) {
  if (await cdpReady()) {
    console.log(JSON.stringify({ ready: true, reused: false, port, profileDirectory, attempts: attempt }));
    process.exit(0);
  }
  await sleep(500);
}

console.log(JSON.stringify({ ready: false, reason: 'cdp_start_timeout', port, profileDirectory }));
process.exit(2);
