# Local configuration for scripts/hanare-llama-run.sh.
# Copy this file to runtime/llama-env.sh and adjust the values to your machine.
# runtime/ is git-ignored: your paths never enter the repository.

# Directory holding effort-proxy.py and the agent extras (chat template, MCP
# config). The proxy is only started when effort-proxy.py exists there.
HANARE_AGENT_DIR=$HOME/llama.cpp/qwen38-agent

# llama-server binary.
HANARE_LLAMA_SERVER=$HOME/llama.cpp/build/bin/llama-server

# Python used to run effort-proxy.py.
HANARE_PROXY_PYTHON=python3

# Optional: CUDA runtime library directory, prepended to LD_LIBRARY_PATH.
# HANARE_CUDA_LIB=$HOME/cuda-12.9/lib64

# GPU index for the AI side.
HANARE_CUDA_DEVICE=0
