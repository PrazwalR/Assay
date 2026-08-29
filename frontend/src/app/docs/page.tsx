import { redirect } from "next/navigation";
import { DOC_PAGES } from "@/lib/docs";

export default function DocsIndex() {
  redirect(`/docs/${DOC_PAGES[0].slug}`);
}
