// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Authorizer} from "./lib/Authorizer.sol";
import {Pauser} from "./lib/Pauser.sol";
import {RAY, RAD, WAD} from "./lib/Math.sol";

contract CDPEngine is Pauser, Authorizer {

    error CDPEngine__NotPositionOperator();
    error CPDEngine__AlreadyPositionOperator();
    error CDPEngine__AlreadyInitialized();
    error CDPEngine__UnrecognizedParameter();

    event OperatorGranted(address indexed owner, address indexed operator);
    event OperatorRevoked(address indexed owner, address indexed operator);
    event CollateralParametersSet(bytes32 indexed collateralId, bytes32 indexed what, uint256 value);
    event SystemParametersSet(bytes32 indexed what, uint256 value);

    // Ilk
    struct CollateralInfo {
        uint256 debt; // Art [wad] 10^18 - total normalised debt for a collateral type
        uint256 accumulatedRate;  // rate [ray] 10^27 - rate accumulated [ray] 10^27 
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
    mapping(address user => mapping(bytes32 collateralId => UserPosition)) public userPositions; // urns
    mapping(address user => uint256 coins) public userCoins; // dai
    mapping(address user => uint256 debt) public userDebt; // sin

    uint256 public totalSystemDebt; // Debt [rad] 10^45 - total debt in the system
    uint256 public unbackedCoins; // Vice [rad] 10^45 - total amount of dai that is not backed by collateral
    uint256 public maxSystemDebt; // Line [rad] 10^45 - max debt allowed in the system

    mapping(address owner => mapping(address admin => bool isAllowed)) public isPositionOperator; // can - can manage a user position


    constructor(){

    }

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
        if(isPositionOperator[msg.sender][operator]) revert CPDEngine__AlreadyPositionOperator();
        isPositionOperator[msg.sender][operator] = true;
        emit OperatorGranted(msg.sender, operator);
    }

    // Nope
    function revokePositionOperator(address operator) public authorized whenLive {
        if(!isPositionOperator[msg.sender][operator]) revert CDPEngine__NotPositionOperator();
        isPositionOperator[msg.sender][operator] = false;
        emit OperatorRevoked(msg.sender, operator);
    }

    // Wish
    function canModifyPosition(address _owner, address _operator) public view returns(bool) {
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
        if(collaterals[_collateralId].accumulatedRate != 0) revert CDPEngine__AlreadyInitialized();
        collaterals[_collateralId].accumulatedRate = RAY;
    }

    // File
    function set(bytes32 _what, uint256 _value) external authorized whenLive {
        if(_what == "maxSystemDebt") maxSystemDebt = _value;
        else revert CDPEngine__UnrecognizedParameter();
        emit SystemParametersSet(_what, _value);
    }

    // File
    function set(bytes32 _collateralId, bytes32 _what, uint256 _value) external authorized whenLive {
        if(_what == "debt") collaterals[_collateralId].debt = _value;
        else if(_what == "accumulatedRate") collaterals[_collateralId].accumulatedRate = _value;
        else if(_what == "safetyPrice") collaterals[_collateralId].safetyPrice = _value;
        else if(_what == "maxDebt") collaterals[_collateralId].maxDebt = _value;
        else if(_what == "minDeposit") collaterals[_collateralId].minDeposit = _value;
        else revert CDPEngine__UnrecognizedParameter();
        emit CollateralParametersSet(_collateralId, _what, _value);
    }


    ///////////////////////// System ////////////////////////////
}