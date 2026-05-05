// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MasterFactory — Single entry point for the entire AI Option ecosystem.
 *
 *   register(version, factory) → anyone adds a new OptionFactory version
 *   getAllOptions()            → returns ALL options from ALL registered factories
 *   getFactoryCount()          → how many factories registered
 *
 *   No owner. Anyone can register. Immutable after renounce().
 */
contract MasterFactory {
    struct FactoryInfo {
        string  version;
        address factory;
        uint256 registeredAt;
    }

    address public owner;
    mapping(uint256 => FactoryInfo) public factories;
    uint256 public factoryCount;

    constructor() { owner = msg.sender; }

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    function register(string calldata _version, address _factory) external {
        factories[factoryCount] = FactoryInfo(_version, _factory, block.timestamp);
        factoryCount++;
    }

    function getAllOptions() external view returns (
        address[] memory optionAddrs,
        string[]  memory versions,
        address[] memory factoryAddrs
    ) {
        // First pass: count total
        uint256 total;
        for (uint256 i = 0; i < factoryCount; i++) {
            (bool ok, bytes memory data) = factories[i].factory.staticcall(
                abi.encodeWithSignature("getOptionCount()")
            );
            if (ok) total += abi.decode(data, (uint256));
        }

        optionAddrs = new address[](total);
        versions    = new string[](total);
        factoryAddrs = new address[](total);

        uint256 idx;
        for (uint256 i = 0; i < factoryCount; i++) {
            address f = factories[i].factory;
            string memory v = factories[i].version;
            (bool ok, bytes memory data) = f.staticcall(
                abi.encodeWithSignature("getOptionCount()")
            );
            if (!ok) continue;
            uint256 count = abi.decode(data, (uint256));
            for (uint256 j = 0; j < count && idx < total; j++) {
                (bool ok2, bytes memory data2) = f.staticcall(
                    abi.encodeWithSignature("getOptions(uint256,uint256)", j, 1)
                );
                if (ok2) {
                    address[] memory addrs = abi.decode(data2, (address[]));
                    if (addrs.length > 0) {
                        optionAddrs[idx] = addrs[0];
                        versions[idx] = v;
                        factoryAddrs[idx] = f;
                        idx++;
                    }
                }
            }
        }
    }

    function renounce() external onlyOwner { owner = address(0); }
}
