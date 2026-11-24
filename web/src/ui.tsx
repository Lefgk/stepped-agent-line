// Shared UI kit for the management page: page shell (network + contract trust signals),
// address links, action hints and transaction status. No dependencies beyond wagmi/viem/react.
import { useRef, useState, type ReactNode } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import type { Address } from "viem";

export const BASE_CHAIN_ID = 8453;
const LOCAL_CHAIN_ID = 31337;

export const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

const EXPLORERS: Record<number, { name: string; url: string }> = {
  1: { name: "Etherscan", url: "https://etherscan.io" },
  8453: { name: "BaseScan", url: "https://basescan.org" },
};

export function explorerUrl(chainId: number, kind: "address" | "tx", value: string) {
  const ex = EXPLORERS[chainId];
  return ex ? `${ex.url}/${kind}/${value}` : undefined;
}

function CopyButton({ value }: { value: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      type="button"
      className="copy"
      title="Copy full address"
      aria-label={`Copy ${value}`}
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(value);
          setDone(true);
          setTimeout(() => setDone(false), 1200);
        } catch {
          /* clipboard unavailable: the full value is still in the title/link */
        }
      }}
    >
      {done ? "Copied" : "Copy"}
    </button>
  );
}

/** Address (or tx hash) with explorer link and copy. Short by default; `full` prints the whole value. */
export function Addr(props: { value?: string; full?: boolean; kind?: "address" | "tx"; copy?: boolean }) {
  const chainId = useChainId();
  const { value, full, kind = "address", copy = true } = props;
  if (!value) return <span className="muted">—</span>;
  const url = explorerUrl(chainId, kind, value);
  const text = <code className="addr-text">{full ? value : short(value)}</code>;
  return (
    <span className="addr">
      {url ? (
        <a href={url} target="_blank" rel="noopener noreferrer" title={`${value} — open in ${EXPLORERS[chainId].name}`}>
          {text}
          <span aria-hidden="true"> ↗</span>
        </a>
      ) : (
        <span title={value}>{text}</span>
      )}
      {copy && <CopyButton value={value} />}
    </span>
  );
}

