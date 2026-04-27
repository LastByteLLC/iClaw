#!/usr/bin/env node
// Unit tests for Extension JS modules (extractor, protocol, compat)
// Run: node Tests/ExtensionTests/test_extractor.js

const assert = require('assert');
const fs = require('fs');
const path = require('path');

// ── Test helpers ──

let passed = 0;
let failed = 0;

function test(name, fn) {
    try {
        fn();
        passed++;
        console.log(`  ✓ ${name}`);
    } catch (e) {
        failed++;
        console.error(`  ✗ ${name}`);
        console.error(`    ${e.message}`);
    }
}

// ── Load protocol.js ──

console.log('\n── protocol.js ──');

// Minimal browser API shim
globalThis.browser = { runtime: { sendNativeMessage: () => {} } };
globalThis.chrome = globalThis.browser;

const protocolSrc = fs.readFileSync(
    path.join(__dirname, '../../Extension/shared/protocol.js'), 'utf8'
);
eval(protocolSrc);

test('ICLAW_NATIVE_HOST is defined', () => {
    assert.strictEqual(globalThis.iClawProtocol.ICLAW_NATIVE_HOST, 'com.geticlaw.nativehost');
});

test('rpcRequest creates valid JSON-RPC', () => {
    const req = globalThis.iClawProtocol.rpcRequest('page.getContent', { tabId: 1 });
    assert.strictEqual(req.jsonrpc, '2.0');
    assert.strictEqual(req.method, 'page.getContent');
    assert.deepStrictEqual(req.params, { tabId: 1 });
    assert.ok(req.id, 'Should have an id');
});

test('rpcRequest generates unique IDs', () => {
    const a = globalThis.iClawProtocol.rpcRequest('test');
    const b = globalThis.iClawProtocol.rpcRequest('test');
    assert.notStrictEqual(a.id, b.id);
});

test('rpcSuccess wraps result', () => {
    const resp = globalThis.iClawProtocol.rpcSuccess('req-1', { text: 'hello' });
    assert.strictEqual(resp.jsonrpc, '2.0');
    assert.strictEqual(resp.id, 'req-1');
    assert.deepStrictEqual(resp.result, { text: 'hello' });
});

test('rpcError wraps error', () => {
    const resp = globalThis.iClawProtocol.rpcError('req-2', -32600, 'Bad request');
    assert.strictEqual(resp.jsonrpc, '2.0');
    assert.strictEqual(resp.id, 'req-2');
    assert.strictEqual(resp.error.code, -32600);
    assert.strictEqual(resp.error.message, 'Bad request');
});

test('ErrorCodes constants exist', () => {
    const codes = globalThis.iClawProtocol.ErrorCodes;
    assert.strictEqual(codes.PARSE_ERROR, -32700);
    assert.strictEqual(codes.INVALID_REQUEST, -32600);
    assert.strictEqual(codes.METHOD_NOT_FOUND, -32601);
    assert.strictEqual(codes.TAB_NOT_FOUND, -32001);
    assert.strictEqual(codes.TIMEOUT, -32004);
});

test('Methods constants exist', () => {
    const m = globalThis.iClawProtocol.Methods;
    assert.strictEqual(m.PAGE_GET_CONTENT, 'page.getContent');
    assert.strictEqual(m.TABS_LIST, 'tabs.list');
    assert.strictEqual(m.HANDSHAKE, 'handshake');
    assert.strictEqual(m.DOM_QUERY_SELECTOR, 'dom.querySelector');
});

// ── Load compat.js ──

console.log('\n── compat.js ──');

const compatSrc = fs.readFileSync(
    path.join(__dirname, '../../Extension/shared/compat.js'), 'utf8'
);

test('compat.js sets globalThis.browser from chrome', () => {
    delete globalThis.browser;
    globalThis.chrome = { runtime: { id: 'test' } };
    eval(compatSrc);
    assert.strictEqual(globalThis.browser, globalThis.chrome);
});

test('compat.js preserves existing browser global', () => {
    const existing = { runtime: { id: 'firefox' } };
    globalThis.browser = existing;
    eval(compatSrc);
    assert.strictEqual(globalThis.browser, existing);
});

// ── Load extractor.js with DOM shims ──

console.log('\n── extractor.js (via message handler) ──');

// Set up minimal DOM environment for the IIFE
let registeredHandler = null;
globalThis.window = { __iclawExtractorLoaded: false };
globalThis.location = { href: 'https://example.com/test' };
globalThis.browser = {
    runtime: {
        onMessage: {
            addListener: (handler) => { registeredHandler = handler; }
        }
    }
};

