/**
 * The hook's event signatures, for decoding real receipts.
 *
 * Copied from `src/interfaces/IAssayEvents.sol` and verified against the chain: the topic0
 * hashes of the two events this pool has actually emitted match
 * `keccak256("PoolRegistered(bytes32,uint24)")` and
 * `keccak256("SwapAssayed(bytes32,address,uint24)")` exactly.
 */
export const ASSAY_EVENT_ABI = [
  {
    type: "event",
    name: "PoolRegistered",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "baseFeePips", type: "uint24", indexed: false },
    ],
  },
  {
    type: "event",
    name: "SwapAssayed",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "sender", type: "address", indexed: true },
      { name: "feePips", type: "uint24", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ReferenceFreshnessChanged",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "fresh", type: "bool", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ToxicitySurchargeDonated",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "inCurrency0", type: "bool", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ChainHaltDetected",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "secondsElapsed", type: "uint256", indexed: false },
      { name: "blocksElapsed", type: "uint256", indexed: false },
      { name: "distrustedUntil", type: "uint32", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ReferenceDeviationCapTripped",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "referenceTick", type: "int24", indexed: false },
      { name: "twapTick", type: "int24", indexed: false },
      { name: "maxDeviationTicks", type: "uint24", indexed: false },
    ],
  },
] as const;
