"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { WagmiProvider } from "wagmi";

import { wagmiConfig } from "@/lib/wagmi";
import { DEPLOYED } from "@/lib/protocol/config";
import type { DataMode } from "@/lib/protocol/fixtures";
import { CURRENCY0, CURRENCY1 } from "@/lib/protocol/tokens";
import { quote, ceilingOverflowPips } from "@/lib/protocol/feeBlend";
import { toneFor, toneLabel, type Tone } from "@/lib/protocol/tone";
import { useReducedMotion } from "@/hooks/useReducedMotion";

export type ModalKind =
  | "tokenIn"
  | "tokenOut"
  | "wallet"
  | "network"
  | "settings"
  | "search"
  | null;

interface AssayState {
  /** Signed drift in ticks. Positive means this swap captures drift from liquidity. */
  drift: number;
  setDrift: (drift: number) => void;
  /** Whether the demonstration walks drift on its own. Pauses on any manual interaction. */
  live: boolean;
  toggleLive: () => void;
  /** Simulates the reference going stale, so the degraded path is inspectable. */
  referenceFresh: boolean;
  toggleReferenceFresh: () => void;

  dataMode: DataMode;
  toggleDataMode: () => void;
  tokenIn: string;
  tokenOut: string;
  setTokenIn: (key: string) => void;
  setTokenOut: (key: string) => void;
  /** Pass the current output amount so it becomes the new input; omit to leave the field as is. */
  flipDirection: (nextAmountIn?: string) => void;

  amountIn: string;
  setAmountIn: (value: string) => void;
  slippageIndex: number;
  setSlippageIndex: (index: number) => void;

  modal: ModalKind;
  openModal: (modal: ModalKind) => void;
  closeModal: () => void;

  /** Derived, so no component recomputes the mechanism. */
  feePips: number;
  twinFeePips: number;
  overflowPips: number;
  tone: Tone;
  toneText: string;

  reducedMotion: boolean;
}

const AssayContext = createContext<AssayState | null>(null);

export function useAssay(): AssayState {
  const value = useContext(AssayContext);
  if (!value) throw new Error("useAssay must be used inside <Providers>");
  return value;
}

const queryClient = new QueryClient();

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <AssayProvider>{children}</AssayProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}

function AssayProvider({ children }: { children: React.ReactNode }) {
  const reducedMotion = useReducedMotion();

  const [drift, setDriftRaw] = useState(24);
  const [walkRequested, setWalkRequested] = useState(true);
  // Derived, not synced. An effect that pushed `false` into state on reduced-motion would be a
  // cascading render, and would also make "paused" indistinguishable from "not allowed".
  const live = walkRequested && !reducedMotion;
  const [referenceFresh, setReferenceFresh] = useState(true);
  const [dataMode, setDataMode] = useState<DataMode>("testnet");
  // The real pool pair. Both directions are tradeable, so which is "in" is just a default.
  const [tokenIn, setTokenIn] = useState(CURRENCY0.symbol);
  const [tokenOut, setTokenOut] = useState(CURRENCY1.symbol);
  const [amountIn, setAmountIn] = useState("1.5");
  const [slippageIndex, setSlippageIndex] = useState(1);
  const [modal, setModal] = useState<ModalKind>(null);

  // Dragging the curve or the meter is a deliberate act of inspection; the walk stops so the
  // value the user chose stays put.
  const setDrift = useCallback((next: number) => {
    setDriftRaw(next);
    setWalkRequested(false);
  }, []);

  // Spec §5: the walk does not start at all under prefers-reduced-motion. Pausing a CSS
  // animation would not help — the number itself is what moves.
  useEffect(() => {
    if (!live) return;
    const id = setInterval(() => {
      setDriftRaw((current) => {
        let next = current + Math.round((Math.random() - 0.45) * 26);
        if (next > 320) next = 320 - Math.random() * 40;
        if (next < -140) next = -140 + Math.random() * 40;
        return Math.round(next);
      });
    }, 2200);
    return () => clearInterval(id);
  }, [live]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setModal("search");
      } else if (event.key === "Escape") {
        setModal(null);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // The toggle now only scales the Markets fixtures. It no longer swaps the token set: there is
  // one real pool, and offering a second pair would imply a market that does not exist.
  const toggleDataMode = useCallback(() => {
    setDataMode((current) => (current === "testnet" ? "mainnet-mock" : "testnet"));
  }, []);

  /**
   * Reverse the pair, carrying the quote across.
   *
   * `nextAmountIn` is the amount currently being quoted *out*, which becomes the amount going
   * *in* after the flip -- the same thing every DEX does, and the only behaviour that leaves a
   * sane quote on screen. Leaving the field alone reinterprets the number as the other token:
   * "21" meaning 21 USDC becomes 21 WETH, which is four orders of magnitude past both the
   * wallet's balance and the pool's depth, so the panel fills with insufficient-balance and
   * exceeds-liquidity states on what is otherwise a one-click demonstration.
   */
  const flipDirection = useCallback(
    (nextAmountIn?: string) => {
      setTokenIn((currentIn) => {
        setTokenOut(currentIn);
        return tokenOut;
      });
      if (nextAmountIn !== undefined) setAmountIn(nextAmountIn);
    },
    [tokenOut],
  );

  const value = useMemo<AssayState>(() => {
    const feePips = quote(drift, referenceFresh, DEPLOYED);
    // The opposite direction against the same drift — the entire per-swap thesis in one number.
    const twinFeePips = quote(-Math.abs(drift), referenceFresh, DEPLOYED);
    const overflowPips = ceilingOverflowPips(drift, referenceFresh, DEPLOYED);

    return {
      drift,
      setDrift,
      live,
      toggleLive: () => setWalkRequested((current) => !current),
      referenceFresh,
      toggleReferenceFresh: () => setReferenceFresh((current) => !current),
      dataMode,
      toggleDataMode,
      tokenIn,
      tokenOut,
      setTokenIn,
      setTokenOut,
      flipDirection,
      amountIn,
      setAmountIn,
      slippageIndex,
      setSlippageIndex,
      modal,
      openModal: setModal,
      closeModal: () => setModal(null),
      feePips,
      twinFeePips,
      overflowPips,
      tone: toneFor(drift, referenceFresh),
      toneText: toneLabel(drift, referenceFresh),
      reducedMotion,
    };
  }, [
    drift,
    setDrift,
    live,
    referenceFresh,
    dataMode,
    toggleDataMode,
    tokenIn,
    tokenOut,
    flipDirection,
    amountIn,
    slippageIndex,
    modal,
    reducedMotion,
  ]);

  return <AssayContext.Provider value={value}>{children}</AssayContext.Provider>;
}
