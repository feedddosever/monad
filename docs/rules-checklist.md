# Monad Metropolis submission checklist

**Deadline: Tue Oct 13, 2026, 11:59 PM ET (= Wed Oct 14, 03:59 UTC).** Build window: Sept 1 to Oct 13, 2026.

Source of truth: the "Metropolis Hackathon Rules & Guidelines" on [hackathon.monad.xyz](https://hackathon.monad.xyz) (behind sign-in). Re-read it before submitting; where this file and the official rules disagree, the official rules win. Items marked *(verify)* come from secondhand public summaries of the rules, not from the official text.

## Required

- [ ] **One track only.** Pick exactly one and tick it in the README [Track](../README.md#track) section:
  - Onchain Finance & Trading
  - Consumer Products & Payments
  - Social, Attention & Culture
  - Trust, Identity & AI Infrastructure
- [ ] **Contract addresses or tx hashes.** Deployed on Monad mainnet (143) or testnet (10143); addresses and tx hashes are listed with explorer links in [Contracts & tx hashes](../README.md#contracts--tx-hashes).
  - [ ] Every link opens on the explorer and shows the right network
  - [ ] Includes at least one real user-action tx, not only the deploy
  - [ ] `broadcast/<Script>/<chainId>/run-latest.json` committed
- [ ] **Why Monad section.** [Why Monad](../README.md#why-monad) is filled in with project-specific reasons, not generic chain marketing.
- [ ] **Public code.** Repo is public on GitHub and stays public through and after judging.
  - [ ] OSI-approved license present: [MIT](../LICENSE) *(verify)*
  - [ ] Opens in a logged-out/incognito browser
  - [ ] Clones and builds from the README alone (`git clone --recurse-submodules`, then [Run locally](../README.md#run-locally))
- [ ] **Demo video, 3:00 max.**
  - [ ] Length is 3:00 or less (hard cap)
  - [ ] Public link (YouTube / Loom / Vimeo), opens logged out *(verify)*
  - [ ] Shows the working product making real Monad transactions, not slides or mockups *(verify)*
  - [ ] Linked in the README [Demo video](../README.md#demo-video) section and in the submission form
- [ ] **AI disclosure.** README [AI tools used](../README.md#ai-tools-used) names every AI coding tool used (Claude Code at minimum) and what it was used for.
- [ ] **Commit history inside the window.** All commits fall between Sept 1 and Oct 13, 2026, with steady progress rather than one bulk upload.
  - [ ] Never backdate or rewrite commit timestamps
  - [ ] Pre-existing code is identified in the README [Built during the hackathon](../README.md#built-during-the-hackathon-sept-1-to-oct-13) section *(verify)*
  - [ ] Final commit is pushed before the deadline

## Also check

- [ ] Submission form completed on hackathon.monad.xyz before 11:59 PM ET Oct 13
- [ ] Solo entry; you are the primary contact for prizes *(verify)*
- [ ] No secrets in the repo: `.env` is untracked and no private keys appear in history
- [ ] CI is green on the final commit

## Pre-submit commands

```shell
# Commit dates: first and last must be inside Sept 1 to Oct 13, 2026
git log --reverse --format='%ad %h %s' --date=iso | head -n 1
git log -1 --format='%ad %h %s' --date=iso

# Nothing secret tracked
git ls-files | grep -E '(^|/)\.env($|\.)' | grep -v '\.env\.example$' || echo "no env files tracked"
git log -p | grep -iE 'private[_ ]?key\s*[:=]\s*(0x)?[0-9a-f]{64}' || echo "no private keys in history"

# Builds from clean
forge build && forge test
(cd app && npm ci && npm run build)

# Deployed code exists at each address
cast code <address> --rpc-url monad_testnet   # or monad_mainnet
```
