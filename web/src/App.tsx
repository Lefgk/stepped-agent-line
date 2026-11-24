import { useState } from "react";
import { useAccount, useChainId, useReadContract } from "wagmi";
import { erc20Abi, formatUnits, isAddress, parseUnits, type Address } from "viem";
import { steppedAgentVaultAbi, steppedAgentVaultFactoryAbi } from "./abi";
import { deployments } from "./config";
import { Addr, Empty, Hint, Loading, Shell, short, useTx } from "./ui";

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
  const dep = deployments[chainId] ?? {};
  const [vault, setVault] = useState<Address | "">("");

  return (
    <Shell
      title="Stepped Agent Line"
      tagline="A USDC credit line for an AI agent that grows with good behaviour. A backer funds a vault; the agent borrows up to a small starting cap, and each full on-time repayment steps the cap up, to a maximum. A missed due date freezes the line and leaves a public default. No interest, no fee."
      steps={[
        "Backer creates a vault and deposits USDC.",
        "Backer opens a line for an agent: starter cap, step size, max cap, term and grace.",
        "Agent borrows within the cap and repays in full before the due date; the cap steps up.",
        "Missed due date plus grace: anyone can mark a default, which freezes the line.",
      ]}
      contractLabel="Vault factory"
      contractOf={(id) => deployments[id]?.factory}
      refs={[{ label: "USDC", address: dep.usdc }]}
      risk={
        <>
          <strong>Real funds.</strong> This contract is not audited. Lending is unsecured: USDC an agent borrows leaves
          the vault, and nothing forces repayment. Only deposit amounts you can afford to lose.
        </>
      }
    >
      {!isConnected && <Empty>Connect a wallet to create a vault, fund a line, or borrow and repay as an agent.</Empty>}

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
    </Shell>
  );
}

