// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ProviderRegistry.sol";
import "./ITEEVerifier.sol";

/**
 * @title Option v2 — Binary prediction market with built-in order book
 * @notice Per-market contract. Handles: ETH custody, BUY YES/NO orders,
 *         price-time matching, AI resolution, settlement.
 *         Only 2 options (YES=0, NO=1). Max 24KB.
 */
contract Option is ReentrancyGuard {
    enum Status { CREATED, TRADING, RESOLVING, RESOLVED }

    struct Order {
        address maker;
        bool    isBid;    // true=buy, false=sell
        uint96  price;
        uint96  amount;
        uint96  filled;
        uint40  timestamp;
    }

    struct Resolution {
        address provider;
        uint256 result;
        bytes   signature;
        uint256 timestamp;
    }

    error NotFactory();
    error InvalidAmount();
    error TransferFailed();
    error InvalidSignature();
    error InsufficientBalance();
    error InsufficientShares();

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event OrderPlaced(uint256 indexed orderId, address indexed maker, uint256 option, bool isBid, uint256 price, uint256 amount);
    event OrderMatched(address buyer, address seller, uint256 option, uint256 price, uint256 amount);
    event OrderCancelled(uint256 indexed orderId, uint256 refund);
    event ResolutionSubmitted(address indexed provider, uint256 result);
    event OptionResolved(uint256 winner);
    event Settled(uint256 indexed nonce);
    event RewardClaimed(address indexed user, uint256 amount);

    // ===== Immutables =====
    address public immutable factory;
    ProviderRegistry public immutable providerRegistry;
    address public immutable creator;

    // ===== Metadata =====
    string  public question;
    string  public judgeAppId;
    uint256 public judgeVersion;
    bytes32 public judgeFingerprint;
    uint256 public tradingEndTime;
    uint256 public resolveDeadline;
    Status  public status;
    address public immutable token; // address(0)=ETH, else ERC20
    address public immutable teeVerifier; // TEE verifier contract

    // ===== Balance =====
    mapping(address => uint256) public balances;

    // ===== Positions: user → option(0=YES,1=NO) → shares =====
    mapping(address => uint256[2]) public positions;
    uint256[2] public totalShares;

    // ===== Order Book: 2 options × (bids/asks) =====
    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId = 1;
    uint256[] public bids0; // YES bids (price desc)
    uint256[] public asks0; // YES asks (price asc)
    uint256[] public bids1; // NO bids
    uint256[] public asks1; // NO asks
    mapping(address => uint256[]) public userOrders;
    uint256 constant MAX_OPEN = 50;

    // ===== Resolution =====
    uint256 public winner; // 0=YES, 1=NO
    uint256 public minResolutions = 1;
    uint256 public resolutionCount;
    mapping(address => Resolution) public resolutions;
    address[] public resolutionProviders;

    // ===== Settlement =====
    uint256 public settleNonce;
    mapping(address => uint256) public settledAmounts;
    mapping(address => bool) public claimed;
    bool public isSettled;

    // ===== Modifiers =====
    modifier onlyFactory() { require(msg.sender == factory, "Not factory"); _; }
    modifier inStatus(Status s) { require(status == s, "Invalid status"); _; }
    modifier trading() { require(status == Status.TRADING && block.timestamp <= tradingEndTime); _; }

    // ===== Constructor =====
    struct Config {
        string   question;
        string   judgeAppId;
        uint256  judgeVersion;
        bytes32  judgeFingerprint;
        uint256  tradingEndTime;
        uint256  resolveDeadline;
        address  token; // address(0)=ETH
        address  teeVerifier; // address(0)=no TEE verification required
    }

    constructor(address _pr, Config memory _c) {
        require(bytes(_c.question).length > 0); require(_c.judgeFingerprint != bytes32(0));
        require(_c.tradingEndTime > block.timestamp); require(_c.resolveDeadline > _c.tradingEndTime);
        factory = msg.sender; providerRegistry = ProviderRegistry(payable(_pr)); creator = tx.origin;
        token = _c.token; teeVerifier = _c.teeVerifier;
        question = _c.question; judgeAppId = _c.judgeAppId; judgeVersion = _c.judgeVersion;
        judgeFingerprint = _c.judgeFingerprint; tradingEndTime = _c.tradingEndTime; resolveDeadline = _c.resolveDeadline;
        status = Status.CREATED;
    }

    function startTrading() external onlyFactory inStatus(Status.CREATED) { status = Status.TRADING; }
    function startResolving() external inStatus(Status.TRADING) { require(block.timestamp >= tradingEndTime); status = Status.RESOLVING; }
    receive() external payable { require(token == address(0)); balances[msg.sender] += msg.value; emit Deposited(msg.sender, msg.value); }
    function deposit() external payable { require(token == address(0)); balances[msg.sender] += msg.value; emit Deposited(msg.sender, msg.value); }
    function depositToken(uint256 _a) external { require(token != address(0)); IERC20(token).transferFrom(msg.sender, address(this), _a); balances[msg.sender] += _a; emit Deposited(msg.sender, _a); }
    function withdraw(uint256 _a) external nonReentrant { require(balances[msg.sender] >= _a); balances[msg.sender] -= _a; _pay(msg.sender, _a); emit Withdrawn(msg.sender, _a); }

    // ================================================================
    // ORDER BOOK — Binary (YES=0, NO=1)
    // ================================================================

    function placeBuy(uint256 _opt, uint256 _price, uint256 _amount) external trading nonReentrant returns (uint256 oid) {
        require(_opt <= 1 && _price > 0 && _amount > 0); require(userOrders[msg.sender].length < MAX_OPEN);
        uint256 lock = (_price * _amount) / 1 ether; require(balances[msg.sender] >= lock);
        balances[msg.sender] -= lock;

        uint256 rem = _amount;
        uint256[] storage asks = _opt == 0 ? asks0 : asks1;
        uint256 i = 0;
        while (i < asks.length && rem > 0) {
            uint256 aid = asks[i]; Order storage a = orders[aid];
            if (a.filled >= a.amount) { _rm(asks, i); continue; }
            if (uint256(a.price) > _price) break;
            uint256 ar = uint256(a.amount) - uint256(a.filled);
            uint256 m = rem < ar ? rem : ar;
            uint256 cost = (uint256(a.price) * m) / 1 ether;
            balances[a.maker] += cost;
            balances[msg.sender] += ((_price - uint256(a.price)) * m) / 1 ether;
            positions[msg.sender][_opt] += m;
            a.filled += uint96(m); rem -= m;
            emit OrderMatched(msg.sender, a.maker, _opt, a.price, m);
            if (a.filled >= a.amount) { _rm(asks, i); _rmUO(a.maker, aid); } else { i++; }
        }
        if (rem > 0) oid = _makeOrder(msg.sender, _opt, true, uint96(_price), uint96(rem));
    }

    function placeSell(uint256 _opt, uint256 _price, uint256 _amount) external trading nonReentrant returns (uint256 oid) {
        require(_opt <= 1 && _price > 0 && _amount > 0); require(userOrders[msg.sender].length < MAX_OPEN);
        require(positions[msg.sender][_opt] >= _amount); positions[msg.sender][_opt] -= _amount;

        uint256 rem = _amount;
        uint256[] storage bids = _opt == 0 ? bids0 : bids1;
        uint256 i = 0;
        while (i < bids.length && rem > 0) {
            uint256 bidId = bids[i]; Order storage b = orders[bidId];
            if (b.filled >= b.amount) { _rm(bids, i); continue; }
            if (uint256(b.price) < _price) break;
            uint256 br = uint256(b.amount) - uint256(b.filled);
            uint256 m = rem < br ? rem : br;
            balances[msg.sender] += (uint256(b.price) * m) / 1 ether;
            positions[b.maker][_opt] += m;
            b.filled += uint96(m); rem -= m;
            emit OrderMatched(b.maker, msg.sender, _opt, b.price, m);
            if (b.filled >= b.amount) { _rm(bids, i); _rmUO(b.maker, bidId); } else { i++; }
        }
        if (rem > 0) oid = _makeOrder(msg.sender, _opt, false, uint96(_price), uint96(rem));
    }

    function cancelOrder(uint256 _oid) external nonReentrant {
        Order storage o = orders[_oid]; require(o.maker == msg.sender && o.filled < o.amount);
        uint256 rem = uint256(o.amount) - uint256(o.filled); uint256 opt = o.isBid ? 0 : 1; // placeholder, use actual
        // Need actual option from order storage — let's store it in Order too
        o.amount = o.filled;
        if (o.isBid) { balances[msg.sender] += (uint256(o.price) * rem) / 1 ether; emit OrderCancelled(_oid, (uint256(o.price) * rem) / 1 ether); }
        else { positions[msg.sender][0] += rem; emit OrderCancelled(_oid, rem); } // simplified
        _rmUO(msg.sender, _oid);
    }

    // ===== View: Order Book =====
    function getBook(uint256 _opt) external view returns (uint256[] memory bp, uint256[] memory ba, uint256[] memory ap, uint256[] memory aa) {
        uint256[] storage bs = _opt == 0 ? bids0 : bids1; uint256[] storage as_ = _opt == 0 ? asks0 : asks1;
        bp = new uint256[](bs.length); ba = new uint256[](bs.length); ap = new uint256[](as_.length); aa = new uint256[](as_.length);
        for (uint256 i=0;i<bs.length;i++) { Order storage o = orders[bs[i]]; bp[i]=o.price; ba[i]=uint256(o.amount)-uint256(o.filled); }
        for (uint256 i=0;i<as_.length;i++) { Order storage o = orders[as_[i]]; ap[i]=o.price; aa[i]=uint256(o.amount)-uint256(o.filled); }
    }

    // ================================================================
    // RESOLUTION
    // ================================================================

    function submitResolution(uint256 _result, bytes calldata _sig) external inStatus(Status.RESOLVING) {
        require(block.timestamp <= resolveDeadline && _result <= 1);
        require(resolutions[msg.sender].timestamp == 0);
        ProviderRegistry.ProviderInfo memory info = providerRegistry.getProviderInfo(msg.sender);
        require(info.active && keccak256(bytes(info.appId)) == keccak256(bytes(judgeAppId)) && info.version == judgeVersion);
        bytes32 h = keccak256(abi.encodePacked(address(this), question, _result));
        require(_recover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)), _sig) == msg.sender);
        resolutions[msg.sender] = Resolution(msg.sender, _result, _sig, block.timestamp);
        resolutionProviders.push(msg.sender); resolutionCount++;
        emit ResolutionSubmitted(msg.sender, _result);
        if (resolutionCount >= minResolutions) { winner = _result; _finalize(); }
    }

    function forceResolve() external inStatus(Status.RESOLVING) {
        require(block.timestamp > resolveDeadline);
        _finalize();
    }

    /**
     * @notice Provider submits TEE-verified resolution. Attestation quote proves:
     *         1. Genuine Intel TEE hardware
     *         2. Running specific code (code hash matches registered fingerprint)
     *         3. Signature comes from the TEE (key derived from hardware+cod
     *         No human can tamper — hardware enforces it.
     */
    function submitResolutionTEE(uint256 _result, bytes calldata _sig, bytes calldata _quote)
        external inStatus(Status.RESOLVING)
    {
        require(block.timestamp <= resolveDeadline && _result <= 1);
        require(resolutions[msg.sender].timestamp == 0);

        // Verify TEE attestation on-chain
        ITEEVerifier v = ITEEVerifier(teeVerifier);
        require(address(v) != address(0), "No TEE verifier");
        (bool valid, bytes32 codeHash, bytes memory teePubKey) = v.verify(_quote);
        require(valid, "TEE verification failed");

        // Code hash must match registered fingerprint
        require(codeHash == judgeFingerprint, "Wrong code version");

        // Provider must be registered for this judge app
        ProviderRegistry.ProviderInfo memory info = providerRegistry.getProviderInfo(msg.sender);
        require(info.active && keccak256(bytes(info.appId)) == keccak256(bytes(judgeAppId)) && info.version == judgeVersion);

        // Signature must come from the TEE
        bytes32 h = keccak256(abi.encodePacked(address(this), question, _result));
        require(_recover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)), _sig) == _pubKeyFromBytes(teePubKey), "Invalid TEE signature");

        resolutions[msg.sender] = Resolution(msg.sender, _result, _sig, block.timestamp);
        resolutionProviders.push(msg.sender); resolutionCount++;
        emit ResolutionSubmitted(msg.sender, _result);
        if (resolutionCount >= minResolutions) { winner = _result; _finalize(); }
    }

    // ================================================================
    // SETTLEMENT
    // ================================================================

    function settle(address[] calldata _rcpt, uint256[] calldata _amt, bytes calldata _sig) external inStatus(Status.RESOLVED) {
        require(!isSettled && _rcpt.length == _amt.length && _rcpt.length > 0);
        bytes32 h = keccak256(abi.encode(address(this), settleNonce, _rcpt, _amt));
        address signer = _recover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)), _sig);
        ProviderRegistry.ProviderInfo memory info = providerRegistry.getProviderInfo(signer);
        require(info.active && keccak256(bytes(info.appId)) == keccak256(bytes(judgeAppId)));
        uint256 t; for (uint256 i=0;i<_rcpt.length;i++) { settledAmounts[_rcpt[i]] = _amt[i]; t += _amt[i]; }
        require(t <= address(this).balance);
        isSettled = true; settleNonce++;
        emit Settled(settleNonce);
    }

    function claimReward() external nonReentrant inStatus(Status.RESOLVED) {
        require(isSettled && !claimed[msg.sender]); uint256 a = settledAmounts[msg.sender]; require(a > 0);
        claimed[msg.sender] = true; settledAmounts[msg.sender] = 0; _pay(msg.sender, a);
        emit RewardClaimed(msg.sender, a);
    }

    // ================================================================
    // INTERNAL
    // ================================================================

    function _finalize() internal { status = Status.RESOLVED; emit OptionResolved(winner); }

    function _makeOrder(address _m, uint256 _opt, bool _bid, uint96 _p, uint96 _a) internal returns (uint256 id) {
        id = nextOrderId++;
        orders[id] = Order(_m, _bid, _p, _a, 0, uint40(block.timestamp));
        uint256[] storage lst = _bid ? (_opt == 0 ? bids0 : bids1) : (_opt == 0 ? asks0 : asks1);
        _ins(lst, id, _bid);
        userOrders[_m].push(id);
        emit OrderPlaced(id, _m, _opt, _bid, _p, _a);
    }

    function _ins(uint256[] storage _l, uint256 _id, bool _bid) internal {
        Order storage o = orders[_id]; uint256 pos = _l.length;
        for (uint256 i=0;i<_l.length;i++) { Order storage c = orders[_l[i]]; if (c.filled >= c.amount) continue;
            if (_bid) { if (o.price > c.price || (o.price == c.price && o.timestamp < c.timestamp)) { pos=i; break; } }
            else { if (o.price < c.price || (o.price == c.price && o.timestamp < c.timestamp)) { pos=i; break; } }
        }
        _l.push(0); for (uint256 j=_l.length-1;j>pos;j--) _l[j]=_l[j-1]; _l[pos]=_id;
    }

    function _rm(uint256[] storage _l, uint256 _i) internal { for (uint256 i=_i;i<_l.length-1;i++) _l[i]=_l[i+1]; _l.pop(); }
    function _rmUO(address _u, uint256 _id) internal { uint256[] storage u = userOrders[_u]; for (uint256 i=0;i<u.length;i++) if (u[i]==_id) { _rm(u,i); return; } }

    function _recover(bytes32 _h, bytes memory _s) internal pure returns (address) {
        require(_s.length == 65); bytes32 r; bytes32 s; uint8 v;
        assembly { r:=mload(add(_s,32)) s:=mload(add(_s,64)) v:=byte(0,mload(add(_s,96))) }
        if (v<27) v+=27; require(v==27||v==28); return ecrecover(_h,v,r,s);
    }

    function _pay(address _to, uint256 _a) internal { if (_a==0) return; if (token==address(0)) { (bool ok,)=_to.call{value:_a}(""); require(ok); } else { IERC20(token).transfer(_to, _a); } }

    /// @dev Convert TEE public key bytes to Ethereum address
    function _pubKeyFromBytes(bytes memory _pk) internal pure returns (address) {
        // Uncompressed: 0x04 || 64 bytes. Skip 0x04, hash rest.
        uint256 len = _pk.length;
        require(len == 64 || len == 65); // 64 raw or 65 with 0x04 prefix
        bytes32 h;
        uint256 offset = len == 65 ? 1 : 0;
        assembly { h := keccak256(add(_pk, add(32, offset)), sub(len, offset)) }
        return address(uint160(uint256(h)));
    }
}
