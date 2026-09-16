import { buildTailscaleConfig, inspectTailscale, removeTailscaleEndpoint } from '../webui/src/components/pages/tailscaleSetup.ts';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
const binary=process.argv[2]; if(!binary) throw new Error('compiled core is required');
const tmp=mkdtempSync(join(tmpdir(),'tailscale-remove-'));
try {
  const base=JSON.stringify({dns:{servers:[{type:'local',tag:'local'}],final:'local'},outbounds:[{type:'direct',tag:'direct'}],route:{final:'direct',rules:[]}});
  const config=JSON.parse(buildTailscaleConfig(base,{hostname:'test',authKey:'',mode:'browser'},inspectTailscale(base)));
  const tag=config.endpoints[0].tag;
  config.dns.servers.push({type:'tailscale',tag:tag+'-dns',endpoint:tag});
  config.dns.rules=[{domain_suffix:['ts.net'],server:tag+'-dns'}];
  config.route.rules=[{domain_suffix:['ts.net'],outbound:tag},{ip_cidr:['100.64.0.0/10','fd7a:115c:a1e0::/48'],preferred_by:['tailscale'],outbound:tag}];
  const source=JSON.stringify(config);
  const broken=structuredClone(config); broken.endpoints=[];
  const check=(value)=> {const file=join(tmp,'candidate.json');writeFileSync(file,typeof value==='string'?value:JSON.stringify(value));return spawnSync(binary,['check','-c',file],{encoding:'utf8',timeout:15000});};
  const old=check(broken);assert.notEqual(old.status,0,'old endpoint-only removal must fail core validation');
  const fixed=check(removeTailscaleEndpoint(source,inspectTailscale(source)));
  assert.equal(fixed.status,0,fixed.stderr);
  console.log('Pinned core rejects the old dangling-reference candidate and accepts the repaired configuration');
} finally { rmSync(tmp,{recursive:true,force:true}); }