// Mock document
function makeDoc(bodyText, title, articleText) {
    return {
        title: title || 'Test Page',
        readyState: 'complete',
        body: {
            cloneNode: () => ({
                querySelectorAll: () => [],
                innerText: bodyText,
                textContent: bodyText,
            }),
            innerText: bodyText,
            textContent: bodyText,
        },
        querySelector: (sel) => {
            if (sel === 'article' && articleText !== undefined) {
                return {
                    cloneNode: () => ({
                        querySelectorAll: () => [],
                        innerText: articleText,
                        textContent: articleText,
                    }),
                };
            }
            if (sel === 'link[rel*="icon"]') return { href: 'https://example.com/favicon.ico' };
            return null;
        },
        querySelectorAll: () => [],
        evaluate: () => ({
            snapshotLength: 0,
            snapshotItem: () => null,
        }),
    };
}

globalThis.document = makeDoc('Body text here', 'Test Page');

// Reset the load guard and evaluate
globalThis.window.__iclawExtractorLoaded = false;
const extractorSrc = fs.readFileSync(
    path.join(__dirname, '../../Extension/content/extractor.js'), 'utf8'
);
eval(extractorSrc);

test('extractor registers message handler', () => {
    assert.ok(registeredHandler, 'Should register a runtime.onMessage handler');
});

test('page.getContent extracts body text', () => {
    globalThis.document = makeDoc('Hello world body text', 'My Page');
    let response = null;
    registeredHandler(
        { method: 'page.getContent' },
        {},
        (r) => { response = r; }
    );
    assert.ok(response);
    assert.ok(response.result);
    assert.strictEqual(response.result.title, 'My Page');
    assert.ok(response.result.text.includes('Hello world body text'));
});

test('page.getContent prefers article over body', () => {
    globalThis.document = makeDoc('Full body', 'Article Page', 'Article content only');
    let response = null;
    registeredHandler(
        { method: 'page.getContent' },
        {},
        (r) => { response = r; }
    );
    assert.ok(response.result.text.includes('Article content'));
    assert.ok(!response.result.text.includes('Full body'));
});

test('page.getInfo returns page metadata', () => {
    globalThis.document = makeDoc('', 'Info Page');
    globalThis.location = { href: 'https://example.com/info' };
    let response = null;
    registeredHandler(
        { method: 'page.getInfo' },
        {},
        (r) => { response = r; }
    );
    assert.strictEqual(response.result.title, 'Info Page');
    assert.strictEqual(response.result.url, 'https://example.com/info');
    assert.strictEqual(response.result.readyState, 'complete');
});

test('unknown method returns error', () => {
    let response = null;
    registeredHandler(
        { method: 'unknown.method' },
        {},
        (r) => { response = r; }
    );
    assert.ok(response.error);
    assert.strictEqual(response.error.code, -32601);
});

// ── Text compaction tests (via page.getContent) ──

console.log('\n── text compaction (via extractor) ──');

test('compacts zero-width characters', () => {
    globalThis.document = makeDoc('hello\u200Bworld\u200Ctest\u200D!', 'ZW');
    let response = null;
    registeredHandler({ method: 'page.getContent' }, {}, (r) => { response = r; });
    assert.ok(!response.result.text.includes('\u200B'));
    assert.ok(!response.result.text.includes('\u200C'));
    assert.ok(!response.result.text.includes('\u200D'));
});

test('collapses whitespace', () => {
    globalThis.document = makeDoc('hello     world\t\ttest', 'WS');
    let response = null;
    registeredHandler({ method: 'page.getContent' }, {}, (r) => { response = r; });
    assert.strictEqual(response.result.text, 'hello world test');
});

test('collapses excessive newlines', () => {
    globalThis.document = makeDoc('line1\n\n\n\n\nline2', 'NL');
    let response = null;
    registeredHandler({ method: 'page.getContent' }, {}, (r) => { response = r; });
    assert.strictEqual(response.result.text, 'line1\n\nline2');
});

test('trims whitespace', () => {
    globalThis.document = makeDoc('  hello world  ', 'Trim');
    let response = null;
    registeredHandler({ method: 'page.getContent' }, {}, (r) => { response = r; });
    assert.strictEqual(response.result.text, 'hello world');
});

test('handles empty text', () => {
    globalThis.document = makeDoc('', 'Empty');
    let response = null;
    registeredHandler({ method: 'page.getContent' }, {}, (r) => { response = r; });
    assert.strictEqual(response.result.text, '');
});

// ── Summary ──

console.log(`\n── Results: ${passed} passed, ${failed} failed ──\n`);
process.exit(failed > 0 ? 1 : 0);
