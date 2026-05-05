// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OrderBookContract — per-bet mini exchange
 * @notice Standalone order book. Deployed once per bet.
 *         Holds all user funds. Handles trading during betting phase.
 *         Reads winning option from BetContract at resolution for payouts.
 */
contract OrderBookContract is ReentrancyGuard {
    struct Order {
        address maker;
        uint40  optionIndex;
        bool    isBid;
        uint96  price;
        uint96  amount;
        uint96  filled;
        uint40  timestamp;
        bool    active;
    }

    error InvalidOption();
    error InvalidAmount();
    error InvalidPrice();
    error NotBetting();
    error TransferFailed();
    error InsufficientBalance();
    error InsufficientShares();
    error NotSettled();

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event OrderPlaced(uint256 indexed orderId, address indexed maker, uint256 optionIndex, bool isBid, uint256 price, uint256 amount);
    event OrderMatched(uint256 indexed bidId, uint256 indexed askId, address buyer, address seller, uint256 optionIndex, uint256 price, uint256 amount);
    event OrderCancelled(uint256 indexed orderId, uint256 refundEth, uint256 refundShares);
    event RewardClaimed(address indexed user, uint256 amount);

    // ===== Immutables =====
    address public immutable factory;
    address public immutable optionAddr;  // reads winningOption from here
    address public immutable creator;
    uint256 public immutable optionCount;
    uint256 public immutable bettingEndTime;

    // ===== State =====
    mapping(address => uint256) public balances;
    mapping(address => mapping(uint256 => uint256)) public positions;
    mapping(uint256 => uint256) public totalShares;

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId = 1;
    mapping(uint256 => uint256[]) public bids;    // option => orderIds (price desc)
    mapping(uint256 => uint256[]) public asks;    // option => orderIds (price asc)
    mapping(address => uint256[]) public userOrders;

    uint256 public winningOption;
    bool    public resolved;
    mapping(address => bool) public claimed;

    uint256 public constant MAX_OPEN = 50;
    uint256 public constant MAX_DEPTH = 200;

    // ===== Modifiers =====
    modifier bettingOpen() { require(!resolved && block.timestamp <= bettingEndTime); _; }
    modifier afterResolve() { require(resolved); _; }

    // ===== Constructor =====
    constructor(address _optionAddr, uint256 _optionCount) {
        factory = msg.sender;
        optionAddr = _optionAddr;
        creator = tx.origin;
        optionCount = _optionCount;
        (bool ok, bytes memory data) = _optionAddr.staticcall(abi.encodeWithSignature("bettingEndTime()"));
        uint256 _betEnd = ok ? abi.decode(data, (uint256)) : type(uint256).max;
        bettingEndTime = _betEnd;
    }

    receive() external payable { balances[msg.sender] += msg.value; emit Deposited(msg.sender, msg.value); }

    // ===== Deposit/Withdraw =====
    function deposit() external payable { balances[msg.sender] += msg.value; emit Deposited(msg.sender, msg.value); }
    function withdraw(uint256 _amount) external nonReentrant { require(balances[msg.sender] >= _amount); balances[msg.sender] -= _amount; (bool ok,) = msg.sender.call{value: _amount}(""); require(ok); emit Withdrawn(msg.sender, _amount); }

    // ===== Order Book =====
    function placeBuy(uint256 _opt, uint256 _price, uint256 _amount) external bettingOpen nonReentrant returns (uint256 oid) {
        require(_opt < optionCount && _price > 0 && _amount > 0);
        uint256 lock = (_price * _amount) / 1 ether;
        require(balances[msg.sender] >= lock); balances[msg.sender] -= lock;

        uint256 rem = _amount; uint256 i = 0;
        while (i < asks[_opt].length && rem > 0) {
            uint256 aid = asks[_opt][i]; Order storage a = orders[aid];
            if (!a.active || a.filled >= a.amount) { i++; continue; }
            if (uint256(a.price) > _price) break;
            uint256 ar = uint256(a.amount) - uint256(a.filled);
            uint256 m = rem < ar ? rem : ar;
            uint256 cost = (uint256(a.price) * m) / 1 ether;
            balances[a.maker] += cost;
            balances[msg.sender] += ((_price - uint256(a.price)) * m) / 1 ether;
            positions[msg.sender][_opt] += m;
            a.filled += uint96(m); rem -= m;
            emit OrderMatched(0, aid, msg.sender, a.maker, _opt, a.price, m);
            if (a.filled >= a.amount) { _rm(asks[_opt], i); a.active = false; _rmUser(a.maker, aid); } else { i++; }
        }
        if (rem > 0) {
            require(bids[_opt].length < MAX_DEPTH && userOrders[msg.sender].length < MAX_OPEN);
            oid = _create(msg.sender, _opt, true, uint96(_price), uint96(rem));
        }
    }

    function placeSell(uint256 _opt, uint256 _price, uint256 _amount) external bettingOpen nonReentrant returns (uint256 oid) {
        require(_opt < optionCount && _price > 0 && _amount > 0);
        require(positions[msg.sender][_opt] >= _amount); positions[msg.sender][_opt] -= _amount;

        uint256 rem = _amount; uint256 i = 0;
        while (i < bids[_opt].length && rem > 0) {
            uint256 bid = bids[_opt][i]; Order storage b = orders[bid];
            if (!b.active || b.filled >= b.amount) { i++; continue; }
            if (uint256(b.price) < _price) break;
            uint256 br = uint256(b.amount) - uint256(b.filled);
            uint256 m = rem < br ? rem : br;
            balances[msg.sender] += (uint256(b.price) * m) / 1 ether;
            positions[b.maker][_opt] += m;
            b.filled += uint96(m); rem -= m;
            emit OrderMatched(bid, 0, b.maker, msg.sender, _opt, b.price, m);
            if (b.filled >= b.amount) { _rm(bids[_opt], i); b.active = false; _rmUser(b.maker, bid); } else { i++; }
        }
        if (rem > 0) {
            require(asks[_opt].length < MAX_DEPTH && userOrders[msg.sender].length < MAX_OPEN);
            oid = _create(msg.sender, _opt, false, uint96(_price), uint96(rem));
        }
    }

    function cancelOrder(uint256 _oid) external nonReentrant {
        Order storage o = orders[_oid];
        require(o.maker == msg.sender && o.active && o.filled < o.amount);
        uint256 rem = uint256(o.amount) - uint256(o.filled); uint256 opt = uint256(o.optionIndex);
        o.active = false;
        if (o.isBid) { _rm(bids[opt], _find(bids[opt], _oid)); balances[msg.sender] += (uint256(o.price) * rem) / 1 ether; emit OrderCancelled(_oid, (uint256(o.price) * rem) / 1 ether, 0); }
        else { _rm(asks[opt], _find(asks[opt], _oid)); positions[msg.sender][opt] += rem; emit OrderCancelled(_oid, 0, rem); }
        _rmUser(msg.sender, _oid);
    }

    // ===== Resolution =====
    function resolve() external {
        require(!resolved && block.timestamp > bettingEndTime);
        // Read winning option from BetContract
        (bool ok, bytes memory data) = optionAddr.staticcall(abi.encodeWithSignature("winningOption()"));
        if (ok) winningOption = abi.decode(data, (uint256));
        resolved = true;
    }

    function claimReward() external nonReentrant afterResolve {
        require(!claimed[msg.sender]);
        uint256 shares = positions[msg.sender][winningOption];
        uint256 bal = balances[msg.sender];
        uint256 total = shares + bal;
        require(total > 0, "No reward");
        claimed[msg.sender] = true;
        (bool ok,) = msg.sender.call{value: total}("");
        require(ok);
        emit RewardClaimed(msg.sender, total);
    }

    // ===== Views =====
    function getBook(uint256 _opt) external view returns (
        uint256[] memory bp, uint256[] memory ba, uint256[] memory ap, uint256[] memory aa
    ) {
        uint256[] storage bs = bids[_opt]; uint256[] storage as_ = asks[_opt];
        bp = new uint256[](bs.length); ba = new uint256[](bs.length); ap = new uint256[](as_.length); aa = new uint256[](as_.length);
        for (uint256 i = 0; i < bs.length; i++) { Order storage o = orders[bs[i]]; bp[i] = o.price; ba[i] = uint256(o.amount) - uint256(o.filled); }
        for (uint256 i = 0; i < as_.length; i++) { Order storage o = orders[as_[i]]; ap[i] = o.price; aa[i] = uint256(o.amount) - uint256(o.filled); }
    }

    function getPosition(address _u) external view returns (uint256[] memory a) { a = new uint256[](optionCount); for (uint256 i=0;i<optionCount;i++) a[i]=positions[_u][i]; }

    // ===== Internal =====
    function _create(address _m, uint256 _opt, bool _bid, uint96 _p, uint96 _amt) internal returns (uint256 id) {
        id = nextOrderId++;
        orders[id] = Order(_m, uint40(_opt), _bid, _p, _amt, 0, uint40(block.timestamp), true);
        _ins(_bid ? bids[_opt] : asks[_opt], id, _bid);
        userOrders[_m].push(id);
        emit OrderPlaced(id, _m, _opt, _bid, _p, _amt);
    }

    function _ins(uint256[] storage _l, uint256 _id, bool _bid) internal {
        Order storage o = orders[_id]; uint256 pos = _l.length;
        for (uint256 i=0;i<_l.length;i++) { Order storage c = orders[_l[i]]; if (!c.active) continue;
            if (_bid) { if (o.price > c.price || (o.price == c.price && o.timestamp < c.timestamp)) { pos=i; break; } }
            else { if (o.price < c.price || (o.price == c.price && o.timestamp < c.timestamp)) { pos=i; break; } }
        }
        _l.push(0); for (uint256 j=_l.length-1;j>pos;j--) _l[j]=_l[j-1]; _l[pos]=_id;
    }

    function _rm(uint256[] storage _l, uint256 _i) internal { for (uint256 i=_i;i<_l.length-1;i++) _l[i]=_l[i+1]; _l.pop(); }
    function _find(uint256[] storage _l, uint256 _id) internal view returns (uint256) { for (uint256 i=0;i<_l.length;i++) if (_l[i]==_id) return i; revert("not found"); }
    function _rmUser(address _u, uint256 _id) internal { uint256[] storage uo = userOrders[_u]; for (uint256 i=0;i<uo.length;i++) if (uo[i]==_id) { _rm(uo,i); return; } }
}
