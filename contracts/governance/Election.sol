pragma solidity ^0.5.13;

import "openzeppelin-solidity/contracts/math/Math.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import "./interfaces/IElection.sol";
import "./interfaces/IValidators.sol";
import "../common/CalledByVm.sol";
import "../common/Initializable.sol";
import "../common/FixidityLib.sol";
import "../common/linkedlists/AddressSortedLinkedList.sol";
import "../common/UsingPrecompiles.sol";
import "../common/UsingRegistry.sol";
import "../common/interfaces/IMapVersionedContract.sol";
import "../common/libraries/Heap.sol";
import "../common/libraries/ReentrancyGuard.sol";

contract Election is
IElection,
IMapVersionedContract,
Ownable,
ReentrancyGuard,
Initializable,
UsingRegistry,
UsingPrecompiles,
CalledByVm
{
    using AddressSortedLinkedList for SortedLinkedList.List;
    using FixidityLib for FixidityLib.Fraction;
    using SafeMath for uint256;

    // 1e20 ensures that units can be represented as precisely as possible to avoid rounding errors
    // when translating to votes, without risking integer overflow.
    // A maximum of 1,000,000,000 MAP (1e27) yields a maximum of 1e47 units, whose product is at
    // most 1e74, which is less than 2^256.
    uint256 private constant UNIT_PRECISION_FACTOR = 100000000000000000000;

    struct PendingVote {
        // The value of the vote, in gold.
        uint256 value;
        // The epoch at which the vote was cast.
        uint256 epoch;
    }

    struct ValidatorPendingVotes {
        // The total number of pending votes that have been cast for this validator.
        uint256 total;
        // Pending votes cast per voter.
        mapping(address => PendingVote) byAccount;
        address[] voters;
    }

    // Pending votes are those for which no following elections have been held.
    // These votes have yet to contribute to the election of validators and thus do not accrue
    // rewards.
    struct PendingVotes {
        // The total number of pending votes cast across all validators.
        uint256 total;
        mapping(address => ValidatorPendingVotes) forValidator;
    }

    // validator info
    struct ValidatorActiveVotes {
        // The total number of active votes that have been cast for this validator.
        uint256 total;
        // The total number of active votes by a voter is equal to the number of active vote units for
        // that voter times the total number of active votes divided by the total number of active
        // vote units.
        uint256 totalUnits;
        mapping(address => uint256) unitsByAccount; //voter => value
    }

    // Active votes are those for which at least one following election has been held.
    // These votes have contributed to the election of validators and thus accrue rewards.
    struct ActiveVotes {
        // The total number of active votes cast across all validators.
        uint256 total;
        mapping(address => ValidatorActiveVotes) forValidator;  // validator => voters
    }

    struct TotalVotes {
        // A list of eligible Validators sorted by total (pending+active) votes.
        // Note that this list will omit ineligible Validators, including those that may have > 0
        // total votes.
        SortedLinkedList.List eligible;
    }

    struct Votes {
        //pending and active can distinguish between before and after reward
        PendingVotes pending; //validator => voters pending
        ActiveVotes active;   //validator => voters active
        TotalVotes total;     //sort validators
        // Maps an account to the list of validators it's voting for.
        mapping(address => address[]) validatorsVotedFor; // voter => validators
    }

    struct ElectableValidators {
        uint256 min;
        uint256 max;
    }

    Votes private votes;
    // Governs the minimum and maximum number of validators that can be elected.
    ElectableValidators public electableValidators;
    // Governs how many validator validators a single account can vote for.
    uint256 public maxNumValidatorsVotedFor;
    // Validators must receive at least this fraction of the total votes in order to be considered in
    // elections.
    FixidityLib.Fraction public electabilityThreshold;

    event ElectableValidatorsSet(uint256 min, uint256 max);
    event MaxNumValidatorsVotedForSet(uint256 maxNumValidatorsVotedFor);
    event ElectabilityThresholdSet(uint256 electabilityThreshold);
    event ValidatorMarkedEligible(address indexed validator);
    event ValidatorMarkedIneligible(address indexed validator);
    event ValidatorVoteCast(address indexed account, address indexed validator, uint256 value);
    event ValidatorVoteActivated(
        address indexed account,
        address indexed validator,
        uint256 value
    );
    event ValidatorPendingVoteRevoked(
        address indexed account,
        address indexed validator,
        uint256 value
    );
    event ValidatorActiveVoteRevoked(
        address indexed account,
        address indexed validator,
        uint256 value
    );
    event EpochRewardRemainsDistributedToValidators(address indexed validator, uint256 value);

    event EpochRewardsDistributedToVoters(address indexed voterAddress, uint256 value);

    /**
     * @notice Returns the storage, major, minor, and patch version of the contract.
     * @return The storage, major, minor, and patch version of the contract.
     */
    function getVersionNumber() external pure returns (uint256, uint256, uint256, uint256) {
        return (1, 1, 2, 1);
    }

    /**
     * @notice Used in place of the constructor to allow the contract to be upgradable via proxy.
     * @param registryAddress The address of the registry core smart contract.
     * @param minElectableValidators The minimum number of validators that can be elected.
     * @param _maxNumValidatorsVotedFor The maximum number of validators that an account can vote for at once.
     * @param _electabilityThreshold The minimum ratio of votes a validator needs before its members can
     *   be elected.
     * @dev Should be called only once.
     */
    function initialize(
        address registryAddress,
        uint256 minElectableValidators,
        uint256 maxElectableValidators,
        uint256 _maxNumValidatorsVotedFor,
        uint256 _electabilityThreshold
    ) external initializer {
        _transferOwnership(msg.sender);
        setRegistry(registryAddress);
        setElectableValidators(minElectableValidators, maxElectableValidators);
        setMaxNumValidatorsVotedFor(_maxNumValidatorsVotedFor);
        setElectabilityThreshold(_electabilityThreshold);
    }

    /**
     * @notice Sets initialized == true on implementation contracts
     * @param test Set to true to skip implementation initialization
     */
    constructor(bool test) public Initializable(test) {}

    /**
     * @notice Updates the minimum and maximum number of validators that can be elected.
     * @param min The minimum number of validators that can be elected.
     * @param max The maximum number of validators that can be elected.
     * @return True upon success.
     */
    function setElectableValidators(uint256 min, uint256 max) public onlyOwner returns (bool) {
        require(0 < min, "Minimum electable validators cannot be zero");
        require(min <= max, "Maximum electable validators cannot be smaller than minimum");
        require(
            min != electableValidators.min || max != electableValidators.max,
            "Electable validators not changed"
        );
        electableValidators = ElectableValidators(min, max);
        emit ElectableValidatorsSet(min, max);
        return true;
    }

    /**
     * @notice Returns the minimum and maximum number of validators that can be elected.
     * @return The minimum and maximum number of validators that can be elected.
     */
    function getElectableValidators() external view returns (uint256, uint256) {
        return (electableValidators.min, electableValidators.max);
    }

    /**
     * @notice Updates the maximum number of validators an account can be voting for at once.
     * @param _maxNumValidatorsVotedFor The maximum number of validators an account can vote for.
     * @return True upon success.
     */
    function setMaxNumValidatorsVotedFor(uint256 _maxNumValidatorsVotedFor) public onlyOwner returns (bool) {
        require(_maxNumValidatorsVotedFor != maxNumValidatorsVotedFor, "Max validators voted for not changed");
        maxNumValidatorsVotedFor = _maxNumValidatorsVotedFor;
        emit MaxNumValidatorsVotedForSet(_maxNumValidatorsVotedFor);
        return true;
    }

    /**
     * @notice Sets the electability threshold.
     * @param threshold Electability threshold as unwrapped Fraction.
     * @return True upon success.
     */
    function setElectabilityThreshold(uint256 threshold) public onlyOwner returns (bool) {
        electabilityThreshold = FixidityLib.wrap(threshold);
        require(
            electabilityThreshold.lt(FixidityLib.fixed1()),
            "Electability threshold must be lower than 100%"
        );
        emit ElectabilityThresholdSet(threshold);
        return true;
    }

    /**
     * @notice Gets the election threshold.
     * @return Threshold value as unwrapped fraction.
     */
    function getElectabilityThreshold() external view returns (uint256) {
        return electabilityThreshold.unwrap();
    }

    /**
     * @notice Increments the number of total and pending votes for `validator`.
     * @param validator The validator to vote for.
     * @param value The amount of gold to use to vote.
     * @param lesser The validator receiving fewer votes than `validator`, or 0 if `validator` has the
     *   fewest votes of any validator.
     * @param greater The validator receiving more votes than `validator`, or 0 if `validator` has the
     *   most votes of any validator.
     * @return True upon success.
     * @dev Fails if `validator` is empty or not a validator.
     */
    function vote(address validator, uint256 value, address lesser, address greater)
    external
    nonReentrant
    returns (bool)
    {
        require(votes.total.eligible.contains(validator), "Validator not eligible");
        require(0 < value, "Vote value cannot be zero");
//        require(canReceiveVotes(validator, value), "Validator cannot receive votes");
        address account = getAccounts().voteSignerToAccount(msg.sender);

        // Add validator to the validators voted for by the account.
        bool alreadyVotedForValidator = false;
        address[] storage validators = votes.validatorsVotedFor[account];
        for (uint256 i = 0; i < validators.length; i = i.add(1)) {
            alreadyVotedForValidator = alreadyVotedForValidator || validators[i] == validator;
        }
        if (!alreadyVotedForValidator) {
            require(validators.length < maxNumValidatorsVotedFor, "Voted for too many validators");
            validators.push(validator);
        }
        require(value <= getLockedGold().getAccountNonvotingLockedGold(account), "Nonvoting Locked Gold too low");
        incrementPendingVotes(validator, account, value);
        incrementTotalVotes(validator, value, lesser, greater);
        getLockedGold().decrementNonvotingAccountBalance(account, value);
        emit ValidatorVoteCast(account, validator, value);
        return true;
    }

    /**
     * @notice Converts `account`'s pending votes for `validator` to active votes.
     * @param validator The voter to vote for.
     * @return True upon success.
     * @dev Pending votes cannot be activated until an election has been held.
     */
    function activate(address validator) external nonReentrant returns (bool) {
        address account = getAccounts().voteSignerToAccount(msg.sender);
        return _activate(validator, account);
    }

    /**
     * @notice Converts `account`'s pending votes for `validator` to active votes.
     * @param validator The voter to vote for.
     * @param account The voter account's pending votes to active votes
     * @return True upon success.
     * @dev Pending votes cannot be activated until an election has been held.
     */
    function activateForAccount(address validator, address account) external nonReentrant returns (bool) {
        return _activate(validator, account);
    }

    function _activate(address validator, address account) internal returns (bool) {
        PendingVote storage pendingVote = votes.pending.forValidator[validator].byAccount[account];
        require(pendingVote.epoch < getEpochNumber(), "Pending vote epoch not passed");
        uint256 value = pendingVote.value;
        require(value > 0, "Vote value cannot be zero");
        decrementPendingVotes(validator, account, value);
        incrementActiveVotes(validator, account, value);
        emit ValidatorVoteActivated(account, validator, value);
        return true;
    }

    /**
     * @notice Returns whether or not an account's votes for the specified validator can be activated.
     * @param account The account with pending votes.
     * @param validator The  validator that `account` has pending votes for.
     * @return Whether or not `account` has activatable votes for `validator`.
     * @dev Pending votes cannot be activated until an election has been held.
     */
    function hasActivatablePendingVotes(address account, address validator) external view returns (bool) {
        PendingVote storage pendingVote = votes.pending.forValidator[validator].byAccount[account];
        return pendingVote.epoch < getEpochNumber() && pendingVote.value > 0;
    }

    function pendingInfo(address account, address validator) external view returns (uint256, uint256) {
        PendingVote storage pendingVote = votes.pending.forValidator[validator].byAccount[account];
        return (pendingVote.value, pendingVote.epoch);
    }


    /**
     * @notice Revokes `value` pending votes for `validator`
     * @param validator The validator to revoke votes from.
     * @param value The number of votes to revoke.
     * @param lesser The validator receiving fewer votes than the validator for which the vote was revoked,
     *   or 0 if that validator has the fewest votes of any validator.
     * @param greater The validator receiving more votes than the validator for which the vote was revoked,
     *   or 0 if that validator has the most votes of any validator.
     * @param index The index of the validator in the account's voting list.
     * @return True upon success.
     * @dev Fails if the account has not voted on a validator.
     */
    function revokePending(
        address validator,
        uint256 value,
        address lesser,
        address greater,
        uint256 index
    ) external nonReentrant returns (bool) {
        require(validator != address(0), "Validator address zero");
        address account = getAccounts().voteSignerToAccount(msg.sender);
        require(0 < value, "Vote value cannot be zero");
        require(
            value <= getPendingVotesForValidatorByAccount(validator, account),
            "Vote value larger than pending votes"
        );
        decrementPendingVotes(validator, account, value);
        decrementTotalVotes(validator, value, lesser, greater);
        getLockedGold().incrementNonvotingAccountBalance(account, value);
        if (getTotalVotesForValidatorByAccount(validator, account) == 0) {
            deleteElement(votes.validatorsVotedFor[account], validator, index);
        }
        emit ValidatorPendingVoteRevoked(account, validator, value);
        return true;
    }

    /**
     * @notice Revokes all active votes for `validator`
     * @param validator The validator to revoke votes from.
     * @param lesser The validator receiving fewer votes than the validator for which the vote was revoked,
     *   or 0 if that validator has the fewest votes of any validator.
     * @param greater The validator receiving more votes than the validator for which the vote was revoked,
     *   or 0 if that validator has the most votes of any validator.
     * @param index The index of the validator in the account's voting list.
     * @return True upon success.
     * @dev Fails if the account has not voted on a validator.
     */
    function revokeAllActive(address validator, address lesser, address greater, uint256 index)
    external
    nonReentrant
    returns (bool)
    {
        address account = getAccounts().voteSignerToAccount(msg.sender);
        uint256 value = getActiveVotesForValidatorByAccount(validator, account);
        return _revokeActive(validator, value, lesser, greater, index);
    }

    /**
     * @notice Revokes `value` active votes for `validator`
     * @param validator The validator  to revoke votes from.
     * @param value The number of votes to revoke.
     * @param lesser The validator receiving fewer votes than the validator for which the vote was revoked,
     *   or 0 if that validator has the fewest votes of any validator.
     * @param greater The validator receiving more votes than the validator for which the vote was revoked,
     *   or 0 if that validator has the most votes of any validator.
     * @param index The index of the validator in the account's voting list.
     * @return True upon success.
     * @dev Fails if the account has not voted on a validator.
     */
    function revokeActive(
        address validator,
        uint256 value,
        address lesser,
        address greater,
        uint256 index
    ) external nonReentrant returns (bool) {
        return _revokeActive(validator, value, lesser, greater, index);
    }

    function _revokeActive(
        address validator,
        uint256 value,
        address lesser,
        address greater,
        uint256 index
    ) internal returns (bool) {
        // TODO(asa): Dedup with revokePending.
        require(validator != address(0), "Validator address zero");
        address account = getAccounts().voteSignerToAccount(msg.sender);
        require(0 < value, "Vote value cannot be zero");
        require(
            value <= getActiveVotesForValidatorByAccount(validator, account),
            "Vote value larger than active votes"
        );
        decrementActiveVotes(validator, account, value);
        decrementTotalVotes(validator, value, lesser, greater);
        getLockedGold().incrementNonvotingAccountBalance(account, value);
        if (getTotalVotesForValidatorByAccount(validator, account) == 0) {
            deleteElement(votes.validatorsVotedFor[account], validator, index);
        }
        emit ValidatorActiveVoteRevoked(account, validator, value);
        return true;
    }

    /**
     * @notice Decrements `value` pending or active votes for `validator` from `account`.
     *         First revokes all pending votes and then, if `value` votes haven't
     *         been revoked yet, revokes additional active votes.
     *         Fundamentally calls `revokePending` and `revokeActive` but only resorts validators once.
     * @param account The account whose votes to `validator` should be decremented.
     * @param validator The validator to decrement votes from.
     * @param maxValue The maxinum number of votes to decrement and revoke.
     * @param lesser The validator receiving fewer votes than the validator for which the vote was revoked,
     *               or 0 if that validator has the fewest votes of any validator.
     * @param greater The validator receiving more votes than the validator for which the vote was revoked,
     *                or 0 if that validator has the most votes of any validator.
     * @param index The index of the validator in the account's voting list.
     * @return uint256 Number of votes successfully decremented and revoked, with a max of `value`.
     */
    function _decrementVotes(
        address account,
        address validator,
        uint256 maxValue,
        address lesser,
        address greater,
        uint256 index
    ) internal returns (uint256) {
        uint256 remainingValue = maxValue;
        uint256 pendingVotes = getPendingVotesForValidatorByAccount(validator, account);
        if (pendingVotes > 0) {
            uint256 decrementValue = Math.min(remainingValue, pendingVotes);
            decrementPendingVotes(validator, account, decrementValue);
            emit ValidatorPendingVoteRevoked(account, validator, decrementValue);
            remainingValue = remainingValue.sub(decrementValue);
        }
        uint256 activeVotes = getActiveVotesForValidatorByAccount(validator, account);
        if (activeVotes > 0 && remainingValue > 0) {
            uint256 decrementValue = Math.min(remainingValue, activeVotes);
            decrementActiveVotes(validator, account, decrementValue);
            emit ValidatorActiveVoteRevoked(account, validator, decrementValue);
            remainingValue = remainingValue.sub(decrementValue);
        }
        uint256 decrementedValue = maxValue.sub(remainingValue);
        if (decrementedValue > 0) {
            decrementTotalVotes(validator, decrementedValue, lesser, greater);
            if (getTotalVotesForValidatorByAccount(validator, account) == 0) {
                deleteElement(votes.validatorsVotedFor[account], validator, index);
            }
        }
        return decrementedValue;
    }

    /**
     * @notice Returns the total number of votes cast by an account.
     * @param account The address of the account.
     * @return The total number of votes cast by an account.
     */
    function getTotalVotesByAccount(address account) external view returns (uint256) {
        uint256 total = 0;
        address[] memory validators = votes.validatorsVotedFor[account];
        for (uint256 i = 0; i < validators.length; i = i.add(1)) {
            total = total.add(getTotalVotesForValidatorByAccount(validators[i], account));
        }
        return total;
    }

    /**
     * @notice Returns the pending votes for `validator` made by `account`.
     * @param validator The address of the validator.
     * @param account The address of the voting account.
     * @return The pending votes for `validator` made by `account`.
     */
    function getPendingVotesForValidatorByAccount(address validator, address account)
    public
    view
    returns (uint256)
    {
        return votes.pending.forValidator[validator].byAccount[account].value;
    }


    /**
     * @notice Returns the total votes for `validator` made by `account`.
     * @param validator The address of the validator.
     * @param account The address of the voting account.
     * @return The total votes for `validator` made by `account`.
     */
    function getTotalVotesForValidatorByAccount(address validator, address account)
    public
    view
    returns (uint256)
    {
        uint256 pending = getPendingVotesForValidatorByAccount(validator, account);
        uint256 active = getActiveVotesForValidatorByAccount(validator, account);
        return pending.add(active);
    }

    /**
     * @notice Returns the total active vote units made for `validator`.
     * @param validator The address of the validator.
     * @return The total active vote units made for `validator`.
     */
    function getActiveVotesForValidator(address validator) public view returns (uint256) {
        return votes.active.forValidator[validator].total;
    }
    /**
     * @notice Returns the total votes made for `validator`.
     * @param validator The address of the validator.
     * @return The total votes made for `validator`.
     */
    function getTotalVotesForValidator(address validator) public view returns (uint256) {
        return votes.pending.forValidator[validator].total.add(votes.active.forValidator[validator].total);
    }

    /**
     * @notice Returns the pending voters vote for `validator`.
     * @param validator The address of the validator.
     * @return The active voters made for `validator`.
     */
    function getPendingVotersForValidator(address validator) public view returns (address[] memory) {
        return votes.pending.forValidator[validator].voters;
    }

    /**
     * @notice Returns the pending votes made for `validator`.
     * @param validator The address of the validator.
     * @return The pending votes made for `validator`.
     */
    function getPendingVotesForValidator(address validator) public view returns (uint256) {
        return votes.pending.forValidator[validator].total;
    }

    /**
     * @notice Returns whether or not a validator is eligible to receive votes.
     * @return Whether or not a validator is eligible to receive votes.
     * @dev Eligible validators that have received their maximum number of votes cannot receive more.
     */
    function getValidatorEligibility(address validator) external view returns (bool) {
        return votes.total.eligible.contains(validator);
    }

    function getTopValidators(uint256 topNum) external view returns (address[] memory) {
        uint256 numElectionValidators = votes.total.eligible.numElementsGreaterThan(0, topNum);
        return votes.total.eligible.headN(numElectionValidators);
    }

    function distributeEpochVotersRewards(address validator, uint256 value, address lesser, address greater)
    external
    onlyVm
    {
        _distributeEpochVotersRewards(validator, value, lesser, greater);
    }

    function _distributeEpochVotersRewards(address validator, uint256 value, address lesser, address greater)
    internal
    {
        if (votes.total.eligible.contains(validator)) {
            uint256 newVoteTotal = votes.total.eligible.getValue(validator).add(value);
            votes.total.eligible.update(validator, newVoteTotal, lesser, greater);
        }

        votes.active.forValidator[validator].total = votes.active.forValidator[validator].total.add(value);
        votes.active.total = votes.active.total.add(value);
        emit EpochRewardsDistributedToVoters(validator, value);
    }


    /**
     * @notice Increments the number of total votes for `validator` by `value`.
     * @param validator The validator whose vote total should be incremented.
     * @param value The number of votes to increment.
     * @param lesser The validator receiving fewer votes than the validator for which the vote was cast,
     *   or 0 if that validator has the fewest votes of any validator.
     * @param greater The validator receiving more votes than the validator for which the vote was cast,
     *   or 0 if that validator has the most votes of any validator.
     */
    function incrementTotalVotes(address validator, uint256 value, address lesser, address greater)
    private
    {
        uint256 newVoteTotal = votes.total.eligible.getValue(validator).add(value);
        votes.total.eligible.update(validator, newVoteTotal, lesser, greater);
    }

    /**
     * @notice Decrements the number of total votes for `validator` by `value`.
     * @param validator The validator whose vote total should be decremented.
     * @param value The number of votes to decrement.
     * @param lesser The validator receiving fewer votes than the validator for which the vote was revoked,
     *   or 0 if that validator has the fewest votes of any validator.
     * @param greater The validator receiving more votes than the validator for which the vote was revoked,
     *   or 0 if that validator has the most votes of any validator.
     */
    function decrementTotalVotes(address validator, uint256 value, address lesser, address greater)
    private
    {
        if (votes.total.eligible.contains(validator)) {
            uint256 newVoteTotal = votes.total.eligible.getValue(validator).sub(value);
            votes.total.eligible.update(validator, newVoteTotal, lesser, greater);
        }
    }

    /**
     * @notice Marks a validator ineligible for electing validators.
     * @param validator The address of the validator.
     * @dev Can only be called by the registered "Validators" contract.
     */
    function markValidatorIneligible(address validator)
    external
    onlyRegisteredContract(VALIDATORS_REGISTRY_ID)
    {
        votes.total.eligible.remove(validator);
        emit ValidatorMarkedIneligible(validator);
    }

    /**
     * @notice Marks a validator eligible for electing validators.
     * @param validator The address of the validator.
     * @param lesser The address of the validator that has received fewer votes than this validator.
     * @param greater The address of the validator that has received more votes than this validator.
     */
    function markValidatorEligible(address lesser, address greater, address validator)
    external
    onlyRegisteredContract(VALIDATORS_REGISTRY_ID)
    {
        uint256 value = getTotalVotesForValidator(validator);
        //will reload the last voters Info
        votes.total.eligible.insert(validator, value, lesser, greater);
        emit ValidatorMarkedEligible(validator);
    }

    /**
     * @notice Increments the number of pending votes for `validator` made by `account`.
     * @param validator The address of the validator.
     * @param account The address of the voting account.
     * @param value The number of votes.
     */
    function incrementPendingVotes(address validator, address account, uint256 value) private {
        PendingVotes storage pending = votes.pending;
        pending.total = pending.total.add(value);

        ValidatorPendingVotes storage validatorPending = pending.forValidator[validator];
        validatorPending.total = validatorPending.total.add(value);

        PendingVote storage pendingVote = validatorPending.byAccount[account];
        if (pendingVote.value == 0) {
            validatorPending.voters.push(account);
        }
        pendingVote.value = pendingVote.value.add(value);
        pendingVote.epoch = getEpochNumber();
    }

    /**
     * @notice Decrements the number of pending votes for `validator` made by `account`.
     * @param validator The address of the validator.
     * @param account The address of the voting account.
     * @param value The number of votes.
     */
    function decrementPendingVotes(address validator, address account, uint256 value) private {
        PendingVotes storage pending = votes.pending;
        pending.total = pending.total.sub(value);

        ValidatorPendingVotes storage validatorPending = pending.forValidator[validator];
        validatorPending.total = validatorPending.total.sub(value);

        PendingVote storage pendingVote = validatorPending.byAccount[account];
        pendingVote.value = pendingVote.value.sub(value);
        if (pendingVote.value == 0) {
            pendingVote.epoch = 0;
        }
    }

    /**
     * @notice Increments the number of active votes for `validator` made by `account`.
     * @param validator The address of the validator.
     * @param account The address of the voting account.
     * @param value The number of votes.
     */
    function incrementActiveVotes(address validator, address account, uint256 value)
    private
    returns (uint256)
    {
        ActiveVotes storage active = votes.active;
        active.total = active.total.add(value);

        uint256 units = votesToUnits(validator, value);

        ValidatorActiveVotes storage validatorActive = active.forValidator[validator];
        validatorActive.total = validatorActive.total.add(value);

        validatorActive.totalUnits = validatorActive.totalUnits.add(units);
        validatorActive.unitsByAccount[account] = validatorActive.unitsByAccount[account].add(units);


        return value;
    }

    /**
     * @notice Decrements the number of active votes for `validator` made by `account`.
     * @param validator The address of the validator.
     * @param account The address of the voting account.
     * @param value The number of votes.
     */
    function decrementActiveVotes(address validator, address account, uint256 value)
    private
    returns (uint256)
    {
        ActiveVotes storage active = votes.active;
        active.total = active.total.sub(value);

        ValidatorActiveVotes storage validatorActive = active.forValidator[validator];
        //--------------------------
        // Rounding may cause votesToUnits to return 0 for value != 0, preventing users
        // from revoking the last of their votes. The case where value == votes is special cased
        // to prevent this.
        uint256 units = 0;
        uint256 activeVotes = getActiveVotesForValidatorByAccount(validator, account);
        if (activeVotes == value) {
            units = validatorActive.unitsByAccount[account];
        } else {
            units = votesToUnits(validator, value);
        }
        validatorActive.total = validatorActive.total.sub(value);
        validatorActive.totalUnits = validatorActive.totalUnits.sub(units);
        validatorActive.unitsByAccount[account] = validatorActive.unitsByAccount[account].sub(units);

        return value;
    }


    /**
     * @notice Returns the validators that `account` has voted for.
     * @param account The address of the account casting votes.
     * @return The validators that `account` has voted for.
     */
    function getValidatorsVotedForByAccount(address account) external view returns (address[] memory) {
        return votes.validatorsVotedFor[account];
    }

    /**
     * @notice Deletes an element from a list of addresses.
     * @param list The list of addresses.
     * @param element The address to delete.
     * @param index The index of `element` in the list.
     */
    function deleteElement(address[] storage list, address element, uint256 index) private {
        require(index < list.length && list[index] == element, "Bad index");
        uint256 lastIndex = list.length.sub(1);
        list[index] = list[lastIndex];
        list.length = lastIndex;
    }

    /**
     * @notice Returns whether or not a validator can receive the specified number of votes.
     * @param validator The address of the validator.
     * @param value The number of votes.
     * @return Whether or not a validator can receive the specified number of votes.
     * @dev Votes are not allowed to be cast that  validator's proportion of locked gold
     *  voting for it to greater than TotalLockedGold
     * @dev Note that validators may still receive additional votes via rewards even if this function
     *   returns false.
     */
    function canReceiveVotes(address validator, uint256 value) public view returns (bool) {
        uint256 left = getTotalVotesForValidator(validator).add(value);
        uint256 right = getLockedGold().getTotalLockedGold();
        return left <= right;
    }

    /**
     * @notice Returns the number of votes that a validator can receive.
     * @return The number of votes that a validator can receive.
     * @dev Votes are not allowed to be cast that would increase a validator's proportion of locked gold
     *   voting for it to greater than
     *   (numValidatorMembers + 1) / min(maxElectableValidators, numRegisteredValidators)
     * @dev Note that a validator's vote total may exceed this number through rewards or config changes.
     */
    function getNumVotesReceivable() external view returns (uint256) {
        uint256 numerator = getLockedGold().getTotalLockedGold();
        uint256 denominator = Math.min(
            electableValidators.max,
            getValidators().getNumRegisteredValidators()
        );
        return numerator.div(denominator);
    }

    /**
     * @notice Returns the total votes received across all validators.
     * @return The total votes received across all validators.
     */
    function getTotalVotes() public view returns (uint256) {
        return votes.active.total.add(votes.pending.total);
    }

    /**
     * @notice Returns the active votes received across all validators.
     * @return The active votes received across all validators.
     */
    function getActiveVotes() public view returns (uint256) {
        return votes.active.total;
    }

    /**
     * @notice Returns the list of validator validators eligible to elect validators.
     * @return The list of validator validators eligible to elect validators.
     */
    function getEligibleValidators() external view returns (address[] memory) {
        return votes.total.eligible.getKeys();
    }

    /**
     * @notice Returns lists of all validator validators and the number of votes they've received.
     * @return Lists of all  validators and the number of votes they've received.
     */
    function getTotalVotesForEligibleValidators()
    external
    view
    returns (address[] memory validators, uint256[] memory values)
    {
        return votes.total.eligible.getElements();
    }

    /**
     * @notice Returns a list of elected validators with seats allocated to validators via the D'Hondt
     *   method.
     * @return The list of elected validators.
     */
    function electValidatorSigners() external view returns (address[] memory) {
        return electNValidatorSigners(electableValidators.min, electableValidators.max);
    }

    /**
     * @notice Returns a list of elected validators with seats allocated to validators
     * @return The list of elected validators.
     */
    function electNValidatorSigners(uint256 minElectableValidators, uint256 maxElectableValidators)
    public
    view
    returns (address[] memory)
    {
        require(getTotalVotes() > 0, "require TotalVotes > 0");
        // Validators must have at least `electabilityThreshold` proportion of the total votes to be
        // considered for the election.
        uint256 requiredVotes = electabilityThreshold
        .multiply(FixidityLib.newFixed(getTotalVotes()))
        .fromFixed();
        // Only consider validators with at least `requiredVotes` but do not consider more validators than the
        // max number of electable validators.
        uint256 numElectionValidators = votes.total.eligible.numElementsGreaterThan(
            requiredVotes,
            maxElectableValidators
        );
        address[] memory electionValidators = votes.total.eligible.headN(numElectionValidators);
        uint256 totalNumMembersElected = electionValidators.length;
        require(totalNumMembersElected >= minElectableValidators, "Not enough elected validators");

        address[] memory electedValidators = new address[](totalNumMembersElected);
        totalNumMembersElected = 0;
        for (uint256 j = 0; j < electionValidators.length; j = j.add(1)) {
            electedValidators[totalNumMembersElected] = getAccounts().getValidatorSigner(electionValidators[j]);
            totalNumMembersElected = totalNumMembersElected.add(1);
        }
        return electedValidators;
    }


    /**
     * @notice Returns get current validator signers using the precompiles.
     * @return List of current validator signers.
     */
    function getCurrentValidatorSigners() public view returns (address[] memory) {
        uint256 n = numberValidatorsInCurrentSet();
        address[] memory res = new address[](n);
        for (uint256 i = 0; i < n; i = i.add(1)) {
            res[i] = validatorSignerAddressFromCurrentSet(i);
        }
        return res;
    }

    // Struct to hold local variables for `forceDecrementVotes`.
    // Needed to prevent solc error of "stack too deep" from too many local vars.
    struct DecrementVotesInfo {
        address[] validators;
        uint256 remainingValue;
    }

    /**
     * @notice Reduces the total amount of `account`'s voting gold by `value` by
     *         iterating over all validators voted for by account.
     * @param account Address to revoke votes from.
     * @param value Maximum amount of votes to revoke.
     * @param lessers The validators receiving fewer votes than the i'th `validator`, or 0 if
     *                the i'th `validator` has the fewest votes of any validator.
     * @param greaters The validators receivier more votes than the i'th `validator`, or 0 if
     *                the i'th `validator` has the most votes of any validator.
     * @param indices The indices of the i'th validator in the account's voting list.
     * @return Number of votes successfully decremented.
     */
    function forceDecrementVotes(
        address account,
        uint256 value,
        address[] calldata lessers,
        address[] calldata greaters,
        uint256[] calldata indices
    ) external nonReentrant onlyRegisteredContract(LOCKED_GOLD_REGISTRY_ID) returns (uint256) {
        require(value > 0, "Decrement value must be greater than 0.");
        DecrementVotesInfo memory info = DecrementVotesInfo(votes.validatorsVotedFor[account], value);
        require(
            lessers.length <= info.validators.length &&
            lessers.length == greaters.length &&
            greaters.length == indices.length,
            "Input lengths must be correspond."
        );
        // Iterate in reverse order to hopefully optimize removing pending votes before active votes
        // And to attempt to preserve `account`'s earliest votes (assuming earliest = prefered)
        for (uint256 i = info.validators.length; i > 0; i = i.sub(1)) {
            info.remainingValue = info.remainingValue.sub(
                _decrementVotes(
                    account,
                    info.validators[i.sub(1)],
                    info.remainingValue,
                    lessers[i.sub(1)],
                    greaters[i.sub(1)],
                    indices[i.sub(1)]
                )
            );
            if (info.remainingValue == 0) {
                break;
            }
        }
        require(info.remainingValue == 0, "Failure to decrement all votes.");
        return value;
    }


    /**
         * @notice Returns the active votes for `validator` made by `account`.
         * @param validator The address of the validator.
         * @param account The address of the voting account.
         * @return The active votes for `validator` made by `account`.
     */
    function getActiveVotesForValidatorByAccount(address validator, address account)
    public
    view
    returns (uint256)
    {
        return unitsToVotes(validator, votes.active.forValidator[validator].unitsByAccount[account]);
    }

    /**
     * @notice Returns the number of units corresponding to `value` active votes.
     * @param validator The address of the validator.
     * @param value The number of active votes.
     * @return The corresponding number of units.
     */
    function votesToUnits(address validator, uint256 value) private view returns (uint256) {
        if (votes.active.forValidator[validator].totalUnits == 0) {
            return value.mul(UNIT_PRECISION_FACTOR);
        } else {
            return
            value.mul(votes.active.forValidator[validator].totalUnits).div(votes.active.forValidator[validator].total);
        }
    }

    /**
     * @notice Returns the number of active votes corresponding to `value` units.
     * @param validator The address of the validator.
     * @param value The number of units.
     * @return The corresponding number of active votes.
     */
    function unitsToVotes(address validator, uint256 value) private view returns (uint256) {
        if (votes.active.forValidator[validator].totalUnits == 0) {
            return 0;
        } else {
            return
            value.mul(votes.active.forValidator[validator].total).div(votes.active.forValidator[validator].totalUnits);
        }
    }


    function activeAllPending(address[] calldata validators)
    external
    nonReentrant
    onlyVm
    returns (bool)
    {
        for (uint256 i = 0; i < validators.length; i = i.add(1)) {
            _activeAllPending(validators[i]);
        }
        return true;
    }

    function _activeAllPending(address validator) internal returns (bool) {
        address[] memory voters = votes.pending.forValidator[validator].voters;
        for (uint256 i = 0; i < voters.length; i = i.add(1)) {
            address account = voters[i];
            PendingVote memory pendingVote = votes.pending.forValidator[validator].byAccount[account];
            uint256 value = pendingVote.value;
            decrementPendingVotes(validator, account, value);
            incrementActiveVotes(validator, account, value);
            emit ValidatorVoteActivated(account, validator, value);
        }
        delete votes.pending.forValidator[validator].voters; //clear voters
        return true;
    }


}




