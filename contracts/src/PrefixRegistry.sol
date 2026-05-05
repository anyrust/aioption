// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PrefixRegistry
 * @notice 命名前綴註冊系統
 * @dev 任何人可以消耗 ETH 登記前綴，一旦登記就綁定地址，只有該地址可以發放 app
 *
 * 前綴規則：
 * - 純字母前綴：例如 "abc" → 可以部署 "abc", "abcxyz"
 * - 含底線前綴：例如 "v_t" → 可以部署 "v_t", "v_tabc", "v_txyz"
 * - 登記後只能接純字母，不能再有底線：登記 "v_t" 後 "v_tabc_a" 不合法
 * - 避免命名空間耗盡：用戶用底線規避，例如登記 "v_t" 而非 "v"
 */
contract PrefixRegistry {
    // ============ Errors ============
    error PrefixAlreadyRegistered();
    error InvalidPrefixFormat();
    error NotPrefixOwner();
    error InvalidAppId();
    error InsufficientFee();
    error TransferFailed();

    // ============ Events ============
    event PrefixRegistered(string indexed prefix, address indexed owner, uint256 fee);
    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);
    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);

    // ============ State ============
    /// @notice 合約管理者（可以修改註冊費用）
    address public owner;

    /// @notice 註冊前綴所需費用（ETH wei）
    uint256 public registrationFee;

    /// @notice prefix => owner address
    mapping(string => address) public prefixOwner;

    /// @notice owner => prefix list (for enumeration)
    mapping(address => string[]) public ownerPrefixes;

    // ============ Modifiers ============
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ============ Constructor ============
    constructor(uint256 _registrationFee) {
        owner = msg.sender;
        registrationFee = _registrationFee;
    }

    // ============ Prefix Registration ============

    /**
     * @notice 登記一個命名前綴
     * @param _prefix 前綴字串（純字母 或 字母_字母）
     *
     * 格式規則：
     * - 只允許 [a-zA-Z] 和最多一個底線 _
     * - 底線不能在開頭或結尾
     * - 不能連續兩個底線
     * - 最小長度 1，最大長度 32
     */
    function register(string calldata _prefix) external payable {
        if (msg.value < registrationFee) revert InsufficientFee();
        if (!_isValidPrefix(_prefix)) revert InvalidPrefixFormat();
        if (prefixOwner[_prefix] != address(0)) revert PrefixAlreadyRegistered();

        prefixOwner[_prefix] = msg.sender;
        ownerPrefixes[msg.sender].push(_prefix);

        // 退還多餘的 ETH
        if (msg.value > registrationFee) {
            (bool ok, ) = msg.sender.call{value: msg.value - registrationFee}("");
            if (!ok) revert TransferFailed();
        }

        emit PrefixRegistered(_prefix, msg.sender, registrationFee);
    }

    /**
     * @notice 驗證 appId 是否屬於指定前綴且格式合法
     * @param _prefix 已登記的前綴
     * @param _appId 要驗證的完整 app ID
     * @return valid 是否合法
     *
     * 規則：
     * - appId 必須以前綴開頭
     * - 前綴之後的部分只能是純字母 [a-zA-Z]（不能有底線）
     * - 例如：前綴 "v_t"，appId "v_tabc" ✓，"v_tabc_a" ✗
     */
    function validateAppId(string calldata _prefix, string calldata _appId)
        external
        pure
        returns (bool valid)
    {
        bytes memory prefixBytes = bytes(_prefix);
        bytes memory appIdBytes = bytes(_appId);

        // appId 必須比前綴長或等長
        if (appIdBytes.length < prefixBytes.length) return false;

        // 前綴部分必須完全匹配
        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (appIdBytes[i] != prefixBytes[i]) return false;
        }

        // 剩餘部分只能是純字母
        for (uint256 i = prefixBytes.length; i < appIdBytes.length; i++) {
            bytes1 c = appIdBytes[i];
            if (!_isLetter(c)) return false;
        }

        return true;
    }

    /**
     * @notice 檢查地址是否擁有該前綴
     */
    function isPrefixOwner(string calldata _prefix, address _addr)
        external
        view
        returns (bool)
    {
        return prefixOwner[_prefix] == _addr;
    }

    /**
     * @notice 獲取某地址擁有的前綴數量
     */
    function getOwnerPrefixCount(address _addr) external view returns (uint256) {
        return ownerPrefixes[_addr].length;
    }

    /**
     * @notice 獲取某地址的所有前綴
     */
    function getOwnerPrefixes(address _addr) external view returns (string[] memory) {
        return ownerPrefixes[_addr];
    }

    // ============ Admin ============

    /**
     * @notice 修改註冊費用（僅 owner）
     */
    function setRegistrationFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = registrationFee;
        registrationFee = _newFee;
        emit RegistrationFeeUpdated(oldFee, _newFee);
    }

    /**
     * @notice 轉移合約所有權
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address");
        emit OwnerUpdated(owner, _newOwner);
        owner = _newOwner;
    }

    /**
     * @notice 放棄所有權 → 合約永久固定，無人能再修改
     * @dev 調用後所有 onlyOwner 函數永久失效
     */
    function renounceOwnership() external onlyOwner {
        emit OwnerUpdated(owner, address(0));
        owner = address(0);
    }

    /**
     * @notice 提取合約中的 ETH（僅 owner）
     */
    function withdrawETH() external onlyOwner {
        (bool ok, ) = owner.call{value: address(this).balance}("");
        if (!ok) revert TransferFailed();
    }

    // ============ Internal ============

    /**
     * @dev 驗證前綴格式
     */
    function _isValidPrefix(string calldata _prefix) internal pure returns (bool) {
        bytes memory b = bytes(_prefix);
        uint256 len = b.length;

        if (len == 0 || len > 32) return false;

        bool hasUnderscore = false;

        for (uint256 i = 0; i < len; i++) {
            bytes1 c = b[i];

            if (c == "_") {
                // 底線不能在開頭或結尾，不能出現兩次
                if (i == 0 || i == len - 1 || hasUnderscore) return false;
                hasUnderscore = true;
            } else if (!_isLetter(c)) {
                return false;
            }
        }

        return true;
    }

    /**
     * @dev 檢查是否為英文字母
     */
    function _isLetter(bytes1 _c) internal pure returns (bool) {
        return (_c >= "a" && _c <= "z") || (_c >= "A" && _c <= "Z");
    }
}