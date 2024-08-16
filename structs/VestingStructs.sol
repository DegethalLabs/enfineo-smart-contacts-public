// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


    struct VestingPeriodDefinition{
        uint256[] vestingPeriods;
        uint256[] vestingPeriodsPercentages; 
    }
    struct VestingTokensStruct{
        uint256 totalAmountOfTokens;
        uint256 currentAmount; 
    }
    
    struct VestingSchedule {
        address beneficiary;
        uint256 vestedAmount;
        uint256 releasedAmount;
        uint256 stakedAmount;
        string vestingName;
        bool isEnabled;
    }