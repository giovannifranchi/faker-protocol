// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Authorizer} from "./lib/Authorizer.sol";
import {Pauser} from "./lib/Pauser.sol";
import {RAY, RAD, WAD, Math} from "./lib/Math.sol";

contract CDPEngine is Pauser, Authorizer {
    error CDPEngine__NotPositionOperator();
    error CPDEngine__AlreadyPositionOperator();
    error CDPEngine__AlreadyInitialized();
    error CDPEngine__UnrecognizedParameter();
    error CDPEngine__UninitializedCollateral();
    error CDPEngine__MaxDebtExceeded();
    error CDPEngine__PositionNotSafe();
    error CDPEngine__BelowMinDeposit();

    event OperatorGranted(address indexed owner, address indexed operator);
    event OperatorRevoked(address indexed owner, address indexed operator);
    event CollateralParametersSet(bytes32 indexed collateralId, bytes32 indexed what, uint256 value);
    event SystemParametersSet(bytes32 indexed what, uint256 value);
    event CollateralCreditModified(bytes32 indexed collateralId, address indexed user, int256 indexed amount);
    event CollateralCreditTransferred(
        bytes32 indexed collateralId, address indexed from, address indexed to, uint256 amount
    );
    event CoinsTransferred(address indexed from, address indexed to, uint256 indexed amount);

    // Ilk
    struct CollateralInfo {
        uint256 debt; // Art [wad] 10^18 - total normalised debt for a collateral type
        uint256 accumulatedRate; // rate [ray] 10^27 - rate accumulated [ray] 10^27
        uint256 safetyPrice; // spot [ray] 10^27 - it is the price in dai for a unit of collateral (safety because has margin for liquidation)
        uint256 maxDebt; // line [rad] 10^45 - max debt allowed for a collateral type
        uint256 minDeposit; // dust [rad] 10^45 - min deposit allowed for a collateral type in order to open a new CDP, it used to prevent low value CDPs that would not be profitable to liquidate
    }

    // urn
    struct UserPosition {
        uint256 depositedCollateral; // ink [wad] 10^18 - total amount of collateral deposited by the user
        uint256 debt; // art [wad] 10^18 - total amount of dai borrowed by the user
    }

    mapping(bytes32 collaterId => CollateralInfo) public collaterals; // Ilks
    mapping(bytes32 collateralId => mapping(address user => UserPosition)) public userPositions; // urns
    mapping(bytes32 collateralID => mapping(address user => uint256 amount)) public userCollateralCredit; // gem - [wad] it tracks the amount of collateral a user has deposited in the system which is not used in any position
    mapping(address user => uint256 coins) public userCoins; // dai
    mapping(address user => uint256 debt) public userDebt; // sin

    uint256 public totalSystemDebt; // Debt [rad] 10^45 - total debt in the system
    uint256 public unbackedCoins; // Vice [rad] 10^45 - total amount of dai that is not backed by collateral
    uint256 public maxSystemDebt; // Line [rad] 10^45 - max debt allowed in the system

    mapping(address owner => mapping(address admin => bool isAllowed)) public isPositionOperator; // can - can manage a user position

    constructor() {}

    ///////////////////////// Access Control ////////////////////////////

    // Rely
    function grantAuthorization(address user) public authorized whenLive {
        _grantAuthotization(user);
    }
    // Deny

    function revokeAuthorization(address user) public authorized whenLive {
        _revokeAuthorization(user);
    }

    // Hope
    function grantPositionOperator(address operator) public authorized whenLive {
        if (isPositionOperator[msg.sender][operator]) revert CPDEngine__AlreadyPositionOperator();
        isPositionOperator[msg.sender][operator] = true;
        emit OperatorGranted(msg.sender, operator);
    }

    // Nope
    function revokePositionOperator(address operator) public authorized whenLive {
        if (!isPositionOperator[msg.sender][operator]) revert CDPEngine__NotPositionOperator();
        isPositionOperator[msg.sender][operator] = false;
        emit OperatorRevoked(msg.sender, operator);
    }

    // Wish
    function canModifyPosition(address _owner, address _operator) public view returns (bool) {
        return isPositionOperator[_owner][_operator] || _owner == _operator;
    }

    ///////////////////////// Puasable ////////////////////////////

    // cage
    function pause() public authorized whenLive {
        _pause();
    }

    function unpause() public authorized {
        _unpause();
    }

    ///////////////////////// Config Setters ////////////////////////////

    // Init
    function initilizeCollateral(bytes32 _collateralId) external authorized {
        if (collaterals[_collateralId].accumulatedRate != 0) revert CDPEngine__AlreadyInitialized();
        collaterals[_collateralId].accumulatedRate = RAY;
    }

    // File
    function set(bytes32 _what, uint256 _value) external authorized whenLive {
        if (_what == "maxSystemDebt") maxSystemDebt = _value;
        else revert CDPEngine__UnrecognizedParameter();
        emit SystemParametersSet(_what, _value);
    }

    // File
    function set(bytes32 _collateralId, bytes32 _what, uint256 _value) external authorized whenLive {
        if (_what == "debt") collaterals[_collateralId].debt = _value;
        else if (_what == "accumulatedRate") collaterals[_collateralId].accumulatedRate = _value;
        else if (_what == "safetyPrice") collaterals[_collateralId].safetyPrice = _value;
        else if (_what == "maxDebt") collaterals[_collateralId].maxDebt = _value;
        else if (_what == "minDeposit") collaterals[_collateralId].minDeposit = _value;
        else revert CDPEngine__UnrecognizedParameter();
        emit CollateralParametersSet(_collateralId, _what, _value);
    }

    ///////////////////////// System ////////////////////////////

    /**
     * Fungibility ********************************
     */

    // Slip - modify collateral credit of a user
    /**
     * @notice Modify collateral credit of a user from one collateral type to another
     * @param _collateralId The collateral
     * @param _user The user whose credit will be moved
     * @param _amount The amount of credit to be moved [wad]
     * @notice _amount is negative when deducting credit and positive when adding credit
     * @notice This function can only be called by GemJoin which is the entry point for collateral deposits and withdrawals
     */
    function modifyCollateralCredit(bytes32 _collateralId, address _user, int256 _amount) external authorized {
        userCollateralCredit[_collateralId][_user] = Math.add(userCollateralCredit[_collateralId][_user], _amount);
        emit CollateralCreditModified(_collateralId, _user, _amount);
    }

    // Flux - Trasfer collateral credit from one user to another
    /**
     * @notice Transfer collateral credit from one user to another
     * @param _collateralId The collateral type
     * @param _from The user from whom the credit will be moved
     * @param _to The user to whom the credit will be moved
     * @param _amount The amount of credit to be moved [wad]
     */
    function transferCollateralCredit(bytes32 _collateralId, address _from, address _to, uint256 _amount) external {
        if (!canModifyPosition(_from, msg.sender)) revert CDPEngine__NotPositionOperator();
        userCollateralCredit[_collateralId][_from] -= _amount;
        userCollateralCredit[_collateralId][_to] += _amount;
        emit CollateralCreditTransferred(_collateralId, _from, _to, _amount);
    }

    // Move - Transfer coin interanl balance from one user to another
    /**
     * @notice Transfer coins from one user to another
     * @param _from The user from whom the coins will be moved
     * @param _to The user to whom the coins will be moved
     * @param _amount The amount of coins to be moved [rad]
     */
    function transferCoins(address _from, address _to, uint256 _amount) external {
        if (!canModifyPosition(_from, msg.sender)) revert CDPEngine__NotPositionOperator();
        userCoins[_from] -= _amount;
        userCoins[_to] += _amount;
        emit CoinsTransferred(_from, _to, _amount);
    }

    /**
     * CDP Manipulation ********************************
     */

    // Frob - Deposit or withdraw collateral and generate or repay debt

    function modifyPoistion(
        bytes32 _collateralId,
        address _positionOwner,
        address _collateralCreditOwner,
        address _coinsReceiver,
        int256 _collateralDelta,
        int256 _debtDelta
    ) external whenLive {
        UserPosition memory userPosition = userPositions[_collateralId][_positionOwner];
        CollateralInfo memory collateralInfo = collaterals[_collateralId];

        if (collateralInfo.accumulatedRate == 0) revert CDPEngine__UninitializedCollateral();

        // Update user position and collateral info optimistically
        userPosition.depositedCollateral = Math.add(userPosition.depositedCollateral, _collateralDelta);
        userPosition.debt = Math.add(userPosition.debt, _debtDelta);
        collateralInfo.debt = Math.add(collateralInfo.debt, _debtDelta);

        int256 rateAccumulatorForCollateralDelta = Math.mul(collateralInfo.accumulatedRate, _debtDelta); // @note - check this better
        uint256 newCollateralRateAccumulator = collateralInfo.accumulatedRate * userPosition.debt;
        totalSystemDebt = Math.add(totalSystemDebt, rateAccumulatorForCollateralDelta);

        // Checks for new position
        // Check that debt has not increased or if it has, that the new debt is within the max debt limit
        if (
            _debtDelta > 0
                && (
                    collateralInfo.accumulatedRate * collateralInfo.debt > collateralInfo.maxDebt
                        || totalSystemDebt > maxSystemDebt
                )
        ) revert CDPEngine__MaxDebtExceeded();

        // Check that the new position is safe
        // If collateral has decreased or debt has increased, check that the new position is safe, i.e. the rate accumulator is above the safety price
        if (
            (_collateralDelta < 0 || _debtDelta > 0)
                && newCollateralRateAccumulator > userPosition.depositedCollateral * collateralInfo.safetyPrice
        ) revert CDPEngine__PositionNotSafe();

        // Check that the new position is safe or that the owner allows this change
        if ((_collateralDelta < 0 || _debtDelta > 0) && !canModifyPosition(_positionOwner, msg.sender)) {
            revert CDPEngine__PositionNotSafe();
        }

        // Check that collateral has not been taken without consent
        if (_collateralDelta > 0 && !canModifyPosition(_collateralCreditOwner, msg.sender)) {
            revert CDPEngine__PositionNotSafe();
        }

        if (_debtDelta < 0 && !canModifyPosition(_coinsReceiver, msg.sender)) revert CDPEngine__PositionNotSafe();

        if (userPosition.debt != 0 && newCollateralRateAccumulator < collateralInfo.minDeposit) {
            revert CDPEngine__BelowMinDeposit();
        }

        userCollateralCredit[_collateralId][_collateralCreditOwner] =
            Math.add(userCollateralCredit[_collateralId][_collateralCreditOwner], _collateralDelta);
        userCoins[_coinsReceiver] = Math.add(userCoins[_coinsReceiver], rateAccumulatorForCollateralDelta);

        userPositions[_collateralId][_positionOwner] = userPosition;
        collaterals[_collateralId] = collateralInfo;
    }
}
