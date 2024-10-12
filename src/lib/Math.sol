// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

uint256 constant WAD = 10 ** 18;
uint256 constant RAY = 10 ** 27;
uint256 constant RAD = 10 ** 45;

library Math {
    function add(uint256 x, int256 y) public pure returns (uint256) {
        if (y < 0) return x - uint256(-y);
        else return x + uint256(y);
    }

    function sub(uint256 x, int256 y) public pure returns (uint256) {
        if (y < 0) return x + uint256(-y);
        else return x - uint256(y);
    }

    function mul(uint256 x, int256 y) public pure returns (int256) {
        return int256(x) * y;
    }
}
