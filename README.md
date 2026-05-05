# AI Option

去中心化 AI 裁判預測市場 — 基於 TEE + OpenRouter AI + 智能合約

## 架構

```
PrefixRegistry (命名前綴註冊)
    ↓
ProviderRegistry (Docker image 指紋 + Provider 質押)
    ↓
BetFactory (合約工廠)
    ↓
BetContract (單一賭約: yes/no, 開倉/平倉, AI 解析)
    ↑
Docker Judge (TEE 內調用 Claude → 簽名回傳)
```

## 核心原則

- **無人能終止**：合約不可升級，Provider 跑在自架 TEE 上
- **無人能篡改**：TEE 遠端認證 + dstack KMS 密鑰派生 + 鏈上指紋驗證
- **絕對 AI 判斷**：即使 AI 出錯也必須跟隨，不設人類裁判
- **任何人可參與**：開發者、Provider、用戶都是 permissionless

## 快速開始

### 1. 安裝依賴

```bash
# Solidity contracts
cd contracts
forge install OpenZeppelin/openzeppelin-contracts
forge build

# Docker judge
cd ../docker-judge
pip install -r requirements.txt
```

### 2. 部署合約 (Sepolia 測試網)

```bash
cd contracts
cp ../.env.example .env
# 編輯 .env 填入 DEPLOYER_PRIVATE_KEY

forge script script/DeployAgentBet.sol:DeployAgentBet \
  --rpc-url sepolia \
  --broadcast \
  --verify \
  -vvvv
```

### 3. 註冊命名前綴

```bash
cast send <PREFIX_REGISTRY_ADDRESS> \
  "register(string)" "v_t" \
  --value 0.01ether \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

### 4. 註冊 Docker Image 指紋

```bash
# Build Docker image
cd docker-judge
docker build -t agent-bet-judge:v1 .
FINGERPRINT=$(docker inspect agent-bet-judge:v1 | jq -r '.[0].Id' | cut -d: -f2)

# Register on-chain
cast send <PROVIDER_REGISTRY_ADDRESS> \
  "registerImage(string,bytes32)" "v_tjudge" "$FINGERPRINT" \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

### 5. 成為 Provider

```bash
cast send <PROVIDER_REGISTRY_ADDRESS> \
  "registerProvider(string,uint256,uint256)" \
  "v_tjudge" 1 10000000000000000 \
  --value 0.1ether \
  --private-key $PROVIDER_PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

### 6. 創建賭約

```bash
# 使用 cast 調用 BetFactory.createBet()
# 或透過前端介面
```

### 7. 運行 Docker Judge

```bash
cd docker-judge
OPENROUTER_API_KEY=sk-or-v1-... \
ETH_PRIVATE_KEY=... \
BET_CONTRACT_ADDRESS=0x... \
PROVIDER_REGISTRY_ADDRESS=0x... \
python judge.py
```

## 合約地址 (Sepolia)

| 合約 | 地址 |
|------|------|
| PrefixRegistry | TBD |
| ProviderRegistry | TBD |
| BetFactory | TBD |

## 目錄結構

```
aioption/
├── contracts/           # Solidity 智能合約 (Foundry)
│   ├── src/
│   │   ├── PrefixRegistry.sol
│   │   ├── ProviderRegistry.sol
│   │   ├── BetFactory.sol
│   │   └── BetContract.sol
│   ├── script/
│   │   └── DeployAgentBet.sol
│   └── test/
├── docker-judge/        # Docker image + AI 裁判
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── judge.py
│   └── requirements.txt
└── .env.example
```

## License

MIT