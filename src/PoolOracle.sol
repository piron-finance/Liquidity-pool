// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IPoolOracle.sol";
import "./AccessManager.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PoolOracle is IPoolOracle, ReentrancyGuard {
    AccessManager public accessManager;
    
    struct InvestmentProofData {
        string proofHash;
        uint256 amount;
        uint256 timestamp;
        bool verified;
        address verifier;
        address submitter;
        uint256 blockNumber;
        string ipfsHash;
        mapping(address => bool) verifierVotes;
        uint256 verificationCount;
    }
    
    struct ValuationRecord {
        uint256 value;
        uint256 timestamp;
        address oracle;
        bool isActive;
        uint256 confidence;
        string dataSource;
    }
    
    struct OracleInfo {
        bool isActive;
        string role;
        uint256 addedAt;
        uint256 lastActivity;
        uint256 reputation;
    }
    
    mapping(address => InvestmentProofData) public poolProofs;
    mapping(address => ValuationRecord[]) public poolValuations;
    mapping(address => ValuationRecord) public currentValuations;
    mapping(address => OracleInfo) public oracles;
    mapping(address => bool) public pausedPools;
    
    address[] public oracleList;
    uint256 public minVerifiers = 2;
    uint256 public verificationTimelock = 24 hours;
    uint256 public maxValuationAge = 7 days;
    
    event InvestmentProofSubmitted(
        address indexed pool,
        string proofHash,
        uint256 amount,
        address indexed submitter,
        string ipfsHash
    );
    
    event ProofVerified(
        address indexed pool,
        string proofHash,
        address indexed verifier,
        uint256 verificationCount
    );
    
    event ProofChallenged(
        address indexed pool,
        string proofHash,
        address indexed challenger,
        string reason
    );
    
    event ValuationUpdated(
        address indexed pool,
        uint256 value,
        uint256 timestamp,
        address indexed oracle,
        uint256 confidence
    );
    
    event OracleAdded(address indexed oracle, string role, uint256 reputation);
    event OracleRemoved(address indexed oracle, string reason);
    event OracleReputationUpdated(address indexed oracle, uint256 oldReputation, uint256 newReputation);
    
    event VerificationRequirementsUpdated(uint256 minVerifiers, uint256 timelock);
    event PoolPaused(address indexed pool, address indexed oracle);
    event PoolUnpaused(address indexed pool, address indexed oracle);
    
    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "Oracle/access-denied");
        _;
    }
    
    modifier onlyValidOracle() {
        require(oracles[msg.sender].isActive, "Oracle/not-authorized");
        _;
    }
    
    modifier onlyActivePool(address pool) {
        require(!pausedPools[pool], "Oracle/pool-paused");
        _;
    }
    
    modifier whenNotPaused() {
        require(!accessManager.paused(), "Oracle/system-paused");
        _;
    }
    
    constructor(address _accessManager) {
        require(_accessManager != address(0), "Oracle/invalid-access-manager");
        accessManager = AccessManager(_accessManager);
    }
    
    function submitInvestmentProof(
        address pool,
        string memory proofHash,
        uint256 amount
    ) external override onlyRole(accessManager.SPV_ROLE()) onlyActivePool(pool) whenNotPaused nonReentrant {
        require(pool != address(0), "Oracle/invalid-pool");
        require(bytes(proofHash).length > 0, "Oracle/invalid-proof-hash");
        require(amount > 0, "Oracle/invalid-amount");
        
        InvestmentProofData storage proof = poolProofs[pool];
        require(proof.timestamp == 0, "Oracle/proof-already-exists");
        
        proof.proofHash = proofHash;
        proof.amount = amount;
        proof.timestamp = block.timestamp;
        proof.verified = false;
        proof.submitter = msg.sender;
        proof.blockNumber = block.number;
        proof.ipfsHash = "";
        proof.verificationCount = 0;
        
        emit InvestmentProofSubmitted(pool, proofHash, amount, msg.sender);
    }
    
    function verifyProof(address pool) external onlyValidOracle onlyActivePool(pool) whenNotPaused nonReentrant {
        InvestmentProofData storage proof = poolProofs[pool];
        require(proof.timestamp > 0, "Oracle/proof-not-found");
        require(!proof.verified, "Oracle/already-verified");
        require(proof.timestamp + verificationTimelock <= block.timestamp, "Oracle/timelock-active");
        require(!proof.verifierVotes[msg.sender], "Oracle/already-voted");
        
        proof.verifierVotes[msg.sender] = true;
        proof.verificationCount++;
        
        oracles[msg.sender].lastActivity = block.timestamp;
        oracles[msg.sender].reputation += 10;
        
        emit ProofVerified(pool, proof.proofHash, msg.sender, proof.verificationCount);
        
        if (proof.verificationCount >= minVerifiers) {
            proof.verified = true;
            proof.verifier = msg.sender;
        }
    }
    
    function challengeProof(address pool, string memory reason) external onlyValidOracle onlyActivePool(pool) whenNotPaused {
        require(bytes(reason).length > 0, "Oracle/invalid-reason");
        
        InvestmentProofData storage proof = poolProofs[pool];
        require(proof.timestamp > 0, "Oracle/proof-not-found");
        require(!proof.verified, "Oracle/cannot-challenge-verified");
        
        oracles[msg.sender].lastActivity = block.timestamp;
        
        emit ProofChallenged(pool, proof.proofHash, msg.sender, reason);
        
        proof.verified = false;
        proof.verificationCount = 0;
        
        for (uint256 i = 0; i < oracleList.length; i++) {
            proof.verifierVotes[oracleList[i]] = false;
        }
    }
    
    function addOracle(address oracle, string memory role) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) whenNotPaused {
        require(oracle != address(0), "Oracle/invalid-oracle");
        require(bytes(role).length > 0, "Oracle/invalid-role");
        require(!oracles[oracle].isActive, "Oracle/oracle-already-exists");
        
        oracles[oracle] = OracleInfo({
            isActive: true,
            role: role,
            addedAt: block.timestamp,
            lastActivity: block.timestamp,
            reputation: 100
        });
        
        oracleList.push(oracle);
        
        emit OracleAdded(oracle, role, 100);
    }
    
    function removeOracle(address oracle) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) whenNotPaused {
        require(oracle != address(0), "Oracle/invalid-oracle");
        require(oracles[oracle].isActive, "Oracle/oracle-not-found");
        
        oracles[oracle].isActive = false;
        
        // Remove from oracle list
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracleList[i] == oracle) {
                oracleList[i] = oracleList[oracleList.length - 1];
                oracleList.pop();
                break;
            }
        }
        
        emit OracleRemoved(oracle, "Admin removal");
    }
    
    function updateOracleReputation(address oracle, uint256 newReputation) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(oracles[oracle].isActive, "Oracle/not-found");
        
        uint256 oldReputation = oracles[oracle].reputation;
        oracles[oracle].reputation = newReputation;
        
        emit OracleReputationUpdated(oracle, oldReputation, newReputation);
    }
    
    function setVerificationRequirements(uint256 _minVerifiers, uint256 _timelock) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_minVerifiers > 0, "Oracle/invalid-min-verifiers");
        require(_timelock > 0, "Oracle/invalid-timelock");
        
        minVerifiers = _minVerifiers;
        verificationTimelock = _timelock;
        
        emit VerificationRequirementsUpdated(_minVerifiers, _timelock);
    }
    
    function emergencyPause(address pool) external override onlyRole(accessManager.EMERGENCY_ROLE()) {
        require(pool != address(0), "Oracle/invalid-pool");
        pausedPools[pool] = true;
        emit PoolPaused(pool, msg.sender);
    }
    
    function emergencyUnpause(address pool) external override onlyRole(accessManager.EMERGENCY_ROLE()) {
        require(pool != address(0), "Oracle/invalid-pool");
        pausedPools[pool] = false;
        emit PoolUnpaused(pool, msg.sender);
    }
    
    function getInvestmentProof(address pool) external view override returns (InvestmentProof memory) {
        InvestmentProofData storage proof = poolProofs[pool];
        return InvestmentProof({
            proofHash: proof.proofHash,
            amount: proof.amount,
            timestamp: proof.timestamp,
            verified: proof.verified,
            verifier: proof.verifier
        });
    }
    
    function getDetailedProof(address pool) external view returns (
        string memory proofHash,
        uint256 amount,
        uint256 timestamp,
        bool verified,
        address verifier,
        address submitter,
        uint256 blockNumber,
        string memory ipfsHash,
        uint256 verificationCount
    ) {
        InvestmentProofData storage proof = poolProofs[pool];
        return (
            proof.proofHash,
            proof.amount,
            proof.timestamp,
            proof.verified,
            proof.verifier,
            proof.submitter,
            proof.blockNumber,
            proof.ipfsHash,
            proof.verificationCount
        );
    }
    
    function getCurrentValuation(address pool) external view override returns (ValuationData memory) {
        ValuationRecord storage valuation = currentValuations[pool];
        return ValuationData({
            value: valuation.value,
            timestamp: valuation.timestamp,
            oracle: valuation.oracle,
            isActive: valuation.isActive
        });
    }
    
    function getHistoricalValuation(address pool, uint256 timestamp) external view override returns (uint256) {
        ValuationRecord[] storage valuations = poolValuations[pool];
        
        // Find the valuation closest to the requested timestamp
        uint256 closestValue = 0;
        uint256 closestTimeDiff = type(uint256).max;
        
        for (uint256 i = 0; i < valuations.length; i++) {
            if (valuations[i].isActive) {
                uint256 timeDiff = timestamp > valuations[i].timestamp 
                    ? timestamp - valuations[i].timestamp 
                    : valuations[i].timestamp - timestamp;
                
                if (timeDiff < closestTimeDiff) {
                    closestTimeDiff = timeDiff;
                    closestValue = valuations[i].value;
                }
            }
        }
        
        return closestValue;
    }
    
    function getValuationHistory(address pool) external view returns (ValuationRecord[] memory) {
        return poolValuations[pool];
    }
    
    function isValidOracle(address oracle) external view override returns (bool) {
        return oracles[oracle].isActive;
    }
    
    function getProofVerificationStatus(address pool) external view override returns (bool) {
        return poolProofs[pool].verified;
    }
    
    function getOracleInfo(address oracle) external view returns (OracleInfo memory) {
        return oracles[oracle];
    }
    
    function getAllOracles() external view returns (address[] memory) {
        return oracleList;
    }
    
    function getActiveOracles() external view returns (address[] memory) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracles[oracleList[i]].isActive) {
                activeCount++;
            }
        }
        
        address[] memory activeOracles = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracles[oracleList[i]].isActive) {
                activeOracles[index] = oracleList[i];
                index++;
            }
        }
        
        return activeOracles;
    }
    
    function hasVerifiedProof(address pool) external view returns (bool) {
        return poolProofs[pool].verified;
    }
    
    function getVerificationProgress(address pool) external view returns (uint256 current, uint256 required) {
        return (poolProofs[pool].verificationCount, minVerifiers);
    }
    
    function canVerifyProof(address pool, address oracle) external view returns (bool) {
        InvestmentProofData storage proof = poolProofs[pool];
        return proof.timestamp > 0 && 
               !proof.verified && 
               proof.timestamp + verificationTimelock <= block.timestamp &&
               !proof.verifierVotes[oracle] &&
               oracles[oracle].isActive;
    }
    
    function isValuationFresh(address pool) external view returns (bool) {
        ValuationRecord storage valuation = currentValuations[pool];
        return valuation.timestamp > 0 && 
               (block.timestamp - valuation.timestamp <= maxValuationAge);
    }
    
    function setMaxValuationAge(uint256 _maxAge) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_maxAge > 0, "Oracle/invalid-max-age");
        maxValuationAge = _maxAge;
    }
    
    function updateValuation(address pool, uint256 value) external override onlyValidOracle onlyActivePool(pool) whenNotPaused nonReentrant {
        require(pool != address(0), "Oracle/invalid-pool");
        require(value > 0, "Oracle/invalid-value");
        
        ValuationRecord memory newValuation = ValuationRecord({
            value: value,
            timestamp: block.timestamp,
            oracle: msg.sender,
            isActive: true,
            confidence: 95, // Default confidence
            dataSource: "Oracle submission"
        });
        
        poolValuations[pool].push(newValuation);
        currentValuations[pool] = newValuation;
        
        oracles[msg.sender].lastActivity = block.timestamp;
        oracles[msg.sender].reputation += 5;
        
        emit ValuationUpdated(pool, value, block.timestamp, msg.sender, 95);
    }
} 