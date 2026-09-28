import test from 'node:test';
import assert from 'node:assert/strict';
import {track,restore,persist,settled} from '../src/pending.ts';
import {request,RpcError} from '../src/protocol.ts';
const input=request('sources.replace',{text:'https://fixture.test/secret-token'},7);
const item=track(input);
function storage() {
  let value=null;
  return {getItem:()=>value,setItem:(_key,text)=>{value=text;},removeItem:()=>{value=null;}};
}
test('only the request ID and method are persisted, never private params',()=>{
  const store=storage(); persist(store,[{...item,params:input.params,expected_revision:7}]);
  const text=store.getItem(''); assert(!text.includes('secret')); assert(!text.includes('params')); assert(!text.includes('revision'));
  assert.deepEqual(restore(store),[item]); persist(store,[]); assert.deepEqual(restore(store),[]);
});
test('corrupt, duplicate, and oversized tracking state cannot be restored',()=>{
  for(const raw of ['{','null',JSON.stringify([item,item]),JSON.stringify([{id:'../escape',method:'service.stop'}]),'x'.repeat(2049),JSON.stringify(Array(9).fill(item))]) assert.deepEqual(restore({getItem:()=>raw}),[]);
});
test('denied storage does not throw or lose in-memory correlation',()=>{
  const store={getItem(){throw new Error('denied');},setItem(){throw new Error('denied');},removeItem(){throw new Error('denied');}};
  assert.deepEqual(restore(store),[]); assert.doesNotThrow(()=>persist(store,[item])); assert.deepEqual(item,{id:input.id,method:input.method});
});
test('missing and unfinished receipts are not negative acknowledgements',()=>{
  assert.equal(settled(item,null),null);
  for(const phase of ['running','unknown','interrupted']) assert.equal(settled(item,{...item,phase,outcome:null}),null);
});
test('a later operation cannot acknowledge or cancel this request',()=>{
  for(const patch of [{id:'0'.repeat(32)},{method:'service.stop'}]) assert.throws(()=>settled(item,{...item,...patch,phase:'completed',outcome:{ok:true,data:{}}}),e=>e instanceof RpcError && e.outcomeUnknown);
});
test('only a matching terminal receipt can settle success or failure',()=>{
  assert.deepEqual(settled(item,{...item,phase:'completed',outcome:{ok:true,data:{revision:8}}}),{ok:true,data:{revision:8}});
  assert.deepEqual(settled(item,{...item,phase:'failed',outcome:{ok:false,error:{code:'missing_dependency',message:'private text'}}}),{ok:false,error:{code:'missing_dependency',effects_possible:false}});
  assert.throws(()=>settled(item,{...item,phase:'failed',outcome:{ok:true,data:{}}}),RpcError);
  assert.throws(()=>settled(item,{...item,phase:'completed',outcome:{ok:true}}),RpcError);
});
