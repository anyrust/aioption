// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BetContract} from "./BetContract.sol";
import "./ProviderRegistry.sol";

/**
 * @title BetFactory
 * @notice Bet contract factory — deploys new BetContract instances
 * @dev
 *   Anyone can create a bet, specifying:
 *   - The judge to use (appId + version + fingerprint)
 *   - Payment token (ETH / USDT / WBTC)
 *   - Betting time window
 *   - Minimum number of provider resolutions
 *
 *   The creator pays a small amount of ETH as a deploy fee (covers gas + platform fee)
 */
contract BetFactory {
    // ============ Errors ============
    error InvalidConfig();
    error FingerprintMismatch();
    error TransferFailed();
    error InsufficientDeployFee();

    // ============ Events ============
    event BetCreated(
        address indexed betContract,
        address indexed creator,
        string question,
        string judgeAppId,
        uint256 judgeVersion
    );
    event DeployFeeUpdated(uint256 oldFee, uint256 newFee);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);

    // ============ State ============

    /// @notice ProviderRegistry contract
    ProviderRegistry public immutable providerRegistry;

    /// @notice Contract owner
    address public owner;

    /// @notice Fee for deploying a new bet (ETH wei, covers gas)
    uint256 public deployFee;

    /// @notice Platform fee (taken from bets, basis points: 100 = 1%)
    uint256 public platformFeeBps;

    /// @notice All deployed bet contracts
    address[] public allBets;

    /// @notice creator => list of bets they created
    mapping(address => address[]) public creatorBets;

    /// @notice Supported ERC20 token list
    mapping(address => bool) public supportedTokens;

    // ============ Modifiers ============
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ============ Constructor ============
    constructor(
        address _providerRegistry,
        uint256 _deployFee,
        uint256 _platformFeeBps
    ) {
        require(_providerRegistry != address(0), "Zero registry");
        require(_platformFeeBps <= 500, "Fee too high"); // max 5%

        providerRegistry = ProviderRegistry(payable(_providerRegistry));
        owner = msg.sender;
        deployFee = _deployFee;
        platformFeeBps = _platformFeeBps;
    }

    // ============ Create Bet ============

    /**
     * @notice Create a new bet
     * @param _config Bet configuration
     *
     * Process:
     * 1. Verify fingerprint matches registration in ProviderRegistry
     * 2. Deploy a new BetContract
     * 3. Automatically start the betting phase
     */
    function createBet(BetContract.BetConfig calldata _config)
        external
        payable
        returns (address betContract)
    {
        if (msg.value < deployFee) revert InsufficientDeployFee();

        // Verify fingerprint matches on-chain registration
        bool valid = providerRegistry.verifyFingerprint(
            _config.judgeAppId,
            _config.judgeVersion,
            _config.judgeFingerprint
        );
        if (!valid) revert FingerprintMismatch();

        // Deploy BetContract (ETH only)
        betContract = address(new BetContract(address(providerRegistry), _config));

        // Record
        allBets.push(betContract);
        creatorBets[msg.sender].push(betContract);

        // Start betting
        BetContract(payable(betContract)).startBetting();

        // Refund excess ETH
        if (msg.value > deployFee) {
            (bool ok, ) = msg.sender.call{value: msg.value - deployFee}("");
            if (!ok) revert TransferFailed();
        }

        emit BetCreated(
            betContract,
            msg.sender,
            _config.question,
            _config.judgeAppId,
            _config.judgeVersion
        );
    }

    /**
     * @notice Trigger a bet to enter the resolving phase
     * @dev Anyone can call this after betting ends
     */
    function triggerResolving(address _betContract) external {
        BetContract bet = BetContract(payable(_betContract));
        bet.startResolving();
    }

    // ============ View Functions ============

    /**
     * @notice Get total number of bets
     */
    function getBetCount() external view returns (uint256) {
        return allBets.length;
    }

    /**
     * @notice Get all bets (with pagination support)
     */
    function getBets(uint256 _offset, uint256 _limit)
        external
        view
        returns (address[] memory bets, uint256 total)
    {
        total = allBets.length;
        uint256 end = _offset + _limit;
        if (end > total) end = total;
        if (_offset >= total) return (new address[](0), total);

        bets = new address[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            bets[i - _offset] = allBets[i];
        }
    }

    /**
     * @notice Get a creator's bet list
     */
    function getCreatorBets(address _creator)
        external
        view
        returns (address[] memory)
    {
        return creatorBets[_creator];
    }

    // ============ Admin ============

    /**
     * @notice Add a supported ERC20 token
     */
    function addSupportedToken(address _token) external onlyOwner {
        require(_token != address(0), "Zero address");
        supportedTokens[_token] = true;
    }

    /**
     * @notice Remove a supported ERC20 token
     */
    function removeSupportedToken(address _token) external onlyOwner {
        supportedTokens[_token] = false;
    }

    /**
     * @notice Update deploy fee
     */
    function setDeployFee(uint256 _newFee) external onlyOwner {
        emit DeployFeeUpdated(deployFee, _newFee);
        deployFee = _newFee;
    }

    /**
     * @notice Update platform fee
     */
    function setPlatformFeeBps(uint256 _newFeeBps) external onlyOwner {
        require(_newFeeBps <= 500, "Fee too high");
        emit PlatformFeeUpdated(platformFeeBps, _newFeeBps);
        platformFeeBps = _newFeeBps;
    }

    /**
     * @notice Withdraw ETH from the contract
     */
    function withdrawETH() external onlyOwner {
        (bool ok, ) = owner.call{value: address(this).balance}("");
        if (!ok) revert TransferFailed();
    }

    /**
     * @notice Transfer ownership
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address");
        owner = _newOwner;
    }

    function renounceOwnership() external onlyOwner {
        owner = address(0);
    }
}