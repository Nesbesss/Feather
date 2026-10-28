// Focused contracts for Feather's explicit transport adapters. Native WebKit is tested separately.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../../Feather/Resources/YouTube/upstream/youtube-upstream.js', import.meta.url), 'utf8');
const endpoint = 'https://youtube.com/youtubei/v1/player?key=synthetic';
const payload = JSON.stringify({keep: 'content', adSlots: [1], adPlacements: [2], playerAds: [3]});
let passed = 0;
async function check(name, run) {await run(); passed++; console.log('PASS ' + name);}
const noAds = value => {assert.equal(value.keep, 'content'); for (const key of ['adSlots', 'adPlacements', 'playerAds']) assert.equal(key in value, false);};
function response(body = payload, finalURL = endpoint, contentType = 'application/json') {
  const value = new Response(body, {status: 201, statusText: 'Created', headers: {
    'content-type': contentType, 'content-length': '999', 'content-encoding': 'gzip', 'x-fixture': 'preserved'}});
  Object.defineProperties(value, {url: {value: finalURL}, redirected: {value: true}, type: {value: 'basic'}});
  return value;
}
function realm(transport = async () => response(), xhrFixture = {}) {
  class RealmResponse extends Response {}
  const context = vm.createContext({URL, Request, Response: RealmResponse, Headers, DOMException, console,
    transport, xhrFixture: {body: payload, url: endpoint, contentType: 'application/json', ...xhrFixture},
    location: {hostname: 'youtube.com', pathname: '/watch', href: 'https://youtube.com/watch?v=synthetic01'}});
  vm.runInContext(`
    class Window {}; globalThis.Window=Window;
    const nativeParse=JSON.parse;
    const document={location,currentScript:null,baseURI:location.href};globalThis.document=document;
    globalThis.xhrNetworkCalls=0;
    class XMLHttpRequest {
      responseType=''; readyState=0; status=0; statusText=''; responseURL='';
      open(method,url){this.method=method;this.requestURL=String(url);this.readyState=1;this._json=undefined;}
      send(){xhrNetworkCalls++;this.readyState=4;this.status=201;this.statusText='Created';this.responseURL=xhrFixture.url;}
      get response(){if(this.responseType==='json')return this._json??=(nativeParse(xhrFixture.body));if(this.responseType==='arraybuffer'||this.responseType==='blob')return xhrFixture.binary;return xhrFixture.body;}
      get responseText(){if(this.responseType!==''&&this.responseType!=='text')throw new DOMException('Wrong response type','InvalidStateError');return this.readyState===4?xhrFixture.body:'';}
      getResponseHeader(name){return name.toLowerCase()==='content-type'?xhrFixture.contentType:name.toLowerCase()==='x-fixture'?'preserved':null;}
      addEventListener(){} setRequestHeader(){}
    }
    globalThis.XMLHttpRequest=XMLHttpRequest;globalThis.fetch=transport;
    globalThis.window={JSON,location,document,fetch:transport,XMLHttpRequest,Response,Request,Headers,Promise,Window,Object,Array,Reflect,Proxy,WeakMap,Map,Set,RegExp,Function};
    globalThis.self=window;
  `, context);
  vm.runInContext(source, context);
  return {context, run: code => vm.runInContext(code, context)};
}

