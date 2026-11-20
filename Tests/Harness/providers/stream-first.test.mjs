import test from 'node:test';
import assert from 'node:assert/strict';
import { ProviderStreamFirst } from '../../../src/harness/providers/stream-first.mjs';
import { ProviderR1Transport } from '../../../src/harness/providers/transport.mjs';

const env='55555555-5555-4555-8555-555555555555';
const b={binding_id:'11111111-1111-4111-8111-111111111111',provider_id:'openai',account_ref:'a',model_id:'m',mode:'inference',catalog_revision:1,capability_id:'22222222-2222-4222-8222-222222222222'};
const cap={capability_id:b.capability_id,version:1,stream_text:false,steer:false,interrupt:false,rollback:false,native_fork:false,tools:false,questions:false,plans:false,resume:false};
const page=(seq=2,bindings=[b],capabilities=[cap])=>({snapshot_id:'33333333-3333-4333-8333-333333333333',revision:1,as_of_seq:seq,bindings,capabilities});
const event=(seq,model='new')=>({protocol_major:1,event_id:`44444444-4444-4444-8444-${String(seq).padStart(12,'0')}`,environment_id:env,seq,committed_at_ms:1,module:'providers',delivery:'inline',payload:{entity_type:'ProviderBinding',entity_key:JSON.stringify(b.binding_id),change:'upsert',value:{...b,model_id:model}}});
const defer=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject}};
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function stream(){let controller;const body=new ReadableStream({start(c){controller=c}});return {response:new Response(body,{headers:{'content-type':'text/event-stream','cache-control':'no-store'}}),emit(e){controller.enqueue(new TextEncoder().encode(`id: ${e.seq}\ndata: ${JSON.stringify(e)}\n\n`))},end(){controller.close()}}}

test('opens stream before displayed snapshot and buffers events received while fetching it',async()=>{
 const display=defer(),ready=defer(),s=stream(),seen=[],calls=[];let snapshots=0;
 const transport={async snapshot(){calls.push('snapshot');return ++snapshots===1?page(2,[{...b,model_id:'preliminary'}],[cap]):display.promise},async openStream({afterSeq}){calls.push(`stream:${afterSeq}`);await ready.promise;return s.response},async payload(){throw Error('unexpected')}};
 const c=new ProviderStreamFirst({environmentId:env,transport,onState:value=>seen.push(value)});c.setScope({principal:'alice',generation:'1'});const started=c.start();await tick();
 assert.deepEqual(calls,['snapshot','stream:2']);assert.deepEqual(seen,[null,null]);ready.resolve();await tick();assert.deepEqual(calls,['snapshot','stream:2','snapshot']);s.emit(event(3));await tick();display.resolve(page());await started;
 assert.equal(seen.length,3);assert.equal(seen[2].bindings[0].model_id,'new');assert.equal(seen[2].seq,3);c.close();
});

test('EOF invalidates state and delayed snapshot cannot revive it',async()=>{
 const display=defer(),s=stream(),seen=[];let n=0;const transport={async snapshot(){return ++n===1?page():display.promise},async openStream(){return s.response},async payload(){throw Error('unexpected')}};
 const c=new ProviderStreamFirst({environmentId:env,transport,onState:v=>seen.push(v)});c.setScope({principal:'alice',generation:'1'});const started=c.start();await tick();s.end();await tick();display.resolve(page());await assert.rejects(started,/stale/);assert.deepEqual(seen,[null,null,null]);await assert.rejects(c.start(),/inactive/);
});

test('auth loss while referenced payload is pending fences the delayed response',async()=>{
 const payload=defer(),s=stream(),seen=[];let calls=0;const transport={async snapshot(){calls++;return page()},async openStream(){return s.response},async payload(){return payload.promise}};
 const c=new ProviderStreamFirst({environmentId:env,transport,onState:v=>seen.push(v)});c.setScope({principal:'alice',generation:'1'});await c.start();
 const e=event(3);const {payload:body,...rest}=e;s.emit({...rest,delivery:'reference',payload_ref:'66666666-6666-4666-8666-666666666666'});await tick();c.setScope(null);payload.resolve(body);await tick();assert.equal(seen.at(-1),null);assert.equal(seen.filter(x=>x?.seq===3).length,0);assert.equal(calls,2);
});

