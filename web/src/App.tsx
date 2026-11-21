import { useState } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { erc20Abi, formatUnits, isAddress, parseUnits, type Address } from "viem";
import { steppedAgentVaultAbi, steppedAgentVaultFactoryAbi } from "./abi";
import { deployments } from "./config";

const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
const usdcFmt = (v?: bigint) => (v === undefined ? "…" : formatUnits(v, 6));
const ts = (v?: bigint | number) => {
  const n = Number(v ?? 0);
  return n > 0 ? new Date(n * 1000).toLocaleString() : "—";
};

type Line = {
  active: boolean;
  allowlistEnabled: boolean;
  frozen: boolean;
  epoch: number;
  term: bigint;
  grace: bigint;
  dueDate: bigint;
  starterCap: bigint;
  stepSize: bigint;
  maxCap: bigint;
  currentCap: bigint;
  principal: bigint;
};

type CreditHistory = {
  onTimeCount: number;
  defaultCount: number;
  currentTier: number;
  currentCap: bigint;
  starterCap: bigint;
  maxCap: bigint;
  frozen: boolean;
  active: boolean;
  lastDefaultAt: bigint;
};

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, chains } = useSwitchChain();
  const dep = deployments[chainId] ?? {};
  const [vault, setVault] = useState<Address | "">("");

  return (
    <div className="wrap">
      <h1>Stepped Agent Line</h1>
      <div className="muted">
        Backer-funded USDC credit lines for AI agents: the cap starts small and steps up after each
        on-time full repayment, up to a max. A missed due date (after grace) freezes the line and
        leaves a public default. Prototype — not audited. Ethereum, Base and local anvil. No interest,
        no fee. Fully backer-collateralized.
      </div>

      <div className="card">
        <h2>Wallet</h2>
        {!isConnected ? (
          <div className="row">
            {connectors.map((c) => (
              <button key={c.uid} onClick={() => connect({ connector: c })}>
                Connect {c.name}
              </button>
            ))}
          </div>
        ) : (
          <div className="row">
            <span>
              Connected <code>{address}</code>
            </span>
            <button className="ghost" onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        )}
        <div className="row">
          {chains.map((c) => (
            <button key={c.id} className={c.id === chainId ? "" : "ghost"} onClick={() => switchChain({ chainId: c.id })}>
              {c.name}
            </button>
          ))}
        </div>
        {!deployments[chainId] && <div className="warn">Unsupported chain: use Ethereum, Base or local anvil.</div>}
        {deployments[chainId] && !dep.factory && (
          <div className="warn">
            <strong>Not deployed yet</strong> on this chain — the factory address is empty. Core flows stay disabled until
            you deploy (<code>make deploy-mainnet</code> or <code>make deploy-base</code>), which writes the address into{" "}
            <code>web/src/deployments.json</code>. You can still paste an existing vault address below after connecting.
          </div>
        )}
        {deployments[chainId]?.live && dep.factory && (
          <div className="warn">
            Live chain with real funds. This contract is NOT audited — only deposit amounts you can afford to lose.
          </div>
        )}
      </div>

      {isConnected && address && (
        <>
          <VaultPicker owner={address} factory={dep.factory} vault={vault} setVault={setVault} />
          {vault && isAddress(vault) && (
            <>
              <VaultOverview vault={vault} usdc={dep.usdc} />
              <BackerSetup vault={vault} />
              <AgentView vault={vault} usdc={dep.usdc} />
              <HistoryLookup vault={vault} />
            </>
          )}
        </>
      )}
    </div>
  );
}

function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [status, setStatus] = useState("");
  const run = async (label: string, fn: () => Promise<`0x${string}`>) => {
    try {
      setStatus(`${label}: confirm in wallet…`);
      const hash = await fn();
      setStatus(`${label}: pending ${short(hash)}`);
      await client!.waitForTransactionReceipt({ hash });
      setStatus(`${label}: confirmed ✓`);
      return true;
    } catch (e) {
      setStatus(`${label}: ${(e as Error).message.split("\n")[0]}`);
      return false;
    }
  };
  return { writeContractAsync, status, run };
}

