import assert from "node:assert/strict";
import test from "node:test";
import {parseOverlay,parseTargets,validRoutingValue} from "./src/components/pages/routingEditor.ts";
import {parsePackageCatalog} from "./src/composables/parsers.ts";

test("structured policy retains raw names and rejects malformed boundary data",()=> {
  for(const tag of ["constructor","__proto__","toString","hasOwnProperty"]) {
    const parsed=parseOverlay({schema:1,rules:[{kind:"domain",value:"example.com",outbound:tag}],outbounds:[{type:"selector",tag,outbounds:["direct"]}]});
    assert.equal(parsed.rules[0].outbound,tag);assert.equal(parsed.outbounds[0].tag,tag);
  }
  assert.equal(parseOverlay({schema:1,rules:[{}],outbounds:[]}),null);
  assert.equal(parseTargets([{tag:"direct"}]),null);
  assert.equal(validRoutingValue("domain","bad.test; id"),false);
  assert.equal(validRoutingValue("app","com.example.reader"),true);
});
test("application catalog preserves labels without treating unknown schema as an empty list",()=> {
  assert.equal(parsePackageCatalog({packages:[{packageName:"com.example.reader",appLabel:"阅读器"}]})[0].appLabel,"阅读器");
  assert.equal(parsePackageCatalog({packages:[{packageName:"com.example.reader"}]}),null);
});