test('the real HTTP adapter uses R1 paths, bearer headers and rejects invalid SSE headers',async()=>{
 const requests=[];const fetchImpl=async(url,options)=>{requests.push({url:String(url),options});if(String(url).includes('/streams/'))return new Response(new ReadableStream(),{headers:{'content-type':'text/event-stream','cache-control':'no-store'}});return Response.json({module:'providers',data:page()})};
 const t=new ProviderR1Transport({baseURL:'http://127.0.0.1:9999',environmentId:env,bearer:'secret',fetchImpl});const snap=await t.snapshot({pageSize:100});assert.equal(snap.as_of_seq,2);const response=await t.openStream({afterSeq:2});assert.equal(requests[0].options.headers.authorization,'Bearer secret');assert.ok(requests[1].url.includes(`/streams/environment/${env}?after_seq=2&modules=providers`));assert.ok(!requests[1].url.includes('secret'));await response.body.cancel();
 const bad=new ProviderR1Transport({baseURL:'http://127.0.0.1:9999',environmentId:env,bearer:'secret',fetchImpl:async()=>new Response('',{headers:{'content-type':'application/json'}})});await assert.rejects(bad.openStream({afterSeq:0}),/invalid stream/);
});

test('retention error clears previously confirmed view and rejects new work',async()=>{
 const s=stream(),seen=[];let count=0;const t={async snapshot(){if(++count<=2)return page();throw Object.assign(new Error('expired'),{code:'ERR_CURSOR_EXPIRED'})},async openStream(){return s.response},async payload(){throw Error('unexpected')}};
 const c=new ProviderStreamFirst({environmentId:env,transport:t,onState:v=>seen.push(v)});c.setScope({principal:'alice',generation:'1'});await c.start();assert.equal(seen.at(-1).bindings.length,1);await assert.rejects(c.start(),/expired/);assert.equal(seen.at(-1),null);await assert.rejects(c.start(),/inactive/);
});

test('new refresh ignores an old stream that fails later and fences delayed first page',async()=>{
 const oldDisplay=defer(),old=stream(),next=stream(),seen=[];let n=0,opens=0;const t={async snapshot(){n++;if(n===2)return oldDisplay.promise;return page()},async openStream(){return ++opens===1?old.response:next.response},async payload(){throw Error('unexpected')}};
 const c=new ProviderStreamFirst({environmentId:env,transport:t,onState:v=>seen.push(v)});c.setScope({principal:'alice',generation:'1'});const first=c.start();await tick();await c.start();oldDisplay.resolve(page(2,[{...b,model_id:'old'}],[cap]));await assert.rejects(first,/stale/);await tick();assert.equal(seen.at(-1).bindings[0].model_id,'m');c.close();
});

test('bounded pending stream queue fails closed before displayed snapshot returns',async()=>{
 const display=defer(),s=stream(),seen=[];let n=0;const t={async snapshot(){return ++n===1?page():display.promise},async openStream(){return s.response},async payload(){throw Error('unexpected')}};
 const c=new ProviderStreamFirst({environmentId:env,transport:t,onState:v=>seen.push(v)});c.setScope({principal:'alice',generation:'1'});const started=c.start();await tick();for(let i=3;i<4102;i++)s.emit(event(i));for(let i=0;i<10&&seen.length<3;i++)await tick();assert.equal(seen.at(-1),null);assert.equal(seen.length,3);display.resolve(page());await assert.rejects(started,/stale/);
});

test('starting a replacement cycle immediately hides state until watcher and snapshot are ready',async()=>{
 const held=defer(),s=stream(),seen=[];let n=0;const t={async snapshot(){return ++n<=2?page():held.promise},async openStream(){return s.response},async payload(){throw Error('unexpected')}};
 const c=new ProviderStreamFirst({environmentId:env,transport:t,onState:v=>seen.push(v)});c.setScope({principal:'alice',generation:'1'});await c.start();assert.equal(seen.at(-1).bindings.length,1);const next=c.start();assert.equal(seen.at(-1),null);c.close();held.resolve(page());await assert.rejects(next,/stale/);
});

test('silent stream times out, cancels reader and clears visibility',async()=>{
 let cancelled=false;const body=new ReadableStream({cancel(){cancelled=true}}),response=new Response(body,{headers:{'content-type':'text/event-stream','cache-control':'no-store'}}),seen=[];
 const t={async snapshot(){return page()},async openStream(){return response},async payload(){throw Error('unexpected')}};const c=new ProviderStreamFirst({environmentId:env,transport:t,onState:v=>seen.push(v),idleTimeoutMS:15});c.setScope({principal:'alice',generation:'1'});await c.start();await new Promise(resolve=>setTimeout(resolve,40));assert.equal(seen.at(-1),null);assert.equal(cancelled,true);await assert.rejects(c.start(),/inactive/);
});

