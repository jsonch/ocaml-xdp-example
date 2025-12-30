# run a simple demo of the sender and receiver on veths

# Cleanup function to run on exit or Ctrl+C
cleanup() {
  echo ""
  echo "Cleaning up..."
  sudo pkill -f "send.exe|recv.exe" 2>/dev/null || true
  sudo ip link set dev sender xdp off 2>/dev/null || true
  sudo ip link set dev receiver xdp off 2>/dev/null || true
  sudo ip link del sender 2>/dev/null || true
}

# Set trap to run cleanup on Ctrl+C or script exit
trap cleanup EXIT INT TERM

echo "building example dir"
dune build

# up veth pair
sudo ip link del sender 2>/dev/null || true
sudo ip link add dev sender type veth peer name receiver
sudo ip link set sender up
sudo ip link set receiver up
sudo ip link set sender promisc on
sudo ip link set receiver promisc on
sudo ip link set dev sender address 02:00:00:00:00:01
sudo ip link set dev receiver address 02:00:00:00:00:02

# start the receiver in the background
echo "starting receiver in background"
sudo ./_build/default/src/bin/recv.exe -d receiver -q 0 -w &
RECV_PID=$!
echo "Receiver PID: $RECV_PID"

sleep 2

# start sender
echo ""
echo "starting sender in background"
sudo ./_build/default/src/bin/send.exe \
  -d sender \
  -q 0 \
  -smac 02:00:00:00:00:01 \
  -dmac 02:00:00:00:00:02 \
  -sip 10.100.1.1:9999 \
  -dip 10.100.1.2:9999 \
  -w &
SEND_PID=$!
echo "Sender PID: $SEND_PID"


echo ""
echo "Running for 10 seconds"
sleep 10

echo ""
echo "Terminating processes"
echo "Killing sender (PID $SEND_PID)..."
sudo kill -INT $SEND_PID 2>/dev/null || true
sleep 1

echo "Killing receiver (PID $RECV_PID)..."
sudo kill -INT $RECV_PID 2>/dev/null || true
sleep 1

echo ""
echo "=== Cleaning up veth pair ==="
sudo ip link set dev sender xdp off 2>/dev/null || true
sudo ip link set dev receiver xdp off 2>/dev/null || true
sudo ip link del sender 2>/dev/null || true
