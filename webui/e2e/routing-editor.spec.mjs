import { expect, test } from "@playwright/test";

async function mount(page, conflict = false) {
  await page.route("**/e2e/routing-fixture.html", route => route.fulfill({contentType:"text/html",body:'<!doctype html><html lang="zh-CN"><meta name="viewport" content="width=device-width, initial-scale=1"><body><main id="fixture" style="padding:16px"></main></body></html>'}));
  await page.goto("/e2e/routing-fixture.html");
  await page.evaluate(async conflict => {
    window.__routing={payload:"",patch:{log:{level:"warn"}},revision:0,saves:0,applies:0,removals:0,conflict};
    window.ksu={spawn(command,_args,_options,callbackName) {
      setTimeout(()=> {
        const f=window.__routing, cb=window[callbackName];let output="",errno=0;
        const envelope=(name,data)=>JSON.stringify({schema:1,ok:true,command:name,data});
        if(command.includes("--json capabilities")) output=envelope("machine.capabilities",{features:["additive_routing_overlay"]});
        else if(command.includes("--json override inspect")) output=envelope("override.inspect",{patch:f.patch,configured_revision:f.revision,pending:false,routing_targets:[{tag:"proxy",type:"selector"},{tag:"direct",type:"direct"},{tag:"block",type:"block"}]});
        else if(command.includes("webui payload create tmp")) {f.payload="";output=`/data/adb/modules/MagicNet/.tmp/webui-payload/${command.match(/routing-[0-9]+-[a-z0-9]+\.json/)[0]}`;}
        else if(command.includes("webui payload append tmp")) {const chunks=command.match(/[a-zA-Z0-9+/]{16,}={0,2}/g);f.payload+=new TextDecoder().decode(Uint8Array.from(atob(chunks.at(-1)), c=>c.charCodeAt(0)));}
        else if(command.includes("webui payload remove tmp")) f.removals++;
        else if(command.includes("--json override preview-file")) output=envelope("override.preview",{valid:true,configured_revision:f.revision,changed_section_count:2});
        else if(command.includes("--json override set-file")) {
          if(f.conflict) {errno=1;output=JSON.stringify({schema:1,ok:false,command:"machine.error",error:{code:"override.conflict",message:"conflict"}});}
          else {f.patch=JSON.parse(f.payload).patch;f.saves++;f.revision++;output=envelope("override.set",{configured_revision:f.revision,pending:true});}
        } else if(command.includes("--json override apply-file")) {f.applies++;output=envelope("override.apply",{configured_revision:f.revision,pending:false,service_running:false});}
        else if(command.includes("--json app inspect")) output=envelope("app.inspect",{schema:1,packages:[{packageName:"com.example.reader",appLabel:"阅读器"}]});
        else {errno=1;output=JSON.stringify({schema:1,ok:false,command:"machine.error",error:{code:"machine.unsupported_command",message:"fixture"}});}
        cb.stdout.emit("data",output);cb.emit("exit",errno);
      },0);
    }};
    const {createApp}=await import("/e2e/vue-fixture.mjs");await import("/src/styles.css");
    const {setLocale}=await import("/src/i18n/index.ts");setLocale("zh-CN");
    const {state}=(await import("/src/composables/useMagicNet.ts")).useMagicNet();state.hasKsu=true;
    const {default:Component}=await import("/src/components/pages/RoutingEditor.vue");createApp(Component).mount("#fixture");
  },conflict);
  await expect(page.getByLabel("匹配类型",{exact:true})).toBeEnabled();
}

