// Ad-only notification evidence contracts; this does not prove live ad prevention.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../../Feather/Resources/YouTube/upstream/youtube-upstream.js', import.meta.url), 'utf8');
const endpoint = 'https://youtube.com/youtubei/v1/player?key=synthetic';
let passed = 0;
async function check(name, run) { await run(); passed++; console.log('PASS ' + name); }
function realm({body = '{"keep":1,"adSlots":[{"slot":1}]}', finalURL = endpoint, mime = 'application/json', throwing = false, callback = true} = {}) {
  const events = [];
  class RealmResponse extends Response {}
  const context = vm.createContext({URL, Request, Response: RealmResponse, Headers, DOMException,
    console: {log(){}, error(){}}, body, finalURL, mime,
    ...(callback ? {__FEATHER_AD_INTERVENTION__: kind => {events.push(kind); if (throwing) throw Error('fixture');}} : {}),
    location: {hostname:'youtube.com', pathname:'/watch', href:'https://youtube.com/watch?v=synthetic01'}});
  vm.runInContext(`
    class Window {}; globalThis.Window=Window;
    const document={location,currentScript:null,baseURI:location.href};globalThis.document=document;
    const nativeParse=JSON.parse;
    class XMLHttpRequest {
      readyState=0;status=0;responseType='';responseURL='';
      open() {this.readyState=1;this._json=undefined;}
      send() {this.readyState=4;this.status=200;this.responseURL=finalURL;}
      get response() {return this.responseType==='json'?(this._json??=nativeParse(body)):body;}
      get responseText() {if(this.responseType&&this.responseType!=='text')throw new DOMException('type','InvalidStateError');return body;}
      getResponseHeader() {return mime;}
    }
    const NativeResponse=Response;
    const fetch=async()=>{const value=new NativeResponse(body,{headers:{'content-type':mime}});Object.defineProperty(value,'url',{value:finalURL});return value;};
    globalThis.XMLHttpRequest=XMLHttpRequest;globalThis.fetch=fetch;
    globalThis.window={JSON,location,document,fetch,XMLHttpRequest,Response,Request,Headers,Promise,Window,Object,Array,Reflect,Proxy,WeakMap,Map,Set,RegExp,Function};
    globalThis.self=window;
  `, context);
  // Test-only reference exposes the actual generated patched functions. It is
  // absent from the shipped bytes and permits isolated recovery/feed fixtures.
  vm.runInContext(source.replace('const functions = {', 'const functions = globalThis.fixtureFunctions = {'), context);
  return {events, run: code => vm.runInContext(code, context)};
}