function VaultPicker(props: {
  owner: Address;
  factory?: Address;
  vault: string;
  setVault: (v: Address | "") => void;
}) {
  const { owner, factory, vault, setVault } = props;
  const { data: vaults, refetch } = useReadContract({
    address: factory,
    abi: steppedAgentVaultFactoryAbi,
    functionName: "vaultsOf",
    args: [owner],
    query: { enabled: !!factory },
  });
  const { writeContractAsync, status, run } = useTx();
  return (
    <div className="card">
      <h2>1. Vault</h2>
      {!factory && (
        <div className="warn">
          <strong>Not deployed yet.</strong> No factory address for this chain. Deploy first (see DEPLOY.md), or set
          VITE_FACTORY_* in web/.env.
        </div>
      )}
      <div className="row">
        <button
          disabled={!factory}
          onClick={async () => {
            if (
              await run("Create vault", () =>
                writeContractAsync({ address: factory!, abi: steppedAgentVaultFactoryAbi, functionName: "createVault" }),
              )
            ) {
              const r = await refetch();
              const list = r.data ?? [];
              if (list.length) setVault(list[list.length - 1]);
            }
          }}
        >
          Create new vault
        </button>
        <label>
          Or use vault address
          <input value={vault} placeholder="0x…" onChange={(e) => setVault(e.target.value as Address)} />
        </label>
      </div>
      {vaults && vaults.length > 0 && (
        <div className="row">
          {vaults.map((v) => (
            <button key={v} className={v === vault ? "" : "ghost"} onClick={() => setVault(v)}>
              {short(v)}
            </button>
          ))}
        </div>
      )}
      <div className="muted">{status}</div>
    </div>
  );
}

function VaultOverview({ vault, usdc }: { vault: Address; usdc?: Address }) {
  const { data: usdcBal, refetch: refetchUsdc } = useReadContract({
    address: usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
    query: { enabled: !!usdc },
  });
  const { data: paused, refetch: refetchPaused } = useReadContract({
    address: vault,
    abi: steppedAgentVaultAbi,
    functionName: "paused",
  });
  const { data: owner } = useReadContract({ address: vault, abi: steppedAgentVaultAbi, functionName: "owner" });
  const { data: totalPrincipal, refetch: refetchPrin } = useReadContract({
    address: vault,
    abi: steppedAgentVaultAbi,
    functionName: "totalPrincipal",
  });
  const { address } = useAccount();
  const { writeContractAsync, status, run } = useTx();
  const [usdcAmt, setUsdcAmt] = useState("100");
  const isOwner = address && owner && address.toLowerCase() === owner.toLowerCase();

  const refresh = () => {
    refetchUsdc();
    refetchPaused();
    refetchPrin();
  };

  return (
    <div className="card">
      <h2>2. Backer funding</h2>
      <div className="muted">
        Backer <code>{owner ? short(owner) : "…"}</code>
        {" · "}liquidity {usdcFmt(usdcBal)} USDC
        {" · "}outstanding {usdcFmt(totalPrincipal)}
        {" · "}
        {paused ? <span className="bad">paused</span> : <span className="ok">active</span>}
      </div>
      <div className="row">
        <label>
          Amount (USDC)
          <input value={usdcAmt} onChange={(e) => setUsdcAmt(e.target.value)} />
        </label>
        <button
          disabled={!usdc || !isOwner}
          onClick={async () => {
            if (!usdc) return;
            const amt = parseUnits(usdcAmt || "0", 6);
            if (
              await run("Approve USDC", () =>
                writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [vault, amt] }),
              )
            ) {
              await run("Deposit", () =>
                writeContractAsync({ address: vault, abi: steppedAgentVaultAbi, functionName: "deposit", args: [amt] }),
              );
              refresh();
            }
          }}
        >
          Deposit
        </button>
        <button
          className="ghost"
          disabled={!usdc || !isOwner || !address}
          onClick={async () => {
            const amt = parseUnits(usdcAmt || "0", 6);
            if (
              await run("Withdraw", () =>
                writeContractAsync({
                  address: vault,
                  abi: steppedAgentVaultAbi,
                  functionName: "withdraw",
                  args: [address!, amt],
                }),
              )
            )
              refresh();
          }}
        >
          Withdraw unused
        </button>
        <button
          className="danger"
          disabled={!isOwner}
          onClick={async () => {
            if (
              await run(paused ? "Unpause" : "Pause", () =>
                writeContractAsync({
                  address: vault,
                  abi: steppedAgentVaultAbi,
                  functionName: paused ? "unpause" : "pause",
                }),
              )
            )
              refresh();
          }}
        >
          {paused ? "Unpause" : "Pause"}
        </button>
      </div>
      <div className="muted">{status}</div>
    </div>
  );
}

