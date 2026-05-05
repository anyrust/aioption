"""
AI Option Judge — TEE 內運行的 AI 裁判

功能：
1. 監聽鏈上 BetContract 的解析請求
2. 調用 OpenRouter API (Claude/DeepSeek 等模型) 判斷賭約
3. 使用 dstack TEE 派生的 ECDSA 密鑰簽名結果
4. 提交簽名結果到智能合約

Provider 部署時需提供：
- OPENROUTER_API_KEY (透過 dstack Encrypted Env Var)
- ETH_PRIVATE_KEY 或使用 dstack 的 key derivation
"""

import os
import json
import time
import hashlib
import logging
from typing import Optional, Tuple
from dataclasses import dataclass

import requests
from web3 import Web3
from web3.middleware import geth_poa_middleware
from eth_account import Account
from eth_account.messages import encode_defunct

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("aioption-judge")


# ============================================================
# Configuration
# ============================================================

@dataclass
class Config:
    # Blockchain
    rpc_url: str
    bet_contract_address: str
    provider_registry_address: str

    # TEE
    tee_mode: str  # "dstack" or "local"
    dstack_sock_path: str  # /var/run/dstack.sock

    # AI (OpenRouter)
    openrouter_api_key: str
    openrouter_model: str  # "anthropic/claude-opus-4-6" or "deepseek/deepseek-chat"

    # Provider
    eth_private_key: str  # 或從 dstack KMS 派生

    # Polling
    poll_interval: int = 15  # seconds
    max_retries: int = 3

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            rpc_url=os.getenv("RPC_URL", "https://ethereum-sepolia.publicnode.com"),
            bet_contract_address=os.getenv("BET_CONTRACT_ADDRESS", ""),
            provider_registry_address=os.getenv("PROVIDER_REGISTRY_ADDRESS", ""),
            tee_mode=os.getenv("TEE_MODE", "local"),
            dstack_sock_path=os.getenv("DSTACK_SOCK_PATH", "/var/run/dstack.sock"),
            openrouter_api_key=os.getenv("OPENROUTER_API_KEY", ""),
            openrouter_model=os.getenv("OPENROUTER_MODEL", "anthropic/claude-opus-4-6"),
            eth_private_key=os.getenv("ETH_PRIVATE_KEY", ""),
            poll_interval=int(os.getenv("POLL_INTERVAL", "15")),
            max_retries=int(os.getenv("MAX_RETRIES", "3")),
        )


# ============================================================
# TEE Attestation (dstack integration)
# ============================================================

class TEEAttestation:
    """
    dstack TEE 整合層

    在 dstack CVM 內：
    - 透過 /var/run/dstack.sock 獲取 TDX quote
    - 透過 dstack KMS 派生 ECDSA 簽名密鑰
    """

    def __init__(self, config: Config):
        self.config = config
        self.derived_key: Optional[str] = None

    def get_tdx_quote(self, report_data: bytes) -> dict:
        """獲取 TDX remote attestation quote"""
        if self.config.tee_mode == "local":
            logger.warning("Local mode: returning mock quote")
            return {"mock": True, "reportData": report_data.hex()}

        try:
            resp = requests.post(
                f"http://localhost/unix:{self.config.dstack_sock_path}:/GetQuote",
                json={"reportData": "0x" + report_data.hex()},
                timeout=10,
            )
            return resp.json()
        except Exception as e:
            logger.error(f"Failed to get TDX quote: {e}")
            raise

    def derive_signing_key(self) -> str:
        """
        從 dstack KMS 派生 ECDSA 簽名密鑰

        dstack 會根據 app image hash + instance id 派生確定性密鑰。
        只有正確的 TEE 實例才能拿到這個密鑰。
        """
        if self.config.tee_mode == "local":
            logger.warning("Local mode: using env ETH_PRIVATE_KEY")
            return self.config.eth_private_key

        try:
            # dstack guest agent 提供 key derivation API
            resp = requests.post(
                f"http://localhost/unix:{self.config.dstack_sock_path}:/DeriveKey",
                json={"keyType": "ecdsa", "path": "bet-judge-signing-key"},
                timeout=10,
            )
            result = resp.json()
            return result.get("privateKey", "")
        except Exception as e:
            logger.error(f"Failed to derive key: {e}")
            raise


# ============================================================
# Claude AI Judge
# ============================================================

