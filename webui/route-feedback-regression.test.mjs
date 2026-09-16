import assert from "node:assert/strict";
import { summarizeRoutingFeedback, sanitizeRoutingFeedbackLog } from "./src/composables/issueDrafts.ts";

// Reproduce #304/#305: oldest Google connection must survive unrelated recent noise.
const many = [{metadata:{host:'play.google.com',processPath:'/system/bin/app_process64 (10093)',network:'tcp',type:'tun/tun-in'},chains:['private-provider','google-proxy'],rule:'route(google-proxy)'},
  ...Array.from({length:100},(_,i)=>({metadata:{host:`domestic${i}.example.cn`,processName:'other',network:'tcp'},chains:['direct','cn-direct'],rule:'route(cn-direct)'}))];
const focused = summarizeRoutingFeedback(JSON.stringify({connections:many}));
assert.match(focused,/route\.1 .*play\.google\.com/);
assert.match(focused,/google_related_routes=1/);
assert.match(focused,/package-unavailable app_process64/);
assert.doesNotMatch(focused,/private-provider/);
assert.match(sanitizeRoutingFeedbackLog('outbound/trojan[PrivateProviderUnusualName] failed'),/\[selected-node\]/);
assert.doesNotMatch(sanitizeRoutingFeedbackLog('outbound/trojan[PrivateProviderUnusualName] failed'),/PrivateProviderUnusualName/);
