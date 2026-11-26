# Deploy runbook: contracts to a public testnet from GitHub

Click-paths for running the release procedure of [deployment-plan.md](./deployment-plan.md) §5
(build, dry run, broadcast, verify on the explorer, write the addresses file, open a PR) from the
**Deploy contracts** workflow (`.github/workflows/deploy-contracts.yml`). Testnets only: Ethereum
Sepolia and Base Sepolia. Mainnet keeps a hardware-wallet signer and is not run from here.

Nothing here needs a terminal. The deployer key and RPC URLs live only in GitHub Actions secrets:
the workflow never prints them, and they are never committed.

## 1. One-time setup

### 1.1 Create a deployer key

The deployer must be a **fresh, testnet-only key**. The workflow refuses the public Anvil key.

1. Create a new account in a wallet you trust (MetaMask: account menu → **Add account or hardware
   wallet** → **Add a new account**), used for nothing else.
2. In that wallet: ⋮ next to the account → **Account details** → **Show private key** → copy it
   (it starts with `0x`; if yours has no prefix, add `0x`).
3. Copy the account's public address too. You need it to fund the account.

### 1.2 Fund it from a faucet

The deployer pays gas for roughly 30 transactions per network.

- Ethereum Sepolia: any Sepolia faucet (for example <https://cloud.google.com/application/web3/faucet/ethereum/sepolia>).
- Base Sepolia: <https://www.alchemy.com/faucets/base-sepolia> or the Coinbase developer faucet.

Paste the public address, request ETH, wait for it to land. About **0.1 ETH** per network is plenty.

### 1.3 Get an RPC URL per network and an explorer key

- RPC: sign up at an RPC provider (Alchemy, Infura, QuickNode), **Create app / endpoint** for
  _Ethereum Sepolia_ and for _Base Sepolia_, and copy each HTTPS URL. The URL itself carries the
  provider key, so treat it as a secret.
- Explorer: <https://etherscan.io/myapikey> → sign in → **Add** → copy the key. One Etherscan v2
  key verifies on both Sepolia and Base Sepolia.

### 1.4 Add the secrets in GitHub

Repository **lacrew/lacrew** → **Settings** → **Secrets and variables** → **Actions** →
**Secrets** tab → **New repository secret**. Add one secret per row:

| Name                   | Value                           | Needed for               |
| ---------------------- | ------------------------------- | ------------------------ |
| `DEPLOYER_PRIVATE_KEY` | the `0x…` key from step 1.1     | both networks            |
| `SEPOLIA_RPC_URL`      | Ethereum Sepolia HTTPS URL      | `network = sepolia`      |
| `BASE_SEPOLIA_RPC_URL` | Base Sepolia HTTPS URL          | `network = base-sepolia` |
| `ETHERSCAN_API_KEY`    | the Etherscan key from step 1.3 | verification on both     |

Only add the RPC secret for the network you deploy to; the run stops with a message naming any
secret that is missing.

### 1.5 Let Actions open the PR

**Settings** → **Actions** → **General** → scroll to **Workflow permissions** → tick **Allow
GitHub Actions to create and approve pull requests** → **Save**.

### 1.6 Optional: other role addresses

By default the testnet deployer is also the `MarketplacePayments` governor and fee recipient. To
use a testnet Safe or another address instead: **Settings** → **Secrets and variables** →
**Actions** → **Variables** tab → **New repository variable**, named `MARKETPLACE_GOVERNOR` and/or
`PLATFORM_FEE_RECIPIENT`. These are public addresses, so variables, not secrets.

## 2. Trigger a deploy

1. Repository → **Actions** tab → **Deploy contracts** in the left list.
2. **Run workflow** (top right of the run list).
3. Pick **network**: `sepolia` or `base-sepolia`.
4. Leave **ref** as `main`, or enter a release tag such as `contracts-v0.1.0` (plan §5 step 1:
   tag the commit first, with CI green).
5. Click the green **Run workflow** button.

Deploy one network at a time. A second run for the same network waits for the first.

## 3. Check the run

Open the run (Actions → **Deploy contracts** → the newest row). Each step should be green:

| Step                                         | What it proves                                                                                |
| -------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Select network / Check secrets               | every secret it needs is set                                                                  |
| Resolve the deployer…                        | the key is not the Anvil key; prints the deployer **address** only                            |
| Check the deployer balance                   | the RPC is the right chain and the deployer has ETH                                           |
| Dry run                                      | the script's guards pass (no mock outside the mock allowlist), nothing is sent                |
| Deploy the org stack                         | every contract is created and the script's post-conditions pass (a half-wired deploy reverts) |
| Deploy MarketplacePayments                   | the protocol contract is created and its governor, fee recipient and token read back          |
| Check sources on the explorer                | the explorer shows source for **every** created address; lists each one                       |
| Write the addresses file / Sync @lacrew/core | `contracts/deployments/<chainId>.json` and `@lacrew/core` carry the new addresses             |
| Open the PR                                  | a branch `deploy/<network>-<run id>` and a PR exist                                           |

The run summary page also holds the artifact **broadcast-&lt;network&gt;-&lt;run id&gt;**: the forge
receipts (the plan's deployment receipt). Download it from **Artifacts** at the bottom of the run.

To double-check by hand: open the PR → **Files changed** → copy any address into
<https://sepolia.etherscan.io> (or <https://sepolia.basescan.org>) → **Contract** tab shows a green
check and the source.

## 4. Merge the PR

The PR holds addresses only. Review that `contracts/deployments/<chainId>.json` has `humanRoot`
equal to your deployer address, then merge. A PR opened by Actions does not start CI on its own;
if you want the checks, close it and reopen it once.

Not covered by this workflow, still open in plan §5: the smoke test of the full flow (step 7) and
the `lacrew.xyz/protocol` page.

## 5. If a run fails

- **Secret not set**: the error names it. Add it (step 1.4) and re-run.
- **Deployer has no ETH**: fund it (step 1.2) and re-run.
- **Source not verified**: the contracts exist but the explorer lacked source. Re-run the failed
  job once (**Re-run failed jobs**); if a deploy already happened, do not run a fresh one, since
  a re-run deploys a new stack. Verify the existing addresses from the artifact instead.
- **Failure after "Deploy the org stack"**: a stack exists on chain but no PR. Download the
  broadcast artifact for the addresses and ask for the record to be written from it.

## 6. After a deploy: retire the key

Testnet keys are cheap but still keys. When you are done with a release, delete
`DEPLOYER_PRIVATE_KEY` (**Settings** → **Secrets and variables** → **Actions** → trash icon) and
create a fresh one for the next. The deployer is the human root of the reference org it deployed,
so rotate the root to a Safe with the High-tier `rotateRoot` proposal if the org is to outlive the key.
