import type { Metadata } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
import type { ReactNode } from "react";

import { AppShell } from "@/components/AppShell";
import { Providers } from "@/components/Providers";

import "./globals.css";

// Inter carries the interface; JetBrains Mono is reserved for figures and
// addresses, where a tabular column and an unambiguous zero matter more than
// the shape of the prose around them.
const inter = Inter({ subsets: ["latin"], variable: "--font-inter", display: "swap" });
const jetbrainsMono = JetBrains_Mono({
  subsets: ["latin"],
  weight: ["400", "500"],
  variable: "--font-jetbrains-mono",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Aegis — rule-governed XRPL treasury",
  description:
    "Spending policy on Flare, signing keys inside a TEE. A payment is signed only if the on-chain policy authorised that exact payment.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${jetbrainsMono.variable}`}>
      <body>
        <Providers>
          <AppShell>{children}</AppShell>
        </Providers>
      </body>
    </html>
  );
}
