// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;


abstract contract Pauser {

    error ContractPaused();
    error ContractLive();

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    bool public isLive;

    modifier whenLive() {
        if(!isLive) revert ContractPaused();
        _;
    }

    constructor() {
        isLive = true;
        emit Unpaused(msg.sender);
    }

    function _pause() internal {
        if(!isLive) revert ContractPaused();
        isLive = false;
        emit Paused(msg.sender);
    }

    function _unpause() internal {
        if(isLive) revert ContractLive();
        isLive = true;
        emit Unpaused(msg.sender);
    }


}