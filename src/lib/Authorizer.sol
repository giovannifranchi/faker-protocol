// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;


abstract contract Authorizer {

    error Unauthorized();
    error AlreadyAuthorized();
    error NotYetAuthorized();

    event AuthorizationGranted(address indexed user);

    event AuthorizationRevoked(address indexed user);

    mapping(address user => bool authorized) public isAuthorized;

    modifier authorized() {
        if (!isAuthorized[msg.sender]) revert Unauthorized();
        _;
    }

    constructor() {
        isAuthorized[msg.sender] = true;
        emit AuthorizationGranted(msg.sender);
    }

    function _grantAuthotization(address user) internal authorized {
        if (isAuthorized[user]) revert AlreadyAuthorized();
        isAuthorized[user] = true;
        emit AuthorizationGranted(user);
    }

    function _revokeAuthorization(address user) internal authorized {
        if (!isAuthorized[user]) revert NotYetAuthorized();
        isAuthorized[user] = false;
        emit AuthorizationRevoked(user);
    }

}