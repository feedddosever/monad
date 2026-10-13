# Demo video

Builds the narrated demo (about 2:50, under the 3:00 cap) from the live app. No screen recorder or editing is needed:

- `stage.html`: 1920×1080 stage with the slides (problem, credit model, why Monad, what's next) and the app in an iframe.
- `narration.json`: what is said (`tts`) and the on-screen caption for each step.
- `make-voice.py`: renders the narration with [Piper](https://github.com/rhasspy/piper), an offline TTS. The voice is synthetic, and the last slide says so.
- `record.mjs`: drives the real app in headless Chrome with an injected wallet and captures it with the CDP screencast. It connects a fresh wallet, switches network, borrows 100 mUSDC, waits for full history credit (¾ of the 60 s demo term), repays, then shows the seeded good payer and late payer.
- `build.py`: lays the narration at the logged times and encodes `out/monad-credit-demo.mp4` (H.264 + AAC).

## Record against Monad Testnet

Run this after `scripts/deploy-testnet.sh` and `scripts/seed-demo.sh`, which write `app/src/lib/deployment.json` and the seeded wallets.

```shell
(cd app && npm run build && npx next start -p 3000) &      # app built for the deployed chain
cd video && npm install
pip install piper-tts                                       # plus a voice, e.g. en_US-ryan-high.onnx(.json) from
                                                            # huggingface.co/rhasspy/piper-voices (en/en_US/ryan/high)
python3 make-voice.py "$(which piper)" /path/to/en_US-ryan-high.onnx
set -a; source ../.env; set +a                              # PRIVATE_KEY: funds a fresh demo wallet (0.3 MON)
node record.mjs                                             # real time, about 3 min
python3 build.py                                            # -> video/out/monad-credit-demo.mp4
```

Options: `CHROMIUM_PATH` if Chrome isn't installed, `RPC_URL` to override the chain's public RPC, and `TAKE=<name>` to reuse a demo wallet. Each take otherwise gets a new one, so it always starts at 800.

The narration quotes what the chain produces for a fresh wallet (800 → 888, collateral 100% → 67%, limit 150) and for the seeded wallets (941 and 571). The recorder waits for the 888, 941 and 571 scores on screen and fails if any is missing. The badge in the live segment names the network it recorded on.
