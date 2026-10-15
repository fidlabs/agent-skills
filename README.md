# fidlabs Claude Skills

Claude Code Skills for interacting with fidlabs tooling and services from a
client's own AI agent.

## Skills

- **[fcss-client](fcss-client/SKILL.md)** — onboard a dataset to the
  Filecoin Cold Storage Service (FCSS) / PoRep Market: prepare it with
  Singularity, upload it to client-owned storage (S3, R2, GCS, or any
  S3-compatible bucket), and propose, fund, and complete two independent
  storage deals (two copies, two different storage-provider organizations) via
  [filecoin-porep-market-tooling](https://github.com/fidlabs/filecoin-porep-market-tooling).
  Client-side only; runs on Filecoin mainnet — all deal proposals and
  payments are real.

## Using a skill

Point your agent (e.g. Claude Code) at the skill's directory, or copy it into
your own project's skills directory. See the individual skill's `SKILL.md`
for what it does, its prerequisites, and its safety notes.
