import { expect, test } from '@playwright/test';

async function mount(page, failure = '') {
  await page.addInitScript(({failure}) => {
    localStorage.setItem('magicnet.webui.onboarding.v1','dismissed');
    window.__playRecovery = {phase:'new',restricted:true,writes:[],failure};
    const candidate='a'.repeat(64);
    const packages=['com.google.android.gms','com.google.android.gsf'];
    window.ksu={spawn(command,_args,_options,callbackName){setTimeout(()=>{
      const f=window.__playRecovery;
      let output='', errno=0;
      const envelope=(command,data)=>JSON.stringify({schema:1,ok:true,command,data});
      if(command.includes('--json capabilities')) output=envelope('machine.capabilities',{commands:['repair','check','reapply','rollback'].map(a=>`network-access.${a}`)});
      else if(command.includes('--json network-access inspect')) output=envelope('network-access.inspect',{
        package_inventory:'observed',providers:[{provider:'oplus',status:failure==='unsupported'?'unsupported':'observed'}],
        entries: f.restricted && failure!=='unsupported' ? [{candidate,provider:'oplus',packages,configured:'reject_all',manual_repair_supported:true}] : [],
        recovery:{status:'observed',records:f.phase==='new'?[]:[{candidate,provider:'oplus',packages,recorded_phase:f.phase}]},
      });
      else if(command.includes('--json network-access check')) output=envelope('network-access.check',{candidate,observed_policy:f.restricted?'original_policy':'recovered_policy'});
      else if(/--json network-access (repair|reapply|rollback)/.test(command)){
        const action=command.match(/--json network-access (repair|reapply|rollback)/)[1];
        f.writes.push(action);
        if(f.failure==='write') {errno=1;output=JSON.stringify({schema:1,ok:false,command:'machine.error',error:{code:'repair_not_effective',message:'private device exception'}});}
        else {f.restricted=action==='rollback';f.phase=action==='rollback'?'rolled_back':'applied';output=envelope(`network-access.${action}`,{candidate,configured_verified:true,changed:true});}
      }
      const cb=window[callbackName];if(output) cb.stdout.emit('data',output);cb.emit('exit',errno);
    },0);}};
  },{failure});
  await page.goto('/#/tools',{waitUntil:'networkidle'});
  await page.getByText('Play 商店联网修复',{exact:true}).click();
  await page.getByRole('button',{name:'检查联网限制',exact:true}).click();
}

test('confirmed Play recovery, explicit reapplication and rollback retain the shared scope',async({page})=>{
  await mount(page);
  await expect(page.getByRole('button',{name:'解除联网限制',exact:true})).toBeVisible();
  expect(await page.evaluate(()=>window.__playRecovery.writes)).toEqual([]);
  await page.getByRole('button',{name:'解除联网限制',exact:true}).click();
  const panel=page.locator('.mn-panel-warn');
  await expect(panel).toContainText('com.google.android.gms');
  await expect(panel).toContainText('com.google.android.gsf');
  expect(await page.evaluate(()=>window.__playRecovery.writes)).toEqual([]);
  await page.getByRole('button',{name:'确认执行',exact:true}).click();
  await expect(page.getByText('系统策略已回读确认。现在打开 Play 商店，测试搜索和下载。',{exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'恢复原限制',exact:true})).toBeVisible();
  expect(await page.evaluate(()=>window.__playRecovery.writes)).toEqual(['repair']);
  await page.evaluate(()=>{window.__playRecovery.restricted=true;});
  await page.getByRole('button',{name:'检查联网限制',exact:true}).click();
  await expect(page.getByRole('button',{name:'重新解除限制',exact:true})).toBeVisible();
  expect(await page.evaluate(()=>window.__playRecovery.writes)).toEqual(['repair']);
  await page.getByRole('button',{name:'重新解除限制',exact:true}).click();
  await page.getByRole('button',{name:'确认执行',exact:true}).click();
  await expect(page.getByText('系统策略已解除',{exact:true})).toBeVisible();
  await page.getByRole('button',{name:'恢复原限制',exact:true}).click();
  await page.getByRole('button',{name:'确认执行',exact:true}).click();
  await expect(page.getByText('已恢复原联网策略。',{exact:true})).toBeVisible();
  expect(await page.evaluate(()=>window.__playRecovery.writes)).toEqual(['repair','reapply','rollback']);
  const publicState=await page.evaluate(async()=>{
    const {state}=(await import('/src/composables/useMagicNet.ts')).useMagicNet();
    return JSON.stringify([state.output,state.lastCommand,state.operationCapture,localStorage,sessionStorage]);
  });
  expect(publicState).not.toContain('com.google.android');
  expect(publicState).not.toContain('a'.repeat(64));
  expect(await page.evaluate(()=>document.documentElement.scrollWidth>document.documentElement.clientWidth+1)).toBe(false);
});

test('unsupported platforms have no write button or success claim',async({page})=>{
  await mount(page,'unsupported');
  await expect(page.getByText('当前平台没有已验证的厂商策略接口，无法确认 Play 的联网限制。',{exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'解除联网限制',exact:true})).toHaveCount(0);
  expect(await page.evaluate(()=>window.__playRecovery.writes)).toEqual([]);
});

test('failed policy writes stay visible as failures without publishing device errors',async({page})=>{
  await mount(page,'write');
  await page.getByRole('button',{name:'解除联网限制',exact:true}).click();
  await page.getByRole('button',{name:'确认执行',exact:true}).click();
  await expect(page.getByRole('status').filter({hasText:'操作未确认成功，请重新检查。'})).toBeVisible();
  await expect(page.locator('body')).not.toContainText('private device exception');
  expect(await page.evaluate(()=>window.__playRecovery.restricted)).toBe(true);
});
