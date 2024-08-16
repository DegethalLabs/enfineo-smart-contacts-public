// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IENFVesting {
    function canStakeDepositType(bytes32 vestingScheduleId, uint256 depositTypeIndex, uint256 amount) external view returns (bool);
}
