#! /bin/bash

export XSK_TEST_DEPS_DIR=$PWD/test
export XSK_TEST_INTF_NAME=test
export XSK_TEST_INTF_MAC=04:04:04:04:04:04
export XSK_ECHO_INTF_NAME=echo
export XSK_ECHO_INTF_MAC=06:06:06:06:06:06

eval $(opam env)

# Run with sudo if not already root (needed for AF_XDP CAP_NET_RAW)
if [ "$(id -u)" -eq 0 ]; then
  # Already root (e.g., in Docker container)
  dune runtest --profile=test
else
  # Not root, use sudo
  sudo --preserve-env=OPAM_SWITCH_PREFIX,CAML_LD_LIBRARY_PATH,OCAML_TOPLEVEL_PATH,PATH,XSK_TEST_DEPS_DIR,XSK_TEST_INTF_NAME,XSK_TEST_INTF_MAC,XSK_ECHO_INTF_NAME,XSK_ECHO_INTF_MAC \
    $(which dune) runtest --profile=test
fi
