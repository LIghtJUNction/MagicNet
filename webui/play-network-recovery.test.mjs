import assert from 'node:assert/strict';
import test from 'node:test';
import { availableRecoveryActions, checkedPolicy, parsePlayPolicies, recoveryCommand } from './src/components/pages/playNetworkRecovery.ts';

const candidate = 'a'.repeat(64);
const entry = { candidate, provider:'oplus', packages:['com.google.android.gms','com.google.android.gsf'], configured:'reject_all', manual_repair_supported:true };
const encode = (data, command = 'network-access.inspect') => JSON.stringify({schema:1, ok:true, command, data});
const inspection = (entries = [entry], records = []) => encode({package_inventory:'observed', providers:[{provider:'oplus',status:'observed'}], entries, recovery:{status:'observed',records}});

test('Play repair dynamically retains the complete shared identity and excludes unrelated apps', () => {
  const parsed = parsePlayPolicies(inspection([entry, {...entry, candidate:'b'.repeat(64), packages:['app.unrelated']}, {...entry,candidate:'c'.repeat(64),packages:[]} ]));
  assert.equal(parsed.rows.length,1);
  assert.deepEqual(parsed.rows[0].packages, entry.packages);
  assert.deepEqual(availableRecoveryActions(parsed.rows[0]),['repair']);
  assert.equal(parsed.observed,true);
});
test('cleared policy remains discoverable via its original journal for rollback', () => {
  const parsed = parsePlayPolicies(inspection([], [{...entry,recorded_phase:'applied'}]));
  assert.equal(parsed.rows[0].candidate,candidate);
  assert.deepEqual(availableRecoveryActions(parsed.rows[0]),[]);
  parsed.rows[0].observed = checkedPolicy(encode({candidate,observed_policy:'recovered_policy'},'network-access.check'),candidate);
  assert.deepEqual(availableRecoveryActions(parsed.rows[0]),['rollback']);
  assert.equal(checkedPolicy(encode({candidate:'b'.repeat(64),observed_policy:'recovered_policy'},'network-access.check'),candidate),'unknown');
});
test('restriction reapplication requires a separate explicit action; uncertain writes allow only rollback', () => {
  const [row] = parsePlayPolicies(inspection([entry],[{...entry,recorded_phase:'applied'}])).rows;
  assert.deepEqual(availableRecoveryActions({...row,observed:'original_policy'}),['reapply','rollback']);
  for(const phase of ['prepared','rollback_prepared']) assert.deepEqual(availableRecoveryActions({...row,phase,observed:'original_policy'}),['rollback']);
  assert.deepEqual(availableRecoveryActions({...row,observed:'policy_conflict'}),[]);
  assert.deepEqual(availableRecoveryActions({...row,observed:'unknown'}),[]);
});
test('malformed identities and failed recovery scans never become a usable repair plan', () => {
  for(const bad of [{...entry,candidate:';id'}, {...entry,packages:['com.google.android.gsf','com.google.android.gms']}, {...entry,provider:'unknown'}]) assert.equal(parsePlayPolicies(inspection([bad])),null);
  assert.equal(parsePlayPolicies(encode({entries:[],providers:[],recovery:{status:'unknown'}})),null);
  assert.equal(parsePlayPolicies(encode({},'service.status')),null);
});
test('machine writes carry explicit confirmation and candidate tokens cannot inject shell commands', () => {
  assert.equal(recoveryCommand('repair',candidate),`--json network-access repair ${candidate} --confirm`);
  assert.equal(recoveryCommand('reapply',candidate),`--json network-access reapply ${candidate} --confirm`);
  assert.equal(recoveryCommand('rollback',candidate),`--json network-access rollback ${candidate} --confirm`);
  assert.equal(recoveryCommand('check',candidate),`--json network-access check ${candidate}`);
  assert.throws(()=>recoveryCommand('repair',';id'));
  assert.throws(()=>recoveryCommand('allow',candidate));
});
