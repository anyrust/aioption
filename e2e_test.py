#!/usr/bin/env python3
"""AI Option — 完整端到端測試腳本 (支援多選項)"""
import subprocess, sys, time, json
from eth_account import Account
from eth_account.messages import encode_defunct
from web3 import Web3

RPC = "http://localhost:8545"

# Anvil default accounts
DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEV_KEY     = "0x59c6996e6d6220f5c66ab03d5055fffe3e0817d1f58d3c4e0b5f35c80acfc8b0"
P1_KEY      = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
P2_KEY      = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"
P3_KEY      = "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
U1_KEY      = "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"
U2_KEY      = "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e"
FP          = "0xdeadbeef01000000000000000000000000000000000000000000000000000000"

w3 = Web3(Web3.HTTPProvider(RPC))

def run(cmd):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: {result.stderr[:200]}")
        sys.exit(1)
    return result.stdout.strip()

def sign_resolution(bet_addr, question, result_index, key):
    """Sign using abi.encodePacked(address, string, uint256) + EIP-191"""
    packed = bytes.fromhex(bet_addr[2:]) + question.encode() + result_index.to_bytes(32, 'big')
    msg_hash = w3.keccak(packed)
    signed = Account.sign_message(encode_defunct(msg_hash), key)
    return "0x" + signed.signature.hex()

def deploy_contracts():
    """Deploy all contracts via forge script"""
    prefix_addr = run(
        f'cd contracts && '
        f'forge create src/PrefixRegistry.sol:PrefixRegistry '
        f'--rpc-url {RPC} --private-key {DEPLOYER_KEY} '
        f'--constructor-args 10000000000000000 --broadcast 2>&1 | '
        f'grep "Deployed to" | awk \'{{print $3}}\''
    )
    if not prefix_addr.startswith("0x"):
        raise Exception(f"Failed to get PrefixRegistry address: {prefix_addr}")

    prov_addr = run(
        f'cd contracts && '
        f'forge create src/ProviderRegistry.sol:ProviderRegistry '
        f'--rpc-url {RPC} --private-key {DEPLOYER_KEY} '
        f'--constructor-args {prefix_addr} 100000000000000000 --broadcast 2>&1 | '
        f'grep "Deployed to" | awk \'{{print $3}}\''
    )

    factory_addr = run(
        f'cd contracts && '
        f'forge create src/BetFactory.sol:BetFactory '
        f'--rpc-url {RPC} --private-key {DEPLOYER_KEY} '
        f'--constructor-args {prov_addr} 0 100 --broadcast 2>&1 | '
        f'grep "Deployed to" | awk \'{{print $3}}\''
    )

    return prefix_addr, prov_addr, factory_addr

# ============================================================
# Pre-deployed on Anvil (from previous session):
# ============================================================
PREFIX_REG = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
PROV_REG   = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
FACTORY    = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"

def cast_send(addr, sig, key, *args):
    extra = " ".join(str(a) for a in args)
    return run(f'cast send {addr} "{sig}" {extra} --private-key {key} --rpc-url {RPC} --gas-limit 500000')

def cast_call(addr, sig, *args):
    extra = " ".join(str(a) for a in args)
    return run(f'cast call {addr} "{sig}" {extra} --rpc-url {RPC}')

def create_bet(question, options, min_resolutions=3):
    """Create a bet with custom options using Python web3"""
    factory_abi = json.loads(run(
        f'cd contracts && forge inspect src/BetFactory.sol:BetFactory abi 2>/dev/null || '
        f'cast abi-encode "f(uint256)" 0'
    ).split('\n')[0] if False else json.dumps([{
        "type": "function",
        "name": "createBet",
        "inputs": [{
            "type": "tuple", "name": "_config",
            "components": [
                {"name": "question", "type": "string"},
                {"name": "judgeAppId", "type": "string"},
                {"name": "judgeVersion", "type": "uint256"},
                {"name": "judgeFingerprint", "type": "bytes32"},
                {"name": "tokenType", "type": "uint8"},
                {"name": "tokenAddress", "type": "address"},
                {"name": "minBetAmount", "type": "uint256"},
                {"name": "bettingStartTime", "type": "uint256"},
                {"name": "bettingEndTime", "type": "uint256"},
                {"name": "resolveDeadline", "type": "uint256"},
                {"name": "minResolutions", "type": "uint256"},
                {"name": "options", "type": "string[]"},
            ]
        }],
        "outputs": [{"name": "betContract", "type": "address"}],
        "stateMutability": "payable",
    }]))

    acct = Account.from_key(DEV_KEY)
    factory = w3.eth.contract(address=Web3.to_checksum_address(FACTORY), abi=factory_abi)
    now = int(time.time())

    config = (
        question,
        "v_tjudge",
        1,
        Web3.to_bytes(hexstr=FP),
        0,  # ETH
        "0x0000000000000000000000000000000000000000",
        Web3.to_wei(0.01, 'ether'),
        now,
        now + 3600,
        now + 7200,
        min_resolutions,
        options,
    )

    tx = factory.functions.createBet(config).build_transaction({
        'from': acct.address,
        'nonce': w3.eth.get_transaction_count(acct.address),
        'gas': 6000000,
        'maxFeePerGas': w3.eth.max_priority_fee + 2 * w3.eth.get_block('latest')['baseFeePerGas'],
        'maxPriorityFeePerGas': w3.eth.max_priority_fee,
    })
    signed = acct.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

    for log in receipt['logs']:
        if log['address'].lower() == FACTORY.lower():
            return '0x' + log['topics'][1].hex()[-40:]
    raise Exception("BetContract not found in logs")

