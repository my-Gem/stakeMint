// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// 引入ReentrancyGuard,防止重入攻击
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract stakeMint is ReentrancyGuard {
	
    address public USDT;
    address public GBC;
	// 每质押100u usdt固定的算力
	uint256 public constant HASHRATE = 1e16; // 0.01
	// 用户每小时可挖出的token数量即算力
	uint256 public constant BASICCOMPUTINGPOWER = 3e16; // 0.03
	// 可赎取奖励的间隔时间
	uint256 public constant TIMEINTERVAL = 24 hours;

	// 矿工结构体
	struct Minter {
	    // 是否开启挖矿
		bool isStartMint;
		// 开启挖矿时间戳
		uint256 startMintTime;
		// 质押的USDT
		uint256 totalUsdt;
		// 上次领取收益的时间戳
		uint256 lastMintTime;
	}

	// 映射对应的矿工信息
	mapping(address => Minter) public minter;

	 // 只允许外部账户操作
    modifier OnlyEOA() {
        require(msg.sender == tx.origin,"Only EOA");
        _;
    }

	// 开启挖矿触发的事件
    event StartMint(
        address indexed owner,
        bool  isStartMint,
        uint256 startMintTime,
        uint256 lastMintTime
    );

    // 质押挖矿触发的事件
    event StakeMint(
        address indexed owner,
        uint256 amount,
        uint256 totalUsdt
    );

    // 赎取奖励触发的事件
    event WithdrawRewards(
        address indexed owner,
        uint256 reward
    );

    // 赎回质押的USDT触发的事件
    event WithdrawStake(address indexed user, uint256 amount);

	constructor(address _usdt, address _gbc) {
		USDT = _usdt;
		GBC = _gbc;
	}


	// 点击开始挖矿
	function startMint() external OnlyEOA nonReentrant {
	    address owner = msg.sender;
		Minter storage _minter = minter[owner];
		require(!_minter.isStartMint, "Mining started");
		_minter.startMintTime = block.timestamp;
		_minter.lastMintTime = block.timestamp;
		_minter.isStartMint = true;
		emit StartMint(owner, true, _minter.startMintTime, _minter.lastMintTime);
	}



	// 质押usdt
	function stakeUsdt(uint256 amount) external OnlyEOA nonReentrant {
	    address from = msg.sender;
	    // 确保开启了挖矿
		require(minter[from].isStartMint && minter[from].startMintTime > 0, "Please start mining");
		 // 确保质押的usdt大于0
		require(amount > 0, "The quantity must be greater than 0");
		// 确保质押的100 usdt必须是整数倍
		require(amount % 100e6 == 0, "USDT must be an integer multiple of 100");

		// 质押前如有奖励先领取奖励,防漏掉奖励
		if (block.timestamp >= minter[from].lastMintTime + TIMEINTERVAL) {
			_withdrawRewards(from);
		}

		// 查询usdt授权给当前合约的数量
        (bool success, bytes memory data) = USDT.staticcall(
            abi.encodeWithSignature(
                "allowance(address,address)",
                from,
                address(this)
            )
        );
        require(success && data.length > 0, "Allowance failed");
        // 解析授权的usdt数量
        uint256 allowanceUsdt = abi.decode(data, (uint256));
		// usdt精度是6, 确保转入的usdt是整数倍
        require(allowanceUsdt >= amount, "Insufficient authorization quantity");
        // 将usdt转入当前合约
        (bool success1, bytes memory data1) = USDT.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                from,
                address(this),
                amount
            )
        );
        require(
            (success1 && data1.length == 0) || (abi.decode(data1, (bool))),
            "TransferFrom failed"
        );

        // 用户总共质押了多少USDT
		minter[from].totalUsdt += amount;
		emit StakeMint(from, amount, minter[from].totalUsdt);
	}

	// 获取算力
	function getPower(address user) public view returns (uint256) {
		return BASICCOMPUTINGPOWER + (minter[user].totalUsdt / 100e6) * HASHRATE;
	}

	// 查询可领取奖励
	function pendingRewards(address user) public view returns (uint256 reward, uint256 power) {
		Minter storage m = minter[user];
		// 没开启挖矿直接返回0奖励
		if (!m.isStartMint || m.startMintTime == 0) {
			return (0, 0);
		}
		// 没到24小时不能领取
		if (block.timestamp < m.lastMintTime + TIMEINTERVAL) {
			return (0, getPower(user));
		}
		// 算一下距离上次领奖过了多少小时
		uint256 passHours = (block.timestamp - m.lastMintTime) / 1 hours;
		power = getPower(user);
		reward = power * passHours;
	}

	// 内部函数，矿工领取奖励
    function _withdrawRewards(address user) internal  {
		Minter storage m = minter[user];
		// 必须开启了挖矿
		require(m.isStartMint && m.startMintTime > 0, "Mining not started");
		// 必须到24小时才能领
		require(block.timestamp >= m.lastMintTime + TIMEINTERVAL, "Not time yet");
		(uint256 reward, ) = pendingRewards(user);
		require(reward > 0, "No rewards");
		
		// 查询当前合约有足够的GBC
        (bool success3, bytes memory data3) = GBC.staticcall(
            abi.encodeWithSignature(
                "balanceOf(address)",
                address(this)
            )
        );
        require(success3 && data3.length > 0, "Query quantity failed");
        // 获取GBC数量
        uint256 gbcAmount = abi.decode(data3, (uint256));
        require(gbcAmount > 0 && gbcAmount >= reward, "Insufficient GBC in contract");
		
		// 更新上次领奖时间
		m.lastMintTime = m.lastMintTime + ((block.timestamp - m.lastMintTime) / 1 hours) * 1 hours;
		// 取回GBC奖励
		(bool success4, ) = GBC.call(abi.encodeWithSelector(0xa9059cbb, user, reward));
        require(success4, "GBC transfer failed");
		emit WithdrawRewards(user, reward);
	}
    
	// 领取质押usdt的奖励
	function withdrawRewards() external OnlyEOA nonReentrant  {
        address from = msg.sender;
		_withdrawRewards(from);
	}

    // 赎回质押的USDT
    function withdrawStakeUsdt(uint256 amount) external OnlyEOA nonReentrant {
        address user = msg.sender;
        Minter storage m = minter[user];
        require(m.isStartMint && m.startMintTime > 0, "Mining not started");
        require(amount > 0 && amount <= m.totalUsdt, "Invalid amount");

        // 取回质押usdt之前,如果有奖励先领取奖励
        if (block.timestamp >= m.lastMintTime + TIMEINTERVAL) {
            _withdrawRewards(user);
        }

        m.totalUsdt -= amount;

        // 确保当前合约有足够的USDT
        (bool success1, bytes memory data1) = USDT.staticcall(
            abi.encodeWithSignature(
                "balanceOf(address)",
                address(this)
            )
        );
        require(success1 && data1.length > 0, "Get balance failed");
        // 解析当前合约的usdt数量
        uint256 contractUsdt = abi.decode(data1, (uint256));
        require(contractUsdt >= amount, "Contract usdt not enough");

        // 转账USDT给到用户   
        (bool success2, bytes memory data2) = USDT.call(abi.encodeWithSelector(0xa9059cbb, user, amount));
        require(success2 && (data2.length == 0 || abi.decode(data2, (bool))), "Transfer failed");
        emit WithdrawStake(user, amount);
    }

	
}
