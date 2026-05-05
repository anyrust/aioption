#!/bin/bash
# ============================================================
# AI Option — Phala Cloud (dstack CVM) 一键部署
# ============================================================
# 前置条件：
#   1. Phala Cloud 账号: https://cloud.phala.com
#   2. npm install -g @phala/cloud
#   3. Docker daemon 运行中
#   4. 设置 OPENROUTER_API_KEY 和 ETH_PRIVATE_KEY
#
# 用法: bash deploy-phala.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker-judge"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} AI Option — Phala Cloud TEE 部署${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

# ============ 检查依赖 ============
check_dep() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${RED}ERROR: $1 not found. Please install it first.${NC}"
        exit 1
    fi
}

check_dep docker
check_dep npm

if ! command -v phala &>/dev/null; then
    echo "Installing phala CLI..."
    npm install -g @phala/cloud
fi

# ============ 检查密钥 ============
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo -e "${RED}ERROR: OPENROUTER_API_KEY not set${NC}"
    echo "  export OPENROUTER_API_KEY=sk-or-v1-..."
    exit 1
fi

if [ -z "${ETH_PRIVATE_KEY:-}" ]; then
    echo -e "${RED}ERROR: ETH_PRIVATE_KEY not set${NC}"
    echo "  export ETH_PRIVATE_KEY=0x..."
    exit 1
fi

# ============ 配置 ============
BET_CONTRACT="${BET_CONTRACT_ADDRESS:-0xab28dba60fb7c0b772b47952ce2396e6bda08ad5}"
PROVIDER_REGISTRY="${PROVIDER_REGISTRY_ADDRESS:-0xaE8716D4d02972CdC36b9bF46082dC5351027Fde}"
RPC_URL="${RPC_URL:-https://ethereum-sepolia.publicnode.com}"

echo "Option:       $BET_CONTRACT"
echo "ProviderRegistry:  $PROVIDER_REGISTRY"
echo "RPC URL:           $RPC_URL"
echo ""

# ============ 构建 Docker 镜像 ============
echo "Building Docker image..."
cd "$DOCKER_DIR"
docker build -t aioption-judge:v1 .

# ============ Phala Cloud 登录 ============
if ! phala status 2>/dev/null | grep -q "Logged in"; then
    echo ""
    echo "Login to Phala Cloud..."
    phala login
fi

# ============ 加密环境变量 ============
echo ""
echo "Encrypting secrets for TEE..."
phala envs encrypt \
    --cvm "$(phala cvms list --limit 1 --json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"])' 2>/dev/null || echo '')" \
    OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
    ETH_PRIVATE_KEY="$ETH_PRIVATE_KEY" \
    RPC_URL="$RPC_URL" \
    BET_CONTRACT_ADDRESS="$BET_CONTRACT" \
    PROVIDER_REGISTRY_ADDRESS="$PROVIDER_REGISTRY" \
    2>/dev/null || echo "(Will be done during deploy)"

# ============ 部署 ============
echo ""
echo -e "${GREEN}Deploying to Phala Cloud TEE...${NC}"
phala deploy \
    --name aioption-judge \
    --compose "$DOCKER_DIR/docker-compose.yml" \
    --kms onchain \
    --chain ethereum-sepolia \
    --env OPENROUTER_API_KEY \
    --env ETH_PRIVATE_KEY \
    --env RPC_URL \
    --env BET_CONTRACT_ADDRESS \
    --env PROVIDER_REGISTRY_ADDRESS \
    --public-tcbinfo

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Deployment Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Verify attestation: phala cvms attestation <CVM_ID>"
echo "  2. View logs: phala logs <CVM_ID>"
echo "  3. Monitor: phala cvms get <CVM_ID>"
echo ""
echo "The TEE judge will now:"
echo "  - Watch Option $BET_CONTRACT on Sepolia"
echo "  - Auto-judge when RESOLVING state detected"
echo "  - Sign and submit resolution from inside TEE"
echo "  - TEE key derived from hardware — no one can extract it"