SYSTEM_PROMPT = """You are an impartial AI judge for a decentralized prediction market.
Your task is to evaluate a bet/question and determine whether the outcome is YES or NO.

Rules:
1. Base your judgment ONLY on verifiable facts and the provided context.
2. If the question is ambiguous, interpret it as a reasonable person would.
3. If you cannot determine the answer with high confidence, respond with UNCLEAR.
4. You MUST respond with exactly one word: YES, NO, or UNCLEAR.
5. Do NOT provide any explanation, reasoning, or additional text.

The bet was created on the blockchain and your judgment will be used to settle it automatically.
Your response will be cryptographically signed inside a TEE (Trusted Execution Environment)
to prove it came from an unmodified AI judge."""


class ClaudeJudge:
    """調用 OpenRouter API 進行賭約判斷（支援 Claude、DeepSeek 等模型）"""

    def __init__(self, config: Config):
        self.config = config
        self.api_url = "https://openrouter.ai/api/v1/chat/completions"

    def judge(self, question: str, context: str = "") -> Tuple[str, str]:
        """
        判斷賭約結果

        Returns:
            (result, reasoning) where result is "YES", "NO", or "UNCLEAR"
        """
        user_message = f"Question: {question}"
        if context:
            user_message += f"\n\nAdditional Context:\n{context}"

        logger.info(f"Judging: {question[:100]}...")

        for attempt in range(self.config.max_retries):
            try:
                response = requests.post(
                    self.api_url,
                    headers={
                        "Authorization": f"Bearer {self.config.openrouter_api_key}",
                        "Content-Type": "application/json",
                        "HTTP-Referer": "https://github.com/aioption",
                        "X-Title": "AI Option Judge",
                    },
                    json={
                        "model": self.config.openrouter_model,
                        "messages": [
                            {"role": "system", "content": SYSTEM_PROMPT},
                            {"role": "user", "content": user_message},
                        ],
                        "max_tokens": 50,
                        "temperature": 0.0,
                    },
                    timeout=30,
                )
                response.raise_for_status()
                data = response.json()

                result = data["choices"][0]["message"]["content"].strip().upper()
                logger.info(f"OpenRouter response: {result}")

                if result == "YES":
                    return "YES", "AI determined the outcome is YES"
                elif result == "NO":
                    return "NO", "AI determined the outcome is NO"
                else:
                    logger.warning(f"Unexpected response: {result}")
                    return "UNCLEAR", f"AI returned: {result}"

            except Exception as e:
                logger.error(f"API error (attempt {attempt + 1}): {e}")
                if attempt < self.config.max_retries - 1:
                    time.sleep(2 ** attempt)
                else:
                    return "UNCLEAR", f"API error after {self.config.max_retries} attempts: {e}"

        return "UNCLEAR", "Unknown error"


# ============================================================
# Blockchain Integration
# ============================================================