for (const [label, input] of [['string', endpoint], ['URL', new URL(endpoint)], ['Request', new Request(endpoint)]]) {
  await check('fetch ' + label + ' input prunes once', async () => {
    let calls = 0; const {context, run} = realm(async () => {calls++; return response();}); context.input=input;
    noAds(await (await run('window.fetch(input)')).json()); assert.equal(calls, 1);
  });
}
await check('fetch bodyUsed, metadata, clones and body independence remain native', async () => {
  const {run} = realm(); const value=await run(`window.fetch('${endpoint}')`);
  assert.equal(value.bodyUsed, false); assert.equal(value.url, endpoint); assert.equal(value.type, 'basic');
  assert.equal(value.status, 201); assert.equal(value.statusText, 'Created'); assert.equal(value.redirected, true);
  assert.equal(value.headers.get('x-fixture'), 'preserved'); assert.equal(value.headers.has('content-length'), false); assert.equal(value.headers.has('content-encoding'), false);
  const clone=value.clone();assert.equal(clone.url,endpoint);assert.equal(clone.type,'basic');assert.equal(clone.redirected,true);
  noAds(await clone.json()); assert.equal(clone.bodyUsed, true); assert.equal(value.bodyUsed, false);
  noAds(await value.json()); assert.equal(value.bodyUsed, true); await assert.rejects(()=>value.text()); assert.throws(()=>value.clone());
});
for (const finalURL of ['https://example.org/youtubei/v1/player?key=synthetic', 'https://youtube.com/unrelated.json']) {
  await check('fetch unrelated final destination retains original body', async () => {
    const original=response(payload,finalURL);const {run}=realm(async()=>original);const value=await run(`window.fetch('${endpoint}')`);
    assert.equal(value,original);assert.equal(value.bodyUsed,false);assert.equal(await value.text(),payload);
  });
}
await check('fetch known player to next redirect is pruned', async () => {
  const {run}=realm(async()=>response(payload,'https://youtube.com/youtubei/v1/next?key=synthetic'));
  noAds(await(await run(`window.fetch('${endpoint}')`)).json());
});
await check('fetch SSE returns before an unclosed body can finish', async () => {
  const stream=new ReadableStream({start(controller){controller.enqueue(new TextEncoder().encode('data: waiting\n\n'));}});
  const original=response(stream,endpoint,'text/event-stream');const {run}=realm(async()=>original);
  const timeout=new Promise((_,reject)=>setTimeout(()=>reject(new Error('SSE was buffered')),200));
  assert.equal(await Promise.race([run(`window.fetch('${endpoint}')`),timeout]),original);assert.equal(original.bodyUsed,false);await original.body.cancel();
});
for (const mime of ['application/octet-stream','text/html','application/x-ndjson','']) {
  await check('fetch unsupported MIME passes through unread: ' + (mime||'missing'), async () => {
    const original=response(payload,endpoint,mime);const {run}=realm(async()=>original);assert.equal(await run(`window.fetch('${endpoint}')`),original);assert.equal(original.bodyUsed,false);
  });
}
await check('fetch network failure is not retried', async () => {
  let calls=0;const error=new Error('synthetic failure');const {run}=realm(()=>{calls++;return Promise.reject(error);});
  await assert.rejects(()=>run(`window.fetch('${endpoint}')`),candidate=>candidate===error);assert.equal(calls,1);
});
await check('fetch nested envelope survives interaction with earlier JSON.parse hooks', async () => {
  const body=JSON.stringify({playerResponse:{keep:'content',streamingData:{serverAbrStreamingUrl:'synthetic'},adSlots:[1],adPlacements:[2],playerAds:[3]}});
  const {run}=realm(async()=>response(body));noAds((await(await run(`window.fetch('${endpoint}')`)).json()).playerResponse);
});
for (const type of ['', 'text', 'json']) {
  await check('XHR ' + (type||'default') + ' retains native request and prunes JSON', () => {
    const {run}=realm();run(`globalThis.x=new XMLHttpRequest();x.open('GET','${endpoint}');x.responseType='${type}';x.send();`);
    const value=run(type==='json'?'x.response':'JSON.parse(x.responseText)');noAds(value);assert.equal(run('xhrNetworkCalls'),1);
    assert.equal(run('x.status'),201);assert.equal(run("x.getResponseHeader('x-fixture')"),'preserved');
    if(type==='json')assert.throws(()=>run('x.responseText'),error=>error.name==='InvalidStateError');
  });
}
for (const type of ['arraybuffer','blob']) {
  await check('XHR ' + type + ' preserves binary identity and responseText exception', () => {
    const binary=type==='arraybuffer'?new Uint8Array([0,255,128,17]).buffer:new Blob([new Uint8Array([0,255,128,17])]);
    const {run}=realm(undefined,{binary});run(`globalThis.x=new XMLHttpRequest();x.open('GET','${endpoint}');x.responseType='${type}';x.send();`);
    assert.equal(run('x.response'),binary);assert.throws(()=>run('x.responseText'),error=>error.name==='InvalidStateError');assert.equal(run('xhrNetworkCalls'),1);
  });
}
for (const url of ['https://example.org/youtubei/v1/player?key=synthetic','https://youtube.com/unrelated.json']) {
  await check('XHR unrelated final response remains unchanged', () => {
    const {run}=realm(undefined,{url});run(`globalThis.x=new XMLHttpRequest();x.open('GET','${endpoint}');x.send();`);assert.equal(run('x.responseText'),payload);
  });
}
await check('XHR known player to next redirect is pruned', () => {
  const {run}=realm(undefined,{url:'https://youtube.com/youtubei/v1/next?key=synthetic'});run(`globalThis.x=new XMLHttpRequest();x.open('GET','${endpoint}');x.send();`);noAds(run('JSON.parse(x.responseText)'));
});
await check('XHR binary MIME text retains native bytes', () => {
  const {run}=realm(undefined,{contentType:'application/octet-stream'});run(`globalThis.x=new XMLHttpRequest();x.open('GET','${endpoint}');x.send();`);assert.equal(run('x.responseText'),payload);
});
console.log(JSON.stringify({suite:'upstream-transport-contracts',passed,limitation:'Node contracts; native WebKit and live playback require separate tests.'}));
