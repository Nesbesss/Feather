import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import {mkdtemp, chmod, rm, readFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {connectFeather, FeatherError} from './feather.mjs';

async function mockBridge(run, handler) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'f-agent-'));
  await chmod(directory, 0o700);
  const socketPath = path.join(directory, 'test.sock');
  const calls = [];
  const server = net.createServer(connection => {
    let input = '';
    connection.on('data', data => {
      input += data;
      if (!input.includes('\n')) return;
      const request = JSON.parse(input.split('\n', 1)[0]);
      calls.push(request);
      const result = handler(request);
      const encoded = JSON.stringify({id: request.id, ...result}) + '\n';
      connection.write(encoded.slice(0, 7));
      connection.end(encoded.slice(7));
    });
    connection.on('error', () => {});
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
  await chmod(socketPath, 0o600);
  try { await run(socketPath, calls, directory); }
  finally { await new Promise(resolve => server.close(resolve)); await rm(directory, {recursive: true, force: true}); }
}

test('page locators use fresh semantic refs and preserve explicit tab IDs', async () => {
  await mockBridge(async (socketPath, calls) => {
    const browser = await connectFeather({socketPath});
    const page = await browser.newPage('http://localhost:3000');
    await page.getByRole('button', {name: 'Save'}).click();
    await page.locator('#title').fill('A new title');
    assert.equal(calls.at(-1).params.value, 'A new title');
    assert.equal(calls.at(-1).params.tabID, 'tab-1');
    const click = calls.find(call => call.method === 'page.click');
    assert.equal(click.params.ref, 'fresh-ref');
    assert.equal(click.params.selector, undefined);
  }, request => ({result: request.method === 'tabs.open' ? {id: 'tab-1'} : request.method === 'page.snapshot' ?
    {elements: [{ref:'fresh-ref',role:'button',name:'Save'}]} : {ok:true}}));
});

test('ambiguous semantic locators never execute an action', async () => {
  await mockBridge(async (socketPath, calls) => {
    const browser = await connectFeather({socketPath});
    const [page] = await browser.pages();
    await assert.rejects(page.getByRole('button', {name:'Save'}).click(), /found 2/);
    assert.equal(calls.some(call => call.method === 'page.click'), false);
  }, request => ({result: request.method === 'tabs.list' ? {tabs:[{id:'tab-1'}]} : request.method === 'page.snapshot' ?
    {elements:[{ref:'1',role:'button',name:'Save'},{ref:'2',role:'button',name:'Save'}]} : {}}));
});

test('screenshot returns bytes and writes requested output', async () => {
  await mockBridge(async (socketPath, _calls, directory) => {
    const browser = await connectFeather({socketPath});
    const page = await browser.newPage();
    const output = path.join(directory, 'image.png');
    const screenshot = await page.screenshot({path:output});
    assert.equal(screenshot.toString(), 'test image');
    assert.deepEqual(await readFile(output), screenshot);
  }, request => ({result: request.method === 'tabs.open' ? {id:'tab-1'} : request.method === 'page.screenshot' ?
    {mimeType:'image/png',data:Buffer.from('test image').toString('base64')} : {}}));
});

test('server operation errors retain their code', async () => {
  await mockBridge(async socketPath => {
    await assert.rejects(connectFeather({socketPath}), error => error instanceof FeatherError && error.code === 'disabled');
  }, () => ({error:{code:'disabled',message:'Agent access is disabled.'}}));
});
