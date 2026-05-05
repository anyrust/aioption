// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PrefixRegistry.sol";

interface IBetContract {
    function status() external view returns (uint8);
    function judgeAppId() external view returns (string memory);
    function hasProviderSubmitted(address) external view returns (bool);
    function creator() external view returns (address);
}

/**
 * @title ProviderRegistry
 * @notice Docker image 指紋註冊 + Provider 質押與價格表
 * @dev
 *   開發者：註冊 Docker image 指紋（可多版本）
 *   Provider：部署特定 image，設定解析價格，質押押金
 *
 *   安全模型：
 *   - 開發者只能新增版本，不能覆蓋舊版本
 *   - Provider 的押金用於懲罰解析失敗或攻擊行為
 *   - 任何人可以成為 Provider
 */
contract ProviderRegistry {
    // ============ Errors ============
    error NotPrefixOwner();
    error VersionAlreadyExists();
    error ImageNotRegistered();
    error VersionNotActive();
    error ProviderAlreadyRegistered();
    error ProviderNotRegistered();
    error InsufficientStake();
    error StakeLocked();
    error InvalidPrice();
    error NotProvider();
    error SlashAmountExceedsStake();
    error TransferFailed();

    // ============ Events ============
    event ImageRegistered(
        string indexed appId,
        uint256 indexed version,
        bytes32 imageFingerprint,
        address indexed developer
    );
    event ImageDeactivated(string indexed appId, uint256 indexed version);
    event ProviderRegistered(
        address indexed provider,
        string indexed appId,
        uint256 indexed version,
        uint256 stake
    );
    event ProviderStakeUpdated(address indexed provider, uint256 newStake);
    event ProviderPriceUpdated(
        address indexed provider,
        string indexed appId,
        uint256 indexed version,
        uint256 newPrice
    );
    event ProviderUnregistered(address indexed provider);
    event ProviderSlashed(
        address indexed provider,
        uint256 amount,
        address indexed slasher,
        string reason
    );
    event MinStakeUpdated(uint256 oldMinStake, uint256 newMinStake);
    event SlashRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // ============ Structs ============

    /// @notice Docker image 版本資訊
    struct ImageVersion {
        bytes32 imageFingerprint;   // Docker image hash (sha256)
        address developer;          // 誰發佈的
        bool active;                // 是否啟用（開發者可以停用舊版本）
        uint256 registeredAt;       // 註冊時間
    }

    /// @notice Provider 資訊
    struct ProviderInfo {
        string appId;               // 部署的 app ID
        uint256 version;            // 部署的版本
        uint256 stake;              // 當前押金
        uint256 pricePerResolution; // 每次解析收費 (ETH wei)
        bool active;                // 是否活躍
        uint256 registeredAt;       // 註冊時間
        uint256 totalResolved;      // 累計解析次數
    }

    // ============ State ============

    /// @notice PrefixRegistry 合約
    PrefixRegistry public immutable prefixRegistry;

    /// @notice 合約管理者
    address public owner;

    /// @notice 最小押金要求
    uint256 public minStake;

    /// @notice Slash 罰金接收地址（預設為合約本身，可改為 DAO 金庫）
    address public slashRecipient;

    /// @notice appId => version => ImageVersion
    mapping(string => mapping(uint256 => ImageVersion)) public imageVersions;

    /// @notice appId => 最新版本號
    mapping(string => uint256) public latestVersion;

    /// @notice appId => 版本列表
    mapping(string => uint256[]) public versionList;

    /// @notice provider address => ProviderInfo
    mapping(address => ProviderInfo) public providers;

    /// @notice 所有活躍 Provider 列表
    address[] public activeProviders;

    /// @notice appId => version => 活躍 Provider 列表
    mapping(string => mapping(uint256 => address[])) public versionProviders;

    // ============ Modifiers ============
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyProvider() {
        require(providers[msg.sender].active, "Not an active provider");
        _;
    }

    // ============ Constructor ============
    constructor(address _prefixRegistry, uint256 _minStake) {
        require(_prefixRegistry != address(0), "Zero address");
        prefixRegistry = PrefixRegistry(_prefixRegistry);
        owner = msg.sender;
        minStake = _minStake;
        slashRecipient = msg.sender; // default: deployer receives slashed funds
    }

    // Allow contract to receive ETH (for slash recipient = address(this))
    receive() external payable {}

    // ============ Developer: Image Registration ============

    /**
     * @notice 開發者註冊 Docker image 指紋
     * @param _appId 完整 app ID（必須匹配開發者擁有的前綴）
     * @param _imageFingerprint Docker image sha256 hash
     *
     * 要求：
     * - msg.sender 必須擁有 _appId 對應的前綴
     * - 同版本不能重複註冊
     */
    function registerImage(string calldata _appId, bytes32 _imageFingerprint)
        external
        returns (uint256 version)
    {
        // 驗證 appId 屬於 msg.sender 的前綴
        _validateAppOwnership(_appId);

        version = latestVersion[_appId] + 1;

        // 檢查版本不重複
        if (imageVersions[_appId][version].registeredAt != 0) {
            revert VersionAlreadyExists();
        }

        imageVersions[_appId][version] = ImageVersion({
            imageFingerprint: _imageFingerprint,
            developer: msg.sender,
            active: true,
            registeredAt: block.timestamp
        });

        latestVersion[_appId] = version;
        versionList[_appId].push(version);

        emit ImageRegistered(_appId, version, _imageFingerprint, msg.sender);
    }

    /**
     * @notice 開發者停用某個版本（不能刪除，只能標記 inactive）
     * @dev 已部署該版本的 Provider 不受影響，但新 Provider 無法註冊該版本
     */
    function deactivateVersion(string calldata _appId, uint256 _version) external {
        ImageVersion storage iv = imageVersions[_appId][_version];
        require(iv.registeredAt != 0, "Version not found");
        require(iv.developer == msg.sender, "Not developer");
        require(iv.active, "Already inactive");

        iv.active = false;
        emit ImageDeactivated(_appId, _version);
    }

    /**
     * @notice 獲取某個 appId 的所有版本
     */
    function getVersions(string calldata _appId)
        external
        view
        returns (uint256[] memory)
    {
        return versionList[_appId];
    }

    /**
     * @notice 獲取某個版本的詳細資訊
     */
    function getImageVersion(string calldata _appId, uint256 _version)
        external
        view
        returns (ImageVersion memory)
    {
        return imageVersions[_appId][_version];
    }

    // ============ Provider: Registration & Management ============

    /**
     * @notice Provider 註冊，部署特定 Docker image 版本
     * @param _appId 要部署的 app ID
     * @param _version 要部署的版本
     * @param _pricePerResolution 每次解析收費 (ETH wei)
     *
     * 要求：
     * - 該版本必須存在且 active
     * - msg.value >= minStake
     * - Provider 不能重複註冊
     */
    function registerProvider(
        string calldata _appId,
        uint256 _version,
        uint256 _pricePerResolution
    ) external payable {
        ImageVersion storage iv = imageVersions[_appId][_version];
        if (iv.registeredAt == 0) revert ImageNotRegistered();
        if (!iv.active) revert VersionNotActive();
        if (providers[msg.sender].active) revert ProviderAlreadyRegistered();
        if (msg.value < minStake) revert InsufficientStake();
        if (_pricePerResolution == 0) revert InvalidPrice();

        providers[msg.sender] = ProviderInfo({
            appId: _appId,
            version: _version,
            stake: msg.value,
            pricePerResolution: _pricePerResolution,
            active: true,
            registeredAt: block.timestamp,
            totalResolved: 0
        });

        activeProviders.push(msg.sender);
        versionProviders[_appId][_version].push(msg.sender);

        // 退還多餘的 ETH
        if (msg.value > minStake) {
            (bool ok, ) = msg.sender.call{value: msg.value - minStake}("");
            if (!ok) revert TransferFailed();
        }

        emit ProviderRegistered(msg.sender, _appId, _version, minStake);
    }

    /**
     * @notice Provider 增加押金
     */
    function addStake() external payable onlyProvider {
        providers[msg.sender].stake += msg.value;
        emit ProviderStakeUpdated(msg.sender, providers[msg.sender].stake);
    }

    /**
     * @notice Provider 更新解析價格
     */
    function updatePrice(uint256 _newPrice) external onlyProvider {
        if (_newPrice == 0) revert InvalidPrice();
        ProviderInfo storage p = providers[msg.sender];
        p.pricePerResolution = _newPrice;
        emit ProviderPriceUpdated(msg.sender, p.appId, p.version, _newPrice);
    }

    /**
     * @notice Provider 退出（押金在冷卻期後可取回）
     * @dev 退出後不再接收新的解析請求，但已有請求仍需完成
     */
    function unregisterProvider() external onlyProvider {
        ProviderInfo storage p = providers[msg.sender];
        p.active = false;

        // 從 activeProviders 移除
        _removeFromActiveProviders(msg.sender);

        // 從 versionProviders 移除
        _removeFromVersionProviders(p.appId, p.version, msg.sender);

        // 退還押金
        uint256 stakeToReturn = p.stake;
        p.stake = 0;
        (bool ok, ) = msg.sender.call{value: stakeToReturn}("");
        if (!ok) revert TransferFailed();

        emit ProviderUnregistered(msg.sender);
    }

    // ============ Slashing ============

    /**
     * @notice 對 Provider 進行罰沒
     * @param _provider 被罰沒的 Provider
     * @param _amount 罰沒金額
     * @param _reason 罰沒原因
     *
     * @dev 目前僅 owner 可以調用。未來可改為 DAO 治理或自動化觸發
     */
    function slash(address _provider, uint256 _amount, string calldata _reason)
        external
        onlyOwner
    {
        ProviderInfo storage p = providers[_provider];
        if (p.stake < _amount) revert SlashAmountExceedsStake();

        p.stake -= _amount;

        // 罰金發送到 slashRecipient
        (bool ok, ) = slashRecipient.call{value: _amount}("");
        if (!ok) revert TransferFailed();

        // 如果押金低於最小要求，強制退出
        if (p.stake < minStake && p.active) {
            p.active = false;
            _removeFromActiveProviders(_provider);
            _removeFromVersionProviders(p.appId, p.version, _provider);

            // 退還剩餘押金
            uint256 remaining = p.stake;
            p.stake = 0;
            if (remaining > 0) {
                (bool ok2, ) = _provider.call{value: remaining}("");
                if (!ok2) revert TransferFailed();
            }
        }

        emit ProviderSlashed(_provider, _amount, msg.sender, _reason);
    }

    // ============ View Functions ============

    /**
     * @notice 獲取某版本的活躍 Provider 列表
     */
    function getVersionProviders(string calldata _appId, uint256 _version)
        external
        view
        returns (address[] memory)
    {
        return versionProviders[_appId][_version];
    }

    /**
     * @notice 獲取所有活躍 Provider 數量
     */
    function getActiveProviderCount() external view returns (uint256) {
        return activeProviders.length;
    }

    /**
     * @notice 獲取 Provider 資訊
     */
    function getProviderInfo(address _provider)
        external
        view
        returns (ProviderInfo memory)
    {
        return providers[_provider];
    }

    /**
     * @notice 檢查 image fingerprint 是否匹配鏈上註冊的版本
     * @dev 供 BetFactory 和 off-chain 驗證使用
     */
    function verifyFingerprint(
        string calldata _appId,
        uint256 _version,
        bytes32 _fingerprint
    ) external view returns (bool) {
        ImageVersion storage iv = imageVersions[_appId][_version];
        return iv.active && iv.imageFingerprint == _fingerprint;
    }

    // ============ Admin ============

    function setMinStake(uint256 _newMinStake) external onlyOwner {
        emit MinStakeUpdated(minStake, _newMinStake);
        minStake = _newMinStake;
    }

    function setSlashRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Zero address");
        emit SlashRecipientUpdated(slashRecipient, _newRecipient);
        slashRecipient = _newRecipient;
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address");
        owner = _newOwner;
    }

    function renounceOwnership() external onlyOwner {
        owner = address(0);
    }

    // ============ Permissionless Slashing ============

    /**
     * @notice 任何人可舉報：Provider 未對特定賭約提交決議 → 罰沒押金
     * @param _betContract 賭約地址
     * @param _provider    被舉報的 Provider
     *
     * 條件：
     * 1. 賭約已 RESOLVED（非透過共識，即 forceResolve）
     * 2. Provider 註冊了該賭約的 judge app
     * 3. Provider 未向該賭約提交決議
     */
    function slashNonResponder(address _betContract, address _provider) external {
        ProviderInfo storage p = providers[_provider];
        require(p.active, "Not active provider");

        // 驗證賭約存在且已 settle
        IBetContract bet = IBetContract(_betContract);
        require(uint256(bet.status()) == 3, "Bet not resolved"); // RESOLVED

        // Provider 的 appId 必須匹配賭約的 judgeAppId
        require(
            keccak256(bytes(p.appId)) == keccak256(bytes(bet.judgeAppId())),
            "Wrong judge app"
        );

        // 檢查此 Provider 是否已提交決議
        require(!bet.hasProviderSubmitted(_provider), "Provider already submitted");

        // 罰沒：沒收 minStake * 10% 的押金
        uint256 penalty = minStake / 10;
        if (p.stake < penalty) revert SlashAmountExceedsStake();

        p.stake -= penalty;

        // 50% 賠償賭約創作者，50% 發給賭約合約退還用戶
        address creatorAddr = bet.creator();
        uint256 creatorShare = penalty / 2;
        uint256 userShare = penalty - creatorShare;

        (bool ok1, ) = creatorAddr.call{value: creatorShare}("");
        require(ok1, "Transfer to creator failed");

        (bool ok2, ) = _betContract.call{value: userShare}("");
        require(ok2, "Transfer to bet failed");

        emit ProviderSlashed(_provider, penalty, msg.sender, "non-responder");
    }

    // ============ Internal ============

    /**
     * @dev 驗證 msg.sender 擁有 appId 對應的前綴
     */
    function _validateAppOwnership(string calldata _appId) internal view {
        bytes memory appIdBytes = bytes(_appId);
        // 嘗試從最長到最短匹配前綴
        for (uint256 len = appIdBytes.length; len > 0; len--) {
            string memory candidate = _slice(_appId, 0, len);
            if (prefixRegistry.isPrefixOwner(candidate, msg.sender)) {
                // 驗證 appId 格式
                require(
                    prefixRegistry.validateAppId(candidate, _appId),
                    "Invalid appId format"
                );
                return;
            }
        }
        revert NotPrefixOwner();
    }

    function _slice(string memory str, uint256 start, uint256 end)
        internal
        pure
        returns (string memory)
    {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
    }

    function _removeFromActiveProviders(address _provider) internal {
        for (uint256 i = 0; i < activeProviders.length; i++) {
            if (activeProviders[i] == _provider) {
                activeProviders[i] = activeProviders[activeProviders.length - 1];
                activeProviders.pop();
                break;
            }
        }
    }

    function _removeFromVersionProviders(
        string memory _appId,
        uint256 _version,
        address _provider
    ) internal {
        address[] storage vp = versionProviders[_appId][_version];
        for (uint256 i = 0; i < vp.length; i++) {
            if (vp[i] == _provider) {
                vp[i] = vp[vp.length - 1];
                vp.pop();
                break;
            }
        }
    }
}