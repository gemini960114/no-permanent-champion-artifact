# LiteLLM HPC Proxy & Gateway

A multi-model, OpenAI-compatible API service on an HPC cluster: a [LiteLLM](https://github.com/BerriAI/litellm) gateway fronting Slurm-managed **SGLang** and **vLLM** engines on NVIDIA H200 GPUs, packaged as Apptainer/Singularity containers. The repository contains the platform (gateway, engine lifecycle, key management), the engine definitions, the benchmark tool and raw results, and the agent skills used to evaluate new models.

It is also the artifact for the paper **"No Permanent Champion: A Deployment Study of SGLang and vLLM across Dense, Ultra-Sparse MoE, and KDA-Hybrid Architectures on H200 GPUs"** ([`paper/`](./paper/)).

> **About this repository.** This is the public artifact for the paper: a redacted copy of the private platform repository and its commit history, produced with `git filter-repo`. Original commit timestamps are preserved. Deployment-specific details are replaced with placeholders throughout the history (see [Redaction](#redaction)). The private deployment's standalone network-access, tunnel, TLS, and client-connection guides are not included, in the current tree or in the history; the benchmark guide and the diagnosis skill retain the redacted connection and repair steps that the reliability analysis (Section 5.5 of the paper) relies on.
>
> **Language note.** Documentation, skills, and commit messages are written in Traditional Chinese; this page is the English entry point.

---

## For readers of the paper

### Where each result comes from

All raw per-run statistics are JSON files produced by [`benchmarks/stress_test.py`](./benchmarks/stress_test.py) and stored in [`benchmarks/results/`](./benchmarks/results/). Each file records success rate, aggregate output tokens, wall time, throughput (`tps`), and latency percentiles. Only HTTP 200 responses contribute output tokens.

| Paper item | Configuration | File(s) in `benchmarks/results/` |
| :--- | :--- | :--- |
| Table 4 | Dense (Qwen3.8-27B), R1 plain | `bench_ab_sglang_27b_r1.json`, `bench_ab_vllm_27b_r1.json` |
| Table 5 | Dense, R2 speculative decoding | `bench_ab_sglang_27b_r2_eagle.json`, `bench_ab_vllm_27b_r2_mtp.json` |
| Table 6 | Ultra-sparse MoE (Qwen3.8-Flash-Next) | `bench_ab_sglang_flash_r1.json`, `bench_ab_sglang_flash_r1b_ple_gpu.json` (embedding kept on GPU), `bench_ab_sglang_flash_r2.json`, `bench_ab_vllm_flash_r1.json`, `bench_ab_vllm_flash_r2.json` |
| Table 7 | KDA hybrid (GLM-5.3-Flash) | `bench_ab_sglang_glm53_r1.json`, `bench_ab_sglang_glm53_r2.json`, `bench_ab_vllm_glm53_r1.json`, `bench_ab_vllm_glm53_r2.json` |
| Table 8, Figure 2 | Synthesis of Tables 4–7 | same files as Tables 4–7 |
| Table 9 | 1,500-user mixed workload | `bench_mixed_1500_users_via_tunnel.json` (91.8%), `bench_mixed_1500_users_bypass_tunnel.json`, `bench_mixed_1500_users_sshd_fd_fixed.json`; the initial 67.9% run is recorded in the case records of [`.agents/skills/concurrency-troubleshooting/`](./.agents/skills/concurrency-troubleshooting/README.md) (case 1) |
| Fairness controls (§4) | Job-to-node placement of every engine in each comparison window | `ab_run_node_mapping.csv` |
| Other figures in the text | Earlier tuning runs (concurrency caps, single-engine loads) | `bench_result_*.json`, `bench_27b_500_users.json`, `bench_glm53_1000_users_cap*.json` |

### Other evidence

- **Engine configurations.** The validated image-version × parameter combinations are listed in [`engines/KNOWN_GOOD.md`](./engines/KNOWN_GOOD.md); each engine's full launch configuration is in its own directory under [`engines/`](./engines/).
- **Evaluation skills.** The procedures the agent executed are in [`.agents/skills/`](./.agents/skills/): `model-onboarding` (support check, hardware fit, A/B comparison), `concurrency-troubleshooting` (layered diagnosis used for Table 9), and `debug-journaling`. The manuscript-writing skills are third-party; they are pinned by content hash in [`skills-lock.json`](./skills-lock.json) and not redistributed.
- **Timeline.** The paper's statement that the benchmarks did not traverse the TLS front end rests on the commit history: the last A/B verdict (`36d19f2`, 2026-09-27 15:23 UTC+8) precedes the commit whose message records the HTTPS deployment (`02ef051`, 17:34). The preserved commit message records HTTPS deployment after the final A/B verdict; the deployment guides and runtime deployment logs are not included in this artifact. The benchmarks targeted the tunnel's plain-HTTP endpoint on the fronting VM.
- **Scope.** This is a substantial but not complete replication package: it does not redistribute model checkpoints or container images, and several scripts assume the NCHC cluster (Slurm accounts, file-system paths, login nodes). See the paper's Limitations and Availability sections.

---

## Architecture

```text
clients ──HTTPS──▶ fronting VM (Caddy, TLS) ──▶ reverse SSH tunnel ──▶ LiteLLM gateway (HPC login node)
                                                                          │  routes by model alias
                                                                          ├──▶ SGLang engines (Slurm jobs, H200)
                                                                          ├──▶ vLLM engines   (Slurm jobs, H200)
                                                                          └──▶ external model APIs
```

- **Engines** are self-contained directories (`engines/<framework>-<model>/`) with a `config.env`, a Slurm submit script, a health check, and a pinned container image.
- **Lifecycle.** An engine registers itself as `starting`, is promoted to `ready` only after an HTTP 200 and a valid OpenAI-format response, and is removed on job exit. Ports are claimed with atomic directory locks, so several instances can share a node.
- **Routing.** `start.sh` runs `scripts/generate_runtime_config.py`, which reconciles endpoint records against Slurm state and writes `config.runtime.yaml` for the gateway. Engines that are not ready are excluded.
- **Candidate isolation.** A candidate engine for an A/B comparison is published under a suffixed alias, so it receives no production traffic until an operator switches the alias.
- **Security.** The gateway binds a cluster-internal address on a non-default port; every request requires a master key or a per-user virtual key (`key_tool.py`), with optional per-key model allowlists and rate limits.

---

## Repository layout

| Path | Contents |
| :--- | :--- |
| `install.sh`, `start.sh`, `start_background.sh`, `stop.sh` | Gateway install, start (foreground/background), stop |
| `start_models.sh`, `stop_models.sh`, `validate_engine.sh`, `new_engine.sh` | Engine dispatch, shutdown, validation, and scaffolding |
| `healthcheck.sh`, `test.sh` | Health check (no inference) and end-to-end inference test |
| `key_tool.py`, `custom_auth.py` | Virtual API key management and gateway authentication hook |
| `config.yaml`, `scripts/generate_runtime_config.py`, `lib/lifecycle.sh` | Static gateway config, runtime config synthesis, shared lifecycle library |
| `engines/` | One directory per engine; `KNOWN_GOOD.md` lists validated recipes |
| `benchmarks/` | Load generator and raw results (see above) |
| `docs/` | Selected guides (Chinese): engine lifecycle, adding a model, lifecycle design |
| `.agents/skills/` | Agent skills for model onboarding and diagnosis (Chinese) |
| `tests/` | Unit and regression tests for the lifecycle logic |
| `paper/` | Paper source (`paper.tex`, `refs.bib`), Markdown version, and compiled PDF |

---

## Quick start

These commands assume a Slurm cluster with Apptainer/Singularity and H200 nodes; paths and account names in `engines/*/config.env` must be adapted to your site.

```bash
./install.sh                                  # virtualenv, LiteLLM, and a generated master key in .env
./start_models.sh --list                      # list engines and their state
./start_models.sh sglang-qwen-27b             # submit engine job(s), wait until ready, then start the gateway
./healthcheck.sh                              # verify processes, binding, auth, and upstream health
./test.sh                                     # end-to-end inference test (consumes tokens)
./key_tool.py generate --name "Alice" --models all   # issue a per-user API key
./stop_models.sh                              # release GPUs
```

Pulling a new engine image requires an explicit, fixed source; floating tags are rejected, and a manifest with the source and SHA-256 is written next to the image:

```bash
cd engines/<engine> && ./pull_image.sh <version-tag> docker://<repo>:<fixed-tag>
```

The gateway is OpenAI-compatible:

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:4000/v1", api_key="<YOUR_USER_API_KEY>")
print(client.chat.completions.create(model="Qwen3.8-27B",
      messages=[{"role": "user", "content": "Hello!"}]).choices[0].message.content)
```

Tests:

```bash
python3 -W error::ResourceWarning tests/test_lifecycle_logic.py
./tests/test_bash_locks.sh
```

For the engine lifecycle and onboarding procedures, see [`docs/`](./docs/) and [`.agents/skills/`](./.agents/skills/). Connection guides for the private deployment are not included.

---

## Redaction

The same substitutions were applied to every file in every commit and to all commit messages:

| Original | Placeholder |
| :--- | :--- |
| Public IP addresses and allowed source ranges | `VM_PUBLIC_IP`, `CLIENT_PUBLIC_IP`, `ALLOWED_CIDR`, `PUBLIC_IP` |
| Cluster-internal IP addresses and ranges | `LOGIN_N_IP`, `INTERNAL_IP`, `INTERNAL_CIDR` |
| Service and organization domains | `service.example.org`, `example.org`, `example-org` |
| Login nodes | `login-1` … `login-5` |
| GPU compute nodes | `node-A` … `node-N` (one-to-one, so same-node and different-node placements in `ab_run_node_mapping.csv` remain distinguishable); other nodes `gpu-node-N`, `cpu-node-1` |
| User name, home and work paths | `your-user`, `/path/to/work` |
| Slurm account and numeric user ID | `your-slurm-account`, `UID` |
| An API key committed early in the history and later removed | `REDACTED_API_KEY` |

Placeholders are plain tokens, so configuration templates remain valid shell syntax; they must still be replaced with site values before use. Slurm job IDs and job start/end times in `ab_run_node_mapping.csv` are kept, because they support the fairness controls in Section 4 of the paper. The corresponding author's e-mail address in the paper is kept. The pre-English versions of this README and the excluded guides are not part of the history. Commits that touched only excluded files were dropped, so commit hashes differ from the private repository.

---

## License

[MIT](./LICENSE). Model weights and container images are not included and are subject to their own licenses.
