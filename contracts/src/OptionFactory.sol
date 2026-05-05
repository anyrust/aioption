// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Option.sol";
import "./ProviderRegistry.sol";

/**
 * @title OptionFactory
 * @notice Factory that deploys new Option contracts.
 *         Validates judge image fingerprints against ProviderRegistry.
 *         After renounceOwnership(), no one can stop it.
 */
contract OptionFactory {
    error InvalidConfig();
    error FingerprintMismatch();
    error TransferFailed();
    error InsufficientDeployFee();

    event OptionCreated(address indexed contractAddr, address indexed creator, string question, string judgeAppId, uint256 judgeVersion);
    event DeployFeeUpdated(uint256 oldFee, uint256 newFee);

    ProviderRegistry public immutable providerRegistry;
    address public owner;
    uint256 public deployFee;

    address[] public allOptions;
    mapping(address => address[]) public creatorOptions;

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor(address _providerRegistry, uint256 _deployFee) {
        require(_providerRegistry != address(0), "Zero registry");
        providerRegistry = ProviderRegistry(payable(_providerRegistry));
        owner = msg.sender;
        deployFee = _deployFee;
    }

    function createOption(Option.Config calldata _config)
        external payable returns (address contractAddr)
    {
        if (msg.value < deployFee) revert InsufficientDeployFee();

        bool valid = providerRegistry.verifyFingerprint(
            _config.judgeAppId, _config.judgeVersion, _config.judgeFingerprint
        );
        if (!valid) revert FingerprintMismatch();

        contractAddr = address(new Option(address(providerRegistry), _config));
        allOptions.push(contractAddr);
        creatorOptions[msg.sender].push(contractAddr);
        Option(payable(contractAddr)).startTrading();

        if (msg.value > deployFee) {
            (bool ok,) = msg.sender.call{value: msg.value - deployFee}("");
            if (!ok) revert TransferFailed();
        }

        emit OptionCreated(contractAddr, msg.sender, _config.question, _config.judgeAppId, _config.judgeVersion);
    }

    function getOptionCount() external view returns (uint256) { return allOptions.length; }

    function getOptions(uint256 _offset, uint256 _limit)
        external view returns (address[] memory contracts, uint256 total)
    {
        total = allOptions.length;
        uint256 end = _offset + _limit; if (end > total) end = total;
        if (_offset >= total) return (new address[](0), total);
        contracts = new address[](end - _offset);
        for (uint256 i = _offset; i < end; i++) contracts[i - _offset] = allOptions[i];
    }

    function getCreatorOptions(address _creator) external view returns (address[] memory) {
        return creatorOptions[_creator];
    }

    function setDeployFee(uint256 _newFee) external onlyOwner {
        emit DeployFeeUpdated(deployFee, _newFee); deployFee = _newFee;
    }

    function withdrawETH() external onlyOwner {
        (bool ok,) = owner.call{value: address(this).balance}(""); if (!ok) revert TransferFailed();
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address"); owner = _newOwner;
    }

    function renounceOwnership() external onlyOwner { owner = address(0); }
}
