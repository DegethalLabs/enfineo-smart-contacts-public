// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./structs/VestingStructs.sol";

/**
 * @author Enfineo
 * @notice Contract with Vesting functionality over ENF token

 
 * @notice The vesting has multiple types:
 * @notice SEED - maxAmount: 8.325.000, 5% @ TGE + 4 x 1.25% @ 4 dates each end of the month over 4 months cliff period, then linear vesting for 12 months
 * @notice EARLY ADOPTERS - maxAmount: 16.500.000, 5% @TGE + 1 x 5% last days of 2 months cliff period , then linear vesting for 9 months
 * @notice PRIVATE SALE - maxAmount: 14.175.000, 5% @TGE + 1 x 5% last days of 2 months cliff period, then linear vesting for 12 months
 * @notice STRATEGIC - maxAmount: 4.000.000, 5% @TGE + 1 x 5% last days of 2 months cliff period, then linear vesting for 8 months
 * @notice PUBLIC SALE - maxAmount: 2.500.000, 25% at TGE, then linear for 8 months
 * @notice ECOSYSTEM - maxAmount: 24.000.000, 0% TGE, 4 % end of month 1, then linear vesting for 32 months
 * @notice LIQUIDITY - maxAmount: 12.000.000, 10% TGE, 1 x 10% at the end of the 12 months cliff period, then linear vesting for 17 months
 * @notice ADVISORS - maxAmount: 2.000.000, 0% TGE, 0% TGE, 11 months cliff, in month 12 10%, then linear vesting for 18 months
 * @notice TEAM - maxAmount: 10.500.000, 0% TGE, 12 months cliff, then linear vesting for 20 months
 * @notice MARKETING - maxAmount 6.000.000, 5% TGE, linear vesting 5% month 1, then linear vesting for 12 months
 
 */


/**
 * @dev Interface of the EnfineoStakingContract
 */
interface IEnfineoStakingContract {
    
    function stake(uint256 amount, uint256 depositTypeIndex, address beneficiary) external;
}


