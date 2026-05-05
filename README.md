# AI Option

**The Unstoppable Prediction Market — Trustless AI Judgment, On-Chain Settlement.**

AI Option is a fully decentralized prediction market where outcomes are resolved by AI models running inside Trusted Execution Environments (TEEs), with all order book matching and settlement executed on-chain on Ethereum. No admin keys. No human appeals. No single point of failure.

---

## Why AI Option?

Traditional prediction markets rely on centralized oracles or human dispute resolution. AI Option replaces both with **cryptographically attested AI inference**, delivering a market that is:

- **Unstoppable** — Contracts renounce ownership after deployment. No admin can pause, upgrade, or censor the protocol.
- **Permissionless** — Anyone can become a provider, developer, or user. No whitelists, no gatekeepers.
- **Verifiable** — Every AI judgment is backed by a TEE attestation, verifiable on-chain against a registered Docker image fingerprint.
- **Economically Secured** — Providers stake ETH as collateral and face slashing for invalid or unresponsive judgments, aligning incentives with market integrity.
- **Gas-Optimized** — Batch settlement allows multiple positions to be resolved in a single transaction.

---

## Architecture

```
PrefixRegistry (Namespace Registry)
    ↓
ProviderRegistry (Docker Fingerprint Verification + Provider Staking)
    ↓
BetFactory (Contract Factory)
    ↓
BetContract (Individual Market: Yes/No, Open/Close Positions, AI Resolution)
    ↑
TEE Judge (Docker → TEE Attestation → OpenRouter AI → Signed Verdict)
```

### How It Works

1. **Developers** register a namespace prefix on-chain and deploy a Docker image containing their AI judge logic.
2. The **Docker image fingerprint** is registered on `ProviderRegistry`, establishing the canonical reference for TEE attestation.
3. **Providers** run the Docker image inside a TEE (e.g., dstack), stake ETH, and listen for resolution requests.
4. **Users** create or trade positions in prediction markets via `BetFactory` → `BetContract`, using an on-chain order book model.
5. When a market reaches its resolution condition, a **TEE-attested judge** calls OpenRouter (Claude, GPT, or any supported model), evaluates the outcome, and signs the result with a key derived from dstack KMS.
6. The signed verdict is submitted on-chain, verified against the registered image fingerprint, and triggers settlement — distributing funds to winners.

---

## Quick Start

### 1. Install Dependencies

```bash
# Solidity contracts
cd contracts
forge install OpenZeppelin/openzeppelin-contracts
forge build

# Docker judge
cd ../docker-judge
pip install -r requirements.txt
```

### 2. Deploy Contracts (Sepolia Testnet)

```bash
cd contracts
cp ../.env.example .env
# Edit .env with your DEPLOYER_PRIVATE_KEY

forge script script/DeployAgentBet.sol:DeployAgentBet \
  --rpc-url sepolia \
  --broadcast \
  --verify \
  -vvvv
```

### 3. Register a Namespace Prefix

```bash
cast send <PREFIX_REGISTRY_ADDRESS> \
  "register(string)" "v_t" \
  --value 0.01ether \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

### 4. Register a Docker Image Fingerprint

```bash
# Build the Docker image
cd docker-judge
docker build -t agent-bet-judge:v1 .
FINGERPRINT=$(docker inspect agent-bet-judge:v1 | jq -r '.[0].Id' | cut -d: -f2)

# Register the fingerprint on-chain
cast send <PROVIDER_REGISTRY_ADDRESS> \
  "registerImage(string,bytes32)" "v_tjudge" "$FINGERPRINT" \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

### 5. Become a Provider (Stake ETH)

```bash
cast send <PROVIDER_REGISTRY_ADDRESS> \
  "registerProvider(string,uint256,uint256)" \
  "v_tjudge" 1 10000000000000000 \
  --value 0.1ether \
  --private-key $PROVIDER_PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

### 6. Create a Market

```bash
# Use cast to call BetFactory.createBet()
# Or deploy through the frontend interface
```

### 7. Run the TEE Judge

```bash
cd docker-judge
OPENROUTER_API_KEY=sk-or-v1-... \
ETH_PRIVATE_KEY=... \
BET_CONTRACT_ADDRESS=0x... \
PROVIDER_REGISTRY_ADDRESS=0x... \
python judge.py
```

---

## Contract Addresses (Sepolia)

| Contract         | Address |
| ---------------- | ------- |
| PrefixRegistry   | TBD     |
| ProviderRegistry | TBD     |
| BetFactory       | TBD     |

---

## Project Structure

```
aioption/
├── contracts/           # Solidity Smart Contracts (Foundry)
│   ├── src/
│   │   ├── PrefixRegistry.sol      # Namespace prefix registration
│   │   ├── ProviderRegistry.sol    # Image fingerprint & provider staking/slashing
│   │   ├── BetFactory.sol          # Market contract factory
│   │   └── BetContract.sol         # Individual market: yes/no, positions, AI resolution
│   ├── script/
│   │   └── DeployAgentBet.sol      # Deployment script
│   └── test/
├── docker-judge/        # TEE Judge — Docker image + AI resolution logic
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── judge.py
│   └── requirements.txt
└── .env.example
```

---

## License

MIT
