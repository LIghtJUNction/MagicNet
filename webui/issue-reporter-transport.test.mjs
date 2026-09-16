import assert from 'node:assert/strict';
import test from 'node:test';
import { createMagicNetIssue } from './src/composables/issueReporter.ts';

for (const unavailable of [false, true]) test(`route collection retains partial evidence with failed transport=${unavailable}`,async()=>{
  const previousWindow=Object.getOwnPropertyDescriptor(globalThis,'window');
  const previousNavigator=Object.getOwnPropertyDescriptor(globalThis,'navigator');
  let copied='',opened='';const calls=[];
  Object.defineProperty(globalThis,'navigator',{configurable:true,value:{clipboard:{writeText:async text=>{copied=text}}}});
  Object.defineProperty(globalThis,'window',{configurable:true,value:{open:url=>{opened=url}}});
  const state={task:'',notice:'',busy:false,phase:'idle',output:'',hasKsu:false,
    runtime:{singBoxState:'sing-box'},lastCommand:'',operationCapture:{command:''},backgroundTask:{label:'',args:'',status:'idle'}};
  const device={schema:1,scope:'read_only_feedback',package_lookup:'available',packages:[{package:'com.android.vending',uid:10123}],memory:{processes:[{rss_kib:102400,anonymous_kib:50000}]}};
  const responses={
    'api conns':JSON.stringify({connections:[{metadata:{host:'play.google.com',processPath:'/system/bin/app_process64 (10123)'},chains:['private-provider','google-proxy'],rule:'route(google-proxy)'}]}),
    '--json service status':JSON.stringify({schema:1,ok:true,command:'service.status',data:{core:{sing_box:{running:true,rss_kib:102400}}}}),
    'api proxies':JSON.stringify({proxies:{'google-proxy':{now:'private-provider'},'private-provider':{type:'Trojan'}}}),
    'service logs sing-box 240':'outbound/trojan[private-provider] play.google.com timeout',
    'support bundle':'[service status]\ncore=running\n[health]\nwarn DNS\n[subscription lifecycle]\nready',
  };
  try{
    await createMagicNetIssue({state,
      runShell:async command=>command.includes('feedback-snapshot.sh')?JSON.stringify(device):command.includes('module.prop')?'version=v1.5.5':'Android test fixture',
      runCli:async(args,_label,quiet)=>{calls.push([args,quiet]);if(unavailable&&args==='api proxies')throw Error('private transport detail');return responses[args]??'unavailable';},
    },{kind:'route-feedback',summary:'Play fails',reproduction:'',expected:'',actual:'',frequency:''});
    assert.equal(state.phase,'done');assert.equal(state.busy,false);
    assert.equal(new URL(opened).searchParams.get('body'),copied);
    for(const name of ['api conns','--json service status','api proxies','service logs sing-box 240','support bundle'])assert.ok(calls.some(([command,quiet])=>command===name&&quiet===true));
    for(const section of ['core and readiness','selector paths','memory and configuration','route feedback samples','routing/error log tail'])assert.ok(copied.includes(`[${section}]`),section);
    assert.match(copied,/play\.google\.com/);assert.match(copied,/com\.android\.vending/);
    assert.match(copied,/rss_kib=102400/);assert.ok(copied.length<=5200);
    assert.match(state.output,/Full focused evidence/);
    assert.doesNotMatch(copied+state.output,/private-provider|private transport detail/);
    assert.match(copied,unavailable?/selectors=unavailable/:/type=trojan/);
  }finally{
    if(previousWindow)Object.defineProperty(globalThis,'window',previousWindow);else delete globalThis.window;
    if(previousNavigator)Object.defineProperty(globalThis,'navigator',previousNavigator);else delete globalThis.navigator;
  }
});
