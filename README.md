## Install dependencies and build
(tested on Ubuntu 24.04 x86 VM and docker)
```bash
./setup.sh
```
## Run example

Sender and receiver pair in `example/`

```bash
./run_example.sh
```

## Run tests

### Bare metal
```bash
./setup.sh
./test/docker_run.sh
```

### Docker
```bash
sudo docker build . -t test && docker run --privileged test
```
### Rebuild xdp echo (for tests)
If you need to rebuild the xdp echo program, run: `.test/build_echo.sh`. This may be necessary for newer versions of ubuntu. We tested on 24.04.





## Change log

12/29/2025

What we fixed:
1. **Fixed infinite recursion bug** in `src/xsk_stubs.c` (caught by modern GCC)
2. **Updated XDP echo program** - rewrote it from scratch with modern BTF format
3. **Fixed Docker memory issue** - Changed from `/tmp` (overlay fs) to `/dev/shm` (tmpfs) for AF_XDP UMEM
4. **Made docker_run.sh portable** - Auto-detects root vs non-root for sudo
5. **Updated test expectations** - Changed 4096 to 4352 for XDP headroom offset
## Key discoveries:
- AF_XDP UMEM needs memory backed by tmpfs (like `/dev/shm`), not overlay filesystems
- The existing libbpf v0.0.8 submodule works fine with kernel 6.17.8 when memory is correct
- Docker containers share the host kernel but have different filesystem characteristics
- All 23 tests now pass on both Ubuntu 24.04 bare metal and Docker
- Added example sender, receiver, and run script.
