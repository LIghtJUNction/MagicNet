import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  DATAPLANE_IFACE,
  dataPlaneFacts,
  firstRunSteps,
  formatAboutOverview,
  successChecks,
} from "./src/components/pages/aboutOverview.ts";

const facts = dataPlaneFacts();
const steps = firstRunSteps();
const checks = successChecks();
const report = formatAboutOverview();
const aboutPage = readFileSync(new URL("./src/components/pages/AboutPage.vue", import.meta.url), "utf8");
const app = readFileSync(new URL("./src/App.vue", import.meta.url), "utf8");

assert.equal(DATAPLANE_IFACE, "magicnet0");
assert.equal(facts.length, 3);
assert.equal(steps.length, 3);
assert.equal(checks.length, 3);
assert.ok(facts.every((item) => item.code && item.title && item.detail));
assert.match(report, /dataplane=sing-box TUN/);
assert.match(report, /iface=magicnet0/);
assert.match(report, /cli health/);
assert.match(report, /cli transparent status/);
assert.doesNotMatch(report, /\bTProxy\b/);
assert.doesNotMatch(report, /\beBPF\b/);
assert.doesNotMatch(report, /ALLOW_MULTI/);
assert.doesNotMatch(report, /cli ebpf status/);
assert.doesNotMatch(report, /\bauto\b/);
assert.equal(
  successChecks().map((item) => item.command).join(" | "),
  "cli health | cli transparent status | magicnet0",
);

assert.match(aboutPage, /路径速览/);
assert.match(aboutPage, /goto-tab/);
assert.match(aboutPage, /DATAPLANE_IFACE/);
assert.doesNotMatch(aboutPage, /TProxy|eBPF|ALLOW_MULTI|cli ebpf status/);

assert.match(app, /type TabKey =[\s\S]*"about"/);
assert.match(app, /import\("@\/components\/pages\/AboutPage\.vue"\)/);
assert.match(app, /key: "about", label: "路径速览"/);
assert.match(app, /@goto-tab="setTab"/);
assert.match(app, /<KeepAlive :max="11">/);

console.log("about overview tests passed");
