# Makefile for Pwnagotchi on Kali Linux (RPi Zero 2 W)
# https://kali.download/arm-images/kali-2025.3/kali-linux-2025.3-raspberry-pi-zero-2-w-armhf.img.xz
# This Makefile automates the installation and setup of Pwnagotchi,
# including the Nexmon drivers, Bettercap, and Pwngrid.

# --- Configuration ---
# These variables can be overridden from the command line.

# Project Settings
PROJECT_NAME := pwnagotchi
APP_USER     ?= $(shell whoami)

# Directory Settings
APP_DIR      ?= /opt/$(PROJECT_NAME)
VENV_DIR     ?= $(APP_DIR)/venv
CONFIG_DIR   ?= /etc/$(PROJECT_NAME)

# Environment Settings
# Default Temporary Directory
TMPDIR ?= /var/tmp

# Python Settings
PYTHON_EXECUTABLE ?= python3

# Pwnagotchi Settings
PWNAGOTCHI_REPO ?= https://github.com/V0r-T3x/pwnagotchi.git
PWNAGOTCHI_BRANCH ?= dev
CONFIG_FILE ?= config.toml
 
# Auto-detect architecture for Go and Pwngrid.
# This prevents "Exec format error" if a 32-bit OS is running on a 64-bit capable Pi.
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),aarch64)
	PWNGRID_ARCH ?= linux_arm64
else
	PWNGRID_ARCH ?= linux_armhf
endif
 
# Pwngrid Settings
PWNGRID_VERSION ?= 1.10.3
 
# System dependencies for Pwnagotchi on Kali Linux, now including the 'bettercap' package from APT.
# Build-essentials are no longer needed for bettercap but kept for general compatibility.
DEPS := git python3 python3-dev python3-venv python3-pip aircrack-ng libpcap-dev bettercap bettercap-caplets unzip ninja-build libglib2.0-dev libdbus-1-dev libjpeg-dev zlib1g-dev libpng-dev libfreetype-dev build-essential python3-dev libyaml-dev libssl-dev libffi-dev i2c-tools swig gpiod libgpiod-dev libgpiod-doc libcap-dev golang

# Use .DEFAULT_GOAL to make `help` the default action.
.DEFAULT_GOAL := help

# Phony targets don't represent files.
.PHONY: all install uninstall clean reinstall help \
		install-deps setup-swap setup-liblgpio setup-libpcap-compat setup-nexmon setup-bettercap setup-pwngrid setup-pwnagotchi setup-config setup-service \
		uninstall-service uninstall-pwnagotchi \
		start stop restart status logs verify-nexmon

##@ General

all: install ## Install Pwnagotchi and all its dependencies.
reinstall: uninstall install ## Uninstall and then reinstall Pwnagotchi.
clean: ## Remove local build artifacts and __pycache__ directories.
	@echo "Cleaning up local build artifacts..."
	-sudo rm -rf $(PWNGRID_INSTALL_DIR)
	find . -type f -name "*.pyc" -delete
	find . -type d -name "__pycache__" -delete
	rm -rf .venv build dist *.egg-info

##@ Installation

install: install-deps setup-swap setup-liblgpio setup-libpcap-compat setup-nexmon setup-bettercap setup-pwngrid setup-pwnagotchi setup-config setup-service ## Run the full installation process.
	@echo "\n✅ Pwnagotchi installation complete."
	@echo "   A reboot is required to load the new drivers and start the services."
	@echo "   Run 'sudo reboot' to apply all changes."
	@echo "   After reboot, run 'make status' to check all service statuses."
	@echo "   Run 'make verify-nexmon' to check if monitor mode is working."

install-deps:
	@echo "--> Updating package lists and installing core system dependencies (including Bettercap build dependencies)..."
	sudo apt-get update
	sudo apt-get install -y $(DEPS)

