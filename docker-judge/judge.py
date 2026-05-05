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
        "model": "anthropic/claude-opus-4-6",
        "headers": {"HTTP-Referer": "https://github.com/aioption", "X-Title": "AI Option Judge"},
    },
    {
        "name": "DeepSeek",
        "endpoint": "https://api.deepseek.com/v1/chat/completions",
        "key_env": "DEEPSEEK_API_KEY",
        "model": "deepseek-chat",
    },
    {
        "name": "Anthropic",
        "endpoint": "https://api.anthropic.com/v1/messages",
        "key_env": "ANTHROPIC_API_KEY",
        "model": "claude-opus-4-6-20250514",
        "type": "anthropic",
    },
    {
        "name": "OpenAI",
        "endpoint": "https://api.openai.com/v1/chat/completions",
        "key_env": "OPENAI_API_KEY",
        "model": "gpt-4o",
    },
]


def query_ai(question: str, options: list[str]) -> Optional[int]:
    """Try each provider in order. Return option index or None if all fail."""

    options_text = "\n".join(f"[{i}] {name}" for i, name in enumerate(options))
    user_msg = f"Question: {question}\n\nOptions:\n{options_text}\n\nWhich option index is correct? Output ONLY the number."

    for provider in PROVIDERS:
        api_key = os.getenv(provider["key_env"], "")
        endpoint = provider["endpoint"]
        if not api_key or not endpoint:
            continue

        logger.info(f"Trying {provider['name']} ({provider['model']})...")

        try:
            if provider.get("type") == "anthropic":
                result = _call_anthropic(api_key, provider["model"], user_msg)
            else:
                result = _call_openai_compat(
                    endpoint, api_key, provider["model"],
                    user_msg, provider.get("headers", {})
                )

            if result is not None:
                logger.info(f"{provider['name']} → option {result}")
                return result
            else:
                logger.warning(f"{provider['name']} returned unexpected output")

        except Exception as e:
            logger.warning(f"{provider['name']} failed: {e}")

    logger.error("ALL providers failed — returning UNCLEAR")
    return None


def _call_openai_compat(endpoint: str, api_key: str, model: str,
                         user_msg: str, extra_headers: dict) -> Optional[int]:
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    headers.update(extra_headers)

    resp = requests.post(endpoint, json={
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_msg},
        ],
        "max_tokens": 10,
        "temperature": 0.0,
    }, headers=headers, timeout=30)
    resp.raise_for_status()
    return _parse_response(resp.json()["choices"][0]["message"]["content"], len(options))


def _call_anthropic(api_key: str, model: str, user_msg: str) -> Optional[int]:
    resp = requests.post("https://api.anthropic.com/v1/messages", json={
        "model": model,
        "max_tokens": 10,
        "temperature": 0.0,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": user_msg}],
    }, headers={
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
    }, timeout=30)
    resp.raise_for_status()
    text = resp.json()["content"][0]["text"]
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
            "gas": 300000,
            "gasPrice": self.w3.eth.gas_price,
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
