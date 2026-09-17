import test from 'node:test';
import assert from 'node:assert/strict';
import { servicePresentation } from './src/lib/servicePresentation.ts';
import { startupFailure } from './src/components/pages/startupFailure.ts';
import { buildControlRuntimeInsight } from './src/components/pages/controlRuntimeInsight.ts';

const runtime = {singBoxState:'sing-box',serviceReady:true,transparentMode:'tun',transparentEffectiveMode:'tun',fswatch:'123'};
const input = {hasKsu:true,phase:'idle',queueDepth:0,runtime};

test('only explicit service readiness permits a green running indicator', () => {
  for (const connected of [true,false]) for (const singBoxState of ['sing-box','stopped','unknown']) for (const serviceReady of [true,false,null]) {
    const result = servicePresentation({singBoxState,serviceReady},connected);
    const ready = connected && singBoxState === 'sing-box' && serviceReady === true;
    assert.equal(result.tone === 'ok',ready);
    assert.equal(result.routeState === 'active',ready);
  }
  assert.equal(servicePresentation({...runtime,serviceReady:null}).label,'状态待确认');
  assert.equal(servicePresentation({...runtime,serviceReady:false}).label,'服务未就绪');
});

test('unknown/stopped/unready states cannot render a healthy control insight', () => {
  assert.equal(buildControlRuntimeInsight(input).status,'ok');
  for (const serviceReady of [false,null]) assert.equal(buildControlRuntimeInsight({...input,runtime:{...runtime,serviceReady}}).status,'warning');
  const unknown = buildControlRuntimeInsight({...input,runtime:{...runtime,singBoxState:'unknown'}});
  assert.equal(unknown.title,'无法确认核心状态');
  assert.doesNotMatch(unknown.detail,/优先启动|一键自修复/);
});

test('the supplied two-line summary is not evidence of lock timeout', () => {
  const output = '◬[warn] sing-box startup failed; see the preceding core or network error.❖\n[error] MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2 magicnet_start_kernel && magicnet_supervisors_start_detached failed with status 1';
  const result = startupFailure(output);
  assert.equal(result.title,'启动失败，原因尚未捕获');
  assert.match(result.detail,/不能据此判定为锁超时/);
  assert.equal(startupFailure('MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2'),null);
  assert.equal(startupFailure('Timed out waiting for config lock: /fixture/config.lock').title,'配置正在被其他任务占用');
});

test('known startup stages override the wrapper message without exposing raw output', () => {
  const output = '\u001b[31m[warn] Startup step failed: stage=config-check exit=1\u001b[0m\nsecret=fake-fixture\nsing-box startup failed';
  const result = buildControlRuntimeInsight({...input,phase:'error',output});
  assert.equal(result.title,'启动停在：配置校验');
  assert.doesNotMatch(JSON.stringify(result),/fake-fixture|\u001b/);
  assert.equal(startupFailure('Startup step failed: stage=__proto__ exit=1'),null);
  assert.equal(startupFailure('Startup step failed: stage=constructor exit=1'),null);
});

test('active tasks take precedence over a previous failure', () => {
  for (const overrides of [{phase:'running'},{queueDepth:1},{backgroundStatus:'timeout'}]) {
    const result = buildControlRuntimeInsight({...input,phase:'error',output:'Startup step failed: stage=dns exit=1',...overrides});
    assert.equal(result.status,'info');
  }
  // A successful new operation must not revive an earlier diagnostic.
  assert.equal(buildControlRuntimeInsight({...input,phase:'done',output:'Startup step failed: stage=dns exit=1'}).status,'ok');
});
