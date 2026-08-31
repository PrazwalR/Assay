/**
 * Minimal ABIs — only the functions this app actually calls.
 *
 * Deliberately not the full generated artifacts. A frontend that ships an ABI for functions it
 * never calls invites someone to call them, and these two reads are the entire live surface.
 */

export const HOOK_ABI = [
  {
    type: "function",
    name: "poolState",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "lastTick", type: "int24" },
          { name: "referenceTick", type: "int24" },
          { name: "lastBlock", type: "uint32" },
          { name: "referenceFresh", type: "bool" },
          { name: "twapTickX32", type: "int64" },
          { name: "lastRefreshAt", type: "uint32" },
          { name: "referenceDistrustedUntil", type: "uint32" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "signedMispricing",
    stateMutability: "view",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "zeroForOne", type: "bool" },
    ],
    outputs: [
      { name: "capturedTicks", type: "int256" },
      { name: "fresh", type: "bool" },
    ],
  },
  {
    type: "function",
    name: "surchargeBounds",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "maxSurchargePips", type: "uint24" },
      { name: "maxTotalPips", type: "uint24" },
    ],
  },
  {
    type: "function",
    name: "feeBounds",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "baseFeePips", type: "uint24" },
      { name: "minFeePips", type: "uint24" },
      { name: "maxFeePips", type: "uint24" },
    ],
  },
] as const;

export const ORACLE_ADAPTER_ABI = [
  {
    type: "function",
    name: "PRICE_NUMERATOR",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "referenceSqrtPriceX96",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "fresh", type: "bool" },
    ],
  },
] as const;

/** The ERC-20 surface this app touches: read a balance, read and grant an allowance. */
export const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

/**
 * The deployed `PoolSwapTest` router.
 *
 * v4 routes every pool operation through `PoolManager.unlock` and a callback, which a browser
 * cannot perform directly — the caller must be a contract. This router is that contract: it
 * takes the swap, runs the unlock/settle dance, and pulls the input from `msg.sender`, which is
 * why a swap needs an ERC-20 allowance granted to the router rather than to the PoolManager.
 */
export const SWAP_ROUTER_ABI = [
  {
    type: "function",
    name: "swap",
    stateMutability: "payable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "zeroForOne", type: "bool" },
          { name: "amountSpecified", type: "int256" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
      {
        name: "testSettings",
        type: "tuple",
        components: [
          { name: "takeClaims", type: "bool" },
          { name: "settleUsingBurn", type: "bool" },
        ],
      },
      { name: "hookData", type: "bytes" },
    ],
    outputs: [{ name: "delta", type: "int256" }],
  },
] as const;

/**
 * v4 keeps all pool state in the PoolManager singleton and exposes it only through raw storage
 * reads — there are no per-pool getters. `StateLibrary` computes the slots; this is the one
 * function needed to read them.
 */
export const POOL_MANAGER_ABI = [
  {
    type: "function",
    name: "extsload",
    stateMutability: "view",
    inputs: [{ name: "slot", type: "bytes32" }],
    outputs: [{ name: "", type: "bytes32" }],
  },
] as const;
