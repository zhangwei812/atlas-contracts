pragma solidity ^0.5.13;
pragma experimental ABIEncoderV2;

interface IValidators {
    function registerValidator(uint256 commission, address lesser, address greater,bytes[] calldata blsBlsG1BlsPopEcdsaPub)
    external
    returns (bool);

    function deregisterValidator() external returns (bool);

    function updateBlsPublicKey(bytes calldata,bytes calldata, bytes calldata) external returns (bool);

    function updateCommission() external;

    function setNextCommissionUpdate(uint256) external;

    function resetSlashingMultiplier() external;

    // only owner
    function setCommissionUpdateDelay(uint256) external;

    function setValidatorScoreParameters(uint256, uint256) external returns (bool);

    function setValidatorLockedGoldRequirements(uint256, uint256) external returns (bool);


    function setSlashingMultiplierResetPeriod(uint256) external;

    // view functions
    function getCommissionUpdateDelay() external view returns (uint256);

    function getValidatorScoreParameters() external view returns (uint256, uint256);

    function calculateEpochScore(uint256) external view returns (uint256);
    //  function calculateValidatorEpochScore(uint256[] calldata) external view returns (uint256);
    function getAccountLockedGoldRequirement(address) external view returns (uint256);

    function meetsAccountLockedGoldRequirements(address) external view returns (bool);

    function getValidatorBlsPublicKeyFromSigner(address) external view returns (bytes memory);

    function getValidator(address account)
    external
    view
    returns (bytes memory, bytes memory, bytes memory, uint256, address, uint256, uint256, uint256, uint256, uint256);

    //  function getValidatorNumMembers(address) external view returns (uint256);
    function getTopValidators(uint256) external view returns (address[] memory);

    function getNumRegisteredValidators() external view returns (uint256);

    // only registered contract
    function updateEcdsaPublicKey(address, address, bytes calldata) external returns (bool);

    function updatePublicKeys(address, address, bytes calldata,bytes calldata, bytes calldata, bytes calldata)
    external
    returns (bool);

    function getValidatorLockedGoldRequirements() external view returns (uint256, uint256);


    function getRegisteredValidators() external view returns (address[] memory);

    function getRegisteredValidatorSigners() external view returns (address[] memory);


    function isValidator(address) external view returns (bool);


    function getValidatorSlashingMultiplier(address) external view returns (uint256);

    // only VM
    function updateValidatorScoreFromSigner(address, uint256) external returns (uint256, bool);

    function distributeEpochPaymentsFromSigner(address, uint256, uint256) external returns (uint256,uint256);

    // only slasher
    function halveSlashingMultiplier(address) external;

}
