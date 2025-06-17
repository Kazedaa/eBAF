// This is the eBPF program that runs in kernel space.
// It inspects network packets and applies filtering rules based on a blacklist of IP addresses.

// The SEC() macro is used to place functions and maps into specific ELF sections which the loader uses to identify them.

#include <linux/bpf.h>          // Core eBPF definitions (structures, constants)
#include <linux/if_ether.h>     // Ethernet header definitions (e.g., struct ethhdr)
#include <linux/ip.h>           // IP header definitions (e.g., struct iphdr)
#include <linux/types.h>        // Type definitions used within kernel space
#include <linux/in.h>           // Internet protocol definitions (e.g., IP protocols)
#include <bpf/bpf_helpers.h>    // Helper functions that help interacting with maps and the kernel
#include <bpf/bpf_endian.h>     // Functions for handling endianness (byte order conversion)
#include "ip_blacklist.h"       // Our pre-resolved IP list (from userspace, compiled into the program)

/*
   eBPF Map: blacklist_ip_map
   - Type: BPF_MAP_TYPE_LRU_HASH
     This is a hash table that automatically evicts the least recently used entries when full.
   - It can store up to 10,000 entries.
   - The keys are 32-bit IP addresses.
   - The values are 8-bit flags (here, 1 means the IP is blocked).
   - SEC(".maps") forces the compiler to place this map in a specific ELF section that the loader will look for.
*/
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 10000);
    __type(key, __u32);
    __type(value, __u64);
} blacklist_ip_map SEC(".maps");  // This macro defines a special “maps” section for eBPF maps

/*
   eBPF Map: stats_map
   - Type: BPF_MAP_TYPE_ARRAY
     A fixed-size array map with constant indices.
   - This map has only 2 entries: one for total packets and one for blocked packets.
   - Keys are 32-bit integers.
   - Values are 64-bit counters used to track packet statistics.
*/
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, __u64);
} stats_map SEC(".maps");

/*
   Define indices for the array in stats_map:
   - STAT_TOTAL (index 0) will count the total number of packets processed.
   - STAT_BLOCKED (index 1) will count the number of packets that were blocked (dropped).
*/
#define STAT_TOTAL 0    // Index zero in stats_map: total packet count
#define STAT_BLOCKED 1  // Index one in stats_map: blocked packet count

/*
   Helper function: update_stats
   - Increments a statistics counter in the stats_map.
   - The function uses bpf_map_lookup_elem() to retrieve a pointer to the counter.
   - The __sync_fetch_and_add() builtin is used for an atomic increment operation.
   - Atomic operations (using __sync_fetch_and_add) ensure safe updates when multiple CPUs update the same counter.
   - __always_inline forces the compiler to inline the function for performance.
*/
static __always_inline void update_stats(__u32 stat_type) {
    // Look up the counter in the stats_map map using the given index (stat_type)
    __u64 *counter = bpf_map_lookup_elem(&stats_map, &stat_type);
    if (counter) {
        // Atomically increment the counter by 1.
        __sync_fetch_and_add(counter, 1);
    }
}

/*
   XDP Program: xdp_blocker
   - This is the main eBPF function that is invoked for each network packet.
   - The SEC("xdp") macro tells the loader that this function is an XDP program.
   - XDP (eXpress Data Path) runs at the network driver level, allowing very fast packet processing.
   - It receives a pointer to a struct xdp_md (metadata describing the packet and context).
*/
SEC("xdp")
int xdp_blocker(struct xdp_md *ctx) {
    /*
       Get pointers to the start and end of the packet data:
       - ctx->data holds the start of the packet.
       - ctx->data_end holds the end of the packet, ensuring we don't read out-of-bounds.
       - Casting via (void *)(long) is used as required by the eBPF verifier.
    */
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    
    // Increment statistics: count this packet in total packet counter.
    update_stats(STAT_TOTAL);

    /*
       Parse the Ethernet header:
       - The Ethernet header is at the start of the packet.
       - Before processing, check that the packet is large enough using data_end pointer.
       - If the packet size is smaller than the expected header, then simply pass the packet.
    */
    struct ethhdr *eth = data;
    if (data + sizeof(*eth) > data_end)
        return XDP_PASS;  // XDP_PASS lets the packet proceed normally in the kernel network stack

    /*
       Filter non-IPv4 packets:
       - The Ethernet header field h_proto indicates the protocol.
       - ETH_P_IP (after conversion to network byte order) indicates an IPv4 packet.
       - If the packet is not IPv4, return XDP_PASS.
    */
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;
    
    /*
       Parse the IP header:
       - It starts immediately after the Ethernet header.
       - Check that the packet is of sufficient length so as not to over-read memory.
    */
    struct iphdr *ip = (struct iphdr *)(data + sizeof(*eth));
    if ((void *)ip + sizeof(*ip) > data_end)
        return XDP_PASS;
    
    /*
       Check the blacklist for the destination IP address:
       - bpf_map_lookup_elem() looks up the key (here, ip->daddr) in blacklist_ip_map.
       - If a non-null pointer is returned, the IP is blocked.
    */
    __u64 *block_count_ptr;
    block_count_ptr = bpf_map_lookup_elem(&blacklist_ip_map, &ip->daddr);
    if (block_count_ptr) {
        // Increment blocked packet counter.
        update_stats(STAT_BLOCKED);
        // Update IP block counter
        __sync_fetch_and_add(block_count_ptr, 1);
        return XDP_DROP;  // XDP_DROP instructs the kernel to drop this packet.
    }
    
    /*
       Similarly, check the blacklist for the source IP address.
       If the source address is found in the blacklist, also drop the packet.
    */
    block_count_ptr = bpf_map_lookup_elem(&blacklist_ip_map, &ip->saddr);
    if (block_count_ptr) {
         // Increment blocked packet counter.
        update_stats(STAT_BLOCKED);
        // Update per-IP block counter
        __sync_fetch_and_add(block_count_ptr, 1);
        return XDP_DROP;
    }
    
    // If neither source nor destination IP is blacklisted, let the packet continue.
    return XDP_PASS;
}

/*
   License Declaration:
   - eBPF programs require an explicit license declaration.
   - Setting a GPL (GNU General Public License) license allows the program to use GPL-only kernel functions.
*/
char _license[] SEC("license") = "GPL";