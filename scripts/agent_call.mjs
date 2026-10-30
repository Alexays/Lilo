#!/usr/bin/env node
// Calls Lilo's agent tools from a shell, through a build's lilo-mcp. Usage:
// agent_call.mjs <lilo-mcp path> <calls.json>, where calls.json is [{"tool": "navigate", "args": {...}}, ...].
// "$tab" in a string argument becomes the tab the first tabs_create_mcp returned; {"sleep": ms} waits.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const [bridge, callsPath] = process.argv.slice(2);
if (!bridge || !callsPath) {
  console.error('usage: agent_call.mjs <lilo-mcp path> <calls.json>');
  process.exit(2);
}
const calls = JSON.parse(readFileSync(callsPath, 'utf8'));
const child = spawn(bridge, [], { stdio: ['pipe', 'pipe', 'inherit'] });
const pending = new Map();
let nextId = 0;
createInterface({ input: child.stdout }).on('line', line => {
  const message = JSON.parse(line);
  pending.get(message.id)?.(message);
  pending.delete(message.id);
});
const request = (method, params) => new Promise(resolve => {
  const id = ++nextId;
  pending.set(id, resolve);
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
});

await request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'lilo-agent-call', version: '1' } });
child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
let tab;
const substitute = value => typeof value === 'string' ? value.replaceAll('$tab', String(tab))
  : Array.isArray(value) ? value.map(substitute)
  : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).map(([k, v]) => [k, substitute(v)]))
  : value;
let failed = false;
for (const call of calls) {
  if (call.sleep) { await new Promise(resolve => setTimeout(resolve, call.sleep)); continue; }
  const args = substitute(call.args ?? {});
  // A tab number argument stays a number once substituted.
  if (typeof args.tabId === 'string') args.tabId = Number(args.tabId);
  const reply = await request('tools/call', { name: call.tool, arguments: args });
  const text = (reply.result?.content ?? []).filter(c => c.type === 'text').map(c => c.text).join('\n') || JSON.stringify(reply.error);
  if (reply.error || reply.result?.isError) failed = true;
  if (call.tool === 'tabs_create_mcp' && tab === undefined) tab = Number(text.match(/Tab ID: (\d+)/)?.[1]);
  console.log(`== ${call.tool}${call.label ? ` (${call.label})` : ''}\n${text}`);
}
child.stdin.end();
child.kill();
process.exit(failed ? 1 : 0);