test('HTTP deadlines cover stuck headers and JSON bodies even if ports ignore abort',async()=>{
 const never=()=>new Promise(()=>{});const headers=new ProviderR1Transport({baseURL:'http://127.0.0.1:9999',environmentId:env,bearer:'secret',timeoutMS:15,fetchImpl:never});await assert.rejects(headers.openStream({afterSeq:0}),/deadline/);
 let cancelled=false;const body=new ProviderR1Transport({baseURL:'http://127.0.0.1:9999',environmentId:env,bearer:'secret',timeoutMS:15,fetchImpl:async()=>new Response(new ReadableStream({cancel(){cancelled=true}}),{headers:{'content-type':'application/json'}})});await assert.rejects(body.snapshot({pageSize:100}),/deadline/);await tick();assert.equal(cancelled,true);
});

test('real loopback HTTP adapter establishes SSE before displayed snapshot',async()=>{
 const http=await import('node:http');const {once}=await import('node:events');let snapshots=0,watcher,streamRequest;const order=[],seen=[];
 const server=http.createServer((req,res)=>{
  assert.equal(req.headers.authorization,'Bearer secret');
  if(req.url.startsWith('/v1/harness/environments/')){snapshots++;order.push(`snapshot:${snapshots}`);res.setHeader('content-type','application/json');if(snapshots===2){assert.ok(watcher);const e=event(3);watcher.write(`id: ${e.seq}\ndata: ${JSON.stringify(e)}\n\n`)};res.end(JSON.stringify({module:'providers',data:page()}));return}
  if(req.url.startsWith('/v1/harness/streams/')){order.push('watcher');streamRequest=req;watcher=res;res.writeHead(200,{'content-type':'text/event-stream','cache-control':'no-store'});res.flushHeaders();return}
  res.writeHead(404);res.end();
 });
 server.listen(0,'127.0.0.1');await once(server,'listening');const address=server.address();
 const transport=new ProviderR1Transport({baseURL:`http://127.0.0.1:${address.port}`,environmentId:env,bearer:'secret',timeoutMS:1000});
 const c=new ProviderStreamFirst({environmentId:env,transport,onState:v=>seen.push(v)});
 try{c.setScope({principal:'alice',generation:'1'});await c.start();for(let i=0;i<100&&seen.at(-1)?.seq!==3;i++)await new Promise(resolve=>setTimeout(resolve,1));assert.deepEqual(order,['snapshot:1','watcher','snapshot:2']);assert.equal(seen.at(-1).seq,3);assert.equal(seen.at(-1).bindings[0].model_id,'new');}finally{c.close();streamRequest?.destroy();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
});

test('idle timeout clears visibility even when stream cancel never resolves',async()=>{
 const body=new ReadableStream({cancel(){return new Promise(()=>{})}}),response=new Response(body,{headers:{'content-type':'text/event-stream','cache-control':'no-store'}}),seen=[];
 const t={async snapshot(){return page()},async openStream(){return response},async payload(){throw Error('unexpected')}};const c=new ProviderStreamFirst({environmentId:env,transport:t,onState:v=>seen.push(v),idleTimeoutMS:15});c.setScope({principal:'alice',generation:'1'});await c.start();await new Promise(resolve=>setTimeout(resolve,40));assert.equal(seen.at(-1),null);await assert.rejects(c.start(),/inactive/);
});

test('rejects foreign referenced events before resolving their payload',async()=>{
 const s=stream(),seen=[];let fetched=0;const t={async snapshot(){return page()},async openStream(){return s.response},async payload(){fetched++;return {}}};
 const c=new ProviderStreamFirst({environmentId:env,transport:t,onState:v=>seen.push(v)});c.setScope({principal:'alice',generation:'1'});await c.start();const e=event(3);const {payload,...base}=e;s.emit({...base,environment_id:'77777777-7777-4777-8777-777777777777',delivery:'reference',payload_ref:'66666666-6666-4666-8666-666666666666'});for(let i=0;i<5&&seen.at(-1)!==null;i++)await tick();assert.equal(fetched,0);assert.equal(seen.at(-1),null);
});
