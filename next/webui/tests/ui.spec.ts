import { test, expect, type Page } from '@playwright/test';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
let root: string;
const binary = resolve('../target/debug/magicnet-cli');
async function cli(args: string[], body = ''): Promise<{errno:number;stdout:string;stderr:string}> {
  return await new Promise((resolve,reject)=>{
    const child=spawn(binary,['--root',root,...args],{stdio:[body ? 'pipe' : 'ignore','pipe','pipe'],timeout:5000});
    let stdout='',stderr=''; child.stdout.on('data',v=>stdout+=v); child.stderr.on('data',v=>stderr+=v);
    child.on('error',reject);
    child.stdin?.on('error',(error:NodeJS.ErrnoException)=>{if(error.code!=='EPIPE') reject(error);});
    child.on('close',code=>resolve({errno:code??1,stdout,stderr})); child.stdin?.end(body);
  });
}
// The production bundle is rendered offline. A test-only KernelSU adapter
// transports the real SDK's stdin payload into the compiled host CLI. This
// does not claim browser CSP, Android WebView, routing or kernel acceptance.
async function boot(page: Page, native=true) {
  if (native) {
    await page.exposeFunction('hostCli',(payload:string)=>cli(['--request-base64-stdin'],payload));
  }
  let html=await readFile('dist/index.html','utf8');
  html=html.replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/g,'').replace(/<script[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link[^>]*>/g,'');
  await page.setContent(html);
  if(native) await page.evaluate(()=>{
    (window as unknown as {__commands: string[]}).__commands=[];
    window.ksu={exec:(command,options,callback)=>{
      (window as unknown as {__commands:string[]}).__commands.push(String(command));
      const payload=JSON.parse(String(options)).env.MAGICNET_REQUEST_B64;
      (window as unknown as {hostCli:(payload:string)=>Promise<{errno:number;stdout:string;stderr:string}>}).hostCli(payload).then(r=>{
        (window as unknown as Record<string,(...args:unknown[])=>void>)[String(callback)](r.errno,r.stdout,r.stderr);
      });
    }};
  });
  for(const name of await readdir('dist/assets')) {
    if(name.endsWith('.css')) await page.addStyleTag({path:`dist/assets/${name}`});
    if(name.endsWith('.js')) await page.addScriptTag({path:`dist/assets/${name}`,type:'module'});
  }
}
test.beforeEach(async()=>{root=await mkdtemp(join(tmpdir(),'magicnet-webui-')); const result=await cli(['--initialize-candidate']); expect(result.errno).toBe(0);});
test.afterEach(async()=>{await rm(root,{recursive:true,force:true});});
for(const width of [320,375,768,1440]) {
  test(`${width}px: every page fits without hiding overflow`,async({page},info)=>{
    await page.setViewportSize({width,height:940}); await boot(page);
    await expect(page.getByRole('heading',{name:'已停止',exact:true})).toBeVisible();
    for(const title of ['概览','订阅','网络','维护']) {
      await page.getByRole('navigation').getByRole('button',{name:title,exact:true}).click();
      await expect(page.getByRole('heading',{name:title,exact:true})).toBeVisible();
      expect(await page.evaluate(()=>document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true);
      await page.screenshot({path:info.outputPath(`${width}-${title}.png`),fullPage:true});
    }
  });
}
test('a normal browser has no fake live status or write fallback',async({page})=>{
  await boot(page,false); await expect(page.getByText('当前仅展示界面结构。没有伪造节点、登录结果或联网状态。')).toBeVisible();
  await expect(page.getByRole('button',{name:'停止服务',exact:true})).toBeDisabled();
  await expect(page.getByRole('heading',{name:'状态待确认'})).toBeVisible();
});
test('link replacement reaches the actual CLI, and deleting all links persists',async({page})=>{
  await boot(page); await page.getByRole('navigation').getByRole('button',{name:'订阅',exact:true}).click();
  const urls=page.getByLabel('每行一个 HTTP / HTTPS 链接'); await expect(urls).toBeEnabled();
  await urls.fill('https://example.test/a\nhttp://192.0.2.1:8080/b');
  await page.getByRole('button',{name:'保存链接列表'}).click(); await expect(page.getByText('2 个来源')).toBeVisible();
  await expect(urls).toBeEnabled(); await urls.fill(''); await page.getByRole('button',{name:'保存链接列表'}).click(); await expect(page.getByText('0 个来源')).toBeVisible();
  expect(JSON.parse((await cli(['settings','--json'])).stdout).data.sources).toEqual([]); await expect(urls).toHaveValue('');
});
test('Unicode import is stored, user shell syntax never enters the command',async({page})=>{
  await boot(page); await page.getByRole('navigation').getByRole('button',{name:'订阅',exact:true}).click();
  const input=page.getByLabel('订阅内容'); await expect(input).toBeEnabled();
  await input.fill(JSON.stringify({proxies:[{type:'trojan',name:'日本😀',server:'example.test',port:443,password:'$(touch /tmp/no); "\\'}]}));
  await page.getByRole('button',{name:'校验并保存本地节点'}).click(); await expect(page.getByRole('status').filter({hasText:'已保存'})).toBeVisible();
  expect(await page.evaluate(()=> (window as unknown as {__commands:string[]}).__commands.every(c=> !c.includes('touch') && !c.includes('日本') && c.includes('MAGICNET_REQUEST_B64')))).toBe(true);
});
test('failed refresh preserves saved links and reports a real dependency failure',async({page})=>{
  await boot(page); await page.getByRole('navigation').getByRole('button',{name:'订阅',exact:true}).click();
  const urls=page.getByLabel('每行一个 HTTP / HTTPS 链接'); await expect(urls).toBeEnabled(); await urls.fill('https://example.test/a');
  await page.getByRole('button',{name:'保存链接列表'}).click(); await expect(page.getByText('1 个来源')).toBeVisible();
  await page.getByRole('button',{name:'更新订阅'}).click(); await expect(page.getByRole('alert')).toContainText('缺少所需工具'); await expect(urls).toHaveValue('https://example.test/a');
});
test('malformed configuration remains in the editor and never becomes success',async({page})=>{
  await boot(page); await page.getByRole('navigation').getByRole('button',{name:'网络',exact:true}).click();
  await page.getByRole('button',{name:'查看原生配置'}).click(); const input=page.getByLabel('原生 sing-box 模板'); await expect(input).toBeEnabled(); await input.fill('{broken');
  await page.getByRole('button',{name:'保存网络配置'}).click(); await expect(page.getByRole('alert')).toContainText('不是有效的 JSON'); await expect(input).toHaveValue('{broken');
});
test('unsaved edits survive navigation and keyboard cancellation of reload',async({page})=>{
  await boot(page); await page.getByRole('navigation').getByRole('button',{name:'订阅',exact:true}).click();
  const urls=page.getByLabel('每行一个 HTTP / HTTPS 链接'); await expect(urls).toBeEnabled(); await urls.fill('https://draft.test/a');
  await page.getByRole('navigation').getByRole('button',{name:'网络',exact:true}).click(); await page.getByRole('button',{name:'重新读取'}).click();
  await expect(page.getByRole('dialog')).toBeVisible(); await page.keyboard.press('Escape'); await expect(page.getByRole('dialog')).toBeHidden();
  await page.getByRole('navigation').getByRole('button',{name:'订阅',exact:true}).click(); await expect(urls).toHaveValue('https://draft.test/a');
});
test('stop is available with a draft and does not silently overwrite it',async({page})=>{
  await boot(page); await page.getByRole('navigation').getByRole('button',{name:'订阅',exact:true}).click();
  const urls=page.getByLabel('每行一个 HTTP / HTTPS 链接'); await expect(urls).toBeEnabled(); await urls.fill('https://draft.test/a');
  await page.getByRole('navigation').getByRole('button',{name:'概览',exact:true}).click(); await page.getByRole('button',{name:'停止服务',exact:true}).click();
  await expect(page.getByRole('status').filter({hasText:'操作已返回'})).toBeVisible(); await page.getByRole('navigation').getByRole('button',{name:'订阅',exact:true}).click(); await expect(urls).toHaveValue('https://draft.test/a');
});