/** One line under an action explaining what signing it will do. */
export function Hint({ children, tone }: { children: ReactNode; tone?: "danger" }) {
  return (
    <p className={`hint${tone ? ` hint-${tone}` : ""}`}>
      <span className="hint-tag">{tone === "danger" ? "Careful" : "What this does"}</span>
      {children}
    </p>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="empty">{children}</div>;
}

export function Loading({ children = "Loading on-chain data…" }: { children?: ReactNode }) {
  return (
    <div className="empty loading" role="status">
      <span className="spinner" aria-hidden="true" />
      {children}
    </div>
  );
}

function humanError(e: unknown): string {
  const err = e as { shortMessage?: string; message?: string };
  const raw = (err?.shortMessage || err?.message || String(e)).split("\n")[0];
  if (/user rejected|user denied|rejected the request|denied transaction/i.test(raw))
    return "Rejected in wallet — nothing was sent.";
  if (/insufficient funds/i.test(raw)) return "Not enough ETH in this wallet to pay for gas.";
  if (/chain mismatch|does not match the target chain/i.test(raw))
    return "Your wallet is on a different network — switch network and try again.";
  if (/not a valid decimal number|Cannot convert .* to a BigInt|invalid BigInt syntax/i.test(raw))
    return "One of the numbers is empty or not a valid number — nothing was sent.";
  if (/Address ".*" is invalid/i.test(raw))
    return "One of the addresses is not valid (0x followed by 40 hex characters) — nothing was sent.";
  return raw.length > 220 ? `${raw.slice(0, 220)}…` : raw;
}

type TxState =
  | { phase: "idle" }
  | { phase: "wallet" | "pending" | "ok" | "error"; label: string; hash?: `0x${string}`; message?: string };

/**
 * Transaction runner. `run` asks the wallet, waits for the receipt and reports each step;
 * `status` is a ready-to-render element; `fail` shows an input error without opening the wallet.
 */
export function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const chainId = useChainId();
  const { chainId: walletChainId } = useAccount();
  const queryClient = useQueryClient();
  const [state, setState] = useState<TxState>({ phase: "idle" });
  const inFlight = useRef(false);

  const run = async (label: string, fn: () => Promise<`0x${string}`>) => {
    if (inFlight.current) return false; // ignore double clicks while a prompt is open
    if (walletChainId !== undefined && walletChainId !== chainId) {
      // Never open a signing prompt while the wallet and the page disagree about the network.
      setState({
        phase: "error",
        label,
        message: `Your wallet is on chain ${walletChainId} but this page is showing chain ${chainId}. Switch network first — nothing was sent.`,
      });
      return false;
    }
    inFlight.current = true;
    let hash: `0x${string}` | undefined;
    try {
      setState({ phase: "wallet", label });
      hash = await fn();
      setState({ phase: "pending", label, hash });
      if (!client) throw new Error("No RPC client for this network.");
      const receipt = await client.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error("Transaction reverted on-chain — nothing changed.");
      setState({ phase: "ok", label, hash });
      // Balances, limits and lists on the page are now stale: re-read everything.
      void queryClient.invalidateQueries();
      return true;
    } catch (e) {
      setState({ phase: "error", label, hash, message: humanError(e) });
      return false;
    } finally {
      inFlight.current = false;
    }
  };

  const fail = (message: string) => setState({ phase: "error", label: "Check your input", message });

  /**
   * Wraps a click handler so a bad input (unparseable amount, malformed address, …) is shown
   * as an inline error instead of an unhandled exception. Nothing reaches the wallet in that case.
   */
  const safe = (fn: () => unknown | Promise<unknown>) => async () => {
    try {
      await fn();
    } catch (e) {
      fail(humanError(e));
    }
  };

  let status: ReactNode = null;
  if (state.phase !== "idle") {
    const url = state.hash ? explorerUrl(chainId, "tx", state.hash) : undefined;
    const text =
      state.phase === "wallet"
        ? "Waiting for you to confirm in your wallet…"
        : state.phase === "pending"
          ? "Submitted. Waiting for confirmation…"
          : state.phase === "ok"
            ? "Confirmed ✓"
            : state.message;
    status = (
      <div className={`tx tx-${state.phase}`} role="status" aria-live="polite">
        {(state.phase === "wallet" || state.phase === "pending") && <span className="spinner" aria-hidden="true" />}
        <span className="tx-body">
          <strong>{state.label}</strong> · {text}
          {state.hash && (
            <>
              {" "}
              {url ? (
                <a href={url} target="_blank" rel="noopener noreferrer">
                  View transaction ↗
                </a>
              ) : (
                <code>{state.hash}</code>
              )}
            </>
          )}
        </span>
      </div>
    );
  }

  const busy = state.phase === "wallet" || state.phase === "pending";
  return { writeContractAsync, status, run, fail, safe, busy };
}

/**
 * Page shell: title, what the dapp does, which network and contract you are talking to,
 * wallet connection and network warnings. Feature cards go in `children`.
 */