setup-swap:
	@echo "--> Checking for and setting up 2GB swap file..."
	@DESIRED_SWAP_SIZE_GB=2; \
	DESIRED_SWAP_SIZE_BYTES=$$((DESIRED_SWAP_SIZE_GB * 1024 * 1024 * 1024)); \
	SWAP_FILE="/swapfile"; \
	CREATE_SWAP=false; \
	if [ -f "$$SWAP_FILE" ]; then \
		CURRENT_SIZE_BYTES=$$(stat -c%s "$$SWAP_FILE" 2>/dev/null || echo 0); \
		if [ "$$CURRENT_SIZE_BYTES" -lt "$$DESIRED_SWAP_SIZE_BYTES" ]; then \
			echo "    Swap file exists but is smaller than $$DESIRED_SWAP_SIZE_GB""GB. Recreating..."; \
			sudo swapoff $$SWAP_FILE || true; \
			sudo rm -f $$SWAP_FILE; \
			sudo sed -i '\|'$$SWAP_FILE'|d' /etc/fstab; \
			CREATE_SWAP=true; \
		else \
			echo "    $$DESIRED_SWAP_SIZE_GB""GB swap file already exists and is correctly sized. Skipping."; \
		fi; \
	else \
		CREATE_SWAP=true; \
	fi; \
	if [ "$$CREATE_SWAP" = true ]; then \
		echo "    Creating new $$DESIRED_SWAP_SIZE_GB""GB swap file at $$SWAP_FILE..."; \
		sudo fallocate -l $${DESIRED_SWAP_SIZE_GB}G $$SWAP_FILE && \
		sudo chmod 600 $$SWAP_FILE && \
		sudo mkswap $$SWAP_FILE && \
		sudo swapon $$SWAP_FILE && \
		echo "$$SWAP_FILE none swap sw 0 0" | sudo tee -a /etc/fstab && \
		echo "✅ Swap file created and enabled."; \
	fi;

setup-liblgpio:
	@echo "--> Manually compiling and installing liblgpio C library..."
	@# This is required because liblgpio is not in the Kali repositories.
	@if ldconfig -p | grep -q 'liblgpio.so'; then \
		echo "    liblgpio already installed. Skipping."; \
	else \
		cd /tmp && \
		wget -q https://github.com/joan2937/lg/archive/master.zip -O lg-master.zip && \
		unzip -q lg-master.zip && \
		cd lg-master && \
		make -j1 && \
		sudo make install && \
		sudo ldconfig && \
		cd / && sudo rm -rf /tmp/lg-master /tmp/lg-master.zip && \
		echo "✅ liblgpio C library installed successfully."; \
	fi;

setup-nexmon:
	@echo "--> Installing Nexmon DKMS and creating pure airmon-ng wlan0mon glue script..."
	sudo apt-get update
	sudo apt-get install -y brcmfmac-nexmon-dkms firmware-nexmon

	# nexutil is not required; airmon-ng works directly with the Nexmon DKMS driver.

	# Create the definitive wlan0mon readiness script using pure airmon-ng
	@echo '#!/bin/bash' | sudo tee /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '# Pure airmon-ng script to create a reliable wlan0mon for pwnagotchi' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'set -e' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'echo "=== Pure airmon-ng wlan0mon setup (Nexmon driver) ==="' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '# Kill interfering processes' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'airmon-ng check kill' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '# Standard airmon-ng flow - Nexmon driver supports this natively' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'sudo airmon-ng start wlan0' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'MON_IFACE="wlan0mon"' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '# Force UP (Nexmon driver quirk)' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'sudo ip link set $$MON_IFACE up 2>/dev/null || true' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'sudo ifconfig $$MON_IFACE up 2>/dev/null || true' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '# Verify (30s timeout)' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'for i in {1..30}; do' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '    if ip link show $$MON_IFACE 2>/dev/null | grep -qE "state (UP|UNKNOWN)"; then' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '        echo "✅ $$MON_IFACE UP and ready"' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '		touch /run/wlan0mon.ready' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '        iwconfig $$MON_IFACE  # Show monitor mode confirmation' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '		exit 0' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '    fi' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '    sleep 1' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'done' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo '' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'echo "❌ $$MON_IFACE failed"' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'ip link | grep wlan' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	@echo 'exit 1' | sudo tee -a /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	sudo chmod +x /usr/local/sbin/setup-wlan0mon.sh

	@echo "✅ Nexmon + wlan0mon glue ready. Reboot required."

