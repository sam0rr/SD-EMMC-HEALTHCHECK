# SD‑EMMC Healthcheck

An SD-EMMC lifetime and health analysis tool written in Bash. This script detects eMMC devices on your system, reads hardware registers, computes wear metrics, and generates a detailed report with lifespan estimates and recommendations.

## Repository

This project is hosted on GitHub:

```none
https://github.com/sam0rr/SD-EMMC_HEALTHCHECK
```

### Directory structure

```
SD-EMMC_HEALTHCHECK/
├── healthcheck.sh      # Main script
└── README.md           # Project documentation (this file)
```

## Features

* **Device discovery**: Automatically finds `mmcblk*` devices.
* **Wear analysis**: Parses EXT\_CSD registers to calculate A/B lifetime estimates.
* **Write statistics**: Computes daily and total written bytes.
* **Lifespan projection**: Estimates TBW, remaining life in days and years.
* **Health assessment**: Flags devices as Excellent, Good, or Attention Required.
* **Recommendations**: Provides actionable guidance based on wear.

## Prerequisites

* `bash` (version 4+)
* `mmc-utils` (for `mmc extcsd read`)
* `bc` (arbitrary‑precision calculator)
* Linux system with `/sys/block/mmcblk*` support

If you don’t have `mmc-utils` or `bc` installed:

```bash
sudo apt update
sudo apt install mmc-utils bc
```

## Installation

Choose one of the following methods:

### 1. One‑line curl + bash

*Downloads and executes the script without saving it locally.*

```bash
curl -fsSL https://raw.githubusercontent.com/sam0rr/SD-EMMC_HEALTHCHECK/main/healthcheck.sh | bash
```

### 2. Install as a system command

1. Download to `/usr/local/bin`:

   ```bash
   sudo curl -fsSL \
       https://raw.githubusercontent.com/sam0rr/SD-EMMC_HEALTHCHECK/main/healthcheck.sh \
       -o /usr/local/bin/emmc-healthcheck
   ```
2. Make executable:

   ```bash
   sudo chmod +x /usr/local/bin/emmc-healthcheck
   ```
3. Run it directly:

   ```bash
   emmc-healthcheck
   ```

## How it works

1. **discover\_emmc\_devices**: Finds block devices matching `mmcblk[0-9]+`.
2. **select\_device**: Prompts user to choose a device.
3. **read\_device\_stats**: Reads `/sys/block/<device>/stat` for write counters.
4. **mmc extcsd read**: Retrieves EXT\_CSD registers for lifetime estimates.
5. **Calculations**: Uses `awk` and `bc` to compute wear percentages and TBW.
6. **Report**: Displays formatted output with colors and recommendations.

## License

MIT License © 2025 Samorr
