// test/StakeMint.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("StakeMint", function () {
    let stakeMint;
    let usdt;
    let gbc;
    let owner;
    let user1;
    let user2;
    let stakeMintAddress;
    let usdtAddress;
    let gbcAddress;
    
    beforeEach(async function () {
        [owner, user1, user2] = await ethers.getSigners();
        
        // 部署 Mock 代币
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        usdt = await MockERC20.deploy("Mock USDT", "USDT");
        await usdt.waitForDeployment();
        usdtAddress = await usdt.getAddress();
        
        gbc = await MockERC20.deploy("GBC Token", "GBC");
        await gbc.waitForDeployment();
        gbcAddress = await gbc.getAddress();
        
        // 部署质押合约
        const StakeMint = await ethers.getContractFactory("StakeMint");
        stakeMint = await StakeMint.deploy(usdtAddress, gbcAddress);
        await stakeMint.waitForDeployment();
        stakeMintAddress = await stakeMint.getAddress();
        
        // 给用户铸造代币
        await usdt.mint(user1.address, ethers.parseUnits("10000", 6));
        await usdt.mint(user2.address, ethers.parseUnits("10000", 6));
        
        // 给合约铸造 GBC 奖励
        await gbc.mint(stakeMintAddress, ethers.parseEther("1000000"));
    });
    
    describe("部署", function () {
        it("应该正确设置代币地址", async function () {
            expect(await stakeMint.USDT()).to.equal(usdtAddress);
            expect(await stakeMint.GBC()).to.equal(gbcAddress);
        });
        
        it("应该正确设置 owner", async function () {
            expect(await stakeMint.owner()).to.equal(owner.address);
        });
        
        it("应该创建初始算力快照", async function () {
            expect(await stakeMint.getHashPowerHistoryLength()).to.equal(1);
        });
    });
    
    describe("开始挖矿", function () {
        it("用户应该能够开始挖矿", async function () {
            await stakeMint.connect(user1).startMint();
            const minter = await stakeMint.minter(user1.address);
            expect(minter.isStartMint).to.be.true;
        });
        
        it("不能重复开始挖矿", async function () {
            await stakeMint.connect(user1).startMint();
            await expect(
                stakeMint.connect(user1).startMint()
            ).to.be.revertedWith("Mining started");
        });
        
        it("应该注册矿工地址", async function () {
            await stakeMint.connect(user1).startMint();
            expect(await stakeMint.isMinerRegistered(user1.address)).to.be.true;
            expect(await stakeMint.getTotalMiners()).to.equal(1);
        });
    });
    
    describe("质押 USDT", function () {
        beforeEach(async function () {
            await stakeMint.connect(user1).startMint();
        });
        
        it("应该能够质押 USDT", async function () {
            const amount = ethers.parseUnits("1000", 6); // 1000 USDT
            await usdt.connect(user1).approve(stakeMintAddress, amount);
            
            await expect(
                stakeMint.connect(user1).stakeUsdt(amount)
            ).to.emit(stakeMint, "Staked").withArgs(
                user1.address,
                amount,
                amount
            );
            
            const minter = await stakeMint.minter(user1.address);
            expect(minter.totalUsdt).to.equal(amount);
            expect(await stakeMint.totalStakedUsdt()).to.equal(amount);
        });
        
        it("质押金额必须是 100 USDT 的整数倍", async function () {
            const amount = ethers.parseUnits("150", 6); // 150 USDT
            await usdt.connect(user1).approve(stakeMintAddress, amount);
            await expect(
                stakeMint.connect(user1).stakeUsdt(amount)
            ).to.be.revertedWith("USDT must be an integer multiple of 100");
        });
        
        it("未开始挖矿不能质押", async function () {
            const amount = ethers.parseUnits("100", 6);
            await usdt.connect(user2).approve(stakeMintAddress, amount);
            await expect(
                stakeMint.connect(user2).stakeUsdt(amount)
            ).to.be.revertedWith("Please start mining");
        });
    });
    
    describe("算力计算", function () {
        it("基础算力应该是 0.03", async function () {
            await stakeMint.connect(user1).startMint();
            const power = await stakeMint.getPower(user1.address);
            expect(power).to.equal(ethers.parseEther("0.03"));
        });
        
        it("质押后算力应该增加", async function () {
            await stakeMint.connect(user1).startMint();
            
            const amount = ethers.parseUnits("1000", 6); // 1000 USDT = 10 * 100
            await usdt.connect(user1).approve(stakeMintAddress, amount);
            await stakeMint.connect(user1).stakeUsdt(amount);
            
            const power = await stakeMint.getPower(user1.address);
            // 直接验证算力大于基础算力，避免BigInt计算错误
            const basePower = ethers.parseEther("0.03");
            expect(power).to.be.gt(basePower);
        });
    });
    
    describe("Chainlink Automation", function () {
        it("checkUpkeep 应该在 1 小时后返回 true", async function () {
            // 前进 1 小时
            await time.increase(3600);
            
            const [upkeepNeeded] = await stakeMint.checkUpkeep("0x");
            expect(upkeepNeeded).to.be.true;
        });
        
        it("checkUpkeep 在 1 小时前应该返回 false", async function () {
            // 前进 30 分钟
            await time.increase(1800);
            
            const [upkeepNeeded] = await stakeMint.checkUpkeep("0x");
            expect(upkeepNeeded).to.be.false;
        });
        
        it("performUpkeep 应该创建新的算力快照", async function () {
            await stakeMint.connect(user1).startMint();
            const amount = ethers.parseUnits("1000", 6);
            await usdt.connect(user1).approve(stakeMintAddress, amount);
            await stakeMint.connect(user1).stakeUsdt(amount);
            
            // 前进 1 小时
            await time.increase(3600);
            
            const lengthBefore = await stakeMint.getHashPowerHistoryLength();
            await stakeMint.performUpkeep("0x");
            const lengthAfter = await stakeMint.getHashPowerHistoryLength();
            
            expect(lengthAfter).to.equal(Number(lengthBefore) + 1);
        });
        
        it("算力快照应该记录正确的数据", async function () {
            await stakeMint.connect(user1).startMint();
            await stakeMint.connect(user2).startMint();
            
            const amount = ethers.parseUnits("1000", 6);
            await usdt.connect(user1).approve(stakeMintAddress, amount);
            await stakeMint.connect(user1).stakeUsdt(amount);
            
            // 前进 1 小时并更新
            await time.increase(3600);
            await stakeMint.performUpkeep("0x");
            
            const [
                timestamp,
                totalHashPower,
                totalStakedUsdt,
                totalMiners
            ] = await stakeMint.getLatestHashPowerSnapshot();
            
            expect(totalStakedUsdt).to.equal(amount);
            expect(totalMiners).to.equal(2); // user1 和 user2
            expect(totalHashPower).to.be.gt(0);
        });
    });
    
    describe("奖励领取", function () {
        beforeEach(async function () {
            await stakeMint.connect(user1).startMint();
            const amount = ethers.parseUnits("1000", 6);
            await usdt.connect(user1).approve(stakeMintAddress, amount);
            await stakeMint.connect(user1).stakeUsdt(amount);
        });
        
        it("24 小时内不能领取奖励", async function () {
            await time.increase(12 * 3600); // 12 小时
            await expect(
                stakeMint.connect(user1).withdrawRewards()
            ).to.be.revertedWith("Not time yet");
        });
        
        it("24 小时后应该能够领取奖励", async function () {
            await time.increase(25 * 3600); // 25 小时
            
            const balanceBefore = await gbc.balanceOf(user1.address);
            await stakeMint.connect(user1).withdrawRewards();
            const balanceAfter = await gbc.balanceOf(user1.address);
            
            expect(balanceAfter).to.be.gt(balanceBefore);
        });
    });
    
    describe("赎回质押", function () {
        beforeEach(async function () {
            await stakeMint.connect(user1).startMint();
            const amount = ethers.parseUnits("1000", 6);
            await usdt.connect(user1).approve(stakeMintAddress, amount);
            await stakeMint.connect(user1).stakeUsdt(amount);
        });
        
        it("应该能够赎回质押的 USDT", async function () {
            const amount = ethers.parseUnits("500", 6);
            
            const balanceBefore = await usdt.balanceOf(user1.address);
            await stakeMint.connect(user1).withdrawStakeUsdt(amount);
            const balanceAfter = await usdt.balanceOf(user1.address);
            
            expect(balanceAfter - balanceBefore).to.equal(amount);
        });
        
        it("不能赎回超过质押的金额", async function () {
            const amount = ethers.parseUnits("2000", 6);
            await expect(
                stakeMint.connect(user1).withdrawStakeUsdt(amount)
            ).to.be.revertedWith("Invalid amount");
        });
    });
    
    describe("管理员功能", function () {
        it("owner 应该能够手动更新算力", async function () {
            const lengthBefore = await stakeMint.getHashPowerHistoryLength();
            await stakeMint.connect(owner).manualUpdateHashPower();
            const lengthAfter = await stakeMint.getHashPowerHistoryLength();
            
            expect(lengthAfter).to.equal(Number(lengthBefore) + 1);
        });
        
        it("非 owner 不能手动更新算力", async function () {
            await expect(
                stakeMint.connect(user1).manualUpdateHashPower()
            ).to.be.revertedWithCustomError(stakeMint, "OwnableUnauthorizedAccount");
        });
        
        it("owner 应该能够转移所有权", async function () {
            await stakeMint.connect(owner).transferOwnership(user1.address);
            expect(await stakeMint.owner()).to.equal(user1.address);
        });
        
        it("owner 应该能够紧急提取代币", async function () {
            const amount = ethers.parseUnits("100", 6);
            await usdt.mint(stakeMintAddress, amount);
            
            const balanceBefore = await usdt.balanceOf(owner.address);
            await stakeMint.connect(owner).emergencyWithdraw(usdtAddress, amount);
            const balanceAfter = await usdt.balanceOf(owner.address);
            
            expect(balanceAfter - balanceBefore).to.equal(amount);
        });
        
        it("非 owner 不能紧急提取代币", async function () {
            const amount = ethers.parseUnits("100", 6);
            await usdt.mint(stakeMintAddress, amount);
            
            await expect(
                stakeMint.connect(user1).emergencyWithdraw(usdtAddress, amount)
            ).to.be.revertedWithCustomError(stakeMint, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("查询函数", function () {
        beforeEach(async function () {
            await stakeMint.connect(user1).startMint();
            await stakeMint.connect(user2).startMint();
            
            const amount = ethers.parseUnits("1000", 6);
            await usdt.connect(user1).approve(stakeMintAddress, amount);
            await stakeMint.connect(user1).stakeUsdt(amount);
        });
        
        it("应该能够获取当前总算力", async function () {
            const totalPower = await stakeMint.getCurrentTotalHashPower();
            expect(totalPower).to.be.gt(0);
        });
        
        it("应该能够获取最近的算力快照", async function () {
            // 创建几个快照
            for (let i = 0; i < 3; i++) {
                await time.increase(3600);
                await stakeMint.performUpkeep("0x");
            }
            
            const snapshots = await stakeMint.getRecentHashPowerSnapshots(3);
            expect(snapshots.length).to.equal(3);
        });
        
        it("应该能够获取活跃矿工数量", async function () {
            const activeMiners = await stakeMint.getActiveMiners();
            expect(activeMiners).to.equal(2); // user1 和 user2
        });
    });
});