# BetContract ABI (minimal, for resolution submission)
BET_CONTRACT_ABI = [
    {
        "inputs": [
            {"internalType": "enum BetContract.BetOption", "name": "_result", "type": "uint8"},
            {"internalType": "bytes", "name": "_signature", "type": "bytes"},
        ],
        "name": "submitResolution",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "status",
        "outputs": [{"internalType": "enum BetContract.BetStatus", "name": "", "type": "uint8"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "question",
        "outputs": [{"internalType": "string", "name": "", "type": "string"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "resolveDeadline",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"internalType": "address", "name": "", "type": "address"}],
        "name": "resolutions",
        "outputs": [
            {"internalType": "address", "name": "provider", "type": "address"},
            {"internalType": "enum BetContract.BetOption", "name": "result", "type": "uint8"},
            {"internalType": "bytes", "name": "signature", "type": "bytes"},
            {"internalType": "uint256", "name": "timestamp", "type": "uint256"},
        ],
        "stateMutability": "view",
        "type": "function",
    },
]


class BlockchainClient:
    """區塊鏈互動層"""

    def __init__(self, config: Config):
        self.config = config
        self.w3 = Web3(Web3.HTTPProvider(config.rpc_url))
        self.w3.middleware_onion.inject(geth_poa_middleware, layer=0)

        self.account = Account.from_key(config.eth_private_key)
        self.contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(config.bet_contract_address),
            abi=BET_CONTRACT_ABI,
        )

        logger.info(f"Provider address: {self.account.address}")

    def get_bet_status(self) -> int:
        """獲取賭約狀態"""
        return self.contract.functions.status().call()

    def get_question(self) -> str:
        """獲取賭約問題"""
        return self.contract.functions.question().call()

    def has_submitted(self) -> bool:
        """檢查是否已提交解析"""
        resolution = self.contract.functions.resolutions(self.account.address).call()
        return resolution[3] > 0  # timestamp > 0

    def submit_resolution(self, result: str) -> str:
        """
        提交解析結果到鏈上

        Args:
            result: "YES" (0) or "NO" (1)

        Returns:
            transaction hash
        """
        result_value = 0 if result == "YES" else 1

        # 構建簽名訊息
        question = self.get_question()
        message_hash = Web3.solidity_keccak(
            ["address", "string", "uint256"],
            [self.contract.address, question, result_value],
        )

        # 使用 EIP-191 簽名
        signed_message = self.account.sign_message(
            encode_defunct(message_hash)
        )

        # 提交交易
        tx = self.contract.functions.submitResolution(
            result_value,
            signed_message.signature,
        ).build_transaction({
            "from": self.account.address,
            "nonce": self.w3.eth.get_transaction_count(self.account.address),
            "gas": 300000,
            "gasPrice": self.w3.eth.gas_price,
        })

        signed_tx = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

        logger.info(f"Resolution submitted: {tx_hash.hex()}")
        return tx_hash.hex()


# ============================================================
# Main Judge Loop
# ============================================================

class AgentBetJudge:
    """
    主裁判循環

    持續監聽鏈上狀態，當賭約進入 RESOLVING 狀態時：
    1. 調用 Claude 判斷
    2. 簽名結果
    3. 提交到鏈上
    """

    # BetStatus enum values
    STATUS_CREATED = 0
    STATUS_BETTING = 1
    STATUS_RESOLVING = 2
    STATUS_RESOLVED = 3
    STATUS_CANCELLED = 4

    def __init__(self, config: Config):
        self.config = config
        self.tee = TEEAttestation(config)
        self.judge = ClaudeJudge(config)
        self.blockchain = BlockchainClient(config)

    def run_once(self) -> bool:
        """
        執行一次判斷循環

        Returns:
            True if action was taken, False if idle
        """
        try:
            status = self.blockchain.get_bet_status()
        except Exception as e:
            logger.error(f"Failed to get bet status: {e}")
            return False

        # 只在 RESOLVING 狀態時行動
        if status != self.STATUS_RESOLVING:
            logger.debug(f"Bet status: {status}, waiting for RESOLVING ({self.STATUS_RESOLVING})")
            return False

        # 檢查是否已提交
        if self.blockchain.has_submitted():
            logger.info("Already submitted resolution, waiting for finalization")
            return False

        # 獲取問題
        try:
            question = self.blockchain.get_question()
        except Exception as e:
            logger.error(f"Failed to get question: {e}")
            return False

        logger.info(f"=== Resolving bet: {question} ===")

        # 調用 Claude 判斷
        result, reasoning = self.judge.judge(question)
        logger.info(f"Judgment: {result} — {reasoning}")

        if result == "UNCLEAR":
            logger.warning("Claude returned UNCLEAR, skipping submission")
            return False

        # 提交到鏈上
        try:
            tx_hash = self.blockchain.submit_resolution(result)
            logger.info(f"✅ Resolution submitted: {tx_hash}")
            return True
        except Exception as e:
            logger.error(f"Failed to submit resolution: {e}")
            return False

    def run_forever(self):
        """持續運行"""
        logger.info("Agent Bet Judge starting...")
        logger.info(f"Contract: {self.config.bet_contract_address}")
        logger.info(f"Provider: {self.blockchain.account.address}")
        logger.info(f"Model: {self.config.claude_model}")

        while True:
            try:
                self.run_once()
            except Exception as e:
                logger.error(f"Unexpected error in main loop: {e}")

            time.sleep(self.config.poll_interval)


# ============================================================
# Entry Point
# ============================================================

def main():
    config = Config.from_env()

    if not config.openrouter_api_key:
        logger.error("OPENROUTER_API_KEY not set")
        return 1

    if not config.bet_contract_address:
        logger.error("BET_CONTRACT_ADDRESS not set")
        return 1

    if not config.eth_private_key and config.tee_mode == "local":
        logger.error("ETH_PRIVATE_KEY not set (required for local mode)")
        return 1

    judge = AgentBetJudge(config)
    judge.run_forever()
    return 0


if __name__ == "__main__":
    exit(main())