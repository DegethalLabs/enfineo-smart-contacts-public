// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IENF is IERC20 {
    function burn(address _account, uint256 _amount) external;

    function balanceOf(address owner) external view returns (uint256);
}
