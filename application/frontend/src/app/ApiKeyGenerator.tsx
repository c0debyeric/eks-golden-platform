"use client";

type ApiKeyGeneratorProps = {
  setApiKey: (key: string) => void;
};

export function getApiKey(length: number = 32): string {
  const chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

  let result = "";

  for (let i = 0; i < length; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }

  console.log("Generated API Key:", result);

  return result;
}

export default function ApiKeyGenerator({
  setApiKey
}: ApiKeyGeneratorProps) {

  return (
    <div className="flex flex-row px-12 gap-16 font-bold text-zinc-600 dark:text-zinc-400">

      <button
        onClick={() => setApiKey(getApiKey())}
        className="h-12 items-center justify-center rounded-full bg-foreground text-background transition-colors hover:bg-[#383838] dark:hover:bg-[#ccc] md:w-[158px] cursor-pointer"
      >
        Generate API Key
      </button>

      <button
        onClick={() => setApiKey("")}
        className="rounded-full w-full border border-solid border-black/[.08] transition-colors hover:border-transparent hover:bg-black/[.04] dark:border-white/[.145] dark:hover:bg-[#1a1a1a] md:w-[158px]"
      >
        Clear API Key
      </button>

    </div>
  );
}