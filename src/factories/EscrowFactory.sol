// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IPoolEscrow.sol";

library Clones {
    function cloneDeterministic(address implementation, bytes32 salt) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "ERC1167: create2 failed");
    }
    
    function predictDeterministicAddress(address implementation, bytes32 salt) internal view returns (address predicted) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000)
            mstore(add(ptr, 0x38), shl(0x60, address()))
            mstore(add(ptr, 0x4c), salt)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            predicted := keccak256(add(ptr, 0x37), 0x55)
        }
    }
}

contract EscrowFactory {
    using Clones for address;
    
    address public immutable escrowImplementation;
    address public immutable admin;
    
    mapping(address => address) public poolEscrows;
    mapping(address => bool) public validEscrows;
    
    event EscrowCreated(
        address indexed pool,
        address indexed manager,
        address indexed escrow,
        address[] signers,
        uint256 requiredConfirmations
    );
    
    constructor(address _escrowImplementation, address _admin) {
        require(_escrowImplementation != address(0), "Invalid escrow implementation");
        require(_admin != address(0), "Invalid admin");
        
        escrowImplementation = _escrowImplementation;
        admin = _admin;
    }
    
    function createEscrow(
        address pool,
        address manager,
        address spvAddress,
        address[] memory signers,
        uint256 requiredConfirmations
    ) external returns (address escrow) {
        require(pool != address(0), "Invalid pool");
        require(manager != address(0), "Invalid manager");
        require(spvAddress != address(0), "Invalid SPV");
        require(signers.length >= 2, "Need at least 2 signers");
        require(requiredConfirmations >= 2, "Need at least 2 confirmations");
        require(requiredConfirmations <= signers.length, "Too many required confirmations");
        require(poolEscrows[pool] == address(0), "Escrow already exists");
        
        bytes32 salt = keccak256(
            abi.encodePacked(
                pool,
                manager,
                spvAddress,
                signers,
                requiredConfirmations,
                block.timestamp
            )
        );
        
        escrow = escrowImplementation.cloneDeterministic(salt);
        
        poolEscrows[pool] = escrow;
        validEscrows[escrow] = true;
        
        emit EscrowCreated(pool, manager, escrow, signers, requiredConfirmations);
        
        return escrow;
    }
    
    function getEscrowForPool(address pool) external view returns (address) {
        return poolEscrows[pool];
    }
    
    function isValidEscrow(address escrow) external view returns (bool) {
        return validEscrows[escrow];
    }
    
    function predictEscrowAddress(
        address pool,
        address manager,
        address spvAddress,
        address[] memory signers,
        uint256 requiredConfirmations
    ) external view returns (address) {
        bytes32 salt = keccak256(
            abi.encodePacked(
                pool,
                manager,
                spvAddress,
                signers,
                requiredConfirmations,
                block.timestamp
            )
        );
        
        return Clones.predictDeterministicAddress(escrowImplementation, salt);
    }
} 