import assert from "node:assert/strict";
import { execFailed, normalizeExecOutcome, normalizeExecResult, unavailableExecOutcome } from "./src/utils.ts";

const emptySuccess = normalizeExecOutcome({ errno: 0, stdout: "", stderr: "" });
assert.equal(emptySuccess.ok, true);
assert.equal(emptySuccess.text, "");
assert.equal(execFailed(emptySuccess.text), false);

const humanErrorSuccess = normalizeExecOutcome({ errno: 0, stdout: "Error: diagnostic text", stderr: "" });
assert.equal(humanErrorSuccess.ok, true);
assert.equal(humanErrorSuccess.text, "Error: diagnostic text");
assert.equal(execFailed(humanErrorSuccess.text), false);

const bracketedHumanErrorSuccess = normalizeExecOutcome({ errno: 0, stdout: "[error] device emitted diagnostic text", stderr: "warning on stderr" });
assert.equal(bracketedHumanErrorSuccess.ok, true);
assert.equal(execFailed(bracketedHumanErrorSuccess.text), false, "content must not override errno=0");

const structuredFailure = normalizeExecOutcome({ errno: 7, stdout: "partial", stderr: "denied" });
assert.equal(structuredFailure.ok, false);
assert.equal(structuredFailure.errno, 7);
assert.match(structuredFailure.text, /^\[error\] errno=7/);
assert.equal(execFailed(structuredFailure.text), true);
assert.equal(normalizeExecResult({ errno: 7, stderr: "denied" }), "[error] errno=7\ndenied");

assert.equal(execFailed("[exec-timeout] operation exceeded deadline"), true);
assert.equal(execFailed("[timeout] human-facing data"), false);
assert.equal(execFailed("[error] transport rejected"), false, "untyped human output is not an exit status");
assert.equal(execFailed("Usage: cli sub update-all"), false);
assert.equal(execFailed("error: human-facing data"), false);

const unavailable = unavailableExecOutcome("magicnet sub status");
assert.equal(unavailable.ok, false);
assert.equal(unavailable.errno, -1);
assert.match(unavailable.text, /^\[error\] unavailable:/);
assert.match(unavailable.text, /command was not run/);
assert.equal(execFailed(unavailable.text), true);

console.log("command outcome tests passed");
