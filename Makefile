-include .env

.PHONY: all test clean deploy fund help install snapshot format anvil scopefile deploy-bridges

DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

all: remove install build

# Clean the repo
clean :; forge clean

# Remove modules
remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "modules"

install :; forge install cyfrin/foundry-devops --no-commit && forge install smartcontractkit/chainlink-brownie-contracts@0.8.0 --no-commit && forge install foundry-rs/forge-std --no-commit && forge install Uniswap/v4-periphery && forge install brevis-network/brevis-contracts --no-commit

# Update Dependencies
update:; forge update

build:; forge build

test :; forge test 

testLowVolatility :; forge test --mt testUniqHook1to1_LowVolatilityImpact_OnFeeAdjustment -vv

testLowVolatilityHighVolume :; forge test --mt testUniqHook1to1_LowVolatilityHighVolume_OnFeeAdjustment -vv

testHighVolatilityLowVolume :; forge test --mt testUniqHook1to1_HighVolatilityImpact_OnFeeAdjustment -vv

testHighVolume :; forge test --mt testUniqHook1to1_HighVolatilityHighVolume_OnFeeAdjustment -vv

testMidVolatility :; forge test --mt testUniqHook1to1_MidVolatilityImpact_OnFeeAdjustment -vv

snapshot :; forge snapshot

format :; forge fmt

anvil :; anvil -m 'test test test test test test test test test test test junk' --steps-tracing --block-time 1

slither :; slither . --config-file slither.config.json --checklist 

scope :; tree ./src/ | sed 's/└/#/g; s/──/--/g; s/├/#/g; s/│ /|/g; s/│/|/g'

scopefile :; @tree ./src/ | sed 's/└/#/g' | awk -F '── ' '!/\.sol$$/ { path[int((length($$0) - length($$2))/2)] = $$2; next } { p = "src"; for(i=2; i<=int((length($$0) - length($$2))/2); i++) if (path[i] != "") p = p "/" path[i]; print p "/" $$2; }' > scope.txt

aderyn :; aderyn . 

simulate :; npm run simulate 

getweth :; cast call TOKEN_BRIDGE_ADDRESS "getWeth()" --rpc-url ${SEPOLIA_RPC_URL} | cut -c 27- | xargs printf "0x%s\n" | cast --to-checksum-address 

deployRWA :; @forge script script/DeployUniqRWA.s.sol --sender 0x6fc5113b55771b884880785042e78521b8b719fa --account defaultKey --rpc-url ${SEPOLIA_RPC_URL} --etherscan-api-key ${ETHERSCAN_API_KEY} --verify --broadcast 

testMint :; @cast send 0x74D317D99411993C089C9b5a28aceee6Dd383a82 "sendMintRequest(uint256)" 0x54534c4100000000000000000000000000000000000000000000000000000000 100000000000000000000 --from 0x6fc5113b55771b884880785042e78521b8b719fa --rpc-url ${SEPOLIA_RPC_URL} --account defaultKey --gas-price 20000000000 --gas-limit 10000000

testMintCall :; cast call 0x5D2AAfB55Ef54Fdb674C56A12A57D5b5380f3d08 "sendMintRequest(bytes32,uint256)" 0x54534c4100000000000000000000000000000000000000000000000000000000 100000000000000000000 --from 0x6fc5113b55771b884880785042e78521b8b719fa --rpc-url ${SEPOLIA_RPC_URL} --account defaultKey  --gas-price 20000000000 --gas-limit 10000000