setup-bettercap: install-deps
	@echo "--> Installing Bettercap from APT repository..."
	# This relies on the 'bettercap' package being in the DEPS list.
	# The install-deps target handles the installation.
	@echo "--> Updating Bettercap caplets and UI..."
	@echo "   - Installing caplets and web UI..."
	@echo "--> Creating bettercap-launcher script..."
	@echo '#!/usr/bin/env bash' | sudo tee /usr/bin/bettercap-launcher > /dev/null
	@echo 'source /usr/bin/pwnlib' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo '' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo '# we need to decrypt something' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo 'if is_crypted_mode; then' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo '  while ! is_decrypted; do' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo '    echo "Waiting for decryption..."' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo '    sleep 1' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo '  done' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo 'fi' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo '' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo 'reload_brcm' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo 'start_monitor_interface' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo '' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo 'if is_auto_mode_no_delete; then' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo '  /usr/bin/bettercap -no-colors -caplet pwnagotchi-auto -iface wlan0mon' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo 'else' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo '  /usr/bin/bettercap -no-colors -caplet pwnagotchi-manual -iface wlan0mon' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	@echo 'fi' | sudo tee -a /usr/bin/bettercap-launcher > /dev/null
	# Patch pwnlib to use our nexmon glue
	@echo '' | sudo tee -a /usr/bin/pwnlib > /dev/null
	@echo 'start_monitor_interface() {' | sudo tee -a /usr/bin/pwnlib > /dev/null
	@echo '    /usr/local/sbin/setup-wlan0mon.sh' | sudo tee -a /usr/bin/pwnlib > /dev/null
	@echo '}' | sudo tee -a /usr/bin/pwnlib > /dev/null

	sudo chmod +x /usr/bin/bettercap-launcher

	@echo "[Unit]" | sudo tee /etc/systemd/system/bettercap.service > /dev/null
	@echo "Description=bettercap with pwnagotchi caplet" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "Documentation=https://bettercap.org" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "Wants=network.target" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "[Service]" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "Type=simple" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "ExecStart=/usr/bin/bettercap-launcher" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "Restart=always" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "RestartSec=30" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "[Install]" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	@echo "WantedBy=multi-user.target" | sudo tee -a /etc/systemd/system/bettercap.service > /dev/null
	sudo /usr/bin/bettercap -eval "caplets.update; ui.update; quit"
	@echo "✅ Bettercap installation complete."

setup-libpcap-compat:
	@echo "--> Compiling and installing libpcap 1.9.1 to fix RPi monitor mode bug in 1.10.x..."
	@if [ ! -f /usr/local/lib/libpcap.so.1.9.1 ]; then \
		cd /tmp && \
		wget -q --show-progress https://www.tcpdump.org/release/libpcap-1.9.1.tar.gz && \
		tar xzf libpcap-1.9.1.tar.gz && \
		cd libpcap-1.9.1 && \
		./configure --prefix=/usr/local && \
		make -j1 && \
		sudo make install && \
		sudo ln -sf /usr/local/lib/libpcap.so.1.9.1 /usr/local/lib/libpcap.so.1 && \
		sudo ldconfig && \
		cd / && sudo rm -rf /tmp/libpcap-1.9.1 /tmp/libpcap-1.9.1.tar.gz && \
		echo "✅ libpcap 1.9.1 installed successfully."; \
	else \
		echo "    libpcap 1.9.1 already installed. Skipping."; \
	fi;

