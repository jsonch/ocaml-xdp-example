/* XDP echo program - swaps MAC addresses and redirects packet back */

/* Basic type definitions */
typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;

typedef signed char __s8;
typedef signed short __s16;
typedef signed int __s32;
typedef signed long long __s64;

typedef __u16 __be16;
typedef __u32 __be32;
typedef __u64 __be64;
typedef __u32 __wsum;

#include <bpf/bpf_helpers.h>

/* Minimal definitions to avoid kernel header dependencies */
#ifndef ETH_ALEN
#define ETH_ALEN 6
#endif

/* XDP action codes */
#ifndef XDP_PASS
#define XDP_PASS 2
#define XDP_TX 3
#endif

/* xdp_md structure - minimal fields we need */
struct xdp_md {
    __u32 data;
    __u32 data_end;
    __u32 data_meta;
    __u32 ingress_ifindex;
    __u32 rx_queue_index;
    __u32 egress_ifindex;
};

/* Ethernet header structure */
struct ethhdr {
    unsigned char h_dest[ETH_ALEN];
    unsigned char h_source[ETH_ALEN];
    unsigned short h_proto;
} __attribute__((packed));

SEC("xdp_echo")
int xdp_echo_func(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    struct ethhdr *eth = data;

    /* Bounds check */
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    /* Swap source and destination MAC addresses */
    unsigned char tmp[ETH_ALEN];
    __builtin_memcpy(tmp, eth->h_source, ETH_ALEN);
    __builtin_memcpy(eth->h_source, eth->h_dest, ETH_ALEN);
    __builtin_memcpy(eth->h_dest, tmp, ETH_ALEN);

    /* Redirect back to same interface */
    return XDP_TX;
}

// char _license[] SEC("license") = "GPL";
