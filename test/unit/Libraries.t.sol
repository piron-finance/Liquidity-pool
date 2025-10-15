// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../fixtures/BaseTest.sol";
import "../../src/libraries/CalculationLibrary.sol";
import "../../src/libraries/ValidationLibrary.sol";

/**
 * @title CalculationLibraryTest
 * @notice Unit tests for CalculationLibrary
 */
contract CalculationLibraryTest is BaseTest {
    
    using CalculationLibrary for *;
    
    /*//////////////////////////////////////////////////////////////
                    FACE VALUE CALCULATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_CalculateFaceValue_Success() public pure {
        uint256 actualRaised = 100_000e6; // 100k
        uint256 discountRate = 500; // 5%
        
        uint256 faceValue = CalculationLibrary.calculateFaceValue(actualRaised, discountRate);
        
        // Face value = 100k / (1 - 0.05) = 100k / 0.95 = 105,263.16
        uint256 expected = (actualRaised * 10_000) / (10_000 - discountRate);
        assertEq(faceValue, expected);
    }
    
    function test_CalculateFaceValue_ZeroDiscount() public pure {
        uint256 actualRaised = 100_000e6;
        uint256 discountRate = 0;
        
        uint256 faceValue = CalculationLibrary.calculateFaceValue(actualRaised, discountRate);
        
        // With 0% discount, face value = raised amount
        assertEq(faceValue, actualRaised);
    }
    
    function test_CalculateFaceValue_RevertIf_InvalidDiscountRate() public {
        uint256 actualRaised = 100_000e6;
        uint256 discountRate = 10_000; // 100% - invalid
        
        vm.expectRevert("Invalid discount rate");
        CalculationLibrary.calculateFaceValue(actualRaised, discountRate);
    }
    
    function test_CalculateFaceValue_RevertIf_DiscountRateTooHigh() public {
        uint256 actualRaised = 100_000e6;
        uint256 discountRate = 10_001; // > 100%
        
        vm.expectRevert("Invalid discount rate");
        CalculationLibrary.calculateFaceValue(actualRaised, discountRate);
    }
    
    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_CalculateFaceValue(uint256 actualRaised, uint256 discountRate) public pure {
        vm.assume(actualRaised > 0 && actualRaised < type(uint128).max);
        vm.assume(discountRate < 10_000); // Must be < 100%
        
        uint256 faceValue = CalculationLibrary.calculateFaceValue(actualRaised, discountRate);
        
        // Face value should always be >= raised amount for valid discount rates
        assertTrue(faceValue >= actualRaised);
    }
    
    function testFuzz_CalculateFaceValue_InverseRelationship(uint256 actualRaised, uint16 discountRate) public pure {
        vm.assume(actualRaised > 1000 && actualRaised < type(uint96).max);
        vm.assume(discountRate > 0 && discountRate < 9000); // 0-90%
        
        uint256 faceValue1 = CalculationLibrary.calculateFaceValue(actualRaised, discountRate);
        uint256 faceValue2 = CalculationLibrary.calculateFaceValue(actualRaised, discountRate + 100); // +1%
        
        // Higher discount rate should result in higher face value
        assertTrue(faceValue2 > faceValue1);
    }
}

/**
 * @title ValidationLibraryWrapper
 * @notice Wrapper contract to test internal library functions
 */
contract ValidationLibraryWrapper {
    using ValidationLibrary for *;
    
    function validateAddress(address addr, bool isReceiver) external pure {
        ValidationLibrary.validateAddress(addr, isReceiver);
    }
    
    function validateAmount(uint256 amount) external pure {
        ValidationLibrary.validateAmount(amount);
    }
}

/**
 * @title ValidationLibraryTest
 * @notice Unit tests for ValidationLibrary
 */
contract ValidationLibraryTest is BaseTest {
    
    ValidationLibraryWrapper public wrapper;
    
    function setUp() public override {
        super.setUp();
        wrapper = new ValidationLibraryWrapper();
    }
    
    /*//////////////////////////////////////////////////////////////
                    ADDRESS VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ValidateAddress_Success() public view {
        address validAddress = address(0x123);
        
        wrapper.validateAddress(validAddress, false);
        wrapper.validateAddress(validAddress, true);
        
        // If we get here, validation passed
        assertTrue(true);
    }
    
    function test_ValidateAddress_RevertIf_ZeroAddress_Sender() public {
        vm.expectRevert("ValidationLibrary/invalid sender");
        wrapper.validateAddress(address(0), false);
    }
    
    function test_ValidateAddress_RevertIf_ZeroAddress_Receiver() public {
        vm.expectRevert("ValidationLibrary/invalid receiver");
        wrapper.validateAddress(address(0), true);
    }
    
    /*//////////////////////////////////////////////////////////////
                    AMOUNT VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ValidateAmount_Success() public view {
        wrapper.validateAmount(100);
        wrapper.validateAmount(1);
        wrapper.validateAmount(type(uint256).max);
        
        assertTrue(true);
    }
    
    function test_ValidateAmount_RevertIf_ZeroAmount() public {
        vm.expectRevert("ValidationLibrary/invalid amount");
        wrapper.validateAmount(0);
    }
    
    /*//////////////////////////////////////////////////////////////
                    FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_ValidateAddress(address addr) public {
        if (addr == address(0)) {
            vm.expectRevert();
            wrapper.validateAddress(addr, false);
        } else {
            wrapper.validateAddress(addr, false);
            assertTrue(true);
        }
    }
    
    function testFuzz_ValidateAmount(uint256 amount) public {
        if (amount == 0) {
            vm.expectRevert("ValidationLibrary/invalid amount");
            wrapper.validateAmount(amount);
        } else {
            wrapper.validateAmount(amount);
            assertTrue(true);
        }
    }
}

