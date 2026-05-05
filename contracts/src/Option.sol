// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ProviderRegistry.sol";

/**
 * @title Option — Decentralized Prediction Market Contract
 * @notice Per-market contract deployed by OptionFactory.
 *         Handles: ETH custody, provider resolution with re-resolution on disagreement,
 *         TEE batch settlement, and provider slashing.
 *
 *         Status: CREATED → TRADING → RESOLVING → RESOLVED
 */
contract Option is ReentrancyGuard {
    // ============ Enums ============
    enum Status { CREATED, TRADING, RESOLVING, RESOLVED }

    // ============ Structs ============
    struct Resolution {
        address provider;
        uint256 result;
        bytes   signature;
        uint256 timestamp;
        uint256 round;     // which re-resolution round
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
    event ResolutionSubmitted(address indexed provider, uint256 result, uint256 round);
    event ReResolutionNeeded(uint256 round, uint256 totalSubmissions);
    event Resolved(uint256 winningOption, uint256 finalRound);
    event Settled(uint256 indexed batchNonce, uint256 totalRecipients);
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
    uint256 public tradingStartTime;
    uint256 public tradingEndTime;
    uint256 public resolveDeadline;
    Status  public status;

    uint256 public optionCount;

    // ============ Balance ============
    mapping(address => uint256) public balances;
    uint256 public totalDeposited;

    // ============ Resolution ============
    uint256 public winningOption;
    bool    public consensusReached;
    uint256 public minResolutions;
    uint256 public resolutionCount;
    uint256 public reRound;    // current re-resolution round (0 = first)
    uint256 public roundStartTime; // timestamp when this round started

    mapping(address => Resolution) public resolutions;
    address[] public resolutionProviders;
    mapping(address => uint256) public lastRoundSubmitted; // provider → round

    // ============ Settlement ============
    uint256 public settlementNonce;
    mapping(address => uint256) public settledAmounts;
    mapping(address => bool) public claimed;
    bool public isSettled;
    address public settler;

    // ============ Modifiers ============
    modifier onlyFactory() { require(msg.sender == factory, "Not factory"); _; }
    modifier inStatus(Status s) { require(status == s, "Invalid status"); _; }

    // ============ Constructor ============
    struct Config {
        string   question;
        string   judgeAppId;
        uint256  judgeVersion;
        bytes32  judgeFingerprint;
        uint256  tradingStartTime;
        uint256  tradingEndTime;
        uint256  resolveDeadline;
        uint256  minResolutions;
        string[] options;
    }

    constructor(address _providerRegistry, Config memory _config) {
        require(_providerRegistry != address(0), "Zero registry");
        require(bytes(_config.question).length > 0, "Empty question");
        require(_config.judgeFingerprint != bytes32(0), "Zero fingerprint");
        require(_config.tradingEndTime > _config.tradingStartTime, "Times");
        require(_config.resolveDeadline > _config.tradingEndTime, "Deadline");
        require(_config.minResolutions >= 2, "Need >= 2 providers");  // at least 2
        uint256 n = _config.options.length;
        require(n >= 2, "Need >= 2 options");

        factory = msg.sender;
        providerRegistry = ProviderRegistry(payable(_providerRegistry));
        creator = tx.origin;
        question = _config.question;
        judgeAppId = _config.judgeAppId;
        judgeVersion = _config.judgeVersion;
        judgeFingerprint = _config.judgeFingerprint;
        tradingStartTime = _config.tradingStartTime;
        tradingEndTime = _config.tradingEndTime;
        resolveDeadline = _config.resolveDeadline;
        minResolutions = _config.minResolutions;
        optionCount = n;
        status = Status.CREATED;
    }

    // ============ Lifecycle ============
    function startTrading() external onlyFactory inStatus(Status.CREATED) { status = Status.TRADING; }

    function startResolving() external inStatus(Status.TRADING) {
        require(block.timestamp >= tradingEndTime, "Not ended");
        status = Status.RESOLVING;
        roundStartTime = block.timestamp;
    }

    // ============ Deposit / Withdraw ============
    receive() external payable { _deposit(msg.sender, msg.value); }
    function deposit() external payable { _deposit(msg.sender, msg.value); }
    function _deposit(address user, uint256 amount) internal {
        balances[user] += amount; totalDeposited += amount;
        emit Deposited(user, amount);
    }
    function withdraw(uint256 _amount) external nonReentrant {
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        balances[msg.sender] -= _amount; totalDeposited -= _amount;
        (bool ok,) = msg.sender.call{value: _amount}(""); require(ok);
        emit Withdrawn(msg.sender, _amount);
    }

    // ============ Resolution (with re-resolution) ============

    /**
     * @notice Provider submits AI-judged result.
     *         If this provider already submitted in a previous round AND
     *         a tie triggered re-resolution, they can submit again.
     */
    function submitResolution(uint256 _result, bytes calldata _signature)
        external inStatus(Status.RESOLVING)
    {
        require(block.timestamp <= resolveDeadline, "Deadline passed");
        require(_result < optionCount, "Invalid option");

        // Allow re-submission only if provider hasn't submitted in THIS round
        require(lastRoundSubmitted[msg.sender] < reRound + 1, "Already submitted this round");

        ProviderRegistry.ProviderInfo memory info = providerRegistry.getProviderInfo(msg.sender);
        require(info.active, "Not active provider");
        require(keccak256(bytes(info.appId)) == keccak256(bytes(judgeAppId)), "Wrong app");
        require(info.version == judgeVersion, "Wrong version");

        bytes32 msgHash = keccak256(abi.encodePacked(address(this), question, _result));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        // Verify against resolution signer (separate hot key), fallback to ETH key
        address expectedSigner = info.resolutionSigner != address(0) ? info.resolutionSigner : msg.sender;
        require(_recoverSigner(ethHash, _signature) == expectedSigner, "Invalid signature");

        resolutions[msg.sender] = Resolution(msg.sender, _result, _signature, block.timestamp, reRound);
        lastRoundSubmitted[msg.sender] = reRound + 1;

        // Track unique providers across rounds
        if (lastRoundSubmitted[msg.sender] == 1) {
            resolutionProviders.push(msg.sender);
        }

        emit ResolutionSubmitted(msg.sender, _result, reRound);
        _checkConsensus();
    }

    function forceResolve() external inStatus(Status.RESOLVING) {
        require(block.timestamp > resolveDeadline, "Not past deadline");
        if (_countCurrentRoundSubmissions() == 0) {
            status = Status.RESOLVED;
            emit Resolved(0, reRound);
            return;
        }
        _finalizeResolution();
    }

    // ============ Settlement ============

    function settle(
        address[] calldata _recipients, uint256[] calldata _amounts,
        bytes calldata _teeSignature
    ) external inStatus(Status.RESOLVED) {
        require(!isSettled && _recipients.length == _amounts.length && _recipients.length > 0);
        bytes32 h = keccak256(abi.encode(address(this), settlementNonce, _recipients, _amounts));
        address signer = _recoverSigner(
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)), _teeSignature);
        ProviderRegistry.ProviderInfo memory info = providerRegistry.getProviderInfo(signer);
        require(info.active && keccak256(bytes(info.appId)) == keccak256(bytes(judgeAppId)), "Bad signer");
        uint256 total;
        for (uint256 i = 0; i < _recipients.length; i++) {
            settledAmounts[_recipients[i]] = _amounts[i]; total += _amounts[i];
        }
        require(total <= address(this).balance);
        isSettled = true; settler = msg.sender; settlementNonce++;
        emit Settled(settlementNonce, _recipients.length);
    }

    function claimReward() external nonReentrant inStatus(Status.RESOLVED) {
        require(isSettled && !claimed[msg.sender]);
        uint256 amount = settledAmounts[msg.sender]; require(amount > 0, "No reward");
        claimed[msg.sender] = true; settledAmounts[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}(""); require(ok);
        emit RewardClaimed(msg.sender, amount);
    }

    // ============ Views ============
    function hasProviderSubmitted(address _p) external view returns (bool) {
        return resolutions[_p].timestamp > 0;
    }
    function getResolutionStats() external view returns (uint256[] memory votes, uint256 total) {
        votes = new uint256[](optionCount);
        uint256 c;
        for (uint256 i = 0; i < resolutionProviders.length; i++) {
            Resolution storage r = resolutions[resolutionProviders[i]];
            if (r.round == reRound && r.timestamp > 0) { if (r.result < optionCount) votes[r.result]++; c++; }
        }
        total = c;
    }
    function getResolutions() external view returns (Resolution[] memory result) {
        result = new Resolution[](resolutionProviders.length);
        for (uint256 i = 0; i < resolutionProviders.length; i++)
            result[i] = resolutions[resolutionProviders[i]];
    }

    // ============ Internal: Consensus ============

    function _countCurrentRoundSubmissions() internal view returns (uint256 count) {
        for (uint256 i = 0; i < resolutionProviders.length; i++)
            if (resolutions[resolutionProviders[i]].round == reRound) count++;
    }

    function _checkConsensus() internal {
        uint256 total = _countCurrentRoundSubmissions();
        if (total < minResolutions) return;

        uint256[] memory votes = new uint256[](optionCount);
        for (uint256 i = 0; i < resolutionProviders.length; i++) {
            Resolution storage r = resolutions[resolutionProviders[i]];
            if (r.round == reRound && r.timestamp > 0 && r.result < optionCount)
                votes[r.result]++;
        }

        uint256 maxVotes; uint256 winIdx;
        for (uint256 i = 0; i < optionCount; i++)
            if (votes[i] > maxVotes) { maxVotes = votes[i]; winIdx = i; }

        uint256 ties;
        for (uint256 i = 0; i < optionCount; i++)
            if (votes[i] == maxVotes) ties++;

        if (ties > 1) {
            // Tie detected → trigger re-resolution
            reRound++;
            roundStartTime = block.timestamp;
            emit ReResolutionNeeded(reRound, total);
            return;
        }

        // Clear majority
        winningOption = winIdx;
        consensusReached = true;
        _finalizeResolution();
    }

    function _finalizeResolution() internal {
        status = Status.RESOLVED;
        emit Resolved(winningOption, reRound);
    }

    function _recoverSigner(bytes32 _hash, bytes memory _sig) internal pure returns (address) {
        require(_sig.length == 65); bytes32 r; bytes32 s; uint8 v;
        assembly { r := mload(add(_sig, 32)) s := mload(add(_sig, 64)) v := byte(0, mload(add(_sig, 96))) }
        if (v < 27) v += 27; require(v == 27 || v == 28);
        return ecrecover(_hash, v, r, s);
    }
}
