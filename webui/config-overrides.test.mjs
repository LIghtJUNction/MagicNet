import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import ts from 'typescript';
import { decodeMachineData, machineErrorCode } from './src/composables/machineStatus.ts';
const source=readFileSync(new URL('./src/components/pages/ConfigOverridesCard.vue',import.meta.url),'utf8');
const script=source.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)[1].replace(/^import .*;\n/gm,'');
const code=ts.transpileModule(script+'\nglobalThis.fixture={text,savedText,revision,pending,busy,message,failed,reloadRequested,requestReload,discardAndReload,load,preview,save,reset};',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
function setup(handler) {
 const calls=[],payloads=[],removed=[];
 const context=vm.createContext({ref:value=>({value}),computed:fn=>({get value(){return fn()}}),onMounted(){},t:(s,p={})=>s.replace(/\{(\w+)\}/g,(_,k)=>p[k]??k),decodeMachineData,machineErrorCode,shellQuote:s=>JSON.stringify(s),Date,Math,JSON,Error,Number,
 useMagicNet:()=>({async runPrivateCli(command,...rest){calls.push([command,...rest]);return handler(command)},async stagePrivatePayload(_ns,name,content){payloads.push(JSON.parse(content));return {basename:name,path:'/private/payload.json'}},async removePrivatePayload(_ns,name){removed.push(name);return true},async refreshStatus(){}})});
 vm.runInContext(code,context);return {f:context.fixture,calls,payloads,removed};
}
function response(command,data={}){return {ok:true,stdout:JSON.stringify({schema:1,ok:true,command,data})}}
const status={configured_revision:2,pending:false,patch:{log:{level:'warn'}}};
test('private inspector rejects malformed data without echoing it',async()=>{
 const {f}=setup(()=>({ok:true,stdout:'private-token-not-json'}));await f.load();
 assert.equal(f.revision.value,null);assert.equal(f.failed.value,true);assert.ok(!f.message.value.includes('private-token'));
});
test('save uses a private file and cleans it after the request',async()=>{
 const x=setup(c=>c.includes('inspect')?response('override.inspect',status):response('override.set',{configured_revision:3,pending:true}));
 await x.f.load();x.f.text.value='{"dns":{"cache_capacity":8192}}';await x.f.save(false);
 assert.equal(x.payloads[0].expected_revision,2);assert.equal(x.payloads[0].patch.dns.cache_capacity,8192);assert.equal(x.f.pending.value,true);assert.equal(x.removed.length,1);assert.ok(x.calls.every(call=>!call[0].includes('cache_capacity')));
});
test('stale writes preserve the draft and never activate it',async()=>{
 const x=setup(c=>c.includes('inspect')?response('override.inspect',status):({ok:false,stdout:JSON.stringify({schema:1,ok:false,command:'override.set',error:{code:'override.conflict'}})}));
 await x.f.load();const draft='{"log":{"level":"info"}}';x.f.text.value=draft;await x.f.save(true);
 assert.equal(x.f.text.value,draft);assert.equal(x.f.revision.value,2);assert.equal(x.f.failed.value,true);assert.equal(x.calls.filter(c=>c[0].includes(' apply-file')).length,0);assert.equal(x.removed.length,1);
});
test('reset clears only override intent then applies it',async()=>{
 const x=setup(c=>c.includes('inspect')?response('override.inspect',status):response(c.includes('reset-file')?'override.reset':'override.apply',{configured_revision:3,pending:c.includes('reset-file')}));
 await x.f.load();await x.f.reset();assert.equal(JSON.stringify(x.payloads[0]),'{"expected_revision":2}');assert.equal(x.f.text.value,'{}\n');assert.equal(x.f.pending.value,false);assert.ok(x.calls.some(c=>c[0].startsWith('--json override apply-file ')));
});
test('an edit during save is not marked as saved',async()=>{
 let finish;const x=setup(c=>c.includes('inspect')?response('override.inspect',status):new Promise(resolve=>{finish=resolve}));
 await x.f.load();x.f.text.value='{"log":{"level":"info"}}';const submitted=x.f.text.value;const saving=x.f.save(false);while(!finish) await Promise.resolve();x.f.text.value='{"log":{"level":"debug"}}';finish(response('override.set',{configured_revision:3,pending:true}));await saving;assert.equal(x.f.savedText.value,submitted);assert.notEqual(x.f.text.value,x.f.savedText.value);
});

test('dirty reload requires an explicit discard and keeps the draft until then', async()=>{
 let count=0;
 const x=setup(()=>response('override.inspect',{...status,configured_revision:++count,patch:{log:{level:count===1?'warn':'error'}}}));
 await x.f.load();x.f.text.value='{"log":{"level":"debug"}}';
 x.f.requestReload();assert.equal(x.f.reloadRequested.value,true);assert.equal(count,1);
 assert.equal(x.f.text.value,'{"log":{"level":"debug"}}');
 await x.f.discardAndReload();assert.equal(count,2);assert.equal(x.f.revision.value,2);
 assert.equal(JSON.parse(x.f.text.value).log.level,'error');
});
