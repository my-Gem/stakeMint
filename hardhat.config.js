require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

// 配置hardhat accounts参数
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  // 指定solidity编译版本(可指定多版本)
  solidity: {
    compilers: [
      {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
          viaIR: true
        }
      },
      {
        version: "0.4.18"
      },

    ]
  },
  // 设置部署的网络
  networks: {
    bscTestnet: {
      url: process.env.BSCTEST_URL,
      chainId: 97,
      accounts: [process.env.PRIVATE_KEY]
    },
    bsc: {
      url: process.env.BSCMAIN_URL,
      chainId: 56,
      accounts: [process.env.PRIVATE_KEY]
    },
    hardhat: {
      chainId: 31337
    }
  },
  // gas fee预测
  gasReporter: {
    enabled: true,
    currency: "USD",
    token: "ETH",
    noColors: true
  },
  // 验证合约并开开源
  etherscan: {
    apiKey: {
      bscTestnet: process.env.BSCSCAN_API_KEY,
      bsc: process.env.BSCSCAN_API_KEY
    }
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  }
};
