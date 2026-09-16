import assert from 'node:assert/strict';
import test from 'node:test';
import { redactFeedbackSecrets } from './src/composables/feedbackSecrets.ts';
import { buildIssueBody, sanitizeDiagnosticText } from './src/composables/issueDrafts.ts';
const marker = 'FAKE_QUOTED_CREDENTIAL_FOR_TEST_ONLY';

test('quoted JSON keys, escaped keys, single quotes and nested values are redacted', () => {
  for (const text of [
    JSON.stringify({password:marker,secret:marker,auth_key:marker}),
    '{"pass\\u0077ord":"'+marker+'","ok":true}',
    "{'auth_key': '"+marker+"', 'ok': true}",
    JSON.stringify({secret:{items:[marker]},safe:'DNS timeout'}),
    JSON.stringify({authorization:'Bearer '+marker,refresh_token:marker}),
    '{"secret":"escaped\\\"'+marker+'","ok":true}',
    '{"secret":"'+marker,
    '{"secret":{"nested":["'+marker+'"]',
  ]) {
    const result=redactFeedbackSecrets(text);
    assert.ok(!result.includes(marker),result);
  }
});
test('bare Tailscale keys and newly covered credential assignments are filtered', () => {
  for (const text of ['tskey-auth-'+marker.replaceAll('_','-'), 'auth_key='+marker,
    'access_token='+marker, 'refresh_token='+marker, 'client_secret='+marker,
    '-----BEGIN PRIVATE KEY-----\n'+marker+'\n-----END PRIVATE KEY-----']) {
    assert.ok(!redactFeedbackSecrets(text).includes(marker));
    assert.ok(!redactFeedbackSecrets(text).includes('tskey-auth-'));
  }
});
test('routing domains, static chains and measured counters survive unchanged', () => {
  const text='{"rss_kib":102400,"ready":false,"host":"play.google.com","chain":"google-proxy -> direct"}';
  assert.equal(redactFeedbackSecrets(text),text);
  assert.deepEqual(JSON.parse(redactFeedbackSecrets('{"password":"'+marker+'","ok":true}')), {password:'[filtered]',ok:true});
});
test('canonical and complete report sanitization both remove quoted credentials', () => {
  const privateText=JSON.stringify({password:marker,auth_key:'tskey-auth-'+marker});
  assert.ok(!sanitizeDiagnosticText(privateText).includes(marker));
  const result=buildIssueBody({kind:'route-feedback',moduleProp:'version=v1.5.6',device:'test',
    support:privateText,focusedContext:privateText,
    report:{summary:privateText},operation:{phase:'error',lastCommand:'',lastOutput:'',backgroundLabel:'',backgroundArgs:'',backgroundStatus:'idle'}});
  assert.ok(!result.includes(marker));
  assert.ok(!result.includes('tskey-auth-'));
});
