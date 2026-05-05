// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PrefixRegistry.sol";

interface IOption {
    function status() external view returns (uint8);
    function judgeAppId() external view returns (string memory);
    function hasProviderSubmitted(address) external view returns (bool);
    function creator() external view returns (address);
}

/**
 * @title ProviderRegistry
 * @notice Docker image fingerprint registry + Provider staking and pricing
 * @dev
 *   Developers: register Docker image fingerprints (multiple versions)
 *   Providers: deploy specific images, set resolution price, stake collateral
 *
 *   Security model:
 *   - Developers can only add new versions, never overwrite old ones
 *   - Provider stake used to penalize failed resolutions or malicious behavior
 *   - Anyone can become a Provider
 *   - Anyone can slash a non-responding Provider
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
        string indexed appId, uint256 indexed version,
        bytes32 imageFingerprint, address indexed developer
    );
    event ImageDeactivated(string indexed appId, uint256 indexed version);
    event ProviderRegistered(address indexed provider, string indexed appId, uint256 indexed version, uint256 stake);
    event ProviderStakeUpdated(address indexed provider, uint256 newStake);
    event ProviderPriceUpdated(address indexed provider, string indexed appId, uint256 indexed version, uint256 newPrice);
    event ProviderUnregistered(address indexed provider);
    event ProviderSlashed(address indexed provider, uint256 amount, address indexed slasher, string reason);
    event MinStakeUpdated(uint256 oldMinStake, uint256 newMinStake);
    event SlashRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // ============ Structs ============

    struct ImageVersion {
        bytes32 imageFingerprint;
        address developer;
        bool active;
        uint256 registeredAt;
    }

    struct ProviderInfo {
        string appId;
        uint256 version;
        uint256 stake;
        uint256 pricePerResolution;
        bool active;
        uint256 registeredAt;
        uint256 totalResolved;
        address resolutionSigner;
        uint256 availableUntil;
        address referral; // handover: if unavailable, this provider takes over
    }

    // ============ State ============
    PrefixRegistry public immutable prefixRegistry;
    address public owner;
    uint256 public minStake;
    address public slashRecipient;

    mapping(string => mapping(uint256 => ImageVersion)) public imageVersions;
    mapping(string => uint256) public latestVersion;
    mapping(string => uint256[]) public versionList;
    mapping(address => ProviderInfo) public providers;
    address[] public activeProviders;
    mapping(string => mapping(uint256 => address[])) public versionProviders;

    // ============ Modifiers ============
    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }
    modifier onlyProvider() { require(providers[msg.sender].active, "Not an active provider"); _; }

    // ============ Constructor ============
    constructor(address _prefixRegistry, uint256 _minStake) {
        require(_prefixRegistry != address(0), "Zero address");
        prefixRegistry = PrefixRegistry(_prefixRegistry);
        owner = msg.sender;
        minStake = _minStake;
        slashRecipient = msg.sender;
    }

    receive() external payable {}

    // ============ Developer: Image Registration ============

    function registerImage(string calldata _appId, bytes32 _imageFingerprint)
        external returns (uint256 version)
    {
        _validateAppOwnership(_appId);
        version = latestVersion[_appId] + 1;
        if (imageVersions[_appId][version].registeredAt != 0) revert VersionAlreadyExists();

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

    function deactivateVersion(string calldata _appId, uint256 _version) external {
        ImageVersion storage iv = imageVersions[_appId][_version];
        require(iv.registeredAt != 0, "Version not found");
        require(iv.developer == msg.sender, "Not developer");
        require(iv.active, "Already inactive");
        iv.active = false;
        emit ImageDeactivated(_appId, _version);
    }

    function getVersions(string calldata _appId) external view returns (uint256[] memory) {
        return versionList[_appId];
    }

    function getImageVersion(string calldata _appId, uint256 _version) external view returns (ImageVersion memory) {
        return imageVersions[_appId][_version];
    }

    // ============ Provider Registration ============

    function registerProvider(string calldata _appId, uint256 _version, uint256 _pricePerResolution) external payable {
        ImageVersion storage iv = imageVersions[_appId][_version];
        if (iv.registeredAt == 0) revert ImageNotRegistered();
        if (!iv.active) revert VersionNotActive();
        if (providers[msg.sender].active) revert ProviderAlreadyRegistered();
        if (msg.value < minStake) revert InsufficientStake();
        if (_pricePerResolution == 0) revert InvalidPrice();

        providers[msg.sender] = ProviderInfo({
            appId: _appId, version: _version, stake: msg.value,
            pricePerResolution: _pricePerResolution, active: true,
            registeredAt: block.timestamp, totalResolved: 0,
            resolutionSigner: address(0),
            availableUntil: type(uint256).max,
            referral: address(0)
        });

        activeProviders.push(msg.sender);
        versionProviders[_appId][_version].push(msg.sender);

        if (msg.value > minStake) {
            (bool ok, ) = msg.sender.call{value: msg.value - minStake}("");
            if (!ok) revert TransferFailed();
        }

        emit ProviderRegistered(msg.sender, _appId, _version, minStake);
    }

    function addStake() external payable onlyProvider {
        providers[msg.sender].stake += msg.value;
        emit ProviderStakeUpdated(msg.sender, providers[msg.sender].stake);
    }

    function updatePrice(uint256 _newPrice) external onlyProvider {
        if (_newPrice == 0) revert InvalidPrice();
        providers[msg.sender].pricePerResolution = _newPrice;
        emit ProviderPriceUpdated(msg.sender, providers[msg.sender].appId, providers[msg.sender].version, _newPrice);
    }

    /**
     * @notice Provider rotates their resolution signing key.
     *         The ETH key stays cold (only for staking).
     *         Resolution key is hot — used for signing AI results.
     */
    /**
     * @notice Provider sets their availability deadline.
     *         Must be at least 3 days from now.
     *         After this time, provider cannot submit new resolutions.
     */
    /**
     * @notice Provider sets a referral: if unavailable, this provider takes over.
     *         Original provider's stake stays locked — they remain responsible.
     */
    function setReferral(address _referral) external onlyProvider {
        require(_referral != msg.sender, "Cannot refer to self");
        require(providers[_referral].active, "Referral not active");
        require(
            keccak256(bytes(providers[_referral].appId)) == keccak256(bytes(providers[msg.sender].appId)),
            "Different app"
        );
        providers[msg.sender].referral = _referral;
    }

    function setAvailableUntil(uint256 _timestamp) external onlyProvider {
        require(_timestamp >= block.timestamp + 3 days, "Must be >= 3 days");
        providers[msg.sender].availableUntil = _timestamp;
    }

    function updateResolutionSigner(address _newSigner) external onlyProvider {
        require(_newSigner != address(0), "Zero address");
        providers[msg.sender].resolutionSigner = _newSigner;
    }

    function unregisterProvider() external onlyProvider {
        ProviderInfo storage p = providers[msg.sender];
        p.active = false;
        _removeFromActiveProviders(msg.sender);
        _removeFromVersionProviders(p.appId, p.version, msg.sender);
        uint256 stakeToReturn = p.stake;
        p.stake = 0;
        (bool ok, ) = msg.sender.call{value: stakeToReturn}("");
        if (!ok) revert TransferFailed();
        emit ProviderUnregistered(msg.sender);
    }

    // ============ Slashing ============

    function slash(address _provider, uint256 _amount, string calldata _reason) external onlyOwner {
        ProviderInfo storage p = providers[_provider];
        if (p.stake < _amount) revert SlashAmountExceedsStake();
        p.stake -= _amount;
        (bool ok, ) = slashRecipient.call{value: _amount}("");
        if (!ok) revert TransferFailed();

        if (p.stake < minStake && p.active) {
            p.active = false;
            _removeFromActiveProviders(_provider);
            _removeFromVersionProviders(p.appId, p.version, _provider);
            uint256 remaining = p.stake;
            p.stake = 0;
            if (remaining > 0) {
                (bool ok2, ) = _provider.call{value: remaining}("");
                if (!ok2) revert TransferFailed();
            }
        }
        emit ProviderSlashed(_provider, _amount, msg.sender, _reason);
    }

    // ============ View ============

    function getVersionProviders(string calldata _appId, uint256 _version) external view returns (address[] memory) {
        return versionProviders[_appId][_version];
    }

    function getActiveProviderCount() external view returns (uint256) { return activeProviders.length; }

    function getProviderInfo(address _provider) external view returns (ProviderInfo memory) {
        return providers[_provider];
    }

    function verifyFingerprint(string calldata _appId, uint256 _version, bytes32 _fingerprint) external view returns (bool) {
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
     * @notice Anyone can report a Provider that failed to submit a resolution
     * @param _optionAddr The bet contract address
     * @param _provider    The non-responding Provider
     *
     * Conditions:
     * 1. Bet is RESOLVED (via forceResolve)
     * 2. Provider registered for the bet's judge app
     * 3. Provider did NOT submit a resolution
     *
     * Penalty distribution: 50% to bet creator, 50% to bet contract for user refunds
     */
    function slashNonResponder(address _optionAddr, address _provider) external {
        ProviderInfo storage p = providers[_provider];
        require(p.active, "Not active provider");

        IOption bet = IOption(_optionAddr);
        require(uint256(bet.status()) == 3, "Bet not resolved"); // RESOLVED

        require(
            keccak256(bytes(p.appId)) == keccak256(bytes(bet.judgeAppId())),
            "Wrong judge app"
        );

        require(!bet.hasProviderSubmitted(_provider), "Provider already submitted");

        uint256 penalty = minStake / 10;
        if (p.stake < penalty) revert SlashAmountExceedsStake();

        p.stake -= penalty;

        // 50% compensates bet creator, 50% goes to bet contract for user refunds
        address creatorAddr = bet.creator();
        uint256 creatorShare = penalty / 2;
        uint256 userShare = penalty - creatorShare;

        (bool ok1, ) = creatorAddr.call{value: creatorShare}("");
        require(ok1, "Transfer to creator failed");

        (bool ok2, ) = _optionAddr.call{value: userShare}("");
        require(ok2, "Transfer to bet failed");

        emit ProviderSlashed(_provider, penalty, msg.sender, "non-responder");
    }

    // ============ Internal ============

    function _validateAppOwnership(string calldata _appId) internal view {
        bytes memory appIdBytes = bytes(_appId);
        for (uint256 len = appIdBytes.length; len > 0; len--) {
            string memory candidate = _slice(_appId, 0, len);
            if (prefixRegistry.isPrefixOwner(candidate, msg.sender)) {
                require(prefixRegistry.validateAppId(candidate, _appId), "Invalid appId format");
                return;
            }
        }
        revert NotPrefixOwner();
    }

    function _slice(string memory str, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) result[i - start] = strBytes[i];
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

    function _removeFromVersionProviders(string memory _appId, uint256 _version, address _provider) internal {
        address[] storage vp = versionProviders[_appId][_version];
        for (uint256 i = 0; i < vp.length; i++) {
            if (vp[i] == _provider) { vp[i] = vp[vp.length - 1]; vp.pop(); break; }
        }
    }
}
