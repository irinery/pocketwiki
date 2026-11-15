import { validateAgainst } from '../contracts/validate.mjs';

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const MAX=4*1024*1024;

// R1 HTTP adapter only. A successful stream response is usable as a watcher
// barrier only when the Kernel guarantees watcher registration before headers.
export class ProviderR1Transport {
  #base; #bearer; #fetch; #environment; #timeout;
  constructor({baseURL,bearer,environmentId,fetchImpl=fetch,timeoutMS=30000}) {
    const base=new URL(baseURL);
    if(base.username||base.password||base.search||base.hash||base.pathname!=='/'||!(base.protocol==='https:'||(base.protocol==='http:'&&['127.0.0.1','localhost','[::1]'].includes(base.hostname))))throw new TypeError('invalid Kernel origin');
    if(typeof bearer!=='string'||!bearer||/[\r\n]/.test(bearer)||!UUID.test(environmentId)||typeof fetchImpl!=='function'||!Number.isInteger(timeoutMS)||timeoutMS<1||timeoutMS>30000)throw new TypeError('invalid provider transport');
    this.#base=base;this.#bearer=bearer;this.#environment=environmentId;this.#fetch=fetchImpl;this.#timeout=timeoutMS;
  }
  async #get(path,signal,accept='application/json') {
    const response=await this.#fetch(new URL(path,this.#base),{signal,redirect:'error',cache:'no-store',headers:{authorization:`Bearer ${this.#bearer}`,accept}});
    if(signal?.aborted){void response.body?.cancel().catch(()=>{});throw signal.reason;}
    if(!response.ok) {let code;try{const body=await readJSON(response,4096,signal);if(validateAgainst('harnessError',body).valid)code=body.code;}catch{}throw Object.assign(new Error(`Kernel HTTP ${response.status}`),{status:response.status,code});}
    return response;
  }
  async snapshot({cursor,pageSize=100,signal}) {
    if(!Number.isInteger(pageSize)||pageSize<1||pageSize>100||(cursor!==undefined&&(typeof cursor!=='string'||!cursor||new TextEncoder().encode(cursor).length>512)))throw new TypeError('invalid snapshot request');
    const query=new URLSearchParams({module:'providers',page_size:String(pageSize)});if(cursor!==undefined)query.set('cursor',cursor);
    const body=await withDeadline(this.#timeout,signal,async bounded=>readJSON(await this.#get(`/v1/harness/environments/${this.#environment}/snapshot?${query}`,bounded),MAX,bounded));
    if(!validateAgainst('snapshotEnvelope',body).valid||body.module!=='providers'||!validateAgainst('providersFeatureSnapshot',body.data).valid||body.data.bindings.length+body.data.capabilities.length>pageSize)throw new Error('invalid provider snapshot');
    return body.data;
  }
  async openStream({afterSeq,signal}) {
    if(!Number.isSafeInteger(afterSeq)||afterSeq<0)throw new TypeError('invalid stream cursor');
    const query=new URLSearchParams({after_seq:String(afterSeq),modules:'providers'});
    const response=await withDeadline(this.#timeout,signal,bounded=>this.#get(`/v1/harness/streams/environment/${this.#environment}?${query}`,bounded,'text/event-stream'));
    if(!/^text\/event-stream(?:\s*;|\s*$)/i.test(response.headers.get('content-type')??'')||!/(?:^|,)\s*no-store\s*(?:,|$)/i.test(response.headers.get('cache-control')??'')||!response.body){void response.body?.cancel();throw new Error('invalid stream response');}
    return response;
  }
  async payload({ref,signal}) {if(!UUID.test(ref))throw new TypeError('invalid payload reference');return withDeadline(this.#timeout,signal,async bounded=>readJSON(await this.#get(`/v1/harness/payloads/${ref}`,bounded),MAX,bounded));}
}
async function readJSON(response,limit,signal){
 if(!response.body)throw new Error('missing response body');const reader=response.body.getReader(),chunks=[];let size=0;
 const cancel=()=>{void reader.cancel().catch(()=>{})};if(signal?.aborted)cancel();else signal?.addEventListener('abort',cancel,{once:true});
 try{for(;;){const {value,done}=await reader.read();if(signal?.aborted)throw signal.reason;if(done)break;size+=value.byteLength;if(size>limit){void reader.cancel();throw new Error('response exceeds limit')};chunks.push(value)};const bytes=new Uint8Array(size);let at=0;for(const chunk of chunks){bytes.set(chunk,at);at+=chunk.byteLength};return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes))}finally{signal?.removeEventListener('abort',cancel);reader.releaseLock()}
}
async function withDeadline(ms,outer,action){
 const controller=new AbortController(),signal=outer?AbortSignal.any([outer,controller.signal]):controller.signal;
 const timer=setTimeout(()=>controller.abort(new Error('provider request deadline exceeded')),ms);let listener;
 const abort=new Promise((_,reject)=>{listener=()=>reject(signal.reason);if(signal.aborted)listener();else signal.addEventListener('abort',listener,{once:true})});
 try{return await Promise.race([Promise.resolve().then(()=>{signal.throwIfAborted();return action(signal)}),abort])}finally{clearTimeout(timer);signal.removeEventListener('abort',listener)}
}
