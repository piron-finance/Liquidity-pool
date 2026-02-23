// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BaseTest is Test {
    
    address public admin = makeAddr("admin");
    address public spv = makeAddr("spv");
    address public operator = makeAddr("operator");
    address public emergency = makeAddr("emergency");
    address public multisigAdmin = makeAddr("multisigAdmin");
    address public treasury = makeAddr("treasury");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");
    
    uint256 public constant INITIAL_BALANCE = 1_000_000e6;
    uint256 public constant BASIS_POINTS = 10_000;
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    
    function setUp() public virtual {
        vm.deal(admin, 100 ether);
        vm.deal(spv, 100 ether);
        vm.deal(operator, 100 ether);
        vm.deal(emergency, 100 ether);
        vm.deal(multisigAdmin, 100 ether);
        vm.deal(treasury, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
    }
    
    function calculateBps(uint256 amount, uint256 bps) public pure returns (uint256) {
        return (amount * bps) / BASIS_POINTS;
    }
    
    function skipTime(uint256 duration) public {
        vm.warp(block.timestamp + duration);
    }
    
    function skipBlocks(uint256 blocks) public {
        vm.roll(block.number + blocks);
    }
}

contract MockERC20 is ERC20 {
    uint8 private _decimals;
    
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _decimals = decimals_;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
    
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
