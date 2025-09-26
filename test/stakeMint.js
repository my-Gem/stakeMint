const { expect } = require("chai");
const { ethers } = require("hardhat");


describe("stakeMint", function () {
    let stakeMint, usdt, gbc, owner, user1, user2;

    beforeEach(async function () {
        try {
            [owner, user1, user2] = await ethers.getSigners();
            console.log("signers ok");

            // 部署 TetherToken 作为 USDT
            const TetherToken = await ethers.getContractFactory("TetherToken");
            // 例如：1000000 USDT, 名称, 符号, 6位小数
            console.log("Deploy params:", ethers.parseUnits("1000000", 6), "Tether USD", "USDT", 6);
            usdt = await TetherToken.deploy(
                ethers.parseUnits("1000000", 6),
                "Tether USD",
                "USDT",
                6
            );
            await usdt.waitForDeployment();
            console.log("usdt address:", usdt.target);

            // 部署 mock GBC
            const GBC = await ethers.getContractFactory("MockERC20");
            console.log("Deploy params:", "GBC Token", "GBC", 18);
            gbc = await GBC.deploy("GBC Token", "GBC", 18);
            await gbc.waitForDeployment();
            console.log("gbc address:", gbc.target);

            // 部署 stakeMint 合约
            const StakeMint = await ethers.getContractFactory("stakeMint");
            console.log("Deploy params:", usdt.target, gbc.target);
            stakeMint = await StakeMint.deploy(usdt.target, gbc.target);
            await stakeMint.waitForDeployment();
            console.log("stakeMint ok");

            // 给 user1 一些 USDT
            await usdt.transfer(user1.address, ethers.parseUnits("1000", 6));
            // user1 授权 stakeMint 合约
            await usdt.connect(user1).approve(stakeMint.target, ethers.parseUnits("1000", 6));

            // 给合约充足的 GBC
            await gbc.mint(stakeMint.target, ethers.parseUnits("10000", 18));
            console.log("mint ok");
        } catch (e) {
            console.error("beforeEach error:", e);
            throw e;
        }
    });

    it("should start mining", async function () {
        await expect(stakeMint.connect(user1).startMint())
            .to.emit(stakeMint, "StartMint");

        const minter = await stakeMint.minter(user1.address);
        expect(minter.isStartMint).to.equal(true);
    });

    it("should stake USDT", async function () {
        await stakeMint.connect(user1).startMint();
        await expect(stakeMint.connect(user1).stakeUsdt(ethers.parseUnits("100", 6)))
            .to.emit(stakeMint, "StakeMint");
        const minter = await stakeMint.minter(user1.address);
        expect(minter.totalUsdt).to.equal(ethers.parseUnits("100", 6));
    });

    it("should get power", async function () {
        await stakeMint.connect(user1).startMint();
        await stakeMint.connect(user1).stakeUsdt(ethers.parseUnits("200", 6));
        const power = await stakeMint.getPower(user1.address);
        expect(power).to.be.gt(0);
    });

    it("should calculate pending rewards", async function () {
        await stakeMint.connect(user1).startMint();
        await stakeMint.connect(user1).stakeUsdt(ethers.parseUnits("100", 6));
        // 模拟时间前进 1 天
        await ethers.provider.send("evm_increaseTime", [24 * 3600]);
        await ethers.provider.send("evm_mine");
        const [reward, power] = await stakeMint.pendingRewards(user1.address);
        expect(reward).to.be.gt(0);
        expect(power).to.be.gt(0);
    });

    it("should withdraw rewards", async function () {
        await stakeMint.connect(user1).startMint();
        await stakeMint.connect(user1).stakeUsdt(ethers.parseUnits("100", 6));
        await ethers.provider.send("evm_increaseTime", [24 * 3600]);
        await ethers.provider.send("evm_mine");
        await expect(stakeMint.connect(user1).withdrawRewards())
            .to.emit(stakeMint, "WithdrawRewards");
    });

    it("should withdraw staked USDT", async function () {
        await stakeMint.connect(user1).startMint();
        await stakeMint.connect(user1).stakeUsdt(ethers.parseUnits("100", 6));
        await ethers.provider.send("evm_increaseTime", [24 * 3600]);
        await ethers.provider.send("evm_mine");
        await expect(stakeMint.connect(user1).withdrawStakeUsdt(ethers.parseUnits("100", 6)))
            .to.emit(stakeMint, "WithdrawStake");
    });
});
