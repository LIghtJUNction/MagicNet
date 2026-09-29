import assert from 'node:assert/strict';
import test from 'node:test';
import { parseTailscaleControl, transitionConfirmed } from './src/components/pages/tailscaleControl.ts';
const idle = { enabled:false, resumable:false, logout_pending:false, local_identity:false, revision:'a'.repeat(64), core:'stopped' };
const envelope = data => JSON.stringify({schema:1,ok:true,command:'tailscale.status',data});
test('requires the versioned status contract and keeps unknown identity unknown',()=>{
  assert.deepEqual(parseTailscaleControl(envelope(idle)), idle);
  assert.equal(parseTailscaleControl(envelope({...idle,local_identity:null})).local_identity,null);
  for(const data of [{...idle,enabled:'false'},{...idle,revision:'private command'},{...idle,core:'maybe'},{...idle,local_identity:undefined}]) {
    assert.throws(()=>parseTailscaleControl(envelope(data)));
  }
  for(const value of ['{}','null',JSON.stringify({schema:1,ok:false,data:idle}),JSON.stringify({schema:2,ok:true,command:'tailscale.status',data:idle})]) {
    assert.throws(()=>parseTailscaleControl(value));
  }
  assert.deepEqual(parseTailscaleControl(envelope({...idle,auth_key:'not-for-display'})),idle);
});
test('pause is not logout, and partial or unknown cleanup is never called logged out',()=>{
  const paused={...idle,resumable:true,local_identity:true};
  assert.equal(transitionConfirmed('disable',paused),true);
  assert.equal(transitionConfirmed('logout',paused),false);
  for(const state of [{...idle,local_identity:null},{...idle,logout_pending:true},{...idle,enabled:true}]) {
    assert.equal(transitionConfirmed('logout',state),false);
  }
  assert.equal(transitionConfirmed('logout',idle),true);
  assert.equal(transitionConfirmed('enable',{...idle,enabled:true}),true);
  assert.equal(transitionConfirmed('enable',{...idle,enabled:true,logout_pending:true}),false);
});
