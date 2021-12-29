// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "./security/ReentrancyGuard.sol";
import "./utils/structs/EnumerableMap.sol";
import "./token/ERC20/SafeERC20.sol";
import "./access/Ownable.sol";
import "./security/Pausable.sol";
import "./token/ACDMToken.sol";

/** @title ACDM marketplace. */
contract Marketplace is Ownable, ReentrancyGuard, Pausable {
  using SafeERC20 for IERC20;

  struct Order {
    uint256 amount;
    uint256 cost;       // eth tokenPrice * amount
    uint256 tokenPrice; // eth
    address account;
    bool isOpen;
  }

  struct Round {
    uint256 createdAt;
    uint256 endTime;
    uint256 tradeVolume; // eth
    uint256 tokensLeft;
    uint256 price;
  }

  event UserRegistered(address indexed account, address indexed referrer);
  event PlacedOrder(uint256 indexed roundID, address indexed account, uint256 amount, uint256 cost);
  event CancelledOrder(uint256 indexed roundID, uint256 indexed orderID, address indexed account);
  event TokenBuy(uint256 indexed roundID, address indexed buyer, address indexed seller, uint256 amount, uint256 price, uint256 cost);
  event StartedSaleRound(uint256 indexed roundID, uint256 newPrice, uint256 oldPrice, uint256 minted);
  event FinishedSaleRound(uint256 indexed roundID, uint256 oldPrice, uint256 burned);
  event StartedTradeRound(uint256 indexed roundID);
  event FinishedTradeRound(uint256 indexed roundID, uint256 tradeVolume);

  uint256 public roundTime;
  uint256 public numRounds;
  address public token;
  bool public isSaleRound;

  mapping(uint256 => Round) public rounds;      // roundID => Round
  mapping(uint256 => Order[]) public orders;    // roundID => orders[]
  mapping(address => address) public referrers; // referral => referrer
  // mapping(address => address[]) public referrers; // ?

  /** @notice Creates Marketplace contract.
   * @dev Sets `msg.sender` as contract Admin
   * @param _token The address of the ACDM token.
   * @param _roundTime Round time (timestamp).
   */
  constructor(address _token, uint256 _roundTime) {
    roundTime = _roundTime;
    token = _token;
  }

  /** @notice Starting first Marketplace round.
   * @dev Mints `mintAmount` of tokens based on `startPrice` and `startVolume`.
   * @param startPrice Starting price per token.
   * @param startVolume Starting trade volume.
   */
  function initMarketplace(uint256 startPrice, uint256 startVolume) external onlyOwner {
    isSaleRound = true;

    numRounds++;
    Round storage newRound = rounds[numRounds];
    newRound.createdAt = block.timestamp;
    newRound.endTime = block.timestamp + roundTime;
    newRound.price = startPrice;

    uint256 mintAmount = startVolume * (10 ** 18) / startPrice;
    newRound.tokensLeft = mintAmount;

    ACDMToken(token).mint(address(this), mintAmount);

    emit StartedSaleRound(numRounds, startPrice, 0, mintAmount);
  }

  /** @notice Allows the user to specify his referrer.
   * @dev Once it's called, the referrer can't be changed.
   * @param referrer The address of the referrer.
   */
  function registerUser(address referrer) external whenNotPaused {
    require(!hasReferrer(msg.sender), "Already has a referrer");
    require(referrer != msg.sender, "Can't be self-referrer");
    referrers[msg.sender] = referrer;
    emit UserRegistered(msg.sender, referrer);
  }

  function placeOrder(uint256 amount, uint256 cost) external whenNotPaused {
    require(!isSaleRound, "Can't place order on sale round");
    require(amount > 0, "Amount can't be zero");
    require(cost > 0, "Cost can't be zero");

    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

    uint256 tokenPrice = cost / (amount / 10 ** 18);

    orders[numRounds].push(Order({
      account: msg.sender,
      amount: amount,
      cost: cost,
      tokenPrice: tokenPrice,
      isOpen: true
    }));

    Round storage round = rounds[numRounds];
    round.tokensLeft += amount;

    emit PlacedOrder(numRounds, msg.sender, amount, cost);
  }

  function cancelOrder(uint256 id) external whenNotPaused {
    Order storage order = orders[numRounds][id];
    require(msg.sender == order.account, "Not your order");
    require(order.isOpen, "Already cancelled");

    rounds[numRounds].tokensLeft -= order.amount;
    _cancelOrder(order);
    emit CancelledOrder(numRounds, id, msg.sender);
  }

  function changeRound() external onlyOwner whenNotPaused {
    require(rounds[numRounds].endTime <= block.timestamp, "Need to wait 3 days");

    isSaleRound ? startTradeRound(rounds[numRounds].price, rounds[numRounds].tokensLeft)
      : startSaleRound(rounds[numRounds].price, rounds[numRounds].tradeVolume);
  }

  function buyTokens(uint256 amount) external payable nonReentrant whenNotPaused {
    require(isSaleRound, "Can't buy in trade round");
    require(amount > 0, "Amount can't be zero");
    Round storage round = rounds[numRounds];
    // Check that the round goes on
    require(round.endTime >= block.timestamp, "This round is ended");
    // Check that the user sent enough ether
    uint256 totalCost = calcCost(round.price, amount);
    require(msg.value >= totalCost, "Not enough ETH");
    
    // Transfer tokens
    IERC20(token).safeTransfer(msg.sender, amount);

    round.tokensLeft -= amount;
    round.tradeVolume += totalCost;

    // Send rewards to referrers
    payReferrers(msg.sender, totalCost);

    // Transfer excess ETH back to msg.sender
    if (msg.value - totalCost > 0) {
      sendEther(msg.sender, msg.value - totalCost);
    }

    emit TokenBuy(numRounds, msg.sender, address(this), amount, round.price, totalCost);
    
    // if (round.tokensLeft == 0) startTradeRound(round.price, round.tokensLeft);
    if (round.tokensLeft == 0) round.endTime = block.timestamp;
  }

  function buyOrder(uint256 id, uint256 amount) external payable nonReentrant whenNotPaused {
    require(id >= 0 && id < orders[numRounds].length, "Incorrect order id");
    Order storage order = orders[numRounds][id];
    require(msg.sender != order.account, "Can't buy from yourself");
    require(order.isOpen, "Order is cancelled");
    require(amount > 0, "Amount can't be zero");
    require(amount <= order.amount, "Order doesn't have enough tokens");
    uint256 totalCost = calcCost(order.tokenPrice, amount);
    require(msg.value >= totalCost, "Not enough ETH");

    // Transfer tokens
    IERC20(token).safeTransfer(msg.sender, amount);

    Round storage round = rounds[numRounds];
    order.amount -= amount;
    round.tokensLeft -= amount;
    round.tradeVolume += totalCost;

    // Transfer 95% ETH to order owner (total - 5%)
    sendEther(order.account, totalCost - (totalCost * 500 / 10000));

    // Send rewards to referrers
    payReferrers(order.account, totalCost);

    // Transfer excess ETH back to msg.sender
    if (msg.value - totalCost > 0) {
      sendEther(msg.sender, msg.value - totalCost);
    }
    // Check if order should be cancelled
    // if (order.amount == 0) _cancelOrder(id);

    emit TokenBuy(numRounds, msg.sender, order.account, amount, order.tokenPrice, totalCost);
  }

  function getCurrentRoundData() external view returns (Round memory) {
    return rounds[numRounds];
  }

  function getRoundData(uint256 id) external view returns (Round memory) {
    return rounds[id];
  }

  function getCurrentRoundOrders() external view returns (Order[] memory) {
    return orders[numRounds];
  }

  function getPastRoundOrders(uint256 roundID) external view returns (Order[] memory) {
    return orders[roundID];
  }

  function getOrderData(uint256 roundID, uint256 id) external view returns (Order memory) {
    return orders[roundID][id];
  }

  // function getUserOrders(address account) external view returns (Order[] memory orders) {
  //   Order[] memory orders;
  //   // for (uint i = start; i <= end; i++) {
  //   //   Proposal memory p = proposals[i];
  //   //   props[i] = p;
  //   // }
  // }

  function getUserReferrer(address account) public view returns (address) {
    return referrers[account];
  }

  function getUserReferrers(address account) public view returns (address, address) {
    return (referrers[account], referrers[referrers[account]]);
  }

  function hasReferrer(address account) public view returns (bool) {
    return referrers[account] != address(0);
  }

  function calcCost(uint256 price, uint256 amount) public pure returns (uint256) {
    return price * (amount / 10 ** 18);
  }

  function sendEther(address account, uint256 amount) private {
    (bool sent,) = account.call{value: amount}("");
    require(sent, "Failed to send Ether");
  }

  /** @notice Transfers reward in ETH to `account` referrers.
   * @dev This contract implements two-lvl referral system:
   *
   * In sale round Lvl1 referral gets 5% and Lvl2 gets 3%
   * If there are no referrals or only one, the contract gets these percents
   *
   * In trade round every referral takes 2.5% reward
   * If there are no referrals or only one, the contract gets these percents
   *
   * @param account The account to get the referrals from.
   * @param sum The amount to calc reward from.
   */
  function payReferrers(address account, uint256 sum) private {
    if (hasReferrer(account)) {
      address ref1 = getUserReferrer(account);
      // Reward ref 1
      sendEther(ref1, sum * (isSaleRound ? 500 : 250) / 10000);
      // Reward ref 2 (if exists)
      if (hasReferrer(ref1)) {
        sendEther(getUserReferrer(ref1), sum * (isSaleRound ? 300 : 250) / 10000);
      }
    }
  }

  function _cancelOrder(Order storage order) private {
    order.isOpen = false;
    // Return unsold tokens to the msg.sender
    if (order.amount > 0) IERC20(token).safeTransfer(order.account, order.amount);
  }

  function startSaleRound(uint256 oldPrice, uint256 tradeVolume) private {
    // Closing orders
    closeOpenOrders();
    // Calc new price as (oldPrice + 3% + 0.000004 eth)
    uint256 newPrice = oldPrice + (oldPrice * 300 / 10000) + 0.000004 ether;
    
    numRounds++;
    Round storage newRound = rounds[numRounds];
    newRound.createdAt = block.timestamp;
    newRound.endTime = block.timestamp + roundTime;
    newRound.price = newPrice;

    uint256 mintAmount = tradeVolume * (10 ** 18) / newPrice;
    ACDMToken(token).mint(address(this), mintAmount);

    newRound.tokensLeft = mintAmount;

    isSaleRound = true;
    emit FinishedTradeRound(numRounds - 1, tradeVolume);
    emit StartedSaleRound(numRounds, newPrice, oldPrice, mintAmount);
  }

  function startTradeRound(uint256 oldPrice, uint256 tokensLeft) private {
    // Burn unsold tokens
    if (tokensLeft > 0) ACDMToken(token).burn(address(this), tokensLeft);
  
    numRounds++;
    Round storage newRound = rounds[numRounds];
    newRound.createdAt = block.timestamp;
    newRound.endTime = block.timestamp + roundTime;
    newRound.price = oldPrice;

    isSaleRound = false;
    emit FinishedSaleRound(numRounds - 1, oldPrice, tokensLeft);
    emit StartedTradeRound(numRounds);
  }

  function closeOpenOrders() private {
    Order[] storage orders = orders[numRounds];
    for (uint256 i = 0; i < orders.length; i++) {
      if (orders[i].isOpen) {
        _cancelOrder(orders[i]);
        emit CancelledOrder(numRounds, i, msg.sender);
      }
    }
  }
}