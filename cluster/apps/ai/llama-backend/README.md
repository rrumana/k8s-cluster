## llama-backend

This kustomization deploys:

- `llama-static-a`: pinned llama.cpp model on node label `ai.llm.role=static-a`
- `llama-static-b`: pinned llama.cpp model on node label `ai.llm.role=static-b`
- `llama-swap`: dynamic model runner on node label `ai.llm.role=swap`
- `llm-gateway` (LiteLLM): shared OpenAI-compatible routing endpoint for LibreChat

Model defaults are defined in:

- `llama-static-a-configmap.yaml`
- `llama-static-b-configmap.yaml`
- `llama-swap-configmap.yaml`
- `litellm-configmap.yaml` (single example model mapping by default)

Swap model seeding:

- `llama-swap` uses an init container to pre-seed all models listed in
  `SWAP_MODELS` (`name|repo|quant`) into `/models/swap/<name>/model.gguf`.
- If a model is already seeded, it is skipped.
- Runtime swap commands use local `--model` paths, avoiding first-request HF fetch.

Shared secret dependency:

- `vllm-shared-secret` must exist and include `HUGGING_FACE_HUB_TOKEN`.
  This kustomization manages it via `externalsecret.yaml`.

Model storage:

- All workers share the RWX claim `llama-models-cache-bulk` for modular model
  pinning and switching.
- The claim uses `cephfs-bulk`, the EC 2:1 data pool on the retained `cephfs`
  filesystem. Model files are immutable/reconstructable bulk data and do not
  belong on the replicated CephFS pool.
- The models were migrated off the retired legacy `ceph-filesystem-data0`
  surface. Do not reintroduce that filesystem or the old claim name when adding
  a worker; mount `llama-models-cache-bulk` instead.
