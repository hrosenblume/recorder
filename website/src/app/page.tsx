import { GitHubLink } from "@/components/github-link";
import { Hero } from "@/components/hero";
import { Features } from "@/components/features";
import { Install } from "@/components/install";
import { Footer } from "@/components/footer";

export default function Home() {
  return (
    <main className="flex-1">
      <GitHubLink />
      <Hero />
      <Features />
      <Install />
      <Footer />
    </main>
  );
}
