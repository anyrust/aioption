# AI OPTION — 遷移文檔

> 從 VS Code Copilot Chat → OpenCode 繼續開發

---

## 專案概述

去中心化 AI 裁判預測市場。任何人開發 Docker image（調用 Claude Opus 4.6 判斷賭約），Provider 在 TEE 內部署執行，結果回傳鏈上智能合約結算。

**核心原則：**
- 無人能終止（合約不可升級，Provider 自架 TEE）
- 無人能篡改（TEE 遠端認證 + dstack KMS + 鏈上指紋）
- 絕對 AI 判斷（不設人類裁判）
- Permissionless（開發者/Provider/用戶皆自由參與）

---

## 目錄結構

```
aioption/
├── contracts/                  # Solidity (Foundry)
│   ├── src/
│   │   ├── PrefixRegistry.sol  # 命名前綴註冊
│   │   ├── ProviderRegistry.sol# Docker 指紋 + Provider 質押
│   │   ├── BetFactory.sol      # 合約工廠
│   │   └── BetContract.sol     # 單一賭約 (yes/no, 開倉平倉)
│   ├── script/
│   │   └── DeployAgentBet.sol  # 部署腳本
│   ├── test/
│   │   └── AgentBet.t.sol      # 51 tests (全部通過 ✅)
│   └── foundry.toml            # via_ir=true, optimizer=true
├── docker-judge/               # AI 裁判 Docker image
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── judge.py                # Claude 調用 + ECDSA 簽名
│   └── requirements.txt
├── e2e_test.py                 # 端到端測試 (Anvil 本地鏈)
├── scripts.sh                  # 輔助腳本
├── .env.example
└── README.md
```

---

## 已完成

### ✅ Solidity 合約 (4 個)

| 合約 | 功能 | 狀態 |
|------|------|------|
| `PrefixRegistry` | 命名前綴註冊（支援 `_` 規避命名耗盡） | ✅ |
| `ProviderRegistry` | Docker image 指紋 + Provider 質押/罰沒 | ✅ |
| `BetFactory` | 合約工廠（驗證 fingerprint → deploy BetContract） | ✅ |
| `BetContract` | yes/no 賭約、開倉平倉、多 Provider AI 解析 | ✅ |

### ✅ Foundry 測試 (51 tests, 全部通過)

```bash
cd contracts && forge test --offline -vvv
# Suite result: ok. 51 passed; 0 failed; 0 skipped
```

測試覆蓋：
- PrefixRegistry: 前綴註冊、格式驗證、appId 驗證、退還多餘 ETH
- ProviderRegistry: image 註冊、多版本、Provider 註冊/退出、staking、slashing
- BetFactory: 創建賭約、fingerprint 驗證、分頁查詢
- BetContract: 完整生命週期（下注→平倉→解析→結算→領獎）、force resolve、錯誤檢查

### ✅ Docker Judge

- `judge.py`: Claude API 調用 + ECDSA 簽名 + 鏈上提交
- `Dockerfile` + `docker-compose.yml`: 支援 dstack TEE 部署

### ✅ 本地鏈部署測試

合約已部署到 Anvil 本地鏈：
```
PrefixRegistry:  0x5FbDB2315678afecb367f032d93F642f64180aa3
ProviderRegistry: 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
BetFactory:      0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
BetContract:     0x75537828f2ce51be7289709686A69CbFDbB714F1
```

步驟 1-7 已驗證成功（註冊前綴、image、Provider、創建賭約、下注）。

---

## 待完成

### 🔴 高優先級

1. **修復 e2e_test.py 簽名驗證**
   - 步驟 8-11：warp 時間 → startResolving → submitResolution → claimReward
   - 當前問題：`submitResolution` 回傳 "Invalid signature"
   - 合約內 `_recoverSigner` 使用 `abi.encodePacked(address, string, uint256)` + EIP-191
   - e2e_test.py 已用 `web3.solidity_pack` + `encode_defunct`，理論上應匹配
   - **調試方法**：在 Anvil 上用 cast 手動比對合約內計算的 hash 和 Python 計算的 hash

2. **部署到 Sepolia 測試網**
   - 需要 Sepolia ETH（faucet 需要瀏覽器互動）
   - 或用主網少量 ETH 透過橋接
   - 部署命令：`forge script script/DeployAgentBet.sol --rpc-url sepolia --broadcast`

3. **Docker image 指紋計算**
   ```bash
   cd docker-judge
   docker build -t agent-bet-judge:v1 .
   docker inspect agent-bet-judge:v1 | jq -r '.[0].Id' | cut -d: -f2
   ```

