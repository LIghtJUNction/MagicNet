import assert from "node:assert/strict";
import { test } from "node:test";
import { nextFrame } from "./src/utils.ts";

test("frame waits finish and release callbacks even when a WebView pauses rendering", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const frames = new Map();
  let id = 0;
  globalThis.window = globalThis;
  globalThis.requestAnimationFrame = (callback) => { frames.set(++id, callback); return id; };
  globalThis.cancelAnimationFrame = (frame) => frames.delete(frame);
  t.after(() => {
    delete globalThis.requestAnimationFrame;
    delete globalThis.cancelAnimationFrame;
  });

  const visible = nextFrame();
  frames.get(id)();
  await visible;
  assert.equal(frames.size, 0);

  let resumed = false;
  const paused = nextFrame().then(() => { resumed = true; });
  t.mock.timers.tick(99);
  await Promise.resolve();
  assert.equal(resumed, false);
  t.mock.timers.tick(1);
  await paused;
  assert.equal(frames.size, 0);
});
