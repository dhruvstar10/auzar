# 02 — Azure setup (realtime voice + vision model)

Goal: an Azure-hosted realtime model our iOS app can talk to, paid from the owner's
$150/month Azure credits. Started 2026-10-22.

Never put keys or endpoints-with-keys in this file. Record names/regions only.

## Choices

- Region: **East US 2 or Central US.** Per Microsoft's region table (page updated 2026-10-19,
  checked 2026-10-22), the realtime models (`gpt-realtime`, `-1.5`, `-2`, `-2.1`, **`-2.1-mini`**,
  `gpt-realtime-mini`) are only in **Canada Central, Central US, East US 2** (Global Standard) and
  Central US / East US 2 (Data Zone). **West US 2 isn't listed for any Azure OpenAI model**, even
  though the portal "recommends" it. Owner is on the US West Coast; the extra ~40–70 ms round trip
  to Central/East is negligible next to model latency.
- Model: **`gpt-realtime-2.1-mini`** (2026-07-07) for development (cheapest); a full `gpt-realtime-2.x` deployment for quality comparisons later.
  Record exact model name + version below.
- Resource type: Microsoft Foundry (formerly Azure AI Foundry / Azure OpenAI) resource.

## Checklist

- [x] Subscription: **Visual Studio Enterprise** (only subscription; $150/mo credit, spending limit on by default)
- [x] Region: **Central US** (chosen 2026-10-22)
- [x] Resource group: **`rg-sbsi`**
- [x] Foundry resource: **`<resource>`** (Central US, public network access, system-assigned identity, no Key Vault/App Insights)
- [x] Foundry project: **`proj-sbsi`**
- [x] Model deployed (2026-10-22): **`realtime-mini`** → `gpt-realtime-2.1-mini` version 2026-07-07,
      **Global Standard**, 100k TPM / 200 RPM, content filter DefaultV2, version-upgrade policy
      "once a new default version is available". Model retirement date: **2027-07-30**.
      Endpoint host: `<resource>.cognitiveservices.azure.com`. The real resource name isn't in the repo: it's the host in `AZURE_OPENAI_ENDPOINT` in the gitignored `.env`.
- [x] Budget `sbsi-monthly` on the subscription (2026-10-22): $150, reset period **billing month**,
      email alerts at actual 50/80/95%. Cost data lags hours, so the spending limit is the real stop.
- [x] Smoke test from the Mac (2026-10-22): `tools/realtime_smoke_test.py` (venv `.venv`, websockets 13.1).
      **Image input + spoken reply both work.** Results: connect 0.74 s; one image ≈ **323 image
      tokens** (2.3 MB PNG, presumably downscaled server-side); **time to first audio 2.1 s**;
      7 s reply = 140 output audio tokens. Correct description ("rubber plant in a purple pot").
      - URL: `wss://<host>/openai/v1/realtime?model=<deployment>`, header `api-key`.
      - GA event names: `session.update` with `session.type: "realtime"`, `output_modalities`,
        `audio.output.format {type: audio/pcm, rate: 24000}`; replies stream as
        `response.output_audio.delta` / `response.output_audio_transcript.delta`.
      - Image goes in `conversation.item.create` as `{"type":"input_image","image_url":"data:<mime>;base64,…"}`.
- [x] Endpoint + key stored locally only: `~/code/sbsi/.env` (gitignored, chmod 600; template
      in `.env.example`). Owner pastes the key themselves. Never paste keys into AI chats.

## Notes

Sources: https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability

## Vision deployment (2026-10-26)

- [x] Azure CLI installed (`brew install azure-cli`, 2.91.0) and logged in (`az login`, Visual Studio Enterprise Subscription).
  Resource group: **`rg-sbsi`**.
- [x] Deployment **`vision`** → `gpt-5.4-mini` version 2026-03-17, GlobalStandard, 50K TPM, created with:
  `az cognitiveservices account deployment create -g rg-sbsi -n <resource> --deployment-name vision --model-name gpt-5.4-mini --model-version 2026-03-17 --model-format OpenAI --sku-name GlobalStandard --sku-capacity 50`
- Used by `VisionClient.swift` (chat completions at `https://<host>/openai/v1/chat/completions`, `model` = deployment name) and
  `tools/vision_test.py`. `.env` key: `AZURE_OPENAI_VISION_DEPLOYMENT=vision`, passed to the app via `tools/gen_ios_secrets.sh`.
- List models the resource can deploy: `az cognitiveservices account list-models -g rg-sbsi -n <resource>`.
