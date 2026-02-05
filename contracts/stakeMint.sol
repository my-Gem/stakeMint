// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/**
 * @title StakeMint
 * @notice 质押挖矿合约，集成 Chainlink Automation 每小时自动记录算力数据
 * @dev 基于原 stakeMint 合约，添加了 Chainlink Keeper 自动化功能
 */
contract StakeMint is Ownable, ReentrancyGuard, AutomationCompatibleInterface {
    
    address public immutable USDT;
    address public immutable GBC;
   
    // 每质押100u usdt固定的算力
    uint256 public constant HASHRATE = 1e16; // 0.01
    // 用户每小时可挖出的token数量即算力
    uint256 public constant BASICCOMPUTINGPOWER = 3e16; // 0.03
    // 可赎取奖励的间隔时间
    uint256 public constant TIMEINTERVAL = 24 hours;
    
    // ============ Chainlink Automation 相关 ============
    
    // 每小时更新一次算力快照
    uint256 public constant UPDATE_INTERVAL = 1 hours;
    
    // 上次更新时间
    uint256 public lastUpdateTime;
    
    // 算力快照结构体
    struct HashPowerSnapshot {
        uint256 timestamp;           // 快照时间戳
        uint256 totalHashPower;      // 总算力
        uint256 totalStakedUsdt;     // 总质押USDT
        uint256 totalMiners;         // 矿工总数
        uint256 blockNumber;         // 区块号
    }
    
    // 算力历史记录（最多保留最近168小时 = 7天）
    HashPowerSnapshot[] public hashPowerHistory;
    uint256 public constant MAX_HISTORY_LENGTH = 168;
    
    // 当前总质押USDT
    uint256 public totalStakedUsdt;
    
    // 活跃矿工数量
    uint256 public totalActiveMiners;

    // 矿工结构体
    struct Minter {
        bool isStartMint;
        uint256 startMintTime;
        uint256 totalUsdt;
        uint256 lastMintTime;
    }

    mapping(address => Minter) public minter;
    
    // 用于追踪所有矿工地址
    address[] public minerAddresses;
    mapping(address => bool) public isMinerRegistered;

    // ============ 修饰符 ============
    
    modifier OnlyEOA() {
        require(msg.sender == tx.origin, "Only EOA");
        _;
    }
    
    // ============ 事件 ============
    
    event StartMint(
        address indexed owner,
        bool isStartMint,
        uint256 startMintTime,
        uint256 lastMintTime
    );

    event Staked(address indexed owner, uint256 amount, uint256 totalUsdt);

    event WithdrawRewards(address indexed owner, uint256 reward);

    event WithdrawStake(address indexed user, uint256 amount);
    
    event HashPowerUpdated(
        uint256 indexed snapshotId,
        uint256 timestamp,
        uint256 totalHashPower,
        uint256 totalStakedUsdt,
        uint256 totalMiners
    );

    // ============ 构造函数 ============
    
    constructor(address usdt, address gbc) Ownable(msg.sender) {
        USDT = usdt;
        GBC = gbc;
        lastUpdateTime = block.timestamp;
        
        // 创建初始快照
        _createHashPowerSnapshot();
    }

    // ============ Chainlink Automation 接口实现 ============
    
    /**
     * @notice Chainlink Keeper 调用此函数检查是否需要执行
     * @dev 当距离上次更新超过 1 小时时返回 true
     * @return upkeepNeeded 是否需要执行 upkeep
     * @return performData 传递给 performUpkeep 的数据
     */
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp - lastUpdateTime) >= UPDATE_INTERVAL;
        performData = "";
    }

    /**
     * @notice Chainlink Keeper 自动调用此函数执行算力更新
     * @dev 创建新的算力快照并更新相关数据
     */
    function performUpkeep(bytes calldata /* performData */) external override {
        // 再次检查条件，防止多次调用
        if ((block.timestamp - lastUpdateTime) >= UPDATE_INTERVAL) {
            _createHashPowerSnapshot();
            lastUpdateTime = block.timestamp;
        }
    }

    // ============ 内部函数 ============
    
    /**
     * @notice 创建算力快照
     * @dev 计算当前总算力并记录到历史数组
     */
    function _createHashPowerSnapshot() internal {
        // 计算总算力
        uint256 totalPower = _calculateTotalHashPower();
        
        // 创建快照
        HashPowerSnapshot memory snapshot = HashPowerSnapshot({
            timestamp: block.timestamp,
            totalHashPower: totalPower,
            totalStakedUsdt: totalStakedUsdt,
            totalMiners: totalActiveMiners,
            blockNumber: block.number
        });
        
        // 如果历史记录超过最大长度，删除最旧的记录
        if (hashPowerHistory.length >= MAX_HISTORY_LENGTH) {
            // 删除第一个元素（最旧的）
            for (uint256 i = 0; i < hashPowerHistory.length - 1; i++) {
                hashPowerHistory[i] = hashPowerHistory[i + 1];
            }
            hashPowerHistory.pop();
        }
        
        // 添加新快照
        hashPowerHistory.push(snapshot);
        
        emit HashPowerUpdated(
            hashPowerHistory.length - 1,
            snapshot.timestamp,
            snapshot.totalHashPower,
            snapshot.totalStakedUsdt,
            snapshot.totalMiners
        );
    }
    
    /**
     * @notice 计算全网总算力
     * @dev 遍历所有矿工计算总算力
     */
    function _calculateTotalHashPower() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < minerAddresses.length; i++) {
            address minerAddr = minerAddresses[i];
            if (minter[minerAddr].isStartMint) {
                total += getPower(minerAddr);
            }
        }
        return total;
    }
    
    /**
     * @notice 注册矿工地址（内部使用）
     */
    function _registerMiner(address minerAddr) internal {
        if (!isMinerRegistered[minerAddr]) {
            minerAddresses.push(minerAddr);
            isMinerRegistered[minerAddr] = true;
            totalActiveMiners++;
        }
    }

    // ============ 功能函数 ============
    
    /**
     * @notice 开始挖矿
     */
    function startMint() external OnlyEOA nonReentrant {
        address user = msg.sender;
        Minter storage _minter = minter[user];
        require(!_minter.isStartMint, "Mining started");
        
        _minter.startMintTime = block.timestamp;
        _minter.lastMintTime = block.timestamp;
        _minter.isStartMint = true;
        
        // 注册矿工
        _registerMiner(user);
        
        emit StartMint(
            user,
            true,
            _minter.startMintTime,
            _minter.lastMintTime
        );
    }

    /**
     * @notice 质押 USDT
     */
    function stakeUsdt(uint256 amount) external OnlyEOA nonReentrant {
        address from = msg.sender;
        require(
            minter[from].isStartMint && minter[from].startMintTime > 0,
            "Please start mining"
        );
        require(
            amount > 0 && amount % 100e6 == 0,
            "USDT must be an integer multiple of 100"
        );

        // 质押前如有奖励先领取奖励
        if (block.timestamp >= minter[from].lastMintTime + TIMEINTERVAL) {
            _withdrawRewards(from);
        }

        // 查询 USDT 授权
        (bool success, bytes memory data) = USDT.staticcall(
            abi.encodeWithSignature(
                "allowance(address,address)",
                from,
                address(this)
            )
        );
        require(success && data.length > 0, "Allowance failed");
        uint256 allowanceUsdt = abi.decode(data, (uint256));
        require(allowanceUsdt >= amount, "Insufficient authorization quantity");
        
        // 转入 USDT
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

        // 更新用户质押量和全网总质押量
        minter[from].totalUsdt += amount;
        totalStakedUsdt += amount;
        
        emit Staked(from, amount, minter[from].totalUsdt);
    }

    /**
     * @notice 获取用户算力
     */
    function getPower(address user) public view returns (uint256) {
        return BASICCOMPUTINGPOWER + (minter[user].totalUsdt / 100e6) * HASHRATE;
    }

    /**
     * @notice 查询可领取奖励
     */
    function pendingRewards(
        address user
    ) public view returns (uint256 reward, uint256 power) {
        Minter storage m = minter[user];
        if (!m.isStartMint || m.startMintTime == 0) {
            return (0, 0);
        }
        if (block.timestamp < m.lastMintTime + TIMEINTERVAL) {
            return (0, getPower(user));
        }
        uint256 passHours = (block.timestamp - m.lastMintTime) / 1 hours;
        power = getPower(user);
        reward = power * passHours;
    }

    /**
     * @notice 内部领取奖励函数
     */
    function _withdrawRewards(address user) internal {
        Minter storage m = minter[user];
        require(m.isStartMint && m.startMintTime > 0, "Mining not started");
        require(
            block.timestamp >= m.lastMintTime + TIMEINTERVAL,
            "Not time yet"
        );
        
        (uint256 reward, ) = pendingRewards(user);
        require(reward > 0, "No rewards");

        // 查询合约 GBC 余额
        (bool success3, bytes memory data3) = GBC.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        require(success3 && data3.length > 0, "Query quantity failed");
        uint256 gbcAmount = abi.decode(data3, (uint256));
        require(
            gbcAmount > 0 && gbcAmount >= reward,
            "Insufficient GBC in contract"
        );

        // 更新领奖时间
        m.lastMintTime =
            m.lastMintTime +
            ((block.timestamp - m.lastMintTime) / 1 hours) *
            1 hours;
            
        // 转账 GBC 奖励
        (bool success4, ) = GBC.call(
            abi.encodeWithSelector(0xa9059cbb, user, reward)
        );
        require(success4, "GBC transfer failed");
        
        emit WithdrawRewards(user, reward);
    }

    /**
     * @notice 领取奖励
     */
    function withdrawRewards() external OnlyEOA nonReentrant {
        address from = msg.sender;
        _withdrawRewards(from);
    }

    /**
     * @notice 赎回质押的 USDT
     */
    function withdrawStakeUsdt(uint256 amount) external OnlyEOA nonReentrant {
        address user = msg.sender;
        Minter storage m = minter[user];
        require(m.isStartMint && m.startMintTime > 0, "Mining not started");
        require(amount > 0 && amount <= m.totalUsdt, "Invalid amount");

        // 取回前先领取奖励
        if (block.timestamp >= m.lastMintTime + TIMEINTERVAL) {
            _withdrawRewards(user);
        }

        // 更新质押量
        m.totalUsdt -= amount;
        totalStakedUsdt -= amount;

        // 查询合约 USDT 余额
        (bool success1, bytes memory data1) = USDT.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        require(success1 && data1.length > 0, "Get balance failed");
        uint256 contractUsdt = abi.decode(data1, (uint256));
        require(contractUsdt >= amount, "Contract usdt not enough");

        // 转账 USDT
        (bool success2, bytes memory data2) = USDT.call(
            abi.encodeWithSelector(0xa9059cbb, user, amount)
        );
        require(
            success2 && (data2.length == 0 || abi.decode(data2, (bool))),
            "Transfer failed"
        );
        
        emit WithdrawStake(user, amount);
    }

    // ============ 查询函数 ============
    
    /**
     * @notice 获取算力历史记录数量
     */
    function getHashPowerHistoryLength() external view returns (uint256) {
        return hashPowerHistory.length;
    }
    
    /**
     * @notice 获取指定索引的算力快照
     */
    function getHashPowerSnapshot(uint256 index) 
        external 
        view 
        returns (
            uint256 timestamp,
            uint256 totalHashPower,
            uint256 _totalStakedUsdt,
            uint256 totalMiners,
            uint256 blockNumber
        ) 
    {
        require(index < hashPowerHistory.length, "Index out of bounds");
        HashPowerSnapshot memory snapshot = hashPowerHistory[index];
        return (
            snapshot.timestamp,
            snapshot.totalHashPower,
            snapshot.totalStakedUsdt,
            snapshot.totalMiners,
            snapshot.blockNumber
        );
    }
    
    /**
     * @notice 获取最新的算力快照
     */
    function getLatestHashPowerSnapshot() 
        external 
        view 
        returns (
            uint256 timestamp,
            uint256 totalHashPower,
            uint256 _totalStakedUsdt,
            uint256 totalMiners,
            uint256 blockNumber
        ) 
    {
        require(hashPowerHistory.length > 0, "No snapshots available");
        HashPowerSnapshot memory snapshot = hashPowerHistory[hashPowerHistory.length - 1];
        return (
            snapshot.timestamp,
            snapshot.totalHashPower,
            snapshot.totalStakedUsdt,
            snapshot.totalMiners,
            snapshot.blockNumber
        );
    }
    
    /**
     * @notice 获取最近 N 个小时的算力数据
     */
    function getRecentHashPowerSnapshots(uint256 count) 
        external 
        view 
        returns (HashPowerSnapshot[] memory) 
    {
        require(count > 0, "Count must be greater than 0");
        uint256 length = hashPowerHistory.length;
        uint256 returnCount = count > length ? length : count;
        
        HashPowerSnapshot[] memory snapshots = new HashPowerSnapshot[](returnCount);
        
        for (uint256 i = 0; i < returnCount; i++) {
            snapshots[i] = hashPowerHistory[length - returnCount + i];
        }
        
        return snapshots;
    }
    
    /**
     * @notice 获取当前全网总算力（实时计算）
     */
    function getCurrentTotalHashPower() external view returns (uint256) {
        return _calculateTotalHashPower();
    }
    
    /**
     * @notice 获取矿工总数
     */
    function getTotalMiners() external view returns (uint256) {
        return minerAddresses.length;
    }
    
    /**
     * @notice 获取活跃矿工数量
     */
    function getActiveMiners() external view returns (uint256) {
        return totalActiveMiners;
    }

    // ============ 管理员函数 ============
    
    /**
     * @notice 手动触发算力快照（仅管理员）
     */
    function manualUpdateHashPower() external onlyOwner {
        _createHashPowerSnapshot();
        lastUpdateTime = block.timestamp;
    }
    
    /**
     * @notice 转移合约所有权
     */
    function transferOwnership(address newOwner) public override onlyOwner {
        super.transferOwnership(newOwner);
    }
    
    /**
     * @notice 紧急提取代币（仅管理员）
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(amount != 0, "Amount is not 0");
        (bool success, ) = token.call(
            abi.encodeWithSelector(0xa9059cbb, owner(), amount)
        );
        require(success, "Transfer failed");
    }
}
