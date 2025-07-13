// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../AccessManager.sol";
import "../PoolRegistry.sol";
import "../Manager.sol";
import "../factories/PoolFactory.sol";

/**
 * @title DeploymentHelper
 * @dev Helper contract showing proper deployment order and configuration
 * @notice This demonstrates the correct way to deploy the Piron Pools system
 */
contract DeploymentHelper {
    
    struct DeploymentConfig {
        address admin;
        address spv;
        address operator;
        address emergency;
        address oracle;
        address verifier;
        address[] poolCreators;
        address[] approvedAssets;
    }
    
    struct DeployedContracts {
        address accessManager;
        address registry;
        address manager;
        address factory;
    }
    
    event SystemDeployed(
        address indexed admin,
        address accessManager,
        address registry,
        address manager,
        address factory
    );
    
    /**
     * @dev Deploy the complete Piron Pools system
     * @param config Configuration for roles and initial setup
     * @return contracts Addresses of deployed contracts
     */
    function deploySystem(DeploymentConfig memory config) external returns (DeployedContracts memory contracts) {
        require(config.admin != address(0), "DeploymentHelper/invalid-admin");
        require(config.spv != address(0), "DeploymentHelper/invalid-spv");
        require(config.operator != address(0), "DeploymentHelper/invalid-operator");
        require(config.emergency != address(0), "DeploymentHelper/invalid-emergency");
        
        // Step 1: Deploy AccessManager first
        AccessManager accessManager = new AccessManager(config.admin);
        contracts.accessManager = address(accessManager);
        
        // Step 2: Deploy Registry (factory will be set later)
        PoolRegistry registry = new PoolRegistry(address(accessManager));
        contracts.registry = address(registry);
        
        // Step 3: Deploy Manager
        Manager manager = new Manager(address(registry), address(accessManager));
        contracts.manager = address(manager);
        
        // Step 4: Deploy Factory
        PoolFactory factory = new PoolFactory(
            address(registry),
            address(manager),
            address(accessManager)
        );
        contracts.factory = address(factory);
        
        // Step 5: Configure system (must be done by admin)
        // Note: In practice, these would be separate transactions by the admin
        
        // Set factory in registry
        registry.setFactory(address(factory));
        
        // Setup initial roles
        accessManager.setupInitialRoles(
            config.admin,
            config.spv,
            config.operator,
            config.emergency
        );
        
        // Grant additional roles
        if (config.oracle != address(0)) {
            accessManager.grantRole(accessManager.ORACLE_ROLE(), config.oracle);
        }
        
        if (config.verifier != address(0)) {
            accessManager.grantRole(accessManager.VERIFIER_ROLE(), config.verifier);
        }
        
        // Grant pool creator roles
        for (uint256 i = 0; i < config.poolCreators.length; i++) {
            if (config.poolCreators[i] != address(0)) {
                accessManager.grantRole(accessManager.POOL_CREATOR_ROLE(), config.poolCreators[i]);
            }
        }
        
        // Approve initial assets
        for (uint256 i = 0; i < config.approvedAssets.length; i++) {
            if (config.approvedAssets[i] != address(0)) {
                registry.approveAsset(config.approvedAssets[i]);
            }
        }
        
        emit SystemDeployed(
            config.admin,
            address(accessManager),
            address(registry),
            address(manager),
            address(factory)
        );
        
        return contracts;
    }
    
    /**
     * @dev Deploy minimal system for testing (admin only)
     * @param admin The admin address
     * @return contracts Addresses of deployed contracts
     */
    function deployMinimalSystem(address admin) external returns (DeployedContracts memory contracts) {
        require(admin != address(0), "DeploymentHelper/invalid-admin");
        
        // Deploy core contracts
        AccessManager accessManager = new AccessManager(admin);
        contracts.accessManager = address(accessManager);
        
        PoolRegistry registry = new PoolRegistry(address(accessManager));
        contracts.registry = address(registry);
        
        Manager manager = new Manager(address(registry), address(accessManager));
        contracts.manager = address(manager);
        
        PoolFactory factory = new PoolFactory(
            address(registry),
            address(manager),
            address(accessManager)
        );
        contracts.factory = address(factory);
        
        // Basic configuration (admin must call setFactory separately)
        // registry.setFactory(address(factory)); // This would be called by admin later
        
        return contracts;
    }
    
    /**
     * @dev Verify deployment integrity
     * @param contracts The deployed contract addresses
     * @param expectedAdmin The expected admin address
     * @return isValid Whether the deployment is valid
     */
    function verifyDeployment(
        DeployedContracts memory contracts,
        address expectedAdmin
    ) external view returns (bool isValid) {
        AccessManager accessManager = AccessManager(contracts.accessManager);
        PoolRegistry registry = PoolRegistry(contracts.registry);
        Manager manager = Manager(contracts.manager);
        PoolFactory factory = PoolFactory(contracts.factory);
        
        // Verify admin has correct role
        if (!accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), expectedAdmin)) {
            return false;
        }
        
        // Verify registry points to correct access manager
        if (address(registry.accessManager()) != contracts.accessManager) {
            return false;
        }
        
        // Verify manager points to correct registry and access manager
        if (address(manager.registry()) != contracts.registry) {
            return false;
        }
        
        if (address(manager.accessManager()) != contracts.accessManager) {
            return false;
        }
        
        // Verify factory points to correct contracts
        if (factory.registry() != contracts.registry) {
            return false;
        }
        
        if (factory.manager() != contracts.manager) {
            return false;
        }
        
        if (address(factory.accessManager()) != contracts.accessManager) {
            return false;
        }
        
        // Verify registry has factory set (if not zero)
        if (registry.factory() != address(0) && registry.factory() != contracts.factory) {
            return false;
        }
        
        return true;
    }
    
    /**
     * @dev Get deployment instructions for manual deployment
     * @return instructions Step-by-step deployment instructions
     */
    function getDeploymentInstructions() external pure returns (string[] memory instructions) {
        instructions = new string[](8);
        
        instructions[0] = "1. Deploy AccessManager with admin address";
        instructions[1] = "2. Deploy PoolRegistry with AccessManager address";
        instructions[2] = "3. Deploy Manager with Registry and AccessManager addresses";
        instructions[3] = "4. Deploy PoolFactory with Registry, Manager, and AccessManager addresses";
        instructions[4] = "5. Admin calls registry.setFactory(factoryAddress)";
        instructions[5] = "6. Admin calls accessManager.setupInitialRoles(...)";
        instructions[6] = "7. Admin approves initial assets via registry.approveAsset(...)";
        instructions[7] = "8. Admin grants POOL_CREATOR_ROLE to authorized addresses";
        
        return instructions;
    }
} 