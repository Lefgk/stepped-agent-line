# Stepped Agent Line — spec (prototype, 22 Nov 2026)

Source: overnight research in `agents-lending.md`, idea 3. A stepped-cap sibling of in-house Agent Credit Line. Separate repo.

**Problem.** A flat credit line does not reward on-time repayment or give other apps a reusable track record. Priors does stepped credit on Robinhood Chain in USDG; 3Jane-style underwriting is too heavy. There is no small, fully backer-collateralized USDC vault on Ethereum and Base whose cap steps up.

**Users.** Backers posting USDC for agents they trust, and operators or other dapps that want a public on-time / default / tier record per agent.

**Scope (v1, Ethereum and Base, after an audit and Lef's OK).** One backer-funded USDC vault (EOA or Safe). Per agent: starter cap, step size, max cap, term, grace, optional destination allowlist. First borrow of a cycle starts `dueDate = now + term`. Full repayment at or before `dueDate` raises the cap by the step, up to the max. After `dueDate + grace`, anyone may `markDefault` and freeze the line. Anyone may repay. Pause, revoke, guardian. Public `creditHistory(agent)`. Simple web dapp. Out: pooled lenders, interest, fees, Aave yield, unsecured credit, other tokens or chains, ERC-8004.

**Competitors.** Agent Credit Line (flat cap, optional fee). Priors — https://priors.trade/use (USDG on Robinhood). 3Jane, Wildcat, Bond Credit. ERC-8460 draft ABI.

**Choices (for Lef to review).** USDC only; no interest and no fee. Fully backer-collateralized. Per-agent starter / step / max / term (1–365 days) / grace (0–14 days, recommended 3). On-time means a full repayment at or before `dueDate` — one step per cycle. Grace only delays `markDefault`; late repayment does not step and does not auto-default. After full repayment the backer may unfreeze, but cap and tier reset to starter; lifetime counts stay. Optional allowlist. Ownable2Step plus an optional guardian (pause/revoke only). Views `availableCredit`, `amountDue`, and `creditHistory` for other apps.
