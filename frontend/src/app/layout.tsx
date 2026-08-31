import type { Metadata } from "next";
import { Archivo, JetBrains_Mono } from "next/font/google";

import { AppShell } from "@/components/shell/AppShell";
import { Providers } from "@/components/Providers";

import "./globals.css";

// Spec §3: two families. Archivo carries anything addressed to a person; JetBrains Mono
// carries every machine fact and every number a user could act on.
const archivo = Archivo({
  variable: "--font-archivo",
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  display: "swap",
});

const jetbrainsMono = JetBrains_Mono({
  variable: "--font-jetbrains-mono",
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  display: "swap",
});

// Resolves `opengraph-image`'s meta tag to an absolute URL, which link unfurling requires and
// a relative path silently fails at. Prefers an explicit custom domain, falls back to Vercel's
// own deployment URL, then localhost for `pnpm dev`.
const siteUrl =
  process.env.NEXT_PUBLIC_SITE_URL ??
  (process.env.VERCEL_URL ? `https://${process.env.VERCEL_URL}` : "http://localhost:3000");

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: "Assay — per-swap adverse selection pricing",
  description:
    "A Uniswap v4 hook that prices each swap on the drift it captures against a cached reference, signed by direction — rather than charging every swap in a block the same volatility-derived rate.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${archivo.variable} ${jetbrainsMono.variable} h-full antialiased`}
    >
      <body className="min-h-full">
        <Providers>
          <AppShell>{children}</AppShell>
        </Providers>
      </body>
    </html>
  );
}
