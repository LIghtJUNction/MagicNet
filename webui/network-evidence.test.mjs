import assert from 'node:assert/strict';
import test from 'node:test';
import { safeRouteHop, safeRouteText, isGoogleEvidence, boundedLines, compactService, selectorEvidence, deviceEvidence, enrichPlayPackages, compactSupport } from './src/composables/networkEvidence.ts';

test('maintained direct/ad/chain tags survive but provider names never do',()=>{
  for(const tag of ['cn-direct','ad-block','lan','chain-exit']) assert.equal(safeRouteHop(tag),tag);
  assert.equal(safeRouteHop('ProviderPrivateLocation'),'[selected-node]');
  assert.equal(safeRouteText('outbound/trojan[ProviderPrivateLocation] route(ProviderPrivateLocation)'), 'outbound/trojan[[selected-node]] route([selected-node])');
});
test('Google evidence is identified by bounded domain suffix, package or known selector',()=>{
  assert.equal(isGoogleEvidence('play.google.com','',''),true);
  assert.equal(isGoogleEvidence('google.com.evil.invalid','',''),false);
  assert.equal(isGoogleEvidence('','com.android.vending',''),true);
  assert.equal(isGoogleEvidence('','','private -> google-proxy'),true);
});
test('line budgeting never chops a rule and reports omitted rows',()=>{
  const full='[section]\n'+('route '+ 'x'.repeat(180)+'\n').repeat(30);
  const short=boundedLines(full,500);
  assert.ok(short.length<=500);
  assert.match(short,/omitted_lines=/);
  for (const line of short.split('\n').filter(x=>x.startsWith('route '))) assert.equal(line.length,186);
  assert.match(compactSupport('[subscription lifecycle]\n'+ 'boring\n'.repeat(100)+'[health]\nok network\n[service status]\ncore=running'), /ok network/);
});
test('selector reports distinguish a blocked exit, cycles and missing evidence',()=>{
  let result=selectorEvidence(JSON.stringify({proxies:{'google-proxy':{now:'private-node'},'private-node':{type:'Reject'}}}));
  assert.match(result,/type=reject/); assert.doesNotMatch(result,/private-node/);
  result=selectorEvidence(JSON.stringify({proxies:{'google-proxy':{now:'google-proxy'}}}));
  assert.match(result,/cycle/); assert.match(selectorEvidence('{}'),/unavailable/);
});
test('machine snapshots disclose only enumerated readiness and numeric memory',()=>{
  const result=compactService(JSON.stringify({schema:1,ok:true,command:'service.status',data:{core:{sing_box:{running:true,rss_kib:100000,secret:'NEVER_PUBLISH'}},api:{url:'http://private',ready:false}}}));
  assert.match(result,/rss_kib=100000/); assert.match(result,/api.ready=false/);assert.doesNotMatch(result,/NEVER|private/);
  assert.equal(compactService('{"schema":1,"ok":false}'),'service_snapshot=unavailable');
});
test('foreground package identity enriches generic Android process names without guessing',()=>{
  const evidence=deviceEvidence(JSON.stringify({schema:1,scope:'read_only_feedback',package_lookup:'available',packages:[{package:'com.android.vending',uid:10123},{package:'private-package',uid:10124}],memory:{processes:[{rss_kib:12345,go_knobs:['GOMEMLIMIT=384MiB','PASSWORD=NEVER_PUBLISH']} ]}}));
  assert.match(evidence.summary,/rss_kib=12345/);assert.match(evidence.summary,/pss_kib=unknown/);assert.doesNotMatch(evidence.summary,/NEVER_PUBLISH/);
  const result=JSON.parse(enrichPlayPackages(JSON.stringify({connections:[{metadata:{processPath:'/system/bin/app_process64 (10123)'}},{metadata:{processPath:'/system/bin/app_process64 (10124)'}}]}),evidence.packages));
  assert.equal(result.connections[0].metadata.processPackageName,'com.android.vending');
  assert.equal(result.connections[1].metadata.processPackageName,undefined);
  assert.equal(deviceEvidence('garbage').summary,'device_evidence=unavailable');
});