await check('install, diagnostic reads and absent constant reads are silent', () => {
  const {run, events}=realm(); run(`__featherYouTubeUpstream;window.ytInitialPlayerResponse={};for(let n=0;n<3;n++)window.ytInitialPlayerResponse.adSlots;`); assert.deepEqual(events,[]);
});
await check('empty, null and undefined ad fields are silent', () => {
  const {run,events}=realm(); run(`window.ytInitialPlayerResponse={adSlots:[],adPlacements:{},playerAds:null};window.ytInitialPlayerResponse.adSlots=[];window.ytInitialPlayerResponse.playerAds=undefined;`); assert.deepEqual(events,[]);
});
await check('initial nonempty ad constants signal only suppression', () => {
  const {run,events}=realm(); run(`window.ytInitialPlayerResponse={adSlots:[1],adPlacements:[2],playerAds:[3]};`);
  assert.deepEqual(events,['ad-data-suppressed','ad-data-suppressed','ad-data-suppressed']);
});
await check('late nonempty constant write signals once, subsequent reads are silent', () => {
  const {run,events}=realm(); run(`window.ytInitialPlayerResponse={};window.ytInitialPlayerResponse.adSlots=[1];for(let n=0;n<5;n++)window.ytInitialPlayerResponse.adSlots;`); assert.deepEqual(events,['ad-data-suppressed']);
});
await check('nonconfigurable ad property produces no false trap signal', () => {
  const {run,events}=realm(); run(`const value={};Object.defineProperty(value,'adSlots',{value:[1],configurable:false});window.ytInitialPlayerResponse=value;`); assert.deepEqual(events,[]);
});
await check('empty and absent JSON ad metadata produce no signal', () => {
  const {run,events}=realm(); run(`JSON.parse('{"playerResponse":{"streamingData":{"serverAbrStreamingUrl":"fixture"},"adSlots":[],"adPlacements":[]}}');JSON.parse('{"keep":1}');`); assert.deepEqual(events,[]);
});
await check('nonempty SABR JSON metadata deletion signals removal', () => {
  const {run,events}=realm(); const result=run(`JSON.parse('{"playerResponse":{"streamingData":{"serverAbrStreamingUrl":"fixture"},"adSlots":[1],"adPlacements":[2]}}').playerResponse`); assert.equal('adSlots' in result,false);assert.deepEqual(events,['ad-data-removed','ad-data-removed']);
});
await check('Shorts true ad item signals removal, false flag remains silent', () => {
  const {run,events}=realm();run(`JSON.parse('{"entries":[{"command":{"reelWatchEndpoint":{"adClientParams":{"isAd":true}}}}]}');`);assert.deepEqual(events,['ad-data-removed']);events.length=0;run(`JSON.parse('{"entries":[{"command":{"reelWatchEndpoint":{"adClientParams":{"isAd":false}}}}]}');`);assert.deepEqual(events,[]);
});
await check('feed renderer mutation signals removal', () => {
  const {run,events}=realm();run(`fixtureFunctions['json-prune']({name:'json-prune',args:['contents.[-].adSlotRenderer'],verbose:false},['contents.[-].adSlotRenderer']);JSON.parse('{"contents":[{"adSlotRenderer":{"slot":1}},{"keep":1}]}');`);assert.deepEqual(events,['ad-data-removed']);
});
await check('throwing observation descriptor cannot abort original pruning', () => {
  const {run,events}=realm();const result=run(`fixtureFunctions['json-prune']({name:'json-prune',args:['adSlots'],verbose:false},['adSlots']);JSON.parse('{"adSlots":[1]}',(key,value)=>key===''?new Proxy(value,{getOwnPropertyDescriptor(){throw Error('fixture descriptor');}}):value);`);assert.equal('adSlots' in result,false);assert.deepEqual(events,[]);
});
await check('JSONPath feed renderer mutation signals removal', () => {
  const {run,events}=realm();run(`fixtureFunctions['json-prune']({name:'json-prune',args:['$..contents[?(@.adSlotRenderer)]'],verbose:false},['$..contents[?(@.adSlotRenderer)]']);JSON.parse('{"contents":[{"adSlotRenderer":{"slot":1}},{"keep":1}]}');`);assert.deepEqual(events,['ad-data-removed']);
});
await check('mute and other recovery mutations remain silent', () => {
  const {run,events}=realm();run(`fixtureFunctions['json-prune']({name:'json-prune',args:['playerConfig.audioConfig.muteOnStart'],verbose:false},['playerConfig.audioConfig.muteOnStart']);JSON.parse('{"playerConfig":{"audioConfig":{"muteOnStart":true}}}');`);assert.deepEqual(events,[]);
});
await check('fetch confirmed replacement signals only after response is prepared', async () => {
  const {run,events}=realm();const response=await run(`window.fetch('${endpoint}')`);assert.equal(response.bodyUsed,false);assert.deepEqual(events,['ad-data-removed']);assert.equal((await response.json()).adSlots,undefined);assert.deepEqual(events,['ad-data-removed']);
});
await check('unchanged fetch, empty ad fields, foreign redirect and MIME bypass stay silent', async () => {
  for(const options of [{body:'{"keep":1}'},{body:'{"adSlots":[]}'},{finalURL:'https://example.org/youtubei/v1/player'},{mime:'text/event-stream'}]) {
    const {run,events}=realm(options);await run(`window.fetch('${endpoint}')`);assert.deepEqual(events,[]);
  }
});
await check('failed fetch replacement discards staged notification', async () => {
  const {run,events}=realm();run(`globalThis.Response=class {constructor(){throw Error('fixture response failure');}};`);
  const response=await run(`window.fetch('${endpoint}')`);assert.deepEqual(events,[]);assert.ok((await response.text()).includes('adSlots'));
});
await check('XHR text and JSON signal once on actual mutation, cached reads are silent', () => {
  for(const type of ['text','json']) {const {run,events}=realm();run(`const x=new XMLHttpRequest();x.open('GET','${endpoint}');x.responseType='${type}';x.send();x.response;x.response;`);assert.deepEqual(events,['ad-data-removed']);}
});
await check('unchanged XHR stays silent', () => {
  const {run,events}=realm({body:'{"keep":1}'});run(`const x=new XMLHttpRequest();x.open('GET','${endpoint}');x.send();x.responseText;x.responseText;`);assert.deepEqual(events,[]);
});
await check('throwing or absent optional callback cannot interrupt suppression', () => {
  for(const options of [{throwing:true},{callback:false}]) {const {run}=realm(options);assert.equal(run(`window.ytInitialPlayerResponse={adSlots:[1]};window.ytInitialPlayerResponse.adSlots`),undefined);}
});
console.log(JSON.stringify({suite:'upstream-ad-signal-contracts',passed,limitation:'Confirms ad-data intervention evidence; not proof a live video ad would have played.'}));
