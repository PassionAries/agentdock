import assert from 'node:assert/strict';
import test from 'node:test';

import { browserProcessIsOwned, createCDPResponseMonitor, textStateInDocument } from './browser-runner.js';

test('attached CDP 会话不拥有外部浏览器进程', () => {
  assert.equal(browserProcessIsOwned({ backend: 'cdp', browser_ownership: 'attached' }), false);
  assert.equal(browserProcessIsOwned({ backend: 'cdp', browser_ownership: 'owned' }), true);
  assert.equal(browserProcessIsOwned({ backend: 'cdp', visible_process: { pid: 123 } }), true);
});

test('精确文本按元素匹配，而不是比较整个页面正文', () => {
  const saveButton = element('保存');
  const document = { body: { querySelectorAll: () => [element('标题 保存'), saveButton] } };
  globalThis.window = { getComputedStyle: () => ({ visibility: 'visible', display: 'block' }) };

  assert.deepEqual(textStateInDocument.call(document, '保存', true), { found: true, visible: true });
});

test('文本状态区分存在与可见', () => {
  const hiddenText = element('稍后显示', { width: 0, height: 0 });
  const document = { body: { querySelectorAll: () => [hiddenText] } };
  globalThis.window = { getComputedStyle: () => ({ visibility: 'visible', display: 'block' }) };

  assert.deepEqual(textStateInDocument.call(document, '稍后显示', true), { found: true, visible: false });
});

test('CDP 导航等待目标生命周期事件', async () => {
  const previousWebSocket = globalThis.WebSocket;
  globalThis.WebSocket = FakeWebSocket;
  try {
    const monitor = await createCDPResponseMonitor({ webSocketDebuggerUrl: 'ws://browser/page' });
    let navigationFinished = false;
    const navigation = monitor.waitForNavigation({ action: 'goto', wait_until: 'load', timeout_ms: 1000 }, async () => {});

    setTimeout(() => FakeWebSocket.instance.emit({ method: 'Page.loadEventFired', params: {} }), 0);
    await navigation;
    navigationFinished = true;

    assert.equal(navigationFinished, true);
    monitor.close();
  } finally {
    globalThis.WebSocket = previousWebSocket;
  }
});

function element(text, rect = { width: 100, height: 20 }) {
  return {
    innerText: text,
    textContent: text,
    getBoundingClientRect: () => rect
  };
}

class FakeWebSocket {
  static instance;

  constructor() {
    FakeWebSocket.instance = this;
    queueMicrotask(() => this.onopen?.());
  }

  send(rawMessage) {
    const message = JSON.parse(rawMessage);
    queueMicrotask(() => this.emit({ id: message.id, result: {} }));
  }

  emit(message) {
    this.onmessage?.({ data: JSON.stringify(message) });
  }

  close() {}
}
