// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PrefixRegistry
 * @notice Naming prefix registration system
 * @dev Anyone can register a prefix by paying ETH. Once registered, the prefix
 *      is bound to the owner's address. Only the owner can deploy apps under that prefix.
 *
 *      Prefix rules:
 *      - Alphanumeric prefix: e.g. "abc" → can deploy "abc", "abcxyz"
 *      - Underscore prefix:   e.g. "v_t" → can deploy "v_t", "v_tabc", "v_txyz"
 *      - After registration: suffix must be letters only, no more underscores
 *        e.g. registering "v_t" → "v_tabc" ✓, "v_tabc_a" ✗
 *      - Prevents namespace exhaustion via underscore workaround
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
    address public owner;
    uint256 public registrationFee;
    mapping(string => address) public prefixOwner;
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
     * @notice Register a naming prefix
     * @param _prefix Prefix string (letters only, or letters_letters)
     *
     * Format rules:
     * - Only [a-zA-Z] and at most one underscore _
     * - Underscore cannot be at start or end
     * - No consecutive underscores
     * - Length: 1–32
     */
    function register(string calldata _prefix) external payable {
        if (msg.value < registrationFee) revert InsufficientFee();
        if (!_isValidPrefix(_prefix)) revert InvalidPrefixFormat();
        if (prefixOwner[_prefix] != address(0)) revert PrefixAlreadyRegistered();

        prefixOwner[_prefix] = msg.sender;
        ownerPrefixes[msg.sender].push(_prefix);

        if (msg.value > registrationFee) {
            (bool ok, ) = msg.sender.call{value: msg.value - registrationFee}("");
            if (!ok) revert TransferFailed();
        }

        emit PrefixRegistered(_prefix, msg.sender, registrationFee);
    }

    /**
     * @notice Validate appId belongs to a given prefix and format is legal
     * @param _prefix Registered prefix
     * @param _appId  Full app ID to validate
     * @return valid Whether the app ID is valid under this prefix
     */
    function validateAppId(string calldata _prefix, string calldata _appId)
        external
        pure
        returns (bool valid)
    {
        bytes memory prefixBytes = bytes(_prefix);
        bytes memory appIdBytes = bytes(_appId);

        if (appIdBytes.length < prefixBytes.length) return false;

        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (appIdBytes[i] != prefixBytes[i]) return false;
        }

        for (uint256 i = prefixBytes.length; i < appIdBytes.length; i++) {
            bytes1 c = appIdBytes[i];
            if (!_isLetter(c)) return false;
        }

        return true;
    }

    function isPrefixOwner(string calldata _prefix, address _addr)
        external view returns (bool)
    {
        return prefixOwner[_prefix] == _addr;
    }

    function getOwnerPrefixCount(address _addr) external view returns (uint256) {
        return ownerPrefixes[_addr].length;
    }

    function getOwnerPrefixes(address _addr) external view returns (string[] memory) {
        return ownerPrefixes[_addr];
    }

    // ============ Admin ============

    function setRegistrationFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = registrationFee;
        registrationFee = _newFee;
        emit RegistrationFeeUpdated(oldFee, _newFee);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address");
        emit OwnerUpdated(owner, _newOwner);
        owner = _newOwner;
    }

    /**
     * @notice Renounce ownership — makes the contract permanently immutable
     * @dev After calling, all onlyOwner functions are permanently disabled
     */
    function renounceOwnership() external onlyOwner {
        emit OwnerUpdated(owner, address(0));
        owner = address(0);
    }

    function withdrawETH() external onlyOwner {
        (bool ok, ) = owner.call{value: address(this).balance}("");
        if (!ok) revert TransferFailed();
    }

    // ============ Internal ============

    function _isValidPrefix(string calldata _prefix) internal pure returns (bool) {
        bytes memory b = bytes(_prefix);
        uint256 len = b.length;

        if (len == 0 || len > 32) return false;

        bool hasUnderscore = false;

        for (uint256 i = 0; i < len; i++) {
            bytes1 c = b[i];

            if (c == "_") {
                if (i == 0 || i == len - 1 || hasUnderscore) return false;
                hasUnderscore = true;
            } else if (!_isLetter(c)) {
                return false;
            }
        }

        return true;
    }

    function _isLetter(bytes1 _c) internal pure returns (bool) {
        return (_c >= "a" && _c <= "z") || (_c >= "A" && _c <= "Z");
    }
}
