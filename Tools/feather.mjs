/** Dependency-free, Playwright-style client for Feather's opt-in Unix bridge.
 * This is not Playwright and does not implement CDP, browser contexts, or arbitrary evaluate().
 */
import net from 'node:net';
import {lstat, writeFile} from 'node:fs/promises';
import path from 'node:path';

export class FeatherError extends Error {
  constructor(code, message) { super(message); this.name = 'FeatherError'; this.code = code; }
}

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const defaultSocket = () => process.env.FEATHER_AGENT_SOCKET || `/tmp/feather-agent-${process.getuid()}/dev.nesbes.Feather.sock`;

async function call(socketPath, method, params = {}) {
  const payload = JSON.stringify({id: 1, method, params}) + '\n';
  if (Buffer.byteLength(payload) > 65536) throw new FeatherError('request_too_large', 'Request exceeds 64 KiB.');
  const [socketInfo, directory] = await Promise.all([lstat(socketPath), lstat(path.dirname(socketPath))]);
  if (!socketInfo.isSocket() || socketInfo.uid !== process.getuid() || (socketInfo.mode & 0o077) ||
      !directory.isDirectory() || directory.uid !== process.getuid() || (directory.mode & 0o077)) {
    throw new FeatherError('unsafe_socket', 'Agent socket and directory must be private and owned by the current user.');
  }
  return new Promise((resolve, reject) => {
    const connection = net.createConnection({path: socketPath});
    const chunks = [];
    let size = 0, settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      connection.destroy();
      error ? reject(error) : resolve(result);
    };
    connection.setTimeout(15000, () => finish(new FeatherError('timeout', 'Feather did not respond within 15 seconds.')));
    connection.on('connect', () => connection.write(payload));
    connection.on('error', error => finish(error));
    connection.on('end', () => { if (!settled) finish(new FeatherError('closed', 'Feather closed the connection without a response.')); });
    connection.on('data', chunk => {
      size += chunk.length;
      if (size > 32 * 1024 * 1024) return finish(new FeatherError('response_too_large', 'Response exceeds 32 MiB.'));
      chunks.push(chunk);
      if (!chunk.includes(10)) return;
      try {
        const line = Buffer.concat(chunks).toString('utf8').split('\n', 1)[0];
        const response = JSON.parse(line);
        if (response.id !== 1) throw new FeatherError('invalid_response', 'Invalid response ID.');
        if (response.error) throw new FeatherError(response.error.code, response.error.message);
        if (!('result' in response)) throw new FeatherError('invalid_response', 'Missing result.');
        finish(null, response.result);
      } catch (error) { finish(error); }
    });
  });
}

class FeatherLocator {
  constructor(page, target) { this.page = page; this.target = target; }
  async invoke(action, params = {}) {
    const target = typeof this.target === 'function' ? await this.target() : this.target;
    return this.page.call(`page.${action}`, {...target, ...params});
  }
  click() { return this.invoke('click'); }
  fill(value) { return this.invoke('fill', {value}); }
  selectOption(value) { return this.invoke('select', {value}); }
  press(key) { return this.invoke('press', {key}); }
}

export class FeatherPage {
  constructor(browser, id) { this.browser = browser; this.id = id; }
  call(method, params = {}) { return call(this.browser.socketPath, method, {...params, tabID: this.id}); }
  async goto(url) { await this.call('page.navigate', {url}); return this.snapshot(); }
  snapshot() { return this.call('page.snapshot'); }
  async title() { return (await this.snapshot()).title; }
  async url() { return (await this.snapshot()).url; }
  async reload() { await this.call('page.reload'); return this.snapshot(); }
  async goBack() { await this.call('page.back'); return this.snapshot(); }
  async goForward() { await this.call('page.forward'); return this.snapshot(); }
  bringToFront() { return this.call('tabs.select'); }
  close() { return this.call('tabs.close'); }
  locator(selector) { return new FeatherLocator(this, {selector}); }
  getByRole(role, {name, exact = true} = {}) {
    return new FeatherLocator(this, async () => {
      const snapshot = await this.snapshot();
      const matches = snapshot.elements.filter(element => {
        if (element.role !== role) return false;
        if (name === undefined) return true;
        if (name instanceof RegExp) { name.lastIndex = 0; return name.test(element.name); }
        return exact ? element.name === name : element.name.toLowerCase().includes(String(name).toLowerCase());
      });
      if (matches.length !== 1) throw new FeatherError('ambiguous_locator', `Expected one visible ${role}; found ${matches.length}.`);
      return {ref: matches[0].ref};
    });
  }
  scroll({x = 0, y} = {}) { return this.call('page.scroll', {x, ...(y === undefined ? {} : {y})}); }
  async screenshot({path: outputPath} = {}) {
    const result = await this.call('page.screenshot');
    const buffer = Buffer.from(result.data, 'base64');
    if (outputPath) await writeFile(outputPath, buffer);
    return buffer;
  }
  async waitForURL(expected, {timeout = 10000} = {}) {
    const deadline = Date.now() + timeout;
    do {
      const url = await this.url();
      if (expected instanceof RegExp) { expected.lastIndex = 0; if (expected.test(url)) return; }
      else if (url === expected) return;
      await pause(100);
    } while (Date.now() < deadline);
    throw new FeatherError('timeout', 'Timed out waiting for URL.');
  }
  async waitForLoadState(state = 'load') {
    if (!['load', 'domcontentloaded'].includes(state)) throw new FeatherError('unsupported', 'Only load and domcontentloaded are supported; Feather does not provide networkidle tracking.');
    await this.snapshot();
  }
}

export class FeatherBrowser {
  constructor(socketPath) { this.socketPath = socketPath; }
  info() { return call(this.socketPath, 'browser.info'); }
  async pages() { return (await call(this.socketPath, 'tabs.list')).tabs.map(tab => new FeatherPage(this, tab.id)); }
  async newPage(url = 'about:blank') {
    const tab = await call(this.socketPath, 'tabs.open', {url});
    return new FeatherPage(this, tab.id);
  }
  /** Stateless per-request transport: disconnect never closes the user's browser or tabs. */
  async disconnect() {}
}

export async function connectFeather({socketPath = defaultSocket()} = {}) {
  const browser = new FeatherBrowser(socketPath);
  await browser.info();
  return browser;
}
