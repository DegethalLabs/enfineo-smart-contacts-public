// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./interfaces/IENF.sol";
import "./structs/StakingStructs.sol";

/**
 * @author Enfineo
 * @notice Contract with Staking functionality over ENF token
 */
contract ENFStaking is ReentrancyGuard, AccessControl, Pausable {
    uint256 public constant DENOMINATOR = 10_000;
    bytes32 public constant UPDATE_DEPOSIT_TYPE_ROLE = keccak256("UPDATE_DEPOSIT_TYPE_ROLE");
    bytes32 public constant OPERATIONAL_ROLE = keccak256("OPERATIONAL_ROLE");
    bytes32 public constant SETTER_ROLE = keccak256("SETTER_ROLE");

    IENF private _enfToken;

    address private _vesting;

    uint256 private _rewardPool;

    /// @dev the types of deposits that an user can stake
    DepositType[] private _depositTypes;

    mapping(address => mapping(uint256 => Deposit)) private _depositsByOwner;
    mapping(address => uint256) private _depositsNumberPerOwner;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPDATE_DEPOSIT_TYPE_ROLE, msg.sender);
        _grantRole(OPERATIONAL_ROLE, msg.sender);
        _grantRole(SETTER_ROLE, msg.sender);
        _pause();
    }

    /**
     * @notice Stake an amount of ENF to get APR.
     * @param amount the amount of ENF to stake, it has to be greater than _minimumAmountToStake
     * @param depositTypeIndex index of the deposit type
     * @param beneficiary address that will be the owner of the deposit
     */
    function stake(
        uint256 amount,
        uint256 depositTypeIndex,
        address beneficiary
    ) external whenNotPaused {

         if (beneficiary == address(0)) {
            revert InvalidBeneficiary();
        }
        bool canStake = false;

        /// @dev only vesting contract can send stake of type 0 or 1
        if(msg.sender == _vesting
            && (depositTypeIndex == 0 || depositTypeIndex == 1)) {
            canStake = true;
            
        } else{

            if(msg.sender == beneficiary
                && depositTypeIndex != 0
                && depositTypeIndex != 1){
                    canStake = true;
            } 
        }
        if(!canStake){
            emit StakeError("Staking not allowed for this type and address");
            revert StakinNotAllowed();
        }


        /// @dev check if selected deposit type exists or if it was deleted
        uint256 reward = getRewardOnADepositType(amount, depositTypeIndex);

        DepositType memory selectedDepositType = _depositTypes[depositTypeIndex];

        if (amount < selectedDepositType.minimumAmountToStake) {
            emit StakeError("Invalid Stake amount");
            revert InvalidAmount();
        }

        if (block.timestamp + selectedDepositType.duration > type(uint40).max) {
            emit StakeError("Invalid block state");
            revert InvalidState();
        }

        updateRewardPool(reward, false);

        uint256 depositsNumberPerOwnerLocal = _depositsNumberPerOwner[beneficiary];

        Deposit memory deposit = Deposit({
            id: depositsNumberPerOwnerLocal,
            startTimestamp: uint40(block.timestamp),
            maturityTimestamp: uint40(block.timestamp) + selectedDepositType.duration,
            owner: beneficiary,
            amount: amount,
            reward: reward,
            depositType: selectedDepositType
        });

        _depositsByOwner[beneficiary][depositsNumberPerOwnerLocal++] = deposit;

        _depositsNumberPerOwner[beneficiary] = depositsNumberPerOwnerLocal;

        /// @dev we transfer funds only if the request came from a real user. Otherwise, the vesting contract will transfer the funds here 
        if(msg.sender != _vesting){
            bool transferStatus = _enfToken.transferFrom(msg.sender, address(this), amount);
            if(!transferStatus){
                emit TransferFailedEvent(msg.sender, address(this), amount);
                revert StakeFundsTransferError();
            }
        }
        
        emit Stake(
            beneficiary,
            amount,
            uint40(block.timestamp),
            uint40(block.timestamp) + selectedDepositType.duration,
            selectedDepositType.apr,
            selectedDepositType.penalty,
            selectedDepositType.duration,
            depositTypeIndex
        );
    }

    /**
     * @notice Unstake a deposit by its id. Some deposits can't be unstaked prior maturity
     * @param depositId id of the deposit
     */
    function unstake(uint256 depositId) public whenNotPaused {
        Deposit memory currentDeposit = _depositsByOwner[msg.sender][depositId];
        if (currentDeposit.owner == address(0)) {
            revert InvalidDeposit();
        }

        /// @notice check if the deposit is mature and can be collected,
        /// @notice otherwise check if it can be unstaked and apply penalty and cooling period
        if (currentDeposit.maturityTimestamp <= block.timestamp) {
            delete _depositsByOwner[msg.sender][depositId];
            bool result = _enfToken.transfer(currentDeposit.owner, currentDeposit.amount + currentDeposit.reward);
            if (!result){
                emit TransferFailedEvent(address(this), currentDeposit.owner,  currentDeposit.amount + currentDeposit.reward);
                revert StakeFundsTransferError();
            }

            emit UnstakeOnMaturity(msg.sender, depositId, currentDeposit.amount, currentDeposit.reward);
        } else {
            if (!currentDeposit.depositType.canUnstakePriorMaturation) {
                revert CannotUnstakeAtThisTypeOfDeposit();
            }

           delete _depositsByOwner[msg.sender][depositId];

           uint256 penaltyAmount;

            penaltyAmount = (currentDeposit.amount * currentDeposit.depositType.penalty) / DENOMINATOR;

            uint256 enfToOwner = currentDeposit.amount - penaltyAmount;

            updateRewardPool(penaltyAmount / 2, true);

            bool tokenTransfer = _enfToken.transfer(currentDeposit.owner, enfToOwner);
            if(!tokenTransfer){
                emit TransferFailedEvent(address(this), currentDeposit.owner,  enfToOwner);
                revert StakeFundsTransferError();
            }

            _enfToken.burn(address(this), penaltyAmount / 2);

            emit UnstakePriorMaturity(msg.sender, depositId, currentDeposit.amount, penaltyAmount);
        }
    }

    /**
     * @notice Update the amount of rewards available
     * @param amount represents the amount of tokens
     * @param add if true amount is added, if false is substracted
     */
    function updateRewardPool(uint256 amount, bool add) private {
        unchecked {
            if (add) {
                _rewardPool += amount;
            } else {
                if (_rewardPool < amount) {
                    revert InsufficientRewardAmountLeft();
                }
                _rewardPool -= amount;
            }
        }
    }
     function addRewardToPool(uint256 amount) external onlyRole(OPERATIONAL_ROLE) {
        _rewardPool += amount;
        emit RewardAddedToPool(_rewardPool, amount);
    }

    function removeRewardFromPool(address to, uint256 amount) external onlyRole(OPERATIONAL_ROLE) {
        if (amount > _rewardPool) {
            revert InvalidAmountToRecover();
        }
        updateRewardPool(amount, false);
        _enfToken.transfer(to, amount);
        emit RewardRemovedFromPool(address(_enfToken), to, amount);
    }

   
    function pauseStake() external onlyRole(OPERATIONAL_ROLE) {
        _pause();
    }

    function unpauseStake() external onlyRole(OPERATIONAL_ROLE) {
        _unpause();
    }

    // setters
    function setEnfToken(IENF tokenAddress) external onlyRole(SETTER_ROLE) {
        if (address(tokenAddress) == address(0)) {
            revert InvalidParam(3);
        }
        _enfToken = tokenAddress;
        emit SetEnfToken(address(tokenAddress));
    }

    function setVestingContractAddress(address contractAddress) external onlyRole(SETTER_ROLE) {
        if (address(contractAddress) == address(0)) {
            revert InvalidParam(4);
        }
        _vesting = contractAddress;
        emit SetVesting(address(contractAddress));
    }

    /**
     * @notice Update/Add a deposit type
     * @notice if is updated with empty/0 fields, it will be considered deleted
     * @notice the check for
     * @param index the index of the deposit type if an update is made,
     * @param index or if it is greater than current length than a new deposit is created
     * @param apr anual percentage rate
     * @param penalty the percent of the staked amount that will be substracted
     * @param duration duration in seconds until maturity
     * @param name the name of the deposit
     * @param canUnstakePriorMaturation bool, if the deposit can be unstaed prior maturity
     */
    function updateDepositsType(
        uint256 index,
        uint16 apr,
        uint16 penalty,
        uint40 duration,
        string calldata name,
        bool canUnstakePriorMaturation,
        uint256 newMinimumAmountToStake
    ) external onlyRole(UPDATE_DEPOSIT_TYPE_ROLE) {
        unchecked {
            uint256 depositTypesLength = _depositTypes.length;

            if (index < depositTypesLength) {
                
                _depositTypes[index] = DepositType({
                    apr: apr,
                    penalty: penalty,
                    duration: duration,
                    name: name,
                    canUnstakePriorMaturation: canUnstakePriorMaturation,
                    minimumAmountToStake: newMinimumAmountToStake
                });
                emit DepositTypeUpdated(
                    index,
                    apr,
                    penalty,
                    duration,
                    name,
                    canUnstakePriorMaturation,
                    newMinimumAmountToStake,
                    false
                );
            } else {
                
                _depositTypes.push(
                    DepositType({
                        apr: apr,
                        penalty: penalty,
                        duration: duration,
                        name: name,
                        canUnstakePriorMaturation: canUnstakePriorMaturation,
                        minimumAmountToStake: newMinimumAmountToStake
                    })
                );
                emit DepositTypeUpdated(
                    depositTypesLength,
                    apr,
                    penalty,
                    duration,
                    name,
                    canUnstakePriorMaturation,
                    newMinimumAmountToStake,
                    true
                );
            }
        }
    }

    // getters
    function getEnfToken() external view returns (IERC20) {
        return _enfToken;
    }

    function getVestingContractAddress() external view returns (address) {
        return _vesting;
    }

    function getDepositTypes() external view returns (DepositType[] memory) {
        return _depositTypes;
    }

    function getDepositsNumberPerOwner(address owner) external view returns (uint256) {
        return _depositsNumberPerOwner[owner];
    }

    /**
     * @notice Return available deposits of an address, with pagination
     * @param owner the address of the user that made the deposit
     * @param startIndex the index from where the search starts
     * @param length how many deposits are iterated, even if they are deleted
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

    function getRewardPoolAmount() external view returns (uint256) {
        return _rewardPool;
    }

    function getRewardOnADepositType(uint256 amount, uint256 depositTypeIndex) public view returns (uint256) {
        if (depositTypeIndex >= _depositTypes.length || _depositTypes[depositTypeIndex].duration == 0) {
            revert InvalidDepositTypeIndex();
        }
        DepositType memory selectedDepositType = _depositTypes[depositTypeIndex];
        return (amount * selectedDepositType.apr * selectedDepositType.duration) / (DENOMINATOR * 365 days);
    }

    // events
    event Stake(
        address indexed owner,
        uint256 amount,
        uint40 startTimestamp,
        uint40 endTimestamp,
        uint16 apr,
        uint16 penalty,
        uint40 duration,
        uint256 depositType
    );

    event UnstakePriorMaturity(address indexed owner, uint256 depositId, uint256 unstakedAmount, uint256 penalty);
    event UnstakeOnMaturity(address indexed owner, uint256 depositId, uint256 unstakedAmount, uint256 reward);
    event Claim(address indexed owner, uint256 amount);
    event SetEnfToken(address newContract);
    event SetVesting(address newContract);
    event SetPenalty(uint16 penalty);
    event DepositTypeUpdated(
        uint256 index,
        uint16 apr,
        uint16 penalty,
        uint40 duration,
        string name,
        bool canUnstakePriorMaturation,
        uint256 minimumAmountToStake,
        bool added
    );
    event TransferFailedEvent(address fromAddress, address toAddress, uint256 amount);
    event RewardAddedToPool(uint256 totalfRewardPool, uint256 addedReward);
    event RewardRemovedFromPool(address token, address to, uint256 amount);
    event StakeError(string errorName);
}

error InvalidAmount();
error InvalidBeneficiary();
error InvalidDepositTypeIndex();
error InvalidDeposit();
error DepositIsNotMature();
error Unauthorized();
error CannotUnstakeAtThisTypeOfDeposit();
error DepositAlreadyUstaked();
error InsufficientRewardAmountLeft();
error CoolingDeposit();
error NotEnoughTokens();
error InvalidAmountToRecover();
error InvalidAmountToUpdateRewardPool();
error InvalidParam(uint256 errorCode);
error StakinNotAllowed();
error InvalidState();
error StakeFundsTransferError();
