// AI Option — Agent-first website. Cloudflare Worker.
// No crypto.subtle needed — function selectors pre-computed.

const RPC = "https://arb1.arbitrum.io/rpc";
const FACTORY = "0x66a449082b61129b1740DAEa487D1793467bA020";
const PROVREG = "0x3a46df259F05c460D6793C5D31456239e317A643";

// Pre-computed function selectors (keccak256 first 4 bytes)
const SELECTORS = {
  getOptionCount: "0x77352690",
  getActiveProviderCount: "0xbf575345",
  question: "0xcc2a9a5b",
  status: "0x200d2ed2",
  optionCount: "0xe60ee2e5",
  winningOption: "0xd056af1b",
  consensusReached: "0xb712caf8",
  reRound: "0x76380209",
  tradingEndTime: "0xedb89bd4",
  resolveDeadline: "0x8bdfabec",
  isSettled: "0x7e7fa339",
  minResolutions: "0xd368f976",
  resolutionCount: "0x3270bb5b",
  creator: "0x02d05d3f",
};

async function rpc(method, params) {
  const r = await fetch(RPC, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const d = await r.json();
  return d.result;
}

async function call(addr, selector) {
  try {
    return await rpc("eth_call", [{ to: addr, data: selector }, "latest"]);
  } catch (e) { return null; }
}

function hexInt(h) {
  if (!h || h === "0x") return 0;
  return parseInt(h, 16);
}

async function getOptionCount() { return hexInt(await call(FACTORY, SELECTORS.getOptionCount)); }
async function getProviderCount() { return hexInt(await call(PROVREG, SELECTORS.getActiveProviderCount)); }

async function getOptionInfo(addr) {
  const calls = {
    question: await call(addr, SELECTORS.question),
    status: await call(addr, SELECTORS.status),
    optionCount: await call(addr, SELECTORS.optionCount),
    winningOption: await call(addr, SELECTORS.winningOption),
    consensusReached: await call(addr, SELECTORS.consensusReached),
    reRound: await call(addr, SELECTORS.reRound),
    tradingEndTime: await call(addr, SELECTORS.tradingEndTime),
    resolveDeadline: await call(addr, SELECTORS.resolveDeadline),
    isSettled: await call(addr, SELECTORS.isSettled),
    minResolutions: await call(addr, SELECTORS.minResolutions),
    resolutionCount: await call(addr, SELECTORS.resolutionCount),
    creator: await call(addr, SELECTORS.creator),
  };
  const statusLabels = ["CREATED", "TRADING", "RESOLVING", "RESOLVED"];
  return {
    question: calls.question || "?",
    status: statusLabels[hexInt(calls.status)] || "?",
    options: hexInt(calls.optionCount),
    winner: hexInt(calls.winningOption),
    consensus: calls.consensusReached === "0x" + "0".padStart(63, "0") + "1",
    reRound: hexInt(calls.reRound),
    tradingEnd: hexInt(calls.tradingEndTime),
    resolveDeadline: hexInt(calls.resolveDeadline),
    settled: calls.isSettled === "0x" + "0".padStart(63, "0") + "1",
    minResolutions: hexInt(calls.minResolutions),
    resolutionCount: hexInt(calls.resolutionCount),
    creator: "0x" + (calls.creator || "0").slice(26),
  };
}

async function getRecentOptions() {
  const total = await getOptionCount();
  if (total === 0) return [];
  // Get option addresses from factory
  const data = SELECTORS.getOptionCount; // We use the count
  // For addresses, we need to iterate
  // Simplified: return just count-based info
  return [];
}

addEventListener("fetch", event => {
  event.respondWith(handleRequest(event.request));
});

async function handleRequest(request) {
  const url = new URL(request.url);
  const p = url.pathname;

  const count = await getOptionCount();
  const provCount = await getProviderCount();

  if (p === "/api/status.json") {
    return new Response(JSON.stringify({
      network: "Arbitrum",
      chainId: 42161,
      optionCount: count,
      activeProviders: provCount,
      factory: FACTORY,
      registry: PROVREG,
    }, null, 2), {
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Cache-Control": "public, max-age=30" }
    });
  }

  if (p === "/api/providers.json") {
    return new Response(JSON.stringify({
      activeProviders: provCount,
      registry: PROVREG,
      factory: FACTORY,
      appId: "aijudge",
    }, null, 2), {
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Cache-Control": "public, max-age=60" }
    });
  }

  const html = `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AI Option</title>
<style>body{font:14px/1.6 system-ui,sans-serif;max-width:800px;margin:0 auto;padding:20px;color:#111}pre{background:#f5f5f5;padding:12px;border-radius:4px;font-size:12px;overflow-x:auto}a{color:#06c}h1{font-size:24px;border-bottom:2px solid #111;padding-bottom:8px}h2{font-size:18px;margin-top:24px}.addr{font-family:monospace;font-size:11px;word-break:break-all}.data{font-family:monospace;font-size:11px;color:#555}</style></head>
<body><h1>AI Option</h1><p>Decentralized prediction market. No OAuth. Pure smart contracts. Anyone can verify.</p>
<h2>Network</h2><pre class="data">Chain: Arbitrum (42161)
RPC:  ${RPC}</pre>
<h2>Contracts</h2><pre class="addr">OptionFactory:    ${FACTORY}
ProviderRegistry: ${PROVREG}</pre>
<h2>State</h2><pre class="data">Active Options:  ${count}
Active Providers: ${provCount}</pre>
<h2>API (for AI agents)</h2><pre>GET /api/status.json     — Network status
GET /api/providers.json  — Provider registry</pre>
<h2>Verify</h2><p><a href="https://github.com/anyrust/aioption">GitHub</a> | <a href="https://arbiscan.io/address/${FACTORY}">Arbiscan</a></p>
<p class="data" style="margin-top:40px">No cookies. No tracking. No login. Built for AI agents and humans alike.</p></body></html>`;

  return new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=30" } });
}
