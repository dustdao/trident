// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.0;

/// @notice Trident pool deployer for whitelisted template factories.
/// @author Mudit Gupta.
contract PoolDeployer {
    address public immutable masterDeployer;

    mapping(address => mapping(address => address[])) public pools;
    mapping(bytes32 => address) public configAddress;

    constructor(address _masterDeployer) {
        require(_masterDeployer != address(0), "ZERO_ADDRESS");
        masterDeployer = _masterDeployer;
    }

    function _registerPool(
        address pool,
        address[] memory tokens,
        bytes32 salt
    ) internal {
        require(configAddress[salt] == address(0), "POOL_ALREADY_DEPLOYED");
        // @dev Store the address of the deployed contract.
        configAddress[salt] = pool;
        // @dev Attacker used underflow, it was not very effective. poolimon!
        // null token array would cause deployment to fail via out of bounds memory axis/gas limit.
        unchecked {
            for (uint256 i; i < tokens.length - 1; i++) {
                require(tokens[i] < tokens[i + 1], "INVALID_TOKEN_ORDER");
                for (uint256 j = i + 1; j < tokens.length; j++) {
                    pools[tokens[i]][tokens[j]].push(pool);
                }
            }
        }
    }

    function poolsCount(address token0, address token1) external view returns (uint256 count) {
        count = pools[token0][token1].length;
    }

    function getPools(
        address token0,
        address token1,
        uint256 startIndex,
        uint256 endIndex
    ) external view returns (address[] memory pairPools) {
        pairPools = new address[](endIndex - startIndex);
        for (uint256 i = 0; startIndex < endIndex; i++) {
            pairPools[i] = pools[token0][token1][startIndex];
            startIndex++;
        }
    }
}
