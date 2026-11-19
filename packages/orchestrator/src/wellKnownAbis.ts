/**
 * Function signatures of contracts crews commonly pay into (PRD F2.6).
 *
 * Decoded by selector, so a match names the function the calldata calls, not
 * the contract at the target: the approver view reports these as
 * `matchedBy: "selector"`, and an operator who wants a stronger statement
 * registers the target's own ABI (`targetAbis.ts`).
 */

import { parseAbi, type Abi } from "viem";

export const WELL_KNOWN_ABIS: Array<{ name: string; abi: Abi }> = [
  {
    name: "uniswapV2Router",
    abi: parseAbi([
      "function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)",
      "function swapTokensForExactTokens(uint256 amountOut, uint256 amountInMax, address[] path, address to, uint256 deadline)",
      "function swapExactETHForTokens(uint256 amountOutMin, address[] path, address to, uint256 deadline)",
      "function swapTokensForExactETH(uint256 amountOut, uint256 amountInMax, address[] path, address to, uint256 deadline)",
      "function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)",
      "function swapETHForExactTokens(uint256 amountOut, address[] path, address to, uint256 deadline)",
      "function addLiquidity(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline)",
      "function removeLiquidity(address tokenA, address tokenB, uint256 liquidity, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline)",
    ]),
  },
  {
    name: "uniswapV3SwapRouter",
    abi: parseAbi([
      "struct ExactInputSingleParams { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }",
      "struct ExactInputParams { bytes path; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; }",
      "struct ExactOutputSingleParams { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 deadline; uint256 amountOut; uint256 amountInMaximum; uint160 sqrtPriceLimitX96; }",
      "struct ExactOutputParams { bytes path; address recipient; uint256 deadline; uint256 amountOut; uint256 amountInMaximum; }",
      "function exactInputSingle(ExactInputSingleParams params)",
      "function exactInput(ExactInputParams params)",
      "function exactOutputSingle(ExactOutputSingleParams params)",
      "function exactOutput(ExactOutputParams params)",
      "function multicall(bytes[] data)",
      "function multicall(uint256 deadline, bytes[] data)",
    ]),
  },
  {
    // SwapRouter02 dropped `deadline` from the params, which changes every selector.
    name: "uniswapSwapRouter02",
    abi: parseAbi([
      "struct ExactInputSingleParams { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }",
      "struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }",
      "function exactInputSingle(ExactInputSingleParams params)",
      "function exactInput(ExactInputParams params)",
    ]),
  },
  {
    name: "uniswapUniversalRouter",
    abi: parseAbi([
      "function execute(bytes commands, bytes[] inputs, uint256 deadline)",
      "function execute(bytes commands, bytes[] inputs)",
    ]),
  },
  {
    name: "permit2",
    abi: parseAbi([
      "function approve(address token, address spender, uint160 amount, uint48 expiration)",
    ]),
  },
  {
    name: "weth",
    abi: parseAbi(["function deposit()", "function withdraw(uint256 wad)"]),
  },
  {
    name: "erc4626",
    abi: parseAbi([
      "function deposit(uint256 assets, address receiver)",
      "function mint(uint256 shares, address receiver)",
      "function withdraw(uint256 assets, address receiver, address owner)",
      "function redeem(uint256 shares, address receiver, address owner)",
    ]),
  },
  {
    name: "nft",
    abi: parseAbi([
      "function setApprovalForAll(address operator, bool approved)",
      "function safeTransferFrom(address from, address to, uint256 tokenId)",
      "function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes data)",
    ]),
  },
];

/**
 * Functions whose effect outlives the call: they hand someone else the right
 * to move funds later. An approver should read these differently from a
 * payment, whatever amount the intent carries.
 */
export const ALLOWANCE_GRANTING = new Set([
  "approve",
  "increaseAllowance",
  "setApprovalForAll",
  "permit",
]);
