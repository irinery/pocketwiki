import test from 'node:test';
import assert from 'node:assert/strict';
import { ProviderProjection } from '../../../src/harness/providers/projection.mjs';
const env='55555555-5555-4555-8555-555555555555';
const b = {binding_id:'11111111-1111-4111-8111-111111111111',provider_id:'openai',account_ref:'a',model_id:'m',mode:'inference',catalog_revision:1,capability_id:'22222222-2222-4222-8222-222222222222'};
const c = {capability_id:b.capability_id,version:1,stream_text:false,steer:false,interrupt:false,rollback:false,native_fork:false,tools:false,questions:false,plans:false,resume:false};
const page=(overrides={})=>({snapshot_id:'33333333-3333-4333-8333-333333333333',revision:1,as_of_seq:2,bindings:[],capabilities:[],...overrides});
const event=(seq,change,value)=>({protocol_major:1,environment_id:env,module:'providers',delivery:'inline',committed_at_ms:1,event_id:`44444444-4444-4444-8444-${String(seq).padStart(12,'0')}`,seq,payload:{entity_type:'ProviderBinding',entity_key:JSON.stringify(value.binding_id),change,value}});
test('atomically swaps pages and applies later event once',()=>{
 const p=new ProviderProjection(env);p.begin(page({bindings:[b],next_cursor:'cursor'}));p.buffer(event(3,'upsert',{...b,model_id:'next'}));assert.equal(p.state.bindings.length,0);
 p.append(page({capabilities:[c]}),'cursor');assert.equal(p.state.bindings[0].model_id,'next');p.apply(event(3,'upsert',{...b,model_id:'next'}));assert.equal(p.state.bindings.length,1);assert.equal(p.state.seq,3);
});
test('rejects altered boundary and foreign capability',()=>{
 const p=new ProviderProjection(env);p.begin(page({bindings:[b],next_cursor:'cursor'}));assert.throws(()=>p.append(page({revision:2,capabilities:[c]}),'cursor'));
 const q=new ProviderProjection(env);assert.throws(()=>q.begin(page({bindings:[b]})));
});
test('rejects stale boundary and accepts only explicitly resolved references',()=>{
 const p=new ProviderProjection(env);p.begin(page({bindings:[b],capabilities:[c]}));p.apply(event(3,'upsert',{...b,model_id:'new'}));assert.throws(()=>p.begin(page({bindings:[b],capabilities:[c]})));
 const inline=event(4,'upsert',{...b,model_id:'referenced'});const {payload,...base}=inline;const ref={...base,delivery:'reference',payload_ref:'66666666-6666-4666-8666-666666666666'};
 assert.throws(()=>p.apply(ref));p.apply(ref,payload);assert.equal(p.state.bindings[0].model_id,'referenced');
});
test('rejects conflicting event replay',()=>{
 const p=new ProviderProjection(env);p.begin(page({bindings:[b],capabilities:[c]}));const first=event(3,'upsert',{...b,model_id:'a'});p.apply(first);p.apply(first);assert.throws(()=>p.apply(event(3,'upsert',{...b,model_id:'different'})));
});
test('shared provider entity corpus',async()=>{
 const {readFile}=await import('node:fs/promises');const corpus=JSON.parse(await readFile(new URL('./corpus.json',import.meta.url),'utf8'));
 for(const slot of corpus.slots){const p=new ProviderProjection(env);let accepted=true;try{p.begin(page({bindings:[slot.binding],capabilities:[slot.capability]}));}catch{accepted=false}assert.equal(accepted,slot.accept,slot.id)}
});
