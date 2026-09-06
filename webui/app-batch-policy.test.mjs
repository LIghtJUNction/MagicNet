import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";

const page = readFileSync(
  new URL("./src/components/pages/AppsPage.vue", import.meta.url),
  "utf8",
);

assert.match(page, /type="checkbox"[\s\S]*togglePackageSelection/);
assert.match(page, /function selectVisiblePackages/);
assert.match(page, /function requestBatchAdd/);
assert.match(page, /app add-many \$\{target\} \$\{quoted\}/);
assert.match(page, /pendingAppAction\.value = \{[\s\S]*批量归类/);
assert.doesNotMatch(
  page.match(
    /async function applyBatchAdd[\s\S]*?\n}\n\nfunction requestBatchAdd/,
  )?.[0] ?? "",
  /\bfor\s*\([^)]*\)[\s\S]*await runCli/,
  "batch classification must use one CLI transaction instead of restarting once per app",
);

// Execute the shipped handler, not a reimplementation of its async ownership.
const script = page.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)?.[1];
assert.ok(script);
const ast = ts.createSourceFile(
  "AppsPage.ts",
  script,
  ts.ScriptTarget.Latest,
  true,
);
const handler = ast.statements.find(
  (node) =>
    ts.isFunctionDeclaration(node) && node.name?.text === "confirmAppAction",
);
assert.ok(handler);
const handlerJs = ts.transpileModule(handler.getText(ast), {
  compilerOptions: { target: ts.ScriptTarget.ES2022 },
}).outputText;

for (const fails of [false, true]) {
  test(`an ${fails ? "unsuccessful" : "successful"} app action preserves a newer confirmation`, async () => {
    const task = Promise.withResolvers();
    const pendingAppAction = {
      value: { key: "apply-batch", run: () => task.promise },
    };
    const confirm = runInNewContext(`${handlerJs}\nconfirmAppAction`, {
      pendingAppAction,
    });
    const completion = confirm();
    assert.equal(pendingAppAction.value, null);
    await confirm(); // A second confirmation cannot submit the consumed action.
    const next = { key: "apply-batch", run: async () => {} };
    pendingAppAction.value = next;
    if (fails) {
      const error = new Error("apply failed");
      task.reject(error);
      await assert.rejects(completion, (actual) => actual === error);
    } else {
      task.resolve();
      await completion;
    }
    assert.equal(pendingAppAction.value, next);
  });
}

console.log("app batch policy tests passed");
