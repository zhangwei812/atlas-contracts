pragma solidity ^0.5.13;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import "../common/CalledByVm.sol";
import "../common/FixidityLib.sol";
import "../common/Initializable.sol";
import "../common/UsingRegistry.sol";
import "../common/UsingPrecompiles.sol";
import "../common/interfaces/IMapVersionedContract.sol";

/**
 * @title Contract for calculating epoch rewards.
 */
contract EpochRewards is
IMapVersionedContract,
IElectionReward,
Ownable,
Initializable,
UsingPrecompiles,
UsingRegistry,
CalledByVm
{
    using FixidityLib for FixidityLib.Fraction;
    using SafeMath for uint256;

    uint256 public startTime = 0;
    FixidityLib.Fraction private communityRewardFraction;
    address public communityPartner;
    uint256 public epochPayment;
    uint256 public epochRelayerPayment;

    event TargetVotingGoldFractionSet(uint256 fraction);
    event CommunityRewardFundSet(address indexed partner, uint256 fraction);
    event TargetValidatorEpochPaymentSet(uint256 payment);
    event TargetRelayerEpochPaymentSet(uint256 payment);
    event TargetVotingYieldParametersSet(uint256 max, uint256 adjustmentFactor);
    event TargetVotingYieldSet(uint256 target);
    event RewardsMultiplierParametersSet(
        uint256 max,
        uint256 underspendAdjustmentFactor,
        uint256 overspendAdjustmentFactor
    );

    event TargetVotingYieldUpdated(uint256 fraction);

    /**
    * @notice Returns the storage, major, minor, and patch version of the contract.
    * @return The storage, major, minor, and patch version of the contract.
    */
    function getVersionNumber() external pure returns (uint256, uint256, uint256, uint256) {
        return (1, 1, 1, 0);
    }

    /**
     * @notice Sets initialized == true on implementation contracts
     * @param test Set to true to skip implementation initialization
     */
    constructor(bool test) public Initializable(test) {}

    /**
     * @notice Used in place of the constructor to allow the contract to be upgradable via proxy.
     * @param registryAddress The address of the registry contract.
     * @param _targetValidatorEpochPayment The target validator epoch payment.
     * @param _communityRewardFraction The percentage of rewards that go the community funds.
     * @dev Should be called only once.
     */
    function initialize(
        address registryAddress,
        uint256 _targetValidatorEpochPayment,
        uint256 _targetRelayerEpochPayment,
        uint256 _communityRewardFraction,
        address _communityPartner
    ) external initializer {
        _transferOwnership(msg.sender);
        setRegistry(registryAddress);
        setTargetValidatorEpochPayment(_targetValidatorEpochPayment);
        setTargetRelayerEpochPayment(_targetRelayerEpochPayment);
        setCommunityRewardFraction(_communityPartner, _communityRewardFraction);
        startTime = now;
    }


    /**
     * @notice Sets the community reward percentage
     * @param value The percentage of the total reward to be sent to the community funds.
     * @return True upon success.
     */
    function setCommunityRewardFraction(address partner, uint256 value) public onlyOwner returns (bool) {
        require(
            partner != communityPartner || value != communityRewardFraction.unwrap(),
            "Partner and value must be different from existing carbon community fund"
        );
        require(
            value < FixidityLib.fixed1().unwrap(),
            "reward fraction and less than 1"
        );
        require(value < FixidityLib.fixed1().unwrap(), "Value must be less than 1");
        communityPartner = partner;
        communityRewardFraction = FixidityLib.wrap(value);
        emit CommunityRewardFundSet(partner, value);
        return true;
    }

    /**
     * @notice Returns the community reward fraction.
     * @return The percentage of total reward which goes to the community funds.
     */
    function getCommunityRewardFraction() external view returns (uint256) {
        return communityRewardFraction.unwrap();
    }


    /**
     * @notice Sets the target per-epoch payment in MAP  for validators.
     * @param value The value in MAP .
     * @return True upon success.
     */
    function setTargetValidatorEpochPayment(uint256 value) public onlyOwner returns (bool) {
        require(value != epochPayment, "Target validator epoch payment unchanged");
        epochPayment = value;
        emit TargetValidatorEpochPaymentSet(value);
        return true;
    }

    /**
      * @notice Sets the target per-epoch payment in MAP  for Relayer.
      * @param value The value in MAP .
      * @return True upon success.
      */
    function setTargetRelayerEpochPayment(uint256 value) public onlyOwner returns (bool) {
        require(value != epochRelayerPayment, "Target validator epoch payment unchanged");
        epochRelayerPayment = value;
        emit TargetRelayerEpochPaymentSet(value);
        return true;
    }
    /**
     * @notice Returns the total target epoch payments to validators, converted to Gold.
     * @return The total target epoch payments to validators, converted to Gold.
     */
    function getTargetTotalEpochPaymentsInGold() public view returns (uint256) {
        return
        epochPayment;
    }



    function getCommunityPartner() external view returns (address ){
        return communityPartner;
    }





    /**
     * @notice Calculates the per validator epoch payment to validator and the total rewards to community.
     * @return The per validator epoch reward to validator, and the total community  reward.
     */
    function calculateTargetEpochRewards()
    external
    view
    returns (uint256,uint256, uint256)
    {
        uint256 communityFund = FixidityLib
        .newFixed(epochPayment)
        .multiply(communityRewardFraction)
        .fromFixed();
        return (
        epochPayment-communityFund,
        communityFund,
        epochRelayerPayment);
    }
}
