"use client";

import { useState } from "react";
import ApiKeyGenerator, { getApiKey } from "./ApiKeyGenerator";

export default function ApiKeySection() {
  const [apiKey, setApiKey] = useState("");

  return (
    <>
      <div className="py-12 px-12 text-center gap-10 text-2xl font-bold text-zinc-600 dark:text-zinc-400">
        {"API Key Here: " + apiKey || "API Key here."}
      </div>

      <ApiKeyGenerator setApiKey={setApiKey} />
    </>
  );
}