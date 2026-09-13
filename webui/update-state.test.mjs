import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { configureUpdateCommand, parseUpdateStatus, updateBytes } from "./src/components/pages/updateState.ts";

const fixture = () => ({ schema:1, settings:{enabled:false,interval_hours:24,wifi_only:true},current_version:"v1.4.9",pending_version:"",phase:"available",last_attempt:1,last_check:1,next_check:0,last_success:0,failures:0,transferred_bytes:100,running:false,error:"",plan:{version:"v1.5.0",core_source:"download",core_bytes:100,download_bytes:150,reuse_bytes:200,components:[{id:"bin-sing-box",sha256:"a".repeat(64),size:200,source:"installed"},{id:"webui",sha256:"b".repeat(64),size:50,source:"download"}]}});

test("component plan distinguishes reuse from download without guessing from versions", () => {
  const parsed = parseUpdateStatus(JSON.stringify(fixture()));
  assert.equal(parsed.plan.components[0].source, "installed");
  assert.equal(parsed.plan.components[1].source, "download");
  assert.equal(parsed.plan.download_bytes, 150);
});
test("missing, failed or malformed status never becomes an enabled updater", () => {
  for (const raw of ["", "[error] unsupported", "{}", "null", "[]", JSON.stringify({...fixture(),running:"false"}),JSON.stringify({...fixture(),phase:"success-maybe"})]) assert.equal(parseUpdateStatus(raw),null);
  for (const change of [{interval_hours:0},{interval_hours:169},{enabled:"false"},{wifi_only:1}]) {
    const value=fixture();Object.assign(value.settings,change);assert.equal(parseUpdateStatus(JSON.stringify(value)),null);
  }
});
test("rejects duplicate components, invalid hashes and impossible byte counts", () => {
  for (const change of [{source:"unknown"},{sha256:"unverified"},{size:-1},{size:Number.MAX_SAFE_INTEGER+1},{id:"../../bin"}]) {
    const value=fixture();Object.assign(value.plan.components[0],change);assert.equal(parseUpdateStatus(JSON.stringify(value)),null);
  }
  const value=fixture();value.plan.components.push(value.plan.components[0]);assert.equal(parseUpdateStatus(JSON.stringify(value)),null);
});
test("settings are a closed command vocabulary, never arbitrary shell input", () => {
  assert.equal(configureUpdateCommand({enabled:true,interval_hours:24,wifi_only:true}),"update configure 1 24 1");
  for (const hours of [0,169,1.5,"24;reboot",NaN,Infinity]) assert.throws(()=>configureUpdateCommand({enabled:true,interval_hours:hours,wifi_only:true}));
});
test("byte reports remain bounded and readable", () => {
  assert.equal(updateBytes(0),"0 B");assert.equal(updateBytes(1024),"1.0 KiB");assert.equal(updateBytes(1048576),"1.00 MiB");assert.equal(updateBytes(-1),"—");
});
test("page uses asynchronous jobs and local polling instead of a page-owned schedule", () => {
  const page=readFileSync(new URL("./src/components/pages/UpdatesPage.vue",import.meta.url),"utf8");
  assert.match(page,/startBackgroundCli/);assert.match(page,/onDeactivated\(stop\)/);assert.match(page,/onBeforeUnmount\(stop\)/);
  assert.match(page,/const preserveDraft = editedBeforeRead \|\| dirty.value \|\| saving.value/);
  assert.match(page,/read-back receipt/);assert.doesNotMatch(page,/\bexecSync\b|setInterval\([^]*?update apply/);
});
