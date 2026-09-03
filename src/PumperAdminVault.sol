// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "./Interfaces.sol";

/// @title PumperAdminVault
/// @notice Plain multi-admin fee vault: any admin can withdraw any amount of
///         any token (or native currency) held here, anytime -- no equal-
///         split accounting, no per-admin claim tracking. This is the
///         destination for PumperProtocolLaunchpad's ADMIN_VAULT_BPS cut of
///         every LP-fee harvest (see PumperProtocolToken.adminVault and
///         PumperProtocolLaunchpad.collectLpFees).
///
///         Deliberately NOT the same design as the existing, unrelated
///         PumperFees.sol/FeeAdmin -- that contract divides fees equally
///         among admins based on balance-since-last-claim. This vault has no
///         such accounting: it is a shared pot, and any admin can move any
///         amount out at any time. Simpler, and matches what was actually
///         asked for ("multiple admins to withdraw the funds anytime").
contract PumperAdminVault {
    mapping(address => bool) public isAdmin;
    address[] private _admins;

    event AdminAdded(address indexed admin, address indexed addedBy);
    event AdminRemoved(address indexed admin, address indexed removedBy);
    event Withdrawn(address indexed token, address indexed to, uint256 amount, address indexed admin);
    event NativeWithdrawn(address indexed to, uint256 amount, address indexed admin);

    error NotAdmin();
    error ZeroAddress();
    error AlreadyAdmin();
    error NotCurrentAdmin();
    error LastAdmin();
    error NoAdmins();

    modifier onlyAdmin() {
        if (!isAdmin[msg.sender]) revert NotAdmin();
        _;
    }

    constructor(address[] memory initialAdmins) {
        if (initialAdmins.length == 0) revert NoAdmins();
        for (uint256 i; i < initialAdmins.length; ++i) {
            _addAdmin(initialAdmins[i]);
        }
    }

    function _addAdmin(address a) internal {
        if (a == address(0)) revert ZeroAddress();
        if (isAdmin[a]) revert AlreadyAdmin();
        isAdmin[a] = true;
        _admins.push(a);
        emit AdminAdded(a, msg.sender);
    }

    /// @notice Add a new admin. Any existing admin can do this -- there is no
    ///         separate "owner" tier above admins.
    function addAdmin(address a) external onlyAdmin {
        _addAdmin(a);
    }

    /// @notice Remove an admin. Always leaves at least one admin standing, so
    ///         the vault can never lock itself out of its own funds.
    function removeAdmin(address a) external onlyAdmin {
        if (!isAdmin[a]) revert NotCurrentAdmin();
        if (_admins.length <= 1) revert LastAdmin();

        isAdmin[a] = false;
        uint256 len = _admins.length;
        for (uint256 i; i < len; ++i) {
            if (_admins[i] == a) {
                _admins[i] = _admins[len - 1];
                _admins.pop();
                break;
            }
        }
        emit AdminRemoved(a, msg.sender);
    }

    /// @notice Withdraw `amount` of `token` (any ERC20 -- WgUSDT in practice,
    ///         since that's what the launchpad's fee harvest pays in) to
    ///         `to`. Any admin, any amount up to the vault's balance, anytime.
    function withdraw(address token, address to, uint256 amount) external onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        require(IERC20(token).transfer(to, amount), "transfer");
        emit Withdrawn(token, to, amount, msg.sender);
    }

    /// @notice Withdraw native currency held here. Defensive -- fees normally
    ///         arrive as an ERC20 WETH.transfer, never native value, but a
    ///         stray direct send (or a future revenue stream) shouldn't be
    ///         unrecoverable.
    function withdrawNative(address payable to, uint256 amount) external onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "native transfer");
        emit NativeWithdrawn(to, amount, msg.sender);
    }

    function admins() external view returns (address[] memory) {
        return _admins;
    }

    function adminCount() external view returns (uint256) {
        return _admins.length;
    }

    receive() external payable {}
}
