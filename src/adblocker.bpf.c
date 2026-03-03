#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>      // Added for IPv6 header definitions
#include <linux/in6.h>       // Added for struct in6_addr
#include <linux/types.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// --- MAPS ---

// IPv4 Blacklist Map (32-bit keys)
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 10000);
    __type(key, __u32);
    __type(value, __u64);
} blacklist_ip_map SEC(".maps");

// IPv6 Blacklist Map (128-bit keys)
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 10000);
    __type(key, struct in6_addr);
    __type(value, __u64);
} blacklist_ipv6_map SEC(".maps");

// IPv4 Whitelist Map
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10000);
    __type(key, __u32);
    __type(value, __u64);
} whitelist_ip_map SEC(".maps");

// IPv6 Whitelist Map
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10000);
    __type(key, struct in6_addr);
    __type(value, __u64);
} whitelist_ipv6_map SEC(".maps");

// Stats Map (Total and Blocked)
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, __u64);
} stats_map SEC(".maps");

#define STAT_TOTAL 0
#define STAT_BLOCKED 1

// --- HELPERS ---

static __always_inline void update_stats(__u32 stat_type) {
    __u64 *counter = bpf_map_lookup_elem(&stats_map, &stat_type);
    if (counter) {
        __sync_fetch_and_add(counter, 1);
    }
}

// --- MAIN XDP PROGRAM ---

SEC("xdp")
int xdp_blocker(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    
    update_stats(STAT_TOTAL);

    struct ethhdr *eth = data;
    if (data + sizeof(*eth) > data_end)
        return XDP_PASS;

    // ==========================================
    // IPv4 PROCESSING
    // ==========================================
    if (eth->h_proto == bpf_htons(ETH_P_IP)) {
        struct iphdr *ip = (struct iphdr *)(data + sizeof(*eth));
        if ((void *)ip + sizeof(*ip) > data_end)
            return XDP_PASS;

        // Allow localhost (127.0.0.0/8)
        if ((ip->saddr & bpf_htonl(0xFF000000)) == bpf_htonl(0x7F000000) || 
            (ip->daddr & bpf_htonl(0xFF000000)) == bpf_htonl(0x7F000000)) {
            return XDP_PASS;
        }

        // Whitelist check
        if (bpf_map_lookup_elem(&whitelist_ip_map, &ip->daddr) || 
            bpf_map_lookup_elem(&whitelist_ip_map, &ip->saddr)) {
            return XDP_PASS;
        }

        // Blacklist check
        __u64 *block_count_ptr;
        
        block_count_ptr = bpf_map_lookup_elem(&blacklist_ip_map, &ip->daddr);
        if (block_count_ptr) {
            update_stats(STAT_BLOCKED);
            __sync_fetch_and_add(block_count_ptr, 1);
            return XDP_DROP;
        }
        
        block_count_ptr = bpf_map_lookup_elem(&blacklist_ip_map, &ip->saddr);
        if (block_count_ptr) {
            update_stats(STAT_BLOCKED);
            __sync_fetch_and_add(block_count_ptr, 1);
            return XDP_DROP;
        }
    }
    // ==========================================
    // IPv6 PROCESSING
    // ==========================================
    else if (eth->h_proto == bpf_htons(ETH_P_IPV6)) {
        struct ipv6hdr *ipv6 = (struct ipv6hdr *)(data + sizeof(*eth));
        if ((void *)ipv6 + sizeof(*ipv6) > data_end)
            return XDP_PASS;

        // Loopback check (::1) is simplified here, letting it pass
        // In IPv6, loopback is 0000:0000:0000:0000:0000:0000:0000:0001
        if (ipv6->saddr.in6_u.u6_addr32[0] == 0 && ipv6->saddr.in6_u.u6_addr32[1] == 0 &&
            ipv6->saddr.in6_u.u6_addr32[2] == 0 && ipv6->saddr.in6_u.u6_addr32[3] == bpf_htonl(1)) {
            return XDP_PASS;
        }

        // Whitelist check
        if (bpf_map_lookup_elem(&whitelist_ipv6_map, &ipv6->daddr) || 
            bpf_map_lookup_elem(&whitelist_ipv6_map, &ipv6->saddr)) {
            return XDP_PASS;
        }

        // Blacklist check
        __u64 *block_count_ptr;
        
        block_count_ptr = bpf_map_lookup_elem(&blacklist_ipv6_map, &ipv6->daddr);
        if (block_count_ptr) {
            update_stats(STAT_BLOCKED);
            __sync_fetch_and_add(block_count_ptr, 1);
            return XDP_DROP;
        }
        
        block_count_ptr = bpf_map_lookup_elem(&blacklist_ipv6_map, &ipv6->saddr);
        if (block_count_ptr) {
            update_stats(STAT_BLOCKED);
            __sync_fetch_and_add(block_count_ptr, 1);
            return XDP_DROP;
        }
    }

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";