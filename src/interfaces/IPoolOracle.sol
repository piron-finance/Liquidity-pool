// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPoolOracle {
    struct InvestmentProof {
        string proofHash;
        uint256 amount;
        uint256 timestamp;
        bool verified;
        address verifier;
    }
    
    struct ValuationData {
        uint256 value;
        uint256 timestamp;
        address oracle;
        bool isActive;
    }
    
    event InvestmentProofSubmitted(
        address indexed pool,
        string proofHash,
        uint256 amount,
        address indexed submitter
    );
    
    event ProofVerified(
        address indexed pool,
        string proofHash,
        address indexed verifier
    );
    
    event ValuationUpdated(
        address indexed pool,
        uint256 value,
        uint256 timestamp,
        address indexed oracle
    );
    
    event OracleAdded(address indexed oracle, string role);
    event OracleRemoved(address indexed oracle);
    
    function getInvestmentProof(address pool) external view returns (InvestmentProof memory);
    function getCurrentValuation(address pool) external view returns (ValuationData memory);
    function isValidOracle(address oracle) external view returns (bool);
    function getProofVerificationStatus(address pool) external view returns (bool);
    
    function submitInvestmentProof(
        address pool,
        string memory proofHash,
        uint256 amount
    ) external;
    
    function verifyProof(address pool) external;
    function challengeProof(address pool, string memory reason) external;
    
    function updateValuation(address pool, uint256 value) external;
    function getHistoricalValuation(address pool, uint256 timestamp) external view returns (uint256);
    
    function addOracle(address oracle, string memory role) external;
    function removeOracle(address oracle) external;
    function setVerificationRequirements(uint256 minVerifiers, uint256 timelock) external;
    
    function emergencyPause(address pool) external;
    function emergencyUnpause(address pool) external;
} 