import assert from "node:assert/strict";
import test from "node:test";
import { setLocale, t } from "./src/i18n/index.ts";
import { buildProxySelectionPlan, formatProxySelectionPlanReport } from "./src/components/pages/proxySelectionPlan.ts";

const locales = ["zh-CN", "en", "ru"];
const group = {
  name: "private-group-name",
  type: "Selector",
  now: "private-current-node",
  proxies: ["private-current-node", "private-target-node"],
};

for (const [expectedClass, delayMillis] of [
  ["untested", undefined],
  ["unknown", null],
  ["fast", 120],
  ["normal", 250],
  ["slow", 251],
]) {
  test(`historical proxy plans preserve ${expectedClass} and privacy across language changes`, () => {
    try {
      const delays = delayMillis === undefined ? [] : [{
        node: "private-target-node",
        summary: "private-raw-delay-message",
        delayMillis,
        quality: delayMillis === null ? "failed" : expectedClass,
      }];
      for (const sourceLocale of locales) {
        setLocale(sourceLocale);
        const plan = buildProxySelectionPlan(group, "private-target-node", delays);
        assert.equal(plan.targetDelayClass, expectedClass);
        for (const exportLocale of locales) {
          setLocale(exportLocale);
          const report = formatProxySelectionPlanReport(plan);
          const targetLine = report.split("\n").find((line) => line.startsWith(`${t("目标延迟")}=`));
          assert.ok(targetLine?.startsWith(`${t("目标延迟")}=${expectedClass} (`));
          assert.doesNotMatch(report, /private-/);
        }
      }
    } finally {
      setLocale("zh-CN");
    }
  });
}
