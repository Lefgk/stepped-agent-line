import { http, createConfig } from "wagmi";
import { mainnet, base, foundry } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import type { Address } from "viem";
import deploymentsFile from "./deployments.json";

const env = import.meta.env;

export const config = createConfig({
  chains: [base, mainnet, foundry],
  connectors: [injected()],
  transports: {
    [mainnet.id]: http(env.VITE_MAINNET_RPC || undefined),
    [base.id]: http(env.VITE_BASE_RPC || undefined),
    [foundry.id]: http(env.VITE_ANVIL_RPC || "http://127.0.0.1:8545"),
  },
});

const asAddr = (v?: string) => (v && /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as Address) : undefined);

type DeploymentRow = { factory?: string; usdc?: string };
const file = deploymentsFile as Record<string, DeploymentRow>;
const fromFile = (chainId: number): { factory?: Address; usdc?: Address } => {
  const row = file[String(chainId)] ?? {};
  return { factory: asAddr(row.factory), usdc: asAddr(row.usdc) };
};

/** Per-chain deployment addresses. Env vars override deployments.json. Empty factory = not deployed yet. */
export const deployments: Record<number, { factory?: Address; usdc?: Address; live: boolean }> = {
  [mainnet.id]: {
    factory: asAddr(env.VITE_FACTORY_MAINNET) ?? fromFile(mainnet.id).factory,
    usdc: fromFile(mainnet.id).usdc ?? "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    live: true,
  },
  [base.id]: {
    factory: asAddr(env.VITE_FACTORY_BASE) ?? fromFile(base.id).factory,
    usdc: fromFile(base.id).usdc ?? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    live: true,
  },
  // Anvil defaults match `script/deploy-anvil.sh` on a fresh anvil when the json entry is empty.
  // MockUSDC is the first create, the factory the second.
  [foundry.id]: {
    factory: asAddr(env.VITE_FACTORY_ANVIL) ?? fromFile(foundry.id).factory ?? "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
    usdc: asAddr(env.VITE_USDC_ANVIL) ?? fromFile(foundry.id).usdc ?? "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    live: false,
  },
};

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
