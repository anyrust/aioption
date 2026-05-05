// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BetContract} from "./BetContract.sol";
import "./ProviderRegistry.sol";

/**
 * @title BetFactory
 * @notice 賭約合約工廠 — 部署新的 BetContract
 * @dev
 *   任何人可以創建賭約，指定：
 *   - 使用的裁判（appId + version + fingerprint）
 *   - 支付代幣（ETH / USDT / WBTC）
 *   - 下注時間窗口
 *   - 最少 Provider 解析數
 *
 *   創建者支付少量 ETH 作為部署費（覆蓋 gas + 平台費）
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

    /// @notice ProviderRegistry 合約
    ProviderRegistry public immutable providerRegistry;

    /// @notice 合約管理者
    address public owner;

    /// @notice 部署新賭約的費用（ETH wei，覆蓋 gas）
    uint256 public deployFee;

    /// @notice 平台手續費（從賭注中抽取，basis points: 100 = 1%）
    uint256 public platformFeeBps;

    /// @notice 所有已部署的賭約
    address[] public allBets;

    /// @notice creator => 他創建的賭約列表
    mapping(address => address[]) public creatorBets;

    /// @notice 支援的 ERC20 代幣列表
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
     * @notice 創建新賭約
     * @param _config 賭約配置
     *
     * 流程：
     * 1. 驗證 fingerprint 匹配 ProviderRegistry 中的註冊
     * 2. 部署新的 BetContract
     * 3. 自動啟動下注階段
     */
    function createBet(BetContract.BetConfig calldata _config)
        external
        payable
        returns (address betContract)
    {
        if (msg.value < deployFee) revert InsufficientDeployFee();

        // 驗證 fingerprint 匹配鏈上註冊
        bool valid = providerRegistry.verifyFingerprint(
            _config.judgeAppId,
            _config.judgeVersion,
            _config.judgeFingerprint
        );
        if (!valid) revert FingerprintMismatch();

        // 部署 BetContract（僅支援 ETH）
        betContract = address(new BetContract(address(providerRegistry), _config));

        // 記錄
        allBets.push(betContract);
        creatorBets[msg.sender].push(betContract);

        // 啟動下注
        BetContract(payable(betContract)).startBetting();

        // 退還多餘 ETH
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
     * @notice 觸發賭約進入解析階段
     * @dev 下注結束後任何人可調用
     */
    function triggerResolving(address _betContract) external {
        BetContract bet = BetContract(payable(_betContract));
        bet.startResolving();
    }

    // ============ View Functions ============

    /**
     * @notice 獲取所有賭約數量
     */
    function getBetCount() external view returns (uint256) {
        return allBets.length;
    }

    /**
     * @notice 獲取所有賭約（支援分頁）
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
     * @notice 獲取某創建者的賭約列表
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
     * @notice 添加支援的 ERC20 代幣
     */
    function addSupportedToken(address _token) external onlyOwner {
        require(_token != address(0), "Zero address");
        supportedTokens[_token] = true;
    }

    /**
     * @notice 移除支援的 ERC20 代幣
     */
    function removeSupportedToken(address _token) external onlyOwner {
        supportedTokens[_token] = false;
    }

    /**
     * @notice 修改部署費用
     */
    function setDeployFee(uint256 _newFee) external onlyOwner {
        emit DeployFeeUpdated(deployFee, _newFee);
        deployFee = _newFee;
    }

    /**
     * @notice 修改平台手續費
     */
    function setPlatformFeeBps(uint256 _newFeeBps) external onlyOwner {
        require(_newFeeBps <= 500, "Fee too high");
        emit PlatformFeeUpdated(platformFeeBps, _newFeeBps);
        platformFeeBps = _newFeeBps;
    }

    /**
     * @notice 提取合約中的 ETH
     */
    function withdrawETH() external onlyOwner {
        (bool ok, ) = owner.call{value: address(this).balance}("");
        if (!ok) revert TransferFailed();
    }

    /**
     * @notice 轉移所有權
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address");
        owner = _newOwner;
    }

    function renounceOwnership() external onlyOwner {
        owner = address(0);
    }
}