setup-pwngrid: setup-libpcap-compat
	@echo "--> Compiling Pwngrid from source to ensure compatibility..."
	@# This is the definitive fix for SIGSEGV errors on specific ARM/Kali combinations.
	@# First, ensure the Go compiler is installed via the main dependency target.
	@if ! command -v go > /dev/null; then \
		echo "   - Go compiler not found. Please run 'make install-deps' first."; \
		exit 1; \
	fi
	@echo "   - [1/4] Cloning and patching gopacket source..."
	cd /tmp && rm -rf gopacket-patched && git clone https://github.com/gopacket/gopacket.git gopacket-patched
	cd /tmp/gopacket-patched && git checkout v1.2.0
	@# This is the definitive fix for the 64-bit time_t type mismatch on 32-bit ARM.
	cd /tmp/gopacket-patched/pcap && sudo sed -i 's/C.gopacket_time_secs_t/C.__time64_t/g' pcap_unix.go
	cd /tmp/gopacket-patched/pcap && sudo sed -i 's/C.gopacket_time_usecs_t/C.__suseconds64_t/g' pcap_unix.go
	
	@echo "   - [2/4] Cloning pwngrid repository..."
	cd /tmp && rm -rf pwngrid && git clone https://github.com/jayofelony/pwngrid.git

	@echo "   - [3/4] Creating patched go.mod with local replace directive..."
	@echo 'module github.com/jayofelony/pwngrid' | sudo tee /tmp/pwngrid/go.mod > /dev/null
	@echo '' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo 'go 1.22' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo 'require (' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '	github.com/biezhi/gorm-paginator/pagination v0.0.0-20190124091837-7a5c8ed20334' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '	github.com/evilsocket/islazy v1.11.0' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '	github.com/go-chi/chi/v5 v5.1.0' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '	github.com/go-chi/cors v1.2.1' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '	github.com/golang-jwt/jwt/v5 v5.2.1' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '	github.com/gopacket/gopacket v1.2.0' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '	github.com/jinzhu/gorm v1.9.16' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '	github.com/joho/godotenv v1.5.1' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo ')' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo 'require golang.org/x/sys v0.22.0 // indirect' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo '' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null
	@echo 'replace github.com/gopacket/gopacket => /tmp/gopacket-patched' | sudo tee -a /tmp/pwngrid/go.mod > /dev/null

	@echo "   - [4/4] Building binary from patched source..."
	cd /tmp/pwngrid && go mod tidy
	cd /tmp/pwngrid && CGO_ENABLED=1 go build -ldflags="-s -w" -o pwngrid ./cmd/pwngrid/
	@echo "   - Installing compiled binary to /usr/local/bin/..."
	sudo mv /tmp/pwngrid/pwngrid /usr/local/bin/pwngrid
	sudo chmod +x /usr/local/bin/pwngrid
	@echo "   - Generating Pwngrid keypair..."
	sudo mkdir -p /etc/pwnagotchi
	@if [ ! -f /etc/pwnagotchi/id_rsa ]; then \
		sudo /usr/local/bin/pwngrid -generate -keys /etc/pwnagotchi; \
	else \
		echo "    Keys already exist, skipping generation."; \
	fi

	@echo "   - Creating pwngrid-peer.service..."
	sudo rm -f /etc/systemd/system/pwngrid-peer.service
	sudo touch /var/log/pwngrid-peer.log
	sudo chown root:root /var/log/pwngrid-peer.log
	sudo chmod 640 /var/log/pwngrid-peer.log

	@echo "[Unit]" | sudo tee /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "Description=pwngrid peer service" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "Documentation=https://pwnagotchi.org" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "Wants=network.target" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	# Wait for the network to be fully online and bind to the wlan0 device itself.
	@echo "After=network-online.target" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "BindsTo=sys-subsystem-net-devices-wlan0.device" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "[Service]" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "Environment=LD_PRELOAD=/usr/local/lib/libpcap.so.1" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "Environment=LD_LIBRARY_PATH=/usr/local/lib" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "Type=simple" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	# Create a fake ifconfig to prevent pwngrid from interfering with the monitor interface.
	# Prepending a custom bin directory to the PATH is safer than replacing system binaries.
	@echo "   - Neutralizing ifconfig for pwngrid service..."
	@sudo mkdir -p /usr/local/share/fake-commands
	@echo '#!/bin/sh' | sudo tee /usr/local/share/fake-commands/ifconfig > /dev/null
	@echo 'exit 0' | sudo tee -a /usr/local/share/fake-commands/ifconfig > /dev/null
	@sudo chmod +x /usr/local/share/fake-commands/ifconfig
	@echo "Environment='PATH=/usr/local/share/fake-commands:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null

	# Add wlan0mon readiness check BEFORE pwngrid starts
	@echo "ExecStartPre=/usr/local/sbin/setup-wlan0mon.sh" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "ExecStartPre=/bin/bash -c 'while [ ! -f /run/wlan0mon.ready ]; do sleep 1; done'" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null


	# The wrapper is no longer needed due to the robust setup-wlan0mon.sh and readiness check.
	# Calling pwngrid directly is now more stable.
	@echo "   - Removing obsolete pwngrid-wrapper..."
	@sudo rm -f /usr/local/bin/pwngrid-wrapper
	@echo "ExecStart=/usr/local/bin/pwngrid -keys /etc/pwnagotchi -peers /root/peers -address 127.0.0.1:8666 -client-token /root/.api-enrollment.json -wait -iface wlan0mon -log /var/log/pwngrid-peer.log" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null

	@echo "Restart=always" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "RestartSec=30" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "[Install]" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null
	@echo "WantedBy=multi-user.target" | sudo tee -a /etc/systemd/system/pwngrid-peer.service > /dev/null

	@echo "   - Starting pwngrid service..."
	sudo systemctl daemon-reload
	sudo systemctl enable pwngrid-peer.service
	sudo systemctl restart pwngrid-peer.service

	@echo "Pwngrid installation and service setup complete."
	