export function Shell(props: {
  title: string;
  tagline: ReactNode;
  /** 3–4 short steps shown under the tagline. */
  steps?: string[];
  /** Name of the entry contract, e.g. "Factory". */
  contractLabel: string;
  /** Entry contract address per chain id (undefined = not deployed there). */
  contractOf: (chainId: number) => Address | undefined;
  /** Other contracts this page touches on the current chain (USDC, Aave pool, …). */
  refs?: { label: string; address?: Address }[];
  /** Risk notice shown on live networks. */
  risk: ReactNode;
  children: ReactNode;
}) {
  const { title, tagline, steps, contractLabel, contractOf, refs, risk, children } = props;
  const { address, isConnected, chainId: walletChainId } = useAccount();
  const chainId = useChainId();
  const { connect, connectors, isPending: connecting, error: connectError } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, chains, isPending: switching, error: switchError } = useSwitchChain();

  const chain = chains.find((c) => c.id === chainId);
  const contract = contractOf(chainId);
  const onBase = chainId === BASE_CHAIN_ID;
  const live = chainId !== LOCAL_CHAIN_ID;
  const walletOnUnsupported = isConnected && walletChainId !== undefined && !chains.some((c) => c.id === walletChainId);
  const baseDeployed = !!contractOf(BASE_CHAIN_ID);

  return (
    <div className="wrap">
      <header className="top">
        <div className="top-title">
          <h1>{title}</h1>
          <span className="pill pill-warn" title="Prototype contracts. No third-party audit.">
            Prototype · not audited
          </span>
        </div>
        <p className="lede">{tagline}</p>
        {steps && steps.length > 0 && (
          <ol className="steps">
            {steps.map((s, i) => (
              <li key={i}>
                <span className="step-n">{i + 1}</span>
                <span>{s}</span>
              </li>
            ))}
          </ol>
        )}
        <div className="pills">
          <span className={`pill ${walletOnUnsupported ? "pill-bad" : onBase ? "pill-ok" : "pill-warn"}`}>
            <span className="dot" aria-hidden="true" />
            {walletOnUnsupported
              ? `Wallet on unsupported network (chain ${walletChainId})`
              : `${chain?.name ?? "Unknown network"} · chain ${chainId}`}
          </span>
          {contract ? (
            <span className="pill">
              {contractLabel} <Addr value={contract} />
            </span>
          ) : (
            <span className="pill pill-warn">{contractLabel} not deployed on this network</span>
          )}
          {(!onBase || walletOnUnsupported) && baseDeployed && (
            <button className="small" disabled={switching} onClick={() => switchChain({ chainId: BASE_CHAIN_ID })}>
              {switching ? "Switching…" : "Switch to Base"}
            </button>
          )}
        </div>
      </header>

      <section className="card">
        <h2>Wallet &amp; network</h2>
        {!isConnected ? (
          <>
            <div className="row">
              {connectors.map((c) => (
                <button key={c.uid} disabled={connecting} onClick={() => connect({ connector: c })}>
                  {connecting ? "Connecting…" : c.name === "Injected" ? "Connect browser wallet" : `Connect ${c.name}`}
                </button>
              ))}
            </div>
            <p className="muted">
              Connecting only shares your address. Nothing is signed or spent until you press an action button and
              confirm it in your wallet.
            </p>
            {connectError && (
              <div className="tx tx-error" role="alert">
                <span className="tx-body">
                  <strong>Could not connect</strong> · {humanError(connectError)} If you have no wallet extension, install
                  one (for example Coinbase Wallet or MetaMask) and reload.
                </span>
              </div>
            )}
          </>
        ) : (
          <div className="row row-center">
            <span className="grow">
              <span className="muted">Connected as</span> <Addr value={address} full />
            </span>
            <button className="ghost" onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        )}

        <div className="field-label">Network</div>
        <div className="row">
          {chains.map((c) => {
            const deployed = !!contractOf(c.id);
            return (
              <button
                key={c.id}
                className={c.id === chainId && !walletOnUnsupported ? "seg seg-on" : "seg"}
                aria-pressed={c.id === chainId && !walletOnUnsupported}
                disabled={switching}
                onClick={() => switchChain({ chainId: c.id })}
              >
                {c.name}
                <span className="seg-sub">
                  {c.id === LOCAL_CHAIN_ID ? "local test" : deployed ? `live · chain ${c.id}` : "not deployed"}
                </span>
              </button>
            );
          })}
        </div>
        {switchError && (
          <div className="tx tx-error" role="alert">
            <span className="tx-body">
              <strong>Network switch failed</strong> · {humanError(switchError)}
            </span>
          </div>
        )}

        {walletOnUnsupported && (
          <div className="warn">
            <strong>Wrong network.</strong> Your wallet is on chain {walletChainId}, which this app does not support.
            Switch to Base (chain {BASE_CHAIN_ID}) before signing anything.
          </div>
        )}

        {contract ? (
          <dl className="dl contracts">
            <dt>{contractLabel}</dt>
            <dd>
              <Addr value={contract} full />
            </dd>
            {(refs ?? [])
              .filter((r) => r.address)
              .map((r) => (
                <div className="dl-pair" key={r.label}>
                  <dt>{r.label}</dt>
                  <dd>
                    <Addr value={r.address} full />
                  </dd>
                </div>
              ))}
          </dl>
        ) : (
          <div className="warn">
            <strong>
              {title} is not deployed on {chain?.name ?? "this network"}.
            </strong>{" "}
            {baseDeployed && !onBase
              ? "The live contract is on Base (chain 8453) — switch network above. "
              : "Actions that need the contract stay disabled. "}
            {chainId === LOCAL_CHAIN_ID && (
              <>
                For local testing, deploy to anvil first; the address is read from <code>web/src/deployments.json</code>{" "}
                or a <code>VITE_*</code> override in <code>web/.env</code>.
              </>
            )}
          </div>
        )}

        {live && contract && <div className="warn">{risk}</div>}
      </section>

      {children}
    </div>
  );
}
