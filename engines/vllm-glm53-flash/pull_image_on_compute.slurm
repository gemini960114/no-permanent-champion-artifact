#!/bin/bash
#SBATCH --job-name=pull_glm53_img
#SBATCH --partition=dev
#SBATCH --account=your-slurm-account
#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=00:59:00
#SBATCH --output=/path/to/work/github/litellm-proxy/engines/vllm-glm53-flash/logs/pull-image-%j.out
#SBATCH --error=/path/to/work/github/litellm-proxy/engines/vllm-glm53-flash/logs/pull-image-%j.err

# 於計算節點拉取 GLM-5.3-Flash 專用 vLLM image（登入節點重 IO 受限＋NFS unlink 競態）
cd /path/to/work/github/litellm-proxy/engines/vllm-glm53-flash
./pull_image.sh glm53-flash docker://vllm/vllm-openai:glm53-flash