setup-pwnagotchi: install-deps setup-liblgpio
	@echo "--> Creating application directory at $(APP_DIR)..."
	sudo mkdir -p $(APP_DIR)
	@echo "--> Cloning Pwnagotchi repository from $(PWNAGOTCHI_REPO)..."
	sudo git clone --branch $(PWNAGOTCHI_BRANCH) $(PWNAGOTCHI_REPO) $(APP_DIR)
	@echo "--> Creating Python virtual environment at $(VENV_DIR)..."
	sudo $(PYTHON_EXECUTABLE) -m venv $(VENV_DIR)
	@echo "--> Installing Pwnagotchi Python dependencies..."
	@# Upgrade pip first.
	sudo $(VENV_DIR)/bin/pip install --upgrade pip setuptools wheel
	@echo "--> Pre-installing NumPy wheel to avoid compilation on RPi..."
	@# Detect architecture to download the correct wheel. armv7l is 32-bit, aarch64 is 64-bit.
	@# This avoids memory/CPU exhaustion from compiling NumPy from source.
	@UNAME_M=$(shell uname -m); \
	if [ "$$UNAME_M" = "armv7l" ]; then \
		echo "--> Pre-installing wheels for armv7l to avoid compilation..."; \
		WHEELS_TO_INSTALL="numpy/numpy-2.3.5-cp313-cp313-linux_armv7l.whl pillow/pillow-11.3.0-cp313-cp313-linux_armv7l.whl cryptography/cryptography-45.0.7-cp313-abi3-linux_armv7l.whl spidev/spidev-3.5-cp313-cp313-linux_armv7l.whl"; \
		for wheel_path in $$WHEELS_TO_INSTALL; do \
			WHEEL_FILE=$$(basename $$wheel_path); \
			PACKAGE_NAME=$$(dirname $$wheel_path); \
			WHEEL_URL="https://www.piwheels.org/simple/$$PACKAGE_NAME/$$WHEEL_FILE"; \
			echo "    Downloading $$WHEEL_FILE..."; \
			if sudo wget -q $$WHEEL_URL -O "/tmp/$$WHEEL_FILE"; then \
				sudo $(VENV_DIR)/bin/pip install "/tmp/$$WHEEL_FILE"; \
				sudo rm "/tmp/$$WHEEL_FILE"; \
			else \
				echo "⚠️  Could not download $$WHEEL_FILE. Pip will try to build from source."; \
			fi; \
		done; \
	else \
		echo "    Architecture is not armv7l ($$UNAME_M), installing NumPy via standard pip."; \
		sudo $(VENV_DIR)/bin/pip install numpy; \
	fi
	@# Install the pwnagotchi project in editable mode.
	@# This will read dependencies from pyproject.toml and install them.
	sudo MAKEFLAGS='-j1' TMPDIR=$(TMPDIR) -H $(VENV_DIR)/bin/pip install --editable $(APP_DIR)
	@echo "--> Setting ownership for application directory..."
	sudo chown -R $(APP_USER):$(APP_USER) $(APP_DIR)
	@echo "✅ Pwnagotchi application setup complete."

setup-config:
	@echo "--> Creating initial configuration directory and file..."
	sudo mkdir -p $(CONFIG_DIR)
	# This creates a blank config file to be edited by the user later
	sudo touch $(CONFIG_DIR)/$(CONFIG_FILE)
	@echo "✅ Configuration file $(CONFIG_DIR)/$(CONFIG_FILE) created."

