import { validateAgainst } from '../contracts/validate.mjs';

const LIMIT = 4 * 1024 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const integer = n => Number.isSafeInteger(n) && n >= 0;
const size = value => new TextEncoder().encode(JSON.stringify(value)).length;
const clone = value => structuredClone(value);
const validEntity = (type, value) => validateAgainst(type, value).valid && (type === 'ProviderBinding'
  ? UUID.test(value.binding_id) && UUID.test(value.capability_id) && integer(value.catalog_revision) && value.catalog_revision >= 1
  : UUID.test(value.capability_id) && integer(value.version) && (!Object.hasOwn(value, 'context_bytes') || value.context_bytes === null || integer(value.context_bytes)));
const keyOf = (kind, value) => kind === 'ProviderBinding' ? value.binding_id : value.capability_id;
const maps = () => ({ bindings:new Map(), capabilities:new Map() });
const publicState = state => ({revision:state.revision, seq:state.seq, bindings:[...state.maps.bindings.values()].map(clone), capabilities:[...state.maps.capabilities.values()].map(clone)});

/** R1 rehydration: no partial snapshot may overwrite the confirmed projection. */
export class ProviderProjection {
  #current = {revision:0, seq:0, maps:maps(), seen:new Map(), sequences:new Map()};
  #environment;
  #scope = null;
  #authority = null;
  // Scope is supplied by the authenticated host, never derived from provider data.
  // This authority ticket is local only; the host must call setScope when
  // its real authorization changes. Every activation invalidates old work.
  setScope(scope) {
    const valid = scope && typeof scope.principal === 'string' && scope.principal.length > 0 &&
      typeof scope.generation === 'string' && scope.generation.length > 0;
    this.#current = {revision:0, seq:0, maps:maps(), seen:new Map(), sequences:new Map()};
    this.#loading = null;
    this.#scope = null;
    this.#authority = valid ? Object.freeze({principal:scope.principal, generation:scope.generation}) : null;
    return this.#authority;
  }
  // Must run before starting any snapshot/stream/payload request. A new cycle
  // invalidates all earlier responses, even at identical revision and sequence.
  beginRefresh(authority) {
    if (!this.#authority || authority !== this.#authority) throw new Error('inactive or stale provider authority');
    // Keep the confirmed projection until every replacement page validates.
    this.#loading = null;
    this.#scope = Object.freeze({});
    return this.#scope;
  }
  #checkScope(scope) {
    if (!this.#scope || scope !== this.#scope)
      throw new Error('inactive or stale provider scope');
  }
  constructor(environmentId) {if(!UUID.test(environmentId))throw new TypeError('invalid environment');this.#environment=environmentId;}
  #loading = null;
  readState(scope) { this.#checkScope(scope); return publicState(this.#current); }
  begin(page, scope) {
    this.#checkScope(scope);
    if (this.#loading) throw new Error('snapshot already in progress');
    this.#loading={id:page?.snapshot_id, revision:page?.revision, seq:page?.as_of_seq, maps:maps(), events:[], eventBytes:0, next:true, expectedCursor:undefined, cursors:new Set(), seen:new Map(), sequences:new Map()};
    try { this.append(page, undefined, scope); } catch (error) { this.#loading=null; throw error; }
  }
  append(page, requestedCursor, scope) {
    this.#checkScope(scope);
    const pending=this.#loading;
    try {
      if (!pending || !pending.next || requestedCursor!==pending.expectedCursor || !page || !validateAgainst('providersFeatureSnapshot',page).valid || !UUID.test(page.snapshot_id) || page.snapshot_id!==pending.id || page.revision!==pending.revision || page.as_of_seq!==pending.seq || !integer(page.revision) || !integer(page.as_of_seq) || (page.revision<this.#current.revision || page.as_of_seq<this.#current.seq) || !Array.isArray(page.bindings) || !Array.isArray(page.capabilities) || page.bindings.length+page.capabilities.length>100 || size(page)>LIMIT || (page.next_cursor!==undefined && (typeof page.next_cursor!=='string'||!page.next_cursor||new TextEncoder().encode(page.next_cursor).length>512))) throw new Error('invalid snapshot page');
      for (const [kind, collection, target] of [['ProviderBinding',page.bindings,pending.maps.bindings],['ProviderCapabilities',page.capabilities,pending.maps.capabilities]]) {
        for (const entity of collection) {const key=keyOf(kind,entity);if (!validEntity(kind,entity)||target.has(key)) throw new Error('invalid or duplicate entity');target.set(key,clone(entity));}
      }
      if(page.next_cursor!==undefined && pending.cursors.has(page.next_cursor))throw new Error('cursor loop');
      if(page.next_cursor!==undefined)pending.cursors.add(page.next_cursor);
      pending.expectedCursor=page.next_cursor;pending.next=page.next_cursor!==undefined;
      if (!pending.next) {
        for (const binding of pending.maps.bindings.values()) if (!pending.maps.capabilities.has(binding.capability_id)) throw new Error('missing capability');
        const next={revision:pending.revision,seq:pending.seq,maps:pending.maps,seen:new Map(), sequences:new Map()};
        for (const event of pending.events.sort((a,b)=>a.seq-b.seq)) applyTo(next,event,this.#environment);
        this.#current=next;this.#loading=null;
      }
    } catch(error) {this.#loading=null;throw error;}
  }
  buffer(event, resolvedPayload, scope) {
    this.#checkScope(scope);
    try {
      event=resolveEvent(event,resolvedPayload);
      if (!this.#loading) return this.apply(event, undefined, scope);
      validateEvent(event,this.#environment);const pending=this.#loading;if(event.seq<=pending.seq)return;
      const digest=canonical(event), previous=pending.seen.get(event.event_id), seqID=pending.sequences.get(event.seq);
      if(previous){if(previous.seq!==event.seq||previous.digest!==digest)throw new Error('conflicting event id');return;}
      if(seqID || event.seq <= (pending.events.at(-1)?.seq ?? pending.seq))throw new Error('invalid event order');
      pending.eventBytes+=size(event);if(pending.eventBytes>LIMIT || pending.seen.size>=4096)throw new Error('snapshot event buffer overflow');
      pending.seen.set(event.event_id,{seq:event.seq,digest});pending.sequences.set(event.seq,event.event_id);pending.events.push(clone(event));
    } catch(error) {this.#loading=null;throw error;}
  }
  apply(event,resolvedPayload,scope) {this.#checkScope(scope);event=resolveEvent(event,resolvedPayload);if(this.#loading)return this.buffer(event,undefined,scope);applyTo(this.#current,event,this.#environment);}
}
function validateEvent(event,environment) {
  const p=event?.payload;if(!validateAgainst('streamEnvelope',event).valid || !validateAgainst('providersModuleEvent',p).valid || event.environment_id!==environment || Object.hasOwn(event,'thread_id') || event.module!=='providers' || event.delivery!=='inline' || !UUID.test(event?.event_id)||!integer(event?.seq)||!p||!['ProviderBinding','ProviderCapabilities'].includes(p.entity_type)||!['upsert','delete'].includes(p.change)||typeof p.entity_key!=='string')throw new Error('invalid event');
  let key;try{key=JSON.parse(p.entity_key);}catch{throw new Error('invalid entity key');}if(!UUID.test(key)||JSON.stringify(key)!==p.entity_key)throw new Error('invalid entity key');
  if(p.change==='upsert'&&(!validEntity(p.entity_type,p.value)||keyOf(p.entity_type,p.value)!==key))throw new Error('invalid event entity');
  if(p.change==='delete'&&Object.hasOwn(p,'value'))throw new Error('delete has value');
}
function applyTo(state,event,environment) {
  validateEvent(event,environment);
  const digest=canonical(event), previous=state.seen.get(event.event_id), seqID=state.sequences.get(event.seq);
  if(previous){if(previous.seq!==event.seq || previous.digest!==digest)throw new Error('conflicting event id');return;}
  if(seqID && seqID!==event.event_id)throw new Error('conflicting event sequence');
  if(event.seq<=state.seq)return;
  if(state.seen.size>=4096)throw new Error('event window overflow');
  state.seen.set(event.event_id,{seq:event.seq,digest});state.sequences.set(event.seq,event.event_id);
  const p=event.payload;const target=p.entity_type==='ProviderBinding'?state.maps.bindings:state.maps.capabilities;const key=JSON.parse(p.entity_key);
  if(p.change==='delete')target.delete(key);else target.set(key,clone(p.value));state.seq=event.seq;
}

// The caller obtains referenced payloads over the authenticated R1 payload endpoint.
function resolveEvent(event,payload) {
 if(!validateAgainst('streamEnvelope',event).valid)throw new Error('invalid stream envelope');
 if(event.delivery==='reference'){if(!validateAgainst('providersModuleEvent',payload).valid)throw new Error('referenced payload required');const {payload_ref,...rest}=event;return {...rest,delivery:'inline',payload};}
 if(payload!==undefined)throw new Error('unexpected referenced payload');return event;
}

function canonical(value) {if(Array.isArray(value))return `[${value.map(canonical).join(',')}]`;if(value&&typeof value==='object')return `{${Object.keys(value).sort().map(k=>`${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;return JSON.stringify(value);}
