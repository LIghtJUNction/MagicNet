import { expect, test } from "@playwright/test";

async function mount(page, scenario = "normal") {
  await page.addInitScript(({scenario}) => {
    localStorage.setItem("magicnet.webui.onboarding.v1", "dismissed");
    window.__updates = { saves:0, status:{schema:1,settings:{enabled:false,interval_hours:24,wifi_only:true},current_version:"v1.4.9",pending_version:scenario==="pending"?"v1.5.0":"",phase:scenario==="pending"?"pending_reboot":"available",last_attempt:1789310000,last_check:1789310000,next_check:0,last_success:0,failures:0,transferred_bytes:800,running:false,error:"",plan:{version:"v1.5.0",core_source:"download",core_bytes:100,download_bytes:150,reuse_bytes:2048,components:[{id:"bin-sing-box",sha256:"a".repeat(64),size:2048,source:"installed"},{id:"webui",sha256:"b".repeat(64),size:50,source:"download"}]}} };
    window.ksu = {spawn(command,_args,_options,name) {
      setTimeout(()=> {
        const callback=window[name];if(!callback)return;
        let output="",errno=0;
        if(command.includes("update status")) { if(scenario==="unsupported"){errno=1;output="[error] unknown command"}else output=JSON.stringify(window.__updates.status); }
        else if(command.includes("update configure")) {
          const match=command.match(/update configure ([01]) (\d+) ([01])/);
          if(match){window.__updates.saves++;window.__updates.status.settings={enabled:match[1]==="1",interval_hours:Number(match[2]),wifi_only:match[3]==="1"};}
        }
        if(output)callback.stdout.emit("data",output);callback.emit("exit",errno);
      },0);
    }};
  },{scenario});
  await page.goto("/#/updates",{waitUntil:"networkidle"});
}
test("persists automatic update controls and protects edits from status polling",async({page})=>{
  await mount(page);
  await expect(page.getByLabel("定时自动更新",{exact:true})).toBeEnabled();
  await page.getByLabel("定时自动更新",{exact:true}).check();
  await page.getByLabel("检查间隔（小时）",{exact:true}).fill("6");
  await page.waitForTimeout(3200);
  await expect(page.getByLabel("检查间隔（小时）",{exact:true})).toHaveValue("6");
  await page.getByRole("button",{name:"保存更新设置",exact:true}).click();
  await expect.poll(()=>page.evaluate(()=>window.__updates.saves)).toBe(1);
  await expect(page.getByRole("button",{name:"保存更新设置",exact:true})).toBeDisabled();
  await expect(page.getByText("复用已安装",{exact:true})).toBeVisible();
  await expect(page.getByText("需要下载",{exact:true})).toBeVisible();
  expect(await page.evaluate(()=>document.documentElement.scrollWidth>document.documentElement.clientWidth+1)).toBe(false);
});
test("pending update cannot be installed twice and never offers forced reboot",async({page})=>{
  await mount(page,"pending");
  await expect(page.getByText("重启后生效",{exact:true})).toBeVisible();
  await expect(page.getByRole("button",{name:"检查更新",exact:true})).toBeDisabled();
  await expect(page.getByRole("button",{name:"下载并安装更新",exact:true})).toHaveCount(0);
  await expect(page.getByText("已暂存 v1.5.0，不会自动重启手机。",{exact:true})).toBeVisible();
});
test("an older backend leaves update controls disabled with a real error",async({page})=>{
  await mount(page,"unsupported");
  await expect(page.getByRole("alert").filter({hasText:"无法读取更新状态"})).toBeVisible();
  await expect(page.getByLabel("定时自动更新",{exact:true})).toBeDisabled();
});
