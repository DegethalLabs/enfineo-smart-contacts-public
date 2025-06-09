// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";


import "./interfaces/IENF.sol";
import "./structs/ManagedAccountsStructs.sol";

interface IEnfineoStakingContract {
    function getDepositsByOwner(address owner, uint256 startIndex, uint256 length) external returns (StakingDeposit[] memory);
    function getDepositsNumberPerOwner(address owner) external returns (uint256);
}


/**
 * @author LA Network Inc.
 * @notice Contract with Managed Accounts functionality
 */
contract ENFManagedAccounts is ReentrancyGuard, AccessControl, Pausable {
    address private _stakeContractAddress;
    bytes32 public constant OPERATIONAL_ROLE = keccak256("OPERATIONAL_ROLE");
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    uint40 private _latestProftDistributionTimestamp;
    address private _treasuryAccount;

    DepositPool[] private _depositsPool;

    Tier[] private _tiers;

    /// @dev the types of deposits
    DepositType[] private _depositTypes;

    mapping(address => mapping(uint256 => Deposit)) private _depositsByOwner;
    mapping(address => uint40) private _depositsNumberPerOwner;
    
    // Array to store all wallet addresses with active deposits
    address[] private _depositOwners;

    // Mapping to track if an address has any active deposits and its index in the array
    mapping(address => bool) private _hasDeposit;
    mapping(address => uint256) private _ownerIndex;
    mapping(address => uint16) private _activeDepositCount;
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATIONAL_ROLE, msg.sender);
        _grantRole(TRANSFER_ROLE, msg.sender);
        _pause();
    }
   
    /**
     * @notice Deposits an amount of a deposit type token in order to take part to the managed account
     * @param amount the amount of deposit token to deposit, it has to be greater than minimumAmountToDeposit of the depositType
     * @param depositTypeIndex index of the deposit type
     */
    function deposit(
        uint256 amount,
        uint256 depositTypeIndex
    ) external whenNotPaused {

        if(depositTypeIndex >= _depositTypes.length){
            emit DepositError("Deposit not allowed");
            revert InvalidDeposit();
        }      

        DepositType memory selectedDepositType = _depositTypes[depositTypeIndex];

         if (selectedDepositType.duration == 0) {
            emit DepositError("Deposit type invalid");
            revert InvalidDeposit();
        }

        if (amount < selectedDepositType.minimumAmountToDeposit) {
            emit DepositError("Invalid deposit amount");
            revert InvalidAmount();
        }

        if (block.timestamp + selectedDepositType.duration > type(uint40).max 
        || uint40(block.timestamp) + selectedDepositType.duration + selectedDepositType.coolOffPeriod > type(uint40).max) {
            emit DepositError("Invalid block state");
            revert InvalidState();
        }

        uint40 depositsNumberPerOwnerLocal = _depositsNumberPerOwner[msg.sender];

       uint16 walletTier = calculateWalletTier(msg.sender);

        if(walletTier == 0){
            revert InvalidWalletStakes();
        }

        Deposit memory newDeposit = Deposit({
            id: depositsNumberPerOwnerLocal,
            startTimestamp: uint40(block.timestamp),
            lastProfitCalculationTimestamp: uint40(block.timestamp),
            maturityTimestamp: uint40(block.timestamp) + selectedDepositType.duration,
            coolOffTimestamp: uint40(block.timestamp) + selectedDepositType.duration + selectedDepositType.coolOffPeriod,
            owner: msg.sender,
            profit: 0,
            amount: amount,
            withrawState:0,
            tierNumber: walletTier,
            depositType: selectedDepositType
        });

        _depositsByOwner[msg.sender][depositsNumberPerOwnerLocal++] = newDeposit;

        _depositsNumberPerOwner[msg.sender] = depositsNumberPerOwnerLocal;

        registerDepositOwner(msg.sender);

        IERC20 tokenToTransfer = IERC20(selectedDepositType.tokenAddress);

        if(tokenToTransfer.allowance(msg.sender, address(this)) < amount){
            revert DepositFundsTransferError();
        }
        
        bool transferStatus = tokenToTransfer.transferFrom(msg.sender, address(this), amount);
        if(!transferStatus){
            emit TransferFailedEvent(msg.sender, address(this), amount, selectedDepositType.tokenAddress);
            revert DepositFundsTransferError();
        }
        
        emit DepositEvent(
            msg.sender,
            amount,
            uint40(block.timestamp),
            uint40(block.timestamp) + selectedDepositType.duration,
            uint40(block.timestamp) + selectedDepositType.coolOffPeriod,
            selectedDepositType.duration,
            depositTypeIndex,
            selectedDepositType.tokenAddress
        );
    }

    /**
     * @notice withdraw a deposit by its id. Some deposits can't be withdrawn prior maturity and untill cool off period passes
     * @param depositId id of the deposit
     * @param onlyProfit tru if you want to withdraw only the profit, false if you withdraw amount+profit
     * @param isIntent true if this is a withdraw intent that starts the cool off period with not actual funds transfer
    */
    function withdraw(uint256 depositId, bool onlyProfit, bool isIntent) public whenNotPaused {

        Deposit storage currentDeposit = _depositsByOwner[msg.sender][depositId];

        if (currentDeposit.owner == address(0)) {
            revert InvalidDeposit();
        }
        /// @dev withdraw state 1 or 2 means that an intent started, 0 means no intent. You wannot withdraw without sending previously sending an intent
         if (!isIntent && currentDeposit.withrawState == 0) {
            revert CannotWithdrawWithoutIntent();
        }
        /// @dev withdraw state 1 or 2 means that an intent started, 0 means no intent. You wannot send intent for a withdraw that was already marked as intent started
         if (isIntent && currentDeposit.withrawState > 0) {
            revert WithdrawAlreadyStarted();
        }

        /// @dev for withdraw intent we just start the cool off and emit an event
        if(isIntent) {
            if (currentDeposit.maturityTimestamp <= uint40(block.timestamp) ) {
                currentDeposit.coolOffTimestamp = uint40(block.timestamp) + currentDeposit.depositType.coolOffPeriod;   
                
                if(onlyProfit){
                    currentDeposit.withrawState = 1;
                    emit WithdrawIntent(msg.sender, currentDeposit.depositType.tokenAddress, depositId, currentDeposit.amount, currentDeposit.profit, false);
                } else {
                    currentDeposit.withrawState = 2;
                    emit WithdrawIntent(msg.sender, currentDeposit.depositType.tokenAddress, depositId, currentDeposit.amount, currentDeposit.profit, true);
                }

            
            }
        } else {
            /// @notice check if the deposit is mature, cool off has passed and can be collected,
            if (currentDeposit.maturityTimestamp <= block.timestamp && currentDeposit.coolOffTimestamp <= block.timestamp) {
                IERC20 tokenToTransfer = IERC20(currentDeposit.depositType.tokenAddress);
                if(onlyProfit){
                    if(currentDeposit.profit > 0){
                        
                        bool result = tokenToTransfer.transfer(currentDeposit.owner, uint256(currentDeposit.profit));
                        if (!result){
                            emit TransferFailedEvent(address(this), currentDeposit.owner, uint256(currentDeposit.profit), currentDeposit.depositType.tokenAddress);
                            revert DepositFundsTransferError();
                        }
                        currentDeposit.withrawState = 0;
                        currentDeposit.profit = 0;
                        emit WithdrawOnMaturity(msg.sender, currentDeposit.depositType.tokenAddress, depositId, currentDeposit.amount, currentDeposit.profit, false);
                    }
                } else {
                    if(currentDeposit.withrawState == 2){
                        removeDepositOwner(msg.sender);
                        
                        uint256 amountToTransfer  = addProfitToAmount(currentDeposit.amount , currentDeposit.profit);

                        bool result = tokenToTransfer.transfer(currentDeposit.owner, amountToTransfer);
                        if (!result){
                            emit TransferFailedEvent(address(this), currentDeposit.owner, amountToTransfer, currentDeposit.depositType.tokenAddress);
                            revert DepositFundsTransferError();
                        }

                        emit WithdrawOnMaturity(msg.sender, currentDeposit.depositType.tokenAddress, depositId, currentDeposit.amount, currentDeposit.profit, true);
                        delete _depositsByOwner[msg.sender][depositId];
                    }
                }
            } else {
                revert CannotWithdrawThisTypeOfDeposit();
            }
        }
    }

   /**
     * @notice Method called by the contact operational role in order to distribute profits to owners.
     * @notice this function is accessible only to addresses with special role: OPERATIONAL_ROLE
     * @notice for loop it's safe here because the length of the arrays will not be higher than 50
     * @param owners array of addresses of the owners of active deposits. 
     * @param depositIds arary of depositIds
     * @param profits array of amounts (amount in Gwei-already multiplied by 10**18) that will add to the current profit of the deposit
     */

    function distributeProfit(
        address[] calldata owners,
        uint256[] calldata depositIds,
        int256[] memory profits
    ) external onlyRole(OPERATIONAL_ROLE) {

        uint256 i = 0;
        if (owners.length != depositIds.length || depositIds.length != profits.length) {
            revert WrongParam();
        }
        
        for (i; i < owners.length; ++i) {
            Deposit storage currentDeposit = _depositsByOwner[owners[i]][depositIds[i]];
            ///@dev if a withdraw intent was executed on this deposit, for entire amount, we can no longer distribute profits to it.
            if(currentDeposit.withrawState < 2){
                currentDeposit.profit += profits[i];
                /// @dev beside profit, we also reset the deposit state and lastProfitCalculationTimestamp
                currentDeposit.withrawState = 0;
                currentDeposit.lastProfitCalculationTimestamp = uint40(block.timestamp);
            }
        }
        _latestProftDistributionTimestamp = uint40(block.timestamp);
    }
     
     /**
     * @notice Uset to calculate the tier for which this wallet will qualify when doing a deposit
     * @notice for loop it's safe here because the length of the arrays will not be higher than 100
     * @param walletAddress address of the deposit owner
     */
    
    function calculateWalletTier(address walletAddress) private returns (uint16){

        IEnfineoStakingContract externalContract = IEnfineoStakingContract(_stakeContractAddress);

        uint256 totalDeposits;
         try externalContract.getDepositsNumberPerOwner(walletAddress) returns (uint256 _totalDeposits) {
            totalDeposits = _totalDeposits;
        } catch {
            revert("Failed to retrieve total staking for the owner");
        }

        uint256 startIndex = 0;
        uint256 pageSize = 100; 
        uint256 totalProcessed = 0;
        uint256 depositsWeight = 0;
        
        while (totalProcessed < totalDeposits) {
            uint256 length = pageSize;
            if (totalProcessed + pageSize > totalDeposits) {
                length = totalDeposits - totalProcessed;
            }

             StakingDeposit[] memory paginatedDeposits;
            try externalContract.getDepositsByOwner(walletAddress, startIndex, length) returns (StakingDeposit[] memory _paginatedDeposits) {
                paginatedDeposits = _paginatedDeposits;
            } catch {
                revert("Failed to retrieve deposits for the owner from the staking contract");
            }
            /// @dev we calculate a weight of all deposits this address has. The more ENF staked the higher the weight. The bigger the period, the higher the weight.
            for (uint256 i = 0; i < paginatedDeposits.length; i++) {
                depositsWeight += (paginatedDeposits[i].amount * (daysLeft(paginatedDeposits[i].maturityTimestamp)+1))/365;
            }

            totalProcessed += length;
            startIndex += length;
        }
        
        ///@dev each tier has a lowestNrOfEnfStaked representing the minimum enf per day you have staked so you can qualify for this tier.
        /// the formula is: (WALLET_ENF_AMOUNT_STAKED * DAYS_BETWEEN_NOW_AND_MATURITY) / 365. 
        uint16 walletTier;
        for (uint256 i = 1; i < _tiers.length; i++) {
                if (_tiers[i].lowestNrOfEnfStaked <= depositsWeight){
                    walletTier = _tiers[i].tierNumber;
                }
        }
            
        return walletTier;
    }

     function addProfitToAmount(uint256 amount, int256 profit) private pure returns (uint256) {
        int256 signedAmount = int256(amount);
        int256 result = signedAmount + profit;
        return uint256(result);
    }

    /**
     * @notice Used to update the owners list after a deposit
     * @param owner address of the deposit owner
     */
    function registerDepositOwner(address owner) internal {
        // If this is the first deposit for this owner, add to _depositOwners
        if (!_hasDeposit[owner]) {
            _ownerIndex[owner] = _depositOwners.length;
            _depositOwners.push(owner);
            _hasDeposit[owner] = true;
        }
        _activeDepositCount[owner]++;
    }

    /**
     * @notice Used to update the owners list after a withdraw
     * @param owner address of the deposit owner
     */
    function removeDepositOwner(address owner) internal {
        if (!_hasDeposit[owner]) {
            return; 
        }
        _activeDepositCount[owner]--;
        // If no active deposits remain, remove the owner from _depositOwners
        if (_activeDepositCount[owner] == 0) {
            uint256 index = _ownerIndex[owner];
            address lastOwner = _depositOwners[_depositOwners.length - 1];

            // Move the last element to the deleted position
            _depositOwners[index] = lastOwner;
            _ownerIndex[lastOwner] = index;

            // Remove the last element
            _depositOwners.pop();

            // Clean up mappings
            _hasDeposit[owner] = false;
            delete _ownerIndex[owner];
        }
    }


    /**
     * @notice Used to transfer funds from contract to treasury. Only TRANSFER_ROLE account can execute
     * @param tokenAddress address of the token we want to transfer
     * @param amount amout we want to transfer
     */
    function transferTokenAmount(address tokenAddress, uint256 amount) external onlyRole(TRANSFER_ROLE) {
            IERC20 token = IERC20(tokenAddress);
            uint256 balance = token.balanceOf(address(this));
            if (balance >= amount) {
                require(token.transfer(_treasuryAccount, amount), "Token transfer failed");
            }
            emit TreasuryTransfer(tokenAddress, amount);
    }
   
    function daysLeft(uint40 maturityTimestamp) private view returns (uint256) {
        uint256 currentTime = block.timestamp;
        if(maturityTimestamp <= currentTime){
            return 0;
        }
        uint256 secondsLeft = maturityTimestamp - currentTime;
        return secondsLeft / 86400; // Number of seconds in a day
    }
   
    /**
     * @notice Update/Add a deposit type
     * @notice if is updated with empty/0 fields, it will be considered deleted
     * @param index of the deposit Type, if it is greater than current length, then a new deposit is created
     * @param duration duration of the deposit in seconds
     * @param coolOffPeriod cool off period of the deposit type
     * @param minimumAmountToDeposit minimum amount allowed for this deposit type
     * @param name the name of the deposit
     * @param tokenAddress the address fo the token used for the deposit
     */
    function updateDepositsType(
        uint256 index,
        uint40 duration,
        uint40 coolOffPeriod,
        uint256 minimumAmountToDeposit,
        address tokenAddress,
        string calldata name
    ) external onlyRole(OPERATIONAL_ROLE) {
        unchecked {
            uint256 depositTypesLength = _depositTypes.length;

            if (index < depositTypesLength) {
                
                _depositTypes[index] = DepositType({
                    coolOffPeriod: coolOffPeriod,
                    duration: duration,
                    name: name,
                    minimumAmountToDeposit: minimumAmountToDeposit,
                    tokenAddress: tokenAddress
                });
                emit DepositTypeUpdated(
                    index,
                    coolOffPeriod,
                    duration,
                    name,
                    minimumAmountToDeposit,
                    tokenAddress,
                    false
                );
            } else {
                _depositTypes.push(
                    DepositType({
                        coolOffPeriod: coolOffPeriod,
                        duration: duration,
                        name: name,
                        minimumAmountToDeposit: minimumAmountToDeposit,
                        tokenAddress: tokenAddress
                    })
                );
                emit DepositTypeUpdated(
                    index,
                    coolOffPeriod,
                    duration,
                    name,
                    minimumAmountToDeposit,
                    tokenAddress,
                    true
                );
            }
        }
    }

     /**
     * @notice Update/Add a tier
     * @param index of the tier, if it is greater than current length, then a new tier is created
     * @param maxProfitPercentage max percentage gain for the tier
     * @param lowestNrOfEnfStaked the min amount of ENF staked (per day) to qualify for this tier.
     * Formula: (WALLET_ENF_AMOUNT_STAKED * (DAYS_BETWEEN_NOW_AND_MATURITY + 1)) / 365. EX: 10.000 enf staked for 3 months has a weight of appx: 2493
     * @param name the name of the tier
     */
    function updateTiers(
        uint16 index,
        uint16 maxProfitPercentage,
        uint256 lowestNrOfEnfStaked,
        string calldata name

    ) external onlyRole(OPERATIONAL_ROLE) {
        unchecked {
            uint256 tiersLength = _tiers.length;

            if (index < tiersLength) {
                _tiers[index] = Tier({
                    tierNumber:index,
                    lowestNrOfEnfStaked:lowestNrOfEnfStaked,
                    maxProfitPercentage: maxProfitPercentage,
                    name: name
                });
              
            } else {
                _tiers.push(
                    Tier({
                        tierNumber:index,
                        lowestNrOfEnfStaked:lowestNrOfEnfStaked,
                         maxProfitPercentage: maxProfitPercentage,
                        name: name
                    })
                );
               
            }
        }
    }

    function getDepositTypes() external view returns (DepositType[] memory) {
        return _depositTypes;
    } 

     function getTiers() external view returns (Tier[] memory) {
        return _tiers;
    }

    function getDepositsNumberPerOwner(address owner) external view returns (uint256) {
        return _depositsNumberPerOwner[owner];
    }
    
    function getLatestProftDistributionTimestamp() external view returns (uint40) {
        return _latestProftDistributionTimestamp;
    }

    /**
     * @notice Return available deposits of an address, with pagination
     * @param owner the address of the user that made the deposit
     * @param startIndex the index from where the search starts
     * @param length how many deposits are iterated
     */
    function getDepositsByOwner(
        address owner,
        uint256 startIndex,
        uint256 length
    ) external view returns (Deposit[] memory) {
        unchecked {
            uint256 depositNumber;
            uint256 step;
            Deposit[] memory deposits = new Deposit[](length);
            uint256 numberOfDeposits = _depositsNumberPerOwner[owner];
            for (startIndex; startIndex < numberOfDeposits && length > step; ++startIndex) {
                if (_depositsByOwner[owner][startIndex].owner != address(0)) {
                    deposits[depositNumber] = _depositsByOwner[owner][startIndex];
                    ++depositNumber;
                }
                ++step;
            }
            step = 0;

            Deposit[] memory depositsFiltered = new Deposit[](depositNumber);
            for (step; step < depositNumber; ++step) {
                depositsFiltered[step] = deposits[step];
            }
            return depositsFiltered;
        }
    }
     /**
     * @notice Return a list of addresses that have active deposits, with pagination
     * @param startIndex the index from where the search starts
     * @param pageSize how many addresses are iterated
     */
    function getDepositOwnersPaginated(uint256 startIndex, uint256 pageSize) 
        external 
        view 
        returns (address[] memory, uint256 totalOwners) 
    {
        uint256 total = _depositOwners.length;

        if (startIndex >= total) {
            address[] memory emptyArray = new address[](0);
            return (emptyArray, total);
        }
        uint256 endIndex = startIndex + pageSize;
        if (endIndex > total) {
            endIndex = total; // Cap at the array length
        }
        uint256 resultSize = endIndex - startIndex;
        address[] memory result = new address[](resultSize);
        for (uint256 i = 0; i < resultSize; i++) {
            result[i] = _depositOwners[startIndex + i];
        }
        return (result, total);
    }

    function getStakingContractAddress() external view returns (address) {
        return _stakeContractAddress;
    }
  
    /**
     * @notice Sets the stake contract address
     * @param stakeAddress stake contract address
     */
    function setStakeContractAddress(address stakeAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _stakeContractAddress = stakeAddress;
    }

     function getTreasuryAddress() external view returns (address) {
        return _treasuryAccount;
    }
  
    /**
     * @notice Sets the treasury account to which we will withdraw deposited funds
     * @param treasuryAddress trasury address
     */
    function setTreasuryAddress(address treasuryAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _treasuryAccount = treasuryAddress;
        emit SetTreasuryAddress(treasuryAddress);
    }


    function pauseDeposit() external onlyRole(OPERATIONAL_ROLE) {
        _pause();
    }

    function unpauseDeposit() external onlyRole(OPERATIONAL_ROLE) {
        _unpause();
    }


    // events
    event DepositEvent(
        address indexed owner,
        uint256 amount,
        uint40 startTimestamp,
        uint40 endTimestamp,
        uint40 coolOffPeriodTimestamp,
        uint40 duration,
        uint256 depositType,
        address depositToken
    );

    event WithdrawOnMaturity(address indexed owner, address tokenAddress, uint256 depositId, uint256 withdrawAmount, int256 profit, bool liquidateDeposit);
    event WithdrawIntent(address indexed owner, address tokenAddress, uint256 depositId, uint256 withdrawAmount, int256 profit, bool liquidateDeposit);

    event DepositTypeUpdated(
        uint256 index,
        uint40 coolOffPeriod,
        uint40 duration,
        string name,
        uint256 minimumAmountToDeposit,
        address tokenAddress,
        bool added
    );
    
    event TransferFailedEvent(address fromAddress, address toAddress, uint256 amount, address tokenAddress);
    event DepositError(string errorName);
    event SetTreasuryAddress(address newAddress);
    event TreasuryTransfer(address tokenAddress, uint256 amount);
    
}

error InvalidAmount();
error InvalidDeposit();
error CannotWithdrawThisTypeOfDeposit();
error WrongParam();
error InvalidState();
error DepositFundsTransferError();
error WithdrawAlreadyStarted();
error CannotWithdrawWithoutIntent();
error InvalidWalletStakes();
