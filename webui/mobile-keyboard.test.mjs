import assert from "node:assert/strict";
import test from "node:test";
import { isMobileKeyboardOpen } from "./src/composables/useMobileKeyboard.ts";

test("a keyboard-sized occlusion hides navigation only while editing", () => {
  assert.equal(isMobileKeyboardOpen(844, 430, true), true);
  assert.equal(isMobileKeyboardOpen(844, 430, false), false);
  assert.equal(isMobileKeyboardOpen(844, 844, true), false);
  assert.equal(isMobileKeyboardOpen(844, 844, false), false);
});

test("toolbars, pinch zoom and a taller viewport are not keyboards", () => {
  assert.equal(isMobileKeyboardOpen(844, 760, true), false);
  assert.equal(isMobileKeyboardOpen(844, 724, true), false);
  assert.equal(isMobileKeyboardOpen(844, 430, true, 2), false);
  assert.equal(isMobileKeyboardOpen(430, 844, true), false);
});
