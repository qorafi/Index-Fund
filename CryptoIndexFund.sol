// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces.sol";

// ============================================================================
// MAIN INDEX FUND CONTRACT
// ============================================================================

contract CryptoIndexFund is IIndexFund {
    using MathUtils for uint256;
    using ArrayUtils for uint256[];
    
    // State variables
    string public name = "Crypto Liquidity Index Fund";
    string public symbol = "CLIF";
    
    address public owner;
    address public treasury;
    address public autoManager;
    
    // Fund composition
    TokenInfo[] public indexTokens;
    mapping(address => uint256) public tokenIndex;
    mapping(address => bool) public isIndexToken;
    
    // Share tracking
    uint256 public totalShares;
    mapping(address => uint256) public shares;
    
    // External contracts
    IAggregator public immutable aggregator;
    IDEXRouter public immutable router;
    address public constant STABLE_COIN = Constants.USDC;
    
    // Fund settings
    uint256 public currentHedgeLevel = 0;
    uint256 public minDeposit = 100 * 1e6; // 100 USDC minimum
    bool public emergencyPaused = false;
    
    // Events
    event Deposit(address indexed user, uint256 usdcValue, uint256 shares, uint256 unitPrice);
    event Withdraw(address indexed user, uint256 shares, uint256 value);
    event TokenAdded(address indexed token, uint256 allocation);
    event HedgeAdjusted(uint256 oldLevel, uint256 newLevel);
    
    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier onlyAutoManager() {
        require(msg.sender == autoManager, "Not auto manager");
        _;
    }
    
    modifier whenNotPaused() {
        if(emergencyPaused) revert EmergencyPaused();
        _;
    }
    
    constructor(
        address _aggregator,
        address _router,
        address _treasury,
        address[] memory _initialTokens,
        uint256[] memory _initialAllocations
    ) {
        owner = msg.sender;
        treasury = _treasury;
        aggregator = IAggregator(_aggregator);
        router = IDEXRouter(_router);
        
        _initializeTokens(_initialTokens, _initialAllocations);
    }
    
    // ============================================================================
    // CORE FUND FUNCTIONS
    // ============================================================================
    
    function deposit(address inputToken, uint256 amount) external override whenNotPaused {
        require(amount > 0, "Zero amount");
        
        // Convert input token to USDC value
        uint256 usdcValue = _convertToUSDC(inputToken, amount);
        require(usdcValue >= minDeposit, "Below minimum deposit");
        
        // Calculate shares to mint
        uint256 currentPrice = getUnitPrice();
        uint256 sharesToMint = (usdcValue * 1e18) / currentPrice;
        
        // Transfer tokens from user
        IERC20(inputToken).transferFrom(msg.sender, address(this), amount);
        
        // Execute index purchase
        executeIndexPurchase(usdcValue);
        
        // Mint shares to user
        shares[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        
        emit Deposit(msg.sender, usdcValue, sharesToMint, currentPrice);
    }
    
    function withdraw(uint256 sharesToBurn) external override whenNotPaused {
        require(shares[msg.sender] >= sharesToBurn, "Insufficient shares");
        require(sharesToBurn > 0, "Zero shares");
        
        uint256 sharePercentage = (sharesToBurn * 1e18) / totalShares;
        
        // Transfer proportional tokens to user
        for(uint256 i = 0; i < indexTokens.length; i++) {
            if(indexTokens[i].isActive) {
                uint256 tokenBalance = IERC20(indexTokens[i].token).balanceOf(address(this));
                uint256 tokenAmount = (tokenBalance * sharePercentage) / 1e18;
                
                if(tokenAmount > 0) {
                    IERC20(indexTokens[i].token).transfer(msg.sender, tokenAmount);
                }
            }
        }
        
        // Burn shares
        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        
        uint256 withdrawalValue = (sharesToBurn * getUnitPrice()) / 1e18;
        emit Withdraw(msg.sender, sharesToBurn, withdrawalValue);
    }
    
    function getUnitPrice() public view override returns (uint256) {
        if(totalShares == 0) return 1e18; // Initial price = 1.0 USDC
        
        uint256 totalValue = getTotalPortfolioValue();
        return (totalValue * 1e18) / totalShares;
    }
    
    function getTotalPortfolioValue() public view override returns (uint256) {
        uint256 totalValue = 0;
        
        // Add value of all index tokens
        for(uint256 i = 0; i < indexTokens.length; i++) {
            if(indexTokens[i].isActive) {
                address token = indexTokens[i].token;
                uint256 balance = IERC20(token).balanceOf(address(this));
                
                if(balance > 0) {
                    uint256 price = aggregator.getRate(token, STABLE_COIN);
                    totalValue += (balance * price) / 1e18;
                }
            }
        }
        
        // Add stablecoin balance (hedge amount)
        totalValue += IERC20(STABLE_COIN).balanceOf(address(this));
        
        return totalValue;
    }
    
    // ============================================================================
    // INDEX MANAGEMENT
    // ============================================================================
    
    function executeIndexPurchase(uint256 usdcAmount) public override onlyAutoManager {
        // Calculate allocation amounts
        uint256 hedgeAmount = usdcAmount.percentage(currentHedgeLevel);
        uint256 investAmount = usdcAmount - hedgeAmount;
        
        if(investAmount > 0) {
            _distributeToIndexTokens(investAmount);
        }
        
        // Keep hedge amount in stablecoin (already in USDC)
    }
    
    function _distributeToIndexTokens(uint256 usdcAmount) internal {
        for(uint256 i = 0; i < indexTokens.length; i++) {
            if(indexTokens[i].isActive) {
                uint256 tokenAmount = usdcAmount.percentage(indexTokens[i].allocation);
                
                if(tokenAmount > 0) {
                    _swapUSDCToToken(indexTokens[i].token, tokenAmount);
                }
            }
        }
    }
    
    function _swapUSDCToToken(address token, uint256 usdcAmount) internal {
        if(token == STABLE_COIN) return; // No swap needed
        
        address[] memory path = new address[](2);
        path[0] = STABLE_COIN;
        path[1] = token;
        
        IERC20(STABLE_COIN).approve(address(router), usdcAmount);
        
        router.swapExactTokensForTokens(
            usdcAmount,
            0, // Accept any amount of tokens out
            path,
            address(this),
            block.timestamp + 300
        );
    }
    
    function _convertToUSDC(address inputToken, uint256 amount) internal returns (uint256) {
        if(inputToken == STABLE_COIN) {
            IERC20(inputToken).transferFrom(msg.sender, address(this), amount);
            return amount;
        }
        
        address[] memory path = new address[](2);
        path[0] = inputToken;
        path[1] = STABLE_COIN;
        
        IERC20(inputToken).approve(address(router), amount);
        
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp + 300
        );
        
        return amounts[1]; // Return USDC amount received
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function _initializeTokens(
        address[] memory tokens,
        uint256[] memory allocations
    ) internal {
        require(tokens.length == allocations.length, "Array length mismatch");
        
        uint256 totalAllocation = 0;
        for(uint256 i = 0; i < tokens.length; i++) {
            indexTokens.push(TokenInfo({
                token: tokens[i],
                allocation: allocations[i],
                currentBalance: 0,
                isActive: true
            }));
            
            isIndexToken[tokens[i]] = true;
            tokenIndex[tokens[i]] = i;
            totalAllocation += allocations[i];
        }
        
        require(totalAllocation == 10000, "Total allocation must be 100%");
    }
    
    function addToken(address token, uint256 allocation) external onlyOwner {
        require(!isIndexToken[token], "Token already exists");
        require(allocation > 0, "Zero allocation");
        
        indexTokens.push(TokenInfo({
            token: token,
            allocation: allocation,
            currentBalance: 0,
            isActive: true
        }));
        
        isIndexToken[token] = true;
        tokenIndex[token] = indexTokens.length - 1;
        
        emit TokenAdded(token, allocation);
    }
    
    function updateTokenAllocation(address token, uint256 newAllocation) external onlyOwner {
        require(isIndexToken[token], "Token not in index");
        
        uint256 index = tokenIndex[token];
        indexTokens[index].allocation = newAllocation;
    }
    
    function setAutoManager(address _autoManager) external onlyOwner {
        autoManager = _autoManager;
    }
    
    function mintFeeShares(address to, uint256 feeAmount) external override onlyAutoManager {
        uint256 currentPrice = getUnitPrice();
        uint256 sharesToMint = (feeAmount * 1e18) / currentPrice;
        
        shares[to] += sharesToMint;
        totalShares += sharesToMint;
    }
    
    function pause() external onlyOwner {
        emergencyPaused = true;
    }
    
    function unpause() external onlyOwner {
        emergencyPaused = false;
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getIndexTokens() external view returns (TokenInfo[] memory) {
        return indexTokens;
    }
    
    function getUserShares(address user) external view returns (uint256) {
        return shares[user];
    }
    
    function getUserValue(address user) external view returns (uint256) {
        if(totalShares == 0) return 0;
        return (shares[user] * getTotalPortfolioValue()) / totalShares;
    }
    
    function getCurrentHedgeLevel() external view returns (uint256) {
        return currentHedgeLevel;
    }
}