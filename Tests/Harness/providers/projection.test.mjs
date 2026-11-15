import test from 'node:test';
import assert from 'node:assert/strict';
import { ProviderProjection } from '../../../src/harness/providers/projection.mjs';
const scope={principal:'alice',generation:'1'};
const make=()=>{const p=new ProviderProjection(env);p.setScope(scope);return p};
const env='55555555-5555-4555-8555-555555555555';
const b = {binding_id:'11111111-1111-4111-8111-111111111111',provider_id:'openai',account_ref:'a',model_id:'m',mode:'inference',catalog_revision:1,capability_id:'22222222-2222-4222-8222-222222222222'};
const c = {capability_id:b.capability_id,version:1,stream_text:false,steer:false,interrupt:false,rollback:false,native_fork:false,tools:false,questions:false,plans:false,resume:false};
const page=(overrides={})=>({snapshot_id:'33333333-3333-4333-8333-333333333333',revision:1,as_of_seq:2,bindings:[],capabilities:[],...overrides});
const event=(seq,change,value)=>({protocol_major:1,environment_id:env,module:'providers',delivery:'inline',committed_at_ms:1,event_id:`44444444-4444-4444-8444-${String(seq).padStart(12,'0')}`,seq,payload:{entity_type:'ProviderBinding',entity_key:JSON.stringify(value.binding_id),change,value}});
test('atomically swaps pages and applies later event once',()=>{
 const p=make();p.begin(page({bindings:[b],next_cursor:'cursor'}),scope);p.buffer(event(3,'upsert',{...b,model_id:'next'}),undefined,scope);assert.equal(p.readState(scope).bindings.length,0);
 p.append(page({capabilities:[c]}),'cursor',scope);assert.equal(p.readState(scope).bindings[0].model_id,'next');p.apply(event(3,'upsert',{...b,model_id:'next'}),undefined,scope);assert.equal(p.readState(scope).bindings.length,1);assert.equal(p.readState(scope).seq,3);
});
test('rejects altered boundary and foreign capability',()=>{
 const p=make();p.begin(page({bindings:[b],next_cursor:'cursor'}),scope);assert.throws(()=>p.append(page({revision:2,capabilities:[c]}),'cursor',scope));
 const q=make();assert.throws(()=>q.begin(page({bindings:[b]}),scope));
});
test('rejects stale boundary and accepts only explicitly resolved references',()=>{
 const p=make();p.begin(page({bindings:[b],capabilities:[c]}),scope);p.apply(event(3,'upsert',{...b,model_id:'new'}),undefined,scope);assert.throws(()=>p.begin(page({bindings:[b],capabilities:[c]}),scope));
 const inline=event(4,'upsert',{...b,model_id:'referenced'});const {payload,...base}=inline;const ref={...base,delivery:'reference',payload_ref:'66666666-6666-4666-8666-666666666666'};
 assert.throws(()=>p.apply(ref,undefined,scope));p.apply(ref,payload,scope);assert.equal(p.readState(scope).bindings[0].model_id,'referenced');
});
test('rejects conflicting event replay',()=>{
 const p=make();p.begin(page({bindings:[b],capabilities:[c]}),scope);const first=event(3,'upsert',{...b,model_id:'a'});p.apply(first,undefined,scope);p.apply(first,undefined,scope);assert.throws(()=>p.apply(event(3,'upsert',{...b,model_id:'different'}),undefined,scope));
});
test('shared provider entity corpus',async()=>{
 const {readFile}=await import('node:fs/promises');const corpus=JSON.parse(await readFile(new URL('./corpus.json',import.meta.url),'utf8'));
 for(const slot of corpus.slots){const p=make();let accepted=true;try{p.begin(page({bindings:[slot.binding],capabilities:[slot.capability]}),scope);}catch{accepted=false}assert.equal(accepted,slot.accept,slot.id)}
});

test('scope changes discard confirmed state, pages and buffered events; stale callbacks cannot mutate',()=>{
 const p=make(), bob={principal:'bob',generation:'1'}, bob2={principal:'bob',generation:'2'};
 p.begin(page({bindings:[b],capabilities:[c]}),scope);
 p.begin(page({revision:2,as_of_seq:3,bindings:[b],next_cursor:'cursor'}),scope);
 p.buffer(event(4,'upsert',{...b,model_id:'old'}),undefined,scope);
 p.setScope(bob); assert.deepEqual(p.readState(bob),{revision:0,seq:0,bindings:[],capabilities:[]});
 assert.throws(()=>p.append(page({revision:2,as_of_seq:3,capabilities:[c]}),'cursor',scope));
 assert.throws(()=>p.apply(event(4,'upsert',b),undefined,scope));
 p.begin(page({bindings:[b],capabilities:[c]}),bob); p.setScope(bob2);
 assert.equal(p.readState(bob2).bindings.length,0); assert.throws(()=>p.apply(event(3,'upsert',b),undefined,bob));
 p.setScope(null); assert.throws(()=>p.readState(scope)); assert.throws(()=>p.begin(page(),bob2));
 const legacy=new ProviderProjection(env); assert.throws(()=>legacy.begin(page()));
});

test('reads require the current principal and authorization generation',()=>{
 const p=make(), bob={principal:'bob',generation:'1'}, bob2={principal:'bob',generation:'2'};
 p.begin(page({bindings:[b],capabilities:[c]}),scope);
 const aliceCallback=()=>p.readState(scope);
 assert.equal(aliceCallback().bindings[0].model_id,'m');
 assert.throws(()=>p.readState());
 assert.throws(()=>p.readState(null));
 p.setScope(bob);
 p.begin(page({bindings:[{...b,model_id:'bob'}],capabilities:[c]}),bob);
 assert.equal(p.readState(bob).bindings[0].model_id,'bob');
 assert.throws(aliceCallback,/inactive or stale provider scope/);
 const oldGenerationCallback=()=>p.readState(bob);
 p.setScope(bob2);
 p.begin(page({bindings:[{...b,model_id:'bob generation 2'}],capabilities:[c]}),bob2);
 assert.equal(p.readState(bob2).bindings[0].model_id,'bob generation 2');
 assert.throws(oldGenerationCallback,/inactive or stale provider scope/);
 p.setScope(null);
 assert.throws(()=>p.readState(bob2),/inactive or stale provider scope/);
 assert.throws(()=>p.readState(),/inactive or stale provider scope/);
 const inactive=new ProviderProjection(env);
 assert.throws(()=>inactive.readState(scope),/inactive or stale provider scope/);
 assert.equal('state' in p,false);
});
