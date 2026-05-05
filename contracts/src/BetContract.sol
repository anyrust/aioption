// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ProviderRegistry.sol";

/**
 * @title BetContract — Lightweight Settlement Contract
 * @notice Handles only ETH deposit/withdrawal + AI judging + TEE batch settlement.
 *         Order book matching is performed off-chain in Phala TEE, not on-chain.
 *
 *   State machine: CREATED → BETTING → RESOLVING → RESOLVED
 *
 *   Security model:
 *   - Matching engine runs in TEE; attacks cannot affect the contract
 *   - Settlement requires TEE ECDSA signature (from a Provider registered in ProviderRegistry)
 *   - deposit/withdraw are unrestricted (users freely deposit and withdraw)
 */
contract BetContract is ReentrancyGuard {
    // ============ Enums ============
    enum BetStatus { CREATED, BETTING, RESOLVING, RESOLVED }

    // ============ Structs ============
    struct Resolution {
        address provider;
        uint256 result;
        bytes   signature;
        uint256 timestamp;
    }

    // ============ Errors ============
    error NotFactory();
    error InvalidStatus();
    error InvalidOption();
    error InvalidAmount();
    error TransferFailed();
    error InvalidSignature();
    error AlreadyResolved_();
    error AlreadyClaimed();
    error NoPosition();
    error NotSettled();

    // ============ Events ============
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Settled(uint256 indexed batchNonce, uint256 totalRecipients);
    event ResolutionSubmitted(address indexed provider, uint256 result);
    event BetResolved(uint256 winningOption);
    event RewardClaimed(address indexed user, uint256 amount);

    // ============ Immutables ============
    address public immutable factory;
    ProviderRegistry public immutable providerRegistry;
    address public immutable creator;

    // ============ Metadata ============
    string  public question;
    string  public judgeAppId;
    uint256 public judgeVersion;
    bytes32 public judgeFingerprint;
    uint256 public bettingStartTime;
    uint256 public bettingEndTime;
    uint256 public resolveDeadline;
    BetStatus public status;

    string[] public optionNames;
    uint256  public optionCount;

    // ============ Balance ============
    mapping(address => uint256) public balances;
    uint256 public totalDeposited;

    // ============ Resolution ============
    uint256 public winningOption;
    bool    public consensusReached;
    uint256 public minResolutions;
    uint256 public resolutionCount;

    mapping(address => Resolution) public resolutions;
    address[] public resolutionProviders;

    // ============ Settlement ============
    uint256 public settlementNonce;
    mapping(address => uint256) public settledAmounts;   // user => final payout (set by TEE)
    mapping(address => bool) public claimed;
    bool public isSettled;
    address public settler;                              // who called settle()

    // ============ Modifiers ============
    modifier onlyFactory() { require(msg.sender == factory, "Not factory"); _; }
    modifier inStatus(BetStatus s) { require(status == s, "Invalid status"); _; }

    // ============ Constructor ============
    struct BetConfig {
        string   question;
        string   judgeAppId;
        uint256  judgeVersion;
        bytes32  judgeFingerprint;
        uint256  bettingStartTime;
        uint256  bettingEndTime;
        uint256  resolveDeadline;
        uint256  minResolutions;
        string[] options;
    }

    constructor(address _providerRegistry, BetConfig memory _config) {
        require(_providerRegistry != address(0), "Zero registry");
        require(bytes(_config.question).length > 0, "Empty question");
        require(_config.judgeFingerprint != bytes32(0), "Zero fingerprint");
        require(_config.bettingEndTime > _config.bettingStartTime, "Times");
        require(_config.resolveDeadline > _config.bettingEndTime, "Deadline");
        require(_config.minResolutions > 0, "Min resolutions");
        uint256 n = _config.options.length;
        require(n >= 2, "Need >= 2 options");

        factory = msg.sender;
        providerRegistry = ProviderRegistry(payable(_providerRegistry));
        creator = tx.origin;
        question = _config.question;
        judgeAppId = _config.judgeAppId;
        judgeVersion = _config.judgeVersion;
        judgeFingerprint = _config.judgeFingerprint;
        bettingStartTime = _config.bettingStartTime;
        bettingEndTime = _config.bettingEndTime;
        resolveDeadline = _config.resolveDeadline;
        minResolutions = _config.minResolutions;
        for (uint256 i = 0; i < n; i++) {
            require(bytes(_config.options[i]).length > 0, "Empty option");
            optionNames.push(_config.options[i]);
        }
        optionCount = n;
        status = BetStatus.CREATED;
    }

    // ============ Lifecycle ============
    function startBetting() external onlyFactory inStatus(BetStatus.CREATED) { status = BetStatus.BETTING; }

    function startResolving() external inStatus(BetStatus.BETTING) {
        require(block.timestamp >= bettingEndTime, "Not ended");
        status = BetStatus.RESOLVING;
    }

    // ============ Deposit / Withdraw ============
    receive() external payable { _deposit(msg.sender, msg.value); }

    function deposit() external payable { _deposit(msg.sender, msg.value); }

    function _deposit(address user, uint256 amount) internal {
        balances[user] += amount;
        totalDeposited += amount;
        emit Deposited(user, amount);
    }

    function withdraw(uint256 _amount) external nonReentrant {
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        balances[msg.sender] -= _amount;
        totalDeposited -= _amount;
        (bool ok,) = msg.sender.call{value: _amount}("");
        require(ok, "Transfer failed");
        emit Withdrawn(msg.sender, _amount);
    }

    // ============ Resolution (AI Judge) ============
    function submitResolution(uint256 _result, bytes calldata _signature)
        external inStatus(BetStatus.RESOLVING)
    {
        require(block.timestamp <= resolveDeadline, "Deadline passed");
        require(_result < optionCount, "Invalid option");
        require(resolutions[msg.sender].timestamp == 0, "Already submitted");

        ProviderRegistry.ProviderInfo memory info = providerRegistry.getProviderInfo(msg.sender);
        require(info.active, "Not active provider");
        require(keccak256(bytes(info.appId)) == keccak256(bytes(judgeAppId)), "Wrong app");
        require(info.version == judgeVersion, "Wrong version");

        bytes32 msgHash = keccak256(abi.encodePacked(address(this), question, _result));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        require(_recoverSigner(ethHash, _signature) == msg.sender, "Invalid signature");

        resolutions[msg.sender] = Resolution(msg.sender, _result, _signature, block.timestamp);
        resolutionProviders.push(msg.sender);
        resolutionCount++;
        emit ResolutionSubmitted(msg.sender, _result);
        _checkConsensus();
    }

    function forceResolve() external inStatus(BetStatus.RESOLVING) {
        require(block.timestamp > resolveDeadline, "Not past deadline");
        if (resolutionCount == 0) {
            status = BetStatus.RESOLVED;
            emit BetResolved(0);
            return;
        }
        _finalizeResolution();
    }

    // ============ Settlement (TEE Batch) ============

    /**
     * @notice TEE batch settlement: allocates all winner amounts in a single on-chain transaction
     * @param _recipients List of recipient addresses
     * @param _amounts    Corresponding amounts (wei)
     * @param _teeSignature TEE ECDSA signature (Provider's TEE key)
     *
     * Security: signature verification → record settlement amounts → users claim themselves
     */
    function settle(
        address[] calldata _recipients,
        uint256[] calldata _amounts,
        bytes calldata _teeSignature
    ) external inStatus(BetStatus.RESOLVED) {
        require(!isSettled, "Already settled");
        require(_recipients.length == _amounts.length, "Length mismatch");
        require(_recipients.length > 0, "Empty batch");

        // Verify TEE signature (from a Provider registered in ProviderRegistry)
        bytes32 hash = keccak256(abi.encode(address(this), settlementNonce, _recipients, _amounts));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        address signer = _recoverSigner(ethHash, _teeSignature);

        ProviderRegistry.ProviderInfo memory info = providerRegistry.getProviderInfo(signer);
        require(info.active, "Signer not active provider");
        require(keccak256(bytes(info.appId)) == keccak256(bytes(judgeAppId)), "Wrong app");

        // Record settlement
        uint256 totalPayout;
        for (uint256 i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0), "Zero address");
            settledAmounts[_recipients[i]] = _amounts[i];
            totalPayout += _amounts[i];
        }
        // Total payout must not exceed contract balance (safety check)
        require(totalPayout <= address(this).balance, "Insufficient contract balance");

        isSettled = true;
        settler = msg.sender;
        settlementNonce++;
        emit Settled(settlementNonce, _recipients.length);
    }

    // ============ Claim ============
    function claimReward() external nonReentrant inStatus(BetStatus.RESOLVED) {
        require(isSettled, "Not settled yet");
        require(!claimed[msg.sender], "Already claimed");
        uint256 amount = settledAmounts[msg.sender];
        require(amount > 0, "No reward");

        claimed[msg.sender] = true;
        // Deduct from deposited balance (user may already have balance + reward)
        settledAmounts[msg.sender] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");
        emit RewardClaimed(msg.sender, amount);
    }

    // ============ View ============
    function getResolutionStats() external view returns (uint256[] memory votes, uint256 total) {
        votes = new uint256[](optionCount);
        for (uint256 i = 0; i < resolutionProviders.length; i++) {
            uint256 r = resolutions[resolutionProviders[i]].result;
            if (r < optionCount) votes[r]++;
        }
        total = resolutionCount;
    }

    function getResolutions() external view returns (Resolution[] memory result) {
        result = new Resolution[](resolutionProviders.length);
        for (uint256 i = 0; i < resolutionProviders.length; i++) {
            result[i] = resolutions[resolutionProviders[i]];
        }
    }

    function hasProviderSubmitted(address _provider) external view returns (bool) {
        return resolutions[_provider].timestamp > 0;
    }

    // ============ Internal ============
    function _checkConsensus() internal {
        if (resolutionCount < minResolutions) return;
        uint256[] memory voteCounts = new uint256[](optionCount);
        for (uint256 i = 0; i < resolutionProviders.length; i++) {
            uint256 r = resolutions[resolutionProviders[i]].result;
            if (r < optionCount) voteCounts[r]++;
        }
        uint256 maxVotes; uint256 winIdx;
        for (uint256 i = 0; i < optionCount; i++) {
            if (voteCounts[i] > maxVotes) { maxVotes = voteCounts[i]; winIdx = i; }
        }
        uint256 ties;
        for (uint256 i = 0; i < optionCount; i++) {
            if (voteCounts[i] == maxVotes) ties++;
        }
        if (ties > 1) return;
        winningOption = winIdx;
        consensusReached = true;
        _finalizeResolution();
    }

    function _finalizeResolution() internal {
        status = BetStatus.RESOLVED;
        emit BetResolved(winningOption);
    }

    function _recoverSigner(bytes32 _hash, bytes memory _sig) internal pure returns (address) {
        require(_sig.length == 65, "Invalid sig");
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := mload(add(_sig, 32))
            s := mload(add(_sig, 64))
            v := byte(0, mload(add(_sig, 96)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "Invalid v");
        return ecrecover(_hash, v, r, s);
    }
}
