// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../Escrow.sol";
import "../interfaces/IPoolRegistry.sol";

contract EscrowFactory {
    address public admin;
    address public registry;
    
    mapping(address => address) public poolToEscrow;
    mapping(address => bool) public validEscrows;
    address[] public allEscrows;
    
    event EscrowCreated(
        address indexed escrow,
        address indexed pool,
        address indexed manager,
        address spvAddress
    );
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call");
        _;
    }
    
    modifier onlyValidPool() {
        require(IPoolRegistry(registry).isRegisteredPool(msg.sender), "Invalid pool");
        _;
    }
    
    constructor(address _admin, address _registry) {
        require(_admin != address(0), "Invalid admin");
        require(_registry != address(0), "Invalid registry");
        
        admin = _admin;
        registry = _registry;
    }
    
    function createEscrow(
        address pool,
        address manager,
        address spvAddress,
        address[] memory signers,
        uint256 requiredConfirmations
    ) external onlyAdmin returns (address escrow) {
        require(pool != address(0), "Invalid pool");
        require(manager != address(0), "Invalid manager");
        require(spvAddress != address(0), "Invalid SPV");
        require(signers.length >= 2, "Need at least 2 signers");
        require(requiredConfirmations > 0 && requiredConfirmations <= signers.length, "Invalid confirmations");
        require(poolToEscrow[pool] == address(0), "Escrow already exists for pool");
        require(IPoolRegistry(registry).isRegisteredPool(pool), "Pool not registered");
        
        escrow = address(new Escrow(
            pool,
            manager,
            spvAddress,
            signers,
            requiredConfirmations
        ));
        
        poolToEscrow[pool] = escrow;
        validEscrows[escrow] = true;
        allEscrows.push(escrow);
        
        emit EscrowCreated(escrow, pool, manager, spvAddress);
        
        return escrow;
    }
    
    function getEscrowForPool(address pool) external view returns (address) {
        return poolToEscrow[pool];
    }
    
    function isValidEscrow(address escrow) external view returns (bool) {
        return validEscrows[escrow];
    }
    
    function getAllEscrows() external view returns (address[] memory) {
        return allEscrows;
    }
    
    function getEscrowCount() external view returns (uint256) {
        return allEscrows.length;
    }
    
    function setRegistry(address newRegistry) external onlyAdmin {
        require(newRegistry != address(0), "Invalid registry");
        registry = newRegistry;
    }
    
    function predictEscrowAddress(
        address pool,
        address manager,
        address spvAddress,
        address[] memory signers,
        uint256 requiredConfirmations
    ) external view returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(Escrow).creationCode,
            abi.encode(pool, manager, spvAddress, signers, requiredConfirmations)
        );
        
        bytes32 salt = keccak256(abi.encodePacked(pool, manager, spvAddress));
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        
        return address(uint160(uint256(hash)));
    }
} 