import { ProviderProjection } from './projection.mjs';
import { runtimeFrames } from '../../harness-ui/runtime/sse.mjs';
import { validateAgainst } from '../contracts/validate.mjs';

const MAX_BYTES=4*1024*1024, MAX_EVENTS=4096;
const bytes=value=>new TextEncoder().encode(JSON.stringify(value)).length;

// Inactive coordinator. setScope must be driven by a trusted authorization
// owner; openStream must resolve only after the remote watcher is registered.
export class ProviderStreamFirst {
 #projection; #transport; #notify; #idleTimeout; #environment; #authority=null; #cycle=null;
 constructor({environmentId,transport,onState,idleTimeoutMS=45000}) {
  if(!transport||typeof transport.snapshot!=='function'||typeof transport.openStream!=='function'||typeof transport.payload!=='function'||typeof onState!=='function'||!Number.isInteger(idleTimeoutMS)||idleTimeoutMS<1||idleTimeoutMS>60000)throw new TypeError('provider ports required');
  this.#projection=new ProviderProjection(environmentId);this.#environment=environmentId;this.#transport=transport;this.#notify=onState;this.#idleTimeout=idleTimeoutMS;
 }
 setScope(scope) {this.#retire();this.#authority=this.#projection.setScope(scope);this.#notify(null);}
 close() {this.setScope(null);}
 #retire(){const prior=this.#cycle;this.#cycle=null;if(prior){prior.abort.abort();prior.release();void prior.response?.body?.cancel().catch(()=>{});}}
 #active(c){return this.#cycle===c&&!c.abort.signal.aborted;}
 #check(c){if(!this.#active(c))throw new Error('stale provider cycle');}
 #fail(c){if(!this.#active(c))return;this.#retire();this.#authority=null;this.#projection.setScope(null);this.#notify(null);}
 async start({pageSize=100}={}) {
  if(!this.#authority)throw new Error('inactive provider authority');
  this.#retire();const scope=this.#projection.beginRefresh(this.#authority),abort=new AbortController();let release;
  const gate=new Promise(resolve=>{release=resolve});const c={scope,abort,gate,release,response:null,chain:Promise.resolve(),count:0,bytes:0,ready:false};this.#cycle=c;
  try {
   this.#notify(null);this.#check(c);
   const preliminary=await this.#transport.snapshot({pageSize,signal:abort.signal});this.#check(c);
   if(!validateAgainst('providersFeatureSnapshot',preliminary).valid||!Number.isSafeInteger(preliminary.as_of_seq)||preliminary.as_of_seq<0)throw new Error('invalid preliminary snapshot');
   const response=await this.#transport.openStream({afterSeq:preliminary.as_of_seq,signal:abort.signal});
   if(!this.#active(c)){void response?.body?.cancel().catch(()=>{});throw new Error('stale provider cycle')}
   c.response=response;
   if(!response?.body||!/^text\/event-stream(?:\s*;|\s*$)/i.test(response.headers?.get('content-type')??'')||!/(?:^|,)\s*no-store\s*(?:,|$)/i.test(response.headers?.get('cache-control')??''))throw new Error('invalid stream response');
   // Start consuming immediately: snapshot I/O must not delay stream reads.
   void this.#pump(c);
   let page=await this.#transport.snapshot({pageSize,signal:abort.signal});this.#check(c);
   if(!Number.isSafeInteger(page?.as_of_seq)||page.as_of_seq<preliminary.as_of_seq)throw new Error('snapshot boundary regressed');
   this.#projection.begin(page,c.scope);c.release();
   while(page.next_cursor!==undefined){const cursor=page.next_cursor;page=await this.#transport.snapshot({cursor,pageSize,signal:abort.signal});this.#check(c);this.#projection.append(page,cursor,c.scope)}
   await c.chain;this.#check(c);c.ready=true;this.#notify(this.#projection.readState(c.scope));
  } catch(error){this.#fail(c);throw error}
 }
 async #pump(c){
  try{for await(const event of runtimeFrames(c.response,{signal:c.abort.signal,idleTimeoutMS:this.#idleTimeout})){this.#check(c);const n=bytes(event);if(++c.count>MAX_EVENTS||(c.bytes+=n)>MAX_BYTES)throw new Error('provider event buffer overflow');
    const next=c.chain.then(async()=>{await c.gate;this.#check(c);if(!validateAgainst('streamEnvelope',event).valid||event.environment_id!==this.#environment||event.module!=='providers'||Object.hasOwn(event,'thread_id'))throw new Error('invalid provider event');let payload;if(event.delivery==='reference'){payload=await this.#transport.payload({ref:event.payload_ref,signal:c.abort.signal});this.#check(c)};const payloadBytes=payload===undefined?0:bytes(payload);if(payloadBytes>MAX_BYTES-c.bytes)throw new Error('provider event buffer overflow');c.bytes+=payloadBytes;this.#projection.buffer(event,payload,c.scope);c.count--;c.bytes-=n+payloadBytes;if(c.ready)this.#notify(this.#projection.readState(c.scope));});
    c.chain=next;void next.catch(()=>this.#fail(c));
   }
   throw new Error('provider stream ended');
  }catch{this.#fail(c)}
 }
}
