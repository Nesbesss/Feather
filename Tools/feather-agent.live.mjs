/** Opt-in live regression: use a disposable Feather build with Agent Access enabled. */
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import {lstat} from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {connectFeather} from './feather.mjs';

const socketPath = process.env.FEATHER_AGENT_LIVE_SOCKET;
assert(socketPath && path.isAbsolute(socketPath), 'Set FEATHER_AGENT_LIVE_SOCKET to the absolute socket path of a disposable Feather preview.');
const fixture = `<!doctype html><html lang="en"><meta charset="utf-8"><title>Feather agent fixture</title>
<style>body{font:20px system-ui;padding:30px}label,button,select{display:block;margin:18px 0}input,button,select{font:inherit}</style>
<h1>Feather agent fixture</h1><form id="form">
<label>Title <input id="title" name="title" aria-label="Title" autocomplete="off"></label>
<label>Password <input type="password" value="fixture-secret" aria-label="Password"></label>
<label>Choice <select id="choice" aria-label="Choice"><option value="a">Alpha</option><option value="b">Beta</option></select></label>
<button type="submit">Save</button></form><p id="status" role="status">Ready</p>
<a href="/next">Next page</a><button id="replace" type="button">Replace action</button>
<script>document.querySelector('#form').addEventListener('submit',e=>{e.preventDefault();document.querySelector('#status').textContent='Saved '+document.querySelector('#title').value+' / '+document.querySelector('#choice').value});document.querySelector('#replace').addEventListener('click',e=>{e.currentTarget.outerHTML='<button>Replacement action</button>'});</script></html>`;
const server = http.createServer((request, response) => {
  response.setHeader('Content-Type', 'text/html; charset=utf-8');
  response.setHeader('Cache-Control', 'no-store');
  response.end(request.url === '/next' ? '<!doctype html><title>Second agent page</title><h1>Second page</h1>' : fixture);
});
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
const base = `http://127.0.0.1:${server.address().port}`;
const created = [];
let browser;
try {
  browser = await connectFeather({socketPath});
  const info = await browser.info();
  assert.notEqual(info.bundleID, 'dev.nesbes.Feather', 'Use an isolated preview bundle, not the main Feather session.');
  const existingIDs = (await browser.pages()).map(page => page.id);
  const page = await browser.newPage(base + '/');
  created.push(page);
  await page.waitForLoadState();
  let snapshot = await page.snapshot();
  assert.equal(snapshot.title, 'Feather agent fixture');
  assert(!JSON.stringify(snapshot).includes('fixture-secret'));
  assert.equal(snapshot.elements.find(element => element.name === 'Password').value, undefined);
  // Critical regression: a ref from a snapshot must survive the next bridge invocation.
  await page.getByRole('textbox', {name:'Title'}).fill('Hello Feather');
  await page.getByRole('combobox', {name:'Choice'}).selectOption('b');
  await page.getByRole('button', {name:'Save'}).click();
  snapshot = await page.snapshot();
  assert(snapshot.text.includes('Saved Hello Feather / b'));
  const ref = snapshot.elements.find(element => element.name === 'Replace action').ref;
  await page.locator('#replace').click();
  await assert.rejects(page.call('page.click', {ref}), /Stale element/);
  await assert.rejects(page.locator('button').click(), /exactly one/);
  await assert.rejects(page.locator('#title').press('Backspace'), /Unsupported key/);
  await page.getByRole('link', {name:'Next page'}).click();
  await page.waitForURL(base + '/next');
  assert.equal(await page.title(), 'Second agent page');
  await assert.rejects(page.call('page.click', {ref}), /Stale element/);
  await page.goto(base + '/');
  await page.getByRole('textbox', {name:'Title'}).fill('Enter path');
  await page.locator('#title').press('Enter');
  assert((await page.snapshot()).text.includes('Saved Enter path / a'));
  const image = await page.screenshot();
  assert.equal(image.subarray(1, 4).toString(), 'PNG');
  assert(image.length > 1000);
  assert.equal((await lstat(socketPath)).mode & 0o777, 0o600);
  assert.equal((await lstat(path.dirname(socketPath))).mode & 0o777, 0o700);
  const delayed = await new Promise((resolve, reject) => {
    const client = net.createConnection({path:socketPath});
    let data = '';
    client.on('connect', () => setTimeout(() => client.write('{"id":7,"method":"browser.info"}\n'), 200));
    client.on('data', chunk => {
      data += chunk;
      if (data.includes('\n')) { client.end(); resolve(JSON.parse(data.split('\n', 1)[0])); }
    });
    client.on('error', reject);
    client.setTimeout(5000, () => { client.destroy(); reject(new Error('Delayed request timed out')); });
  });
  assert.equal(delayed.id, 7);
  assert.equal(delayed.result.name, 'Feather');
  const messages = [
    {jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-06-18'}},
    {jsonrpc:'2.0',id:2,method:'tools/list'},
    {jsonrpc:'2.0',id:3,method:'tools/call',params:{name:'feather_browser_info',arguments:{}}},
  ];
  const adapter = fileURLToPath(new URL('./feather-agent.py', import.meta.url));
  const processResult = spawnSync('python3', [adapter, '--socket', socketPath, '--mcp'], {
    input:messages.map(message => JSON.stringify(message)).join('\n') + '\n', encoding:'utf8', timeout:20000,
  });
  assert.equal(processResult.status, 0, processResult.stderr);
  const outputs = processResult.stdout.trim().split('\n').map(JSON.parse);
  assert.equal(outputs.length, 3);
  assert(outputs[1].result.tools.some(tool => tool.name === 'feather_page_screenshot'));
  assert.equal(JSON.parse(outputs[2].result.content[0].text).bundleID, info.bundleID);
  const remainingIDs = new Set((await browser.pages()).map(tab => tab.id));
  for (const id of existingIDs) assert(remainingIDs.has(id), 'A pre-existing tab was unexpectedly removed.');
  console.log('LIVE PASS: native tabs, DOM refs, password omission, fill/select/click, stale refs, strict locators, navigation, Enter, screenshots, delayed socket I/O, permissions, and MCP.');
} finally {
  // Only tabs created by this test are eligible for cleanup.
  for (const page of created) await page.close().catch(error => {
    console.error(`Could not close test tab ${page.id}: ${error.message}`);
    process.exitCode = 1;
  });
  await browser?.disconnect();
  await new Promise(resolve => server.close(resolve));
}