setup-service:
	@echo "--> Creating pwnagotchi systemd service file..."
	@echo "[Unit]" | sudo tee /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "Description=Pwnagotchi deep reinforcement learning" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null	
	@echo "After=network-online.target pwngrid-peer.service bettercap.service" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "Wants=pwngrid-peer.service bettercap.service" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "[Service]" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "# Pwnagotchi must be run as root to access wifi/bettercap" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "User=root" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "Group=root" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "Type=simple" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "# ExecStart is a Python script wrapper that calls the main Pwnagotchi executable" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "ExecStart=sudo $(VENV_DIR)/bin/python3 $(VENV_DIR)/bin/pwnagotchi" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "Restart=always" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "RestartSec=30" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "[Install]" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null
	@echo "WantedBy=multi-user.target" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service > /dev/null

	@echo "   - Enabling and starting pwnagotchi service..."
	sudo systemctl daemon-reload
	sudo systemctl enable $(PROJECT_NAME).service
	# Do not start service now, wait for final reboot
	# sudo systemctl start $(PROJECT_NAME).service
	@echo "✅ Pwnagotchi service configuration complete."

##@ Uninstallation

uninstall: uninstall-service uninstall-pwnagotchi ## Run the full uninstallation process.

uninstall-service:
	@echo "--> Disabling and stopping all Pwnagotchi-related services..."
	-sudo systemctl stop $(PROJECT_NAME).service
	-sudo systemctl disable $(PROJECT_NAME).service
	-sudo systemctl stop pwngrid-peer.service
	-sudo systemctl disable pwngrid-peer.service
	-sudo systemctl stop bettercap.service
	-sudo systemctl disable bettercap.service
	-sudo rm /etc/systemd/system/$(PROJECT_NAME).service
	-sudo rm /etc/systemd/system/pwngrid-peer.service
	-sudo rm /usr/bin/bettercap-launcher
	-sudo systemctl daemon-reload

uninstall-pwnagotchi:
	@echo "--> Removing Pwnagotchi application, environment, and configuration files..."
	-sudo rm -rf $(APP_DIR)
	-sudo rm -rf $(CONFIG_DIR)
	@echo "✅ Uninstallation complete. (Note: Bettercap/Nexmon drivers must be manually uninstalled if no longer needed.)"

##@ Service Control

start: ## Start the pwnagotchi systemd service.
	sudo systemctl start $(PROJECT_NAME).service

stop: ## Stop the pwnagotchi systemd service.
	sudo systemctl stop $(PROJECT_NAME).service

restart: ## Restart the pwnagotchi systemd service.
	sudo systemctl restart $(PROJECT_NAME).service

status: ## Check the status of the pwnagotchi systemd service.
	@echo "--- Pwnagotchi Service Status ---"
	sudo systemctl status $(PROJECT_NAME).service || echo "Pwnagotchi service not found/active."
	@echo "\n--- Pwngrid Service Status ---"
	sudo systemctl status pwngrid-peer.service || echo "Pwngrid service not found/active."
	@echo "\n--- Bettercap is a prerequisite service; verify its installation: ---"
	@if [ -f /usr/bin/bettercap ]; then \
	    /usr/bin/bettercap -version; \
	else \
		echo "⚠️ Bettercap binary not found at /usr/bin/bettercap. Please run 'make install-deps'."; \
	fi

logs: ## Tail the logs for the pwnagotchi service.
	sudo journalctl -u $(PROJECT_NAME).service -f

##@ Verification

verify-nexmon: ## Verify that the Nexmon driver is loaded and monitor mode works.
	@echo "--- [1/3] Checking loaded kernel module..."
	@echo "          Expected output should contain '/updates/dkms/brcmfmac.ko'"
	@modinfo brcmfmac | grep filename
	@echo "\n--- [2/3] Attempting to start monitor mode on wlan0..."
	@echo "          Look for a new interface like 'wlan0mon' with type 'monitor'."
	-sudo airmon-ng start wlan0
	@echo "\n--- Current wireless devices:"
	@iw dev
	@echo "\n--- [3/3] Testing packet injection on wlan0mon (if available)..."
	@echo "          Look for 'Injection is working!'"
	@if iw dev | grep -q "wlan0mon"; then \
		sudo aireplay-ng --test wlan0mon; \
	else \
		echo "⚠️  wlan0mon interface not found. Cannot test injection."; \
		echo "   ... run 'sudo airmon-ng start wlan0' manually to resolve."; \
	fi

##@ Help

help: ## Show this help message.
	@echo "Usage: make <target>"
	@echo ""
	@grep -E '(^[a-zA-Z_-]+:.*##.*$$)|(^##@)' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##"; print "Available targets:\n"} /^##@/ {print "\n" $$1 "\n"} /^[^#]/ {printf "  %-30s %s\n", $$1, $$2}'