#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// Map to store blacklisted IPs
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 10000);
    __type(key, __u32);  // IP address
    __type(value, __u8);
} blacklist_ip_map SEC(".maps");

// Statistics map
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, __u64);
} stats_map SEC(".maps");

// Stats indices
#define STAT_TOTAL 0
#define STAT_BLOCKED 1

static __always_inline void update_stats(__u32 stat_type) {
    __u64 *counter = bpf_map_lookup_elem(&stats_map, &stat_type);
    if (counter) {
        __sync_fetch_and_add(counter, 1);
    }
}

SEC("xdp")
int xdp_blocker(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    
    // Update total packet counter
    update_stats(STAT_TOTAL);

    // Check if it's an IPv4 packet
    struct ethhdr *eth = data;
    if (data + sizeof(*eth) > data_end)
        return XDP_PASS;
    
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;
    
    struct iphdr *ip = (struct iphdr *)(data + sizeof(*eth));
    if ((void *)ip + sizeof(*ip) > data_end)
        return XDP_PASS;
    
    // Check if source or destination IP is blacklisted
    __u8 *blocked;
    
    // Check destination IP
    blocked = bpf_map_lookup_elem(&blacklist_ip_map, &ip->daddr);
    if (blocked) {
        // Update blocked packet counter
        update_stats(STAT_BLOCKED);
        return XDP_DROP;
    }
    
    // Check source IP
    blocked = bpf_map_lookup_elem(&blacklist_ip_map, &ip->saddr);
    if (blocked) {
        // Update blocked packet counter
        update_stats(STAT_BLOCKED);
        return XDP_DROP;
    }
    
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