function BackerSetup({ vault }: { vault: Address }) {
  const { address } = useAccount();
  const { data: owner } = useReadContract({ address: vault, abi: steppedAgentVaultAbi, functionName: "owner" });
  const isOwner = address && owner && address.toLowerCase() === owner.toLowerCase();
  const [agent, setAgent] = useState("");
  const [starter, setStarter] = useState("100");
  const [step, setStep] = useState("50");
  const [maxCap, setMaxCap] = useState("500");
  const [termDays, setTermDays] = useState("30");
  const [graceDays, setGraceDays] = useState("3");
  const [allowlist, setAllowlist] = useState(false);
  const [recipient, setRecipient] = useState("");
  const { writeContractAsync, status, run } = useTx();
  const validAgent = isAddress(agent);

  const { data: line, refetch } = useReadContract({
    address: vault,
    abi: steppedAgentVaultAbi,
    functionName: "getLine",
    args: validAgent ? [agent as Address] : undefined,
    query: { enabled: validAgent },
  });

  const open = async () => {
    if (
      await run("Open / update line", () =>
        writeContractAsync({
          address: vault,
          abi: steppedAgentVaultAbi,
          functionName: "openLine",
          args: [
            agent as Address,
            parseUnits(starter || "0", 6),
            parseUnits(step || "0", 6),
            parseUnits(maxCap || "0", 6),
            BigInt(Number(termDays) * 86400),
            BigInt(Number(graceDays) * 86400),
            allowlist,
          ],
        }),
      )
    )
      refetch();
  };

  const l = line as Line | undefined;

  return (
    <div className="card">
      <h2>3. Open a stepped line (backer)</h2>
      <div className="row">
        <label>
          Agent address
          <input value={agent} placeholder="0x…" onChange={(e) => setAgent(e.target.value)} />
        </label>
        <label>
          Starter cap (USDC)
          <input value={starter} onChange={(e) => setStarter(e.target.value)} />
        </label>
        <label>
          Step size (USDC)
          <input value={step} onChange={(e) => setStep(e.target.value)} />
        </label>
        <label>
          Max cap (USDC)
          <input value={maxCap} onChange={(e) => setMaxCap(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <label>
          Term (days)
          <input value={termDays} onChange={(e) => setTermDays(e.target.value)} />
        </label>
        <label>
          Grace (days)
          <input value={graceDays} onChange={(e) => setGraceDays(e.target.value)} />
        </label>
        <label>
          Destination allowlist
          <select value={allowlist ? "on" : "off"} onChange={(e) => setAllowlist(e.target.value === "on")}>
            <option value="off">Off — any destination</option>
            <option value="on">On — only listed addresses</option>
          </select>
        </label>
        <button disabled={!isOwner || !validAgent} onClick={open}>
          Open / update line
        </button>
        <button
          className="danger"
          disabled={!isOwner || !validAgent}
          onClick={async () => {
            if (
              await run("Revoke", () =>
                writeContractAsync({
                  address: vault,
                  abi: steppedAgentVaultAbi,
                  functionName: "revokeAgent",
                  args: [agent as Address],
                }),
              )
            )
              refetch();
          }}
        >
          Revoke
        </button>
        <button
          className="ghost"
          disabled={!isOwner || !validAgent}
          onClick={async () => {
            if (
              await run("Clear default", () =>
                writeContractAsync({
                  address: vault,
                  abi: steppedAgentVaultAbi,
                  functionName: "clearDefault",
                  args: [agent as Address],
                }),
              )
            )
              refetch();
          }}
        >
          Clear default
        </button>
      </div>
      <div className="row">
        <label>
          Allowlisted recipient
          <input value={recipient} placeholder="0x…" onChange={(e) => setRecipient(e.target.value)} />
        </label>
        <button
          disabled={!isOwner || !validAgent || !isAddress(recipient)}
          onClick={async () => {
            if (
              await run("Allow recipient", () =>
                writeContractAsync({
                  address: vault,
                  abi: steppedAgentVaultAbi,
                  functionName: "setRecipient",
                  args: [agent as Address, recipient as Address, true],
                }),
              )
            )
              refetch();
          }}
        >
          Allow
        </button>
      </div>
      {l && (
        <div className="muted">
          {l.active ? <span className="ok">active</span> : "inactive"}
          {l.frozen ? " · " : " · "}
          {l.frozen ? <span className="bad">frozen</span> : <span className="ok">not frozen</span>}
          {" · "}cap {usdcFmt(l.currentCap)} / max {usdcFmt(l.maxCap)} (starter {usdcFmt(l.starterCap)}, step{" "}
          {usdcFmt(l.stepSize)})
          {" · "}debt {usdcFmt(l.principal)}
          {" · "}due {ts(l.dueDate)}
        </div>
      )}
      <div className="muted">{status}</div>
    </div>
  );
}

function AgentView({ vault, usdc }: { vault: Address; usdc?: Address }) {
  const { address } = useAccount();
  const [to, setTo] = useState("");
  const [amt, setAmt] = useState("10");
  const [memo, setMemo] = useState("");
  const [repayAgent, setRepayAgent] = useState("");
  const { writeContractAsync, status, run } = useTx();

  const { data: line, refetch: refetchLine } = useReadContract({
    address: vault,
    abi: steppedAgentVaultAbi,
    functionName: "getLine",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const { data: credit, refetch: refetchCredit } = useReadContract({
    address: vault,
    abi: steppedAgentVaultAbi,
    functionName: "availableCredit",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const { data: hist, refetch: refetchHist } = useReadContract({
    address: vault,
    abi: steppedAgentVaultAbi,
    functionName: "creditHistory",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  const refresh = () => {
    refetchLine();
    refetchCredit();
    refetchHist();
  };

  const l = line as Line | undefined;
  const h = hist as CreditHistory | undefined;

  return (
    <div className="card">
      <h2>4. Borrow / repay (agent or anyone paying)</h2>
      <div className="muted">
        Your line:{" "}
        {l ? (
          <>
            cap {usdcFmt(l.currentCap)} · available {usdcFmt(credit)} · debt {usdcFmt(l.principal)} · due {ts(l.dueDate)}
            {h ? ` · tier ${h.currentTier} · on-time ${h.onTimeCount} · defaults ${h.defaultCount}` : ""}
            {l.frozen ? " · frozen" : ""}
          </>
        ) : (
          "…"
        )}
      </div>
      <div className="row">
        <label>
          Pay to
          <input value={to} placeholder="0x…" onChange={(e) => setTo(e.target.value)} />
        </label>
        <label>
          Borrow (USDC)
          <input value={amt} onChange={(e) => setAmt(e.target.value)} />
        </label>
        <label>
          Memo (optional)
          <input value={memo} onChange={(e) => setMemo(e.target.value)} />
        </label>
        <button
          disabled={!isAddress(to)}
          onClick={async () => {
            const raw = new TextEncoder().encode(memo).slice(0, 32);
            const hex = Array.from(raw, (b) => b.toString(16).padStart(2, "0")).join("").padEnd(64, "0");
            const bytes32 = (`0x${hex}`) as `0x${string}`;
            if (
              await run("Borrow", () =>
                writeContractAsync({
                  address: vault,
                  abi: steppedAgentVaultAbi,
                  functionName: "borrow",
                  args: [to as Address, parseUnits(amt || "0", 6), bytes32],
                }),
              )
            )
              refresh();
          }}
        >
          Borrow
        </button>
      </div>
      <div className="row">
        <label>
          Repay for agent
          <input
            value={repayAgent}
            placeholder={address ?? "0x…"}
            onChange={(e) => setRepayAgent(e.target.value)}
          />
        </label>
        <label>
          Amount (USDC)
          <input value={amt} onChange={(e) => setAmt(e.target.value)} />
        </label>
        <button
          disabled={!usdc}
          onClick={async () => {
            if (!usdc || !address) return;
            const who = (isAddress(repayAgent) ? repayAgent : address) as Address;
            const value = parseUnits(amt || "0", 6);
            if (
              await run("Approve USDC", () =>
                writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [vault, value] }),
              )
            ) {
              if (
                await run("Repay", () =>
                  writeContractAsync({
                    address: vault,
                    abi: steppedAgentVaultAbi,
                    functionName: "repay",
                    args: [who, value],
                  }),
                )
              )
                refresh();
            }
          }}
        >
          Repay
        </button>
        <button
          className="danger"
          onClick={async () => {
            const who = (isAddress(repayAgent) ? repayAgent : address) as Address;
            if (
              await run("Mark default", () =>
                writeContractAsync({
                  address: vault,
                  abi: steppedAgentVaultAbi,
                  functionName: "markDefault",
                  args: [who],
                }),
              )
            )
              refresh();
          }}
        >
          Mark default
        </button>
      </div>
      <div className="muted">{status}</div>
    </div>
  );
}

function HistoryLookup({ vault }: { vault: Address }) {
  const [agent, setAgent] = useState("");
  const valid = isAddress(agent);
  const { data: hist, refetch } = useReadContract({
    address: vault,
    abi: steppedAgentVaultAbi,
    functionName: "creditHistory",
    args: valid ? [agent as Address] : undefined,
    query: { enabled: valid },
  });
  const { data: due } = useReadContract({
    address: vault,
    abi: steppedAgentVaultAbi,
    functionName: "amountDue",
    args: valid ? [agent as Address] : undefined,
    query: { enabled: valid },
  });
  const h = hist as CreditHistory | undefined;

  return (
    <div className="card">
      <h2>5. Public credit history</h2>
      <div className="muted">Anyone can look up an agent. Other apps can call <code>creditHistory(agent)</code> on-chain.</div>
      <div className="row">
        <label>
          Agent address
          <input value={agent} placeholder="0x…" onChange={(e) => setAgent(e.target.value)} />
        </label>
        <button disabled={!valid} onClick={() => refetch()}>
          Look up
        </button>
      </div>
      {h && (
        <table>
          <tbody>
            <tr>
              <th>On-time repayments</th>
              <td>{h.onTimeCount}</td>
            </tr>
            <tr>
              <th>Defaults</th>
              <td className={h.defaultCount ? "bad" : ""}>{h.defaultCount}</td>
            </tr>
            <tr>
              <th>Current tier</th>
              <td>{h.currentTier}</td>
            </tr>
            <tr>
              <th>Current cap</th>
              <td>
                {usdcFmt(h.currentCap)} USDC (starter {usdcFmt(h.starterCap)}, max {usdcFmt(h.maxCap)})
              </td>
            </tr>
            <tr>
              <th>Outstanding</th>
              <td>{usdcFmt(due)} USDC</td>
            </tr>
            <tr>
              <th>Status</th>
              <td>
                {h.active ? <span className="ok">active</span> : "inactive"}
                {" · "}
                {h.frozen ? <span className="bad">frozen</span> : <span className="ok">not frozen</span>}
              </td>
            </tr>
            <tr>
              <th>Last default</th>
              <td>{ts(h.lastDefaultAt)}</td>
            </tr>
          </tbody>
        </table>
      )}
    </div>
  );
}
