import ApiKeySection from "./ApiKeySection";

export default function Home() {
  return (
    <div className="min-h-screen bg-zinc-50 font-sans dark:bg-black">
      <main className="flex min-h-screen flex-col items-center justify-center py-16">
        <div className="flex flex-col items-center gap-4 px-6 text-center">
          <h1 className="text-5xl font-bold text-black dark:text-white">
            EKS Golden Platform
          </h1>
          <p className="text-xl text-zinc-600 dark:text-zinc-400">
            Generate and manage API keys. Keys are minted server-side and stored
            as hashes in Amazon RDS.
          </p>
        </div>

        <ApiKeySection />
      </main>
    </div>
  );
}

