# rebuild the echo program
sudo apt-get install -y clang llvm libbpf-dev
echo "Compiling XDP echo program..."
# Check for required tools
if ! command -v clang &> /dev/null; then
    echo "Error: clang not found."
    echo ""
    echo "To install the required dependencies, run:"
    echo "  sudo apt-get update"
    echo "  sudo apt-get install -y clang llvm libbpf-dev"
    echo ""
    exit 1
fi
#
clang -O2 -g \
    -target bpf \
    -D__TARGET_ARCH_x86 \
    -c "test/xdp/xdp_echo.bpf.c" \
    -o "test/xdp/xdp_prog_kern.o"
