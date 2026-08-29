"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { WagmiProvider } from "wagmi";

import { wagmiConfig } from "@/lib/wagmi";
import { DEPLOYED } from "@/lib/protocol/config";
import type { DataMode } from "@/lib/protocol/fixtures";
import { TOKEN_PAIR } from "@/lib/protocol/fixtures";
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
  flipDirection: () => void;

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
  const [tokenIn, setTokenIn] = useState(TOKEN_PAIR.testnet[0]);
  const [tokenOut, setTokenOut] = useState(TOKEN_PAIR.testnet[1]);
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

  const toggleDataMode = useCallback(() => {
    setDataMode((current) => {
      const next: DataMode = current === "testnet" ? "mainnet-mock" : "testnet";
      const [nextIn, nextOut] = TOKEN_PAIR[next];
      setTokenIn(nextIn);
      setTokenOut(nextOut);
      return next;
    });
  }, []);

  const flipDirection = useCallback(() => {
    setTokenIn((currentIn) => {
      setTokenOut(currentIn);
      return tokenOut;
    });
  }, [tokenOut]);

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
