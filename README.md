
<div align="right">
  <details>
    <summary >🌐 Language</summary>
    <div>
      <div align="right">
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=en">English</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=zh-CN">简体中文</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=zh-TW">繁體中文</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=ja">日本語</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=ko">한국어</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=hi">हिन्दी</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=th">ไทย</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=fr">Français</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=de">Deutsch</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=es">Español</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=it">Itapano</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=ru">Русский</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=pt">Português</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=nl">Nederlands</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=pl">Polski</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=ar">العربية</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=fa">فارسی</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=tr">Türkçe</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=vi">Tiếng Việt</a></p>
        <p><a href="https://openaitx.github.io/view.html?user=Kazedaa&project=eBAF&lang=id">Bahasa Indonesia</a></p>
      </div>
    </div>
  </details>
</div>

# eBAF - eBPF Based Ad Firewall
<p align="center">
    <img src="assets/banner.png" alt="eBAF - eBPF Ad Firewall Banner" width="600"/>
</p>

## "You Wouldn't Download an Ad"
### But You Would Block One!
 
Spotify has built an empire on a simple formula: monetize your attention, underpay the artists, and sell you back your own time as a premium feature.
In their world, your listening experience is not yours. It’s a carefully curated marketplace — your ears are the product, your patience is the currency.

They like to call it a "free" tier.
But let’s be honest: it’s not free if you’re paying with your time.

Meanwhile, the artists you love — the people whose work keeps the platform alive — often earn mere fractions of pennies per stream. Spotify profits handsomely, the advertisers get their exposure, and the creators? They get scraps.

This isn’t just about skipping a few annoying ads.
It’s about refusing to participate in a system that profits from exploitation, distraction, and the commodification of your attention.

#### What is this?
An elegant little act of digital resistance: a clean, open-source adblocker for Spotify that stops the noise — literally.

No sketchy mods, no cracked clients, no malware masquerading as freedom. Just one goal: let the music play without being held hostage by ads.

Spotify isn’t free — you pay with your patience.

They bombard you with the same grating ads, over and over, until you give up and subscribe. Not because you love Premium. But because you’ve been worn down. That’s not freemium — that’s psychological warfare with a playlist.

Meanwhile, the artists? Still underpaid.
The ads? Louder. More frequent. Sometimes literally louder.
You? Just trying to vibe.

They profit from your patience and their underpayment of creators, all while pretending it’s the only sustainable way. Spoiler: it isn’t. They had a choice — but they chose profit margins over people.

Spotify wants you to believe this is the cost of access.
We believe that’s a lie.

We’re not pirates. We’re not criminals. We’re just people who think it's okay to draw a line.

This project isn’t about skipping a few ads. It’s about rejecting a system that says your silence can be sold, your experience can be interrupted, and your value begins only when you open your wallet.

Blocking ads is not theft.<br>
Stealing your time is.<br>
We’re not here to pirate. We’re here to opt out.<br>
<br>
**You wouldnt Download an Ad. But you would block one.**

## How does eBAF work?

eBAF (eBPF Ad Firewall) leverages the power of eBPF (Extended Berkeley Packet Filter) to block unwanted advertisements at the kernel level. Here's a high-level overview of its functionality:

## How does eBAF work?

eBAF (eBPF Ad Firewall) leverages eBPF (Extended Berkeley Packet Filter) to block ads at the kernel level efficiently. Here's a simplified overview:

1. **Packet Filtering**:
   - Inspects incoming network packets and blocks those matching a blacklist of IP addresses using XDP (eXpress Data Path).

2. **Dynamic Updates**:
   - Resolves domain names into IP addresses and updates the blacklist dynamically to stay effective against changing ad servers.

3. **Web Dashboard**:
   - Provides live statistics and monitoring through a user-friendly interface.

4. **High Performance**:
   - Operates directly at the network interface level, bypassing the kernel's networking stack for faster processing and minimal resource usage.

eBAF combines efficiency, transparency, and ease of use to deliver a powerful ad-blocking solution.

## Simple Install (Reccomended)
Make sure to have git and curl installed
```bash
git --version
curl --version
```
### Install
#### Enable Spotify integration (Recommended)
```bash
EBAF_ENABLE_SPOTIFY=yes curl -sSL https://github.com/Kazedaa/eBAF/raw/main/install.sh | sudo -E bash
```
#### Disable explicitly
```bash
EBAF_ENABLE_SPOTIFY=no curl -sSL https://github.com/Kazedaa/eBAF/raw/main/install.sh | sudo bash```
```

### Uninstall
```bash
curl -sSL https://raw.githubusercontent.com/Kazedaa/eBAF/main/uninstall.sh | sudo bash
```


## Dev Install
Run the following commands to install the required dependencies:
### Ubuntu/Debian
```bash
sudo apt-get update
sudo apt-get install libbpf-dev clang llvm libelf-dev zlib1g-dev gcc make python3

sudo apt update
sudo apt install net-tools
```

### Fedora/CentOS/RHEL 8+
```bash
sudo dnf update
sudo dnf install -y libbpf-devel clang llvm elfutils-libelf-devel zlib-devel gcc make python3 net-tools bc
```

### Arch
```bash
sudo pacman -Syu
sudo pacman -S --needed libbpf clang llvm libelf zlib gcc make python net-tools bc
```

### Fix asm/types.h Error whiel running eBPF code
Check the current link
`ls -l /usr/include/asm`
Find the currect link
`find /usr/include -name "types.h" | grep asm`
Fix the symbolic link 
```bash
sudo rm /usr/include/asm
sudo ln -s <current_link> /usr/include/asm
```

### Building the Project

To build the eBPF Adblocker, follow these steps:

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd eBAF
   ```

2. Build the project:
   ```bash
   make
   ```

3. (Optional) Install system-wide:
   ```bash
   sudo make install
   ```

4. Other install options (help desk)
    ```bash
    make help
    ````
5. UnInstall
    ```bash
    make uninstall
    ````

## Usage

### Running the Adblocker
    Uses spotify-stable.txt as default Blacklist.
    Usage: ebaf [OPTIONS] [INTERFACE...]
    OPTIONS:
    -a, --all               Run on all active interfaces
    -d, --default           Run only on the default interface (with internet access)
    -i, --interface IFACE   Specify an interface to use
    -D, --dash              Start the web dashboard (http://localhost:8080)
    -q, --quiet             Suppress output (quiet mode)
    -h, --help              Show this help message


### Configuring Blacklist
Edit the lists to add or remove domains. Each domain should be on a separate line. Comments start with `#`.

## Acknowledgements

A Special thanks to ❤️ <br>
1. [Isaaker's Spotify-AdsList](https://github.com/Isaaker/Spotify-AdsList/tree/main) <br>
2. [AnanthVivekanand's spotify-adblock](https://github.com/AnanthVivekanand/spotify-adblock)

for providing a spotify block list

## ⭐️ Support the Project

If you find eBAF useful, please consider starring the repository on GitHub! Your support helps increase visibility and encourages further development.