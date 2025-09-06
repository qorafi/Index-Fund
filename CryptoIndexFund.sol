// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces.sol";

// ============================================================================
// MULTI-TIER INDEX FUND SYSTEM
// ============================================================================

contract MultiTierIndexFund {
    using MathUtils for uint256;
    
    // Tier definitions
    enum IndexTier { CONSERVATIVE_10, BALANCED_100, AGGRESSIVE_300 }
    
    struct TierConfig {
        string name;
        string description;
        uint256 tokenCount;
        uint256 minLiquidity;        // Minimum liquidity requirement
        uint256 managementFee;       // Annual fee in basis points
        uint256 minDeposit;          // Minimum deposit amount
        uint256 riskLevel;           // 1-10 risk scale
        bool isActive;
    }
    
    struct UserPosition {
        IndexTier tier;
        uint256 shares;
        uint256 lastDeposit;
        uint256 totalDeposited;
    }
    
    // Tier configurations
    mapping(IndexTier => TierConfig) public tierConfigs;
    mapping(IndexTier => address[]) public tierTokens;
    mapping(IndexTier => mapping(address => uint256)) public tierAllocations;
    
    // User positions per tier
    mapping(address => mapping(IndexTier => UserPosition)) public userPositions;
    mapping(IndexTier => uint256) public totalShares;
    mapping(IndexTier => uint256) public totalAssets;
    
    // Events
    event TierDeposit(address indexed user, IndexTier tier, uint256 amount, uint256 shares);
    event TierWithdraw(address indexed user, IndexTier tier, uint256 shares, uint256 amount);
    event TierRebalanced(IndexTier tier, address[] newTokens, uint256[] newAllocations);
    event TierConfigUpdated(IndexTier tier, TierConfig config);
    
    constructor() {
        _initializeTiers();
    }
    
    function _initializeTiers() internal {
        // CONSERVATIVE TIER - Top 10
        tierConfigs[IndexTier.CONSERVATIVE_10] = TierConfig({
            name: "CLIF Conservative",
            description: "Top 10 blue-chip crypto assets with maximum stability",
            tokenCount: 10,
            minLiquidity: 100_000_000 * 1e6,  // $100M minimum liquidity
            managementFee: 50,                 // 0.5% annual fee
            minDeposit: 100 * 1e6,            // $100 minimum
            riskLevel: 3,                      // Low risk
            isActive: true
        });
        
        // BALANCED TIER - Top 100  
        tierConfigs[IndexTier.BALANCED_100] = TierConfig({
            name: "CLIF Balanced",
            description: "Top 100 tokens balancing growth and stability",
            tokenCount: 100,
            minLiquidity: 10_000_000 * 1e6,   // $10M minimum liquidity
            managementFee: 75,                 // 0.75% annual fee
            minDeposit: 250 * 1e6,            // $250 minimum
            riskLevel: 6,                      // Medium risk
            isActive: true
        });
        
        // AGGRESSIVE TIER - Top 300
        tierConfigs[IndexTier.AGGRESSIVE_300] = TierConfig({
            name: "CLIF Aggressive", 
            description: "Top 300 tokens for maximum diversification and growth",
            tokenCount: 300,
            minLiquidity: 1_000_000 * 1e6,    // $1M minimum liquidity
            managementFee: 100,                // 1% annual fee
            minDeposit: 500 * 1e6,             // $500 minimum
            riskLevel: 9,                      // High risk
            isActive: true
        });
    }
    
    // ============================================================================
    // USER INVESTMENT FUNCTIONS
    // ============================================================================
    
    function depositToTier(
        IndexTier tier,
        address inputToken,
        uint256 amount
    ) external {
        require(tierConfigs[tier].isActive, "Tier not active");
        require(amount >= tierConfigs[tier].minDeposit, "Below minimum deposit");
        
        // Convert input to USDC value
        uint256 usdcValue = _convertToUSDC(inputToken, amount);
        
        // Calculate shares based on tier NAV
        uint256 shares = _calculateShares(tier, usdcValue);
        
        // Execute investment according to tier strategy
        _executeInvestment(tier, usdcValue);
        
        // Update user position
        UserPosition storage position = userPositions[msg.sender][tier];
        position.tier = tier;
        position.shares += shares;
        position.lastDeposit = block.timestamp;
        position.totalDeposited += usdcValue;
        
        // Update tier totals
        totalShares[tier] += shares;
        totalAssets[tier] += usdcValue;
        
        emit TierDeposit(msg.sender, tier, usdcValue, shares);
    }
    
    function withdrawFromTier(
        IndexTier tier,
        uint256 sharesToBurn
    ) external {
        UserPosition storage position = userPositions[msg.sender][tier];
        require(position.shares >= sharesToBurn, "Insufficient shares");
        
        // Calculate withdrawal value
        uint256 withdrawalValue = _calculateWithdrawalValue(tier, sharesToBurn);
        
        // Execute proportional withdrawal
        _executeWithdrawal(tier, sharesToBurn, totalShares[tier]);
        
        // Update positions
        position.shares -= sharesToBurn;
        totalShares[tier] -= sharesToBurn;
        totalAssets[tier] -= withdrawalValue;
        
        emit TierWithdraw(msg.sender, tier, sharesToBurn, withdrawalValue);
    }
    
    // ============================================================================
    // TIER MANAGEMENT FUNCTIONS
    // ============================================================================
    
    function _executeInvestment(IndexTier tier, uint256 usdcAmount) internal {
        address[] memory tokens = tierTokens[tier];
        
        for(uint256 i = 0; i < tokens.length; i++) {
            uint256 allocation = tierAllocations[tier][tokens[i]];
            uint256 tokenAmount = (usdcAmount * allocation) / 10000;
            
            if(tokenAmount > 0) {
                _swapUSDCToToken(tokens[i], tokenAmount);
            }
        }
    }
    
    function _calculateShares(IndexTier tier, uint256 usdcValue) internal view returns (uint256) {
        if(totalShares[tier] == 0) {
            return usdcValue; // 1:1 for first deposit
        }
        
        uint256 tierNAV = getTierNAV(tier);
        return (usdcValue * totalShares[tier]) / tierNAV;
    }
    
    function getTierNAV(IndexTier tier) public view returns (uint256) {
        uint256 totalValue = 0;
        address[] memory tokens = tierTokens[tier];
        
        for(uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            uint256 price = _getTokenPrice(tokens[i]);
            totalValue += (balance * price) / 1e18;
        }
        
        return totalValue;
    }
    
    // ============================================================================
    // TIER COMPARISON FUNCTIONS
    // ============================================================================
    
    function compareTiers() external view returns (
        string[] memory names,
        uint256[] memory tokenCounts,
        uint256[] memory riskLevels,
        uint256[] memory fees,
        uint256[] memory navs,
        uint256[] memory returns
    ) {
        names = new string[](3);
        tokenCounts = new uint256[](3);
        riskLevels = new uint256[](3);
        fees = new uint256[](3);
        navs = new uint256[](3);
        returns = new uint256[](3);
        
        for(uint256 i = 0; i < 3; i++) {
            IndexTier tier = IndexTier(i);
            TierConfig memory config = tierConfigs[tier];
            
            names[i] = config.name;
            tokenCounts[i] = config.tokenCount;
            riskLevels[i] = config.riskLevel;
            fees[i] = config.managementFee;
            navs[i] = getTierNAV(tier);
            returns[i] = _calculate30DayReturn(tier);
        }
    }
    
    function getUserPortfolio(address user) external view returns (
        IndexTier[] memory tiers,
        uint256[] memory shares,
        uint256[] memory values,
        uint256[] memory allocations
    ) {
        // Count user's active positions
        uint256 activePositions = 0;
        for(uint256 i = 0; i < 3; i++) {
            if(userPositions[user][IndexTier(i)].shares > 0) {
                activePositions++;
            }
        }
        
        tiers = new IndexTier[](activePositions);
        shares = new uint256[](activePositions);
        values = new uint256[](activePositions);
        allocations = new uint256[](activePositions);
        
        uint256 index = 0;
        uint256 totalValue = 0;
        
        // First pass: collect data and calculate total
        for(uint256 i = 0; i < 3; i++) {
            IndexTier tier = IndexTier(i);
            UserPosition memory position = userPositions[user][tier];
            
            if(position.shares > 0) {
                tiers[index] = tier;
                shares[index] = position.shares;
                values[index] = _calculateUserValue(tier, user);
                totalValue += values[index];
                index++;
            }
        }
        
        // Second pass: calculate allocations
        for(uint256 i = 0; i < activePositions; i++) {
            allocations[i] = totalValue > 0 ? (values[i] * 10000) / totalValue : 0;
        }
    }
    
    // ============================================================================
    // TIER CONFIGURATION & ADMIN
    // ============================================================================
    
    function updateTierTokens(
        IndexTier tier,
        address[] memory newTokens,
        uint256[] memory newAllocations
    ) external onlyOwner {
        require(newTokens.length == newAllocations.length, "Array length mismatch");
        require(newTokens.length <= tierConfigs[tier].tokenCount, "Too many tokens");
        
        // Validate allocations sum to 100%
        uint256 totalAllocation = 0;
        for(uint256 i = 0; i < newAllocations.length; i++) {
            totalAllocation += newAllocations[i];
        }
        require(totalAllocation == 10000, "Allocations must sum to 100%");
        
        // Clear existing tokens
        delete tierTokens[tier];
        
        // Set new tokens and allocations
        for(uint256 i = 0; i < newTokens.length; i++) {
            tierTokens[tier].push(newTokens[i]);
            tierAllocations[tier][newTokens[i]] = newAllocations[i];
        }
        
        emit TierRebalanced(tier, newTokens, newAllocations);
    }
    
    function updateTierConfig(
        IndexTier tier,
        TierConfig memory newConfig
    ) external onlyOwner {
        tierConfigs[tier] = newConfig;
        emit TierConfigUpdated(tier, newConfig);
    }
    
    // ============================================================================
    // VIEW FUNCTIONS FOR UI
    // ============================================================================
    
    function getTierInfo(IndexTier tier) external view returns (
        TierConfig memory config,
        address[] memory tokens,
        uint256[] memory allocations,
        uint256 nav,
        uint256 totalShares_,
        uint256 return30d
    ) {
        config = tierConfigs[tier];
        tokens = tierTokens[tier];
        
        allocations = new uint256[](tokens.length);
        for(uint256 i = 0; i < tokens.length; i++) {
            allocations[i] = tierAllocations[tier][tokens[i]];
        }
        
        nav = getTierNAV(tier);
        totalShares_ = totalShares[tier];
        return30d = _calculate30DayReturn(tier);
    }
    
    function getTierPerformanceMetrics(IndexTier tier) external view returns (
        uint256 nav,
        uint256 return1d,
        uint256 return7d,
        uint256 return30d,
        uint256 volatility,
        uint256 sharpeRatio
    ) {
        nav = getTierNAV(tier);
        return1d = _calculate1DayReturn(tier);
        return7d = _calculate7DayReturn(tier);
        return30d = _calculate30DayReturn(tier);
        volatility = _calculateVolatility(tier);
        sharpeRatio = _calculateSharpeRatio(tier);
    }
    
    function getRecommendedTier(
        address user,
        uint256 investmentAmount,
        uint256 riskTolerance  // 1-10 scale
    ) external view returns (
        IndexTier recommendedTier,
        string memory reasoning
    ) {
        // Simple recommendation logic
        if(riskTolerance <= 4 && investmentAmount >= tierConfigs[IndexTier.CONSERVATIVE_10].minDeposit) {
            return (IndexTier.CONSERVATIVE_10, "Conservative investor with preference for stability");
        } else if(riskTolerance <= 7 && investmentAmount >= tierConfigs[IndexTier.BALANCED_100].minDeposit) {
            return (IndexTier.BALANCED_100, "Balanced approach with moderate diversification");
        } else if(investmentAmount >= tierConfigs[IndexTier.AGGRESSIVE_300].minDeposit) {
            return (IndexTier.AGGRESSIVE_300, "High growth potential with maximum diversification");
        } else {
            return (IndexTier.CONSERVATIVE_10, "Start with conservative tier and upgrade later");
        }
    }
    
    // ============================================================================
    // HELPER FUNCTIONS
    // ============================================================================
    
    function _calculateUserValue(IndexTier tier, address user) internal view returns (uint256) {
        UserPosition memory position = userPositions[user][tier];
        if(position.shares == 0) return 0;
        
        uint256 tierNAV = getTierNAV(tier);
        return (position.shares * tierNAV) / totalShares[tier];
    }
    
    function _calculate30DayReturn(IndexTier tier) internal view returns (uint256) {
        // Simplified return calculation
        // In practice, you'd track historical NAV values
        return 850; // 8.5% (placeholder)
    }
    
    function _calculate7DayReturn(IndexTier tier) internal view returns (uint256) {
        return 150; // 1.5% (placeholder)
    }
    
    function _calculate1DayReturn(IndexTier tier) internal view returns (uint256) {
        return 25; // 0.25% (placeholder)
    }
    
    function _calculateVolatility(IndexTier tier) internal view returns (uint256) {
        // Return volatility as basis points
        if(tier == IndexTier.CONSERVATIVE_10) return 1500;  // 15%
        if(tier == IndexTier.BALANCED_100) return 2500;     // 25%
        return 3500; // 35% for aggressive
    }
    
    function _calculateSharpeRatio(IndexTier tier) internal view returns (uint256) {
        // Return Sharpe ratio * 100
        if(tier == IndexTier.CONSERVATIVE_10) return 180;   // 1.8
        if(tier == IndexTier.BALANCED_100) return 220;      // 2.2
        return 190; // 1.9 for aggressive
    }
    
    // Placeholder functions - implement with actual DEX integration
    function _convertToUSDC(address token, uint256 amount) internal returns (uint256) {
        // Implementation needed
        return amount;
    }
    
    function _swapUSDCToToken(address token, uint256 amount) internal {
        // Implementation needed
    }
    
    function _getTokenPrice(address token) internal view returns (uint256) {
        // Implementation needed
        return 1e18;
    }
    
    function _executeWithdrawal(IndexTier tier, uint256 shares, uint256 totalShares_) internal {
        // Implementation needed
    }
    
    function _calculateWithdrawalValue(IndexTier tier, uint256 shares) internal view returns (uint256) {
        // Implementation needed
        return (shares * getTierNAV(tier)) / totalShares[tier];
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    address public owner;
}
