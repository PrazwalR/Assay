"use client";

import { useEffect, useRef } from "react";

/**
 * Modal shell. Escape is handled globally in `Providers` (it also clears other transient
 * state), so this only owns the scrim, focus, and scroll lock.
 */
export function Modal({
  title,
  width = 440,
  onClose,
  children,
}: {
  title: string;
  width?: number;
  onClose: () => void;
  children: React.ReactNode;
}) {
  const panel = useRef<HTMLDivElement>(null);

  useEffect(() => {
    // Moving focus into the panel is what makes Escape and Tab behave for keyboard users; a
    // modal that leaves focus behind it is a modal only for people using a mouse.
    panel.current?.focus();

    const { overflow } = document.body.style;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = overflow;
    };
  }, []);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-5"
      style={{ animation: "assayRise 0.18s ease" }}
      onClick={onClose}
    >
      <div
        ref={panel}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        tabIndex={-1}
        onClick={(event) => event.stopPropagation()}
        style={{
          maxWidth: width,
          animation: "assayRise 0.26s cubic-bezier(.22,1,.36,1)",
          boxShadow: "0 40px 90px -30px rgb(0 0 0 / 0.9)",
        }}
        className="max-h-[82vh] w-full overflow-y-auto rounded-[18px] border border-border-2 bg-surface outline-none"
      >
        <div className="flex items-center justify-between gap-4 border-b border-border px-5 py-4">
          <h2 className="text-[15px] font-semibold leading-none tracking-[-0.01em] text-text">
            {title}
          </h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="flex size-[26px] items-center justify-center rounded-md bg-surface-5 font-mono text-[13px] leading-none text-text-dim transition-colors hover:text-text"
          >
            ✕
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}
