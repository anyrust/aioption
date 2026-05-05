// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Option.sol";
import "./OrderBook.sol";
import "./ProviderRegistry.sol";

contract OptionFactory {
    error InvalidConfig();
    error FingerprintMismatch();
    error TransferFailed();
    error InsufficientDeployFee();

    event OptionCreated(address indexed optionAddr, address indexed orderBookAddr, address indexed creator, string question, string judgeAppId, uint256 judgeVersion);

    ProviderRegistry public immutable providerRegistry;
    address public owner;
    uint256 public deployFee;
    address[] public allOptions;
    mapping(address => address) public getOrderBook; // optionAddr → orderBookAddr

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor(address _providerRegistry, uint256 _deployFee) {
        require(_providerRegistry != address(0), "Zero registry");
        providerRegistry = ProviderRegistry(payable(_providerRegistry));
        owner = msg.sender;
        deployFee = _deployFee;
    }

    function createOption(Option.Config calldata _config)
        external payable returns (address optionAddr, address orderBookAddr)
    {
        if (msg.value < deployFee) revert InsufficientDeployFee();
        bool valid = providerRegistry.verifyFingerprint(_config.judgeAppId, _config.judgeVersion, _config.judgeFingerprint);
        if (!valid) revert FingerprintMismatch();

        optionAddr = address(new Option(address(providerRegistry), _config));
        allOptions.push(optionAddr);
        Option(payable(optionAddr)).startTrading();

        // Auto-deploy OrderBook
        orderBookAddr = address(new OrderBookContract(optionAddr, _config.options.length));
        getOrderBook[optionAddr] = orderBookAddr;

        if (msg.value > deployFee) {
            (bool ok,) = msg.sender.call{value: msg.value - deployFee}("");
            if (!ok) revert TransferFailed();
        }
        emit OptionCreated(optionAddr, orderBookAddr, msg.sender, _config.question, _config.judgeAppId, _config.judgeVersion);
    }

    function getOptionCount() external view returns (uint256) { return allOptions.length; }
    function getOptions(uint256 _offset, uint256 _limit) external view returns (address[] memory contracts, uint256 total) {
        total = allOptions.length;
        uint256 end = _offset + _limit; if (end > total) end = total;
        if (_offset >= total) return (new address[](0), total);
        contracts = new address[](end - _offset);
        for (uint256 i = _offset; i < end; i++) contracts[i - _offset] = allOptions[i];
    }
    function setDeployFee(uint256 _newFee) external onlyOwner { deployFee = _newFee; }
    function withdrawETH() external onlyOwner { (bool ok,) = owner.call{value: address(this).balance}(""); if (!ok) revert TransferFailed(); }
    function transferOwnership(address _newOwner) external onlyOwner { require(_newOwner != address(0), "Zero address"); owner = _newOwner; }
    function renounceOwnership() external onlyOwner { owner = address(0); }
}
