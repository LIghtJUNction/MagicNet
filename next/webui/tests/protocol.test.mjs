import test from 'node:test';
import assert from 'node:assert/strict';
import {request, encode, decode, settings, status, capabilities, RpcError} from '../src/protocol.ts';
const success = (r, data) => JSON.stringify({schema:1, ok:true, command:r.method, request_id:r.id, data});
test('Unicode and shell syntax stay inside the encoded stdin payload', () => {
  const r = request('sources.import',{body:'日本😀\n$(touch /tmp/do-not-execute); "\\'},3);
  const decoded = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(encode(r)),c=>c.charCodeAt(0))));
  assert.deepEqual(decoded,r); assert.match(r.id,/^[a-f0-9]{32}$/);
});
test('IDs are independent and revisions cannot lose integer precision', () => {
  const ids = new Set(Array.from({length:200},()=>request('status').id)); assert.equal(ids.size,200);
  assert.throws(()=>request('settings.replace',{},Number.MAX_SAFE_INTEGER+1),RpcError);
  assert.throws(()=>request('status;echo secret'),RpcError);
});
test('successful response must bind the request ID, command and exit code',()=>{
  const r=request('status'); assert.deepEqual(decode(success(r,{phase:'stopped'}),0,r),{phase:'stopped'});
  for(const mutate of [v=>({...v,schema:2}),v=>({...v,request_id:'0'.repeat(32)}),v=>({...v,command:'service.start'}),v=>({...v,ok:'true'})]){
    assert.throws(()=>decode(JSON.stringify(mutate(JSON.parse(success(r,{})))),0,r),RpcError);
  }
  assert.throws(()=>decode(success(r,{}),1,r),RpcError);
});
test('human logs, concatenated JSON and missing payloads cannot mean success',()=>{
  const r=request('status'); for(const text of ['started successfully','{}{}','null',JSON.stringify({schema:1,ok:true,command:r.method,request_id:r.id})]) assert.throws(()=>decode(text,0,r),RpcError);
});
test('a structured failure retains its effects-possible flag without leaking message text',()=>{
  const r=request('service.stop'); try { decode(JSON.stringify({schema:1,ok:false,command:r.method,request_id:r.id,error:{code:'stop_timeout',effects_possible:true,message:'secret'}}),1,r); assert.fail(); }
  catch(e){assert.equal(e.code,'stop_timeout');assert.equal(e.effectsPossible,true);assert(!e.message.includes('secret'));}
});
test('partial and unsafe settings snapshots are rejected rather than defaulted empty',()=>{
  for(const value of [null,{}, {schema:1,revision:1,enabled:false,mode:'tun',user_agent:'ua',sources:[],template:null}, {schema:1,revision:Number.MAX_SAFE_INTEGER+1,enabled:false,mode:'tun',user_agent:'ua',sources:[],template:{}}]) assert.throws(()=>settings(value),RpcError);
});
test('status is not inferred from truthy values or a core process alone',()=>{
  assert.throws(()=>status({phase:'healthy',configured:true}),RpcError);
  assert.throws(()=>status({phase:'running',configured:'false',configured_revision:1,effective_revision:1,pending_changes:false,recovery_pending:false,mode:'tun',source_count:0,network_health:'unknown',observation:'process_identity_only',operation:null}),RpcError);
});
test('oversized requests and responses are bounded before native dispatch',()=>{
  assert.throws(()=>encode(request('sources.import',{body:'x'.repeat(4*1024*1024)})),RpcError);
  assert.throws(()=>decode('x'.repeat(8*1024*1024+1),0,request('status')),RpcError);
});

test('all uncorrelated write replies preserve uncertainty instead of authorizing a retry',()=>{
  const r=request('sources.replace',{text:'https://fixture.test/private'},0);
  const reply=JSON.parse(success(r,{}));
  for(const [body,errno] of [['{',0],['null',0],[JSON.stringify({...reply,request_id:'0'.repeat(32)}),0],[JSON.stringify({...reply,command:'status'}),0],[success(r,{}),1]]) {
    assert.throws(()=>decode(body,errno,r),e=>e.code==='invalid_response' && e.outcomeUnknown && e.effectsPossible);
  }
  assert.throws(()=>decode('{',0,request('status')),e=>!e.outcomeUnknown && !e.effectsPossible);
});
test('correlated server rejection is known even if partial effects need recovery',()=>{
  const r=request('service.stop');
  const body=JSON.stringify({schema:1,ok:false,request_id:r.id,command:r.method,error:{code:'stop_timeout',effects_possible:true}});
  assert.throws(()=>decode(body,1,r),e=>e.code==='stop_timeout' && e.effectsPossible && !e.outcomeUnknown);
});
test('status scalar fields cannot be arrays, negative counts, or unsafe integers',()=>{
  const value={phase:'stopped',configured:false,configured_revision:0,effective_revision:0,pending_changes:false,recovery_pending:false,mode:'tun',source_count:0,network_health:'unknown',observation:'process_identity_only',operation:null};
  assert.deepEqual(status(value),value);
  for(const patch of [{phase:['running']},{configured_revision:-1},{effective_revision:Number.MAX_SAFE_INTEGER+1},{source_count:-1},{source_count:33},{mode:['tun']},{operation:{id:'bad',method:'service.stop',phase:'running'}}]) assert.throws(()=>status({...value,...patch}),RpcError);
});
test('settings require unique source identities and real scalar values',()=>{
  const source={id:'a'.repeat(32),url:'https://a.test/sub',enabled:true};
  const value={schema:1,revision:0,enabled:false,mode:'tun',user_agent:'MagicNet',sources:[source],template:{}};
  assert.deepEqual(settings(value),value);
  for(const patch of [{mode:['tun']},{user_agent:'bad\nheader'},{sources:[source,{...source,url:'https://b.test/sub'}]},{sources:[source,{...source,id:'b'.repeat(32)}]}]) assert.throws(()=>settings({...value,...patch}),RpcError);
});
test('capabilities reject transport text and malformed operation lists',()=>{
  const value={schema:1,read:['status'],write:['service.stop'],unported:['tailscale'],lifecycle:'experimental',android_acceptance:'not_verified'};
  assert.deepEqual(capabilities(value),value);
  for(const patch of [{lifecycle:['accepted']},{write:['service.stop;echo']},{read:'status'},{android_acceptance:''}]) assert.throws(()=>capabilities({...value,...patch}),RpcError);
});
