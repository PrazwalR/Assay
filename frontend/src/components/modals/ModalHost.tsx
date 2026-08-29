"use client";

import { useAssay } from "@/components/Providers";
import { Modal } from "@/components/modals/Modal";
import { NetworkModal } from "@/components/modals/NetworkModal";
import { SearchModal } from "@/components/modals/SearchModal";
import { SettingsModal } from "@/components/modals/SettingsModal";
import { TokenModal } from "@/components/modals/TokenModal";
import { WalletModal } from "@/components/modals/WalletModal";

const TITLES = {
  tokenIn: "Select a token to pay",
  tokenOut: "Select a token to receive",
  wallet: "Wallet",
  network: "Network",
  settings: "Transaction settings",
  search: "Search documentation",
} as const;

export function ModalHost() {
  const { modal, closeModal } = useAssay();
  if (!modal) return null;

  return (
    <Modal
      title={TITLES[modal]}
      width={modal === "settings" ? 420 : 440}
      onClose={closeModal}
    >
      {(modal === "tokenIn" || modal === "tokenOut") && <TokenModal side={modal} />}
      {modal === "wallet" && <WalletModal />}
      {modal === "network" && <NetworkModal />}
      {modal === "settings" && <SettingsModal />}
      {modal === "search" && <SearchModal />}
    </Modal>
  );
}