contract ENFVesting is AccessControl, ReentrancyGuard {
    address private _stakeContractAddress;
    IERC20 private _enfToken;
    bytes32 public constant CREATE_VESTING_SCHEDULE_ROLE = keccak256("CREATE_VESTING_SCHEDULE_ROLE");
    bytes32 public constant ENABLE_VESTING_SCHEDULE_ROLE = keccak256("ENABLE_VESTING_SCHEDULE_ROLE");
    
    uint constant SCALING_FACTOR = 100; 
    mapping(address => string[]) private _addressVestingCount;
    mapping(bytes32 => VestingSchedule) private _vestings;
    uint128 private _vestingContractStartingDate;
    uint128 private _vestingContractClaimAndStakeStartingDate;
    mapping(string => VestingPeriodDefinition) private _vestingDefinitions;
    mapping(string => VestingTokensStruct) private _vestingTokens;
     bytes32[] private _vestingKeys;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CREATE_VESTING_SCHEDULE_ROLE, msg.sender);
        _grantRole(ENABLE_VESTING_SCHEDULE_ROLE, msg.sender);

        /// @dev we define how much time an interval should last (in days)
         _vestingDefinitions["SEED"].vestingPeriods =  [0 days, 30 days, 1 seconds, 30 days, 1 seconds, 30 days, 1 seconds, 30 days, 1 seconds,12*30 days];

        /** @dev we define how much percentage an interval has alocated. value is equal to desired percentage * SCALING_FACTOR. 
         * E.g.: If SCALING_FACTOR = 100 and desired percentage is 5.65, the value inserted in the array should be 565
         */
        _vestingDefinitions["SEED"].vestingPeriodsPercentages =  [500, 0, 125, 0, 125, 0,  125, 0, 125, 9000];

        /// @dev we define total amount of token alocated to this vesting
        _vestingTokens["SEED"] = VestingTokensStruct(8325000 * 10 ** 18,0);


        _vestingDefinitions["EARLY_ADOPTERS"].vestingPeriods =  [0 days, 60 days, 1 seconds, 9*30 days];
        _vestingDefinitions["EARLY_ADOPTERS"].vestingPeriodsPercentages =  [500, 0, 500, 9000];
        _vestingTokens["EARLY_ADOPTERS"] = VestingTokensStruct(16500000 * 10 ** 18, 0);

        _vestingDefinitions["PRIVATE"].vestingPeriods =  [0 days, 60 days, 1 seconds, 12*30 days];
        _vestingDefinitions["PRIVATE"].vestingPeriodsPercentages =  [500, 0, 500, 9000];
        _vestingTokens["PRIVATE"] = VestingTokensStruct(14175000 * 10 ** 18, 0);

        _vestingDefinitions["STRATEGIC"].vestingPeriods =  [0 days, 60 days, 1 seconds, 8*30 days];
        _vestingDefinitions["STRATEGIC"].vestingPeriodsPercentages =  [500, 0, 500, 9000];
        _vestingTokens["STRATEGIC"] = VestingTokensStruct(4000000 * 10 ** 18, 0);

        _vestingDefinitions["PUBLIC_SALE"].vestingPeriods =  [0 days, 8*30 days];
        _vestingDefinitions["PUBLIC_SALE"].vestingPeriodsPercentages =  [2500, 7500];
        _vestingTokens["PUBLIC_SALE"] = VestingTokensStruct(2500000 * 10 ** 18, 0);

        //ECOSYSTEM - might need 1 month cliff after week 4. if not, leave it as it is
        _vestingDefinitions["ECOSYSTEM"].vestingPeriods =  [0 days, 30 days, 1 seconds, 32*30 days];
        _vestingDefinitions["ECOSYSTEM"].vestingPeriodsPercentages =  [0, 0, 400,9600];
        _vestingTokens["ECOSYSTEM"] = VestingTokensStruct(24000000 * 10 ** 18, 0);

         _vestingDefinitions["LIQUIDITY"].vestingPeriods =  [0 days, 12*30 days,1 seconds, 17*30 days];
        _vestingDefinitions["LIQUIDITY"].vestingPeriodsPercentages =  [1000, 0, 1000,8000];
        _vestingTokens["LIQUIDITY"] = VestingTokensStruct(12000000 * 10 ** 18, 0);

        _vestingDefinitions["ADVISORY"].vestingPeriods =  [0 days, 11*30 days, 30 days, 18*30 days];
        _vestingDefinitions["ADVISORY"].vestingPeriodsPercentages =  [0, 0, 1000,9000];
        _vestingTokens["ADVISORY"] = VestingTokensStruct(2000000 * 10 ** 18, 0);

        _vestingDefinitions["TEAM"].vestingPeriods =  [0 days, 12*30 days, 20*30 days];
        _vestingDefinitions["TEAM"].vestingPeriodsPercentages =  [0, 0, 10000];
        _vestingTokens["TEAM"] = VestingTokensStruct(10500000 * 10 ** 18, 0);

        _vestingDefinitions["MARKETING"].vestingPeriods =  [0 days, 1*30 days, 12*30 days];
        _vestingDefinitions["MARKETING"].vestingPeriodsPercentages =  [500, 500, 9000];
        _vestingTokens["MARKETING"] = VestingTokensStruct(6000000 * 10 ** 18, 0);
    }

    /**
     * @notice Create a vesting schedule for an address with one of the predefined types of vesting plans.
     * @notice this function is accesible only to addresses with special role: CREATE_VESTING_SCHEDULE_ROLE
     * @param beneficiary the address of the vesting schedule that can claim the tokens
     * @param vestingName name of the vesting
     * @param amount amount that is locked according to the vesting type
     */
    
    function createVestingSchedule(
        address beneficiary,
        string calldata vestingName,
        uint256 amount
    ) private {
        
        if (beneficiary == address(0)) {
            revert InvalidBeneficiary();
        }
        /// @dev check if vesting type exists
        if (_vestingTokens[vestingName].totalAmountOfTokens == 0) {
            revert InvalidVestingIndexPlan();
        }
        /// @dev check if vesting type can accept more funds
        if (
            amount + _vestingTokens[vestingName].currentAmount >
            _vestingTokens[vestingName].totalAmountOfTokens
        ) {
            revert InvalidAmountForVestingPlan();
        }

        _vestingTokens[vestingName].currentAmount += amount;

        bytes32 id = computeVestingIdForAddressAndVestingName(beneficiary, vestingName);

        _vestings[id] = VestingSchedule(beneficiary, amount, 0, 0, vestingName, false);
        _vestingKeys.push(id);

        _addressVestingCount[beneficiary].push(vestingName);

        emit CreateVestingSchedule(beneficiary, vestingName, amount, _addressVestingCount[beneficiary].length);
    }

    /**
     * @notice Create a vesting schedules for an array of addresses with predefined types of vesting plans.
     * @notice this function is accesible only to addresses with special role: CREATE_VESTING_SCHEDULE_ROLE
     * @param beneficiaries array of addresses of the vesting schedule that can claim the tokens
     * @param vestingNames arary of vesting names
     * @param amounts array of amounts (amount in Gwei-already multiplied by 10**18) that are locked according to the vesting type
     */
      function createVestingSchedules(
        address[] calldata beneficiaries,
        string[] calldata vestingNames,
        uint256[] memory amounts
    ) external  onlyRole(CREATE_VESTING_SCHEDULE_ROLE) {
        uint256 i;
        if (beneficiaries.length != vestingNames.length || beneficiaries.length != amounts.length) {
            revert WrongParam();
        }
        for (i; i < beneficiaries.length; ++i) {
            createVestingSchedule(beneficiaries[i], vestingNames[i], amounts[i]);
        }
    }

    /**
     * @notice Claim released tokens. Can be called only by the beneficiary of the vesting schedule
     * @param vestingScheduleId represents the computed id of a vesting schedule. It is computed from beneficiary address and vesting name
     */
     
     function claimTokens(bytes32 vestingScheduleId) external  nonReentrant{
        if(address(_enfToken) == address(0) ){
            revert InvalidTokenAddress();
        }
        VestingSchedule storage vest = _vestings[vestingScheduleId];
        if (msg.sender != vest.beneficiary) {
            revert ClaimCanBeExecutedOnlyByOwnerOfTokens();
        }
        
        /// @dev check if selected vesting exists
        if (vest.vestedAmount == 0) {
            revert InvalidVestingScheduleId();
        }
        /// @dev if the wallet address doesn't have KYC, we won't allow the claim
        if(!vest.isEnabled){
            revert VestingIsNotEnabled();
        }

        uint256 releaseToSend = getReleaseAmount(vestingScheduleId);

        vest.releasedAmount += releaseToSend;

        if (vest.releasedAmount > vest.vestedAmount) {
            releaseToSend = vest.vestedAmount - (vest.releasedAmount - releaseToSend);
            vest.releasedAmount = vest.vestedAmount;
            emit ClaimTokensIssue(vest.beneficiary, releaseToSend);
        }
        if(releaseToSend > 0){
            bool success = _enfToken.transfer(vest.beneficiary, releaseToSend);
            if (!success) {
                emit TransferFailedEvent(address(this),vest.beneficiary, releaseToSend);
                revert TransferFailed();
            }
            emit Claim(vest.beneficiary, releaseToSend, vest.vestingName);
        } else {
            emit ClaimTokensIssue(vest.beneficiary, releaseToSend);
        }
        
    }
    /**
     * @notice Claim released tokens and send them to the stake contract. Can be called only by the beneficiary of the vesting schedule
     * @param vestingScheduleId represents the computed id of a vesting schedule. It is computed from beneficiary address and vesting name
     */
     
     function claimAndStakeTokens(bytes32 vestingScheduleId) external  nonReentrant{
        if(_stakeContractAddress == address(0)){
            revert InvalidStakeContract();
        }
        VestingSchedule storage vest = _vestings[vestingScheduleId];
        if (msg.sender != vest.beneficiary) {
            revert ClaimCanBeExecutedOnlyByOwnerOfTokens();
        }

        /// @dev check if selected vesting exists
        if (vest.vestedAmount == 0) {
            revert InvalidVestingScheduleId();
        }

        if(!vest.isEnabled){
            revert VestingIsNotEnabled();
        }
        
        uint256 currentTime = block.timestamp;
        uint256 stakeTypeId = 999;
        /// @dev claim and stake is allowed only between staking start time and vesting start time + 30 days
        if(currentTime < _vestingContractClaimAndStakeStartingDate || currentTime >= _vestingContractStartingDate + 30 days){
            revert StakeFailed(); 
        }
        /// @dev if the method is claimed before we start the vesting contract, but after we start the claimand stake period, we send the tokens to pool 1
        if(currentTime >= _vestingContractClaimAndStakeStartingDate && currentTime < _vestingContractStartingDate){
            stakeTypeId = 0;
        }
        /// @dev if the method is called after the vesting contract start date, we send the tokens to pool 2
        if(currentTime >= _vestingContractStartingDate && currentTime < _vestingContractStartingDate + 30 days){
            stakeTypeId = 1;
        }
       uint256 tgeAmount = calculateTgeAmount(vestingScheduleId);
        if(vest.stakedAmount == 0 
        && vest.releasedAmount == 0 
        && (stakeTypeId == 0 || stakeTypeId == 1)){

            vest.stakedAmount += tgeAmount;
            vest.releasedAmount += tgeAmount;

            bool success = _enfToken.transfer(_stakeContractAddress, tgeAmount);
            if (!success) {
                emit TransferFailedEvent(address(this), _stakeContractAddress, tgeAmount);
                revert TransferFailed();
            }

            IEnfineoStakingContract externalContract = IEnfineoStakingContract(_stakeContractAddress);

            try externalContract.stake(tgeAmount, stakeTypeId, vest.beneficiary) {
                emit ClaimAndStake(vest.beneficiary, tgeAmount, vest.vestingName);
            } catch Error(string memory reason) {
                vest.stakedAmount = vest.stakedAmount - tgeAmount;
                emit ClaimAndStakeIssue(vest.beneficiary, tgeAmount, reason);
                revert (reason);
            } catch (bytes memory lowLevelData) {
                vest.stakedAmount = vest.stakedAmount - tgeAmount;
                emit ClaimAndStakeIssue(vest.beneficiary, tgeAmount, "Unknown issue");
                revert(string(abi.encodePacked("Staking failed with unknown error:" , string(lowLevelData))));
                
            }
           
        } else {
            emit ClaimAndStakeIssue(vest.beneficiary, tgeAmount,"Conditions not met");
        }
        
    }

    /**
     * @notice View function for calculating releasable tokens
     * @param vestingScheduleId represents the computed id of a vesting schedule. It is computed from beneficiary address and vesting name
     * @return vestedAmount current amount that can be claimed by beneficiary.
     */function getReleaseAmount(bytes32 vestingScheduleId) public view returns (uint256) {
        if (_vestingContractStartingDate == 0) {
            return 0;
        }
        uint256 currentTime = block.timestamp;
         if (currentTime < _vestingContractStartingDate) {
            return 0;
        }
        VestingSchedule storage vestingSchedule = _vestings[vestingScheduleId];
        if (vestingSchedule.vestedAmount == 0) {
            revert InvalidVestingScheduleId();
        }
        /// @dev temp variable used to calculate vested ammount
        uint256 tempTime = _vestingContractStartingDate;
        
        VestingPeriodDefinition storage vestingDefinitions = _vestingDefinitions[vestingSchedule.vestingName];
        
        uint256 tgeAmount;
      
        uint256 vestedAmount;

         for (uint i; i < vestingDefinitions.vestingPeriods.length; ++i) {
           if(i==0 && vestingDefinitions.vestingPeriods[i] == 0){
                tgeAmount = (vestingSchedule.vestedAmount * vestingDefinitions.vestingPeriodsPercentages[i])/(100 * SCALING_FACTOR);
           } else{
            //if current time means that the interval time has passed, we add the total tokens alocated to that interval
                if(tempTime + vestingDefinitions.vestingPeriods[i] <= currentTime){
                    vestedAmount += (vestingSchedule.vestedAmount * vestingDefinitions.vestingPeriodsPercentages[i])/(100 * SCALING_FACTOR);
                    tempTime += vestingDefinitions.vestingPeriods[i];
                }else {
                     //if current time means that we are inside the interval, we add only the coresponding ammount
                     uint256 payedTime =currentTime - tempTime;
                     vestedAmount += ((vestingSchedule.vestedAmount * payedTime * vestingDefinitions.vestingPeriodsPercentages[i])/vestingDefinitions.vestingPeriods[i])/(100 * SCALING_FACTOR);
                     break;
                }
           }
         }

        vestedAmount = vestedAmount + tgeAmount - vestingSchedule.releasedAmount;
        return vestedAmount;
    }

    

        /**
    * @notice Returns the TGE amount for a specific vesting schedule
    * @param vestingScheduleId the vesting schedule id
    * @return TGE amount
    */
    function calculateTgeAmount(bytes32 vestingScheduleId) public view returns (uint256) {
        VestingSchedule storage vestingSchedule = _vestings[vestingScheduleId];
        VestingPeriodDefinition storage vestingDefinitions = _vestingDefinitions[vestingSchedule.vestingName];
        uint256 tgeAmount = (vestingSchedule.vestedAmount * vestingDefinitions.vestingPeriodsPercentages[0])/(100 * SCALING_FACTOR);
        return tgeAmount;
    }
     
    /**
     * @notice Sets the start time of the claim and stake .
     * @param newVestingContractClaimAndStakeStartingDate starting time of the claim and stake, in unix timestamp
     */
    function setVestingContractClaimAndStakeStartingDate(uint128 newVestingContractClaimAndStakeStartingDate)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_vestingContractClaimAndStakeStartingDate != 0) {
            revert ClaimAndStakeDateWasSetted();
        }
        _vestingContractClaimAndStakeStartingDate = newVestingContractClaimAndStakeStartingDate;
        emit SetClaimAndStakeDate(newVestingContractClaimAndStakeStartingDate);
    }
    /**
     * @notice View contract claim and stake start time
     * @return contract claim and stake start time in unix timestamp
     */
    function getVestingContractClaimAndStakeStartingDate() external view returns (uint128) {
        return _vestingContractClaimAndStakeStartingDate;
    }

    /**
     * @notice Sets the start time of the vesting contract.
     * @param newVestingContractStartingDate starting time of the vesting, in unix timestamp
     */
    function setVestingContractStartingDate(uint128 newVestingContractStartingDate)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_vestingContractStartingDate != 0) {
            revert VestingDateWasSetted();
        }
        _vestingContractStartingDate = newVestingContractStartingDate;
        emit SetVestingDate(newVestingContractStartingDate);
    }
    /**
     * @notice View contract start time
     * @return contract start time in unix timestamp
     */
    function getVestingContractStartingDate() external view returns (uint128) {
        return _vestingContractStartingDate;
    }

    function computeVestingIdForAddressAndVestingName(address to, string memory vestingName) public pure returns (bytes32) {
        return keccak256(abi.encode(to, vestingName));
    }

    /**
     * @notice View function to get all vesting schedule ids for an address
     * @param beneficiary the address for which it is searched
     * @return ids array with ids. The lenght is given by _addressVestingCount[_beneficiary]
     */
    function getAddressVestingSchedulesIds(address beneficiary) public view returns (bytes32[] memory) {
        string[] memory accountVestings = _addressVestingCount[beneficiary];
        uint256 count = accountVestings.length;
        bytes32[] memory ids = new bytes32[](count);
        uint256 i;
        for (i; i < count; ++i) {
            ids[i] = computeVestingIdForAddressAndVestingName(beneficiary, accountVestings[i]);
        }
        return ids;
    }

    /**
    * @notice Returns the vesting definition
    * @param vestingId the name of the vesting definition
    * @return vesting definition
    */
    function getVestingById(bytes32 vestingId) external view returns (VestingSchedule memory) {
        return _vestings[vestingId];
    }
