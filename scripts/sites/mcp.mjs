// A small MCP client for cha-mcp: the site checks drive cha the way
// Claude Code does. node >= 22 (fetch, top-level await).
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';

export async function connect(bridge) {
  const p = spawn(bridge, [], { stdio: ['pipe', 'pipe', 'inherit'] });
  let buf = '', id = 0;
  const waiting = new Map();
  p.stdout.on('data', d => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      const m = JSON.parse(line);
      waiting.get(m.id)?.(m); waiting.delete(m.id);
    }
  });
  const rpc = (method, params) => new Promise(r => {
    const n = ++id; waiting.set(n, r);
    p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: n, method, params }) + '\n');
  });
  await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'sites', version: '1' } });
  p.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const call = async (name, args = {}) => {
    const r = await rpc('tools/call', { name, arguments: args });
    const content = r.result?.content ?? [];
    return {
      error: !!r.result?.isError || !!r.error,
      text: content.filter(c => c.type === 'text').map(c => c.text).join('\n') || JSON.stringify(r.error ?? ''),
      image: content.find(c => c.type === 'image')?.data,
    };
  };
  const tab = { id: null };
  return {
    call,
    close: () => p.stdin.end(),
    async open(url, wait = 3000) {
      const r = await call('open_tab', { url });
      tab.id = r.text.match(/\[(\w{8})\]/)?.[1];
      await sleep(wait);
      return r;
    },
    // JS in the session's tab; the value comes back parsed when it is JSON.
    async js(code) {
      const r = await call('javascript', { code, ...(tab.id ? { tab_id: tab.id } : {}) });
      if (r.error) return { __error: r.text };
      try { return JSON.parse(r.text); } catch { return r.text; }
    },
    async shot(file) {
      const r = await call('screenshot', tab.id ? { tab_id: tab.id } : {});
      if (r.image) { mkdirSync(file.replace(/\/[^/]*$/, ''), { recursive: true }); writeFileSync(file, Buffer.from(r.image, 'base64')); }
      return r;
    },
    async closeTab() { if (tab.id) await call('close_tab', { tab_id: tab.id }); tab.id = null; },
    tab,
  };
}

export const sleep = ms => new Promise(r => setTimeout(r, ms));
