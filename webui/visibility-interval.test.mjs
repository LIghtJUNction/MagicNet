import assert from "node:assert/strict";
import { test } from "node:test";
import { createVisibilityInterval } from "./src/composables/visibilityInterval.ts";

function fixture(t, hidden = false) {
  const originalWindow = globalThis.window;
  const originalDocument = globalThis.document;
  const timers = new Map();
  const listeners = new Set();
  let sequence = 0;
  let calls = 0;
  globalThis.window = {
    setInterval(callback) { timers.set(++sequence, callback); return sequence; },
    clearInterval(id) { timers.delete(id); },
  };
  globalThis.document = {
    hidden,
    addEventListener(_name, callback) { listeners.add(callback); },
    removeEventListener(_name, callback) { listeners.delete(callback); },
  };
  const poller = createVisibilityInterval(() => { calls += 1; }, 5000);
  t.after(() => {
    poller.stop();
    globalThis.window = originalWindow;
    globalThis.document = originalDocument;
  });
  return {
    poller, timers, listeners,
    calls: () => calls,
    tick() { for (const callback of [...timers.values()]) callback(); },
    hidden(value) {
      document.hidden = value;
      for (const callback of [...listeners]) callback();
    },
  };
}

test("visibility interval is idle until explicitly started", (t) => {
  const f = fixture(t);
  assert.equal(f.timers.size, 0);
  assert.equal(f.listeners.size, 0);
});

test("background WebViews do not start root polling", (t) => {
  const f = fixture(t, true);
  f.poller.start();
  assert.equal(f.timers.size, 0);
  f.tick();
  assert.equal(f.calls(), 0);
  f.hidden(false);
  f.tick();
  assert.equal(f.calls(), 1);
});

test("hide clears polling and ignores already queued callbacks", (t) => {
  const f = fixture(t);
  f.poller.start();
  const stale = [...f.timers.values()][0];
  f.hidden(true);
  assert.equal(f.timers.size, 0);
  stale();
  f.hidden(false);
  stale();
  assert.equal(f.calls(), 0);
  f.tick();
  assert.equal(f.calls(), 1);
});

test("repeated activation keeps one timer and one listener", (t) => {
  const f = fixture(t);
  for (let i = 0; i < 20; i++) f.poller.start();
  assert.equal(f.timers.size, 1);
  assert.equal(f.listeners.size, 1);
  f.tick();
  assert.equal(f.calls(), 1);
});

test("deactivation removes everything and visibility cannot restart it", (t) => {
  const f = fixture(t);
  f.poller.start();
  const stale = [...f.timers.values()][0];
  f.poller.stop();
  f.hidden(true);
  f.hidden(false);
  stale();
  assert.equal(f.timers.size, 0);
  assert.equal(f.listeners.size, 0);
  assert.equal(f.calls(), 0);
});
