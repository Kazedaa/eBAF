// This is the eBPF program that runs in kernel space to inspect and filter network packets
#include <linux/bpf.h>          // Core eBPF definitions
#include <linux/if_ether.h>     // Ethernet header definitions
#include <linux/ip.h>           // IP header definitions
#include <linux/in.h>           // Internet protocol definitions
#include <bpf/bpf_helpers.h>    // Helper functions for eBPF programs
#include <bpf/bpf_endian.h>     // Functions to handle endianness (byte order)

// Map to store blacklisted IP addresses
// - BPF_MAP_TYPE_LRU_HASH: A hash map that evicts least recently used entries when full
// - This map can store up to 10,000 IP addresses
// - Keys are 32-bit IP addresses
// - Values are 8-bit flags (1 means blocked)
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 10000);
    __type(key, __u32);
    __type(value, __u8);
} blacklist_ip_map SEC(".maps");  // SEC(".maps") is a special section for eBPF maps

// Statistics map to count total and blocked packets
// - BPF_MAP_TYPE_ARRAY: A simple array with fixed indices
// - Only 2 entries: one for total packets, one for blocked packets
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, __u64);
} stats_map SEC(".maps");

// Indices for the stats map
#define STAT_TOTAL 0    // Index 0 stores the total packet count
#define STAT_BLOCKED 1  // Index 1 stores the blocked packet count

// Helper function to increment statistics counters
// Uses atomic operations to safely update counters from multiple CPUs
static __always_inline void update_stats(__u32 stat_type) {
    // Look up the counter in the map
    __u64 *counter = bpf_map_lookup_elem(&stats_map, &stat_type);
    if (counter) {
        // Atomically increment the counter by 1
        __sync_fetch_and_add(counter, 1);
    }
}

// The main eBPF program that inspects each packet
// This runs for every network packet that passes through the interface
// SEC("xdp") defines this as an XDP (eXpress Data Path) program
SEC("xdp")
int xdp_blocker(struct xdp_md *ctx) {
    // Get pointers to the beginning and end of the packet data
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    
    // Count this packet in our total statistics
    update_stats(STAT_TOTAL);

    // Parse the Ethernet header (first layer of network packet)
    struct ethhdr *eth = data;
    // Check if the packet is large enough to contain an Ethernet header
    if (data + sizeof(*eth) > data_end)
        return XDP_PASS;  // If not, let the packet continue normally
    
    // Check if this is an IPv4 packet (we only filter these)
    // h_proto contains the protocol type, ETH_P_IP is IPv4
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;  // Not IPv4, let it pass
    
    // Parse the IP header (second layer of network packet)
    struct iphdr *ip = (struct iphdr *)(data + sizeof(*eth));
    // Check if the packet is large enough to contain an IP header
    if ((void *)ip + sizeof(*ip) > data_end)
        return XDP_PASS;  // If not, let the packet continue normally
    
    // Variable to hold the result of our blacklist lookup
    __u8 *blocked;
    
    // Check if the destination IP address is in our blacklist
    blocked = bpf_map_lookup_elem(&blacklist_ip_map, &ip->daddr);
    if (blocked) {
        // IP is blacklisted, update our blocked packet counter
        update_stats(STAT_BLOCKED);
        return XDP_DROP;  // Drop the packet (block it)
    }
    
    // Check if the source IP address is in our blacklist
    blocked = bpf_map_lookup_elem(&blacklist_ip_map, &ip->saddr);
    if (blocked) {
        // IP is blacklisted, update our blocked packet counter
        update_stats(STAT_BLOCKED);
        return XDP_DROP;  // Drop the packet (block it)
    }
    
    // If we get here, the packet is allowed
    return XDP_PASS;  // Let the packet continue normally
}

// Required license declaration for eBPF programs
// GPL license is required for accessing certain kernel features
char _license[] SEC("license") = "GPL";