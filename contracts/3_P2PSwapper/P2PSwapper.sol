// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.0;

// helper methods for interacting with ERC20 tokens and sending ETH that do not consistently return true/false
library TransferHelper {
    function safeApprove(
        address token,
        address to,
        uint256 value
    ) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            'TransferHelper::safeApprove: approve failed'
        );
    }

    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            'TransferHelper::safeTransfer: transfer failed'
        );
    }

    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            'TransferHelper::transferFrom: transferFrom failed'
        );
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'TransferHelper::safeTransferETH: ETH transfer failed');
    }
}


library SafeMath {
    function add(uint a, uint b) internal pure returns (uint c) { c = a + b; require(c >= a); }
    function sub(uint a, uint b) internal pure returns (uint c) { require(a >= b); c = a - b; }
    function mul(uint a, uint b) internal pure returns (uint c) { c = a * b; require(a == 0 || c / a == b); }
    function div(uint a, uint b) internal pure returns (uint c) { require(b > 0); c = a / b; }
}


contract P2P_WETH {
    using SafeMath for uint;
    string public name     = "P2P SwapWrapped Ether";
    string public symbol   = "P2PETH";
    uint8  public decimals = 18;

    event  Approval(address indexed src, address indexed guy, uint wad);
    event  Transfer(address indexed src, address indexed dst, uint wad);
    event  Deposit(address indexed dst, uint wad);
    event  Withdrawal(address indexed src, uint wad);

    mapping (address => uint)                       public  balanceOf;
    mapping (address => mapping (address => uint))  public  allowance;
    
    receive() payable external {
        deposit();
    }
    
    function deposit() public payable {
        balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
        emit Deposit(msg.sender, msg.value);
    }
    
    function withdraw(
        uint wad
    ) public {
        require(balanceOf[msg.sender] >= wad);
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(wad);
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint) {
        return address(this).balance;
    }

    function approve(
        address guy,
        uint wad
    ) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(
        address dst,
        uint wad
    ) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(
        address src,
        address dst,
        uint wad
    ) public returns (bool) {
        require(balanceOf[src] >= wad);
        if (src != msg.sender && allowance[src][msg.sender] != uint(2 ** 256-1 )) {
            require(allowance[src][msg.sender] >= wad);
            allowance[src][msg.sender] -= wad;
        }
        balanceOf[src] = balanceOf[src].sub(wad);
        balanceOf[dst] = balanceOf[dst].add(wad);
        emit Transfer(src, dst, wad);
        return true;
    }    
}

interface IP2P_WETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
    function balanceOf(address) external returns (uint);
    function approve(address,uint) external returns (bool);
}

