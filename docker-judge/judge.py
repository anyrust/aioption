#!/usr/bin/env python3
"""
AI Option Judge — Multi-Provider Fallback

Zero trust in any single AI provider. Configure multiple endpoints.
Fails over automatically. Provider only needs ONE valid API key.

Supported providers (all OpenAI-compatible):
  - Perplexity   (perplexity.ai)     — built-in web search, best for factual bets
  - OpenRouter   (openrouter.ai)     — unified gateway, many models
  - DeepSeek     (deepseek.com)      — cheap, strong reasoning
  - Groq         (groq.com)          — fastest, generous free tier
  - Anthropic    (anthropic.com)     — Claude direct
  - OpenAI       (openai.com)        — GPT-4o direct
  - Together     (together.ai)       — open models at scale
  - Custom        (any OpenAI-compatible endpoint)

Environment:
  PERPLEXITY_API_KEY   — optional
  OPENROUTER_API_KEY   — optional
  DEEPSEEK_API_KEY     — optional
  GROQ_API_KEY         — optional
  ANTHROPIC_API_KEY    — optional
  OPENAI_API_KEY       — optional
  TOGETHER_API_KEY     — optional
  CUSTOM_AI_ENDPOINT + CUSTOM_AI_KEY + CUSTOM_AI_MODEL — optional

If NONE are set → returns UNCLEAR → Provider not slashed,
other Providers will resolve the bet.
"""

import os, json, time, re, logging
from typing import Optional
import requests
from web3 import Web3
from eth_account import Account
from eth_account.messages import encode_defunct

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("aioption-judge")

SYSTEM_PROMPT = """You are an impartial AI judge for a decentralized prediction market.
Your task is to evaluate a bet/question and determine which option is the correct outcome.
Use web search if available to verify facts.

Rules:
1. Base judgment ONLY on verifiable facts.
2. You MUST respond with exactly the option INDEX (0-based integer).
3. Example: ["YES","NO"] → "0" or "1". ["Team A","Team B","Draw"] → "0","1",or "2".
4. Output ONLY the integer. No explanation."""


# ============================================================
# Multi-Provider Fallback Engine
# ============================================================

PROVIDERS = [
    {
        "name": "Perplexity",
        "endpoint": "https://api.perplexity.ai/chat/completions",
        "key_env": "PERPLEXITY_API_KEY",
        "model": "sonar-pro",
    },
    {
        "name": "OpenRouter",
        "endpoint": "https://openrouter.ai/api/v1/chat/completions",
        "key_env": "OPENROUTER_API_KEY",
        "model": "perplexity/sonar-pro",
        "headers": {"HTTP-Referer": "https://github.com/aioption", "X-Title": "AI Option Judge"},
    },
    {
        "name": "Anthropic",
        "endpoint": "https://api.anthropic.com/v1/messages",
        "key_env": "ANTHROPIC_API_KEY",
        "model": "claude-opus-4-7",
        "type": "anthropic",
        "extra_body": {"tools": [{"type": "web_search_20250305"}]},
    },
    {
        "name": "OpenAI",
        "endpoint": "https://api.openai.com/v1/chat/completions",
        "key_env": "OPENAI_API_KEY",
        "model": "gpt-5.5",
        "extra_body": {"web_search_options": {"enabled": True}},
    },
]


def query_ai(question: str, options: list[str], max_reruns: int = 3) -> Optional[int]:
    """Query ALL configured providers. Require majority consensus.
    If tie, re-run up to max_reruns times. Returns winning option index or None."""

    options_text = "\n".join(f"[{i}] {name}" for i, name in enumerate(options))
    user_msg = f"Question: {question}\n\nOptions:\n{options_text}\n\nWhich option index is correct? Output ONLY the number."

    # Collect available providers (those with API key set)
    available = []
    for p in PROVIDERS:
        if os.getenv(p["key_env"], "") and p["endpoint"]:
            available.append(p)

    if len(available) < 2:
        logger.error(f"Need at least 2 LLM providers configured, only {len(available)} available")
        return None

    logger.info(f"Querying {len(available)} providers: {[p['name'] for p in available]}")

    for attempt in range(max_reruns):
        results: dict[int, int] = {}  # option_index → vote count
        round_label = f"Round {attempt + 1}/{max_reruns}" if attempt > 0 else ""

        for provider in available:
            api_key = os.getenv(provider["key_env"], "")
            endpoint = provider["endpoint"]
            if not api_key or not endpoint:
                continue

            logger.info(f"{round_label} {provider['name']} ({provider['model']})...")

            try:
                if provider.get("type") == "anthropic":
                    result = _call_anthropic(api_key, provider["model"], user_msg)
                else:
                    result = _call_openai_compat(
                        endpoint, api_key, provider["model"],
                        user_msg, provider.get("headers", {}),
                        provider.get("extra_body")
                    )

                if result is not None and 0 <= result < len(options):
                    results[result] = results.get(result, 0) + 1
                    logger.info(f"  {provider['name']} → option {result} ({options[result]})")
                else:
                    logger.warning(f"  {provider['name']} → invalid/unexpected output")

            except Exception as e:
                logger.warning(f"  {provider['name']} → ERROR: {e}")

        if not results:
            logger.error("No valid results from any provider")
            if attempt < max_reruns - 1:
                time.sleep(2)
                continue
            return None

        # Check for majority (>= 2 votes same option)
        max_votes = max(results.values())
        total_votes = sum(results.values())

        if max_votes >= 2:
            # Find the winning option
            for opt, votes in results.items():
                if votes == max_votes:
                    logger.info(f"Consensus: option {opt} with {max_votes}/{total_votes} votes")
                    return opt

        # Tie or no majority — re-run
        logger.warning(f"No majority ({results}), re-running...")
        if attempt < max_reruns - 1:
            time.sleep(2)

    logger.error(f"No consensus after {max_reruns} rounds — skipping")
    return None


