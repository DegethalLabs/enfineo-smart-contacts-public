// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct Deposit {
    uint40 startTimestamp;
    uint40 lastProfitCalculationTimestamp;
    uint40 maturityTimestamp;
    uint40 coolOffTimestamp;
    address owner;
    uint256 amount;
    int256 profit;
    uint40 id;
    uint40 withrawState; // 1 means intent for only profit. 2 means intent for all amount
    uint16 tierNumber;
    DepositType depositType;
}

struct DepositType {
    uint40 duration;
    uint40 coolOffPeriod;
    uint256 minimumAmountToDeposit;
    address tokenAddress;
    string name;
}

struct DepositPool {
   uint256 amount;
   address tokenAddress;
   uint256 maxAllowedDeposits;
}

struct Tier {
    uint16 tierNumber;
    uint256 lowestNrOfEnfStaked;
    uint16 maxProfitPercentage;
    string name;
}

struct StakingDeposit {
    uint40 startTimestamp;
    uint40 maturityTimestamp;
    address owner;
    uint256 amount;
    uint256 reward;
    uint256 id;
    StakingDepositType depositType;
}

struct StakingDepositType {
    uint16 apr;
    uint16 penalty;
    uint40 duration;
    bool canUnstakePriorMaturation;
    uint256 minimumAmountToStake;
    string name;
}


