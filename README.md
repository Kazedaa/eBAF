# eBPF Adblocker

A high-performance adblocker that uses eBPF/XDP to block network packets from blacklisted domains at the kernel level.

## Features

- Kernel-level packet filtering using eBPF/XDP
- DNS query inspection and domain blocking
- Configurable blacklist from file
- Real-time statistics
- Minimal performance overhead
- Multiple XDP mode support (native, hardware, generic)

## Prerequisites

- Linux kernel 4.18+ with eBPF support
- libbpf development libraries
- clang compiler
- CAP_NET_ADMIN capability (usually requires root)

## Installation

```bash
# Install dependencies on Ubuntu/Debian
sudo apt-get install libbpf-dev clang llvm

# Build the project
make

# Install (optional)
sudo make install
```

## Usage

First, find your network interface:
```bash
# Find available network interfaces
make find-interface

# Or manually check
ip link show
```

Then run the adblocker:
```bash
# Example: Run on wlan0 interface (replace with your interface)
sudo ./bin/adblocker wlan0 blacklist.txt

# Example: Run on enp0s3 interface (common in VMs)
sudo ./bin/adblocker enp0s3 blacklist.txt
```

Common interface names:
- `wlan0`, `wlp2s0` - WiFi interfaces
- `eth0`, `enp0s3`, `ens33` - Ethernet interfaces
- `docker0`, `br-*` - Docker/bridge interfaces

## Configuration

Edit `blacklist.txt` to add or remove domains. Each domain should be on a separate line. Comments start with `#`.

## How it Works

1. The eBPF program is attached to a network interface using XDP
2. All packets are inspected at the kernel level
3. DNS queries are parsed to extract domain names
4. Domain names are checked against the blacklist stored in an eBPF map
5. Packets from blacklisted domains are dropped before reaching userspace

## XDP Modes

The program automatically tries different XDP modes in order of performance:

1. **Native (DRV) Mode**: Fastest, requires driver support
2. **Hardware (HW) Mode**: Offloaded to NIC hardware
3. **Generic (SKB) Mode**: Most compatible, works on all interfaces
4. **Default Mode**: Kernel decides the best mode

## Performance

- Processes packets at line rate with minimal CPU overhead
- Scales to handle high network loads
- No userspace context switches for packet processing

## Troubleshooting

### XDP Attachment Issues

1. **Driver not supported**: The program will automatically fall back to generic SKB mode
2. **Permission denied**: Make sure to run with `sudo`
3. **Interface not found**: Use `make find-interface` to see available interfaces

### eBPF Verifier Issues

If you encounter verifier errors:
- The program uses a smaller domain buffer (64 bytes) to reduce complexity
- Loop iterations are limited with `#pragma unroll`
- Try updating to a newer kernel (5.4+)

### Common Issues

1. **Interface not found**: Use `make find-interface` to see available interfaces
2. **Permission denied**: Make sure to run with `sudo`
3. **Verifier errors**: Try updating to a newer kernel (5.4+)
4. **No XDP support**: The program will use generic SKB mode automatically

### Kernel Requirements

- Linux kernel 4.18+ with eBPF support
- XDP support (available in generic mode on all kernels with eBPF)
- CONFIG_BPF_SYSCALL=y in kernel config

## Testing

To test if the adblocker is working:

1. Start the adblocker with a domain in your blacklist
2. Try to resolve that domain with `nslookup` or `dig`
3. Check the statistics output for blocked packets

```bash
# Example test
echo "example.com" >> blacklist.txt
sudo ./bin/adblocker wlan0 blacklist.txt

# In another terminal
nslookup example.com
```
