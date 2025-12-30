#!/bin/bash
set -e

echo "=== Setting up OCaml XSK environment ==="
echo ""

# Check if we're on Ubuntu
if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    echo "Warning: This script is designed for Ubuntu, but we'll try anyway..."
fi

# Install system dependencies
echo "Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y clang llvm libelf-dev linux-base zlib1g-dev gcc-multilib ethtool apt-utils m4 pkg-config tcpdump iproute2

# Create a new opam switch for this project
echo ""
echo "Creating new opam switch 'xsk-test' with OCaml 4.10.0+flambda..."
opam switch create xsk-test 4.10.0+flambda --yes || echo "Switch already exists, continuing..."
eval $(opam env --switch=xsk-test)

# Install OCaml dependencies
echo ""
echo "Installing OCaml dependencies..."
opam install -y base dune ppx_jane base_bigstring ppx_cstruct cstruct expect_test_helpers_kernel core core_bench

# Build the project
echo ""
echo "Building the project..."
eval $(opam env --switch=xsk-test)
dune build

echo ""
echo "=== Setup complete ==="
