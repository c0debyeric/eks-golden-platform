import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactCompiler: true,

  // Emit .next/standalone: a self-contained server bundle with only the
  // node_modules actually reached by the build. This is what lets the runtime
  // image skip `npm ci` entirely — without it the image has to carry the full
  // dependency tree (hundreds of MB) and Next's own toolchain.
  output: "standalone",

  // The pod runs behind an ALB and is not the public origin; Next only needs to
  // stop advertising itself.
  poweredByHeader: false,
};

export default nextConfig;
