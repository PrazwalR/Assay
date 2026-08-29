import { Footer } from "@/components/shell/Footer";
import { Header } from "@/components/shell/Header";
import { StatusBanner } from "@/components/shell/StatusBanner";
import { ModalHost } from "@/components/modals/ModalHost";

export function AppShell({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col bg-bg">
      <StatusBanner />
      <Header />
      <div className="flex-1">{children}</div>
      <Footer />
      <ModalHost />
    </div>
  );
}
