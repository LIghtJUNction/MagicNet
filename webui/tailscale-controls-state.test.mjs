import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import ts from './node_modules/typescript/lib/typescript.js';
import { computed, ref, reactive } from 'vue';
import { parseTailscaleControl, transitionConfirmed } from './src/components/pages/tailscaleControl.ts';
const code = readFileSync(new URL('./src/components/pages/TailscaleControls.vue', import.meta.url), 'utf8')
 .match(/<script setup lang="ts">([\s\S]*?)<\/script>/)[1].replace(/^import[\s\S]*?;\s*$/gm,'');
const compiled=ts.transpileModule(code,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText;
const initial={enabled:true,resumable:false,logout_pending:false,local_identity:true,core:'running',revision:'a'.repeat(64)};
const tick=()=>new Promise(r=>setImmediate(r));
function controls(options={}) {
 const calls=[],events=[],hooks={}; let backend={...initial,...options.backend};
 const props=reactive({disabled:false,online:true,hostname:'phone',refreshKey:''});
 const deps={computed,ref,watch:()=>{},defineProps:()=>props,defineEmits:()=>(name,value)=>events.push([name,value]),
  ...Object.fromEntries(['onMounted','onActivated','onDeactivated','onUnmounted'].map(name=>[name,fn=>hooks[name]=fn])),
  t:key=>key,parseTailscaleControl,transitionConfirmed,
  useMagicNet:()=>({state:{busy:false,hasKsu:true},shellQuote:s=>s,openExternal:async()=>{},refreshStatus:async()=>{},
   runPrivateCli:async command=>{calls.push(command);
    if(command==='--json tailscale status') return {ok:true,stdout:JSON.stringify({schema:1,ok:true,command:'tailscale.status',data:backend})};
    if(options.mutate) await options.mutate();
    const action=command.split(' ')[1];
    if(options.fail) return {ok:false,stdout:'private diagnostic, not UI text'};
    backend={...backend,enabled:action==='enable',resumable:action==='disable',local_identity:action!=='logout',logout_pending:false};
    return {ok:true,stdout:''};
   }})};
 const make=new Function(...Object.keys(deps),compiled+'\nreturn {read,change,control,pending,confirmLogout,message,failed};');
 return {...make(...Object.values(deps)),calls,events,hooks,props};
}
test('logout needs explicit confirmation and cannot be accidentally submitted twice',async()=>{
 let resolve; const gate=new Promise(r=>resolve=r),p=controls({mutate:()=>gate});
 await p.read(); p.calls.length=0; await p.change('logout'); assert.deepEqual(p.calls,[]);
 p.confirmLogout.value=true; const work=p.change('logout'); await p.change('logout');
 assert.equal(p.pending.value,true); assert.equal(p.calls.length,1); resolve(); await work;
 assert.equal(p.control.value.local_identity,false); assert.equal(p.failed.value,false);
 assert.equal(p.calls.filter(c=>c.startsWith('tailscale logout')).length,1);
});
test('disable preserves the reported identity and does not claim logout',async()=>{
 const p=controls(); await p.read(); await p.change('disable');
 assert.equal(p.control.value.enabled,false); assert.equal(p.control.value.resumable,true);
 assert.match(p.message.value,/登录信息保留/);
});
test('failed writes are not reported as success and private diagnostics are not displayed',async()=>{
 const p=controls({fail:true}); await p.read(); await p.change('disable');
 assert.equal(p.failed.value,true); assert.equal(p.control.value.enabled,true);
 assert.ok(!p.message.value.includes('private diagnostic'));
});
test('incomplete logout blocks resume, and external busy state blocks destructive writes',async()=>{
 const p=controls({backend:{enabled:false,resumable:true,logout_pending:true}}); await p.read(); p.calls.length=0;
 await p.change('enable'); assert.equal(p.calls.length,0);
 p.confirmLogout.value=true;p.props.disabled=true;await p.change('logout');assert.equal(p.calls.length,0);
});
test('completion after navigation cannot publish a stale status or reload the old page',async()=>{
 let resolve; const gate=new Promise(r=>resolve=r),p=controls({mutate:()=>gate}); await p.read(); p.events.length=0;
 const work=p.change('disable');p.hooks.onDeactivated();resolve();await work;await tick();
 assert.equal(p.control.value.enabled,true);assert.equal(p.pending.value,false);
 assert.ok(!p.events.some(([name])=>name==='changed'||name==='observed'));
});