test("builds a custom group and domain/app policy, previews, applies and offers undo",async ({page})=> {
  const errors=[];page.on("pageerror",e=>errors.push(e.message));await mount(page);
  await page.getByText("自定义策略组与出口",{exact:false}).click();
  await page.getByLabel("名称",{exact:true}).fill("我的出口");
  await page.getByRole("button",{name:"加入或更新出口",exact:true}).click();
  await page.getByLabel("域名",{exact:true}).fill("example.com");
  await page.getByLabel("目标出口",{exact:true}).selectOption("我的出口");
  await page.getByRole("button",{name:"加入草稿",exact:true}).click();
  await page.getByRole("button",{name:"读取已安装应用",exact:true}).click();
  await expect(page.locator("#routing-packages option")).toHaveAttribute("label","阅读器");
  await page.getByLabel("匹配类型",{exact:true}).selectOption("app");
  await page.getByLabel("应用包名",{exact:true}).fill("com.example.reader");
  await page.getByRole("button",{name:"加入草稿",exact:true}).click();
  expect(await page.evaluate(()=>window.__routing.saves)).toBe(0);
  await page.getByRole("button",{name:"预览变更",exact:true}).click();
  await expect(page.getByText("分流预览通过。确认列表后保存并应用。",{exact:true})).toBeVisible();
  await page.getByRole("button",{name:"保存并应用",exact:true}).click();
  await expect(page.getByText("覆写已生成，服务保持停止状态。",{exact:true})).toBeVisible();
  const result=await page.evaluate(()=>window.__routing);
  expect(result.saves).toBe(1);expect(result.applies).toBe(1);expect(result.patch.log).toEqual({level:"warn"});
  expect(result.patch.$magicnet_routing.rules).toHaveLength(2);
  expect(result.patch.$magicnet_routing.outbounds[0].tag).toBe("我的出口");
  await page.getByRole("button",{name:"撤销上次应用",exact:true}).click();
  await expect(page.locator(".routing-rules li")).toHaveCount(0);
  await expect(page.getByRole("button",{name:"保存并应用",exact:true})).toBeDisabled();
  expect(await page.evaluate(()=>document.documentElement.scrollWidth>document.documentElement.clientWidth+1)).toBe(false);
  expect(errors).toEqual([]);
  await page.screenshot({path:test.info().outputPath("routing.png"),fullPage:true});
});

test("stale save preserves the draft and never activates it",async({page})=> {
  await mount(page,true);await page.getByLabel("域名",{exact:true}).fill("example.com");
  await page.getByRole("button",{name:"加入草稿",exact:true}).click();
  await page.getByRole("button",{name:"预览变更",exact:true}).click();
  await page.getByRole("button",{name:"保存并应用",exact:true}).click();
  await expect(page.getByRole("alert")).toContainText("配置已被其他操作修改");
  await expect(page.locator(".routing-rules li")).toHaveCount(1);
  expect(await page.evaluate(()=>window.__routing.applies)).toBe(0);
});


test("edits a credential-bearing outbound without exposing it in shared output",async({page})=> {
  await mount(page);await page.getByText("自定义策略组与出口",{exact:false}).click();
  await page.getByLabel("出口类型",{exact:true}).selectOption("http");
  await page.getByLabel("名称",{exact:true}).fill("private-outbound");
  await page.getByLabel("服务器",{exact:true}).fill("proxy.example.invalid");
  await page.getByLabel("端口",{exact:true}).fill("443");
  await page.getByLabel("用户名",{exact:true}).fill("sample-user");
  const secret="routing-fixture-secret";
  await expect(page.getByLabel("密码",{exact:true})).toHaveAttribute("type","password");
  await page.getByLabel("密码",{exact:true}).fill(secret);
  await page.getByRole("button",{name:"加入或更新出口",exact:true}).click();
  await page.getByRole("button",{name:"修改出口",exact:true}).click();
  await expect(page.getByLabel("名称",{exact:true})).toHaveValue("private-outbound");
  await expect(page.getByLabel("密码",{exact:true})).toHaveValue(secret);
  await page.getByLabel("端口",{exact:true}).fill("8443");
  await page.getByRole("button",{name:"加入或更新出口",exact:true}).click();
  await page.getByLabel("域名",{exact:true}).fill("example.com");
  await page.getByLabel("目标出口",{exact:true}).selectOption("private-outbound");
  await page.getByRole("button",{name:"加入草稿",exact:true}).click();
  await page.getByRole("button",{name:"预览变更",exact:true}).click();
  await page.getByRole("button",{name:"保存并应用",exact:true}).click();
  await expect(page.getByText("覆写已生成，服务保持停止状态。",{exact:true})).toBeVisible();
  const privateValue=await page.evaluate(()=>window.__routing.patch.$magicnet_routing.outbounds[0]);
  expect(privateValue.server_port).toBe(8443);expect(privateValue.password).toBe(secret);
  const shared=await page.evaluate(async()=>{const {state}=(await import("/src/composables/useMagicNet.ts")).useMagicNet();return JSON.stringify({output:state.output,lastCommand:state.lastCommand,capture:state.operationCapture});});
  expect(shared).not.toContain(secret);expect(await page.locator("body").innerText()).not.toContain(secret);
});
