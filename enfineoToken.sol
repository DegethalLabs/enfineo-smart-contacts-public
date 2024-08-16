// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @author Softbinator Technologies
 * @notice ENF Token Contract
 */
contract ENF is ERC20, AccessControl {
    uint256 public constant MAX_SUPPLY = 150_000_000 * 1e18;
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant MINT_ROLE = keccak256("MINT_ROLE");

    constructor() ERC20("Enfineo", "ENF") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINT_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
    }

    function mint(address account) external onlyRole(MINT_ROLE) {
        if (totalSupply() >= MAX_SUPPLY) {
            revert AlreadyMinted();
        }

        _mint(account, MAX_SUPPLY);
        emit Mint(account, MAX_SUPPLY);
    }

    function burn(address _account, uint256 _amount) external onlyRole(BURNER_ROLE) {
        _burn(_account, _amount);
        emit Burn(_account, _amount);
    }

    event Burn(address indexed account, uint256 amount);
    event Mint(address indexed account, uint256 amount);

    error AlreadyMinted();
}