/*
    function vestingDetails(uint256 index) external view returns (VestingDetails memory) {
        return _vestingDetails[index];
    }
*/
    function getAddressVestingsCount(address beneficiary) external view returns (uint256) {
        return _addressVestingCount[beneficiary].length;
    }

    function getEnfTokenAddress() external view returns (IERC20) {
        return _enfToken;
    }

     function getStakingContractAddress() external view returns (address) {
        return _stakeContractAddress;
    }
    /**
     * @notice Sets the token address
     * @param tokenAddress token address
     */
    function setEnfToken(IERC20 tokenAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _enfToken = tokenAddress;
        emit SetEnfToken(tokenAddress);
    }

    /**
     * @notice Sets the stake contract address
     * @param stakeAddress stake contract address
     */
    function setStakeContractAddress(address stakeAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _stakeContractAddress = stakeAddress;
        emit SetStakeContractAddress(stakeAddress);
    }

    
    function getVestingPeriodsDetailsByVestingId(bytes32 vestingScheduleId) external view returns (uint256[] memory) {
        VestingSchedule memory vestingSchedule = _vestings[vestingScheduleId];
        
        return _vestingDefinitions[vestingSchedule.vestingName].vestingPeriods;
    }

    function getEndOfVestingByVestingId(bytes32 vestingScheduleId) external view returns (uint256) {
        VestingSchedule memory vestingSchedule = _vestings[vestingScheduleId];
        VestingPeriodDefinition memory vestingDefinitions = _vestingDefinitions[vestingSchedule.vestingName];
        uint256 endOfVestingValue = _vestingContractStartingDate;
        for (uint i; i < vestingDefinitions.vestingPeriods.length; ++i) 
        {
            endOfVestingValue += vestingDefinitions.vestingPeriods[i];
        }

        return endOfVestingValue;
    }

    /**
     * @notice Updates the isEnabled status of a vesting schedule. isEnable controls if the vesting can be claimed or not.
     * @param vestingScheduleIds the index of the vesting schedule
     * @param status true/false the status we want to update to
     */
    function setVestingScheduleEnableStatus(
        bytes32[] calldata vestingScheduleIds,
        bool[] calldata status
    ) external onlyRole(ENABLE_VESTING_SCHEDULE_ROLE) {
        uint256 i;
        for (i; i < vestingScheduleIds.length; ++i) {
            VestingSchedule storage vest = _vestings[vestingScheduleIds[i]];
      
            /// @dev check if selected vesting exists
            if (vest.vestedAmount == 0) {
                revert InvalidVestingScheduleId();
            }
            vest.isEnabled = status[i];
        }
        
    }


    event CreateVestingSchedule(
        address indexed beneficiary,
        string vestingName,
        uint256 amount,
        uint256 currentNumberOfVestedSchedules
    );
    event Claim(address indexed account, uint256 amount, string vestingName);
    event ClaimTokensIssue(address indexed account, uint256 amount);
    event ClaimAndStake(address indexed account, uint256 amount, string vestingName);
    event ClaimAndStakeIssue(address indexed account, uint256 amount, string issue);
    event SetEnfToken(IERC20 newAddress);
    event SetStakeContractAddress(address newAddress);
    event SetVestingDate(uint128 newVestingDate);
    event SetClaimAndStakeDate(uint128 newVestingDate);
    event StakeContractAccess(uint256 amount);
    event TransferFailedEvent(address fromAddress, address toAddress, uint256 amount);

    error InvalidBeneficiary();
    error InvalidVestingIndexPlan();
    error InvalidAmountForVestingPlan();
    error InvalidVestingScheduleId();
    error ClaimCanBeExecutedOnlyByOwnerOfTokens();
    error TransferFailed();
    error StakeFailed();
    error InvalidReleasedAmount();
    error WrongParam();
    error VestingDateWasSetted();
    error ClaimAndStakeDateWasSetted();
    error InvalidStakeContract();
    error InvalidTokenAddress();
    error InvalidDepositType();
    error VestingIsNotEnabled();
}