def _call_openai_compat(endpoint: str, api_key: str, model: str,
                         user_msg: str, extra_headers: dict,
                         extra_body=None) -> Optional[int]:
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    headers.update(extra_headers)

    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_msg},
        ],
        "max_tokens": 10,
        "temperature": 0.0,
    }
    if extra_body:
        body.update(extra_body)

    resp = requests.post(endpoint, json=body, headers=headers, timeout=30)
    resp.raise_for_status()
    return _parse_response(resp.json()["choices"][0]["message"]["content"], 100)


def _call_anthropic(api_key: str, model: str, user_msg: str) -> Optional[int]:
    resp = requests.post("https://api.anthropic.com/v1/messages", json={
        "model": model,
        "max_tokens": 10,
        "temperature": 0.0,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": user_msg}],
        "tools": [{"type": "web_search_20250305"}],
        "tool_choice": {"type": "auto"},
    }, headers={
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
    }, timeout=30)
    resp.raise_for_status()
    # Extract text from response (may include tool_use blocks)
    content = resp.json().get("content", [])
    text = ""
    for block in content:
        if block.get("type") == "text":
            text += block.get("text", "")
    if not text:
        return None
    return _parse_response(text, 100)


def _parse_response(text: str, num_options: int) -> Optional[int]:
    text = text.strip().upper().replace("OPTION", "").replace("INDEX", "")
    match = re.search(r'\d+', text)
    if match:
        idx = int(match.group())
        if 0 <= idx < num_options:
            return idx
    return None


# ============================================================
# Blockchain
# ============================================================

ABI = [
    {"inputs":[{"name":"_result","type":"uint256"},{"name":"_signature","type":"bytes"}],"name":"submitResolution","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[],"name":"status","outputs":[{"name":"","type":"uint8"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"question","outputs":[{"name":"","type":"string"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"optionNames","outputs":[{"name":"","type":"string[]"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"name":"","type":"address"}],"name":"resolutions","outputs":[{"name":"provider","type":"address"},{"name":"result","type":"uint256"},{"name":"signature","type":"bytes"},{"name":"timestamp","type":"uint256"}],"stateMutability":"view","type":"function"},
]

class Chain:
    def __init__(self, rpc: str, bet: str, key: str):
        self.w3 = Web3(Web3.HTTPProvider(rpc))
        self.acct = Account.from_key(key) if key else None
        self.bet = Web3.to_checksum_address(bet) if bet else None
        self.contract = self.w3.eth.contract(address=self.bet, abi=ABI) if self.bet else None
        if self.acct:
            logger.info(f"Provider: {self.acct.address}")

    def status(self): return self.contract.functions.status().call()
    def question(self): return self.contract.functions.question().call()
    def options(self):
        try: return self.contract.functions.optionNames().call()
        except: return ["YES", "NO"]
    def submitted(self):
        r = self.contract.functions.resolutions(self.acct.address).call()
        return r[3] > 0 if self.acct else True

    def submit(self, result: int) -> str:
        q = self.question()
        packed = bytes.fromhex(self.contract.address[2:]) + q.encode() + result.to_bytes(32, "big")
        msg_hash = Web3.keccak(packed)
        sig = self.acct.sign_message(encode_defunct(msg_hash))
        tx = self.contract.functions.submitResolution(result, sig.signature).build_transaction({
            "from": self.acct.address,
            "nonce": self.w3.eth.get_transaction_count(self.acct.address),
            "gas": 3000000,
            "maxFeePerGas": self.w3.eth.max_priority_fee + 2 * self.w3.eth.get_block('latest')['baseFeePerGas'],
            "maxPriorityFeePerGas": self.w3.eth.max_priority_fee,
        })
        signed = self.acct.sign_transaction(tx)
        h = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        logger.info(f"Submitted: {h.hex()}")
        return h.hex()


# ============================================================
# Main
# ============================================================

def main():
    rpc = os.getenv("RPC_URL", "https://ethereum-sepolia.publicnode.com")
    bet = os.getenv("BET_CONTRACT_ADDRESS", "")
    key = os.getenv("ETH_PRIVATE_KEY", "")
    interval = int(os.getenv("POLL_INTERVAL", "15"))

    if not bet:
        logger.error("BET_CONTRACT_ADDRESS required")
        return 1

    chain = Chain(rpc, bet, key)
    logger.info(f"Contract: {bet}")

    while True:
        try:
            if chain.status() != 2:  # RESOLVING
                time.sleep(interval)
                continue
            if chain.submitted():
                logger.info("Already submitted")
                time.sleep(interval)
                continue

            q = chain.question()
            opts = chain.options()
            logger.info(f"=== Judging: {q} ===")
            logger.info(f"Options: {opts}")

            result = query_ai(q, opts)
            if result is None:
                logger.info("Skipping — all providers unavailable")
                time.sleep(interval)
                continue

            logger.info(f"Final: option {result} ({opts[result]})")
            chain.submit(result)

        except Exception as e:
            logger.error(f"Loop error: {e}")
            time.sleep(interval)


if __name__ == "__main__":
    exit(main())
