// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct Deposit {
    uint40 startTimestamp;
    uint40 maturityTimestamp;
    address owner;
    uint256 amount;
    uint256 reward;
    uint256 id;
    DepositType depositType;
}



struct DepositType {
    uint16 apr;
    uint16 penalty;
    uint40 duration;
    bool canUnstakePriorMaturation;
    uint256 minimumAmountToStake;
    string name;
}

