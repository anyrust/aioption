#!/bin/bash
# ============================================================
# AI Option — 輔助腳本
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker-judge"

# ============================================================
# Build Docker image and compute fingerprint
# ============================================================
build_and_fingerprint() {
    local tag="${1:-aioption-judge:v1}"

    echo "Building Docker image: $tag"
    cd "$DOCKER_DIR"
    docker build -t "$tag" .

    echo ""
    echo "=== Docker Image Fingerprint ==="
    # Get the full image ID (sha256 hash)
    local fingerprint
    fingerprint=$(docker inspect "$tag" | jq -r '.[0].Id' | sed 's/^sha256://')
    echo "Fingerprint: $fingerprint"

    # Also compute the compressed image hash (more stable for reproducibility)
    echo ""
    echo "=== Compressed Image Hash (for reproducible builds) ==="
    docker save "$tag" | sha256sum | cut -d' ' -f1

    echo ""
    echo "Register this fingerprint on-chain:"
    echo "  cast send <PROVIDER_REGISTRY_ADDRESS> \\"
    echo "    \"registerImage(string,bytes32)\" \"v_tjudge\" \"$fingerprint\" \\"
    echo "    --private-key \$DEPLOYER_PRIVATE_KEY \\"
    echo "    --rpc-url \$SEPOLIA_RPC_URL"
}

# ============================================================
# Timezone → Unix Timestamp Converter
# ============================================================
tz2unix() {
    local time_str="${1:-}"
    local tz="${2:-UTC}"

    if [ -z "$time_str" ]; then
        echo "Usage: $0 tz2unix \"2026-06-01 12:00\" \"Asia/Shanghai\""
        echo ""
        echo "Examples:"
        echo "  $0 tz2unix \"2026-06-01 12:00\" \"UTC+8\""
        echo "  $0 tz2unix \"2026-06-01 12:00\" \"Asia/Shanghai\""
        echo "  $0 tz2unix \"2026-06-01 12:00\" \"America/New_York\""
        echo "  $0 tz2unix \"2026-12-31 23:59\" \"UTC\""
        echo ""
        echo "Output: Unix timestamp (uint256 for BetConfig)"
        exit 1
    fi

    local olson_tz="$tz"
    if [[ "$tz" =~ ^UTC([+-])([0-9]+)$ ]]; then
        local sign="${BASH_REMATCH[1]}"
        local hours="${BASH_REMATCH[2]}"
        if [ "$sign" = "+" ]; then
            olson_tz="Etc/GMT-$hours"
        else
            olson_tz="Etc/GMT+${hours#-}"
        fi
    fi

    local unix_ts
    if command -v gdate &>/dev/null; then
        unix_ts=$(TZ="$olson_tz" gdate -d "$time_str" +%s 2>/dev/null)
    else
        unix_ts=$(TZ="$olson_tz" date -j -f "%Y-%m-%d %H:%M" "$time_str" +%s 2>/dev/null)
    fi

    if [ -z "$unix_ts" ]; then
        echo "ERROR: Invalid time string or timezone. Use format: \"YYYY-MM-DD HH:MM\""
        exit 1
    fi

    echo "Timezone: $tz ($olson_tz)"
    echo "Time:     $time_str"
    echo "Unix:     $unix_ts"
    echo ""
    echo "# Use in BetConfig:"
    echo "bettingStartTime: $unix_ts"
}

# ============================================================
# Run judge locally (for testing)
# ============================================================
run_local() {
    local bet_contract="${1:-}"
    local provider_registry="${2:-}"

    if [ -z "$bet_contract" ] || [ -z "$provider_registry" ]; then
        echo "Usage: $0 run-local <BET_CONTRACT_ADDRESS> <PROVIDER_REGISTRY_ADDRESS>"
        exit 1
    fi

    cd "$DOCKER_DIR"

    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
        echo "ERROR: OPENROUTER_API_KEY not set"
        exit 1
    fi
    if [ -z "${ETH_PRIVATE_KEY:-}" ]; then
        echo "ERROR: ETH_PRIVATE_KEY not set"
        exit 1
    fi

    BET_CONTRACT_ADDRESS="$bet_contract" \
    PROVIDER_REGISTRY_ADDRESS="$provider_registry" \
    TEE_MODE=local \
    python judge.py
}

# ============================================================
# Deploy contracts (interactive)
# ============================================================
deploy_contracts() {
    cd "$SCRIPT_DIR/contracts"

    if [ ! -f .env ]; then
        echo "ERROR: contracts/.env not found. Copy from .env.example and fill in DEPLOYER_PRIVATE_KEY"
        exit 1
    fi

    echo "Installing dependencies..."
    forge install OpenZeppelin/openzeppelin-contracts --no-commit 2>/dev/null || true

    echo "Building contracts..."
    forge build

    echo ""
    echo "Deploying to Sepolia..."
    forge script script/DeployAgentBet.sol:DeployAgentBet \
        --rpc-url sepolia \
        --broadcast \
        --verify \
        -vvvv
}

# ============================================================
# Main
# ============================================================
case "${1:-}" in
    build)
        build_and_fingerprint "${2:-}"
        ;;
    tz2unix)
        tz2unix "${2:-}" "${3:-}"
        ;;
    run-local)
        run_local "${2:-}" "${3:-}"
        ;;
    deploy)
        deploy_contracts
        ;;
    *)
        echo "Usage: $0 {build|tz2unix|run-local|deploy}"
        echo ""
        echo "  build              Build Docker image and print fingerprint"
        echo "  tz2unix <time> <tz> Convert time+timezone to Unix timestamp"
        echo "  run-local <bet> <reg>  Run judge locally against a bet contract"
        echo "  deploy             Deploy all contracts to Sepolia"
        exit 1
        ;;
esac