### 🟡 中優先級

4. **多 Provider 共識機制**
   - 當前：簡單多數決（2/3）
   - 需要：timeout、fallback、LLM 非確定性容忍

5. **Provider 經濟模型**
   - Provider 每次解析收多少費？
   - 誰付 gas？
   - Provider 抵押多少？

6. **TLS Certificate Pinning**
   - 防止 Provider 劫持 Claude API 調用
   - 在 Docker image 內硬編碼 Anthropic TLS 公鑰指紋

### 🟢 低優先級

7. **多選項賭約**（目前只有 yes/no）
8. **ERC20 代幣支援**（USDT/WBTC，目前只有 ETH）
9. **前端介面**
10. **鏈上 TDX quote 驗證**（整合 Automata Network）

---

## 常用命令

### Foundry 測試
```bash
cd contracts
forge test --offline -vvv                    # 全部測試
forge test --offline --match-test test_Full  # 單一測試
forge test --offline --match-test test_Full -vvvvv  # 完整 trace
```

### 本地鏈 (Anvil)
```bash
# 啟動（終端 1）
anvil --port 8545

# 部署合約
forge create --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast src/PrefixRegistry.sol:PrefixRegistry \
  --constructor-args 10000000000000000

# 互動
cast send <ADDR> "register(string)" "v_t" --value 0.01ether \
  --private-key <KEY> --rpc-url http://localhost:8545

cast call <ADDR> "status()(uint8)" --rpc-url http://localhost:8545
```

### Docker
```bash
cd docker-judge
docker build -t agent-bet-judge:v1 .
docker run -e ANTHROPIC_API_KEY=... -e ETH_PRIVATE_KEY=... agent-bet-judge:v1
```

### 端到端測試
```bash
# 確保 Anvil 在 localhost:8545 運行
python3 e2e_test.py
```

---

## 合約架構圖

```
用戶 ──→ BetFactory.createBet()
              │
              │ deploy
              ▼
         BetContract (每個賭約一個)
              │
              │ placeBet() / closePosition()
              │
     ┌───────┴───────┐
     │   BETTING     │
     │  (接受下注)    │
     └───────┬───────┘
             │ startResolving()
     ┌───────┴───────┐
     │  RESOLVING    │
     │ (等 Provider)  │◄── Provider.submitResolution()
     └───────┬───────┘
             │ 共識達成
     ┌───────┴───────┐
     │   RESOLVED    │
     │  (用戶領獎)    │
     └───────────────┘
```

---

## 安全模型

```
Layer 1: Intel TDX 硬體
  → CPU 級別隔離，Host OS 無法讀取 TEE 記憶體
  → 篡改 image → hash 改變 → TDX quote 揭露

Layer 2: dstack-KMS
  → 只有 image hash 匹配鏈上指紋才釋放簽名密鑰
  → KMS 本身也跑在 TEE 裡

Layer 3: 智能合約
  → 只接受有效 ECDSA 簽名的結果
  → 簽名密鑰只有正確的 TEE 實例能拿到

Layer 4: TLS Pinning (應用層)
  → 防止 Provider 劫持 Claude API 調用

Layer 5: 多 Provider 共識 + Slashing
  → 經濟層面防止作惡
```

---

## 關鍵設計決策

1. **appId 命名規則**：前綴後只能純字母，不能有底線
   - `v_t` → `v_tjudge` ✅
   - `v_t` → `v_t_judge` ❌（後綴有底線）

2. **合約不可升級**：無 proxy pattern，部署後永久固定

3. **開發者只能新增版本**：不能覆蓋舊版本，舊賭約永遠指向舊指紋

4. **Provider 退出**：押金全額退還，不設冷卻期（MVP）

5. **Slashing**：目前僅 owner 可調用，未來改 DAO 治理

---

## Anvil 測試帳號

| 角色 | 地址 | 私鑰 |
|------|------|------|
| Deployer | `0xf39Fd...` | `0xac0974...` |
| Developer | `0x70997...` | `0x59c699...` |
| Provider1 | `0x3C44C...` | `0x5de411...` |
| Provider2 | `0x90F79...` | `0x7c8521...` |
| Provider3 | `0x15d34...` | `0x47e179...` |
| User1 | `0x99655...` | `0x8b3a35...` |
| User2 | `0x976EA...` | `0x92db14...` |

---

## 聯絡

- 專案路徑：`/Users/pang/Documents/aioption`
- 所有程式碼已就緒，可直接 `forge test` 驗證
- 有問題直接繼續問 AI
