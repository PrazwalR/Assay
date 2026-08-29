"use client";

import { useSyncExternalStore } from "react";

/**
 * Whether the viewer has asked for reduced motion.
 *
 * CSS already suppresses animation (see globals.css), but some motion in this app is a *value*
 * changing rather than a property animating — the live-market walk moves a number every 2.2s,
 * which no media query can stop. This hook is what lets that be switched off too.
 *
 * `useSyncExternalStore` rather than `useState` + `useEffect`: a media query is an external
 * store, and subscribing to one through an effect means rendering once with the wrong answer
 * and then re-rendering, which is both a cascading render and a visible flash of motion for
 * exactly the people who asked for none.
 */

const QUERY = "(prefers-reduced-motion: reduce)";

function subscribe(onChange: () => void) {
  const query = window.matchMedia(QUERY);
  query.addEventListener("change", onChange);
  return () => query.removeEventListener("change", onChange);
}

const getSnapshot = () => window.matchMedia(QUERY).matches;

// The server has no media queries. `false` matches the CSS default, so the markup the server
// produces is the markup the client hydrates against.
const getServerSnapshot = () => false;

export function useReducedMotion(): boolean {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
}