function VaultPicker(props: {
  owner: Address;
  factory?: Address;
  vault: string;
  setVault: (v: Address | "") => void;
}) {
  const { owner, factory, vault, setVault } = props;
  const { data: vaults, refetch, isLoading } = useReadContract({
    address: factory,
    abi: steppedAgentVaultFactoryAbi,
    functionName: "vaultsOf",
    args: [owner],
    query: { enabled: !!factory },
  });
  const { writeContractAsync, status, run, safe } = useTx();
  return (
    <div className="card">
      <h2>1. Choose a vault</h2>
      <p className="muted">
        A vault is the backer's own contract. It holds the USDC and enforces every agent's cap. Agents paste the
        address of the vault that backs them.
      </p>
      <div className="field-label">Vaults you back on this network</div>
      {!factory ? (
        <Empty>No factory on this network, so vaults cannot be listed or created here.</Empty>
      ) : isLoading ? (
        <Loading>Looking up your vaults…</Loading>
      ) : vaults && vaults.length > 0 ? (
        <div className="row">
          {vaults.map((v) => (
            <button key={v} className={v === vault ? "seg seg-on" : "seg"} aria-pressed={v === vault} onClick={() => setVault(v)}>
              <code>{short(v)}</code>
              <span className="seg-sub">{v === vault ? "selected" : "select"}</span>
            </button>
          ))}
        </div>
      ) : (
        <Empty>This wallet backs no vaults yet. Create one below, or paste the address of a vault you borrow from.</Empty>
      )}
      <div className="row">
        <button
          disabled={!factory}
          onClick={safe(async () => {
            if (
              await run("Create vault", () =>
                writeContractAsync({ address: factory!, abi: steppedAgentVaultFactoryAbi, functionName: "createVault" }),
              )
            ) {
              const r = await refetch();
              const list = r.data ?? [];
              if (list.length) setVault(list[list.length - 1]);
            }
          })}
        >
          Create new vault
        </button>
        <label>
          Or open a vault by address
          <input value={vault} placeholder="0x…" spellCheck={false} onChange={(e) => setVault(e.target.value.trim() as Address)} />
        </label>
      </div>
      {vault && !isAddress(vault) && <div className="bad muted">That is not a valid address (0x followed by 40 hex characters).</div>}
      <Hint>
        “Create new vault” deploys a vault contract owned by your connected wallet. One transaction, gas only — no
        funds move.
      </Hint>
      {status}
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
  const { writeContractAsync, status, run, safe } = useTx();
  const [usdcAmt, setUsdcAmt] = useState("100");
  const isOwner = address && owner && address.toLowerCase() === owner.toLowerCase();

  const refresh = () => {
    refetchUsdc();
    refetchPaused();
    refetchPrin();
  };

  return (
    <div className="card">
      <h2>2. Vault funding (backer)</h2>
      <dl className="dl">
        <dt>Vault</dt>
        <dd>
          <Addr value={vault} full />
        </dd>
        <dt>Backer</dt>
        <dd>
          <Addr value={owner} /> {isOwner && <span className="ok">(you)</span>}
        </dd>
        <dt>Available to lend</dt>
        <dd>{usdcFmt(usdcBal)} USDC</dd>
        <dt>Lent out</dt>
        <dd>{usdcFmt(totalPrincipal)} USDC</dd>
        <dt>Borrowing</dt>
        <dd>{paused === undefined ? "…" : paused ? <span className="bad">Paused</span> : <span className="ok">Active</span>}</dd>
      </dl>
      {owner && !isOwner && (
        <div className="info">
          You are not the backer of this vault. Funding and line settings are disabled; borrowing, repaying and the
          public history below still work.
        </div>
      )}
      <div className="row">
        <label>
          Amount (USDC)
          <input value={usdcAmt} inputMode="decimal" onChange={(e) => setUsdcAmt(e.target.value)} />
        </label>
        <button
          disabled={!usdc || !isOwner}
          onClick={safe(async () => {
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
          })}
        >
          Approve + deposit
        </button>
        <button
          className="ghost"
          disabled={!usdc || !isOwner || !address}
          onClick={safe(async () => {
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
          })}
        >
          Withdraw unused
        </button>
        <button
          className={paused ? "" : "danger"}
          disabled={!isOwner}
          onClick={safe(async () => {
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
          })}
        >
          {paused ? "Unpause" : "Pause borrowing"}
        </button>
      </div>
      <Hint>
        Deposit asks twice: an approval for exactly this amount, then the deposit, which moves the USDC from your
        wallet into the vault where agents with a line can borrow it. “Withdraw unused” sends USDC that is not lent
        out back to your connected wallet. Pause blocks all new borrows; repayments and withdrawals still work.
      </Hint>
      {status}
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
  const { writeContractAsync, status, run, safe, fail } = useTx();
  const validAgent = isAddress(agent);

  const { data: line, refetch } = useReadContract({
    address: vault,
    abi: steppedAgentVaultAbi,
    functionName: "getLine",
    args: validAgent ? [agent as Address] : undefined,
    query: { enabled: validAgent },
  });

  const open = async () => {
    const t = Number(termDays);
    const g = Number(graceDays);
    if (!Number.isFinite(t) || t <= 0) return fail("Term must be a number of days greater than 0.");
    if (!Number.isFinite(g) || g < 0) return fail("Grace must be a number of days, 0 or more.");
    const caps = [parseUnits(starter || "0", 6), parseUnits(step || "0", 6), parseUnits(maxCap || "0", 6)] as const;
    if (caps[0] === 0n || caps[1] === 0n) return fail("Starter cap and step size must be greater than 0.");
    if (caps[2] < caps[0]) return fail("Max cap cannot be lower than the starter cap.");
    if (
      await run("Open / update line", () =>
        writeContractAsync({
          address: vault,
          abi: steppedAgentVaultAbi,
          functionName: "openLine",
          args: [
            agent as Address,
            caps[0],
            caps[1],
            caps[2],
            BigInt(Math.floor(t * 86400)),
            BigInt(Math.floor(g * 86400)),
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
      <h2>3. Agent line (backer)</h2>
      {!isOwner && <p className="muted">Only the backer can change lines. These controls are disabled for your wallet.</p>}
      <div className="row">
        <label>
          Agent address
          <input value={agent} placeholder="0x…" spellCheck={false} onChange={(e) => setAgent(e.target.value.trim())} />
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
        <button disabled={!isOwner || !validAgent} onClick={safe(open)}>
          Open / update line
        </button>
      </div>
      <Hint>
        One transaction, no funds move. It lets this agent borrow the vault's USDC up to the starter cap. Each full
        repayment made on time raises the cap by the step size, up to the max cap. Term is how long the agent has to
        repay after its first borrow; grace is the extra time before a default can be marked.
      </Hint>
      {l && (
        <dl className="dl">
          <dt>Line status</dt>
          <dd>
            {l.active ? <span className="ok">Active</span> : "Not active"} ·{" "}
            {l.frozen ? <span className="bad">Frozen (default)</span> : <span className="ok">Not frozen</span>}
          </dd>
          <dt>Cap now</dt>
          <dd>
            {usdcFmt(l.currentCap)} USDC (starter {usdcFmt(l.starterCap)}, step {usdcFmt(l.stepSize)}, max {usdcFmt(l.maxCap)})
          </dd>
          <dt>Debt</dt>
          <dd>{usdcFmt(l.principal)} USDC</dd>
          <dt>Due</dt>
          <dd>{ts(l.dueDate)}</dd>
        </dl>
      )}
      <h3>Destination allowlist</h3>
      <div className="row">
        <label>
          Allowlisted recipient
          <input value={recipient} placeholder="0x…" spellCheck={false} onChange={(e) => setRecipient(e.target.value.trim())} />
        </label>
        <button
          disabled={!isOwner || !validAgent || !isAddress(recipient)}
          onClick={safe(async () => {
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
          })}
        >
          Allow recipient
        </button>
      </div>
      <Hint>
        With the allowlist switched on for a line, the agent can only send borrowed USDC to addresses added here.
      </Hint>
      <h3>Stop or reset</h3>
      <div className="row">
        <button
          className="danger"
          disabled={!isOwner || !validAgent}
          onClick={safe(async () => {
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
          })}
        >
          Revoke agent
        </button>
        <button
          className="ghost"
          disabled={!isOwner || !validAgent}
          onClick={safe(async () => {
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
          })}
        >
          Clear default
        </button>
      </div>
      <Hint tone="danger">
        Revoke ends this agent's right to borrow at once and wipes its allowlist; its debt and public history remain.
        “Clear default” unfreezes a defaulted line, only after it is fully repaid, and resets the cap to the starter
        cap.
      </Hint>
      {status}
    </div>
  );
}

function AgentView({ vault, usdc }: { vault: Address; usdc?: Address }) {
  const { address } = useAccount();
  const [to, setTo] = useState("");
  const [amt, setAmt] = useState("10");
  const [repayAmt, setRepayAmt] = useState("10");
  const [memo, setMemo] = useState("");
  const [repayAgent, setRepayAgent] = useState("");
  const { writeContractAsync, status, run, safe, fail } = useTx();

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
      <h2>4. Borrow and repay (agent)</h2>
      {!l ? (
        <Loading />
      ) : !l.active && l.principal === 0n ? (
        <Empty>The connected wallet ({short(address)}) has no line on this vault, so it cannot borrow here. It can still repay for another agent.</Empty>
      ) : (
        <dl className="dl">
          <dt>Your line</dt>
          <dd>
            {l.active ? <span className="ok">Active</span> : <span className="bad">Revoked</span>}
            {l.frozen && <span className="bad"> · Frozen (default)</span>}
          </dd>
          <dt>Cap / available</dt>
          <dd>
            {usdcFmt(l.currentCap)} / {usdcFmt(credit)} USDC
          </dd>
          <dt>Debt</dt>
          <dd>{usdcFmt(l.principal)} USDC</dd>
          <dt>Due</dt>
          <dd>{ts(l.dueDate)}</dd>
          {h && (
            <>
              <dt>History</dt>
              <dd>
                tier {h.currentTier} · {h.onTimeCount} on time · {h.defaultCount} defaults
              </dd>
            </>
          )}
        </dl>
      )}
      <h3>Borrow</h3>
      <div className="row">
        <label>
          Pay to
          <input value={to} placeholder="0x…" spellCheck={false} onChange={(e) => setTo(e.target.value.trim())} />
        </label>
        <label>
          Borrow (USDC)
          <input value={amt} inputMode="decimal" onChange={(e) => setAmt(e.target.value)} />
        </label>
        <label>
          Memo (optional)
          <input value={memo} onChange={(e) => setMemo(e.target.value)} />
        </label>
        <button
          disabled={!isAddress(to)}
          onClick={safe(async () => {
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
          })}
        >
          Borrow
        </button>
      </div>
      <Hint>
        One transaction: the vault sends that much USDC straight to the “Pay to” address and adds it to your debt.
        The first borrow starts the term clock; repay in full before the due date to step your cap up. The memo (up
        to 32 bytes) is stored publicly with the borrow.
      </Hint>
      <h3>Repay</h3>
      <div className="row">
        <label>
          Agent to repay for (empty = you)
          <input
            value={repayAgent}
            placeholder={address ?? "0x…"}
            spellCheck={false}
            onChange={(e) => setRepayAgent(e.target.value.trim())}
          />
        </label>
        <label>
          Amount (USDC)
          <input value={repayAmt} inputMode="decimal" onChange={(e) => setRepayAmt(e.target.value)} />
        </label>
        <button
          disabled={!usdc}
          onClick={safe(async () => {
            if (!usdc || !address) return;
            if (repayAgent && !isAddress(repayAgent)) return fail("Agent to repay for is not a valid address.");
            const who = (repayAgent || address) as Address;
            const value = parseUnits(repayAmt || "0", 6);
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
          })}
        >
          Approve + repay
        </button>
        <button
          className="danger"
          onClick={safe(async () => {
            if (repayAgent && !isAddress(repayAgent)) return fail("Agent address is not valid.");
            const who = (repayAgent || address) as Address;
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
          })}
        >
          Mark default
        </button>
      </div>
      <Hint>
        Repay asks twice: an approval for exactly this amount, then the repayment, which moves USDC from your wallet
        into the vault and reduces that agent's debt (never more than is owed). Anyone can repay for any agent.
      </Hint>
      <Hint tone="danger">
        “Mark default” is open to anyone, but only succeeds once the agent's due date plus grace has passed with debt
        still owed. It freezes that line and adds a permanent public default to its history.
      </Hint>
      {status}
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
      <p className="muted">
        Read-only. Anyone can look up an agent on this vault; other apps can call <code>creditHistory(agent)</code>{" "}
        on-chain.
      </p>
      <div className="row">
        <label>
          Agent address
          <input value={agent} placeholder="0x…" spellCheck={false} onChange={(e) => setAgent(e.target.value.trim())} />
        </label>
        <button className="ghost" disabled={!valid} onClick={() => refetch()}>
          Refresh
        </button>
      </div>
      {!agent && <Empty>Enter an agent address to see its repayment record.</Empty>}
      {agent && !valid && <div className="bad muted">That is not a valid address.</div>}
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
