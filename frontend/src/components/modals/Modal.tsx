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
    const node = panel.current;

    // Captured before anything below moves focus. Reading it afterwards would record the panel
    // itself and "restoring" would be a no-op — the bug this ordering exists to avoid.
    // An autofocused child has already taken focus by now (React applies `autoFocus` in the
    // layout phase, before this passive effect), so in that case this is the element that
    // opened the modal, which is exactly what we want to return to.
    const opener = node?.contains(document.activeElement)
      ? null
      : (document.activeElement as HTMLElement | null);

    // Focus the panel only when nothing inside already took it. Focusing unconditionally stole
    // the caret out of the search and token inputs and left them untypeable.
    if (node && !node.contains(document.activeElement)) node.focus();

    const { overflow } = document.body.style;
    document.body.style.overflow = "hidden";

    // Without a trap, Tab walks straight out of the dialog into the header and footer behind
    // the scrim, which are still clickable. `aria-modal` alone does not stop that.
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Tab" || !panel.current) return;
      const focusable = panel.current.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])',
      );
      if (focusable.length === 0) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", onKeyDown);

    return () => {
      document.body.style.overflow = overflow;
      document.removeEventListener("keydown", onKeyDown);
      // Returning focus where it came from, rather than dropping it on <body> and sending
      // keyboard users back to the top of the document after every modal.
      opener?.focus?.();
    };
  }, []);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-5"
      style={{ animation: "assayRise 0.18s ease" }}
      // Dismiss only when the press *started* on the scrim. `click` fires on the common ancestor
      // of press and release, so a text selection dragged out of the panel would otherwise close
      // the dialog mid-gesture.
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div
        ref={panel}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        tabIndex={-1}
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