contract P2PSwapper {
    using SafeMath for uint;
    
    struct Deal {
        address initiator;
        address bidToken;
        uint bidPrice;
        address askToken;
        uint askAmount;
        uint status;        // 0 : 거래 가능 / 1 : 거래 완료 / 2 : 취소된 거래 / 3 : withdrawn
    }

    enum DealState {
        Active,
        Succeeded,
        Canceled,
        Withdrawn
    }

    event NewUser(address user, uint id, uint partnerId);
    event WithdrawFees(address partner, uint userId, uint amount);
    event NewDeal(address bidToken, uint bidPrice, address askToken, uint askAmount, uint dealId);
    event TakeDeal(uint dealId, address bidder);
    event CancelDeal(uint dealId);

    uint public dealCount;
    mapping(uint => Deal) public deals;
    mapping(address => uint[]) private _dealHistory;
    
    uint public userCount;
    mapping(uint => uint) public partnerFees;
    mapping(address => uint) public distributedFees;
    mapping(uint => uint) public partnerById;
    mapping(address => uint) public userByAddress;
    mapping(uint => address) public addressById;

    IP2P_WETH public immutable p2pweth;

    /// @param weth WETH(Wrapped ETH) 컨트랙트 주소
    /// @notice 3개의 mapping도 초기화 (userByAddress / addressById / partnerById)
    constructor(address weth) public {
        p2pweth = IP2P_WETH(weth);

        userByAddress[msg.sender] = 1;
        addressById[1] = msg.sender;
        partnerById[1] = 1;
    }

    // Prevent ReEntrancy Attack
    bool private entered = false;
    modifier nonReentrant() {
        require(entered == false, 'P2PSwapper: re-entrancy detected!');
        entered = true;
        _;
        entered = false;
    }

    /// @notice 매도 거래 생성을 위한 함수
    /// @param bidToken 매도할 토큰
    /// @param bidPrice 매도 금액
    /// @param askToken 매수할 토큰
    /// @param askAmount 매수 수량
    /// @dev 거래수수료(fee)는 msg.value를 통해 수신하며, 내부적으로 _createDeal()을 호출하여 거래 생성
    function createDeal(
        address bidToken,
        uint bidPrice,
        address askToken,
        uint askAmount
    ) external payable returns (uint dealId) {
        uint fee = msg.value;
        require(fee > 31337, "P2PSwapper: fee too low");            
        p2pweth.deposit{value: msg.value}();                        // fee는 31337 을 초과해서 지불해야 하며, 지불된 fee는 p2pweth 컨트랙트에 예치
        partnerFees[userByAddress[msg.sender]] = partnerFees[userByAddress[msg.sender]].add(fee.div(2));

        TransferHelper.safeTransferFrom(bidToken, msg.sender, address(this), bidPrice); // 거래사용자가 매도하고자 하는 bidToken을 매도 수량(bidPrice)만큼 P2PSwapper 컨트랙트로 전송
        dealId = _createDeal(bidToken, bidPrice, askToken, askAmount);  // 처리
    }

    
     /// @notice 매수 거래 생성을 위한 함수
     /// @param dealId deals[] 배열에 있는 deal 구조체를 포인팅하기 위한 인덱스값
     /// @dev 
    function takeDeal(
        uint dealId
    ) external nonReentrant {
        require(dealCount >= dealId && dealId > 0, "P2PSwapper: deal not found");

        Deal storage deal = deals[dealId];
        require(deal.status == 0, "P2PSwapper: deal not available");

        TransferHelper.safeTransferFrom(deal.askToken, msg.sender, deal.initiator, deal.askAmount); // 매수를 위해 deal 구조체에 명시된 금액을 매수요청자로부터 수신하여 매도인에게 전송
        _takeDeal(dealId);
    }

    /**
     * @notice 거래 취소 요청을 위한 함수
     * @param dealId deals[] 배열에 있는 deal 구조체를 포인팅하기 위한 인덱스값
     */
    function cancelDeal(
        uint dealId
    ) external nonReentrant { 
        require(dealCount >= dealId && dealId > 0, "P2PSwapper: deal not found");
        
        Deal storage deal = deals[dealId];
        require(deal.initiator == msg.sender, "P2PSwapper: access denied");     // 거래 최초 생성요청자 검증

        TransferHelper.safeTransfer(deal.bidToken, msg.sender, deal.bidPrice);  // 거래 생성요청자에게 매도금액 반환
        
        deal.status = 2;        // status = 2(cancle)로 설정
        emit CancelDeal(dealId);
    }

    /// @notice 입력받은 dealId에 저장된 거래의 상태 확인
    /// @param dealId deals[] 배열에 있는 deal 구조체를 포인팅하기 위한 인덱스 값
    function status(
        uint dealId
    ) public view returns (DealState) {
        require(dealCount >= dealId && dealId > 0, "P2PSwapper: deal not found");
        Deal storage deal = deals[dealId];
        if (deal.status == 1) {
            return DealState.Succeeded;
        } else if (deal.status == 2 || deal.status == 3) {
            return DealState(deal.status);
        } else {
            return DealState.Active;
        }
    }

    /// @notice 특정 사용자의 거래 내역을 확인
    /// @param user 거래 내역을 확인하고자 하는 사용자의 주소
    function dealHistory(
        address user
    ) public view returns (uint[] memory) {
        return _dealHistory[user];
    }

    /// @notice 오버라이딩된 signup(uint partnerId) 호출
    // function signup() public returns (uint) {
    //     return signup(1);
    // }

    /// @notice P2PSwapper 시스템 가입을 지원하는 함수
    /// @param partnerId 레퍼럴 프로그램 기능을 위한 주소이며, 추천인/파트너의 주소를 입력
    function signup(uint partnerId) public returns (uint id) {
        require(userByAddress[msg.sender] == 0, "P2PSwapper: user exists");
        require(addressById[partnerId] != address(0), "P2PSwapper: partner not found");
        
        id = ++userCount;                       // 사용자 식별값인 id는 ++하여 자동으로 설정
        userByAddress[msg.sender] = id;
        addressById[id] = msg.sender;
        partnerById[id] = partnerId;            // partnerId는 1로 고정?
        // 사용자 가입시
        // id = 1 , userByAddress[attacker] = 1 , addressById[1] = attacker , partnerById[1] = 1

        emit NewUser(msg.sender, id, partnerId);
    }

    /// @notice
    /// @param user 사용자
    function withdrawFees(address user) public nonReentrant returns (uint fees) {
        uint userId = userByAddress[user];          // 사용자 주소를 이용해 ID 확인
        require(partnerById[userId] == userByAddress[msg.sender], "P2PSwapper: user is not your referral");     // 레퍼럴 가입 여부 체크
        
        fees = partnerFees[userId].sub(distributedFees[user]);  // 분배할 fee 계산

        require(fees > 0, "P2PSwapper: no fees to distribute");

        distributedFees[user] = distributedFees[user].add(fees);
        p2pweth.withdraw(fees);
        TransferHelper.safeTransferETH(msg.sender, fees);

        emit WithdrawFees(msg.sender, userId, fees);
    }

    /// @notice 매도 거래 생성을 위한 함수로, createDeal()에서 내부적으로 호출 (실제 매도 거래 생성 처리 수행)
    /// @param bidToken 매도할 토큰 
    /// @param bidPrice 매도할 금액
    /// @param askToken 매수할 토큰
    /// @param askAmount 매수 수량
    function _createDeal(
        address bidToken,
        uint bidPrice,
        address askToken,
        uint askAmount
    ) private returns (uint dealId) { 
        // 거래 생성 조건
        // 1. 매수하고자 하는 askToken() 주소는 비어있어서는 안됨
        // 2. 매도 가격은 0 보다 커야 함
        // 3. 매수 수량도 0 보다 커야 함
        require(askToken != address(0), "P2PSwapper: invalid address");
        require(bidPrice > 0, "P2PSwapper: invalid bid price");
        require(askAmount > 0, "P2PSwapper: invalid ask amount");
        dealId = ++dealCount;
        Deal storage deal = deals[dealId];
        deal.initiator = msg.sender;
        deal.bidToken = bidToken;
        deal.bidPrice = bidPrice;
        deal.askToken = askToken;
        deal.askAmount = askAmount;
        
        _dealHistory[msg.sender].push(dealId);
        
        emit NewDeal(bidToken, bidPrice, askToken, askAmount, dealId);
    }

    /// @notice 매수 거래 생성을 위한 함수로, takeDeal()에서 내부적으로 호출 (실제 매수 거래 생성 처리 수행)
    /// @param dealId 매수자에게 매도자로부터의 토큰 전송
    function _takeDeal(
        uint dealId
    ) private { 
        Deal storage deal = deals[dealId];

        TransferHelper.safeTransfer(deal.bidToken, msg.sender, deal.bidPrice);

        deal.status = 1;
        emit TakeDeal(dealId, msg.sender);
    }

    receive() external payable {
        require(msg.sender == address(p2pweth), "P2PSwapper: transfer not allowed");
    }
 }