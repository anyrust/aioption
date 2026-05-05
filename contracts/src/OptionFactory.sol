// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Option.sol";
import "./ProviderRegistry.sol";

contract OptionFactory {
    error FingerprintMismatch();

    event OptionCreated(address indexed optionAddr, address indexed creator, string question, string judgeAppId, uint256 judgeVersion);

    ProviderRegistry public immutable providerRegistry;
    address public owner;
    address[] public allOptions;

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor(address _pr) {
        providerRegistry = ProviderRegistry(payable(_pr)); owner = msg.sender;
    }

    function create(Option.Config calldata _c) external returns (address a) {
        require(providerRegistry.verifyFingerprint(_c.judgeAppId, _c.judgeVersion, _c.judgeFingerprint), "Bad fingerprint");
        a = address(new Option(address(providerRegistry), _c));
        allOptions.push(a);
        Option(payable(a)).startTrading();
        emit OptionCreated(a, msg.sender, _c.question, _c.judgeAppId, _c.judgeVersion);
    }

    function getOptionCount() external view returns (uint256) { return allOptions.length; }
    function getOptions(uint256 _o, uint256 _l) external view returns (address[] memory c, uint256 t) {
        t = allOptions.length; uint256 e = _o+_l>t?t:_o+_l; if(_o>=t) return (new address[](0),t);
        c = new address[](e-_o); for(uint256 i=_o;i<e;i++) c[i-_o]=allOptions[i];
    }
    function renounce() external onlyOwner { owner = address(0); }
}
