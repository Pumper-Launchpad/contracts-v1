// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PumperToken} from "./PumperToken.sol";

/// @title PumperTokenFactory
/// @notice Exists purely to keep `PumperToken`'s (and its nested
///         `PumperRewardLocker`'s) creation bytecode out of `PumperLaunchpad`'s
///         runtime bytecode. `new PumperToken(...)` inlines the token's full
///         init code -- plus the locker init code the token's constructor
///         itself `new`s -- into whichever contract calls it; doing that
///         directly from the launchpad risks the EIP-170 24KB runtime limit.
///         Isolating the `new` here keeps both contracts comfortably under it.
///
///         Trust model: the caller (`PumperLaunchpad`) is responsible for
///         setting `p.launchpad` correctly -- `PumperToken` grants `burnFrom`
///         authority to whatever address is passed there, not to this factory
///         or to `msg.sender`. This factory holds and moves no funds.
contract PumperTokenFactory {
    function createToken(PumperToken.InitParams calldata p, bytes32 salt) external returns (address token) {
        token = address(new PumperToken{salt: salt}(p));
    }
}
