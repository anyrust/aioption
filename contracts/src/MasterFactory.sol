// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MasterFactory v2 — Permanent single entry point for AI Option ecosystem.
 *
 *   Deploy ONCE. Never redeploy.
 *
 *   registerFactory(version, addr)   → add option/stock/multi factories
 *   registerRegistry(version, addr)  → add provider registries
 *   getAllOptions()                  → iterate ALL options from ALL factories
 *   getAllFactories()                → list all registered sub-factories
 *
 *   anyone can register. renounce() makes it immutable forever.
 */
contract MasterFactory {
    struct Info {
        string  version;
        address addr;
        uint256 registeredAt;
    }

    address public owner;

    mapping(uint256 => Info) public factories;
    uint256 public factoryCount;

    mapping(uint256 => Info) public registries;
    uint256 public registryCount;

    constructor() { owner = msg.sender; }

    function registerFactory(string calldata _v, address _a) external {
        factories[factoryCount++] = Info(_v, _a, block.timestamp);
    }

    function registerRegistry(string calldata _v, address _a) external {
        registries[registryCount++] = Info(_v, _a, block.timestamp);
    }

    /**
     * @notice Returns ALL options from ALL registered factories.
     *         Single call — no pagination needed for small sets.
     */
    function getAllOptions() external view returns (
        address[] memory optionAddrs,
        string[]  memory versions,
        address[] memory factoryAddrs
    ) {
        uint256 total;
        for (uint256 i = 0; i < factoryCount; i++) {
            (bool ok, bytes memory d) = factories[i].addr.staticcall(
                abi.encodeWithSignature("getOptionCount()")
            );
            if (ok) total += abi.decode(d, (uint256));
        }

        optionAddrs = new address[](total);
        versions = new string[](total);
        factoryAddrs = new address[](total);
        uint256 idx;

        for (uint256 i = 0; i < factoryCount; i++) {
            address f = factories[i].addr;
            string memory v = factories[i].version;
            (bool ok, bytes memory d) = f.staticcall(
                abi.encodeWithSignature("getOptionCount()")
            );
            if (!ok) continue;
            uint256 count = abi.decode(d, (uint256));
            for (uint256 j = 0; j < count && idx < total; j++) {
                (bool ok2, bytes memory d2) = f.staticcall(
                    abi.encodeWithSignature("getOptions(uint256,uint256)", j, 1)
                );
                if (!ok2) continue;
                (address[] memory addrs,) = abi.decode(d2, (address[], uint256));
                if (addrs.length > 0) {
                    optionAddrs[idx] = addrs[0];
                    versions[idx] = v;
                    factoryAddrs[idx] = f;
                    idx++;
                }
            }
        }
    }

    function renounce() external { require(msg.sender == owner); owner = address(0); }
}