# ============================================================
# TEST: Multi-Option Lifecycle
# ============================================================
def test_multioplifecycycle():
    print("=" * 60)
    print("AI Option — 多選項端到端測試")
    print("=" * 60)

    # --- Setup ---
    print("\n[1] Register prefix + image + providers...")
    cast_send(PREFIX_REG, "register(string)", DEV_KEY, "v_t")
    cast_send(PROV_REG, "registerImage(string,bytes32)", DEV_KEY, "v_tjudge", FP)
    for pk in [P1_KEY, P2_KEY, P3_KEY]:
        cast_send(PROV_REG, "registerProvider(string,uint256,uint256)", pk,
                  "v_tjudge", "1", "10000000000000000", "--value", "0.1ether")
    print("  ✓ Registered")

    # --- Create bet with 3 options ---
    print("\n[2] Create bet: 3 options (Team A / Team B / Draw)...")
    bet_addr = create_bet(
        "Who will win the match?",
        ["Team A wins", "Team B wins", "Draw"],
        min_resolutions=3
    )
    print(f"  ✓ BetContract: {bet_addr}")

    # Verify options
    n = cast_call(bet_addr, "getOptionCount()(uint256)")
    assert n == "3", f"Expected 3 options, got {n}"

    opt0 = cast_call(bet_addr, "options(uint256)(string)", "0")
    assert "Team A" in opt0, f"Unexpected option 0: {opt0}"
    print(f"  Options verified: [{opt0}, "
          f"{cast_call(bet_addr, 'options(uint256)(string)', '1')}, "
          f"{cast_call(bet_addr, 'options(uint256)(string)', '2')}]")

    # --- Place bets ---
    print("\n[3] Place bets on different options...")
    cast_send(bet_addr, "placeBet(uint256,uint256)", U1_KEY, "0", "1000000000000000000",
              "--value", "1ether")
    cast_send(bet_addr, "placeBet(uint256,uint256)", U2_KEY, "1", "500000000000000000",
              "--value", "0.5ether")

    total0 = cast_call(bet_addr, "totalOptionAmounts(uint256)(uint256)", "0")
    total1 = cast_call(bet_addr, "totalOptionAmounts(uint256)(uint256)", "1")
    assert "1000000000000000000" in total0, f"Expected 1 ETH on option 0"
    assert "500000000000000000" in total1, f"Expected 0.5 ETH on option 1"
    print(f"  ✓ Option 0 (Team A): {total0}")
    print(f"  ✓ Option 1 (Team B): {total1}")

    # --- Warp & Start Resolving ---
    bet_end_raw = cast_call(bet_addr, "bettingEndTime()(uint256)")
    bet_end = int(bet_end_raw.split('[')[0].strip())
    print(f"\n[4] Warp to {bet_end+1}, start resolving...")
    run(f"cast rpc anvil_setNextBlockTimestamp {hex(bet_end+1)} --rpc-url {RPC}")
    run(f"cast rpc anvil_mine --rpc-url {RPC}")
    cast_send(bet_addr, "startResolving()", U1_KEY)
    status = cast_call(bet_addr, "status()(uint8)")
    assert "2" in status, f"Expected status 2 (RESOLVING), got {status}"
    print("  ✓ Status: RESOLVING")

    # --- Submit Resolutions ---
    print("\n[5] Submit AI resolutions (P1:TeamA, P2:TeamA, P3:Draw)...")
    question = cast_call(bet_addr, "question()(string)").strip('"')

    sig1 = sign_resolution(bet_addr, question, 0, P1_KEY)
    sig2 = sign_resolution(bet_addr, question, 0, P2_KEY)
    sig3 = sign_resolution(bet_addr, question, 2, P3_KEY)

    cast_send(bet_addr, "submitResolution(uint256,bytes)", P1_KEY, "0", sig1)
    cast_send(bet_addr, "submitResolution(uint256,bytes)", P2_KEY, "0", sig2)
    cast_send(bet_addr, "submitResolution(uint256,bytes)", P3_KEY, "2", sig3)
    print("  ✓ All 3 resolutions submitted")

    # --- Check Consensus ---
    print("\n[6] Check consensus...")
    status = cast_call(bet_addr, "status()(uint8)")
    winner = cast_call(bet_addr, "winningOption()(uint256)")
    consensus = cast_call(bet_addr, "consensusReached()(bool)")

    assert "3" in status, f"Expected RESOLVED(3), got {status}"
    assert "0" in winner, f"Expected winner=0 (Team A), got {winner}"
    assert "true" in consensus.lower(), f"Expected consensus=true"
    print(f"  ✓ RESOLVED — Winner: Team A wins (option 0)")
    print(f"  ✓ Consensus: {consensus.strip()}")

    # --- Check Resolution Stats ---
    stats = cast_call(bet_addr, "getResolutionStats()(uint256[],uint256)")
    print(f"  ✓ Vote counts: {stats}")

    # --- Claim Rewards ---
    print("\n[7] Claim rewards...")
    u1_before = int(run(f"cast balance {w3.eth.account.from_key(U1_KEY).address} --rpc-url {RPC}"))
    cast_send(bet_addr, "claimReward()", U1_KEY)
    u1_after = int(run(f"cast balance {w3.eth.account.from_key(U1_KEY).address} --rpc-url {RPC}"))
    profit = (u1_after - u1_before) / 1e18
    print(f"  ✓ U1 profit: {profit:.6f} ETH")

    # --- Odds Check ---
    print("\n[8] Check multi-option odds...")
    odds_out = cast_call(bet_addr, "getOdds()(uint256[],uint256[])")
    print(f"  ✓ Odds: {odds_out}")

    print("\n" + "=" * 60)
    print("ALL TESTS PASSED — Multi-option lifecycle verified!")
    print("=" * 60)

if __name__ == "__main__":
    test_multioplifecycycle()
