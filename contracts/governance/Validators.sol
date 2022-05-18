pragma solidity ^0.5.13;
pragma experimental ABIEncoderV2;

import "openzeppelin-solidity/contracts/math/Math.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";

import "./interfaces/IValidators.sol";

import "../common/CalledByVm.sol";
import "../common/Initializable.sol";
import "../common/FixidityLib.sol";
import "../common/linkedlists/AddressLinkedList.sol";
import "../common/UsingRegistry.sol";
import "../common/UsingPrecompiles.sol";
import "../common/interfaces/IMapVersionedContract.sol";
import "../common/libraries/ReentrancyGuard.sol";

/**
 * @title A contract for registering and electing  Validators.
 */
contract Validators is
IValidators,
IMapVersionedContract,
Ownable,
ReentrancyGuard,
Initializable,
UsingRegistry,
UsingPrecompiles,
CalledByVm
{
    using FixidityLib for FixidityLib.Fraction;
    using AddressLinkedList for LinkedList.List;
    using SafeMath for uint256;
    using BytesLib for bytes;

    // For Validators, these requirements must be met in order to:
    //   1. Register a validator
    //   2. Receive epoch payments (the validator must meet the validator requirements )
    // Accounts may de-register  after their Validator `duration` seconds
    // after which no restrictions on Locked Gold will apply to the account.
    struct LockedGoldRequirements {
        uint256 value;
        // In seconds.
        uint256 duration;
    }

    struct SlashingInfo {
        FixidityLib.Fraction multiplier;
        uint256 lastSlashed;
    }

    struct PublicKeys {
        bytes ecdsa;
        bytes bls;
        bytes blsG1;
    }

    struct Validator {
        PublicKeys publicKeys;
        FixidityLib.Fraction score;

        //----- New changes -----
        FixidityLib.Fraction commission;
        FixidityLib.Fraction nextCommission;
        uint256 nextCommissionBlock;
        SlashingInfo slashInfo;
        uint256 registerTimestamp;
    }


    // Parameters that govern the calculation of validator's score.
    struct ValidatorScoreParameters {
        uint256 exponent;
        FixidityLib.Fraction adjustmentSpeed;
    }

    mapping(address => Validator) private validators;
    address[] private registeredValidators;
    address[] private deregisterValidators;

    LockedGoldRequirements public validatorLockedGoldRequirements;
    ValidatorScoreParameters private validatorScoreParameters;
    // The number of blocks to delay a Validator's commission update
    uint256 public commissionUpdateDelay;
    uint256 public slashingMultiplierResetPeriod;
    uint256 public downtimeGracePeriod;
    FixidityLib.Fraction public pledgeMultiplierInReward; //Proportion of pledge in reward   >0   <FIXED1_UINT

    event CommissionUpdateDelaySet(uint256 delay);
    event PledgeMultiplierInRewardSet(uint256 delay);
    event ValidatorScoreParametersSet(uint256 exponent, uint256 adjustmentSpeed);
    event ValidatorLockedGoldRequirementsSet(uint256 value, uint256 duration);
    event ValidatorRegistered(address indexed validator, uint256  indexed commission);
    event ValidatorDeregistered(address indexed validator);
    event ValidatorPreDeregistered(address indexed validator);
    event ValidatorEcdsaPublicKeyUpdated(address indexed validator, bytes ecdsaPublicKey);
    event ValidatorBlsPublicKeyUpdated(address indexed validator, bytes blsPublicKey);
    event ValidatorScoreUpdated(address indexed validator, uint256 score, uint256 epochScore);


    event ValidatorCommissionUpdateQueued(
        address indexed validator,
        uint256 commission,
        uint256 activationBlock
    );
    event ValidatorCommissionUpdated(address indexed validator, uint256 commission);
    event ValidatorEpochPaymentDistributed(
        address indexed validator,
        uint256 validatorPayment
    );

    modifier onlySlasher() {
        require(getLockedGold().isSlasher(msg.sender), "Only registered slasher can call");
        _;
    }

    /**
     * @notice Returns the storage, major, minor, and patch version of the contract.
     * @return The storage, major, minor, and patch version of the contract.
     */
    function getVersionNumber() external pure returns (uint256, uint256, uint256, uint256) {
        return (1, 2, 0, 2);
    }

    /**
     * @notice Sets initialized == true on implementation contracts
     * @param test Set to true to skip implementation initialization
     */
    constructor(bool test) public Initializable(test) {}

    /**
     * @notice Used in place of the constructor to allow the contract to be upgradable via proxy.
     * @param registryAddress The address of the registry core smart contract.
     * @param validatorRequirementValue The Locked Gold requirement amount for validators.
     * @param validatorRequirementDuration The Locked Gold requirement duration for validators.
     * @param validatorRequirementValue The Locked Gold requirement amount for validators.
     * @param validatorRequirementDuration The Locked Gold requirement duration for validators.
     * @param validatorScoreExponent The exponent used in calculating validator scores.
     * @param validatorScoreAdjustmentSpeed The speed at which validator scores are adjusted.
     * @param _commissionUpdateDelay The number of blocks to delay a ValidatorValidator's commission
     * update.
     * @dev Should be called only once.
     */
    function initialize(
        address registryAddress,
        uint256 validatorRequirementValue,
        uint256 validatorRequirementDuration,
        uint256 validatorScoreExponent,
        uint256 validatorScoreAdjustmentSpeed,
        uint256 _slashingMultiplierResetPeriod,
        uint256 _commissionUpdateDelay,
        uint256 _pledgeMultiplierInReward,
        uint256 _downtimeGracePeriod
    ) external initializer {
        _transferOwnership(msg.sender);
        setRegistry(registryAddress);
        setValidatorLockedGoldRequirements(validatorRequirementValue, validatorRequirementDuration);
        setValidatorScoreParameters(validatorScoreExponent, validatorScoreAdjustmentSpeed);
        setCommissionUpdateDelay(_commissionUpdateDelay);
        setPledgeMultiplierInReward(_pledgeMultiplierInReward);
        setSlashingMultiplierResetPeriod(_slashingMultiplierResetPeriod);
        setDowntimeGracePeriod(_downtimeGracePeriod);
    }

    /**
     * @notice Updates the block delay for a Validator's commission udpdate
     * @param delay Number of blocks to delay the update
     */
    function setCommissionUpdateDelay(uint256 delay) public onlyOwner {
        require(delay != commissionUpdateDelay, "commission update delay not changed");
        commissionUpdateDelay = delay;
        emit CommissionUpdateDelaySet(delay);
    }

    /**
     * @notice Updates the block delay for Proportion of pledge in reward
     * @param pledgeMultiplier Number of blocks to delay the update
     */
    function setPledgeMultiplierInReward(uint256 pledgeMultiplier) public onlyOwner {
        require(!FixidityLib.wrap(pledgeMultiplier).equals(pledgeMultiplierInReward), "Proportion of pledge in reward update delay not changed");
        pledgeMultiplierInReward = FixidityLib.wrap(pledgeMultiplier);
        emit PledgeMultiplierInRewardSet(pledgeMultiplier);
    }

    /**
     * @notice Updates the validator score parameters.
     * @param exponent The exponent used in calculating the score.
     * @param adjustmentSpeed The speed at which the score is adjusted.
     * @return True upon success.
     */
    function setValidatorScoreParameters(uint256 exponent, uint256 adjustmentSpeed)
    public
    onlyOwner
    returns (bool)
    {
        require(
            adjustmentSpeed <= FixidityLib.fixed1().unwrap(),
            "Adjustment speed cannot be larger than 1"
        );
        require(
            exponent != validatorScoreParameters.exponent ||
            !FixidityLib.wrap(adjustmentSpeed).equals(validatorScoreParameters.adjustmentSpeed),
            "Adjustment speed and exponent not changed"
        );
        validatorScoreParameters = ValidatorScoreParameters(
            exponent,
            FixidityLib.wrap(adjustmentSpeed)
        );
        emit ValidatorScoreParametersSet(exponent, adjustmentSpeed);
        return true;
    }



    /**
     * @notice Returns the block delay for a Validator's commission udpdate.
     * @return The block delay for a ValidatorValidator's commission udpdate.
     */
    function getCommissionUpdateDelay() external view returns (uint256) {
        return commissionUpdateDelay;
    }

    /**
     * @notice Returns the block delay for Validator's Proportion of pledge in reward.
     * @return The block delay for a Validator's Proportion of pledge in reward.
     */
    function getPledgeMultiplierInReward() external view returns (uint256) {
        return pledgeMultiplierInReward.unwrap();
    }

    /**
     * @notice Updates the Locked Gold requirements for Validators.
     * @param value The amount of Locked Gold required.
     * @param duration The time (in seconds) that these requirements persist for.
     * @return True upon success.
     */
    function setValidatorLockedGoldRequirements(uint256 value, uint256 duration)
    public
    onlyOwner
    returns (bool)
    {
        LockedGoldRequirements storage requirements = validatorLockedGoldRequirements;
        require(
            value != requirements.value || duration != requirements.duration,
            "Validator requirements not changed"
        );
        validatorLockedGoldRequirements = LockedGoldRequirements(value, duration);
        emit ValidatorLockedGoldRequirementsSet(value, duration);
        return true;
    }

    /**
     * @notice Registers a validator
     * @param blsBlsG1BlsPopEcdsaPub contain 4 params
            blsBlsG1BlsPopEcdsaPub[0] = bytes memory blsPublicKey,
            blsBlsG1BlsPopEcdsaPub[1] = bytes memory blsG1PubKey,
            blsBlsG1BlsPopEcdsaPub[2] = bytes memory blsPop,
            blsBlsG1BlsPopEcdsaPub[3] = bytes memory ecdsaPublicKey,
     * @return True upon success.
     * @dev Fails if the account is already a validator or  validator.
     * @dev Fails if the account does not have sufficient Locked Gold.
     */
    function registerValidator(
        uint256 commission,
        address lesser,
        address greater,
        bytes[] calldata blsBlsG1BlsPopEcdsaPub
    ) external nonReentrant returns (bool) {
        require(blsBlsG1BlsPopEcdsaPub.length == 4, "wrong params");
        FixidityLib.Fraction memory newCommission = FixidityLib.newFixed(commission).divide(FixidityLib.newFixed(1000000));
        uint256 newCommissionWrap = newCommission.unwrap();
        require(newCommissionWrap <= FixidityLib.fixed1().unwrap(), "Commission can't be greater than 100%");
        address account = getAccounts().validatorSignerToAccount(msg.sender);
        require(!isValidator(account), "Already registered");
        Validator storage validator = validators[account];
        address signer = getAccounts().getValidatorSigner(account);
        require(
            _updateEcdsaPublicKey(validator, account, signer, blsBlsG1BlsPopEcdsaPub[3]),
            "Error updating ECDSA public key"
        );
        require(
            _updateBlsPublicKey(validator, account, blsBlsG1BlsPopEcdsaPub[0], blsBlsG1BlsPopEcdsaPub[1], blsBlsG1BlsPopEcdsaPub[2]),
            "Error updating BLS public key"
        );
        uint256 lockedGoldBalance = getLockedGold().getAccountTotalLockedGold(account);
        require(lockedGoldBalance >= validatorLockedGoldRequirements.value, "Deposit too small");
        require(validators[account].publicKeys.bls.length > 0, "no have blsPublicKey");

        registeredValidators.push(account);
        //------------ New changes -------
        validator.commission = newCommission;
        validator.slashInfo = SlashingInfo(FixidityLib.fixed1(), 0);
        emit ValidatorRegistered(account, newCommissionWrap);
        validator.registerTimestamp = now;
        getElection().markValidatorEligible(lesser, greater, account);
        return true;
    }

    function revertRegisterValidator() external returns (bool) {
        address account = getAccounts().validatorSignerToAccount(msg.sender);
        require(isValidator(account), "account not a pending deRegister Validator");
        for (uint256 i=0; i<deregisterValidators.length;i=i.add(1)){
            if (deregisterValidators[i] == account){
                deleteElement(deregisterValidators, account, i);
               return true;
            }
        }
        return false;
    }

    function isPendingDeRegisterValidator() external view returns (bool) {
        address account = getAccounts().validatorSignerToAccount(msg.sender);
        for (uint256 i=0; i<deregisterValidators.length;i=i.add(1)){
            if (deregisterValidators[i] == account){
                return true;
            }
        }
        return false;
    }


    /**
     * @notice Returns the parameters that govern how a validator's score is calculated.
     * @return The parameters that goven how a validator's score is calculated.
     */
    function getValidatorScoreParameters() external view returns (uint256, uint256) {
        return (validatorScoreParameters.exponent, validatorScoreParameters.adjustmentSpeed.unwrap());
    }


    /**
     * @notice Calculates the validator score for an epoch from the uptime value for the epoch.
     * @param uptime The Fixidity representation of the validator's uptime, between 0 and 1.
     * @dev epoch_score = uptime ** exponent
     * @return Fixidity representation of the epoch score between 0 and 1.
     */
    function calculateEpochScore(uint256 uptime) public view returns (uint256) {
        require(uptime <= FixidityLib.fixed1().unwrap(), "Uptime cannot be larger than one");
        uint256 numerator;
        uint256 denominator;
        uptime = Math.min(uptime.add(downtimeGracePeriod), FixidityLib.fixed1().unwrap());
        (numerator, denominator) = fractionMulExp(
            FixidityLib.fixed1().unwrap(),
            FixidityLib.fixed1().unwrap(),
            uptime,
            FixidityLib.fixed1().unwrap(),
            validatorScoreParameters.exponent,
            18
        );
        return FixidityLib.newFixedFraction(numerator, denominator).unwrap();
    }

    /**
     * @notice Updates a validator's score based on its uptime for the epoch.
     * @param signer The validator signer of the validator account whose score needs updating.
     * @param uptime The Fixidity representation of the validator's uptime, between 0 and 1.
     * @return True upon success.
     */
    function updateValidatorScoreFromSigner(address signer, uint256 uptime) external onlyVm() returns (uint256, bool){
        return _updateValidatorScoreFromSigner(signer, uptime);
    }

    /**
     * @notice Updates a validator's score based on its uptime for the epoch.
     * @param signer The validator signer of the validator whose score needs updating.
     * @param uptime The Fixidity representation of the validator's uptime, between 0 and 1.
     * @dev new_score = uptime ** exponent * adjustmentSpeed + old_score * (1 - adjustmentSpeed)
     * @return True upon success.
     */
    function _updateValidatorScoreFromSigner(address signer, uint256 uptime) internal returns (uint256, bool) {
        address account = getAccounts().signerToAccount(signer);
        //        require(isValidator(account), "Not a validator");
        if (isValidator(account)) {
            FixidityLib.Fraction memory epochScore = FixidityLib.wrap(calculateEpochScore(uptime));
            FixidityLib.Fraction memory newComponent = validatorScoreParameters.adjustmentSpeed.multiply(
                epochScore
            );

            FixidityLib.Fraction memory currentComponent = FixidityLib.fixed1().subtract(
                validatorScoreParameters.adjustmentSpeed
            );
            currentComponent = currentComponent.multiply(validators[account].score);
            validators[account].score = FixidityLib.wrap(
                Math.min(epochScore.unwrap(), newComponent.add(currentComponent).unwrap())
            );
            emit ValidatorScoreUpdated(account, validators[account].score.unwrap(), epochScore.unwrap());
            return (validators[account].score.unwrap(), true);
        }
        return (0, false);
    }

    /**
     * @notice Distributes epoch payments to the account associated with `signer` and its validator.
     * @param signer The validator signer of the account to distribute the epoch payment to.
     * @param maxPayment The maximum payment to the validator. Actual payment is based on score and
     *   validator commission.
     * @return The total payment paid to the validator and voters.
     */
    function distributeEpochPaymentsFromSigner(address signer, uint256 maxPayment, uint256 totalScores)
    external
    onlyVm()
    returns (uint256, uint256)
    {
        return _distributeEpochPaymentsFromSigner(signer, maxPayment, totalScores);
    }

    /**
     * @notice Distributes epoch payments to the account associated with `signer` and its validator.
     * @param signer The validator signer of the validator to distribute the epoch payment to.
     * @param maxPayment The maximum payment to the validator. Actual payment is based on score and
     *   validator commission.
     * @return The total payment paid to the validator and voters.
     */
    function _distributeEpochPaymentsFromSigner(address signer, uint256 maxPayment, uint256 totalScores)
    internal
    returns (uint256, uint256)
    {
        address account = getAccounts().signerToAccount(signer);
        if (isValidator(account)) {
            require(account != address(0), "Validator not registered with a validator");
            // Both the validator and the validator must maintain the minimum locked gold balance in order to
            // receive epoch payments.
            if (meetsAccountLockedGoldRequirements(account)) {
                FixidityLib.Fraction memory totalPayment = FixidityLib.newFixed(maxPayment);
                // maxPayment * score * multiplier
                //totalScores = (N*p+s1+s2+s3...)
                //totalPaymentMultiplier = (score + p) / totalScores
                FixidityLib.Fraction memory totalPaymentMultiplier =
                validators[account].score.add(pledgeMultiplierInReward)
                .divide(FixidityLib.wrap(totalScores));

                totalPayment = totalPayment.multiply(totalPaymentMultiplier);
                //                 .multiply(validators[account].slashInfo.multiplier); //todo slash

                uint256 validatorCommission =
                totalPayment
                .multiply(validators[account].commission).fromFixed();

                uint256 remainPayment = totalPayment.fromFixed().sub(validatorCommission);
                //----------------- validator -----------------
                require(getGoldToken2().mint(account, validatorCommission), "mint failed to validator account");

                emit ValidatorEpochPaymentDistributed(account, validatorCommission);
                return (totalPayment.fromFixed(), remainPayment);
            } else {
                return (0, 0);
            }
        } else {
            return (0, 0);
        }
    }






    /**
     * @notice De-registers a validator.
     * @return True upon success.
     * @dev Fails if the account is not a validator.
     * @dev Fails if the validator has been a member of a validator too recently.
     */
    function deregisterValidator() external nonReentrant returns (bool) {
        address account = getAccounts().validatorSignerToAccount(msg.sender);
        require(isValidator(account), "Not a validator");

        // Require that the validator has not been a member of a validator for
        // `validatorLockedGoldRequirements.duration` seconds.
        Validator storage validator = validators[account];
        uint256 requirementEndTime = validator.registerTimestamp.add(
            validatorLockedGoldRequirements.duration
        );
        require(requirementEndTime < now, "Not yet requirement end time");

        deregisterValidators.push(account);
        emit ValidatorPreDeregistered(account);
        //        //Marks a validator ineligible for electing validators.
        //        //Will not participate in validation
        //        getElection().markValidatorIneligible(account);
        //        // Remove the validator.
        //        deleteElement(registeredValidators, account, index);
        //        delete validators[account];
        //        emit ValidatorDeregistered(account);
        return true;
    }


    function deRegisterAllValidatorsInPending()
    external
    nonReentrant
    onlyVm
    returns (address[] memory)
    {
         for (uint256 i = 0; i < deregisterValidators.length; i = i.add(1)){
             for (uint256 j = 0; j < registeredValidators.length; j = j.add(1)) {
                 if (deregisterValidators[i] ==registeredValidators[j]){
                     deleteElement(registeredValidators, deregisterValidators[i], j);
                     //Marks a validator ineligible for electing validators.
                     //Will not participate in validation
                     getElection().markValidatorIneligible(deregisterValidators[i]);
                     delete validators[deregisterValidators[i]];
                     emit ValidatorDeregistered(deregisterValidators[i]);
                     break;
                 }
             }
         }
         delete deregisterValidators;
         return registeredValidators;
    }





    /**
     * @notice Updates a validator's BLS key.
     * @param blsPublicKey The BLS public key that the validator is using for consensus, should pass
     *   proof of possession. 48 bytes.
     * @param blsPop The BLS public key proof-of-possession, which consists of a signature on the
     *   account address. 48 bytes.
     * @return True upon success.
     */
    function updateBlsPublicKey(bytes calldata blsPublicKey, bytes calldata blsG1PublicKey, bytes calldata blsPop)
    external
    returns (bool)
    {
        address account = getAccounts().validatorSignerToAccount(msg.sender);
        require(isValidator(account), "Not a validator");
        Validator storage validator = validators[account];
        require(
            _updateBlsPublicKey(validator, account, blsPublicKey, blsG1PublicKey, blsPop),
            "Error updating BLS public key"
        );
        return true;
    }

    /**
     * @notice Updates a validator's BLS key.
     * @param validator The validator whose BLS public key should be updated.
     * @param account The address under which the validator is registered.
     * @param blsPublicKey The BLS public key that the validator is using for consensus, should pass
     *   proof of possession. 96 bytes.
     * @param blsPop The BLS public key proof-of-possession, which consists of a signature on the
     *   account address. 48 bytes.
     * @return True upon success.
     */
    function _updateBlsPublicKey(
        Validator storage validator,
        address account,
        bytes memory blsPublicKey,
        bytes memory blsG1PubKey,
        bytes memory blsPop
    ) private returns (bool) {
        require(blsG1PubKey.length == 64, "Wrong blsG1 public key length");
        require(blsPublicKey.length == 128, "Wrong BLS public key length");
        require(blsPop.length == 64, "Wrong BLS PoP length");
        require(checkProofOfPossession(account, blsPublicKey, blsG1PubKey, blsPop), "Invalid BLS PoP");
        validator.publicKeys.bls = blsPublicKey;
        validator.publicKeys.blsG1 = blsG1PubKey;
        emit ValidatorBlsPublicKeyUpdated(account, blsPublicKey);
        return true;
    }

    /**
     * @notice Updates a validator's ECDSA key.
     * @param account The address under which the validator is registered.
     * @param signer The address which the validator is using to sign consensus messages.
     * @param ecdsaPublicKey The ECDSA public key corresponding to `signer`.
     * @return True upon success.
     */
    function updateEcdsaPublicKey(address account, address signer, bytes calldata ecdsaPublicKey)
    external
    onlyRegisteredContract(ACCOUNTS_REGISTRY_ID)
    returns (bool)
    {
        require(isValidator(account), "Not a validator");
        Validator storage validator = validators[account];
        require(
            _updateEcdsaPublicKey(validator, account, signer, ecdsaPublicKey),
            "Error updating ECDSA public key"
        );
        return true;
    }

    /**
     * @notice Updates a validator's ECDSA key.
     * @param validator The validator whose ECDSA public key should be updated.
     * @param signer The address with which the validator is signing consensus messages.
     * @param ecdsaPublicKey The ECDSA public key that the validator is using for consensus. Should
     *   match `signer`. 64 bytes.
     * @return True upon success.
     */
    function _updateEcdsaPublicKey(
        Validator storage validator,
        address account,
        address signer,
        bytes memory ecdsaPublicKey
    ) private returns (bool) {
        require(ecdsaPublicKey.length == 64, "Wrong ECDSA public key length");
        require(
            address(uint160(uint256(keccak256(ecdsaPublicKey)))) == signer,
            "ECDSA key does not match signer"
        );
        validator.publicKeys.ecdsa = ecdsaPublicKey;
        emit ValidatorEcdsaPublicKeyUpdated(account, ecdsaPublicKey);
        return true;
    }

    /**
     * @notice Updates a validator's ECDSA and BLS keys.
     * @param account The address under which the validator is registered.
     * @param signer The address which the validator is using to sign consensus messages.
     * @param ecdsaPublicKey The ECDSA public key corresponding to `signer`.
     * @param blsPublicKey The BLS public key that the validator is using for consensus, should pass
     *   proof of possession. 96 bytes.
     * @param blsPop The BLS public key proof-of-possession, which consists of a signature on the
     *   account address. 48 bytes.
     * @return True upon success.
     */
    function updatePublicKeys(
        address account,
        address signer,
        bytes calldata ecdsaPublicKey,
        bytes calldata blsPublicKey,
        bytes calldata blsG1PublicKey,
        bytes calldata blsPop
    ) external onlyRegisteredContract(ACCOUNTS_REGISTRY_ID) returns (bool) {
        require(isValidator(account), "Not a validator");
        Validator storage validator = validators[account];
        require(
            _updateEcdsaPublicKey(validator, account, signer, ecdsaPublicKey),
            "Error updating ECDSA public key"
        );
        require(
            _updateBlsPublicKey(validator, account, blsPublicKey, blsG1PublicKey, blsPop),
            "Error updating BLS public key"
        );
        return true;
    }


    /**
     * @notice Queues an update to a validator's commission.
     * If there was a previously scheduled update, that is overwritten.
     * @param commission Fixidity representation of the commission this validator receives on epoch
     *   payments made to its members. Must be in the range [0, 1.0].
     */
    function setNextCommissionUpdate(uint256 commission) external {
        address account = getAccounts().validatorSignerToAccount(msg.sender);
        require(isValidator(account), "Not a validator");
        Validator storage validator = validators[account];
        FixidityLib.Fraction memory newCommission = FixidityLib.newFixed(commission).divide(FixidityLib.newFixed(1000000));
        uint256 newCommissionUnwrap = newCommission.unwrap();
        require(newCommissionUnwrap <= FixidityLib.fixed1().unwrap(), "Commission can't be greater than 100%");
        require(newCommissionUnwrap != validator.commission.unwrap(), "Commission must be different");

        validator.nextCommission = newCommission;
        validator.nextCommissionBlock = block.number.add(commissionUpdateDelay);
        emit ValidatorCommissionUpdateQueued(account, newCommissionUnwrap, validator.nextCommissionBlock);
    }
    /**
     * @notice Updates a validator's commission based on the previously queued update
     */
    function updateCommission() external {
        address account = getAccounts().validatorSignerToAccount(msg.sender);
        require(isValidator(account), "Not a validator");
        Validator storage validator = validators[account];

        require(validator.nextCommissionBlock != 0, "No commission update queued");
        require(validator.nextCommissionBlock <= block.number, "Can't apply commission update yet");

        validator.commission = validator.nextCommission;
        delete validator.nextCommission;
        delete validator.nextCommissionBlock;
        emit ValidatorCommissionUpdated(account, validator.commission.unwrap());
    }

    /**
     * @notice Returns the current locked gold balance requirement for the supplied account.
     * @param account The account that may have to meet locked gold balance requirements.
     * @return The current locked gold balance requirement for the supplied account.
     */
    function getAccountLockedGoldRequirement(address account) public view returns (uint256) {
        if (isValidator(account)) {
            return validatorLockedGoldRequirements.value;
        }
        return 0;
    }

    /**
     * @notice Returns whether or not an account meets its Locked Gold requirements.
     * @param account The address of the account.
     * @return Whether or not an account meets its Locked Gold requirements.
     */
    function meetsAccountLockedGoldRequirements(address account) public view returns (bool) {
        uint256 balance = getLockedGold().getAccountTotalLockedGold(account);
        // Add a bit of "wiggle room" to accommodate the fact that vote activation can result in ~1
        // wei rounding errors. Using 10 as an additional margin of safety.
        return balance.add(10) >= getAccountLockedGoldRequirement(account);
    }

    /**
     * @notice Returns the validator BLS key.
     * @param signer The account that registered the validator or its authorized signing address.
     * @return The validator BLS key.
     */
    function getValidatorBlsPublicKeyFromSigner(address signer)
    external
    view
    returns (bytes memory blsPublicKey)
    {
        address account = getAccounts().signerToAccount(signer);
        require(isValidator(account), "Not a validator");
        return validators[account].publicKeys.bls;
    }
    /**
    * @notice Returns the validator BLS key.
    * @param signer The account that registered the validator or its authorized signing address.
    * @return The validator BLS key.
    */
    function getValidatorBlsG1PublicKeyFromSigner(address signer)
    external
    view
    returns (bytes memory blsG1PublicKey)
    {
        address account = getAccounts().signerToAccount(signer);
        require(isValidator(account), "Not a validator");
        return validators[account].publicKeys.blsG1;
    }
    /**
     * @notice Returns validator information.
     * @param account The account that registered the validator.
     * @return The unpacked validator struct.
     */
    function getValidator(address account)
    public
    view
    returns (
        bytes memory ecdsaPublicKey,
        bytes memory blsPublicKey,
        bytes memory blsG1PublicKey,
        uint256 score,
        address signer,
    //--------- New changes -----
        uint256 commission,
        uint256 nextCommission,
        uint256 nextCommissionBlock,
        uint256 slashMultiplier,
        uint256 lastSlashed
    )
    {
        require(isValidator(account), "Not a validator");
        Validator storage validator = validators[account];
        address addr = getAccounts().getValidatorSigner(account);
        return (
        validator.publicKeys.ecdsa,
        validator.publicKeys.bls,
        validator.publicKeys.blsG1,
        validator.score.unwrap(),
        addr,
        //--------- New changes -----
        validator.commission.unwrap(),
        validator.nextCommission.unwrap(),
        validator.nextCommissionBlock,
        validator.slashInfo.multiplier.unwrap(),
        validator.slashInfo.lastSlashed
        );
    }



    /**
     * @notice Returns the top n validator members for a particular validator.
     * @param n The number of members to return.
     * @return The top n validator members for a particular validator.
     */
    function getTopValidators(uint256 n)
    external
    view
    returns (address[] memory)
    {
        address[] memory topAccounts = getElection().getTopValidators(n);
        address[] memory topValidators = new address[](n);
        for (uint256 i = 0; i < topAccounts.length; i = i.add(1)) {
            topValidators[i] = getAccounts().getValidatorSigner(topAccounts[i]);
        }
        return topValidators;
    }



    /**
     * @notice Returns the number of registered validators.
     * @return The number of registered validators.
     */
    function getNumRegisteredValidators() external view returns (uint256) {
        return registeredValidators.length;
    }

    /**
     * @notice Returns the Locked Gold requirements for validators.
     * @return The Locked Gold requirements for validators.
     */
    function getValidatorLockedGoldRequirements() external view returns (uint256, uint256) {
        return (validatorLockedGoldRequirements.value, validatorLockedGoldRequirements.duration);
    }



    /**
     * @notice Returns the list of registered validator accounts.
     * @return The list of registered validator accounts.
     */
    function getRegisteredValidators() external view returns (address[] memory) {
        return registeredValidators;
    }

    /**
     * @notice Returns the list of signers for the registered validator accounts.
     * @return The list of signers for registered validator accounts.
     */
    function getRegisteredValidatorSigners() external view returns (address[] memory) {
        IAccounts accounts = getAccounts();
        address[] memory signers = new address[](registeredValidators.length);
        for (uint256 i = 0; i < signers.length; i = i.add(1)) {
            signers[i] = accounts.getValidatorSigner(registeredValidators[i]);
        }
        return signers;
    }


    /**
     * @notice Returns whether a particular account has a registered validator.
     * @param account The account.
     * @return Whether a particular address is a registered validator.
     */
    function isValidator(address account) public view returns (bool) {
        return validators[account].publicKeys.bls.length > 0;
    }

    /**
     * @notice Deletes an element from a list of addresses.
     * @param list The list of addresses.
     * @param element The address to delete.
     * @param index The index of `element` in the list.
     */
    function deleteElement(address[] storage list, address element, uint256 index) private {
        require(index < list.length && list[index] == element, "deleteElement: index out of range");
        uint256 lastIndex = list.length.sub(1);
        list[index] = list[lastIndex];
        delete list[lastIndex];
        list.length = lastIndex;
    }


    /**
     * @notice Sets the slashingMultiplierRestPeriod property if called by owner.
     * @param value New reset period for slashing multiplier.
     */
    function setSlashingMultiplierResetPeriod(uint256 value) public nonReentrant onlyOwner {
        slashingMultiplierResetPeriod = value;
    }

    /**
     * @notice Sets the downtimeGracePeriod property if called by owner.
     * @param value New downtime grace period for calculating epoch scores.
     */
    function setDowntimeGracePeriod(uint256 value) public nonReentrant onlyOwner {
        downtimeGracePeriod = value;
    }

    /**
     * @notice Resets a validator's slashing multiplier if it has been >= the reset period since
     *         the last time the validator was slashed.
     */
    function resetSlashingMultiplier() external nonReentrant {
        address account = getAccounts().validatorSignerToAccount(msg.sender);
        require(isValidator(account), "Not a validator");
        Validator storage validator = validators[account];
        require(
            now >= validator.slashInfo.lastSlashed.add(slashingMultiplierResetPeriod),
            "`resetSlashingMultiplier` called before resetPeriod expired"
        );
        validator.slashInfo.multiplier = FixidityLib.fixed1();
    }

    /**
     * @notice Halves the validator's slashing multiplier.
     * @param account The validator being slashed.
     */
    function halveSlashingMultiplier(address account) external nonReentrant onlySlasher {
        require(isValidator(account), "Not a validator");
        Validator storage validator = validators[account];
        validator.slashInfo.multiplier = FixidityLib.wrap(validator.slashInfo.multiplier.unwrap().div(2));
        validator.slashInfo.lastSlashed = now;
    }

    /**
     * @notice Getter for a validator's slashing multiplier.
     * @param account The validator to fetch slashing multiplier for.
     */
    function getValidatorSlashingMultiplier(address account) external view returns (uint256) {
        require(isValidator(account), "Not a validator");
        Validator storage validator = validators[account];
        return validator.slashInfo.multiplier.unwrap();
    }


}
